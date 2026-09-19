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
import argparse, json, re, socket, subprocess, sys, time
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


def mdns_query(timeout=2.0):
    """ask the lan for `_tc002._tcp.local` and read the answers.

    this is the discovery that actually scales to more than one clock: the runtime answers mdns
    for a name derived from its own mac, so two devices are two names rather than two addresses
    that have to be told apart. no dependencies -- mdns is just udp and a dns message.
    """
    q = bytearray([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
    for label in (b"_tc002", b"_tcp", b"local"):
        q.append(len(label)); q += label
    q += bytes([0, 0, 12, 0, 1])                    # root, QTYPE=PTR, QCLASS=IN

    # browse from 5353 to receive multicast replies, including those from older firmware
    # without legacy unicast support. 5353 is already held by mDNSResponder on macos,
    # hence both reuse options.
    s = None
    found = {}
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except (AttributeError, OSError):
            pass
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        s.bind(("", 5353))
        mreq = socket.inet_aton("224.0.0.251") + socket.inet_aton("0.0.0.0")
        s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
        s.settimeout(0.4)
        # the group membership is not effective the instant setsockopt returns, and a query sent
        # into that gap gets an answer we are not yet subscribed to hear. give igmp a moment, then
        # ask twice: one lost query otherwise reads as "no clocks on this network".
        time.sleep(0.15)
        s.sendto(bytes(q), ("224.0.0.251", 5353))
        resent = False
        end_at = time.time() + timeout
        while time.time() < end_at:
            try:
                data, addr = s.recvfrom(4096)
            except socket.timeout:
                if not resent:
                    resent = True
                    try:
                        s.sendto(bytes(q), ("224.0.0.251", 5353))
                    except OSError:
                        pass
                continue
            except OSError:
                break
            if len(data) < 12 or not (data[2] & 0x80):
                continue                       # queries, including our own, are not answers
            records = list(_parse_answers(data))
            # bound to the group, we hear every mdns responder on the lan. only a packet that
            # actually answers for our service type is a clock; without this check a hue bridge
            # announcing itself is reported as a tc002.
            inst = None
            for name, _ in records:
                if name.endswith("._tc002._tcp.local"):
                    inst = name.split(".")[0]
                    break
            if inst is None:
                continue
            host_ip = addr[0]
            # prefer the A record for our own host name over the packet's source address
            for name, ip in records:
                if ip and name.split(".")[0] == inst:
                    host_ip = ip
            # old firmware may reuse an instance name: never let that hide another clock.
            found[(inst, host_ip)] = {"instance": inst, "ip": host_ip}
    except OSError:
        pass                            # discovery is optional; adb and sweep still work
    finally:
        if s is not None:
            s.close()
    return found


def _name_at(buf, off, depth=0):
    """decode a dns name, following compression pointers. returns (name, offset-after)."""
    parts = []
    after = None
    while depth < 8:
        if off >= len(buf):
            return "", off
        n = buf[off]
        if n == 0:
            off += 1
            break
        if n & 0xC0 == 0xC0:
            if off + 1 >= len(buf):
                return "", off
            ptr = ((n & 0x3F) << 8) | buf[off + 1]
            if after is None:
                after = off + 2
            if ptr >= off:
                return "", off
            off = ptr
            depth += 1
            continue
        if off + 1 + n > len(buf):
            return "", off
        parts.append(buf[off + 1: off + 1 + n].decode("utf-8", "replace"))
        off += 1 + n
    return ".".join(parts), (after if after is not None else off)


def _parse_answers(buf):
    """yield (name, ipv4-or-None) for every answer record."""
    if len(buf) < 12:
        return
    qd = int.from_bytes(buf[4:6], "big")
    an = int.from_bytes(buf[6:8], "big") + int.from_bytes(buf[8:10], "big") + int.from_bytes(buf[10:12], "big")
    off = 12
    for _ in range(qd):
        _, off = _name_at(buf, off)
        off += 4
    for _ in range(an):
        name, off = _name_at(buf, off)
        if off + 10 > len(buf):
            return
        rtype = int.from_bytes(buf[off:off + 2], "big")
        rdlen = int.from_bytes(buf[off + 8:off + 10], "big")
        rdata = buf[off + 10: off + 10 + rdlen]
        off += 10 + rdlen
        if rtype == 12 and rdlen:                    # PTR -> the instance name
            target, _ = _name_at(buf, off - rdlen)
            yield target, None
        elif rtype == 1 and rdlen == 4:              # A
            yield name, ".".join(str(b) for b in rdata)
        else:
            yield name, None


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
    ap.add_argument("--no-mdns", action="store_true", help="skip the mdns probe")
    a = ap.parse_args()
    ADB = a.adb

    rows = {}

    # mdns first: it needs no adb transport, no subnet guess and no sweep, and it is the only
    # probe that returns a *name* rather than an address to be disambiguated later.
    if not a.no_mdns:
        for d in mdns_query().values():
            if not d.get("ip"):
                continue
            rows[d["ip"]] = {"transport": f'{d["ip"]}:5555', "ip": d["ip"], "mac": "",
                             "kind": "runtime", "name": f'{d["instance"]}.local'}

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
                merged[ip] = {**keep, **r}
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
    print(f'  {"address":<16} {"mdns name":<20} {"mac":<18} running')
    for r in out:
        addr = r.get("ip") or "-"
        print(f'  {addr:<16} {r.get("name","-"):<20} {r.get("mac",""):<18} {r["kind"]}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
