import {httpURL, sitePattern} from './media.js';

export const DEFAULT_SETTINGS = Object.freeze({extensions: ['ZIP', 'RAR', 'EXE', 'DMG', 'MP4', 'MKV', 'ISO'], minimumMB: 1, interceptionSites: []});
const MIME = {
  ZIP: ['application/zip','application/x-zip-compressed'], RAR: ['application/vnd.rar','application/x-rar-compressed'],
  EXE: ['application/vnd.microsoft.portable-executable','application/x-msdownload'],
  '7Z': ['application/x-7z-compressed'], TAR: ['application/x-tar'], GZ: ['application/gzip','application/x-gzip'], PDF: ['application/pdf'],
  DMG: ['application/x-apple-diskimage'], MP4: ['video/mp4'], MKV: ['video/x-matroska'], ISO: ['application/x-iso9660-image'],
};
const GENERIC = ['application/octet-stream','binary/octet-stream','application/download','application/force-download'];
export function cleanSettings(raw = {}) {
  const list = Array.isArray(raw.extensions) ? raw.extensions : DEFAULT_SETTINGS.extensions;
  const extensions = [...new Set(list.map(x => String(x).trim().replace(/^\./,'').toUpperCase()).filter(x => /^[A-Z0-9]{1,10}$/.test(x)))].slice(0,64);
  const minimumMB = Number.isFinite(raw.minimumMB) ? Math.min(10240, Math.max(0, raw.minimumMB)) : 1;
  const interceptionSites = Array.isArray(raw.interceptionSites) ? [...new Set(raw.interceptionSites.filter(x => {
    try {return typeof x === 'string' && !x.slice(0, -2).includes('*') && sitePattern(x.replace(/\/\*$/, '/')) === x;} catch {return false;}
  }))].slice(0,200) : [];
  return {extensions, minimumMB, interceptionSites};
}
export function dispositionFilename(value = '') {
  if (!value) return null;
  if (!/^attachment(?:\s*;|\s*$)/i.test(value)) throw new Error('Not an attachment');
  const encoded = /(?:^|;)\s*filename\*\s*=\s*UTF-8'[^']*'([^;]+)/i.exec(value);
  const normal = /(?:^|;)\s*filename\s*=\s*(?:"([^"\r\n]*)"|([^;\r\n]+))/i.exec(value);
  const name = encoded ? decodeURIComponent(encoded[1].trim()) : normal ? (normal[1] ?? normal[2]).trim() : null;
  if (name && (/[\\/:\x00-\x1f\x7f]/.test(name) || name === '.' || name === '..' || name.length > 180)) throw new Error('Unsafe filename');
  return name;
}
export function eligibleDownload(item, metadata, settings) {
  try {
    const url = httpURL(item.finalUrl || item.url);
    const page = httpURL(item.referrer);
    if (!settings.interceptionSites.includes(sitePattern(page.href))) return null;
    const size = item.totalBytes;
    if (metadata?.size != null && metadata.size !== size) return null;
    if (!Number.isSafeInteger(size) || size <= 0 || size < settings.minimumMB * 1024 * 1024) return null;
    const mime = String(metadata?.type || item.mime || '').split(';')[0].trim().toLowerCase();
    const disposition = metadata?.disposition || '';
    const supplied = dispositionFilename(disposition);
    const urlName = decodeURIComponent(url.pathname.split('/').pop() || '');
    const chromeName = String(item.filename || '').split(/[\\/]/).pop();
    const name = supplied || chromeName || urlName;
    if (!name || /[\\/:\x00-\x1f\x7f]/.test(name) || name.length > 180) return null;
    const ext = name.split('.').pop().toUpperCase();
    if (!settings.extensions.includes(ext) || ['TS','M2TS','M3U8'].includes(ext)) return null;
    // A known MIME must corroborate the suffix, or a generic binary attachment
    // must explicitly name it. HTML/JSON/errors cannot be caught as executables.
    if (!(MIME[ext]?.includes(mime) || (supplied && GENERIC.includes(mime)))) return null;
    const pathExt = urlName.includes('.') ? urlName.split('.').pop().toUpperCase() : null;
    if (pathExt && MIME[pathExt] && pathExt !== ext) return null;
    return {url: url.href, filename: name, pageURL: page.href, kind: 'direct'};
  } catch {return null;}
}
