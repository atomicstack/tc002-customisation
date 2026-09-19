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


class DeviceSelectionTests(unittest.TestCase):
    def test_up_normalizes_explicit_device_and_exports_same_serial(self):
        for given, expected in [("10.0.0.111", "10.0.0.111:5555"),
                                ("tc002-ddeeff.local", "tc002-ddeeff.local:5555"),
                                ("10.0.0.111:5556", "10.0.0.111:5556")]:
            with self.subTest(device=given), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                tools = root / "runtime" / "tools"
                tools.mkdir(parents=True)
                bindir = root / "bin"
                bindir.mkdir()
                shutil.copyfile(ROOT / "runtime/tools/tc002-up.sh", tools / "tc002-up.sh")
                log = root / "calls.jsonl"
                fake = f'''#!{sys.executable}
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
'''
                for path, content in [(bindir / "adb", fake), (tools / "tc002-run.sh", fake),
                                      (bindir / "sleep", "#!/bin/sh\nexit 0\n"),
                                      (tools / "tc002ctl.py", "print('{}')\n")]:
                    path.write_text(content)
                    path.chmod(0o755)
                env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", TEST_ADB_LOG=str(log))
                result = subprocess.run(["/bin/bash", str(tools / "tc002-up.sh"), "--device", given,
                                         "--no-build", "--keep-settings"], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                adb_calls = [call for call in calls if call["command"] == "adb"]
                self.assertIn(["connect", expected], [call["args"] for call in adb_calls])
                for call in adb_calls:
                    if call["args"][0] != "connect":
                        self.assertEqual(call["args"][:2], ["-s", expected])
                self.assertTrue(any(call["command"] == "tc002-run.sh" for call in calls))
                self.assertEqual({call["device"] for call in calls}, {expected})


if __name__ == "__main__":
    unittest.main()
