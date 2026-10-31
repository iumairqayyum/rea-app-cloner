#!/usr/bin/env python3
"""Run every discovered XCTest suite with bounded lifetime and hang diagnostics."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys


def main():
    subprocess.run(["swift", "build", "--build-tests", "-j", "2"], check=True, timeout=300)
    listing = subprocess.run(["swift", "test", "list", "--skip-build"], check=True, capture_output=True, text=True, timeout=45)
    tests = [line.strip() for line in listing.stdout.splitlines() if re.fullmatch(r"[A-Za-z0-9_.]+/[A-Za-z0-9_]+", line.strip())]
    if not tests:
        raise RuntimeError("Swift reported no discoverable XCTest cases")
    suites = sorted({name.split("/")[0] for name in tests})
    print(f"Discovered {len(tests)} XCTest cases across {len(suites)} suites", flush=True)
    diagnostics = Path("dist/test-diagnostics")
    diagnostics.mkdir(parents=True, exist_ok=True)
    failures = []
    for suite in suites:
        print("START " + suite, flush=True)
        process = subprocess.Popen(["swift", "test", "--skip-build", "--filter", "^" + re.escape(suite) + "/"], start_new_session=True,
                                   env=dict(os.environ, NSUnbufferedIO="YES"))
        try:
            code = process.wait(timeout=90)
        except subprocess.TimeoutExpired:
            print("TIMEOUT " + suite + "; collecting owned-process stacks", flush=True)
            table = subprocess.check_output(["ps", "-axo", "pid,ppid,comm"], text=True)
            (diagnostics / (suite + ".processes.txt")).write_text(table)
            rows = [line.strip().split(None, 2) for line in table.splitlines()[1:]]
            descendants = {process.pid}
            for _ in range(12):
                descendants.update(int(pid) for pid, parent, _ in rows if int(parent) in descendants)
            for pid, _, command in rows:
                if int(pid) in descendants and "xctest" in command.lower():
                    try:
                        subprocess.run(["sample", pid, "2", "-file", str(diagnostics / (suite + ".sample.txt"))], timeout=15, check=False)
                    except subprocess.TimeoutExpired:
                        pass
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=10)
            code = 124
        if code:
            failures.append({"suite": suite, "exit": code})
        print(f"END {suite}: exit {code}", flush=True)
    result = {"discovered_cases": len(tests), "suite_count": len(suites), "failed_suites": failures}
    (diagnostics / "result.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    return int(bool(failures))


if __name__ == "__main__":
    sys.exit(main())
