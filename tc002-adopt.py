#!/usr/bin/python3
"""Discover Ulanzi TC002 pixel clocks and join one to a wifi network.

Replaces the Ulanzi Studio desktop app for initial setup.

  discover                    find TC002 devices on the LAN
  adopt --ssid NAME           join a device (in setup-AP mode) to wifi

Discovery:
  A joined TC002 announces itself about once a second by UDP broadcast to
  port 55555 with the payload "Ulanzi TC002 <mac-tail>:<mac>:<serial>:<bool>".
  'discover' listens for that first (a few seconds), then confirms each
  device over HTTP. If nothing is heard - a different VLAN, a firewall, or a
  broadcast-filtering AP - it falls back to sweeping the subnet for hosts
  answering GET /getBase.

Adoption flow:
  A factory-fresh TC002 with no wifi credentials starts a WPA2 access point
  named "U-Clock" (channel 6) and acts as gateway on 192.168.1.1, handing out
  DHCP leases from 192.168.1.101-200. Join that AP, then POST the target
  network's credentials to /setWifiConfig. The device stores them, drops the
  AP, and joins your network.

Use Apple's /usr/bin/python3 - Homebrew binaries are blocked from LAN access
by macOS Local Network Privacy.
"""
import argparse, getpass, json, re, socket, subprocess, sys, time, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor

SETUP_AP_SSID = "U-Clock"
SETUP_AP_HOST = "192.168.1.1"
TC002_KEYS = {"devSn", "mac", "mcuVer", "appVer", "ssid", "ip"}
BROADCAST_PORT = 55555
BROADCAST_RE = re.compile(
    r"^Ulanzi TC002 (?P<tail>[0-9a-f]{4}):(?P<mac>[0-9a-f]{12}):(?P<sn>[A-Za-z0-9]+):(?P<flag>true|false)$")


def http_json(host, path, payload=None, timeout=3.0):
    url = f"http://{host}/{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data,
                                 method="POST" if data else "GET")
    if data:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def looks_like_tc002(obj):
    return isinstance(obj, dict) and TC002_KEYS.issubset(obj.keys())


def local_subnet():
    """Best-effort /24 for the interface holding the default route."""
    try:
        out = subprocess.run(["/usr/sbin/ipconfig", "getifaddr", "en0"],
                             capture_output=True, text=True, timeout=4).stdout.strip()
        if not out:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("192.0.2.1", 53))
            out = s.getsockname()[0]
            s.close()
        return ".".join(out.split(".")[:3])
    except Exception:
        return None


def probe(host):
    try:
        obj = http_json(host, "getBase", timeout=2.0)
        return (host, obj) if looks_like_tc002(obj) else None
    except Exception:
        return None


def sweep(subnet, workers=128):
    """Probe every host in a /24 for a TC002 answering GET /getBase."""
    hosts = [f"{subnet}.{i}" for i in range(1, 255)]
    found = []
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for r in ex.map(probe, hosts):
            if r:
                found.append(r)
    return found


