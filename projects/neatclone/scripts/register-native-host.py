#!/usr/bin/env python3
"""Register an exact unpacked-extension ID for the user's installed Mac app."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--extension-id", required=True)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Chrome macOS registration must be run on the Mac")
    if not re.fullmatch(r"[a-p]{32}", args.extension_id):
        parser.error("Copy the 32-letter extension ID from chrome://extensions")
    app = args.app.expanduser().resolve(strict=True)
    binary = app / "Contents/MacOS/NeatCloneBridge"
    if app.suffix != ".app" or not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("Build NeatClone.app first and use its installed location")
    support = Path.home() / "Library/Application Support/NeatClone"
    support.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(support, 0o700)
    origin = "chrome-extension://" + args.extension_id + "/"
    launcher = support / "chrome-native-host.sh"
    text = "#!/bin/sh\nexport NEATCLONE_ALLOWED_ORIGIN=" + shlex.quote(origin) + "\nexec " + shlex.quote(str(binary)) + ' "$@"\n'
    launcher.write_text(text)
    os.chmod(launcher, 0o700)
    directory = Path.home() / "Library/Application Support/Google/Chrome/NativeMessagingHosts"
    directory.mkdir(parents=True, exist_ok=True)
    manifest = directory / "com.neatclone.bridge.json"
    manifest.write_text(json.dumps({
        "name": "com.neatclone.bridge", "description": "NeatClone user-approved download inbox",
        "path": str(launcher), "type": "stdio", "allowed_origins": [origin],
    }, indent=2) + "\n")
    os.chmod(manifest, 0o600)
    print("Registered NeatClone for that Chrome extension. Reload the extension, then open its popup.")


if __name__ == "__main__":
    main()
