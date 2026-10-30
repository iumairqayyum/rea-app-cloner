# Project 01 — NeatClone (NDM-inspired download manager)

Status: first functional vertical slice implemented; portable Linux checks pass.
macOS AppKit execution and real Chrome-to-Mac handoff remain unverified. See
[artifact evidence](ndm-analysis.md) and [verification results](neatclone-verification.md).
No claim of completed reverse engineering.

## Objective
Build an original macOS 12+ (Intel x86_64) download manager with familiar download-manager workflows, Chrome Manifest V3 extension integration, and video handling that prefers direct MP4 when an accessible equivalent exists.

## Required behaviors
- Desktop: add URL, download queue, progress, speed, pause/resume where HTTP range requests permit, retry, history, choose destination.
- Browser: explicit user-triggered detection and handoff of media URLs from authorized pages; secure native messaging between Chrome extension and app.
- Selection: prioritize suitable direct MP4 over segmented HLS only when both represent the requested video and available quality; never assume a .ts segment is the full video.
- HLS: handle unencrypted, authorized playlists and remux to MP4 when codec/container compatible; preserve audio and A/V sync. Do not bypass DRM or protected access.
- Download correctness: redirects, filenames, content types, Range/ETag validation, resumability, cancellation, network failures.
- Security: no credentials or signed URLs in logs; limit extension host permissions; request consent for each site; safe filename/path handling.

## Implementation approach
1. Inventory target artifacts and legal access. Obtain a user-supplied authorized NDM app/extension package or document public behavior. Do not fabricate REA results.
2. Read AGENTS.md and REA skill. Use static inspection first. Record evidence, observed features, and unknowns in docs/ndm-analysis.md.
3. Draft UI and component architecture; prefer native Swift/AppKit for macOS 12 and a Manifest V3 extension with native messaging. Account for Linux Cloud inability to compile/test macOS binaries.
4. Build an original minimal vertical slice: browser URL handoff -> app queue -> direct MP4 download -> progress -> saved file.
5. Add HLS detection/remux and resilient downloads with tests and fixtures. Avoid copying NDM source/assets or circumventing licensing/DRM.
6. Provide reproducible build instructions for macOS and report verified vs unverified capabilities.

## Acceptance tests
- Download a test MP4 with correct hash.
- Resume an HTTP range-supported test download and handle a non-range server.
- Distinguish MP4 from HLS manifest and TS segments.
- Test authorized unencrypted HLS to MP4 with audio/video sync.
- Chrome extension communicates with app on a supported macOS installation.
- No assertion of native macOS build success until compiled and run on a Mac.

## Immediate next action
Both user-supplied DMG and CRX were inspected statically. Validate the AppKit build
and Chrome native-host handoff on an Intel macOS 12+ installation using
`projects/neatclone/README.md`; continue deeper native analysis only with a
configured provider and authorized runtime evidence. Do not infer unobserved
NDM implementation details from the first slice.
