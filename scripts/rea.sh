#!/usr/bin/env bash
set -euo pipefail
runtime_dir="${REA_RUNTIME_DIR:-/workspace/rea-runtime}"
export PATH="$runtime_dir/node_modules/.bin:$PATH"
exec "$runtime_dir/node_modules/.bin/node" \
  "$runtime_dir/lib/node_modules/rea-agents/scripts/rea.mjs" "$@"
