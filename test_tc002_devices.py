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
                # the tokens land in the shared file and in one named for the clock, so two clocks
                # do not overwrite each other's and the console can pick the right one per host
                self.assertTrue((root / "tokens").exists())
                self.assertTrue((root / f"tokens-{given.split(':')[0]}").exists(), sorted(os.listdir(root)))


class DecoderTests(unittest.TestCase):
    """the dns decoder itself: the other tests mock at the socket and only ever see well-formed
    announcements built by this file."""

    def test_pointer_is_followed_and_the_offset_is_after_the_pointer(self):
        # "local" at 12, then "tc002-x" + a pointer back to it
        buf = bytearray(12) + dns_name("local")
        name_at = len(buf)
        buf += bytes([7]) + b"tc002-x" + bytes([0xC0, 12])
        name, after = devices._name_at(bytes(buf), name_at)
        self.assertEqual(name, "tc002-x.local")
        self.assertEqual(after, len(buf))

    def test_forward_and_self_pointers_are_refused(self):
        self.assertEqual(devices._name_at(bytes([0xC0, 0x04, 0, 0, 0]), 0)[0], "")
        self.assertEqual(devices._name_at(bytes([0xC0, 0x00]), 0)[0], "")

    def test_a_label_running_off_the_end_is_refused(self):
        self.assertEqual(devices._name_at(bytes([40, ord("a"), ord("b")]), 0)[0], "")
        self.assertEqual(devices._name_at(bytes([3, ord("a")]), 0)[0], "")

    def test_answers_walk_answer_authority_and_additional_sections(self):
        # one question, one answer (PTR) and one additional (A): all three sections are walked
        inst, ip = "tc002-aabbccddeeff", "10.0.0.68"
        service = "_tc002._tcp.local"
        target = dns_name(f"{inst}.{service}")
        question = dns_name(service) + struct.pack("!HH", 12, 1)
        ptr = dns_name(service) + struct.pack("!HHIH", 12, 1, 4500, len(target)) + target
        a = dns_name(f"{inst}.local") + struct.pack("!HHIH", 1, 1, 120, 4) + socket.inet_aton(ip)
        pkt = struct.pack("!HHHHHH", 0, 0x8400, 1, 1, 0, 1) + question + ptr + a
        self.assertEqual(list(devices._parse_answers(pkt)),
                         [(f"{inst}.{service}", None), (f"{inst}.local", ip)])

    def test_truncated_rdata_stops_the_walk_without_raising(self):
        pkt = announcement("tc002-aabbccddeeff", "10.0.0.68")
        for cut in (13, len(pkt) - 3, len(pkt) - 1):
            with self.subTest(cut=cut):
                records = list(devices._parse_answers(pkt[:cut]))
                self.assertTrue(all(isinstance(r, tuple) for r in records))

    def test_a_record_with_the_wrong_length_is_not_an_address(self):
        inst = "tc002-aabbccddeeff"
        bad = dns_name(f"{inst}.local") + struct.pack("!HHIH", 1, 1, 120, 3) + b"\x0a\x00\x00"
        pkt = struct.pack("!HHHHHH", 0, 0x8400, 0, 1, 0, 0) + bad
        self.assertEqual(list(devices._parse_answers(pkt)), [(f"{inst}.local", None)])

    def test_a_reply_for_another_service_is_not_a_clock(self):
        sock = Mock()
        hue = struct.pack("!HHHHHH", 0, 0x8400, 0, 1, 0, 0) + dns_name("_hue._tcp.local") + \
            struct.pack("!HHIH", 12, 1, 4500, 0)
        sock.recvfrom.side_effect = [(hue, ("10.0.0.9", 5353)), OSError()]
        with patch.object(devices.socket, "socket", return_value=sock), patch.object(devices.time, "sleep"):
            self.assertEqual(devices.mdns_query(), {})


if __name__ == "__main__":
    unittest.main()
