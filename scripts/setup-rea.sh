#!/usr/bin/env bash
# Uses the documented npm global installation and scoped REA setup workflow.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export REA_RUNTIME_DIR="${REA_RUNTIME_DIR:-/workspace/rea-runtime}"
mkdir -p "$REA_RUNTIME_DIR"
# Acquire packages from a trusted directory outside the application checkout.
cd "$REA_RUNTIME_DIR"
npm install --prefix "$REA_RUNTIME_DIR" --no-audit --no-fund node@24.22.1
export PATH="$REA_RUNTIME_DIR/node_modules/.bin:$PATH"
npm install --global --prefix "$REA_RUNTIME_DIR" --no-audit --no-fund rea-agents@6.8.0
"$repo_dir/scripts/rea.sh" setup --client codex --dry-run --json
"$repo_dir/scripts/rea.sh" setup --client codex --yes --json
# REA 6.8.0 can select a shebang alias. Pin the documented absolute Node/script
# form so a client with the original Node 24.19 on PATH can still start REA.
python3 "$repo_dir/scripts/pin-rea-launcher.py"
"$repo_dir/scripts/rea.sh" doctor --client codex --skill --json
"$repo_dir/scripts/rea.sh" mcp doctor --json
