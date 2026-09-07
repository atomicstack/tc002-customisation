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
            with open(p, "wb") as f:
                f.write(raw)
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


def load_mock():
    spec = importlib.util.spec_from_file_location("mock_device", os.path.join(HERE, "mock-device.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class EndToEndTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mock_mod = load_mock()
        # both servers log every request to stderr; keep test output pristine, restored below
        cls._serve_log, cls._mock_log = serve.Handler.log_message, cls.mock_mod.Handler.log_message
        serve.Handler.log_message = lambda *a, **k: None
        cls.mock_mod.Handler.log_message = lambda *a, **k: None
        cls.control, cls.admin = secrets.token_hex(32), secrets.token_hex(32)
        cls.device = cls.mock_mod.Device(cls.control, cls.admin)
        cls.mock = cls.mock_mod.make_server(0, cls.device)
        cls.mock_port = cls.mock.server_address[1]
        threading.Thread(target=cls.mock.serve_forever, daemon=True).start()
        cls.proxy = serve.make_server(0, {"control": cls.control, "admin": cls.admin}, HERE)
        cls.proxy_port = cls.proxy.server_address[1]
        threading.Thread(target=cls.proxy.serve_forever, daemon=True).start()
        cls.bare = serve.make_server(0, {"control": None, "admin": None}, HERE)
        cls.bare_port = cls.bare.server_address[1]
        threading.Thread(target=cls.bare.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        for s in (cls.mock, cls.proxy, cls.bare):
            s.shutdown(); s.server_close()
        serve.Handler.log_message = cls._serve_log
        cls.mock_mod.Handler.log_message = cls._mock_log

    def call(self, method, path, body=None, ctype="application/json", port=None, headers=None):
        port = port or self.proxy_port
        url = f"http://127.0.0.1:{port}/api/127.0.0.1:{self.mock_port}/v1/{path}"
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
        if data is not None:
            req.add_header("Content-Type", ctype)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_tokens_endpoint_reports_presence_only(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.proxy_port}/tokens") as r:
            self.assertEqual(json.loads(r.read()), {"control": True, "admin": True})
        with urllib.request.urlopen(f"http://127.0.0.1:{self.bare_port}/tokens") as r:
            self.assertEqual(json.loads(r.read()), {"control": False, "admin": False})

    def test_static_serving_is_allow_listed(self):
        # the proxy must never hand back its own source, or another file that happens to sit
        # beside it (like the mock's default token file), even though SimpleHTTPRequestHandler
        # would otherwise serve anything under `directory`
        req = urllib.request.Request(f"http://127.0.0.1:{self.proxy_port}/serve.py")
        try:
            urllib.request.urlopen(req, timeout=5)
            self.fail("expected an http error")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 404)
            self.assertEqual(json.loads(e.read())["error"], "not_found")
        with urllib.request.urlopen(f"http://127.0.0.1:{self.proxy_port}/sim.js", timeout=5) as r:
            self.assertEqual(r.status, 200)
            self.assertIn(r.headers.get("Content-Type", "").split(";")[0].strip(),
                          ("application/javascript", "text/javascript"))
        # mock-tokens is not the real proxy's problem to guard (it lives in HERE only incidentally,
        # created by mock-device.py), but the same allow-list must block it too; prove that against
        # a throwaway directory so the test does not depend on the real file existing or not
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "mock-tokens"), "wb") as f:
                f.write(b"not a real token file")
            srv = serve.make_server(0, {"control": None, "admin": None}, d)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            try:
                req = urllib.request.Request(f"http://127.0.0.1:{srv.server_address[1]}/mock-tokens")
                try:
                    urllib.request.urlopen(req, timeout=5)
                    self.fail("expected an http error")
                except urllib.error.HTTPError as e:
                    self.assertEqual(e.code, 404)
            finally:
                srv.shutdown(); srv.server_close()

    def test_status_through_the_proxy(self):
        status, doc = self.call("GET", "status")
        self.assertEqual(status, 200)
        for k in ("epoch", "revision", "renderer", "base", "generator", "overlay", "brightness", "transport", "mqtt", "network", "time"):
            self.assertIn(k, doc)
        self.assertEqual(doc["transport"], "plaintext")

    def test_no_token_is_503_from_the_proxy(self):
        status, doc = self.call("GET", "status", port=self.bare_port)
        self.assertEqual(status, 503)
        self.assertEqual(doc["error"], "no_token")

    def test_client_authorization_is_dropped(self):
        status, _ = self.call("GET", "status", headers={"Authorization": "Bearer " + "00" * 32})
        self.assertEqual(status, 200)

    def test_admin_route_uses_the_admin_token(self):
        status, doc = self.call("PATCH", "config", {"brightness": 42})
        self.assertEqual(status, 200)
        self.assertEqual(doc["brightness"], 42)
        status, doc = self.call("GET", "mqtt")
        self.assertEqual(status, 200)
        self.assertIn("password_set", doc)

    def test_scene_action_notify_and_frame(self):
        _, st = self.call("GET", "status")
        status, doc = self.call("PUT", "scene", {"base": "clock", "request_id": "a1", "epoch": st["epoch"]})
        self.assertEqual((status, doc["status"]), (200, "applied"))
        status, doc = self.call("POST", "action", {"action": "brightness", "brightness": 30, "request_id": "a2", "epoch": st["epoch"]})
        self.assertEqual((status, doc["status"]), (200, "applied"))
        status, doc = self.call("POST", "notify", {"text": "hi", "duration_s": 2, "request_id": "a3", "epoch": st["epoch"]})
        self.assertEqual((status, doc["status"]), (200, "applied"))
        frame = bytes([9]) * 2496
        status, doc = self.call("POST", f"frame?duration_s=2&request_id=a4&epoch={st['epoch']}", frame, "application/octet-stream")
        self.assertEqual((status, doc["status"]), (200, "applied"))
        _, st2 = self.call("GET", "status")
        self.assertEqual(st2["overlay"], "frame")
        self.assertEqual(st2["base"], "clock")
        self.assertEqual(st2["brightness"], 30)

    def test_device_errors_pass_through(self):
        status, doc = self.call("POST", "notify", {"text": "hi", "request_id": "b1", "epoch": 999})
        self.assertEqual((status, doc["error"]), (409, "stale_epoch"))
        status, doc = self.call("POST", "notify", {"text": "hi", "request_id": "b2", "epoch": 1, "bogus": 1})
        self.assertEqual((status, doc["error"]), (400, "unknown_field"))
        status, doc = self.call("GET", "nope")
        self.assertEqual(status, 404)

    def test_unreachable_device_is_502(self):
        url = f"http://127.0.0.1:{self.proxy_port}/api/127.0.0.1:1/v1/status"
        try:
            urllib.request.urlopen(url, timeout=5)
            self.fail("expected an http error")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 502)
            self.assertEqual(json.loads(e.read())["error"], "proxy")

    def test_stream_route_authenticates_before_503(self):
        # talks to the mock directly: the proxy always adds a token, so this is the only way to
        # exercise the mock's own auth check ahead of its 503 not_implemented answer.
        url = f"http://127.0.0.1:{self.mock_port}/api/v1/streams"
        req = urllib.request.Request(url, method="POST")
        try:
            urllib.request.urlopen(req, timeout=5)
            self.fail("expected an http error")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 401)
            self.assertEqual(json.loads(e.read())["error"], "unauthorized")
        req = urllib.request.Request(url, data=b"{}", method="POST",
                                      headers={"Authorization": f"Bearer {self.control}", "Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=5)
            self.fail("expected an http error")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 503)
            self.assertEqual(json.loads(e.read())["error"], "not_implemented")


if __name__ == "__main__":
    unittest.main()
