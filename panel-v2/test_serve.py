#!/usr/bin/python3
"""tests for the panel-v2 proxy. run: /usr/bin/python3 -m unittest test_serve -v"""
import contextlib, importlib.util, json, os, secrets, socket, subprocess, sys, tempfile, threading, unittest, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import serve  # noqa: E402


@contextlib.contextmanager
def mock_attr(obj, name, value):
    """swap an attribute for the body of a with-block, so a test can stand in for subprocess.run."""
    old = getattr(obj, name)
    setattr(obj, name, value)
    try:
        yield
    finally:
        setattr(obj, name, old)


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
        self.assertEqual(serve.token_for("GET", "ntfy"), "admin")
        self.assertEqual(serve.token_for("PUT", "ntfy"), "admin")
        self.assertEqual(serve.token_for("POST", "notify"), "control")

    def test_rewrite(self):
        self.assertEqual(serve.rewrite("/api/10.0.0.5/v1/status"), ("10.0.0.5", "status", ""))
        self.assertEqual(serve.rewrite("/api/127.0.0.1:8080/v1/frame?duration_s=3&request_id=ab&epoch=1"),
                         ("127.0.0.1:8080", "frame", "duration_s=3&request_id=ab&epoch=1"))
        self.assertEqual(serve.rewrite("/api/10.0.0.5/v1/config/save"), ("10.0.0.5", "config/save", ""))
        for bad in ("/api/10.0.0.5/status", "/api//v1/status", "/tokens", "/api/10.0.0.5/v1/../etc"):
            self.assertIsNone(serve.rewrite(bad), bad)

    def test_adb_pull_tries_the_durable_token_path_then_the_volatile_one(self):
        # the runtime keeps its credentials on /data and falls back to /tmp only when it could not
        # make the durable directory, so the durable path is tried first
        self.assertEqual(serve.TOKEN_PATHS,
                         ("/data/tc002/state/credentials/tokens", "/tmp/tc002/credentials/tokens"))
        tried = []

        def fake_run(cmd, **kw):
            tried.append(cmd[-2])
            if cmd[-2] == serve.TOKEN_PATHS[0]:
                return subprocess.CompletedProcess(cmd, 1, "", "adb: error: remote object does not exist")
            with open(cmd[-1], "wb") as f:
                f.write(b"\x11" * 32 + b"\x22" * 32)
            return subprocess.CompletedProcess(cmd, 0, "", "")

        with mock_attr(serve.subprocess, "run", fake_run):
            tokens = serve.adb_pull()
        self.assertEqual(tried, list(serve.TOKEN_PATHS))
        self.assertEqual(tokens["control"], "11" * 32)
        self.assertEqual(tokens["admin"], "22" * 32)

    def test_adb_pull_names_both_paths_when_neither_is_there(self):
        def fake_run(cmd, **kw):
            return subprocess.CompletedProcess(cmd, 1, "", "adb: error: remote object does not exist")

        with mock_attr(serve.subprocess, "run", fake_run):
            with self.assertRaises(RuntimeError) as e:
                serve.adb_pull()
        for path in serve.TOKEN_PATHS:
            self.assertIn(path, str(e.exception))

    def test_adb_pull_passes_the_serial_through(self):
        seen = []

        def fake_run(cmd, **kw):
            seen.append(cmd)
            with open(cmd[-1], "wb") as f:
                f.write(b"\x33" * 64)
            return subprocess.CompletedProcess(cmd, 0, "", "")

        with mock_attr(serve.subprocess, "run", fake_run):
            serve.adb_pull("R58M123")
        self.assertEqual(seen[0][:3], ["adb", "-s", "R58M123"])


