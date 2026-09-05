#!/usr/bin/python3
"""make the ulanzi tc002 sync its clock more often (and, optionally, from your own ntp server).

the tc002 has no rtc and no ntp setting. its app library (libzkgui.so) steps the clock
from a hardcoded list of seven ntp server ips once at start and then every 2 hours,
after a random first delay of up to 1 hour. both numbers are compile-time constants, and
the crystal on the unit tested here runs ~70 ppm fast, so the displayed seconds are up
to half a second off just before each sync.

this tool patches those constants in a copy of the library, pushes it to /tmp (tmpfs) and
bind-mounts it over /res/lib/libzkgui.so, the absolute path the launcher opens (it is
named in /res/etc/EasyUI.cfg as startupLibPath, so LD_LIBRARY_PATH does not help). then
it restarts the app. nothing in flash is touched: a reboot restores stock behaviour, and
so does `revert`. the copy costs about 7.5 mb of the device's ~13 mb free ram.

    /usr/bin/python3 tc002-ntp-patch.py status  [-s DEVICE]
    /usr/bin/python3 tc002-ntp-patch.py apply   [-s DEVICE] [--period MINUTES] [--server IP ...]
    /usr/bin/python3 tc002-ntp-patch.py revert  [-s DEVICE]
    /usr/bin/python3 tc002-ntp-patch.py patch   --in libzkgui.so --out patched.so [--period MINUTES] [--server IP ...]

the offsets are for app version 1.1.1 (libzkgui.so sha256 64d7dc6f...). any other build is
refused rather than guessed at.

needs `adb` on the host and adb enabled on the device (it is, by default, on port 5555).
on macos 15+ the terminal app needs local network permission or adb reports "no route to host".
"""

import argparse
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time

# ---------------------------------------------------------------------------
# what we know about app 1.1.1's libzkgui.so
# ---------------------------------------------------------------------------

KNOWN = {
    "sha256": "64d7dc6f7c06cc4f00164b28a52e73cf0b24678a2f3360e22b4ef757818bb7e1",
    "size": 7484524,
    "app": "1.1.1",
}

DEVICE_LIB = "/res/lib/libzkgui.so"
OVERRIDE_LIB = "/tmp/libzkgui.so"
SERVICE = "zkswe"

# mainActivity::onCreate literal pool: UiHandler::schedule(name, fn, period_ms, first_delay_ms)
PERIOD_OFF = 0x1F4484
PERIOD_ORIG = struct.pack("<I", 7_200_000)

# the first-delay computation ends in `sub r3, r0, r3` (r0 = rand()), giving rand() % 3600000.
# we swap that one instruction for `and r3, r0, #0xff00`, giving 0..65 s of jitter instead.
DELAY_INSN_OFF = 0x1F4174
DELAY_INSN_ORIG = bytes.fromhex("033040e0")  # sub r3, r0, r3
DELAY_INSN_NEW = bytes.fromhex("ff3c00e2")   # and r3, r0, #0xff00

# ntp::defaultServerList(): seven ip strings in .rodata, each in its own 16-byte nul-padded slot
SERVER_SLOT0_OFF = 0x625E34
SERVER_SLOT_SIZE = 16
SERVERS_ORIG = [
    "203.107.6.88",     # ntp.aliyun.com
    "182.92.12.11",     # time5.aliyun.com
    "120.25.115.20",    # cn.ntp.org.cn
    "103.11.143.248",
    "202.73.57.107",
    "158.69.48.97",
    "216.218.254.202",
]

MIN_PERIOD_S = 60
MAX_PERIOD_S = 24 * 3600


def die(msg, code=1):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------------------
# pure byte patching (no device needed)
# ---------------------------------------------------------------------------

def ipv4(s):
    parts = s.split(".")
    if len(parts) != 4 or not all(p.isdigit() and 0 <= int(p) <= 255 and str(int(p)) == p for p in parts):
        raise argparse.ArgumentTypeError(f"{s!r} is not a dotted-quad ipv4 address (the device uses inet_addr, no dns)")
    return s


