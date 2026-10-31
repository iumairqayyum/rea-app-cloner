# Phase 02 D: queue automation and macOS integration

This workstream adds functioning platform integration without executing arbitrary
browser-supplied commands. Existing Neat Download Manager artifacts/research and
the installed REA environment were not changed or reinstalled.

## Queue and scheduler behavior

- Named queues persist in a private `queue.schedules.json` sidecar. Existing
  Phase 01 `queue.json` arrays remain readable: missing queue/connection fields
  migrate to nil/zero. Corrupt data still throws rather than silently overwriting
  history. Failed state writes block starting more work; a later successful save
  clears the persistence error.
- Queue definitions can be enabled/disabled and optionally have weekly local-time
  start/end windows. A fixed IANA timezone is stored. Windows may cross midnight
  and belong to their starting weekday. A one-shot absolute-date window is also
  available in the public API. The scheduler UI edits weekly recurring windows.
- DST gap times move to the next valid local time. Repeated times use their first
  occurrence; a window is not replayed twice. Missed windows are skipped, not
  replayed after sleep or shutdown. These rules are explicit design choices.
- One cancellable task sleeps until the next calendar boundary, rather than
  polling the queue. Wake, system clock and timezone notifications reevaluate it.
  At an end boundary the active job is cancelled into the queued/waiting state;
  validated partial work remains available for the next eligible start.
- The transfer queue still runs **one download at a time**. Eligible named queues
  alternate at download boundaries. This is download-level fairness, not
  simultaneous multi-download weighted scheduling. The adaptive engine can use
  several connections inside the active download.
- `enqueue(..., queueID:)` assigns a scheduled queue before any network start.
  Existing queued/paused jobs can be assigned from the grid or scheduler. Explicit
  paused jobs stay paused; scheduling does not override a user's pause. Scheduled
  interrupted/queued jobs recover as waiting on restart, while ordinary
  interrupted jobs retain Phase 01's conservative paused behavior.
- Queue refresh is limited to paused/failed direct downloads. It awaits any
  prior asynchronous cancellation, then calls the engine's identity/sample
  validator before replacing the URL. Running jobs cannot race manifest edits.

The Queue panel provides queue creation/edit/removal, timezone/weekday/window
configuration, enable/disable, and moving waiting downloads. Removing a queue
returns its jobs to the default queue. It never deletes downloaded files.

## Credentials and user consent

`KeychainCredentialStore` stores only this app's credential records in macOS
Keychain, scoped to an exact HTTPS host **and port**. The credential panel
requires explicit consent before Save. Credentials can be deleted per origin.
No raw password is persisted in UserDefaults, queue JSON or repository files.
The current implementation supports username/password **HTTP Basic** authorization
over HTTPS. It does not import browser cookies, OAuth sessions or other apps'
Keychain records. Unsupported/protected authentication can fail normally.

The queue asks its ephemeral authorization provider only at transfer start; the
engine strips credentials for other origins. Resume manifests do not encode
authorization headers. Log and notification text never includes passwords,
signed URLs, browser context or raw transport error strings. This is not an
assertion that Swift strings can be securely zeroed from process memory.

## macOS platform services

- `NSStatusItem` shows active count and offers Show, Resume All, Pause All,
  scheduler and credential actions. No alternate localhost control port exists.
- Dock tile progress and pending badge update from queue callbacks. HLS progress
  remains segment-based; engine connection instrumentation is direct-download
  only.
- Completion/failure alerts use `UNUserNotificationCenter`. App alerts default
  **off**; enabling them requests macOS notification authorization. Content is
  generic to avoid exposing private filenames or signed URLs.
- Post-queue sleep, process termination and scripts are **not implemented**.
  There is no arbitrary-command action vocabulary in the browser protocol. Those
  security-sensitive features need separate explicit design/review and consent.

## Verification and remaining limits

Linux scheduler tests cover exact HTTPS origin scope, fixed-zone/cross-midnight
windows, both DST transitions, invalid/disabled windows, missed one-shot policy,
old-state migration and persisted queue definitions, plus actual start/end
boundary transitions. The complete integrated suite must be run after merging
the engine and UI branches. macOS tests include a Keychain save/read/update/delete
roundtrip using a UUID-isolated service, with cleanup; no preexisting credentials
are inspected or altered.

AppKit status item, notification permission prompts, Dock visuals, real Keychain
authorization dialogs and the queue panel require macOS execution. Tests source
or a successful Linux compile does not prove those behaviors. Actual CI results
and manual Monterey/Chrome limitations belong in the consolidated parent report.

Per-download connection/rate settings are snapshotted at each transfer start;
pause/resume applies a changed per-download default safely. The shared global
limiter can be adjusted while active. No CPU/memory profile on physical
low-memory Macs is claimed in this workstream.
