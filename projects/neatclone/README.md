# NeatClone — Project 01

An original first vertical slice of a download manager: Chrome user selection →
native message → durable private inbox → Swift queue → real file download.
The macOS interface uses AppKit and targets **macOS Monterey 12+ on Intel**.
This is an early developer build, not a signed/notarized consumer installer.

The supplied Neat Download Manager artifacts were inspected statically before
implementation. See [the evidence ledger](../../docs/ndm-analysis.md) for confirmed
facts, inferences and gaps. No target code, icons or proprietary binaries are
included. Existing REA 6.8.0 was reused without reinstalling it.

## Implemented scope

- Native AppKit queue/history table, URL entry, destination chooser, progress,
  transfer speed, pause, resume, retry, cancel, show completed file.
- A serial durable queue shared by the UI and portable CLI. Restarted interrupted
  transfers remain paused until the user resumes. Receipt IDs prevent duplicate
  inbox imports after a crash. Queue/history stores error categories, not raw
  errors with signed URLs. Local JSON state contains requested URLs and must be
  treated as private data; it is permission-restricted, not encrypted.
- Streaming HTTP(S) transfers to private partial files. Strong ETag or
  Last-Modified plus `If-Range`; validated range start/end/total and response
  lengths. A 200 response to Range truncates and restarts; inconsistent 206 or
  stale 416 is not accepted as complete. Bounded transient retries use backoff.
  Existing files are not overwritten. Names are sanitized and collisions get
  numbered names. HTTPS downgrade redirects and encoded response bodies are
  refused. Server `Content-Disposition` renaming is not implemented: the URL
  path or user name determines the safe filename, so a redirect may need a name.
- Chrome MV3 popup with explicit per-site permission, DOM media/source/link and
  resource-timing detection, opt-in response MIME observation, and user-triggered
  handoff. It does not collect browser cookies, intercept downloads, or read
  response bodies. Cross-site media requires separate site permission.
- Direct MP4 preferred over HLS **only** for the same DOM media group and equal
  explicitly declared quality. Unknown identity/quality is left to the user.
  TS segments are marked incomplete and cannot be handed off as a full video.
- Authorized **unencrypted VOD HLS**: basic master/media playlists, relative
  URLs, highest-bandwidth variant, MPEG-TS or fMP4 initialization maps, and
  declared separate audio. Segments are downloaded by Swift and remuxed with
  FFmpeg stream copy into MP4. FFmpeg sees only generated local playlists and
  local filenames, with the `file` protocol allowlist. No remote playlist is
  passed directly to FFmpeg.

## HLS boundaries

Install a trusted FFmpeg executable separately. The app checks `/usr/local/bin`
and `/opt/homebrew/bin`; CLI/core also accepts `NEATCLONE_FFMPEG` as an absolute
path. No codec transcoding is performed. Incompatible MP4 codecs fail instead of
silently producing a mislabeled file. Encryption keys/DRM, live streams, byte
ranges, discontinuities, gaps, changing maps, nested masters, variable URLs and
content steering are refused. No authentication controls are bypassed: if a
resource needs browser-only cookies or headers, it may return 401/403 and fail.

Pause cancels the HLS operation. Resuming HLS restarts its segment pass to avoid
joining stale changed content; it does not promise byte-resume or cache reuse.
HLS progress counts segments/init files and speed is segments/s, not bytes/s.
Limits include 1 MiB playlists, 64 MiB per segment/init file, 10,000 segments per
playlist, 64 variants, 32 audio groups, and 8 GiB fetched media per operation.
FFmpeg failure retains private partial work for diagnosis/retry; Cancel removes
that job's partial work. Basic tested fixtures preserve video/audio durations;
arbitrary content, codec compatibility and every timestamp layout are unverified.

## Build and use on your Mac

These steps are supplied for macOS validation; **this Linux task has not executed
the AppKit UI or a macOS binary**. A Mac validation checklist is below.

1. Install Xcode command-line tools with a Swift **5.9+** compiler (or Xcode).
   Build on a supported current macOS/Xcode host; the resulting app targets 12.0.
   For HLS also install FFmpeg from a source you trust, for example Homebrew.
2. In Terminal, open this repository's `projects/neatclone` directory and run:

   ```bash
   bash scripts/build-macos.sh
   ```

