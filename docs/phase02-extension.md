# Phase 02 workstream C — Chrome integration

Implemented in the original MV3 extension; no target code/assets were copied and
no completed REA research or dependency installation was repeated.

## Functional changes

- A popup settings panel persists a case-insensitive extension allowlist (default
  ZIP, RAR, EXE, DMG, MP4, MKV, ISO) and minimum size (default **1 MiB**).
  Interception is **off for every site by default**. Enable it explicitly for the
  current exact scheme+hostname after granting Chrome's optional host permission.
  Chrome match patterns cover all ports for that host; no wildcard site consent
  is accepted. Disabling a site removes its interception setting.
- `chrome.downloads` observes user/browser-created downloads. A known positive
  full size meeting the configured threshold, approved source page/referrer,
  permitted target origin, allowed suffix, and corroborating MIME are required.
  Generic binary types require an explicit safe `Content-Disposition: attachment`
  filename. HTML/JSON, unsafe names, mismatched metadata, unknown lengths, small
  resources and TS segments are left with Chrome. RFC5987 UTF-8 names are parsed;
  malformed encodings and path/control characters are refused.
- This is MV3-compatible **handoff after download creation**, not blocking
  `webRequest`. Eligible browser downloads are paused; the extension verifies
  they remain in-progress and paused, sends the existing bounded native request,
  and cancels the browser copy only after the compiled native host acknowledges
  a durable receipt. A host rejection/error or browser race resumes the browser
  copy where possible. No download history is erased. An ambiguous native error
  after receipt creation can result in duplicate work; there is no distributed
  exactly-once guarantee or automatic resend.
- Native acknowledgement is receipt acceptance, **not completed download**. The
  application may still report authorization, disk or network failure. Browser
  cookies, passwords, arbitrary headers and request bodies are not transferred.
- A **Send link to NeatClone** context menu explicitly hands off approved HTTP(S)
  link/video/audio URLs. It requests the specific page and media host permissions
  from that browser user action; denial leaves the browser untouched. Context-menu
  failure does not suppress the browser's normal action. TS links are refused.
- Explicit per-site media scanning and response-MIME observation remain, including
  actual source qualities only. A **Show floating media control** popup action
  installs an isolated-world control for already-discovered HTML5 media sources.
  It lists only observed candidates, rejects synthetic clicks, and uses cached
  candidate IDs. Content requests must be from this extension's main-frame
  approved content world and the unchanged scanned page. Unknown IDs, iframes,
  unrelated pages and native commands other than enqueue cannot be sent.
- Direct MP4 substitution still requires the same DOM media group and identical
  explicit quality. No universal video extraction, guessed quality, DRM bypass,
  or TS-as-full-video behavior was added. A service-worker restart loses transient
  signed URL caches; scan again. Settings contain filter/site patterns, not URLs,
  cookies or signed query tokens.

## Browser/security boundaries

The manifest adds `downloads`, `storage` and `contextMenus` to the existing
`activeTab`, `scripting`, `nativeMessaging` and `webRequest` permissions. There
is still **no static host permission**, installed content script, cookie/debugger
permission or `webRequestBlocking`. Host approval remains per site.

No Option/Ctrl-click modifier is invented: Chrome's downloads API does not expose
those key states, so there is no reliable modifier bypass for automatic handoff.
Use the explicit context menu, normal popup, or disable interception for that
site. Safari Web Extensions and Orion are **unsupported/unverified**, not Chrome
adapters relabeled as compatible. macOS host registration and signing remain the
application's documented build/installer responsibility, with one exact extension
ID allowed in the host manifest. Moving the app requires re-registration.

## Measured verification

`npm test --prefix projects/neatclone/extension`: **20 executed, 20 passed,
0 failures, 0 skipped**. Tests include prior media/bridge tests plus filter and
RFC5987 validation, host acknowledgement/cancel ordering, pause failure/completion
races, site consent, unknown-size refusal, forged floating sender/ID refusal,
context-menu handoff and popup-only settings mutations. These are real controller
calls with mocked Chrome APIs, not proof that Chrome loaded the extension.

`node projects/neatclone/extension/tests/chromium-smoke.mjs`: **blocked, exit 2**.
Managed Chromium policy in this Cloud instance denies new extensions. No policy
was changed. Actual browser event ordering, floating-control visuals, permission
prompts and end-to-end Chrome-to-macOS execution remain for a permitted Mac test.
