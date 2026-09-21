"""offline regression tests for discovery and explicit device selection."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("tc002_devices", ROOT / "tc002-devices.py")
devices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(devices)


def dns_name(name):
    return b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\0"


def announcement(instance, ip):
    service = "_tc002._tcp.local"
    target = dns_name(f"{instance}.{service}")
    ptr = dns_name(service) + struct.pack("!HHIH", 12, 1, 120, len(target)) + target
    address = dns_name(f"{instance}.local") + struct.pack("!HHIH", 1, 1, 120, 4) + socket.inet_aton(ip)
    return struct.pack("!HHHHHH", 0, 0x8400, 0, 2, 0, 0) + ptr + address


def adb_result(args, **kwargs):
    if args[1:] == ["devices"]:
        output = "List of devices attached\n10.0.0.111:5555\tdevice\n"
    elif args[-1] == "cat /sys/class/net/wlan0/address":
        output = "aa:bb:cc:dd:ee:ff\n"
    elif args[-1] == "ifconfig wlan0":
        output = "inet addr:10.0.0.111\n"
    else:
        output = "/res/bin/tc002-supervisor\n"
    return subprocess.CompletedProcess(args, 0, stdout=output, stderr="")


class DiscoveryTests(unittest.TestCase):
    def run_main(self, sock, argv=("--json",), adb=adb_result):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(devices.socket, "socket", return_value=sock), \
             patch.object(devices.time, "sleep"), \
             patch.object(devices.subprocess, "run", side_effect=adb), \
             patch.object(sys, "argv", ["tc002-devices.py", "--no-listen", *argv]), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            # --no-listen: one mock socket cannot serve two listening threads; BroadcastTests
            # covers the udp/55555 listener on its own
            result = devices.main()
        return result, stdout.getvalue(), stderr.getvalue()

    def test_first_send_failure_keeps_adb_fallback_and_closes_socket(self):
        sock = Mock()
        sock.sendto.side_effect = OSError("network unavailable")
        result, output, _ = self.run_main(sock)
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output)[0]["mac"], "aa:bb:cc:dd:ee:ff")
        sock.close.assert_called_once()

    def test_socket_setup_failure_keeps_adb_fallback_and_closes_socket(self):
        sock = Mock()
        sock.setsockopt.side_effect = OSError("network unavailable")
        result, output, _ = self.run_main(sock)
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output)[0]["ip"], "10.0.0.111")
        sock.close.assert_called_once()

    def test_socket_creation_failure_keeps_adb_fallback(self):
        stdout = io.StringIO()
        with patch.object(devices.socket, "socket", side_effect=OSError("unavailable")), \
             patch.object(devices.subprocess, "run", side_effect=adb_result), \
             patch.object(sys, "argv", ["tc002-devices.py", "--json"]), \
             contextlib.redirect_stdout(stdout):
            self.assertEqual(devices.main(), 0)
        self.assertEqual(len(json.loads(stdout.getvalue())), 1)

    def test_merging_adb_keeps_mdns_hostname(self):
        sock = Mock()
        sock.recvfrom.side_effect = [(announcement("tc002-ddeeff", "10.0.0.111"), ("10.0.0.111", 5353)), OSError()]
        def usb_adb(args, **kwargs):
            result = adb_result(args, **kwargs)
            if args[1:] == ["devices"]:
                result.stdout = "List of devices attached\nusb-clock\tdevice\n"
            return result

        result, output, _ = self.run_main(sock, adb=usb_adb)
        self.assertEqual(result, 0)
        rows = json.loads(output)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].get("name"), "tc002-ddeeff.local")
        self.assertEqual(rows[0]["mac"], "aa:bb:cc:dd:ee:ff")
        self.assertEqual(rows[0]["transport"], "usb-clock")

    def test_duplicate_instance_at_two_addresses_remains_ambiguous(self):
        for argv in [("--json",), ("--one",)]:
            with self.subTest(argv=argv):
                sock = Mock()
                sock.recvfrom.side_effect = [
                    (announcement("tc002-ddeeff", ip), (ip, 5353))
                    for ip in ("10.0.0.111", "10.0.0.112")
                ] + [OSError()]
                no_adb = lambda args, **kwargs: subprocess.CompletedProcess(args, 0, stdout="List of devices attached\n", stderr="")
                result, output, error = self.run_main(sock, argv, no_adb)
                if argv == ("--json",):
                    self.assertEqual(result, 0)
                    self.assertEqual({r["ip"] for r in json.loads(output)}, {"10.0.0.111", "10.0.0.112"})
                else:
                    self.assertEqual(result, 2)
                    self.assertEqual(output, "")
                    self.assertIn("found 2 devices", error)


    def test_runtime_from_tmp_is_a_runtime_when_mdns_says_so(self):
        # describe_adb only looked for the flashed /res/bin binary, and the adb row won the merge,
        # so a /tmp-run runtime answering _tc002._tcp was reported as stock.
        sock = Mock()
        sock.recvfrom.side_effect = [(announcement("tc002-aabbccddeeff", "10.0.0.111"), ("10.0.0.111", 5353)), OSError()]
        def stock_looking_adb(args, **kwargs):
            result = adb_result(args, **kwargs)
            if args[-1].startswith("ls "):
                result.stdout = ""
            return result
        result, output, _ = self.run_main(sock, adb=stock_looking_adb)
        self.assertEqual(result, 0)
        rows = json.loads(output)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["kind"], "runtime")
        self.assertEqual(rows[0]["name"], "tc002-aabbccddeeff.local")

    def test_describe_adb_sees_a_runtime_in_tmp(self):
        def tmp_runtime_adb(args, **kwargs):
            result = adb_result(args, **kwargs)
            if args[-1].startswith("ls "):
                result.stdout = "/tmp/tc002/tc002-supervisor\n" if "/tmp/tc002" in args[-1] else ""
            return result
        with patch.object(devices.subprocess, "run", side_effect=tmp_runtime_adb):
            self.assertEqual(devices.describe_adb("10.0.0.111:5555")["kind"], "runtime")

    def test_merge_is_independent_of_arrival_order(self):
        mdns_row = {"transport": "10.0.0.111:5555", "ip": "10.0.0.111", "mac": "", "kind": "runtime", "name": "tc002-aabbccddeeff.local"}
        adb_row = {"transport": "usb-clock", "ip": "10.0.0.111", "mac": "aa:bb:cc:dd:ee:ff", "kind": "stock"}
        for order in ([mdns_row, adb_row], [adb_row, mdns_row]):
            with self.subTest(first=order[0]["transport"]):
                out = devices.merge_rows(order)
                self.assertEqual(len(out), 1)
                self.assertEqual(out[0]["transport"], "usb-clock")
                self.assertEqual(out[0]["mac"], "aa:bb:cc:dd:ee:ff")
                self.assertEqual(out[0]["name"], "tc002-aabbccddeeff.local")
                self.assertEqual(out[0]["kind"], "runtime")

    def test_mdns_query_stops_after_a_quiet_gap(self):
        sock = Mock()
        sock.recvfrom.side_effect = [(announcement("tc002-aabbccddeeff", "10.0.0.111"), ("10.0.0.111", 5353))] + [socket.timeout()] * 100000
        with patch.object(devices.socket, "socket", return_value=sock), patch.object(devices.time, "sleep"):
            started = devices.time.time()
            found = devices.mdns_query(timeout=5.0, quiet=0.2)
        self.assertEqual({d["ip"] for d in found.values()}, {"10.0.0.111"})
        self.assertLess(devices.time.time() - started, 2.0)

    def test_mdns_query_asks_on_every_interface(self):
        sock = Mock()
        sock.recvfrom.side_effect = OSError()
        with patch.object(devices.socket, "socket", return_value=sock), patch.object(devices.time, "sleep"), \
             patch.object(devices, "_local_ipv4s", return_value=["10.0.0.5", "192.168.1.5"]):
            devices.mdns_query()
        joins = [c.args[2] for c in sock.setsockopt.call_args_list if c.args[1] == socket.IP_ADD_MEMBERSHIP]
        self.assertEqual(joins, [socket.inet_aton("224.0.0.251") + socket.inet_aton(ip) for ip in ("10.0.0.5", "192.168.1.5")])
        outbound = [c.args[2] for c in sock.setsockopt.call_args_list if c.args[1] == socket.IP_MULTICAST_IF]
        self.assertEqual(outbound, [socket.inet_aton("10.0.0.5"), socket.inet_aton("192.168.1.5")])
        self.assertEqual(sock.sendto.call_count, 2)

    def test_one_lists_the_mdns_name_when_ambiguous(self):
        sock = Mock()
        sock.recvfrom.side_effect = [
            (announcement(inst, ip), (ip, 5353))
            for inst, ip in (("tc002-aabbccddeeff", "10.0.0.111"), ("tc002-aabbccddee00", "10.0.0.112"))
        ] + [OSError()]
        no_adb = lambda args, **kwargs: subprocess.CompletedProcess(args, 0, stdout="List of devices attached\n", stderr="")
        result, output, error = self.run_main(sock, ("--one",), no_adb)
        self.assertEqual(result, 2)
        self.assertIn("tc002-aabbccddeeff.local", error)
        self.assertIn("tc002-aabbccddee00.local", error)


FAKE_ADB = """#!{py}
import json, os, pathlib, sys
with open(os.environ["TEST_ADB_LOG"], "a") as log:
    log.write(json.dumps({{"command": pathlib.Path(sys.argv[0]).name, "args": sys.argv[1:], "device": os.environ.get("TC002_DEVICE")}}) + "\\n")
