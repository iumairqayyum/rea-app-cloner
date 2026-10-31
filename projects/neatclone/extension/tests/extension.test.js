import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import {webcrypto} from "node:crypto";
import {classify, httpURL, sitePattern, normalize, preferEquivalent, displayURL, collectPageMedia, HOST} from "../media.js";
import {createController} from "../background.js";
if (!globalThis.crypto) globalThis.crypto = webcrypto;

test("manifest installs no broad host access or credential capture permissions", () => {
  const manifest = JSON.parse(fs.readFileSync(new URL("../manifest.json", import.meta.url)));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.host_permissions, undefined);
  assert.equal(manifest.content_scripts, undefined);
  assert.ok(manifest.permissions.includes("nativeMessaging"));
  assert.ok(manifest.permissions.includes("downloads"));
  for (const permission of ["cookies", "debugger", "webRequestBlocking"]) assert.ok(!manifest.permissions.includes(permission));
});
test("classifies MIME and pathname without mistaking query parameters for a file", () => {
  assert.equal(classify("https://cdn.test/v.mp4?token=secret"), "direct");
  assert.equal(classify("https://cdn.test/get", "Video/MP4; codecs=avc1"), "direct");
  assert.equal(classify("https://cdn.test/hls", "application/vnd.apple.mpegurl"), "hls");
  assert.equal(classify("https://cdn.test/part.TS"), "segment");
  assert.equal(classify("https://cdn.test/get?file=movie.mp4"), null);
  assert.equal(classify("https://cdn.test/file", "video/mp2t"), "segment");
});
test("URLs forbid embedded credentials and non-network schemes; labels omit signed queries", () => {
  for (const url of ["file:///tmp/private", "blob:https://a.test/123", "javascript:alert(1)", "https://user:pass@a.test/a.mp4"]) assert.throws(() => httpURL(url));
  assert.equal(httpURL("https://a.test/v.mp4#secret").href, "https://a.test/v.mp4");
  assert.equal(sitePattern("https://a.test/page"), "https://a.test/*");
  assert.equal(sitePattern("http://localhost:8123/video"), "http://localhost/*");
  assert.equal(displayURL("https://a.test/video.mp4?secret=token"), "a.test/video.mp4");
});
test("MP4 substitution requires the same explicit media identity and quality", () => {
  const hls = {id: "h", kind: "hls", group: "element:0", quality: "720"};
  const mp4 = {id: "m", kind: "direct", group: "element:0", quality: "720"};
  assert.equal(preferEquivalent([hls, mp4], hls), mp4);
  assert.equal(preferEquivalent([hls, {...mp4, group: "element:1"}], hls), hls);
  assert.equal(preferEquivalent([hls, {...mp4, quality: "360"}], hls), hls);
  assert.equal(preferEquivalent([{...hls, quality: ""}, {...mp4, quality: ""}], {...hls, quality: ""}).kind, "hls");
  assert.equal(preferEquivalent([mp4], mp4), mp4);
});
test("normalization ignores unsupported media, constrains metadata, and retains URL tokens for transfer", () => {
  assert.equal(normalize({url: "https://a.test/a.html"}, "x"), null);
  const item = normalize({url: "https://a.test/a.mp4?token=x", quality: "1080p", group: "element:1"}, "x");
  assert.equal(item.quality, "1080");
  assert.equal(item.url, "https://a.test/a.mp4?token=x");
});

