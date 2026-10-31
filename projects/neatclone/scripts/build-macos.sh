#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Build the AppKit application on macOS with Xcode command-line tools.' >&2
  exit 78
fi
export MACOSX_DEPLOYMENT_TARGET=12.0
build_arch="${NEATCLONE_ARCH:-x86_64}"
case "$build_arch" in x86_64|arm64) ;; *) echo 'Choose x86_64 or arm64.' >&2; exit 2 ;; esac
swift build -c release --arch "$build_arch" -j 2
bin_dir="$(swift build -c release --arch "$build_arch" --show-bin-path)"
app="$PWD/dist/NeatClone.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/NeatClone" "$app/Contents/MacOS/NeatClone"
cp "$bin_dir/NeatCloneBridge" "$app/Contents/MacOS/NeatCloneBridge"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.neatclone.app</string>
<key>CFBundleName</key><string>NeatClone</string>
<key>CFBundleExecutable</key><string>NeatClone</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/MacOS/NeatCloneBridge"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built $build_arch application: $app (local ad-hoc signature; not notarized)"
