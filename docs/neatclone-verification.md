# Project 01 verification — 30 October 2026

These results belong to this Linux Codex Cloud task. macOS or real Chrome-to-app
execution is not implied by portable tests. Existing REA 6.8.0 was reused, not
reinstalled. No Chromium policy, authentication control, or DRM restriction was
bypassed. The original app/extension code was inspected but never executed.

## Passed

| Check | Result and coverage |
| --- | --- |
| Swift Linux build | All declared portable targets compiled with Swift 6.0.3, `-j 2`. `NeatClone` compiles its Linux refusal branch, **not AppKit**. |
| Swift XCTest suite | **19 executed, 0 failures**: DownloadTests 5, HTTPDownloadTests 3, HLSTests 8, NativeBridgeTests 3. The separate Swift Testing runner reports 0 because these tests use XCTest; that is not the test count. |
| Real HTTP integration within Swift tests | Exact downloaded bytes after pause/resume; server observed Range; strong validator resume; non-range and changed validator restart; malformed range cannot corrupt output and a fresh retry succeeds. |
| HLS actual media fixtures | Generated MPEG-TS VOD and master fMP4 with separate audio. Downloaded/remuxed by the implemented engine using FFmpeg; ffprobe found both A/V streams, approximately 2-second durations, and duration difference under 0.15 seconds. This is a bounded fixture check, not arbitrary-content sync proof. |
| Compiled-binary integration suite | **5 executed, 0 failures**: real generated MP4 hash and redirect, 403 without bypass/token logging, valid native receipt/private inbox, rejection of wrong origin/file URL/truncated/oversize framing, and real host → shared inbox importer → queue → downloaded MP4 plus idempotent receipt replay. |
| MV3 extension tests | **10 executed, 0 failures**, dependency-free Node tests. Permission constraints, MIME/path classification, same-group/equal-quality MP4 preference, DOM scan, actual background-controller logic with mocked Chrome API, stale/forged/TS request refusal, native acknowledgements/errors and response observation. |
| Target static REA analysis | Chrome JavaScript application graph and desktop inventory, plus bundled SQLite schema. Evidence IDs and limits are in [ndm-analysis.md](ndm-analysis.md). |

The integration harness exercises the **same** inbox importer used by AppKit,
without claiming the macOS process launch occurred. Browser tests mock Chrome
APIs; the host test invokes the compiled Swift bridge directly with a controlled
origin, as a protocol/implementation test, not a browser-origin security bypass.
Chrome's actual origin enforcement still needs testing on a permitted browser.

## Blocked, unrun, or intentionally unsupported

- **macOS AppKit compile/run, Intel Monterey execution:** no macOS SDK/host in
  Linux. Build script and a macOS CI job were added; neither proves that job has
  run or that the application works on a Mac. No macOS binary is claimed built.
- **Actual Chromium extension loading:** smoke script exits **2**, reports
  `blocked: true`. Managed `ExtensionInstallBlocklist: ["*"]` prohibits new
  extensions. Initial load attempts did not register the extension. Policy was
  left unchanged; no real browser-native handshake passed here.
- **Real Chrome → Mac app handoff:** unverified. Registration and app-launch
  scripts are supplied for Mac validation.
- **REA native-macos plist inspection:** `capability_unavailable` on Linux;
  Python's plist parser read bundle metadata instead. Native disassembly was
  not performed: no configured provider. Header/strings observations are not
  decompilation or recovered algorithms.
- **HLS encrypted/DRM/live/byte-range/discontinuous playlists:** deliberately
  refused. HLS resume restarts acquisition. No authorization/cookie transfer,
  automatic URL renewal, transcoding, FTP/proxy controls, bandwidth caps or
  parallel segmented acceleration in this first slice.
- **Vendor signature trust and exhaustive analysis:** not established. Both
  attachments were inspected within stated static bounds; original runtime
  behavior, performance, all features and exact algorithm internals remain open.

## Commands used

From `projects/neatclone`, with the retained Linux Swift toolchain on PATH:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/neatclone-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/neatclone-swift-cache \
swift test --cache-path /tmp/neatclone-pm-cache \
  --config-path /tmp/neatclone-pm-config -j 2
python3 scripts/check-integration.py
npm test --prefix extension
node extension/tests/chromium-smoke.mjs  # expected blocker: exit 2
```

Loopback fixture/subprocess tests required reviewed execution permissions outside
the restrictive command sandbox. Initial fixture startup/cleanup problems were
corrected (Python readiness deadline, proper directory argument, signal handling)
and the final suite completed. Failed preliminary runs are not counted as passes.
No disabled assertions or expected-failure substitutions were used.