def check_known(data):
    h = hashlib.sha256(data).hexdigest()
    if len(data) != KNOWN["size"] or h != KNOWN["sha256"]:
        die(f"this libzkgui.so is not the app {KNOWN['app']} build these offsets were worked out on\n"
            f"  got  size={len(data)} sha256={h[:16]}...\n"
            f"  want size={KNOWN['size']} sha256={KNOWN['sha256'][:16]}...\n"
            "  refusing to guess at offsets in an unknown build")
    return h


def expect(data, off, orig, what):
    got = data[off:off + len(orig)]
    if got != orig:
        die(f"unexpected bytes at {off:#x} ({what}): got {got.hex()} want {orig.hex()}")


def patch_bytes(data, period_s=None, servers=None):
    """return (patched_bytes, list of change descriptions)."""
    data = bytearray(data)
    changes = []

    if period_s is not None:
        if not MIN_PERIOD_S <= period_s <= MAX_PERIOD_S:
            die(f"period must be between {MIN_PERIOD_S} s and {MAX_PERIOD_S} s")
        expect(data, PERIOD_OFF, PERIOD_ORIG, "sync period literal")
        data[PERIOD_OFF:PERIOD_OFF + 4] = struct.pack("<I", period_s * 1000)
        changes.append(f"sync period 2 h -> {fmt_secs(period_s)}")

        expect(data, DELAY_INSN_OFF, DELAY_INSN_ORIG, "first-delay instruction")
        data[DELAY_INSN_OFF:DELAY_INSN_OFF + 4] = DELAY_INSN_NEW
        changes.append("first sync delay rand()%3600000 ms -> rand()&0xff00 ms (0..65 s)")

    if servers:
        for i, orig in enumerate(SERVERS_ORIG):
            off = SERVER_SLOT0_OFF + i * SERVER_SLOT_SIZE
            expect(data, off, orig.encode() + b"\0" * (SERVER_SLOT_SIZE - len(orig)), f"server slot {i}")
        for i in range(len(SERVERS_ORIG)):
            ip = servers[i % len(servers)]
            off = SERVER_SLOT0_OFF + i * SERVER_SLOT_SIZE
            data[off:off + SERVER_SLOT_SIZE] = ip.encode().ljust(SERVER_SLOT_SIZE, b"\0")
        changes.append(f"ntp servers {', '.join(SERVERS_ORIG)} -> {', '.join(servers)} (all 7 slots)")

    return bytes(data), changes


def fmt_secs(s):
    if s % 3600 == 0:
        return f"{s // 3600} h"
    if s % 60 == 0:
        return f"{s // 60} min"
    return f"{s} s"


def read_patched(data):
    """describe what a (possibly patched) 1.1.1 library will do."""
    period_ms = struct.unpack_from("<I", data, PERIOD_OFF)[0]
    insn = bytes(data[DELAY_INSN_OFF:DELAY_INSN_OFF + 4])
    if insn == DELAY_INSN_ORIG:
        delay = "rand() % 3600000 ms (0..60 min)"
    elif insn == DELAY_INSN_NEW:
        delay = "rand() & 0xff00 ms (0..65 s)"
    else:
        delay = f"unknown instruction {insn.hex()}"
    servers = []
    for i in range(len(SERVERS_ORIG)):
        off = SERVER_SLOT0_OFF + i * SERVER_SLOT_SIZE
        servers.append(bytes(data[off:off + SERVER_SLOT_SIZE]).split(b"\0", 1)[0].decode("latin1"))
    return period_ms, delay, servers


# ---------------------------------------------------------------------------
# adb plumbing
# ---------------------------------------------------------------------------

TRANSIENT = ("error: closed", "device offline", "device not found", "no devices/emulators", "connection reset")


