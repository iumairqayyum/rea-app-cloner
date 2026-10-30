# Neat Download Manager: evidence ledger for Project 01

This is a bounded static investigation of **both** user-supplied attachments,
not a claim of complete reverse engineering or observed macOS execution.
All target content was treated as untrusted data, not instructions. No target
binary, installer, extension script or copied bootstrap was executed. NeatClone
uses original source and assets, not the extracted implementation.

## Artifacts and identity

| Supplied file | Size | SHA-256 |
| --- | ---: | --- |
| `NeatDMInstaller.dmg` | 1,468,544 | `c0e301ee4b13504a76eb6c54846c9dcf6d8148d32489b4bb91bd2062d471ef81` |
| `cpcifbdmkopohnnofedkjghjiclmhdah-1.9.92-Crx4Chrome.com.crx` | 36,607 | `d5899599fe47e08e536a234903ac040887bfa2f370ca9a78cfbe60adb5cbbca7` |

These hashes identify the received bytes. They do **not** authenticate the vendor
or establish that this third-party CRX download is identical to the Chrome Store
release. CRX3 signature / Chrome Store identity and macOS code-signature trust
were not verified. ZIP CRCs and DMG extraction checks establish readable content,
not publisher trust. Attachments, target scripts and proprietary assets are not
committed to this repository.

The DMG was listed and extracted using Debian 7-Zip 25.01's DMG/APFS support;
extraction reported `Everything is Ok`, 71 files and 19 directories. It was not
mounted or installed. CRX3 framing was checked (`Cr24`, version 3, 1,310-byte
header), then its embedded ZIP was extracted with traversal/symlink checks.
The CRX has 11 entries, including `bg.js`, `ct.js`, `manifest.json`, icons and
Chrome metadata. ZIP extraction verified member CRCs.

## Publicly documented behavior (claims, not runtime tests)

