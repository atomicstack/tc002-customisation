#!/usr/bin/python3
"""tests for the panel-v2 proxy. run: /usr/bin/python3 -m unittest test_serve -v"""
import importlib.util, json, os, secrets, sys, tempfile, threading, unittest, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import serve  # noqa: E402


class PureTests(unittest.TestCase):
    def test_parse_tokens_splits_64_bytes(self):
        raw = bytes(range(64))
        control, admin = serve.parse_tokens(raw)
        self.assertEqual(control, raw[:32].hex())
        self.assertEqual(admin, raw[32:].hex())

    def test_parse_tokens_rejects_other_lengths(self):
        for n in (0, 32, 63, 65):
            with self.assertRaises(ValueError):
                serve.parse_tokens(bytes(n))

    def test_load_token_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "tokens")
            raw = secrets.token_bytes(64)
            open(p, "wb").write(raw)
            self.assertEqual(serve.load_token_file(p), {"control": raw[:32].hex(), "admin": raw[32:].hex()})

    def test_token_for(self):
        self.assertEqual(serve.token_for("PATCH", "config"), "admin")
        self.assertEqual(serve.token_for("POST", "config/save"), "admin")
        self.assertEqual(serve.token_for("GET", "mqtt"), "admin")
        self.assertEqual(serve.token_for("PUT", "mqtt"), "admin")
        self.assertEqual(serve.token_for("GET", "config"), "control")
        self.assertEqual(serve.token_for("GET", "mqtt/status"), "control")
        self.assertEqual(serve.token_for("POST", "notify"), "control")

    def test_rewrite(self):
        self.assertEqual(serve.rewrite("/api/10.0.0.5/v1/status"), ("10.0.0.5", "status", ""))
        self.assertEqual(serve.rewrite("/api/127.0.0.1:8080/v1/frame?duration_s=3&request_id=ab&epoch=1"),
                         ("127.0.0.1:8080", "frame", "duration_s=3&request_id=ab&epoch=1"))
        self.assertEqual(serve.rewrite("/api/10.0.0.5/v1/config/save"), ("10.0.0.5", "config/save", ""))
        for bad in ("/api/10.0.0.5/status", "/api//v1/status", "/tokens", "/api/10.0.0.5/v1/../etc"):
            self.assertIsNone(serve.rewrite(bad), bad)


if __name__ == "__main__":
    unittest.main()
