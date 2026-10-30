#!/usr/bin/env bash
# Functional smoke test: REA must recover a known import and export without
# executing the target JavaScript. Temporary files are removed on exit.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$(mktemp -d)"
result_file="$(mktemp)"
trap 'rm -rf -- "$fixture_dir"; rm -f -- "$result_file"' EXIT
printf '%s\n' '{"name":"rea-smoke-app","version":"1.0.0","main":"index.js"}' > "$fixture_dir/package.json"
printf '%s\n' 'const path = require("node:path");' 'exports.describe = name => path.basename(name);' > "$fixture_dir/index.js"
"$repo_dir/scripts/rea.sh" analyze-javascript-application "$fixture_dir" --json > "$result_file"
python3 - "$result_file" <<'PY'
import json
import sys
evidence = json.load(open(sys.argv[1]))
assert evidence['operation'] == 'analyze_javascript_application'
result = evidence['normalized_result']
assert result['integrity_contradictions'] == []
graph = json.dumps(result['graph'])
assert 'node:path' in graph, 'Expected built-in module import not recovered'
assert '"exported_name": "describe"' in graph, 'Expected export not recovered'
assert evidence['evidence_id'], 'Missing evidence identity'
print('PASS: REA recovered the known JavaScript import and export with evidence')
PY