Source: [official product page](https://www.neatdownloadmanager.com/index.php/en/),
retrieved 30 October 2026. It advertises dynamic segmentation, pause/resume and
crash recovery, status/type organization, HTTP/HTTPS/FTP, proxy/authentication,
bandwidth/connection controls, browser video/audio capture and expired-download
renewal. It explicitly describes HLS as downloading TS files and merging into a
single **TS** file; it does not establish MP4 remuxing or equivalent-MP4 priority.
The page labels the Mac download 1.3 and the Windows version 1.4. Marketing
statements such as acceleration are not validated performance results here.

## Confirmed DMG static facts

`NeatDownloadManager.app/Contents/Info.plist`, parsed as inert plist data:
bundle identifier `com.NeatDownloadManager`, version **1.3**, build **24**, minimum
system **10.10**, AppKit principal class `NSApplication`, main nib
`NeatMainWindow`, `LSUIElement=true`. Resources include compiled nibs, `Assets.car`,
icons and `Resources/NeatDB.db`. A packaged Safari app extension and its own
JavaScript resources are also present; these are not the same release as the
separate supplied Chrome CRX.

The main executable is a universal Mach-O with x86_64 and arm64 slices. Its
SHA-256 is `82ac9da838a633a187029aef14cef45f5bd8a9b8914ad2d0ccea5205c47641a9`.
Load commands link Foundation, AppKit, SQLite, Objective-C, libc++, libSystem,
ApplicationServices, CoreFoundation, CoreServices, IOKit and Security. This
establishes linked dependencies, not which API implements a particular transfer.
No separate dynamic libcurl dependency appeared in those load commands; static
linking or other networking implementations remain possible.

Readable native strings/type encodings include `NeatDownloadEngine`,
`NeatSegmentManager`, segment rollback/merge diagnostics, `Content-Range`,
`HTTP/1.1 101 Switching Protocols` and `neatextension.v1`. These support the
**inference** of a native segmented engine with a WebSocket endpoint; they do
not reveal its algorithms, synchronization correctness, retry rules or actual
runtime behavior. No decompiled functions or control-flow claims are made.

The bundled SQLite schema has `auths`, `headers`, `downloads` and the internal
`sqlite_sequence`. Download columns include URL, method, file name, category,
status, bandwidth limit, connections, resumability, MIME type, error, page
metadata, post data and destination folder. Schema presence does not demonstrate
actual persisted data handling or encryption. Only schema was requested.

## Confirmed Chrome CRX facts (version 1.9.92)

References below use original extracted file line numbers; source is minified.

| Question | Static evidence and boundary |
| --- | --- |
| Architecture | `manifest.json`: Manifest V3, `bg.js` service worker; `ct.js` injected into HTTP(S) pages, all frames at document start. |
| Permissions | `webRequest`, `webNavigation`, `cookies`, `contextMenus`, `storage`, `downloads`; static host permission `<all_urls>`. No `nativeMessaging` permission. |
| Detection inputs | `bg.js:12–13,27–35`: request body/header observers, response MIME/filename/extension, status 200/206, content length/range, content disposition; recognizes video/audio and playlist types. |
| HLS | `bg.js:21–24`: inert parser checks `#EXTM3U`, `EXTINF`, `EXT-X-STREAM-INF`, `EXT-X-BYTERANGE`; resolves relative URLs, formats bandwidth/resolution labels, publishes HLS/TS entries. This is extension-side parsing, not proof of engine support for every HLS feature. |
| Segment filtering | `bg.js:2,31–32`: a TS/MPEGTS/MP2T/F4F pattern is excluded from an ordinary media-candidate branch. Does not establish universal segment filtering. |
| Progressive MP4 | `bg.js:31` reads Vimeo `request.files.progressive`; `ct.js:18–19` scans inline progressive arrays on Vimeo pages. `ct.js:16–17` has Facebook SD/HD source patterns. Static site-specific logic may be obsolete. |
| Selection UI | `ct.js:19–27` associates candidates with DOM video/audio/object/embed elements and floating panels. Association includes heuristics; no general proof of equivalence or MP4-over-HLS policy. |
| Desktop transport | `bg.js:18`: `ws://127.0.0.1:10007/download`, WebSocket subprotocol `neatextension.v1`. **Not Chrome native messaging.** |
| Payload | `bg.js:16–18`: CRLF-delimited numbered fields, including `1` method, `2` URL, `6` mode (`normal`, `media`, `hls`); optional numbered metadata and Origin/Referer/Cookie/Content-Type/Disposition/x-* fields. POST may carry `__0NeatPostData9__`. It refuses a string longer than 118,784 characters. Exact server interpretation beyond sender assignments is unknown. |
| Desktop replies | `bg.js:19`: recognizes `waiting`, `nowaiting`, and `ShowPanelChrome=...`; uses waiting status to decide whether a HEAD metadata probe is needed. Does not prove complete duplex protocol. |
| Cookies/interception | `bg.js:20,33,38–39` gathers cookies for handoff; `bg.js:15` can cancel/erase a matching Chrome download after interception. NeatClone deliberately does neither. |

## REA 6.8.0 execution evidence

The existing installation was reused without reinstalling it. CLI fallback was
used because this chat does not advertise direct REA tools.

- `analyze-javascript-application /tmp/neat-analysis/crx --json`: **passed**,
  Evidence `ev_844d25f337bd67cbc25ca39f92c973a2b27eefef61bf57b490c1e6b0cd8bd058`,
  36 graph nodes. REA parsed target code inertly. It explicitly reports incomplete
  graph coverage and a 512-state alias expansion bound; dynamic/obfuscated
  relationships remain unknown. Findings above combine REA with direct text
  inspection; they are not claims that REA recovered every semantic path.
- `inspect-desktop-application ... --detail summary --evidence_output ...`:
  **passed**; parent Evidence
  `ev_8b66b645bcb8005cc27fc9fa254c203e23b1a9ba8a5e31c36093d4f74ac1aec5`,
  summary `ev_b239af4650ddfed97c3eb70fc4f8bdf02ecbfb4c99b44cfbaa20b5124beb364a`.
  It examined 81 entries, probed 20 files / 1,304 bytes, and reported no runtime
  candidates. That bounded header scan does not imply absence of native code:
  the executable was separately identified above. Its directory digest commits
  to observed metadata/read ranges, not every file's content. Complete source
  Evidence was exported locally. This route does not decompile procedures.
- `inspect-sqlite-database ... --schema-scope database --json`: **passed**,
  Evidence `ev_61e4e5c31f51e91eb3faaf4443b94fe1128f5a14f31af90407faca68f1bee22b`.
- `inspect-plist ... --json`: **unavailable on this Linux host**. Plain bundle
  metadata was independently parsed with Python `plistlib`; no macOS tooling
  result is claimed.

Native macOS execution, GUI behavior, Safari integration, real Chrome-to-NDM
WebSocket exchange, native decompilation, publisher trust and end-to-end NDM
download behavior are **unverified**. Linux can inspect Mach-O headers and
strings; no Ghidra/Hopper/IDA/Kuna provider is configured for deeper analysis.

## Artifacts needed for the next investigation

Already obtained: Mac bundle/executables/resources and a separate Chrome CRX.
For deeper engine/control-flow claims: a supported configured disassembler and
the chosen architecture slice, plus a Mac for reproducible runtime traces. For
actual transport details and selection fidelity: a user-authorized Mac/Chrome
session, matching contemporaneous app/extension versions, sanitized WebSocket
captures, and controlled HTTP/HLS fixtures with known video identity/quality.
For real website behavior: explicit access to that site and permitted assets;
no authentication, licensing or DRM bypass is part of this project.

## Independent design decisions

NeatClone uses Swift/AppKit + URLSession, a durable serial queue, validated HTTP
Range/If-Range recovery, and caller-installed FFmpeg for unencrypted VOD HLS
remuxing. Its MV3 extension requires explicit site approval and user handoff,
uses Chrome native messaging with an exact extension-origin allowlist, and sends
no cookies or captured authentication headers. A direct MP4 is preferred only
within an explicitly shared media group with equal known quality; unrelated
URLs and unknown quality are not assumed equivalent. A TS segment is never
represented as a complete video. These are original product choices, not
recovered NDM internals. Broader dynamic segmentation, FTP/proxies, renewal and
site-specific extraction are outside the first vertical slice.
