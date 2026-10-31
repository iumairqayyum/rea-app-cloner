# Luma TV starter

A small Next.js renderer inside an Electron desktop shell. The UI is seeded with placeholder channels; the playlist file picker and channel data are not wired up yet.

## Start

```sh
npm install
npm run dev
```

## Architecture notes

- **UI:** A narrow library sidebar, top status bar, live player, channel search/category filters, channel list, and playback status. The sample layout is intentionally compact and desktop first.
- **Playback:** `components/Player.tsx` owns the HTML video element. It uses `hls.js` where Media Source Extensions are available and native HLS otherwise. A real app should validate playlist entries and surface actionable network/codec errors.
- **IPC:** Electron's main process owns the native window and privileged operations. `preload.cjs` exposes a tiny `contextBridge` API; the renderer calls named, narrow methods via `ipcRenderer.invoke`. Keep `nodeIntegration` off and `contextIsolation` on. Add playlist file selection through a main-process dialog and return only the selected contents or a safe app-managed identifier.

## Blueprint provenance

The attached `iptv_blueprint.txt` contains an REA error message about passing a directory to a binary-only analyzer. It does not include IPTVnator's source, UI inventory, playback implementation, or IPC design. The architecture notes above describe this starter's design and common Electron practices, not verified IPTVnator internals.
