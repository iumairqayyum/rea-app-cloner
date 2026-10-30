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
