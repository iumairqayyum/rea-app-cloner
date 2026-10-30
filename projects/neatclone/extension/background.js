import {HOST, httpURL, sitePattern, normalize, preferEquivalent, collectPageMedia} from "./media.js";

export function createController(chromeAPI) {
  const tabs = new Map();
  const nextID = () => globalThis.crypto.randomUUID();
  const authorized = async url => chromeAPI.permissions.contains({origins: [sitePattern(url)]});
  async function scan(tabID) {
    const tab = await chromeAPI.tabs.get(tabID);
    const page = httpURL(tab.url);
    if (!await authorized(page.href)) throw new Error("Authorize this site before scanning");
    const results = await chromeAPI.scripting.executeScript({target: {tabId: tabID}, func: collectPageMedia});
    const state = {pageURL: page.href, candidates: [], observed: new Set()};
    function add(raw) {
      try {
        const item = normalize(raw, nextID());
        if (item && !state.candidates.some(x => x.url === item.url)) state.candidates.push(item);
      } catch { /* Ignore untrusted/malformed target data. */ }
    }
    for (const result of results) for (const raw of result.result || []) add(raw);
    state.candidates = state.candidates.slice(0, 200);
    tabs.set(tabID, state);
    return {ok: true, candidates: state.candidates};
  }
  async function observe(details) {
    const state = tabs.get(details.tabId);
    if (!state || state.candidates.length >= 200 || !await authorized(details.url)) return;
    // Only watch the currently approved page. Navigation requires a new scan.
    const tab = await chromeAPI.tabs.get(details.tabId);
    if (tab.url !== state.pageURL) { tabs.delete(details.tabId); return; }
    const type = details.responseHeaders?.find(x => x.name.toLowerCase() === "content-type")?.value || "";
    try {
      const candidate = normalize({url: details.url, type, source: "observed response"}, nextID());
      if (candidate && !state.candidates.some(x => x.url === candidate.url)) state.candidates.push(candidate);
    } catch { /* No response bodies or credential headers are collected. */ }
  }
  async function send(tabID, candidateID) {
    const state = tabs.get(tabID);
    if (!state) throw new Error("Scan the page again");
    const tab = await chromeAPI.tabs.get(tabID);
    if (tab.url !== state.pageURL || !await authorized(state.pageURL)) throw new Error("Page changed or permission was removed; scan again");
    const selected = state.candidates.find(x => x.id === candidateID);
    if (!selected || selected.kind === "segment") throw new Error("Select a complete MP4 or HLS playlist, not a TS segment");
    const chosen = preferEquivalent(state.candidates, selected);
    const url = httpURL(chosen.url);
    if (!await authorized(url.href)) throw new Error("Authorize the media URL's site before sending");
    const message = {version: 1, action: "enqueue", url: url.href, kind: chosen.kind, pageURL: state.pageURL};
    const reply = await chromeAPI.runtime.sendNativeMessage(HOST, message);
    if (!reply || reply.ok !== true || typeof reply.id !== "string") throw new Error("Native host did not acknowledge the download");
    return {ok: true, id: reply.id, usedDirectMP4: chosen.id !== selected.id};
  }
  async function handle(message, sender) {
    if (sender.id !== chromeAPI.runtime.id || sender.url !== chromeAPI.runtime.getURL("popup.html")) {
      return {ok: false, error: "Only the extension popup can request a download"};
    }
    try {
      if (!Number.isInteger(message.tabID) || message.tabID < 0) throw new Error("Invalid tab");
      if (message.action === "scan") return await scan(message.tabID);
      if (message.action === "list") return {ok: true, candidates: tabs.get(message.tabID)?.candidates || []};
      if (message.action === "send") return await send(message.tabID, message.candidateID);
      throw new Error("Unsupported action");
    } catch {
      // Avoid echoing native-host errors or target URLs, which can contain tokens.
      return {ok: false, error: "Request failed. Check site permission, scan again, and ensure the NeatClone native host is installed. Protected URLs may require authorization not available to the app."};
    }
  }
  return {handle, observe, forget: tabID => tabs.delete(tabID)};
}

if (globalThis.chrome?.runtime?.onMessage) {
  const controller = createController(chrome);
  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    controller.handle(message, sender).then(respond);
    return true;
  });
  chrome.webRequest.onHeadersReceived.addListener(details => {
    controller.observe(details).catch(() => {});
  }, {urls: ["http://*/*", "https://*/*"]}, ["responseHeaders"]);
  chrome.tabs.onRemoved.addListener(controller.forget);
  chrome.tabs.onUpdated.addListener((id, change) => { if (change.url) controller.forget(id); });
}