class Adb:
    def __init__(self, serial=None):
        if shutil.which("adb") is None:
            die("adb not found on PATH (brew install --cask android-platform-tools)")
        self.serial = serial
        if serial and re.match(r"^\d+\.\d+\.\d+\.\d+(:\d+)?$", serial):
            if ":" not in serial:
                self.serial = serial + ":5555"
            self._connect()
        if not self.serial:
            devs = self._devices()
            if len(devs) != 1:
                die("pass -s <ip[:port]>; adb sees " + (", ".join(devs) if devs else "no devices"))
            self.serial = devs[0]

    def _connect(self):
        subprocess.run(["adb", "connect", self.serial], capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def _devices(self):
        out = subprocess.run(["adb", "devices"], capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
        return [l.split()[0] for l in out.splitlines()[1:] if l.strip().endswith("device")]

    def _run(self, *args, check=True, timeout=90):
        """run an adb command; ride out the ~1 min 'device offline' spells wifi adb has."""
        t0 = time.time()
        while True:
            p = subprocess.run(["adb", "-s", self.serial, *args], capture_output=True, text=True,
                               stdin=subprocess.DEVNULL)
            err = (p.stderr or "") + (p.stdout or "")
            if p.returncode == 0 or not any(t in err for t in TRANSIENT):
                break
            if time.time() - t0 > timeout:
                break
            time.sleep(3)
            if ":" in self.serial:
                subprocess.run(["adb", "disconnect", self.serial], capture_output=True, stdin=subprocess.DEVNULL)
                self._connect()
        if check and p.returncode != 0:
            die(f"adb {' '.join(args[:2])} failed: {(p.stderr or p.stdout).strip()}")
        return p.stdout.replace("\r\n", "\n")

    def shell(self, cmd, check=True):
        return self._run("shell", cmd, check=check)

    def pull(self, remote, local):
        self._run("pull", remote, local)

    def push(self, local, remote):
        self._run("push", local, remote)

    # --- device facts ------------------------------------------------------

    def app_pid(self):
        for line in self.shell("ps").splitlines():
            cols = line.split()
            if cols and cols[-1] == "/bin/zkgui":
                return int(cols[0])
        return None

    def mapped_inode(self, pid):
        """(device, inode) of the libzkgui.so the running app has mapped, or none."""
        for line in self.shell(f"cat /proc/{pid}/maps", check=False).splitlines():
            cols = line.split()
            if len(cols) >= 6 and cols[5].endswith("libzkgui.so"):
                return cols[3], int(cols[4])
        return None

    def inode(self, path):
        out = self.shell(f"ls -i {path}", check=False).strip()
        m = re.match(r"^\s*(\d+)\s", out)
        return int(m.group(1)) if m else None

    def override_mounted(self):
        return any(DEVICE_LIB in l for l in self.shell("mount").splitlines())

    def override_present(self):
        return "No such file" not in self.shell(f"ls {OVERRIDE_LIB}", check=False)

    def mem_available_kb(self):
        m = re.search(r"MemAvailable:\s+(\d+)", self.shell("cat /proc/meminfo"))
        return int(m.group(1)) if m else None

    def tmp_free_kb(self):
        for line in self.shell("df /tmp").splitlines():
            cols = line.split()
            if len(cols) >= 6 and cols[-1] == "/tmp":
                return int(cols[3])
        return None

    def sync_log(self):
        """[(device-utc timestamp, pid, message)] for every ntp sync line still in the log buffer."""
        out = self.shell("logcat -d -v time -s NTP:* zkgui:D zkgui:I", check=False)
        rows = []
        for line in out.splitlines():
            if "time sync success" in line or "NTP sync success" in line or "ntp.cpp" in line:
                m = re.search(r"\(\s*(\d+)\)", line)
                msg = re.sub(r"\x1b\[[0-9;]*m", "", line.split("] ", 1)[-1]).strip()
                rows.append((line[:18], int(m.group(1)) if m else 0, msg))
        return rows

    def props(self):
        return {k: self.shell(f"getprop {k}").strip() for k in ("ro.firmware", "ro.build.date", "ro.system.version")}

    # --- service control ---------------------------------------------------

    # this init knows ctl.start/ctl.stop but silently ignores ctl.restart.

    def stop_app(self):
        if self.app_pid() is None:
            return
        self.shell(f"setprop ctl.stop {SERVICE}")
        for _ in range(15):
            if self.app_pid() is None:
                return
            time.sleep(1)
        die("zkgui did not stop within 15 s")

    def start_app(self):
        self.shell(f"setprop ctl.start {SERVICE}")
        t0 = time.time()
        while time.time() - t0 < 40:
            pid = self.app_pid()
            if pid:
                time.sleep(3)  # let the loader map everything
                return pid
            time.sleep(1)
        die("zkgui did not come back within 40 s; check `adb shell ps` and `adb shell logcat -d`")

    def unmount_override(self):
        """the running app holds the file open, so the caller stops it first."""
        for _ in range(5):
            if not self.override_mounted():
                return
            self.shell(f"umount {DEVICE_LIB}", check=False)
            time.sleep(1)
        die(f"could not unmount {DEVICE_LIB} even with the app stopped; a reboot clears it")


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

def cmd_patch(args):
    with open(args.infile, "rb") as f:
        data = f.read()
    check_known(data)
    patched, changes = patch_bytes(data, args.period_s, args.server)
    if not changes:
        die("nothing to change: give --period and/or --server")
    with open(args.outfile, "wb") as f:
        f.write(patched)
    for c in changes:
        print(f"  {c}")
    print(f"wrote {args.outfile} ({len(patched)} bytes)")


def describe_lib(label, data):
    period_ms, delay, servers = read_patched(data)
    print(f"{label}:")
    print(f"  sync period    {fmt_secs(period_ms // 1000)}")
    print(f"  first delay    {delay}")
    print(f"  servers        {', '.join(servers)}")


def print_sync_log(adb, pid=None):
    rows = adb.sync_log()
    if pid is not None:
        rows = [r for r in rows if r[1] == pid]
    if rows:
        print(f"sync lines still in the log buffer ({len(rows)}; it only holds an hour or two):")
        for ts, p, msg in rows[-10:]:
            print(f"  {ts}  {msg}")
    else:
        print("no sync lines in the log buffer (it only holds an hour or two)")


def cmd_status(args):
    adb = Adb(args.serial)
    props = adb.props()
    print(f"device {adb.serial}: firmware {props['ro.firmware']} built {props['ro.build.date']}, system {props['ro.system.version']}")
    pid = adb.app_pid()
    mounted = adb.override_mounted()
    present = adb.override_present()
    tmp_inode = adb.inode(OVERRIDE_LIB) if present else None
    if pid is None:
        print("zkgui is not running")
    else:
        mapped = adb.mapped_inode(pid)
        if mapped and tmp_inode and mapped[1] == tmp_inode:
            print(f"zkgui pid {pid} is running the patched library (bind-mounted from {OVERRIDE_LIB})")
        else:
            print(f"zkgui pid {pid} is running the stock library")
    print(f"override file {'present' if present else 'absent'}, bind mount {'active' if mounted else 'absent'}, "
          f"memavailable {adb.mem_available_kb()} kb")
    if present:
        with tempfile.TemporaryDirectory() as td:
            local = os.path.join(td, "override.so")
            adb.pull(OVERRIDE_LIB, local)
            with open(local, "rb") as f:
                data = f.read()
        if len(data) == KNOWN["size"]:
            describe_lib(f"{OVERRIDE_LIB} (tmpfs, gone after a reboot)", data)
        else:
            print(f"{OVERRIDE_LIB} exists but is {len(data)} bytes; not a 1.1.1 build")
    else:
        print("stock behaviour: 2 h period, 0..60 min first delay, vendor servers")
    print_sync_log(adb)


def cmd_apply(args):
    if args.period_s is None and not args.server:
        die("nothing to change: give --period and/or --server")
    adb = Adb(args.serial)
    props = adb.props()
    print(f"device {adb.serial}: firmware {props['ro.firmware']} built {props['ro.build.date']}")
    mem_before = adb.mem_available_kb()
    if adb.override_mounted():
        # the stock bytes are hidden behind the mount, and the running app pins it
        print("an override is already mounted; stopping the app and unmounting it first (display goes blank)", flush=True)
        adb.stop_app()
        adb.unmount_override()
    free = adb.tmp_free_kb()
    need = KNOWN["size"] // 1024 + 512
    if free is not None and free < need and not adb.override_present():
        die(f"/tmp has only {free} kb free; need ~{need} kb")

    with tempfile.TemporaryDirectory() as td:
        stock = os.path.join(td, "stock.so")
        patched_path = os.path.join(td, "patched.so")
        print(f"pulling {DEVICE_LIB} ...", flush=True)
        adb.pull(DEVICE_LIB, stock)
        with open(stock, "rb") as f:
            data = f.read()
        check_known(data)
        patched, changes = patch_bytes(data, args.period_s, args.server)
        for c in changes:
            print(f"  {c}")
        with open(patched_path, "wb") as f:
            f.write(patched)
        print(f"pushing to {OVERRIDE_LIB} ...", flush=True)
        adb.push(patched_path, OVERRIDE_LIB)

    adb.shell(f"mount -o bind {OVERRIDE_LIB} {DEVICE_LIB}")
    tmp_inode = adb.inode(OVERRIDE_LIB)
    if adb.inode(DEVICE_LIB) != tmp_inode:
        die(f"bind mount did not take: {DEVICE_LIB} still resolves to the stock file")

    print("restarting the app (the display goes blank for a few seconds) ...", flush=True)
    adb.stop_app()
    pid = adb.start_app()
    mapped = adb.mapped_inode(pid)
    if not mapped or mapped[1] != tmp_inode:
        die(f"zkgui (pid {pid}) came back mapping {mapped}, not the override (inode {tmp_inode})")
    print(f"zkgui pid {pid} is running the patched library (memavailable {mem_before} -> {adb.mem_available_kb()} kb)")

    # the app syncs once at start; show that it happened with the new build
    for _ in range(40):
        rows = [r for r in adb.sync_log() if r[1] == pid and "success" in r[2]]
        if rows:
            print(f"first sync after restart: {rows[0][0]}  {rows[0][2]}")
            break
        time.sleep(1)
    else:
        print("no sync logged within 40 s; check `status` later (servers unreachable? look for E/NTP in logcat)")
    print("this lives in tmpfs: a reboot restores stock behaviour; `revert` does so now")


def cmd_revert(args):
    adb = Adb(args.serial)
    mounted = adb.override_mounted()
    present = adb.override_present()
    pid = adb.app_pid()
    tmp_inode = adb.inode(OVERRIDE_LIB) if present else None
    running_override = bool(pid and tmp_inode and (adb.mapped_inode(pid) or (None, None))[1] == tmp_inode)
    if not (mounted or present or running_override):
        print("nothing to revert: no override file, no bind mount, stock library running")
        return
    was_running = pid is not None
    print("stopping the app (the display goes blank for a few seconds) ...", flush=True)
    adb.stop_app()
    if mounted:
        adb.unmount_override()
    if present:
        adb.shell(f"rm -f {OVERRIDE_LIB}")
    if not was_running:
        print("override removed; zkgui was not running before, start it with `adb shell setprop ctl.start zkswe`")
        return
    pid = adb.start_app()
    mapped = adb.mapped_inode(pid)
    stock_inode = adb.inode(DEVICE_LIB)
    ok = mapped and mapped[1] == stock_inode
    print(f"zkgui pid {pid} is running the {'stock library' if ok else 'unexpected library ' + str(mapped)}; "
          f"memavailable {adb.mem_available_kb()} kb")


# ---------------------------------------------------------------------------

def period_arg(s):
    try:
        minutes = float(s)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{s!r} is not a number of minutes")
    secs = int(round(minutes * 60))
    if not MIN_PERIOD_S <= secs <= MAX_PERIOD_S:
        raise argparse.ArgumentTypeError(f"period must be between 1 and {MAX_PERIOD_S // 60} minutes")
    return secs


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n", 1)[1])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("-s", "--serial", metavar="DEVICE", help="device ip[:port] or adb serial (default: the only connected device)")

    def patchopts(p):
        p.add_argument("--period", dest="period_s", type=period_arg, metavar="MINUTES",
                       help="minutes between syncs (1..1440; stock is 120)")
        p.add_argument("--server", action="append", type=ipv4, metavar="IP",
                       help="ntp server ipv4 to use instead of the vendor list; repeat for more than one (all 7 slots are filled, cycling)")

    p = sub.add_parser("status", help="what the device is running, and its recent syncs")
    common(p)
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("apply", help="pull, patch, push to /tmp, bind-mount over the stock path and restart the app")
    common(p)
    patchopts(p)
    p.set_defaults(fn=cmd_apply)

    p = sub.add_parser("revert", help="unmount and remove the override and restart the app on the stock library")
    common(p)
    p.set_defaults(fn=cmd_revert)

    p = sub.add_parser("patch", help="patch a local copy of libzkgui.so (no device needed)")
    p.add_argument("--in", dest="infile", required=True, metavar="LIBZKGUI_SO")
    p.add_argument("--out", dest="outfile", required=True, metavar="PATCHED_SO")
    patchopts(p)
    p.set_defaults(fn=cmd_patch)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
