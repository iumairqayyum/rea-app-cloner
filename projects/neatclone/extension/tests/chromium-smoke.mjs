// Actual Chromium loader/API smoke test; optional temporary native-host fixture.
// This tests browser transport, not a macOS application or download execution.
import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";

const extension = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
// Respect managed browser policy. This environment currently denies all new
// extensions; do not change policy or try another profile to evade it.
try {
  const policyDirectory = "/etc/chromium/policies/managed";
  for (const name of await fs.readdir(policyDirectory)) {
    if (!name.endsWith(".json")) continue;
    const policy = JSON.parse(await fs.readFile(path.join(policyDirectory, name), "utf8"));
    if (policy.ExtensionInstallBlocklist?.includes("*") || policy.ExtensionSettings?.["*"]?.installation_mode === "blocked") {
      console.error(JSON.stringify({blocked: true, reason: "Managed Chromium policy blocks new extensions; browser integration is unverified. No policy was changed."}));
      process.exit(2);
    }
  }
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
const directory = await fs.mkdtemp(path.join(os.tmpdir(), "neatclone-chromium-"));
const fixture = process.argv.includes("--with-native-fixture");
let nativeManifest;
let browser;
let socket;
const errors = [];
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
try {
  browser = spawn(process.env.CHROMIUM || "chromium", [
    "--headless=new", "--no-sandbox", "--disable-gpu", "--no-first-run", "--enable-unsafe-extension-debugging",
    "--no-default-browser-check", "--remote-debugging-port=0",
    `--user-data-dir=${directory}/profile`,
    `--disable-extensions-except=${extension}`, `--load-extension=${extension}`,
    "about:blank",
  ], {stdio: ["ignore", "ignore", "pipe"]});
  let browserDiagnostics = "";
  browser.stderr.on("data", chunk => { browserDiagnostics = (browserDiagnostics + chunk).slice(-16384); });
  const deadline = Date.now() + 30000;
  let port;
  while (Date.now() < deadline) {
    try { port = (await fs.readFile(`${directory}/profile/DevToolsActivePort`, "utf8")).split("\n")[0]; break; }
    catch { await delay(100); }
  }
  assert.ok(port, "Chromium did not open DevTools in 30 seconds");
  let worker;
  let lastTargets = [];
  while (Date.now() < deadline) {
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`, {signal: AbortSignal.timeout(5000)})).json();
    lastTargets = targets;
    worker = targets.find(x => x.type === "service_worker" && x.url.endsWith("/background.js"));
    if (worker) break;
    await delay(100);
  }
  if (!worker) {
    const registrations = [];
    for (const name of ["Preferences", "Secure Preferences"]) {
      try {
        const profile = JSON.parse(await fs.readFile(`${directory}/profile/Default/${name}`, "utf8"));
        for (const [id, value] of Object.entries(profile.extensions?.settings || {})) {
          registrations.push({id, name: value.manifest?.name, path: value.path});
        }
      } catch {}
    }
    console.error(JSON.stringify({targets: lastTargets.map(x => ({type: x.type, url: x.url})), registrations,
      extensionDiagnostics: browserDiagnostics.split("\n").filter(x => /extension/i.test(x))}));
  }
  assert.ok(worker, "Extension service worker was not discovered");
  const extensionID = new URL(worker.url).hostname;
  socket = new WebSocket(worker.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let sequence = 0;
  const pending = new Map();
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (message.method === "Runtime.exceptionThrown") errors.push(message.params.exceptionDetails.text);
    if (pending.has(message.id)) {
      const {resolve, reject, timer} = pending.get(message.id);
      pending.delete(message.id); clearTimeout(timer);
      message.error ? reject(new Error(message.error.message)) : resolve(message.result);
    }
  };
  function rpc(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timed out: ${method}`)); }, 15000);
      pending.set(id, {resolve, reject, timer});
      socket.send(JSON.stringify({id, method, params}));
    });
  }
  async function evaluate(expression) {
    const result = await rpc("Runtime.evaluate", {expression, awaitPromise: true, returnByValue: true});
    assert.equal(result.exceptionDetails, undefined, "Extension runtime evaluation failed");
    return result.result.value;
  }
  await rpc("Runtime.enable");
  const manifest = await evaluate("chrome.runtime.getManifest()");
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.name, "NeatClone Link Handoff");
  const permissions = await evaluate("chrome.permissions.getAll()");
  assert.deepEqual(permissions.origins || [], []);
  assert.ok(permissions.permissions.includes("nativeMessaging"));
  const background = await evaluate("import(chrome.runtime.getURL('background.js')).then(x => typeof x.createController)");
  assert.equal(background, "function");
  let nativeRoundTrip = "not requested";
  if (fixture) {
    const hostDirectory = path.join(os.homedir(), ".config/chromium/NativeMessagingHosts");
    const manifestPath = path.join(hostDirectory, "com.neatclone.bridge.json");
    await fs.mkdir(hostDirectory, {recursive: true});
    const hostPath = path.join(directory, "host.py");
    await fs.writeFile(hostPath, `#!/usr/bin/env python3\nimport json,struct,sys\nraw=sys.stdin.buffer.read(4)\nif len(raw)!=4: sys.exit(1)\nn=struct.unpack('=I',raw)[0]\nif n>65536: sys.exit(1)\nrequest=json.loads(sys.stdin.buffer.read(n))\nif request!={'version':1,'action':'enqueue','url':'https://example.test/video.mp4','kind':'direct'}: sys.exit(1)\nreply=json.dumps({'ok':True,'id':'chromium-smoke-test'}).encode()\nsys.stdout.buffer.write(struct.pack('=I',len(reply))+reply)\nsys.stdout.buffer.flush()\n`, {mode: 0o700});
    // Exclusive create protects any real user-installed host. Never overwrite it.
    await fs.writeFile(manifestPath, JSON.stringify({name: "com.neatclone.bridge", description: "Temporary NeatClone transport test", path: hostPath, type: "stdio", allowed_origins: [`chrome-extension://${extensionID}/`]}), {flag: "wx", mode: 0o600});
    nativeManifest = manifestPath;
    const reply = await evaluate("chrome.runtime.sendNativeMessage('com.neatclone.bridge', {version:1,action:'enqueue',url:'https://example.test/video.mp4',kind:'direct'})");
    assert.deepEqual(reply, {ok: true, id: "chromium-smoke-test"});
    nativeRoundTrip = "passed with temporary Python fixture, not the macOS app";
  }
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({chromiumExtensionLoaded: true, serviceWorkerImported: true, broadHostAccessAtInstall: false, nativeRoundTrip, extensionRuntimeErrors: errors.length}, null, 2));
} finally {
  socket?.close();
  if (nativeManifest) await fs.unlink(nativeManifest);
  if (browser) {
    browser.kill("SIGTERM");
    await Promise.race([new Promise(resolve => browser.once("exit", resolve)), delay(3000)]);
    if (browser.exitCode === null) browser.kill("SIGKILL");
  }
  await fs.rm(directory, {recursive: true, force: true});
}
