#!/usr/bin/env python3
"""Bounded local HTTP benchmark of the compiled CLI, not a low-memory-Mac claim."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mib", type=int, default=32)
    args = parser.parse_args()
    if not 1 <= args.mib <= 256:
        parser.error("Use 1–256 MiB")
    size = args.mib * 1024 * 1024
    block = bytes(range(256)) * 256
    counters = {"requests": 0, "range_requests": 0, "active": 0, "max_active": 0}
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_HEAD(self):
            self.send_response(200)
            self.send_header("Content-Length", str(size))
            self.send_header("ETag", '"controlled-profile-v1"')
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()

        def do_GET(self):
            start, end, status = 0, size - 1, 200
            header = self.headers.get("Range")
            if header:
                span = header.removeprefix("bytes=").split("-", 1)
                start = int(span[0]); end = min(int(span[1]) if span[1] else size - 1, size - 1)
                status = 206
            with lock:
                counters["requests"] += 1
                counters["range_requests"] += int(header is not None)
                counters["active"] += 1
                counters["max_active"] = max(counters["max_active"], counters["active"])
            try:
                self.send_response(status)
                self.send_header("Content-Length", str(end - start + 1))
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("ETag", '"controlled-profile-v1"')
                self.send_header("Accept-Ranges", "bytes")
                if status == 206:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                self.end_headers()
                for position in range(start, end + 1, 65536):
                    count = min(65536, end - position + 1)
                    offset = position % len(block)
                    data = (block + block)[offset:offset + count]
                    self.wfile.write(data); self.wfile.flush()
                    time.sleep(0.002)  # Slow enough to observe overlapping requests.
            except (ConnectionResetError, BrokenPipeError):
                pass
            finally:
                with lock:
                    counters["active"] -= 1

    root = Path(__file__).resolve().parents[1]
    binary = Path(os.environ.get("NEATCLONE_BIN_DIR", root / ".build/debug")) / "NeatCloneCLI"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        with tempfile.TemporaryDirectory() as destination:
            before = resource.getrusage(resource.RUSAGE_CHILDREN)
            started = time.monotonic()
            result = subprocess.run([str(binary), "download", f"http://127.0.0.1:{server.server_port}/profile.bin", destination], capture_output=True, timeout=180)
            elapsed = time.monotonic() - started
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            if result.returncode:
                raise RuntimeError("Profile transfer failed: " + result.stderr.decode())
            output = Path(destination) / "profile.bin"
            actual = hashlib.sha256()
            with output.open("rb") as stream:
                for chunk in iter(lambda: stream.read(65536), b""):
                    actual.update(chunk)
            expected = hashlib.sha256()
            for _ in range(size // len(block)):
                expected.update(block)
            assert output.stat().st_size == size and actual.digest() == expected.digest()
            print(json.dumps({
                "platform": sys.platform, "payload_mib": args.mib, "elapsed_seconds": round(elapsed, 3),
                "cpu_seconds": round(after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime, 3),
                "peak_child_rss_mib": round(after.ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024), 2),
                "server_requests": counters["requests"], "range_requests": counters["range_requests"],
                "max_simultaneous_server_requests": counters["max_active"], "sha256_verified": True,
                "limitation": "Controlled loopback measurement; no comparison or low-memory hardware claim",
            }, indent=2))
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=5)


if __name__ == "__main__":
    main()
