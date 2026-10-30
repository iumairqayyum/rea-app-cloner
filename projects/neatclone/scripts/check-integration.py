#!/usr/bin/env python3
"""Exercise compiled binaries against controlled fixtures; no target app code."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("NEATCLONE_BIN_DIR", ROOT / ".build/debug"))
ORIGIN = "chrome-extension://" + "a" * 32 + "/"


class FunctionalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for name in ["NeatCloneCLI", "NeatCloneBridge"]:
            if not (BIN / name).is_file():
                raise RuntimeError("Build the Swift package before running integration checks")
        cls.fixture = tempfile.TemporaryDirectory()
        mp4 = Path(cls.fixture.name) / "fixture.mp4"
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=64x64:r=10", "-t", "0.4", "-c:v", "mpeg4", "-y", str(mp4)], check=True, timeout=30)
        payload = mp4.read_bytes()
        cls.payload = payload

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/fixture.mp4")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.path.startswith("/denied"):
                    self.send_response(403)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("ETag", '"fixture-1"')
                self.end_headers()
                self.wfile.write(payload)

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = "http://127.0.0.1:" + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join(timeout=5)
        cls.fixture.cleanup()

    def test_direct_real_mp4_hash_and_redirect(self):
        for path in ["/fixture.mp4", "/redirect"]:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run([str(BIN / "NeatCloneCLI"), "download", self.base + path, directory], capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                queue = json.loads((Path(directory) / ".neatclone-cli-queue.json").read_text())
                # Locate the finished file independently of the persisted schema.
                files = [p for p in Path(directory).iterdir() if p.is_file() and not p.name.startswith(".")]
                self.assertEqual(len(files), 1)
                self.assertEqual(hashlib.sha256(files[0].read_bytes()).digest(), hashlib.sha256(self.payload).digest())
                self.assertTrue(queue)

    def test_http_authorization_failure_is_not_bypassed_or_logged(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([str(BIN / "NeatCloneCLI"), "download", self.base + "/denied?token=do-not-log", directory], capture_output=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(b"do-not-log", result.stdout + result.stderr)
            self.assertNotIn(self.base.encode(), result.stdout + result.stderr)

    def bridge(self, raw, directory, origin=ORIGIN):
        env = dict(os.environ, NEATCLONE_ALLOWED_ORIGIN=ORIGIN, NEATCLONE_INBOX_DIR=directory)
        return subprocess.run([str(BIN / "NeatCloneBridge"), origin], input=raw, capture_output=True, env=env, timeout=15)

    @staticmethod
    def frame(message):
        payload = json.dumps(message).encode()
        return struct.pack("<I", len(payload)) + payload

    @staticmethod
    def reply(result):
        size = struct.unpack("<I", result.stdout[:4])[0]
        assert len(result.stdout) == 4 + size
        return json.loads(result.stdout[4:])

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux bridge protocol fixture does not test macOS app launch")
    def test_native_message_to_durable_private_inbox(self):
        with tempfile.TemporaryDirectory() as directory:
            message = {"version": 1, "action": "enqueue", "url": self.base + "/fixture.mp4", "kind": "direct"}
            result = self.bridge(self.frame(message), directory)
            self.assertEqual(result.returncode, 0)
            reply = self.reply(result)
            self.assertTrue(reply["ok"])
            entry = Path(directory) / (reply["id"] + ".json")
            saved = json.loads(entry.read_text())
            self.assertEqual(saved["request"], message)
            self.assertEqual(entry.stat().st_mode & 0o777, 0o600)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux tests shared importer; macOS app launch requires a Mac")
    def test_native_handoff_to_shared_queue_download_and_idempotent_replay(self):
        with tempfile.TemporaryDirectory() as inbox, tempfile.TemporaryDirectory() as destination:
            message = {"version": 1, "action": "enqueue", "url": self.base + "/fixture.mp4", "kind": "direct"}
            response = self.reply(self.bridge(self.frame(message), inbox))
            self.assertTrue(response["ok"])
            receipt = Path(inbox) / (response["id"] + ".json")
            original = receipt.read_bytes()
            command = [str(BIN / "NeatCloneCLI"), "import-inbox", inbox, destination]
            first = subprocess.run(command, capture_output=True, timeout=30)
            self.assertEqual(first.returncode, 0, first.stderr.decode())
            self.assertFalse(receipt.exists())
            output = Path(destination) / "fixture.mp4"
            self.assertEqual(output.read_bytes(), self.payload)
            # Simulate a crash after durable enqueue but before receipt removal.
            receipt.write_bytes(original)
            repeated = subprocess.run(command, capture_output=True, timeout=30)
            self.assertEqual(repeated.returncode, 0, repeated.stderr.decode())
            state = json.loads((Path(destination) / ".neatclone-cli-queue.json").read_text())
            self.assertEqual(len(state), 1)
            self.assertEqual(state[0]["id"].lower(), response["id"].lower())
            self.assertEqual(state[0]["status"], "completed")
            self.assertEqual(output.read_bytes(), self.payload)
            self.assertFalse(receipt.exists())

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux-only host framing fixture")
    def test_native_host_rejects_origin_scheme_and_truncated_input(self):
        with tempfile.TemporaryDirectory() as directory:
            wrong = self.bridge(b"", directory, origin="chrome-extension://" + "b" * 32 + "/")
            self.assertNotEqual(wrong.returncode, 0)
            self.assertEqual(wrong.stdout, b"")
            for raw in [self.frame({"version": 1, "action": "enqueue", "url": "file:///etc/passwd", "kind": "direct"}), struct.pack("<I", 20) + b"{}", struct.pack("<I", 65537)]:
                result = self.bridge(raw, directory)
                self.assertFalse(self.reply(result)["ok"])
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
