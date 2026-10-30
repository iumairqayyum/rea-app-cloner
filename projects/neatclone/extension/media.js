// Independent implementation. No target extension code is used here.
export const HOST = "com.neatclone.bridge";
export function httpURL(value) {
  if (typeof value !== "string" || value.length > 8192 || /[\x00-\x1f\x7f]/.test(value)) throw new Error("Invalid URL");
  const url = new URL(value);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new Error("Only HTTP(S) URLs without embedded credentials are supported");
  }
  url.hash = "";
  return url;
}
export function sitePattern(value) {
  const url = httpURL(value);
  // Chrome host match patterns cannot restrict ports. Retain the exact scheme
  // and hostname; never widen a grant to subdomains or the other scheme.
  return `${url.protocol}//${url.hostname}/*`;
}
export function classify(url, type = "") {
  const pathname = httpURL(url).pathname.toLowerCase();
  type = type.split(";", 1)[0].trim().toLowerCase();
  if (/\.(ts|m2ts)$/.test(pathname) || type === "video/mp2t") return "segment";
  if (/\.m3u8$/.test(pathname) || ["application/vnd.apple.mpegurl", "application/x-mpegurl"].includes(type)) return "hls";
  if (/\.(mp4|m4v)$/.test(pathname) || type === "video/mp4") return "direct";
  return null;
}
export function normalize(raw, id) {
  const url = httpURL(raw.url).href;
  const kind = classify(url, raw.type);
  if (!kind) return null;
  const group = typeof raw.group === "string" ? raw.group.slice(0, 200) : "";
  const quality = /^\d{2,4}p?$/.test(String(raw.quality || "")) ? String(raw.quality).replace(/p$/, "") : "";
  return {id, url, kind, group, quality, source: String(raw.source || "page").slice(0, 40)};
}
// Substitution requires evidence for both identity AND quality. Sharing a page,
// hostname or filename alone never establishes that two URLs are equivalent.
export function preferEquivalent(candidates, chosen) {
  if (chosen.kind !== "hls" || !chosen.group || !chosen.quality) return chosen;
  return candidates.find(x => x.kind === "direct" && x.group === chosen.group && x.quality === chosen.quality) || chosen;
}
export function displayURL(value) {
  const url = httpURL(value);
  return url.host + url.pathname; // Never display query tokens or credentials.
}

// This function is injected only after a popup action grants site permission.
// It is self-contained because Chrome serializes the function for executeScript.
export function collectPageMedia() {
  const found = [];
  const add = (url, type, group, quality, source) => {
    try {
      const parsed = new URL(url, document.baseURI);
      if (["http:", "https:"].includes(parsed.protocol)) found.push({url: parsed.href, type, group, quality, source});
    } catch { /* Malformed target data is ignored, never executed. */ }
  };
  document.querySelectorAll("video,audio").forEach((element, index) => {
    const group = `element:${index}`;
    const sources = [...element.querySelectorAll("source")];
    for (const source of sources) {
      add(source.src, source.type, group, source.dataset.quality || source.dataset.height || "", "media source");
    }
    if (element.currentSrc || element.src) {
      const current = element.currentSrc || element.src;
      const matching = sources.find(x => x.src === current);
      add(current, matching?.type || "", group, matching?.dataset.quality || matching?.dataset.height || "", "media element");
    }
  });
  document.querySelectorAll("a[href]").forEach((link, index) => add(link.href, link.type || "", `link:${index}`, "", "page link"));
  for (const resource of performance.getEntriesByType("resource")) add(resource.name, "", "", "", "resource timing");
  return found.slice(0, 2000);
}