function mock() {
  const sent = [], granted = new Set(["https://page.test/*"]);
  const tab = {id: 7, url: "https://page.test/watch"};
  let raw = [
    {url: "https://page.test/movie.m3u8", group: "element:0", quality: "720"},
    {url: "https://page.test/movie.mp4?token=secret", group: "element:0", quality: "720"},
    {url: "https://page.test/part.ts"},
  ];
  const api = {
    tabs: {get: async id => { assert.equal(id, 7); return tab; }},
    permissions: {contains: async ({origins}) => origins.every(x => granted.has(x))},
    scripting: {executeScript: async options => {
      assert.equal(options.target.tabId, 7);
      assert.equal(options.func, collectPageMedia);
      return [{result: raw}];
    }},
    runtime: {
      id: "extension-id", getURL: path => "chrome-extension://extension-id/" + path,
      sendNativeMessage: async (host, message) => { sent.push({host, message}); return {ok: true, id: "download-1"}; },
    },
  };
  const sender = {id: api.runtime.id, url: api.runtime.getURL("popup.html")};
  const controller = createController(api);
  const handle = message => controller.handle({tabID: 7, ...message}, sender);
  return {api, sender, controller, handle, sent, granted, tab, setRaw: value => {raw = value;}};
}
test("actual controller scans and sends equivalent MP4 via the native host", async () => {
  const m = mock();
  const scan = await m.handle({action: "scan"});
  assert.equal(scan.ok, true);
  assert.equal(scan.candidates.length, 3);
  const reply = await m.handle({action: "send", candidateID: scan.candidates[0].id});
  assert.deepEqual(reply, {ok: true, id: "download-1", usedDirectMP4: true});
  assert.deepEqual(m.sent[0], {host: HOST, message: {
    version: 1, action: "enqueue", url: "https://page.test/movie.mp4?token=secret", kind: "direct", pageURL: "https://page.test/watch",
  }});
  assert.equal(Object.hasOwn(m.sent[0].message, "cookies"), false);
});
test("controller refuses unapproved sites, forged senders, arbitrary IDs, TS and stale pages", async () => {
  const m = mock();
  assert.equal((await m.controller.handle({action: "scan", tabID: 7}, {id: "other", url: m.sender.url})).ok, false);
  m.granted.clear();
  assert.equal((await m.handle({action: "scan"})).ok, false);
  m.granted.add("https://page.test/*");
  const scan = await m.handle({action: "scan"});
  assert.equal((await m.handle({action: "send", candidateID: "arbitrary"})).ok, false);
  assert.equal((await m.handle({action: "send", candidateID: scan.candidates[2].id})).ok, false);
  m.tab.url = "https://page.test/different";
  assert.equal((await m.handle({action: "send", candidateID: scan.candidates[1].id})).ok, false);
  assert.equal(m.sent.length, 0);
});
test("cross-site handoff requires separate permission and native errors never echo tokens", async () => {
  const m = mock();
  m.setRaw([{url: "https://cdn.test/media.mp4?secret=token"}]);
  const scan = await m.handle({action: "scan"});
  assert.equal((await m.handle({action: "send", candidateID: scan.candidates[0].id})).ok, false);
  m.granted.add("https://cdn.test/*");
  m.api.runtime.sendNativeMessage = async () => { throw new Error("URL secret=token"); };
  const failed = await m.handle({action: "send", candidateID: scan.candidates[0].id});
  assert.equal(failed.ok, false);
  assert.ok(!JSON.stringify(failed).includes("secret=token"));
});
test("opt-in response observation uses MIME, deduplicates and respects navigation", async () => {
  const m = mock();
  await m.handle({action: "scan"});
  const details = {tabId: 7, url: "https://page.test/get?id=1", responseHeaders: [{name: "Content-Type", value: "video/mp4"}]};
  await m.controller.observe(details);
  await m.controller.observe(details);
  assert.equal((await m.handle({action: "list"})).candidates.length, 4);
  await m.controller.observe({...details, url: "https://unapproved.test/get"});
  assert.equal((await m.handle({action: "list"})).candidates.length, 4);
  m.tab.url = "https://page.test/new";
  await m.controller.observe(details);
  assert.deepEqual((await m.handle({action: "list"})).candidates, []);
});
test("DOM scan retains source grouping and quality and collects main-frame links/resources only", () => {
  const originalDocument = globalThis.document;
  const originalPerformance = globalThis.performance;
  const sources = [
    {src: "https://page.test/v.m3u8", type: "application/vnd.apple.mpegurl", dataset: {quality: "720p"}},
    {src: "https://page.test/v.mp4", type: "video/mp4", dataset: {quality: "720p"}},
  ];
  globalThis.document = {
    baseURI: "https://page.test/watch",
    querySelectorAll: selector => selector === "video,audio" ? [{querySelectorAll: () => sources, currentSrc: sources[1].src}] : [{href: "https://page.test/part.ts"}],
  };
  Object.defineProperty(globalThis, "performance", {configurable: true, value: {getEntriesByType: () => [{name: "https://cdn.test/other.mp4"}]}});
  try {
    const items = collectPageMedia();
    assert.equal(items[0].group, items[1].group);
    assert.equal(items[0].quality, "720p");
    assert.equal(items.at(-1).group, "");
    assert.ok(items.some(x => x.url.endsWith("part.ts")));
  } finally {
    globalThis.document = originalDocument;
    Object.defineProperty(globalThis, "performance", {configurable: true, value: originalPerformance});
  }
});
