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
             patch.object(sys, "argv", ["tc002-devices.py", *argv]), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
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
    for name in ("tc002-update.sh", "tc002-up.sh"):
        shutil.copyfile(ROOT / "runtime/tools" / name, tools / name)
        (tools / name).chmod(0o755)
    payload_dir = root / "runtime" / "zig-out" / "bin"
    payload_dir.mkdir(parents=True)
    (payload_dir / "tc002-supervisor").write_bytes(payload)
    log = root / "calls.jsonl"
    (root / "tokens").write_text("control=" + "a" * 64 + "\nadmin=" + "b" * 64 + "\n")
    fake = FAKE_ADB.format(py=sys.executable)
    for path, content in [(bindir / "adb", fake), (tools / "tc002-run.sh", fake),
                          (bindir / "sleep", "#!/bin/sh\nexit 0\n"),
                          (tools / "tc002ctl.py", FAKE_CTL.format(py=sys.executable))]:
        path.write_text(content)
        path.chmod(0o755)
    return root, bindir, log


def run_update(root, bindir, log, *args, script="tc002-update.sh"):
    env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", TEST_ADB_LOG=str(log))
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
                notices = [i for i, c in enumerate(calls) if c["command"] == "tc002ctl.py" and "notify" in c["args"] and "updating" in c["args"]]
                stops = [i for i, c in enumerate(calls) if c["command"] == "tc002-run.sh" and c["args"][:1] == ["stop"]]
                self.assertTrue(notices, "no updating notice was sent")
                self.assertTrue(stops and notices[0] < stops[0], (notices, stops))

    def test_the_old_bring_up_script_is_the_in_place_mode(self):
        with tempfile.TemporaryDirectory() as d:
            root, bindir, log = fake_checkout(d)
            r = run_update(root, bindir, log, "--device", "10.0.0.7", "--no-build", "--keep-settings", script="tc002-up.sh")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertTrue((root / "tokens-10.0.0.7").exists())


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


if __name__ == "__main__":
    unittest.main()
