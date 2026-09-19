#!/usr/bin/env python3
"""tc002-devices.py: list every TC002 this machine can reach, so tools stop guessing.

  tc002-devices.py [--sweep 10.0.0] [--one] [--json] [--adb PATH]

One clock on a LAN needs no discovery and every tool here grew up assuming it.
With two, "the device" is ambiguous and the failure is silent: a tool picks the
first transport and talks to the wrong clock. This enumerates them and refuses
to choose.

It finds both kinds, which need different probes:

  stock firmware   GET /getBase      -> 200 and a json body with devSn/mac
  custom runtime   GET /api/v1/status -> 401 (auth required, but the route
                                         exists, which nothing else answers)

`--one` prints a single adb address for scripts. If there is exactly one device
it prints it and exits 0; if there are none or several it prints the table on
stderr and exits 2, so the caller stops instead of picking.
"""
import argparse, json, re, socket, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ADB = "adb"


def sh(args, timeout=8):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.stdout.replace("\r", "")
    except Exception:
        return ""


def http(host, path, timeout=2.0):
    """returns (status, body). apple's python only; no third-party deps."""
    try:
        with socket.create_connection((host, 80), timeout) as s:
            s.settimeout(timeout)
            s.sendall(f"GET {path} HTTP/1.0\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
            buf = b""
            while len(buf) < 65536:
                b = s.recv(8192)
                if not b:
                    break
                buf += b
    except Exception:
        return 0, ""
    head, _, body = buf.partition(b"\r\n\r\n")
    m = re.match(rb"HTTP/1\.[01] (\d{3})", head)
    return (int(m.group(1)) if m else 0), body.decode("utf-8", "replace")


def identify(host):
    """what kind of tc002 is at this address, if any."""
    code, body = http(host, "/getBase")
    if code == 200 and "devSn" in body:
        try:
            d = json.loads(body)
        except Exception:
            d = {}
        return {"kind": "stock", "serial": d.get("devSn", ""), "mac": d.get("mac", ""),
                "ssid": d.get("ssid", ""), "app": d.get("appVer", "")}
    code, _ = http(host, "/api/v1/status")
    if code in (401, 403):
        return {"kind": "runtime", "serial": "", "mac": "", "ssid": "", "app": ""}
    return None


def adb_transports():
    out = sh([ADB, "devices"])
    return [l.split()[0] for l in out.splitlines()[1:] if l.strip().endswith("device")]


def describe_adb(serial):
    """identity of one adb transport, read from the device itself."""
    mac = sh([ADB, "-s", serial, "shell",
              "cat /sys/class/net/wlan0/address"], timeout=10).strip()
    ip = ""
    ifc = sh([ADB, "-s", serial, "shell", "ifconfig wlan0"], timeout=10)
    m = re.search(r"inet addr:([0-9.]+)", ifc)
    if m:
        ip = m.group(1)
    runtime = "tc002-supervisor" in sh(
        [ADB, "-s", serial, "shell", "ls /res/bin/tc002-supervisor 2>/dev/null"], timeout=10)
    return {"transport": serial, "ip": ip, "mac": mac,
            "kind": "runtime" if runtime else "stock"}


def main():
    global ADB
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sweep", metavar="A.B.C", help="probe every host in this /24 as well")
    ap.add_argument("--one", action="store_true", help="print one adb address, or fail if ambiguous")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--adb", default="adb")
    a = ap.parse_args()
    ADB = a.adb

    rows = {}
    for serial in adb_transports():
        d = describe_adb(serial)
        if not d["mac"]:
            continue                      # not a tc002, or not answering
        rows[d["mac"]] = d

    if a.sweep:
        hosts = [f"{a.sweep}.{i}" for i in range(1, 255)]
        with ThreadPoolExecutor(max_workers=64) as ex:
            for host, info in zip(hosts, ex.map(identify, hosts)):
                if not info:
                    continue
                key = info.get("mac") or host
                if key in rows:
                    rows[key].setdefault("ip", host)
                else:
                    rows[key] = {"transport": f"{host}:5555", "ip": host,
                                 "mac": info.get("mac", ""), "kind": info["kind"],
                                 "serial": info.get("serial", "")}

    # adb rows are keyed by mac, sweep rows by ip when the runtime returns no
    # mac. the same clock therefore arrives twice. merge on ip, keeping the adb
    # row, which is the one that knows the mac and the transport.
    merged = {}
    for r in rows.values():
        ip = r.get("ip") or ""
        if ip and ip in merged:
            keep = merged[ip]
            if not keep.get("mac") and r.get("mac"):
                r.setdefault("transport", keep.get("transport"))
                merged[ip] = r
            continue
        merged[ip or r["transport"]] = r
    out = sorted(merged.values(), key=lambda r: r.get("ip") or "")

    if a.one:
        if len(out) == 1:
            r = out[0]
            print(r["transport"] if ":" in r["transport"] else f'{r["ip"]}:5555')
            return 0
        print(f"tc002-devices: found {len(out)} devices; name one with --device", file=sys.stderr)
        for r in out:
            print(f'  {r.get("ip",""):15} {r.get("mac",""):18} {r["kind"]}', file=sys.stderr)
        return 2

    if a.json:
        print(json.dumps(out, indent=2))
        return 0

    if not out:
        print("no tc002 found. is one connected over adb, or try --sweep 10.0.0")
        return 1
    print(f'  {"address":<20} {"mac":<18} {"running":<8} transport')
    for r in out:
        addr = r.get("ip") or "-"
        print(f'  {addr:<20} {r.get("mac",""):<18} {r["kind"]:<8} {r["transport"]}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
