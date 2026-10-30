#!/usr/bin/env python3
"""Check actual local Codex discovery and a read-only REA call; no model turn."""
import json
import os
import selectors
import subprocess
import tempfile
import time
from pathlib import Path


def main():
    root = str(Path(__file__).resolve().parents[1])
    with tempfile.TemporaryFile(mode="w+") as errors:
        process = subprocess.Popen(
            ["codex", "app-server", "--stdio"], cwd=root,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
        )
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        pending = b""
        sequence = 0

        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            process.stdin.flush()

        def rpc(method, params):
            nonlocal sequence, pending
            sequence += 1
            request_id = sequence
            send({"id": request_id, "method": method, "params": params})
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if b"\n" not in pending:
                    if not selector.select(max(0, deadline - time.monotonic())):
                        break
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError("Codex app-server closed its output")
                    pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    message = json.loads(line)
                    if message.get("id") == request_id:
                        if "error" in message:
                            raise RuntimeError(json.dumps(message["error"]))
                        return message["result"]
                    if "id" in message and "method" in message:
                        # Do not silently approve an unexpected server request.
                        raise RuntimeError("Unexpected server request: " + message["method"])
            raise TimeoutError("Codex timed out: " + method)

        try:
            rpc("initialize", {
                "clientInfo": {"name": "rea-readiness", "version": "1.0.0"},
                "capabilities": {"experimentalApi": True},
            })
            send({"method": "initialized", "params": {}})
            thread = rpc("thread/start", {"cwd": root, "ephemeral": True})
            thread_id = thread["thread"]["id"]
            inventory = rpc("mcpServerStatus/list", {
                "threadId": thread_id, "serverName": "rea",
            })
            server = next(x for x in inventory["data"] if x["name"] == "rea")
            tools = server.get("tools", {})
            if server.get("toolsError") or "binary_session" not in tools:
                raise RuntimeError("Codex did not discover REA binary_session: "
                                   + str(server.get("toolsError")))
            result = rpc("mcpServer/tool/call", {
                "threadId": thread_id, "server": "rea",
                "tool": "binary_session", "arguments": {},
            })
            if result.get("isError"):
                raise RuntimeError("REA binary_session returned an error")
            skills = rpc("skills/list", {"cwds": [root], "forceReload": True})
            skill_found = "reverse-engineer-anything" in json.dumps(skills)
            summary = {
                "codex_local_mcp_tools": len(tools),
                "binary_session_call_succeeded": True,
                "codex_local_skill_discovered": skill_found,
                "cloud_chat_tool_availability": "not established by this local client probe",
            }
            print(json.dumps(summary, indent=2))
            if not skill_found:
                raise RuntimeError("Codex did not discover the installed REA skill")
        finally:
            selector.close()
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