if sys.argv[-1] == "get-state":
    state = pathlib.Path(os.environ["TEST_ADB_LOG"] + ".state")
    if not state.exists():
        state.touch()
        sys.exit(1)
if len(sys.argv) > 3 and sys.argv[3] == "pull":
    pathlib.Path(sys.argv[-1]).touch()
if sys.argv[-1] == "ps":
    print("1234 root tc002-supervisor")
"""

FAKE_CURL = """#!{py}
import json, os, sys
with open(os.environ["TEST_ADB_LOG"], "a") as log:
    log.write(json.dumps({{"command": "curl", "args": sys.argv[1:], "device": os.environ.get("TC002_DEVICE")}}) + "\\n")
if "/status" in " ".join(sys.argv):
    print('{{"base":"art","generator":"plasma"}}')
else:
    print('{{"applied":1}}')
"""

FAKE_CTL = """#!{py}
import json, os, pathlib, sys
with open(os.environ["TEST_ADB_LOG"], "a") as log:
    log.write(json.dumps({{"command": "tc002ctl.py", "args": sys.argv[1:], "device": os.environ.get("TC002_DEVICE")}}) + "\\n")
print("{{}}")
"""


def fake_checkout(directory, payload=b"\x7fELF the supervisor, built for /tmp/tc002"):
    """a checkout with the update script, a fake adb and a fake payload, for driving the script
    without a device or a compiler. returns (root, bindir, log)."""
    root = Path(directory)
    tools = root / "runtime" / "tools"
    tools.mkdir(parents=True)
    bindir = root / "bin"
    bindir.mkdir()
    for name in ("tc002-update.sh", "tc002-up.sh", "tc002-lock.sh", "tc002-notice.sh"):
        shutil.copyfile(ROOT / "runtime/tools" / name, tools / name)
        (tools / name).chmod(0o755)
    shutil.copyfile(ROOT / "runtime/tools/tc002-run.sh", tools / "tc002-run.sh.real")
    (tools / "tc002-run.sh.real").chmod(0o755)
    payload_dir = root / "runtime" / "zig-out" / "bin"
    payload_dir.mkdir(parents=True)
    (payload_dir / "tc002-supervisor").write_bytes(payload)
    log = root / "calls.jsonl"
    (root / "tokens").write_text("control=" + "a" * 64 + "\nadmin=" + "b" * 64 + "\n")
    fake = FAKE_ADB.format(py=sys.executable)
    for path, content in [(bindir / "adb", fake), (tools / "tc002-run.sh", fake),
                          (bindir / "sleep", "#!/bin/sh\nexit 0\n"),
                          (bindir / "curl", FAKE_CURL.format(py=sys.executable)),
                          (tools / "tc002ctl.py", FAKE_CTL.format(py=sys.executable))]:
        path.write_text(content)
        path.chmod(0o755)
    return root, bindir, log


def run_update(root, bindir, log, *args, script="tc002-update.sh"):
    env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", TEST_ADB_LOG=str(log), CURL=str(bindir / "curl"))
    env.pop("TC002_DEVICE", None)
    return subprocess.run(["/bin/bash", str(root / "runtime" / "tools" / script), *args],
                          env=env, text=True, capture_output=True)


class UpdateScriptTests(unittest.TestCase):
    def test_a_mode_is_required_and_the_usage_names_both(self):
        with tempfile.TemporaryDirectory() as d:
            root, bindir, log = fake_checkout(d)
            r = run_update(root, bindir, log, "--device", "10.0.0.5")
            self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
            self.assertIn("--in-place", r.stderr)
            self.assertIn("--flash", r.stderr)
            self.assertIn("reboot", r.stderr)
            r = run_update(root, bindir, log, "--in-place", "--flash", "--device", "10.0.0.5")
            self.assertEqual(r.returncode, 2)

    def test_in_place_refuses_a_payload_built_for_flash(self):
        # the two modes need different builds (the flashed supervisor has /res/bin compiled in),
        # and they share zig-out, so pushing the wrong one must be refused rather than discovered
        # on the panel as a crash loop
        with tempfile.TemporaryDirectory() as d:
            root, bindir, log = fake_checkout(d, payload=b"\x7fELF built with /res/bin compiled in")
            r = run_update(root, bindir, log, "--in-place", "--device", "10.0.0.5", "--no-build", "--keep-settings")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("/res/bin", r.stderr)
            self.assertFalse(log.exists() and any('"push"' in line for line in log.read_text().splitlines()))

    def test_in_place_normalizes_the_device_and_writes_a_token_file_per_host(self):
        for given, expected in [("10.0.0.111", "10.0.0.111:5555"),
                                ("tc002-ddeeff.local", "tc002-ddeeff.local:5555"),
                                ("10.0.0.111:5556", "10.0.0.111:5556")]:
            with self.subTest(device=given), tempfile.TemporaryDirectory() as d:
                root, bindir, log = fake_checkout(d)
                r = run_update(root, bindir, log, "--in-place", "--device", given, "--no-build", "--keep-settings")
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                adb_calls = [c for c in calls if c["command"] == "adb"]
                self.assertIn(["connect", expected], [c["args"] for c in adb_calls])
                for c in adb_calls:
                    if c["args"][0] != "connect":
                        self.assertEqual(c["args"][:2], ["-s", expected])
                self.assertTrue(any(c["command"] == "tc002-run.sh" for c in calls))
                self.assertEqual({c["device"] for c in calls}, {expected})
                self.assertTrue((root / "tokens").exists())
                self.assertTrue((root / f"tokens-{given.split(':')[0]}").exists(), sorted(os.listdir(root)))
                self.assertIn("no reboot", r.stdout)
                # every update puts "updating" on the panel before the panel is taken away: the
                # notice goes out before the running runtime is stopped
                # the notice is the flasher's: the canvas base, mini face, pulsing, and it goes up
                # before the copy so it pulses while the binaries arrive
                notices = [i for i, c in enumerate(calls) if c["command"] == "curl" and "/canvas" in " ".join(c["args"])
                           and '"font":"mini"' in " ".join(c["args"]) and '"kind":"pulse"' in " ".join(c["args"])]
                self.assertTrue(notices, "no mini-font pulsing notice was drawn")
                pushes = [i for i, c in enumerate(calls) if c["command"] == "tc002-run.sh" and c["args"][:2] == ["push", "--staged"]]
                halts = [i for i, c in enumerate(calls) if c["command"] == "tc002-run.sh" and c["args"][:1] == ["halt"]]
                stops = [i for i, c in enumerate(calls) if c["command"] == "tc002-run.sh" and c["args"][:1] == ["stop"]]
                self.assertTrue(pushes, "the binaries are staged beside the running runtime, not over it")
                # notice, then the staged copy while it pulses, then the halt that swaps it in
                self.assertTrue(halts and notices[0] < pushes[0] < halts[0], (notices, pushes, halts))
                self.assertFalse(stops, "an in-place update must not hand the panel back between runtimes")
                # and the scene the clock was showing is put back once the new runtime is up
                restores = [i for i, c in enumerate(calls) if c["command"] == "curl" and "/scene" in " ".join(c["args"]) and '"base":"art"' in " ".join(c["args"])]
                self.assertTrue(restores and restores[-1] > halts[0], (restores, halts))

    def test_the_old_bring_up_script_is_the_in_place_mode(self):
        with tempfile.TemporaryDirectory() as d:
            root, bindir, log = fake_checkout(d)
            r = run_update(root, bindir, log, "--device", "10.0.0.7", "--no-build", "--keep-settings", script="tc002-up.sh")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertTrue((root / "tokens-10.0.0.7").exists())


class RunScriptTests(unittest.TestCase):
    def test_halt_kills_the_runtime_without_a_black_frame_or_a_hand_back(self):
        # `stop` sends sigterm (a paced black frame) and restarts zkswe; `halt` is for an update:
        # the frame on the glass stays until the next runtime draws, and nothing else is started
        with tempfile.TemporaryDirectory() as d:
            root, bindir, log = fake_checkout(d)
            env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", TEST_ADB_LOG=str(log),
                       TC002_LOCK_FILE=str(root / "lock.txt"), TC002_DEVICE="10.0.0.7:5555")
            Path(str(log) + ".state").touch()   # the fake adb's first get-state fails, as a real cold one does
            r = subprocess.run(["/bin/bash", str(root / "runtime/tools/tc002-run.sh.real"), "halt"],
                               env=env, text=True, capture_output=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            shells = [" ".join(c["args"]) for c in map(json.loads, log.read_text().splitlines()) if c["command"] == "adb" and "shell" in c["args"]]
            self.assertTrue(any("kill -KILL" in s or "kill -9" in s for s in shells), shells)
            self.assertFalse(any("TERM" in s for s in shells), shells)
            self.assertFalse(any("ctl.start zkswe" in s for s in shells), shells)
            # a staged directory, if any, is swapped in by renames after the kill
            self.assertTrue(any("/tmp/tc002.new" in s and "mv" in s for s in shells), shells)

    def test_a_staged_push_lands_beside_the_running_runtime(self):
        with tempfile.TemporaryDirectory() as d:
            root, bindir, log = fake_checkout(d)
            for name in ("tc002-supervisor", "tc002d", "tc002-netd", "tc002-ntfy", "tc002-berryd", "tc002-audiod"):
                (root / "runtime" / "zig-out" / "bin" / name).write_bytes(b"\x7fELF")
                (root / "runtime" / "zig-out" / "bin" / name).chmod(0o755)
            (root / "runtime" / "zig-out" / "lib").mkdir()
            (root / "runtime" / "zig-out" / "lib" / "libtc002-bootstrap.so").write_bytes(b"\x7fELF")
            env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", TEST_ADB_LOG=str(log),
                       TC002_LOCK_FILE=str(root / "lock.txt"), TC002_DEVICE="10.0.0.7:5555", TC002_NO_BUILD="1")
            Path(str(log) + ".state").touch()
            r = subprocess.run(["/bin/bash", str(root / "runtime/tools/tc002-run.sh.real"), "push", "--staged"],
                               env=env, text=True, capture_output=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            pushes = [c["args"] for c in calls if c["command"] == "adb" and "push" in c["args"]]
            self.assertTrue(pushes)
            self.assertTrue(all(a[-1].startswith("/tmp/tc002.new/") for a in pushes), pushes)


class DeviceSelectionTests(unittest.TestCase):
    def test_run_hint_names_the_variable_when_it_is_unset(self):
        # the hint was wrapped in ${TC002_DEVICE:+...}, so it showed only when the variable was
        # already set and was hidden in the exact case it was written for.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "runtime" / "tools"
            tools.mkdir(parents=True)
            bindir = root / "bin"
            bindir.mkdir()
            shutil.copyfile(ROOT / "runtime/tools/tc002-run.sh", tools / "tc002-run.sh")
            (bindir / "adb").write_text("#!/bin/sh\nexit 1\n")
            (bindir / "adb").chmod(0o755)
            env = {k: v for k, v in os.environ.items() if k != "TC002_DEVICE"}
            env["PATH"] = f"{bindir}:{env['PATH']}"
            env["TC002_NO_BUILD"] = "1"
            result = subprocess.run(["/bin/bash", str(tools / "tc002-run.sh"), "push"], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("export TC002_DEVICE", result.stderr)
            env["TC002_DEVICE"] = "10.0.0.111:5555"
            result = subprocess.run(["/bin/bash", str(tools / "tc002-run.sh"), "push"], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("at 10.0.0.111:5555", result.stderr)
            self.assertNotIn("export TC002_DEVICE", result.stderr)


class BroadcastTests(unittest.TestCase):
    """the stock firmware announces itself on udp/55555 once a second; this is the only way to
    find a stock clock without adb or a sweep, and it used to live in tc002-adopt.py."""

    def test_the_announcement_is_parsed_and_junk_is_not(self):
        d = devices.parse_broadcast(b"Ulanzi TC002 9e85:ccc4b2779e85:B0D32I008U3672679:true")
        self.assertEqual(d, {"tail": "9e85", "mac": "cc:c4:b2:77:9e:85", "serial": "B0D32I008U3672679", "flag": "true"})
        for junk in (b"", b"Ulanzi TC002", b"hello 9e85:ccc4b2779e85:sn:true", b"Ulanzi TC002 9e85:zz:sn:maybe"):
            self.assertIsNone(devices.parse_broadcast(junk), junk)

    def test_listening_hears_a_clock_and_stops_after_a_quiet_gap(self):
        payload = b"Ulanzi TC002 9e85:ccc4b2779e85:B0D32I008U3672679:true"
        sock = Mock()
        sock.recvfrom.side_effect = [(payload, ("10.0.0.9", 40001)), (payload, ("10.0.0.9", 40002))] + [socket.timeout()] * 100000
        with patch.object(devices.socket, "socket", return_value=sock):
            started = devices.time.time()
            heard = devices.listen_broadcasts(seconds=5.0, quiet=0.2)
        self.assertLess(devices.time.time() - started, 2.0)
        self.assertEqual(list(heard), ["10.0.0.9"])
        self.assertEqual(heard["10.0.0.9"]["mac"], "cc:c4:b2:77:9e:85")
        self.assertEqual(heard["10.0.0.9"]["serial"], "B0D32I008U3672679")
        sock.bind.assert_called_once_with(("0.0.0.0", 55555))

    def test_no_listen_leaves_the_broadcast_port_alone(self):
        sock = Mock()
        sock.recvfrom.side_effect = OSError()
        no_adb = lambda args, **kwargs: subprocess.CompletedProcess(args, 0, stdout="List of devices attached\n", stderr="")
        stdout = io.StringIO()
        with patch.object(devices.socket, "socket", return_value=sock), patch.object(devices.time, "sleep"), \
             patch.object(devices.subprocess, "run", side_effect=no_adb), \
             patch.object(sys, "argv", ["tc002-devices.py", "--json", "--no-listen"]), contextlib.redirect_stdout(stdout):
            devices.main()
        self.assertNotIn(("0.0.0.0", 55555), [c.args[0] for c in sock.bind.call_args_list])

    def test_a_broadcasting_stock_clock_is_listed_as_stock(self):
        heard = {"10.0.0.9": {"ip": "10.0.0.9", "mac": "cc:c4:b2:77:9e:85", "serial": "B0D32I008U3672679"}}
        no_adb = lambda args, **kwargs: subprocess.CompletedProcess(args, 0, stdout="List of devices attached\n", stderr="")
        stdout = io.StringIO()
        with patch.object(devices, "listen_broadcasts", return_value=heard), \
             patch.object(devices.subprocess, "run", side_effect=no_adb), \
             patch.object(sys, "argv", ["tc002-devices.py", "--json", "--no-mdns"]), contextlib.redirect_stdout(stdout):
            self.assertEqual(devices.main(), 0)
        rows = json.loads(stdout.getvalue())
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["ip"], rows[0]["kind"], rows[0]["mac"], rows[0].get("serial")),
                         ("10.0.0.9", "stock", "cc:c4:b2:77:9e:85", "B0D32I008U3672679"))


if __name__ == "__main__":
    unittest.main()