def load_mock():
    spec = importlib.util.spec_from_file_location("mock_device", os.path.join(HERE, "mock-device.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class MockDeviceTests(unittest.TestCase):
    """pure tests on Device, no server: the log ring's capacity and sequence numbering."""

    def test_log_ring_caps_at_64_and_keeps_the_sequence_counting(self):
        mod = load_mock()
        device = mod.Device(control="c" * 64, admin="a" * 64)
        # start from an empty ring: Device.__init__ seeds 20 boot-history lines, which would make
        # the expected starting sequence below depend on that seed count rather than only on this
        # test's own 100 appends
        device.log_lines = []
        device.log_seq = 0
        for i in range(100):
            device._append_log(f"line {i}")
        self.assertEqual(len(device.log_lines), 64)
        self.assertEqual(device.log_seq, 100)
        seqs = [seq for seq, _ in device.log_lines]
        self.assertEqual(seqs, list(range(37, 101)))
        doc = device.logs(0)
        self.assertEqual(doc["lines"][0]["seq"], 37)


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

    def mock_call(self, path, body=None):
        """the mock's own control endpoints (mock/restart, mock/persist): no auth, not proxied."""
        data = json.dumps(body).encode() if body is not None else b""
        req = urllib.request.Request(f"http://127.0.0.1:{self.mock_port}/{path}", data=data,
                                     method="POST", headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read())

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

    def test_power_action_toggles_status(self):
        _, st = self.call("GET", "status")
        status, doc = self.call("POST", "action", {"action": "power", "power": False, "request_id": "d1", "epoch": st["epoch"]})
        self.assertEqual((status, doc["status"]), (200, "applied"))
        _, st2 = self.call("GET", "status")
        self.assertEqual(st2["power"], False)
        status, doc = self.call("POST", "action", {"action": "power", "power": True, "request_id": "d2", "epoch": st2["epoch"]})
        self.assertEqual((status, doc["status"]), (200, "applied"))
        _, st3 = self.call("GET", "status")
        self.assertEqual(st3["power"], True)

    def test_input_is_validated_and_applied(self):
        _, st = self.call("GET", "status")
        status, doc = self.call("POST", "input", {"control": "left", "event": "click", "request_id": "e1", "epoch": st["epoch"]})
        self.assertEqual((status, doc["status"]), (200, "applied"))
        _, st2 = self.call("GET", "status")
        self.assertEqual(st2["base"], "clock")
        # pin brightness to a known value first, so the rotary assertion below actually proves the
        # ±5-per-step math rather than clamping silently at the already-maxed-out 100
        status, doc = self.call("POST", "action", {"action": "brightness", "brightness": 50, "request_id": "e6", "epoch": st2["epoch"]})
        self.assertEqual((status, doc["status"]), (200, "applied"))
        status, doc = self.call("POST", "input", {"control": "rotary", "event": "cw", "steps": 2, "request_id": "e2", "epoch": st2["epoch"]})
        self.assertEqual((status, doc["status"]), (200, "applied"))
        _, st3 = self.call("GET", "status")
        self.assertEqual(st3["brightness"], 60)
        status, doc = self.call("POST", "input", {"control": "left", "event": "long", "request_id": "e3", "epoch": st3["epoch"]})
        self.assertEqual((status, doc["error"]), (400, "invalid_event"))
        status, doc = self.call("POST", "input", {"control": "rotary", "event": "cw", "steps": 17, "request_id": "e4", "epoch": st3["epoch"]})
        self.assertEqual((status, doc["error"]), (400, "invalid_steps"))
        status, doc = self.call("POST", "input", {"control": "nope", "event": "click", "request_id": "e5", "epoch": st3["epoch"]})
        self.assertEqual((status, doc["error"]), (400, "invalid_control"))
        status, doc = self.call("POST", "input", {"control": "middle", "event": "click", "steps": 2, "request_id": "e7", "epoch": st3["epoch"]})
        self.assertEqual((status, doc["error"]), (400, "invalid_steps"))
        # switch to art and confirm cw moves the generator there, not the brightness
        status, doc = self.call("POST", "input", {"control": "middle", "event": "click", "request_id": "e8", "epoch": st3["epoch"]})
        self.assertEqual((status, doc["status"]), (200, "applied"))
        _, st4 = self.call("GET", "status")
        self.assertEqual(st4["base"], "art")
        generator_before = st4["generator"]
        status, doc = self.call("POST", "input", {"control": "rotary", "event": "cw", "request_id": "e9", "epoch": st4["epoch"]})
        self.assertEqual((status, doc["status"]), (200, "applied"))
        _, st5 = self.call("GET", "status")
        self.assertNotEqual(st5["generator"], generator_before)
        self.assertEqual(st5["brightness"], st4["brightness"])

    def test_status_carries_a_total_for_every_used_figure(self):
        # a bar needs a denominator: the runtime reports memory, tmpfs and flash as used and total
        # (RUNTIME.md, "what it samples")
        _, st = self.call("GET", "status")
        for key in ("memory_available_kb", "memory_total_kb", "tmpfs_total_kb", "flash_used_kb", "flash_total_kb"):
            self.assertIsInstance(st.get(key), int, key)
        self.assertGreater(st["memory_total_kb"], st["memory_available_kb"])
        self.assertGreater(st["flash_total_kb"], st["flash_used_kb"])
        self.assertGreaterEqual(st["tmpfs_total_kb"], st["tmpfs_used_kb"] or 0)
        self.assertIn(st["cpu_pct"], range(0, 101))
        self.assertIn(st["brightness"], range(1, 101))

    def test_scenes_publishes_a_parameter_table_for_every_scene(self):
        # the catalogue is what a client builds its forms from: name, kind, range or choices
        _, sc = self.call("GET", "scenes")
        self.assertEqual([g["name"] for g in sc["generators"]], ["popsquares", "plasma", "cube"])
        self.assertEqual([p["name"] for p in sc["parameters"]["art"]], ["scene"])
        self.assertEqual([p["name"] for p in sc["parameters"]["clock"]],
                         ["face", "colour", "shade", "colour 2", "gradient", "spread", "digits"])
        # ip stopped being a base scene (it is a page of the device menu now), so it has no
        # parameter table any more. its four layouts are still published as their own block,
        # which is what the console's layout select reads
        self.assertNotIn("ip", sc["parameters"])
        self.assertEqual(sorted(sc["parameters"]), sorted(sc["bases"]))
        self.assertEqual(sc["ip"]["modes"], ["lines", "mini", "scroll", "big"])
        spread = next(p for p in sc["parameters"]["clock"] if p["name"] == "spread")
        self.assertEqual((spread["kind"], spread["min"], spread["max"], spread["step"]), ("number", 0, 255, 15))
        cube = next(g for g in sc["generators"] if g["name"] == "cube")
        self.assertEqual([p["name"] for p in cube["parameters"]],
                         ["palette", "colour", "hue drift", "background", "spin", "speed", "zoom"])
        # popsquares declares the processing sketch's sliders; plasma still declares none of its
        # own. this used to assert that popsquares declared nothing, which was true of the
        # hand-typed catalogue in mock-device.py and had not been true of the runtime for a while
        pops = next(g for g in sc["generators"] if g["name"] == "popsquares")
        self.assertEqual([p["name"] for p in pops["parameters"]],
                         ["pop ms", "alive", "dim chance", "dim floor", "dim ceiling", "tint", "tint colour"])
        self.assertEqual(next(g for g in sc["generators"] if g["name"] == "plasma")["parameters"], [])
        self.assertEqual(sc["clock"]["spread"], [0, 255])

    def test_scenes_is_served_verbatim_from_the_generated_catalogue(self):
        # the mock does not have a catalogue of its own: it serves what `zig build scenes` wrote
        # from the runtime's comptime tables, so the two cannot disagree
        with open(os.path.join(HERE, "scenes.json"), encoding="utf-8") as f:
            generated = json.load(f)
        _, sc = self.call("GET", "scenes")
        self.assertEqual(sc, generated)

    def test_status_reports_the_art_seed_and_reseed_changes_it(self):
        # the console runs the same generators in its preview; without the seed it cannot
        # reproduce what the panel is drawing, only the algorithm
        _, before = self.call("GET", "status")
        self.assertIsInstance(before["seed"], int)
        self.assertGreaterEqual(before["seed"], 0)
        self.assertLessEqual(before["seed"], 0xffffffff)

        status, _ = self.call("POST", "action", {"action": "reseed", "seed": 123456,
                                                 "request_id": "5e1", "epoch": before["epoch"]})
        self.assertEqual(status, 200)
        _, named = self.call("GET", "status")
        self.assertEqual(named["seed"], 123456)

        self.call("POST", "action", {"action": "reseed", "request_id": "5e2", "epoch": before["epoch"]})
        _, random_seed = self.call("GET", "status")
        self.assertNotEqual(random_seed["seed"], 123456, "a reseed with no seed should pick one")

        status, doc = self.call("POST", "action", {"action": "reseed", "seed": -1,
                                                   "request_id": "5e3", "epoch": before["epoch"]})
        self.assertEqual((status, doc["error"]), (400, "invalid_seed"))

    def test_the_three_buttons_select_the_first_three_bases_in_order(self):
        # the base enum is numbered in the panel's own left/middle/right order, so the buttons
        # read it positionally rather than naming a base that may retire (right was `ip`)
        _, sc = self.call("GET", "scenes")
        _, st = self.call("GET", "status")
        for control, index in (("left", 0), ("middle", 1), ("right", 2)):
            self.call("POST", "input", {"control": control, "event": "click",
                                        "request_id": f"6{index}", "epoch": st["epoch"]})
            _, now = self.call("GET", "status")
            self.assertEqual(now["base"], sc["bases"][index],
                             f"the {control} button should select {sc['bases'][index]}")

    def test_clock_spread_is_both_a_setting_and_a_transient_scene_field(self):
        _, cfg = self.call("GET", "config")
        status, doc = self.call("PATCH", "config", {"clock_spread": 120, "expected_revision": cfg["revision"]})
        self.assertEqual((status, doc["clock"]["spread"]), (200, 120))
        _, st = self.call("GET", "status")
        self.assertEqual(st["clock"]["spread"], 120)
        status, _ = self.call("PUT", "scene", {"base": "clock", "clock": {"spread": 30},
                                               "request_id": "5b1", "epoch": st["epoch"]})
        self.assertEqual(status, 200)
        _, st2 = self.call("GET", "status")
        self.assertEqual(st2["clock"]["spread"], 30)
        _, cfg2 = self.call("GET", "config")
        self.assertEqual(cfg2["clock"]["spread"], 120)   # the durable default is untouched
        # spread is a u8 on the wire, so anything outside 0..255 is refused
        status, _ = self.call("PUT", "scene", {"base": "clock", "clock": {"spread": 300},
                                               "request_id": "5b2", "epoch": st2["epoch"]})
        self.assertEqual(status, 400)
        status, _ = self.call("PATCH", "config", {"clock_spread": -1})
        self.assertEqual(status, 400)

    def test_clock_digits_is_a_clock_parameter_on_both_routes(self):
        # the settings call it clock_digit and the scene block calls it digits; the device reports
        # the effective one in the clock object like every other field
        _, sc = self.call("GET", "scenes")
        digits = next(p for p in sc["parameters"]["clock"] if p["name"] == "digits")
        self.assertEqual((digits["kind"], digits["choices"]), ("choice", ["solid", "outline", "shadow"]))
        _, st = self.call("GET", "status")
        self.assertEqual(st["clock"]["digits"], "solid")
        status, _ = self.call("PUT", "scene", {"base": "clock", "clock": {"digits": "outline"},
                                               "request_id": "d19", "epoch": st["epoch"]})
        self.assertEqual(status, 200)
        _, st2 = self.call("GET", "status")
        self.assertEqual(st2["clock"]["digits"], "outline")
        status, doc = self.call("PUT", "scene", {"base": "clock", "clock": {"digits": "embossed"},
                                                 "request_id": "d1a", "epoch": st2["epoch"]})
        self.assertEqual((status, doc["error"]), (400, "invalid_digits"))
        _, cfg = self.call("GET", "config")
        status, doc = self.call("PATCH", "config", {"clock_digit": "shadow", "expected_revision": cfg["revision"]})
        self.assertEqual((status, doc["clock"]["digits"]), (200, "shadow"))
        _, st3 = self.call("GET", "status")
        self.assertEqual(st3["clock"]["digits"], "shadow")   # a settings change replaces the transient style
        status, doc = self.call("PATCH", "config", {"clock_digit": "embossed"})
        self.assertEqual((status, doc["error"]), (400, "invalid_digits"))

    CUBE_DEFAULTS = {"palette": "mono", "colour": "30a0ff", "hue drift": 0, "background": "000000",
                     "spin": "parallel", "speed": 6, "zoom": 100}
    POPSQUARES_DEFAULTS = {"pop ms": 2000, "alive": 100, "dim chance": 25, "dim floor": 0,
                           "dim ceiling": 100, "tint": 15, "tint colour": "3a6ea5"}

    def test_generator_parameters_read_as_an_object_and_write_as_a_list(self):
        # asymmetric on purpose: an object keyed by the scene's own names to read, a list to write,
        # because a strict parser cannot know a scene's names in advance
        _, cfg = self.call("GET", "config")
        self.assertEqual(cfg["generators"]["popsquares"], self.POPSQUARES_DEFAULTS)
        self.assertEqual(cfg["generators"]["plasma"], {})
        self.assertEqual(cfg["generators"]["cube"], self.CUBE_DEFAULTS)
        status, doc = self.call("PATCH", "config", {"generator_params": [
            {"scene": "cube", "name": "zoom", "value": "150"},
            {"scene": "cube", "name": "palette", "value": "poly"},
        ]})
        self.assertEqual(status, 200)
        self.assertEqual(doc["generators"]["cube"]["zoom"], 150)
        self.assertEqual(doc["generators"]["cube"]["palette"], "poly")
        self.assertEqual(doc["revision"], cfg["revision"] + 1)   # one patch, one revision
        self.assertEqual(doc["revision"], doc["saved_revision"])

    def test_a_refused_generator_parameter_writes_nothing(self):
        _, before = self.call("GET", "config")
        for entry, code in (({"scene": "nope", "name": "zoom", "value": "1"}, "invalid_scene"),
                            ({"scene": "cube", "name": "nope", "value": "1"}, "invalid_param"),
                            ({"scene": "cube", "name": "zoom", "value": "9999"}, "invalid_param_value"),
                            ({"scene": "cube", "name": "zoom", "value": "wide"}, "invalid_param_value"),
                            ({"scene": "cube", "name": "palette", "value": "mauve"}, "invalid_param_value"),
                            ({"scene": "cube", "name": "colour", "value": "teal"}, "invalid_param_value")):
            status, doc = self.call("PATCH", "config", {"generator_params": [entry]})
            self.assertEqual((status, doc["error"]), (400, code), entry)
        # a good entry beside a bad one writes neither
        status, doc = self.call("PATCH", "config", {"generator_params": [
            {"scene": "cube", "name": "speed", "value": "9"},
            {"scene": "cube", "name": "zoom", "value": "9999"},
        ]})
        self.assertEqual((status, doc["error"]), (400, "invalid_param_value"))
        status, doc = self.call("PATCH", "config", {"generator_params":
                                                    [{"scene": "cube", "name": "zoom", "value": "90"}] * 9})
        self.assertEqual((status, doc["error"]), (400, "too_many_params"))
        _, after = self.call("GET", "config")
        self.assertEqual(after["generators"], before["generators"])
        self.assertEqual(after["revision"], before["revision"])

    def test_generator_parameters_take_every_kind(self):
        status, doc = self.call("PATCH", "config", {"generator_params": [
            {"scene": "cube", "name": "colour", "value": "#ff8000"},
            {"scene": "cube", "name": "background", "value": "101010"},
            {"scene": "cube", "name": "spin", "value": "single"},
            {"scene": "cube", "name": "hue drift", "value": "30"},
        ]})
        self.assertEqual(status, 200)
        cube = doc["generators"]["cube"]
        self.assertEqual(cube["colour"], "ff8000")          # hex without the hash, as a patch sends it
        self.assertEqual(cube["background"], "101010")
        self.assertEqual(cube["spin"], "single")
        self.assertEqual(cube["hue drift"], 30)

    def test_config_carries_the_night_schedule_and_where_the_device_is(self):
        _, cfg = self.call("GET", "config")
        self.assertEqual(cfg["night"], {"enabled": False, "brightness": 5, "lead_min": 30})
        self.assertIsNone(cfg["latitude"])
        self.assertIsNone(cfg["longitude"])
        # with no pin the location comes from the timezone, and says so
        self.assertEqual(cfg["location"]["source"], "timezone")
        status, doc = self.call("PATCH", "config", {"night": True, "night_brightness": 8, "night_lead_min": 45,
                                                    "latitude": -33.87, "longitude": 151.215})
        self.assertEqual(status, 200)
        self.assertEqual(doc["night"], {"enabled": True, "brightness": 8, "lead_min": 45})
        self.assertAlmostEqual(doc["latitude"], -33.87, places=2)
        self.assertEqual(doc["location"]["source"], "set")
        self.assertAlmostEqual(doc["location"]["longitude"], 151.215, places=2)
        # location_auto drops the pin and hands the timezone's point back
        status, doc = self.call("PATCH", "config", {"location_auto": True})
        self.assertEqual(status, 200)
        self.assertIsNone(doc["latitude"])
        self.assertEqual(doc["location"]["source"], "timezone")
        self.call("PATCH", "config", {"night": False, "night_brightness": 5, "night_lead_min": 30})

    def test_the_night_schedule_refuses_what_it_cannot_use(self):
        for body, code in (({"night_brightness": 0}, "invalid_night_brightness"),
                           ({"night_brightness": 101}, "invalid_night_brightness"),
                           ({"night_lead_min": 121}, "invalid_night_lead"),
                           ({"latitude": 10}, "invalid_location"),
                           ({"longitude": 10}, "invalid_location"),
                           ({"latitude": 91, "longitude": 0}, "invalid_latitude"),
                           ({"latitude": 0, "longitude": 181}, "invalid_longitude")):
            status, doc = self.call("PATCH", "config", body)
            self.assertEqual((status, doc["error"]), (400, code), body)

    def test_status_reports_the_phase_and_the_sun_s_own_day(self):
        self.call("PATCH", "config", {"night": True, "latitude": 52.37, "longitude": 4.90})
        try:
            _, st = self.call("GET", "status")
            self.assertEqual(st["night"]["enabled"], True)
            self.assertIn(st["night"]["phase"], ("day", "to_night", "night", "to_day"))
            self.assertIs(st["night"]["held"], False)
            today = st["night"]["today"]
            self.assertIn(today["sun_up"], (True, False))
            crossings = [today[k] for k in ("dawn", "sunrise", "sunset", "dusk")]
            self.assertEqual(crossings, sorted(crossings), "the day runs dawn, sunrise, sunset, dusk")
            for t in crossings:
                self.assertGreater(t, 1_700_000_000)
            # a hand-set brightness stands in the schedule's way until the next ramp
            _, st2 = self.call("GET", "status")
            self.call("POST", "action", {"action": "brightness", "brightness": 42,
                                         "request_id": "9a1", "epoch": st2["epoch"]})
            _, st3 = self.call("GET", "status")
            self.assertIs(st3["night"]["held"], True)
        finally:
            self.call("PATCH", "config", {"night": False, "location_auto": True})
        _, off = self.call("GET", "status")
        self.assertEqual(off["night"]["enabled"], False)
        self.assertIsNone(off["night"]["phase"])

    def test_logs_page_through_the_ring(self):
        status, doc = self.call("GET", "logs?after=0")
        self.assertEqual(status, 200)
        self.assertIn("next", doc)
        self.assertLessEqual(len(doc["lines"]), 16)
        for line in doc["lines"]:
            self.assertIn("seq", line)
            self.assertIn("text", line)
        status2, doc2 = self.call("GET", f"logs?after={doc['next']}")
        self.assertEqual(status2, 200)
        if doc["lines"]:
            last_seq = doc["lines"][-1]["seq"]
            self.assertTrue(all(l["seq"] > last_seq for l in doc2["lines"]))
        # a missing after defaults to 0, per RUNTIME.md / api.zig, not a 400
        status3, doc3 = self.call("GET", "logs")
        self.assertEqual(status3, 200)
        self.assertEqual(doc3["lines"], doc["lines"])
        status4, doc4 = self.call("GET", "logs?after=abc")
        self.assertEqual((status4, doc4["error"]), (400, "invalid_after"))

    def test_screen_is_not_served_by_the_mock(self):
        status, doc = self.call("GET", "screen")
        self.assertEqual((status, doc["error"]), (404, "not_found"))

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

    DEFAULT_CLOCK = {"font": "classic", "colour_mode": "solid", "colour": "ffffff", "colour2": "ffffff",
                     "gradient": "horizontal", "spread": 255, "digits": "solid"}

    def test_ntfy_settings_round_trip_without_secrets(self):
        status, doc = self.call("PUT", "ntfy", {"enabled": True, "url": "https://ntfy.sh", "topic": "tc002", "token": "tk_x", "duration_s": 8})
        self.assertEqual(status, 200)
        self.assertEqual((doc["enabled"], doc["url"], doc["topic"], doc["token_set"], doc["duration_s"]), (True, "https://ntfy.sh", "tc002", True, 8))
        self.assertNotIn("token", doc)
        self.assertEqual(doc["status"]["state"], "subscribed")
        status, doc = self.call("PUT", "ntfy", {"url": "ntfy.sh"})
        self.assertEqual((status, doc["error"]), (400, "invalid_url"))
        status, doc = self.call("PUT", "ntfy", {"ca": "nope"})
        self.assertEqual((status, doc["error"]), (400, "invalid_ca"))
        _, st = self.call("GET", "status")
        self.assertEqual(st["ntfy"]["state"], "subscribed")
        status, doc = self.call("PUT", "ntfy", {"enabled": False})
        self.assertEqual(doc["status"]["state"], "off")

    def test_scenes_status_and_config_carry_the_clock_style(self):
        _, scenes = self.call("GET", "scenes")
        # `digits` belongs here too: the hand-typed catalogue omitted it while validating against
        # a CLOCK_DIGITS list it kept privately, so a client could not discover the digit styles
        self.assertEqual(scenes["clock"], {"fonts": ["classic", "mini", "segment", "big", "block", "hires"], "colour_modes": ["solid", "gradient"],
                                           "digits": ["solid", "outline", "shadow"],
                                           "gradients": ["horizontal", "vertical", "diagonal"], "spread": [0, 255], "max_spread": 255})
        self.device.config["clock"] = dict(self.DEFAULT_CLOCK); self.device.clock = dict(self.DEFAULT_CLOCK)
        _, st = self.call("GET", "status")
        self.assertEqual(st["clock"], self.DEFAULT_CLOCK)
        _, cfg = self.call("GET", "config")
        self.assertEqual(cfg["clock"], self.DEFAULT_CLOCK)

    def test_scene_clock_block_is_transient_and_validated(self):
        self.device.config["clock"] = dict(self.DEFAULT_CLOCK); self.device.clock = dict(self.DEFAULT_CLOCK)
        _, st = self.call("GET", "status")
        status, doc = self.call("PUT", "scene", {"base": "clock", "clock": {"font": "big", "colour_mode": "gradient", "colour": "ff8000", "colour2": "#ffc000"},
                                                 "request_id": "f1", "epoch": st["epoch"]})
        self.assertEqual((status, doc["status"]), (200, "applied"))
        _, st2 = self.call("GET", "status")
        self.assertEqual(st2["base"], "clock")
        # a partial block merges over the current style; colour2 is reported as requested, before the spread clamp
        self.assertEqual(st2["clock"], {"font": "big", "colour_mode": "gradient", "colour": "ff8000", "colour2": "ffc000",
                                        "gradient": "horizontal", "spread": 255, "digits": "solid"})
        _, cfg = self.call("GET", "config")
        self.assertEqual(cfg["clock"], self.DEFAULT_CLOCK)   # the durable defaults are untouched
        for block, code in (({"font": "comic"}, "invalid_font"), ({"colour_mode": "rainbow"}, "invalid_colour_mode"),
                            ({"colour": "red"}, "invalid_colour"), ({"colour2": "12345"}, "invalid_colour2"),
                            ({"gradient": "radial"}, "invalid_gradient"), ({"bogus": 1}, "unknown_field")):
            status, doc = self.call("PUT", "scene", {"base": "clock", "clock": block, "request_id": "f2", "epoch": st2["epoch"]})
            self.assertEqual((status, doc["error"]), (400, code), block)
        # a settings change re-applies the full durable style, replacing the transient one
        status, doc = self.call("PATCH", "config", {"clock_font": "segment"})
        self.assertEqual(status, 200)
        _, st3 = self.call("GET", "status")
        self.assertEqual(st3["clock"], {**self.DEFAULT_CLOCK, "font": "segment"})
        # so does a renderer restart
        status, doc = self.call("PUT", "scene", {"base": "clock", "clock": {"font": "mini"}, "request_id": "f3", "epoch": st3["epoch"]})
        self.assertEqual(status, 200)
        with self.device.lock:
            self.device.restart()
        _, st4 = self.call("GET", "status")
        self.assertEqual(st4["clock"]["font"], "segment")

    def test_clock_settings_patch_applies_live_and_is_validated(self):
        self.device.config["clock"] = dict(self.DEFAULT_CLOCK); self.device.clock = dict(self.DEFAULT_CLOCK)
        _, cfg = self.call("GET", "config")
        status, doc = self.call("PATCH", "config", {"expected_revision": cfg["revision"], "clock_font": "segment", "clock_colour_mode": "gradient",
                                                    "clock_colour": "00ff80", "clock_gradient": "vertical"})
        self.assertEqual(status, 200)
        want = {"font": "segment", "colour_mode": "gradient", "colour": "00ff80", "colour2": "ffffff",
                "gradient": "vertical", "spread": 255, "digits": "solid"}
        self.assertEqual(doc["clock"], want)
        self.assertEqual(doc["revision"], cfg["revision"] + 1)
        _, st = self.call("GET", "status")
        self.assertEqual(st["clock"], want)
        for body, code in (({"clock_colour_mode": "rainbow"}, "invalid_colour_mode"), ({"clock_colour2": "red"}, "invalid_colour2"),
                           ({"clock_font": "comic"}, "invalid_font"), ({"clock_gradient": "radial"}, "invalid_gradient"),
                           ({"clock_colour": "#12345g"}, "invalid_colour")):
            status, doc = self.call("PATCH", "config", body)
            self.assertEqual((status, doc["error"]), (400, code), body)
        _, cfg2 = self.call("GET", "config")
        self.assertEqual(cfg2["clock"], want)   # a rejected patch changes nothing

    def test_every_settings_write_is_persisted_before_the_reply(self):
        # the device writes each accepted change to flash before answering, so the two revisions in
        # its reply always match; the console reads that as "it is on the device"
        _, cfg = self.call("GET", "config")
        status, doc = self.call("PATCH", "config", {"brightness": 42, "expected_revision": cfg["revision"]})
        self.assertEqual(status, 200)
        self.assertEqual(doc["revision"], doc["saved_revision"])
        self.assertGreater(doc["revision"], cfg["revision"])
        _, st = self.call("GET", "status")
        self.assertEqual(st["config_revision"], st["saved_revision"])
        # broker and ntfy settings are settings writes too
        status, _ = self.call("PUT", "mqtt", {"host": "10.0.0.9"})
        self.assertEqual(status, 200)
        _, after_mqtt = self.call("GET", "config")
        self.assertEqual(after_mqtt["revision"], after_mqtt["saved_revision"])
        status, _ = self.call("PUT", "ntfy", {"topic": "persisted"})
        self.assertEqual(status, 200)
        _, after_ntfy = self.call("GET", "config")
        self.assertEqual(after_ntfy["revision"], after_ntfy["saved_revision"])
        self.assertGreater(after_ntfy["revision"], after_mqtt["revision"])

    def test_the_save_route_remains_and_is_a_no_op_when_everything_is_written(self):
        _, cfg = self.call("GET", "config")
        status, doc = self.call("POST", "config/save", {"revision": cfg["revision"]})
        self.assertEqual((status, doc["status"]), (200, "saved"))
        self.assertEqual(doc["saved_revision"], cfg["revision"])

    def test_a_failed_flash_write_leaves_the_revisions_apart(self):
        # the only way the two can differ now: the write to flash failed. the console reports that
        # as an error rather than asking for a save
        self.assertEqual(self.mock_call("mock/persist", {"enabled": False})[0], 200)
        try:
            _, cfg = self.call("GET", "config")
            status, doc = self.call("PATCH", "config", {"brightness": 44, "expected_revision": cfg["revision"]})
            self.assertEqual(status, 200)
            self.assertGreater(doc["revision"], doc["saved_revision"])
            _, st = self.call("GET", "status")
            self.assertGreater(st["config_revision"], st["saved_revision"])
        finally:
            self.mock_call("mock/persist", {"enabled": True})
        _, back = self.call("GET", "config")
        self.assertEqual(back["revision"], back["saved_revision"])


class BaseButtonTests(unittest.TestCase):
    """the console must not carry its own list of base scenes: the runtime is retiring one (ip) and
    adding another (canvas), and a hard-coded button posts a base the device now rejects."""

    def test_the_console_does_not_hard_code_the_base_scenes(self):
        with open(os.path.join(HERE, "index.html"), encoding="utf-8") as f:
            html = f.read()
        seg = html[html.index('id="base"'):]
        seg = seg[:seg.index("</div>")]
        self.assertNotIn("data-v=", seg,
                         "the base radiogroup has buttons written into the html; build them from "
                         "GET /scenes so a new or retired base needs no edit here")
        self.assertIn("fillBaseButtons(SCENES.bases", html)


class CatalogueTests(unittest.TestCase):
    """panel-v2/scenes.json is generated from the runtime's tables; a stale copy is the exact bug
    this whole arrangement exists to stop, so it is checked rather than trusted."""

    def test_the_committed_catalogue_is_what_the_runtime_generates_now(self):
        runtime = os.path.join(os.path.dirname(HERE), "runtime")
        if not os.path.isdir(runtime):
            self.skipTest("runtime/ is not present")
        try:
            subprocess.run(["zig", "version"], capture_output=True, check=True)
        except (OSError, subprocess.CalledProcessError):
            self.skipTest("zig is not installed")
        path = os.path.join(HERE, "scenes.json")
        with open(path, "rb") as f:
            before = f.read()
        r = subprocess.run(["zig", "build", "scenes"], cwd=runtime, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, f"`zig build scenes` failed:\n{r.stderr}")
        with open(path, "rb") as f:
            after = f.read()
        self.assertEqual(before, after,
                         "panel-v2/scenes.json is stale: `zig build scenes` in runtime/ changed it. "
                         "commit the regenerated file")


class StartScriptTests(unittest.TestCase):
    def test_mock_mode_brings_up_the_mock_and_the_proxy_with_shared_tokens(self):
        import signal, subprocess, time
        with tempfile.TemporaryDirectory() as d:
            token_file = os.path.join(d, "tokens")
            # two free ports, released before the script binds them
            ports = []
            for _ in range(2):
                s = socket.socket(); s.bind(("127.0.0.1", 0)); ports.append(s.getsockname()[1]); s.close()
            proxy_port, mock_port = ports
            proc = subprocess.Popen(["/bin/bash", os.path.join(HERE, "start-panel.sh"), "--mock", "--port", str(proxy_port),
                                     "--mock-port", str(mock_port), "--token-file", token_file],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, cwd=d)
            try:
                deadline = time.monotonic() + 15
                tokens = None
                while time.monotonic() < deadline:
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{proxy_port}/tokens", timeout=1) as r:
                            tokens = json.loads(r.read())
                        break
                    except (urllib.error.URLError, ConnectionError, OSError):
                        time.sleep(0.2)
                self.assertEqual(tokens, {"control": True, "admin": True})
                self.assertEqual(os.path.getsize(token_file), 64)
                url = f"http://127.0.0.1:{proxy_port}/api/127.0.0.1:{mock_port}/v1/status"
                with urllib.request.urlopen(url, timeout=5) as r:
                    self.assertEqual(json.loads(r.read())["renderer"], "running")
            finally:
                os.killpg(proc.pid, signal.SIGTERM)
                out = proc.communicate(timeout=10)[0].decode()
            self.assertIn(f"console: http://127.0.0.1:{proxy_port}/?host=127.0.0.1:{mock_port}", out)
            # the trap stopped the mock as well: nothing listens on its port any more
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    socket.create_connection(("127.0.0.1", mock_port), timeout=1).close()
                    time.sleep(0.1)
                except ConnectionRefusedError:
                    break
            else:
                self.fail("the mock is still listening after the launcher was stopped")


if __name__ == "__main__":
    unittest.main()