def listen(seconds):
    """Collect TC002 broadcast announcements on udp/55555.

    Returns {ip: {"mac", "sn", "flag"}}. The device sends about once a second,
    so a few seconds is enough. SO_REUSEPORT lets this coexist with Ulanzi
    Studio, which listens on the same port.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except (AttributeError, OSError):
        pass
    try:
        s.bind(("0.0.0.0", BROADCAST_PORT))
    except OSError as e:
        print(f"  cannot listen on udp/{BROADCAST_PORT}: {e}", file=sys.stderr)
        return {}
    heard = {}
    deadline = time.monotonic() + seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        s.settimeout(remaining)
        try:
            data, (ip, _port) = s.recvfrom(1024)
        except socket.timeout:
            break
        except OSError:
            continue
        m = BROADCAST_RE.match(data.decode("utf-8", "replace").strip())
        if m:
            heard[ip] = m.groupdict()
    s.close()
    return heard


def cmd_discover(args):
    found = []          # list of (ip, base-json-or-None, broadcast-dict-or-None)

    if not args.no_listen:
        print(f"listening for tc002 broadcasts on udp/{BROADCAST_PORT} for {args.listen:g}s ...")
        heard = listen(args.listen)
        if heard:
            # confirm each over http; the broadcast alone carries mac + serial
            with ThreadPoolExecutor(max_workers=8) as ex:
                for ip, base in zip(heard, ex.map(probe, heard)):
                    found.append((ip, base[1] if base else None, heard[ip]))

    if not found and not args.no_sweep:
        subnet = args.subnet or local_subnet()
        if not subnet:
            print("  nothing heard, and could not determine the local subnet; pass --subnet 10.0.0",
                  file=sys.stderr)
            return 2
        if not args.no_listen:
            print("  nothing heard (different vlan, or broadcasts filtered?)")
        print(f"sweeping {subnet}.0/24 for tc002 devices ...")
        found = [(ip, base, None) for ip, base in sweep(subnet)]

    if not found:
        print("  none found")
        print(f"  if the device is unconfigured it is hosting the '{SETUP_AP_SSID}' ap;")
        print(f"  join that network and run: {sys.argv[0]} adopt --ssid <your-wifi>")
        return 1
    for ip, base, bc in found:
        if base:
            print(f"  {ip}  sn={base.get('devSn')}  mac={base.get('mac')}  app={base.get('appVer')} "
                  f"mcu={base.get('mcuVer')}  joined-ssid={base.get('ssid')!r}")
        else:
            print(f"  {ip}  sn={bc['sn']}  mac={bc['mac']}  (announced by broadcast; http not reachable)")
    return 0


def cmd_adopt(args):
    host = args.host
    try:
        base = http_json(host, "getBase", timeout=4.0)
    except Exception as e:
        print(f"  cannot reach a tc002 at {host}: {e}", file=sys.stderr)
        print(f"  are you joined to the '{SETUP_AP_SSID}' wifi network?", file=sys.stderr)
        return 2
    if not looks_like_tc002(base):
        print(f"  {host} does not look like a tc002", file=sys.stderr)
        return 2
    print(f"  found tc002 sn={base.get('devSn')} at {host}")

    password = args.password
    if password is None:
        password = getpass.getpass(f"  password for wifi network {args.ssid!r} (hidden): ")

    try:
        res = http_json(host, "setWifiConfig",
                        {"ssid": args.ssid, "password": password}, timeout=10.0)
    except Exception as e:
        print(f"  setWifiConfig failed: {e}", file=sys.stderr)
        return 1
    if res.get("code") == 200:
        print(f"  accepted. the device will drop the '{SETUP_AP_SSID}' ap and join {args.ssid!r}.")
        print("  rejoin your normal wifi, then run 'discover' to find its new address.")
        return 0
    print(f"  device rejected the request: {res}", file=sys.stderr)
    return 1


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("discover", help="find tc002 devices on the lan")
    d.add_argument("--listen", type=float, default=3.0, metavar="SECONDS",
                   help="how long to listen for udp broadcasts (default 3)")
    d.add_argument("--no-listen", action="store_true", help="skip listening; sweep only")
    d.add_argument("--no-sweep", action="store_true", help="do not fall back to the subnet sweep")
    d.add_argument("--subnet", help="first three octets for the sweep, e.g. 10.0.0")
    d.set_defaults(func=cmd_discover)

    a = sub.add_parser("adopt", help="join a device in setup-ap mode to wifi")
    a.add_argument("--ssid", required=True, help="wifi network for the device to join")
    a.add_argument("--password", help="wifi password (omit to be prompted, which is safer)")
    a.add_argument("--host", default=SETUP_AP_HOST,
                   help=f"device address in ap mode (default {SETUP_AP_HOST})")
    a.set_defaults(func=cmd_adopt)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
