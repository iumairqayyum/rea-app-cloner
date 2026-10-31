# NeatClone Phase 02 — integrated recovery report

Date: 31 October 2026. Requirements: [Issue #1](https://github.com/iumairqayyum/rea-app-cloner/issues/1).
This is an original developer build, not a claim of production parity with IDM
or Neat Download Manager. The existing REA analysis was reused; no dependencies
were reinstalled and no completed target research was repeated.

## Recovered work

The interrupted worktrees were inspected before editing. Existing changes were
preserved in `/workspace/recovery-phase02` archives and a binary patch. Four
isolated workstream branches were recovered, completed and merged without
overwriting each other's owned files:

| Stream | Recovered commit | Implemented behavior |
| --- | --- | --- |
| A — UI | `3425d8e` | Resizable AppKit toolbar and sortable/filterable grid, contextual queue actions, full-error and refresh-address sheets, persisted connection/rate preferences, standard responder-chain Edit commands and keyboard shortcuts. |
| B — engine | `0ac23b2` | Verified parallel HTTP ranges, sparse random-access file, bounded chunk work-sharing, atomic checkpoints and cached-range corruption checks, safe sequential fallback, checked address renewal, cancellable per-download/shared global rate limits. |
| C — browser | `1f435ad` | Explicit per-site MV3 interception, extension/size/MIME/disposition filters, pause-before-handoff and cancel-only-after-native-ack, resume on handoff failure, context menu and authorized floating HTML5 media controls. |
| D — platform | `3df452b` | Named queues and timezone-aware scheduling, migration of old queue state, Keychain-scoped HTTPS Basic credentials, opt-in completion/failure notifications, menu-bar controls and event-driven Dock progress. |

A standard Edit menu routes Cut/Copy/Paste/Select All/Undo/Redo through the active
responder rather than replacing field-editor behavior. Settings default to **8**
connections (choices 2, 4, 8, 16, 24, 32), unlimited payload rates and notifications
off. The grid reports actual active connections, throughput, ETA and progress;
HLS uses segment units. Settings changes govern subsequent transfers; the global
rate bucket can be updated while work is active.

## Correctness and security boundaries

Parallel ranges require a proven 206 response, exact Content-Range/length, known
total and a strong ETag or parsed Last-Modified date. Responses are at most
512 KiB; durable granularity is 64 KiB. Checkpoints follow disk synchronization.
The effective concurrency ceiling can fall under errors and grow with successful
work. Slow/retried pending work shrinks and fast workers claim remaining work;
already in-flight requests are not split or speculatively duplicated. Adaptive
files are capped at 512 GiB in this version. These are bounds on application
payload buffers, not all memory retained by the OS or URLSession.

Address renewal is allowed only after a direct job is inactive/paused or failed.
It validates the replacement's reliable validator and length and compares samples
of completed local data; failed validation leaves the manifest unchanged. This
is not a cryptographic proof that every remote byte is identical. No blind append
is authorized by matching filenames or size alone.

The browser catches only explicitly approved source sites and separately
authorized target sites. Unknown/small or inconsistent resources are left to
Chrome. It never cancels the Chrome transfer until the private native inbox
acknowledges receipt. The acknowledgement means received, not finished. Cookies
and authentication headers are not harvested. Raw passwords stay in Keychain;
the app's consent UI scopes ephemeral Basic authorization to the exact HTTPS
hostname and port. Redirects do not carry it to a different origin.

Named queues alternate fairly at the **download** level, with one active file
and multiple verified connections within that file. Recurring local-time windows
use explicit timezone/DST rules; missed windows are skipped, and wake/time changes
reevaluate eligibility. No arbitrary browser commands, scripts, sleep or
termination post-actions are executed. Destructive post-actions remain outside
this build pending a separate security-reviewed design.

## Migration and build instructions

Phase 01 `queue.json` arrays remain readable; absent connection/queue fields get
safe defaults. Queue schedules use a private sibling `*.schedules.json` file.
Preferences preserve the prior destination; credentials are not put in preferences
or queue JSON. Back up your Application Support folder before trying developer
builds with valuable history. HLS remains authorized, unencrypted VOD only, with
the Phase 01 refusals for unsupported/encrypted content.

Use [the project README](../projects/neatclone/README.md) for native-host setup.
The build script accepts `NEATCLONE_ARCH=x86_64` (default) or `arm64`; both target
macOS 12.0. CI packages each application using `ditto` into an executable-preserving
ZIP and attempts a real AppKit content-view PNG after smoke checks. Builds
have local ad-hoc signatures, not Developer ID notarization. Do not disable macOS
security controls to install them.

## Verification

Latest integrated verification passed in [GitHub Actions run 41175693063](https://github.com/iumairqayyum/rea-app-cloner/actions/runs/41175693063)
at commit `7744bfe785482d12a38df913a5cb408d287558d2`: Linux ran **42 XCTest
cases**, **5 compiled native-host integration tests**, and **20 extension Node
tests**, all with zero failures. Intel and arm64 macOS each ran **46 XCTest
cases** with zero failures, built the app, and passed the AppKit launch smoke
for menus, URL paste, sorting, filters, settings, and sheet editing. Linux local
reruns in the managed task could not bind loopback sockets (`EPERM`); the same
HTTP fixture and native-host checks passed in CI.

The Intel developer ZIP is [NeatClone-x86_64-developer-build](https://github.com/iumairqayyum/rea-app-cloner/actions/runs/41175693063/artifacts/13033300529)
(artifact ID `13033300529`, expires 29 January 2027). It contains the Intel
`NeatClone.app`, MV3 extension, native-host registration script, and `INSTALL.txt`.
The optional screenshot artifact was not produced: the hosted AppKit process
reported a zero-height content view. Screenshot capture does not gate the
functional smoke or build. The AppKit smoke ran on macOS 15 hosted runners; no
physical Monterey 12+ Intel machine was available for direct installation tests.

Measured fixture checks transferred 262,144 bytes in approximately 2.0 seconds
under a 131,072 B/s per-download cap, and two concurrent downloads shared that
global cap instead of multiplying it. The controlled 32 MiB loopback profile
verified SHA-256, observed eight concurrent requests, took 1.994 seconds / 2.142
CPU-seconds and reported 38.2 MiB peak child RSS on this Linux machine. It is not
a speedup comparison or a measurement on low-memory Mac hardware.

The macOS CI results and downloadable artifacts will be recorded after the PR
build. No macOS success is implied by these Linux results.

Chromium's existing managed `ExtensionInstallBlocklist: ["*"]` still blocks real
extension loading in Cloud. The smoke script reports that blocker (exit 2); no
policy was changed. Real Chrome-to-Mac handoff and actual Monterey launch remain
separate acceptance work even if newer macOS CI builds and UI checks pass.

## Remaining limitations

- No verified Safari/Orion adapters, universal website/YouTube extraction, DRM,
  browser cookie transfer or modifier-click interception beyond Chrome API limits.
- No live splitting of an in-flight range, simultaneous active files, or
  performance comparison with other download managers.
- Global/per-download limits govern transferred payloads, not TCP/TLS overhead;
  server, disk and fairness constraints may produce rates below the configured cap.
- Credential support is explicitly consented HTTPS Basic auth; other auth schemes
  are not claimed. Notifications require macOS user permission.
- Scheduled sleep, scripts and app termination are intentionally unsupported.
- No low-memory physical-Mac, Monterey hardware or arbitrary-content media-sync
  qualification; controlled fixture measurements do not establish those claims.

## Phase 02 stabilization pass

The integration branch adds HTTP-status preservation for permanent probe denials,
safe single-stream recovery after malformed or interrupted ranges, batched durable
range checkpoints, and deterministic 100 MB resume coverage. The default history
is newest first, sortable by table columns, supports multi-select removal without
deleting output, and offers a separately confirmed delete-file action. The AppKit
smoke path now seeds isolated sample states and checks filtering, sorting, paste,
settings, responder menus, and download context actions. Screenshot capture is
optional if AppKit does not provide a drawable bitmap.
Connection settings now expose every value from 1 through 32.

Cloudflare's public 1 MB endpoint ignored `Range` and returned HTTP 200 with the
full 1,000,000-byte body, which exercises the safe single-stream path. The 100 MB
endpoint returned HTTP 403 with a one-byte response even to the initial one-byte
range probe. That is a remote server restriction, not a demonstrated client
transfer defect; NeatClone surfaces the 403 and does not retry through another
mode or bypass the refusal. No large third-party transfer was attempted.

In the managed Linux workspace, newest-first sorting and safe remove/delete
tests passed locally; local HTTP fixture and native-host integration reruns were
blocked because this task sandbox denies loopback socket creation (`EPERM`). The
latest GitHub Actions matrix completed those checks successfully. AppKit runs on
the hosted macOS CI workers; this Linux host cannot execute the macOS UI.
