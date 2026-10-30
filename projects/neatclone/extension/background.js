import {cleanSettings, eligibleDownload} from "./interception.js";
import {floatingMediaControls} from "./floating.js";
import {HOST, httpURL, sitePattern, normalize, preferEquivalent, collectPageMedia} from "./media.js";

export function createController(chromeAPI) {
  const tabs = new Map(), responses = new Map(), catching = new Set();
  const settings = async () => cleanSettings((await chromeAPI.storage?.local.get('settings'))?.settings);
  const saveSettings = async value => {const clean = cleanSettings(value); await chromeAPI.storage.local.set({settings: clean}); return clean;};
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
    if (details.statusCode === 200 || details.statusCode === 206) {
      try {
        if (await authorized(details.url)) {
          const header = name => details.responseHeaders?.find(x => x.name.toLowerCase() === name)?.value;
          const length = header('content-length');
          // Do not infer complete resource size from a partial response length.
          if (details.statusCode === 200 && /^\d+$/.test(length || '')) {
            responses.set(httpURL(details.url).href, {size: Number(length), type: header('content-type'), disposition: header('content-disposition'), at: Date.now()});
            if (responses.size > 500) responses.delete(responses.keys().next().value);
          }
        }
      } catch { /* Unapproved or invalid response is ignored. */ }
    }
    const state = tabs.get(details.tabId);
    if (!state || state.candidates.length >= 200 || !await authorized(details.url)) return;
    // Only watch the currently approved page. Navigation requires a new scan.
    const tab = await chromeAPI.tabs.get(details.tabId);
    if (httpURL(tab.url).href !== state.pageURL) { tabs.delete(details.tabId); return; }
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
    if (httpURL(tab.url).href !== state.pageURL || !await authorized(state.pageURL)) throw new Error("Page changed or permission was removed; scan again");
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
  async function intercept(item) {
    if (catching.has(item.id) || item.state !== 'in_progress' || item.paused) return false;
    let paused = false;
    catching.add(item.id);
    try {
      const config = await settings();
      const metadata = responses.get(httpURL(item.finalUrl || item.url).href);
      const fresh = metadata && Date.now() - metadata.at < 120000 ? metadata : undefined;
      const candidate = eligibleDownload(item, fresh, config);
      if (!candidate || !await authorized(candidate.url) || !await authorized(candidate.pageURL)) return false;
      // Pause before handoff, so an acknowledged native request cannot cause us
      // to discard a browser transfer that completed while the host was waking.
      await chromeAPI.downloads.pause(item.id); paused = true;
      const [current] = await chromeAPI.downloads.search({id: item.id});
      if (!current || current.state !== 'in_progress' || !current.paused) return false;
      const reply = await chromeAPI.runtime.sendNativeMessage(HOST, {version: 1, action: 'enqueue', ...candidate});
      if (!reply?.ok || typeof reply.id !== 'string') return false;
      await chromeAPI.downloads.cancel(item.id);
      paused = false;
      return true;
    } catch {return false;}
    finally {
      if (paused) {try {await chromeAPI.downloads.resume(item.id);} catch { /* Browser may have already completed/cancelled it. */ }}
      catching.delete(item.id);
    }
  }
  async function contextDownload(info, tab) {
    try {
      const url = httpURL(info.linkUrl || info.srcUrl), page = httpURL(info.pageUrl || tab?.url);
      if (classifyContext(url) === 'segment') return false;
      if (!await authorized(page.href) || !await authorized(url.href)) return false;
      const reply = await chromeAPI.runtime.sendNativeMessage(HOST, {version: 1, action: 'enqueue', url: url.href, kind: /\.m3u8$/i.test(url.pathname) ? 'hls' : 'direct', pageURL: page.href});
      return reply?.ok === true;
    } catch {return false;}
  }
  function classifyContext(url) {return /\.(ts|m2ts)$/i.test(url.pathname) ? 'segment' : 'direct';}
  async function handle(message, sender) {
    if (message?.action === 'floatingSend') {
      try {
        if (sender.id !== chromeAPI.runtime.id || sender.frameId !== 0 || !sender.tab || httpURL(sender.url).href !== tabs.get(sender.tab.id)?.pageURL) return {ok: false};
        return await send(sender.tab.id, message.candidateID);
      } catch {return {ok: false};}
    }
    if (sender.id !== chromeAPI.runtime.id || sender.url !== chromeAPI.runtime.getURL("popup.html")) {
      return {ok: false, error: "Only the extension popup can request a download"};
    }
    try {
      if (message.action === 'settings') return {ok: true, settings: await settings()};
      if (message.action === 'saveSettings') {
        const previous = await settings();
        return {ok: true, settings: await saveSettings({...previous, extensions: message.extensions, minimumMB: message.minimumMB})};
      }
      if (!Number.isInteger(message.tabID) || message.tabID < 0) throw new Error("Invalid tab");
      if (message.action === 'interception') {
        const tab = await chromeAPI.tabs.get(message.tabID), pattern = sitePattern(tab.url);
        if (!await authorized(tab.url)) throw new Error('Site permission required');
        const previous = await settings();
        previous.interceptionSites = previous.interceptionSites.filter(x => x !== pattern);
        if (message.enabled === true) previous.interceptionSites.push(pattern);
        return {ok: true, settings: await saveSettings(previous)};
      }
      if (message.action === 'floating') {
        const tab = await chromeAPI.tabs.get(message.tabID), state = tabs.get(message.tabID);
        if (!state || state.pageURL !== httpURL(tab.url).href || !await authorized(tab.url)) throw new Error('Scan first');
        await chromeAPI.scripting.executeScript({target: {tabId: message.tabID}, func: floatingMediaControls, args: [state.candidates.filter(x => x.kind !== 'segment' && x.group.startsWith('element:')).map(({id,kind,quality,source}) => ({id,kind,quality,source}))]});
        return {ok: true};
      }
      if (message.action === "scan") return await scan(message.tabID);
      if (message.action === "list") return {ok: true, candidates: tabs.get(message.tabID)?.candidates || []};
      if (message.action === "send") return await send(message.tabID, message.candidateID);
      throw new Error("Unsupported action");
    } catch {
      // Avoid echoing native-host errors or target URLs, which can contain tokens.
      return {ok: false, error: "Request failed. Check site permission, scan again, and ensure the NeatClone native host is installed. Protected URLs may require authorization not available to the app."};
    }
  }
  return {handle, observe, intercept, contextDownload, forget: tabID => tabs.delete(tabID)};
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
  chrome.downloads?.onCreated.addListener(item => {controller.intercept(item).catch(() => {});});
  chrome.downloads?.onChanged.addListener(async change => {
    if (!change.totalBytes && !change.mime && !change.filename) return;
    try {const [item] = await chrome.downloads.search({id: change.id}); if (item) await controller.intercept(item);} catch {}
  });
  chrome.runtime.onInstalled?.addListener(() => {
    chrome.contextMenus.create({id: 'neatclone-send', title: 'Send link to NeatClone', contexts: ['link', 'video', 'audio']});
  });
  chrome.contextMenus?.onClicked.addListener(async (info, tab) => {
    if (info.menuItemId !== 'neatclone-send') return;
    try {
      const origins = [...new Set([sitePattern(info.pageUrl || tab?.url), sitePattern(info.linkUrl || info.srcUrl)])];
      if (await chrome.permissions.request({origins})) await controller.contextDownload(info, tab);
    } catch { /* Permission denial leaves the browser untouched. */ }
  });
  chrome.tabs.onRemoved.addListener(controller.forget);
  chrome.tabs.onUpdated.addListener((id, change) => { if (change.url) controller.forget(id); });
}
