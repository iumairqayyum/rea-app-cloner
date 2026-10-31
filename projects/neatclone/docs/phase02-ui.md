# Phase 02: AppKit interface and settings

The download window now has a customizable native toolbar (Add URL,
Start/Resume, Pause, Queue, Settings), a horizontally/vertically scrollable grid,
status filtering and file-name search. Click a column heading to sort. Selection
is preserved by download ID as the queue changes. Right-click a row for transfer
controls, safe address refresh, a selectable full-error sheet, file reveal, cancel,
and assignment to a named queue. The Queue toolbar button opens scheduling controls.

The grid displays actual active connections supplied by the engine, byte or
segment progress, throughput, ETA and queue name. A requested connection ceiling
is never presented as an active count or speed guarantee. HLS progress remains in
segments rather than misleading byte units.

Edit menu commands use the AppKit responder chain: Cut ⌘X, Copy ⌘C, Paste ⌘V,
Select All ⌘A, Undo ⌘Z and Redo ⇧⌘Z. This allows the focused field editor in URL
entry, settings and sheets to receive the operation. The grid supports native
multi-selection/Select All and Copy of selected file names/statuses. Other
shortcuts are Add URL ⌘N, Settings ⌘,, Start/Resume ⌘R, Pause ⌘P, Retry ⇧⌘R,
Refresh Address ⇧⌘U and Choose Folder ⇧⌘D. Controls use native colors, fonts,
accessibility labels, keyboard focus and dark appearance rather than fixed colors.

Settings save only non-secret preferences in UserDefaults:

| Preference | Default | Scope |
| --- | --- | --- |
| Connections per download | 8 | Choices 2, 4, 8, 16, 24, 32; engine applies its verified effective cap |
| Per-download limit | Unlimited | Whole KiB/s; blank or 0 means unlimited |
| Global limit | Unlimited | Whole KiB/s; blank or 0 means unlimited |
| Result notifications | Off | User opt-in; platform authorization still applies |
| Destination | Downloads/NeatClone | Existing destination preference is retained |

Limits/settings apply to new or resumed transfers; changing a requested ceiling
is not a claim that an already-running transfer has been reconfigured. The
existing queue JSON is retained by the platform migration; this UI does not reset
history or write credentials into preferences. Credentials are managed through
the platform's Keychain panel, opened from Settings.

## Verification

`tests-ui/check-settings.sh` compiles and executes dependency-free portable Swift
checks for defaults, preferences round trip, valid connection choices, rate parsing
and invalid/overflow rate rejection. It passed on Linux. macOS-only XCTest cases
in `Tests/NeatCloneMacTests/AppKitTests.swift` exercise actual responder editing,
menu equivalents, grid selection/copy and preferences.

On macOS, the app also accepts an explicit developer probe:

```bash
/path/to/NeatClone.app/Contents/MacOS/NeatClone --ui-smoke-output /tmp/NeatClone.png
```

This initializes an isolated temporary queue, checks real URL/filename/settings
and sheet field-editor actions and Edit menu shortcuts, then writes a PNG of the
actual AppKit content view and exits. It does not fabricate download rows or
claim a screenshot was captured before the command runs successfully. Clipboard
text is restored after the probe. GitHub Actions invokes this mode for macOS UI
validation/screenshots; the Linux branch cannot execute AppKit. A current macOS
CI pass does not establish launch or compatibility on Monterey hardware.
