# NeatClone Chrome extension

This is original Manifest V3 code, not a modified copy of the supplied Neat
extension. It uses Chrome native messaging (`com.neatclone.bridge`), not the
original application's localhost WebSocket protocol.

Load this directory with **chrome://extensions → Developer mode → Load unpacked**.
Install the macOS native host using the app's installation instructions and this
extension's displayed ID. Chrome's host manifest must allow exactly
`chrome-extension://YOUR_EXTENSION_ID/`; do not use a wildcard. The service worker
accepts handoff commands only from this extension's popup, never a web page.

On an authorized HTTP(S) page, open the popup and choose **Enable this site &
scan**. Permission is requested for that site's exact scheme and hostname, not
every site on install. Chrome host permission patterns cover all ports on that
host; they cannot restrict an individual port. Subdomains and the other scheme
are not included in the grant.
The scan reads main-frame media elements, source elements, links, and resource
timing entries. After scanning, playing media can add MIME-identified response
URLs observed by `webRequest` on already permitted origins; reopen the popup and
choose **Refresh observed media**. A service-worker restart loses this ephemeral
list; scan again. Navigation clears candidates.

Choose **Send to NeatClone** next to the wanted media. Cross-origin media requires
an additional permission prompt for its origin. Only HTTP(S) URLs are passed, not
cookies, arbitrary headers, response bodies, or embedded credentials. The app may
therefore receive a genuine authorization error for a protected URL; the extension
does not work around that. Query tokens needed for a URL are transferred but not
logged or shown in popup labels. URLs are not persisted in extension storage.

Direct MP4 substitution occurs only for sources of the same media element with
the same explicit `data-quality` or `data-height` value. Without that evidence,
the user chooses; no equivalence is guessed from a shared page or CDN. TS responses
are labeled as segments and cannot be queued as complete videos. HLS requires an
unencrypted playlist supported by the app. DRM is unsupported.

Known limits: main-frame scan only, no cross-frame DOM traversal, no arbitrary
site/player-specific extraction, no blob/MediaSource reconstruction, no automatic
download interception, and no cookie/session transfer. MIME observation of a CDN
requires that CDN to have been granted permission separately. These are deliberate
limits, not claims of parity with the original extension.

Run dependency-free tests with `npm test` in this directory using Node.js 22.8+
(or `node tests/extension.test.js`). In-process test isolation also makes the
individual test counts visible in restrictive Cloud subprocess sandboxes.
Tests exercise selection/URL validation, actual
background-controller scan and handoff with mocked Chrome APIs, permission
failures, stale navigation, TS refusal, native-host errors, response observation,
and injected DOM collection. A real Chrome-to-macOS app handoff remains a separate
acceptance check; mocked API tests do not establish it.

An additional browser smoke test is available with
`node tests/chromium-smoke.mjs`. It launches only this extension in a temporary
headless Chromium profile, checks worker imports, runtime errors, and installed
permissions. On a compatible Linux host, `--with-native-fixture` additionally
tests real Chrome native messaging against a temporary synthetic Python host;
it refuses to overwrite an existing `com.neatclone.bridge` manifest and cleans up
its own fixture. This proves browser transport only, not macOS application
execution. Node.js 22+ with built-in WebSocket and Chromium are needed.

In the current Codex Cloud machine, actual unpacked-extension loading is blocked
by managed Chromium `ExtensionInstallBlocklist: ["*"]`. The smoke script reports
that blocker and exits 2 without trying to bypass policy. Initial browser load
attempts did not register the extension; native messaging with the real browser
therefore remains unverified. The 10 Node tests pass independently. macOS Chrome
installation and handoff must be checked on a machine whose policy permits it.
