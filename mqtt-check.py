#!/usr/bin/python3
"""verify mosquitto credentials by reading the mqtt connack return code."""
import socket, sys, getpass

def enc_str(s):
    b = s.encode()
    return len(b).to_bytes(2, "big") + b

def enc_len(n):
    out = b""
    while True:
        d = n % 128; n //= 128
        if n: d |= 0x80
        out += bytes([d])
        if not n: return out

CODES = {
    0: ("ACCEPTED", "credentials are valid"),
    1: ("REFUSED", "unacceptable protocol version"),
    2: ("REFUSED", "client id rejected"),
    3: ("REFUSED", "server unavailable"),
    4: ("REFUSED", "BAD USERNAME OR PASSWORD"),
    5: ("REFUSED", "NOT AUTHORIZED"),
}

def check(host, port, user=None, pw=None, cid="cred-check"):
    flags = 0x02                      # clean session
    payload = enc_str(cid)
    if user is not None:
        flags |= 0x80; payload += enc_str(user)
    if pw is not None:
        flags |= 0x40; payload += enc_str(pw)
    vh = enc_str("MQTT") + bytes([4, flags]) + (60).to_bytes(2, "big")
    pkt = b"\x10" + enc_len(len(vh + payload)) + vh + payload
    s = socket.create_connection((host, port), timeout=5)
    try:
        s.sendall(pkt)
        r = s.recv(4)
        if len(r) < 4 or r[0] != 0x20:
            return None, f"no valid CONNACK (got {r!r})"
        return r[3], CODES.get(r[3], ("UNKNOWN", f"code {r[3]}"))[1]
    finally:
        s.close()

if __name__ == "__main__":
    host = sys.argv[1] if len(sys.argv) > 1 else "10.0.0.136"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 1883
    if len(sys.argv) > 3 and sys.argv[3] == "--anon":
        code, msg = check(host, port)
        print(f"  anonymous -> code={code}  {msg}")
    else:
        user = input("  mqtt username: ")
        pw = getpass.getpass("  mqtt password (hidden): ")
        code, msg = check(host, port, user, pw)
        verdict = "VALID" if code == 0 else "INVALID"
        print(f"  {user}@{host}:{port} -> code={code}  {msg}  [{verdict}]")
