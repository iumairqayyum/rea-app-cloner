import {httpURL, sitePattern, displayURL} from "./media.js";
const status = document.getElementById("status");
let activeTab;
async function tab() {
  [activeTab] = await chrome.tabs.query({active: true, currentWindow: true});
  httpURL(activeTab?.url);
  return activeTab;
}
async function request(action, extra = {}) {
  const current = await tab();
  return chrome.runtime.sendMessage({action, tabID: current.id, ...extra});
}
function render(candidates) {
  const list = document.getElementById("candidates");
  list.replaceChildren();
  for (const candidate of candidates) {
    const row = document.createElement("li");
    const label = document.createElement("span");
    label.textContent = `${candidate.kind.toUpperCase()} ${candidate.quality ? candidate.quality + "p" : "(quality unknown)"} · ${displayURL(candidate.url)}`;
    row.append(label);
    const button = document.createElement("button");
    button.textContent = candidate.kind === "segment" ? "Segment only — choose its playlist" : "Send to NeatClone";
    button.disabled = candidate.kind === "segment";
    button.addEventListener("click", async () => {
      button.disabled = true;
      try {
        if (!await chrome.permissions.request({origins: [sitePattern(candidate.url)]})) throw new Error("permission");
        const reply = await request("send", {candidateID: candidate.id});
        if (!reply.ok) throw new Error("native");
        status.textContent = reply.usedDirectMP4 ? "Queued an equivalent direct MP4 in NeatClone." : "Download queued in NeatClone.";
      } catch { status.textContent = "Not sent. Authorize the media site and install the NeatClone native messaging host. No browser credentials are transferred."; }
      button.disabled = false;
    });
    row.append(button);
    list.append(row);
  }
}
document.getElementById("scan").addEventListener("click", async () => {
  try {
    const current = await tab();
    if (!await chrome.permissions.request({origins: [sitePattern(current.url)]})) {
      status.textContent = "Site permission was not granted."; return;
    }
    const reply = await request("scan");
    if (!reply.ok) throw new Error("scan");
    render(reply.candidates);
    status.textContent = `${reply.candidates.length} candidates. Start playback and refresh for newly observed responses.`;
  } catch { status.textContent = "Cannot scan this page. Use an HTTP(S) page and enable permission for this site."; }
});
document.getElementById("refresh").addEventListener("click", async () => {
  try {
    const reply = await request("list");
    render(reply.candidates || []);
    status.textContent = `${reply.candidates?.length || 0} candidates. Cross-site media needs its own permission before sending.`;
  } catch { status.textContent = "Scan a supported page first."; }
});

async function showSettings() {
  const reply = await chrome.runtime.sendMessage({action: 'settings'});
  if (!reply?.ok) return;
  document.getElementById('extensions').value = reply.settings.extensions.join(',');
  document.getElementById('minimum').value = reply.settings.minimumMB;
  const current = await tab();
  const enabled = reply.settings.interceptionSites.includes(sitePattern(current.url));
  document.getElementById('enableInterception').disabled = enabled;
  document.getElementById('disableInterception').disabled = !enabled;
}
document.getElementById('saveSettings').addEventListener('click', async () => {
  try {
    const reply = await chrome.runtime.sendMessage({action: 'saveSettings', extensions: document.getElementById('extensions').value.split(/[\s,;]+/), minimumMB: Number(document.getElementById('minimum').value)});
    status.textContent = reply?.ok ? 'Filters saved. Unknown/small resources are not intercepted.' : 'Could not save filters.';
    await showSettings();
  } catch {status.textContent = 'Could not save settings.';}
});
for (const [id, enabled] of [['enableInterception', true], ['disableInterception', false]]) {
  document.getElementById(id).addEventListener('click', async () => {
    try {
      const current = await tab();
      if (enabled && !await chrome.permissions.request({origins: [sitePattern(current.url)]})) throw new Error('denied');
      const reply = await request('interception', {enabled});
      status.textContent = reply?.ok ? (enabled ? 'Interception enabled for this site only.' : 'Interception disabled for this site.') : 'Could not change interception.';
      await showSettings();
    } catch {status.textContent = 'Authorize an HTTP(S) site before enabling interception.';}
  });
}
document.getElementById('floating').addEventListener('click', async () => {
  try {
    const reply = await request('floating');
    status.textContent = reply?.ok ? 'Floating control installed for discovered HTML5 media.' : 'Enable this site and scan first.';
  } catch {status.textContent = 'Enable this site and scan first.';}
});
showSettings().catch(() => {});
