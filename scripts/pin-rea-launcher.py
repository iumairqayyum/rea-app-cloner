#!/usr/bin/env python3
"""Pin only REA's launcher to its installed Node, preserving other settings."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import tomllib

runtime = Path(os.environ.get("REA_RUNTIME_DIR", "/workspace/rea-runtime")).resolve()
profile = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
config = profile / "config.toml"
if config.is_symlink():
    raise RuntimeError("Refusing to replace a linked Codex configuration")
original = config.read_bytes()
text = original.decode()
rea = tomllib.loads(text)["mcp_servers"]["rea"]
entry = runtime / "lib/node_modules/rea-agents/scripts/rea.mjs"
node = runtime / "node_modules/.bin/node"
command = Path(rea["command"]).resolve()
if command not in (entry.resolve(), node.resolve()):
    raise RuntimeError("Existing REA launcher is not owned by this installation")
if rea.get("args") not in (["mcp"], [str(entry), "mcp"]):
    raise RuntimeError("Unexpected REA arguments; manual review required")
match = re.search(r"(?m)^\[mcp_servers\.rea\]\s*\n(?P<body>(?:(?!^\[).|\n)*)", text)
if not match:
    raise RuntimeError("Cannot safely identify REA configuration section")
body = match["body"]
body, count_command = re.subn(r"(?m)^command\s*=.*$", "command = " + json.dumps(str(node)), body)
body, count_args = re.subn(r"(?ms)^args\s*=\s*\[[^\]]*\]", "args = " + json.dumps([str(entry), "mcp"]), body)
if (count_command, count_args) != (1, 1):
    raise RuntimeError("Cannot safely replace REA launcher fields")
updated = (text[:match.start("body")] + body + text[match.end("body"):]).encode()
assert tomllib.loads(updated.decode())["mcp_servers"]["rea"]["command"] == str(node)
if updated != original:
    backup = config.with_name(config.name + ".rea-launcher." + hashlib.sha256(original).hexdigest() + ".backup")
    if not backup.exists():
        shutil.copy2(config, backup)
    if backup.read_bytes() != original or config.read_bytes() != original:
        raise RuntimeError("Configuration or backup changed; refusing overwrite")
    fd, staging = tempfile.mkstemp(prefix=".rea-launcher-", dir=profile)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(updated)
        os.chmod(staging, config.stat().st_mode & 0o777)
        os.replace(staging, config)
    finally:
        if os.path.exists(staging):
            os.unlink(staging)
print("REA launcher uses the pinned Node runtime")
