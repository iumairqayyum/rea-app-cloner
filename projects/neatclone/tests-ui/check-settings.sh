#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
bin="$(mktemp -d)"
trap 'rm -rf -- "$bin"' EXIT
swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$bin/cache}" Sources/NeatClone/Settings.swift tests-ui/SettingsChecks.swift -o "$bin/settings-checks"
"$bin/settings-checks"
