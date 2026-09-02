#!/usr/bin/python3
"""Discover Ulanzi TC002 pixel clocks and join one to a wifi network.

Replaces the Ulanzi Studio desktop app for initial setup.

  discover                    sweep the local subnet for TC002 devices
  adopt --ssid NAME           join a device (in setup-AP mode) to wifi

Adoption flow:
  A factory-fresh TC002 with no wifi credentials starts a WPA2 access point
  named "U-Clock" (channel 6) and acts as gateway on 192.168.1.1, handing out
  DHCP leases from 192.168.1.101-200. Join that AP, then POST the target
  network's credentials to /setWifiConfig. The device stores them, drops the
  AP, and joins your network.

Use Apple's /usr/bin/python3 - Homebrew binaries are blocked from LAN access
by macOS Local Network Privacy.
"""
import argparse, getpass, json, socket, struct, subprocess, sys, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor

SETUP_AP_SSID = "U-Clock"
SETUP_AP_HOST = "192.168.1.1"
TC002_KEYS = {"devSn", "mac", "mcuVer", "appVer", "ssid", "ip"}


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


def discover(subnet, workers=128):
    hosts = [f"{subnet}.{i}" for i in range(1, 255)]
    found = []
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for r in ex.map(probe, hosts):
            if r:
                found.append(r)
    return found


def cmd_discover(args):
    subnet = args.subnet or local_subnet()
    if not subnet:
        print("could not determine local subnet; pass --subnet 10.0.0", file=sys.stderr)
        return 2
    print(f"scanning {subnet}.0/24 for tc002 devices ...")
    found = discover(subnet)
    if not found:
        print("  none found")
        print(f"  if the device is unconfigured it is hosting the '{SETUP_AP_SSID}' ap;")
        print(f"  join that network and run: {sys.argv[0]} adopt --ssid <your-wifi>")
        return 1
    for host, b in found:
        print(f"  {host}  sn={b.get('devSn')}  app={b.get('appVer')} "
              f"mcu={b.get('mcuVer')}  joined-ssid={b.get('ssid')!r}")
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

    d = sub.add_parser("discover", help="sweep the subnet for tc002 devices")
    d.add_argument("--subnet", help="first three octets, e.g. 10.0.0")
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