3. Copy `dist/NeatClone.app` to `/Applications`, then open it. The build script
   requests x86_64 and sets deployment target 12.0. It makes a local ad-hoc
   signature; no Developer ID signing, notarization or distribution testing has
   occurred. Use macOS's normal approval UI if it asks about this local build.
   The bundle permits HTTP for user-requested downloads; HTTPS certificate
   verification remains enabled and HTTPS-to-HTTP redirects are refused.
4. In Chrome open `chrome://extensions`, enable **Developer mode**, choose
   **Load unpacked**, and select this project's `extension` folder. Copy the
   extension's 32-letter ID displayed on that page.
5. Register the private native messaging host for that exact ID:

   ```bash
   python3 scripts/register-native-host.py \
     --app /Applications/NeatClone.app --extension-id YOUR_EXTENSION_ID
   ```

6. Reload the extension. Open a page you are authorized to download from, click
   the NeatClone extension icon, approve that site and scan. Choose an MP4 or HLS
   candidate and click **Send to NeatClone**. The app should open and queue it in
   your selected destination (initially `~/Downloads/NeatClone`). For manual HLS
   entry, enable **Unencrypted HLS → MP4** before adding its playlist URL.

The host manifest names `com.neatclone.bridge`, allows only your extension ID,
and points to a user-private wrapper. The compiled host also validates Chrome's
caller origin. It accepts bounded length-prefixed JSON, validates protocol and
URLs, writes a private receipt, and launches the installed app. No listening TCP
port is opened. A native acknowledgement means the request was received; consult
the app for actual completion or errors. Keep the installed app at its registered
location, or rerun registration after moving it.

Queue/history is `~/Library/Application Support/NeatClone/queue.json`; pending
receipts are in its `Inbox` subdirectory. Partial files sit in hidden
`.neatclone-UUID` directories beside the destination. To disable integration,
remove only `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.neatclone.bridge.json`
and disable/remove the Chrome extension. Keep history/download files unless you
intend to delete them. Chromium profiles and other Chromium-based browsers need
their own host registration and are not claimed supported by this installer.

## Run portable checks in Codex Cloud

Use the existing Swift installation if available. In this task a Linux Swift
6.0.3 toolchain was obtained independently of REA. No Swift package dependencies
are downloaded. Linux uses FoundationNetworking, not AppKit.

```bash
cd projects/neatclone
export PATH=/workspace/toolchains/swift-6.0.3-RELEASE-ubuntu22.04/usr/bin:$PATH
export CLANG_MODULE_CACHE_PATH=/tmp/neatclone-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/neatclone-swift-cache
swift test --cache-path /tmp/neatclone-pm-cache --config-path /tmp/neatclone-pm-config -j 2
python3 scripts/check-integration.py
cd extension
npm test
```

Tests that bind a local fixture server require the environment's supported
execution permission outside restrictive command sandboxes. Preserve the
network proxy/policy; no external target account is involved. Tests require
Python 3, FFmpeg/ffprobe and Node.js, in addition to Swift.

The portable CLI can download a user-authorized URL:

```bash
.build/debug/NeatCloneCLI download 'https://example.org/video.mp4' /path/to/downloads
.build/debug/NeatCloneCLI download 'https://example.org/vod.m3u8' /path/to/downloads --hls
```

The CLI is a test/automation harness; queue pause/resume controls are in the app
and shared API. Do not paste a signed URL into public logs or commit it. URL
renewal, FTP, proxy configuration, bandwidth caps, parallel acceleration, rich
search/filtering and automatic site-specific extraction are not in this slice.

## macOS acceptance work still required

- Compile AppKit against the macOS SDK and run on Intel Monterey 12+.
- Confirm destination chooser, UI progress, quit/reopen recovery and history.
- Register Chrome's actual extension ID and verify browser → compiled host →
  running app → completed file. Linux host tests alone do not prove Mac launch.
- Test real authorized sites and equivalent quality grouping; no universal
  video extraction or support for protected services is promised.
- Test signed/notarized distribution separately if this becomes a public app.

See [verification results](../../docs/neatclone-verification.md) for the actual
checks run in this task. CI configuration is provided; a workflow file is not
evidence that CI has run or passed.
