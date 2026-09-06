#!/usr/bin/env python3
"""a minimal mqtt 3.1.1 broker for testing the device's client on a lan: connect/connack,
subscribe/suback with '#' and '+' matching, publish forwarding with retained messages, qos 1
acks, ping. logs every packet to stdout. not for production use.

  tc002-test-broker.py [--port 1883] [--user U --password P]
  tc002-test-broker.py --publish HOST TOPIC PAYLOAD_OR_@FILE [--qos 1]     (a tiny client)
"""
import argparse, socket, struct, sys, threading, time

def enc_len(n):
    out = b""
    while True:
        b = n % 128; n //= 128
        out += bytes([b | (0x80 if n else 0)])
        if not n: return out

def read_packet(sock):
    first = sock.recv(1)
    if not first: return None, None
    mult, n = 1, 0
    while True:
        b = sock.recv(1)
        if not b: return None, None
        n += (b[0] & 0x7f) * mult; mult *= 128
        if not b[0] & 0x80: break
    body = b""
    while len(body) < n:
        chunk = sock.recv(n - len(body))
        if not chunk: return None, None
        body += chunk
    return first[0], body

def mqtt_str(b, o):
    n = struct.unpack(">H", b[o:o+2])[0]
    return b[o+2:o+2+n].decode(errors="replace"), o + 2 + n

def matches(pattern, topic):
    p, t = pattern.split("/"), topic.split("/")
    for i, seg in enumerate(p):
        if seg == "#": return True
        if i >= len(t): return False
        if seg != "+" and seg != t[i]: return False
    return len(p) == len(t)

class Broker:
    def __init__(self, user, password):
        self.user, self.password = user, password
        self.clients = {}   # sock -> {"subs": [...], "id": str}
        self.retained = {}
        self.lock = threading.Lock()

    def log(self, *a):
        print(time.strftime("%H:%M:%S"), *a, flush=True)

    def send_publish(self, sock, topic, payload, retain=False, qos=0, pid=1):
        first = 0x30 | (qos << 1) | (1 if retain else 0)
        body = struct.pack(">H", len(topic)) + topic.encode() + (struct.pack(">H", pid) if qos else b"") + payload
        try: sock.sendall(bytes([first]) + enc_len(len(body)) + body)
        except OSError: pass

    def forward(self, topic, payload, retain, origin):
        with self.lock:
            if retain:
                if payload: self.retained[topic] = payload
                else: self.retained.pop(topic, None)
            targets = [(s, c) for s, c in self.clients.items() if any(matches(p, topic) for p in c["subs"])]
        for s, c in targets:
            self.send_publish(s, topic, payload)

    def serve(self, sock, addr):
        cid = "?"
        try:
            while True:
                first, body = read_packet(sock)
                if first is None: break
                kind = first >> 4
                if kind == 1:
                    o = 0
                    _, o = mqtt_str(body, o); o += 1
                    flags = body[o]; o += 1
                    keepalive = struct.unpack(">H", body[o:o+2])[0]; o += 2
                    cid, o = mqtt_str(body, o)
                    will = None
                    if flags & 0x04:
                        wt, o = mqtt_str(body, o); wp, o = mqtt_str(body, o)
                        will = (wt, wp, bool(flags & 0x20))
                    user = pw = None
                    if flags & 0x80: user, o = mqtt_str(body, o)
                    if flags & 0x40: pw, o = mqtt_str(body, o)
                    ok = (self.user is None) or (user == self.user and pw == self.password)
                    self.log(f"connect from {addr} id={cid} keepalive={keepalive} will={will} user={user} auth={'ok' if ok else 'refused'}")
                    sock.sendall(b"\x20\x02\x00" + (b"\x00" if ok else b"\x05"))
                    if not ok: break
                    with self.lock: self.clients[sock] = {"subs": [], "id": cid, "will": will}
                elif kind == 8:
                    pid = struct.unpack(">H", body[:2])[0]; o = 2; codes = b""
                    while o < len(body):
                        t, o = mqtt_str(body, o); q = body[o]; o += 1
                        with self.lock: self.clients[sock]["subs"].append(t)
                        codes += bytes([min(q, 1)])
                        self.log(f"  subscribe {cid}: {t} qos {q}")
                        for rt, rp in list(self.retained.items()):
                            if matches(t, rt): self.send_publish(sock, rt, rp, retain=True)
                    sock.sendall(b"\x90" + enc_len(2 + len(codes)) + struct.pack(">H", pid) + codes)
                elif kind == 3:
                    qos = (first >> 1) & 3; retain = bool(first & 1)
                    t, o = mqtt_str(body, 0)
                    pid = None
                    if qos:
                        pid = struct.unpack(">H", body[o:o+2])[0]; o += 2
                        sock.sendall(b"\x40\x02" + struct.pack(">H", pid))
                    payload = body[o:]
                    shown = payload if len(payload) < 400 else payload[:120] + b"...(%d bytes)" % len(payload)
                    self.log(f"  publish {cid}: {t} qos={qos} retain={retain} {shown!r}")
                    self.forward(t, payload, retain, sock)
                elif kind == 12:
                    sock.sendall(b"\xd0\x00")
                elif kind == 14:
                    self.log(f"disconnect {cid}"); break
        except OSError as e:
            self.log(f"socket error {cid}: {e}")
        finally:
            with self.lock:
                c = self.clients.pop(sock, None)
            sock.close()
            if c and c.get("will"):
                wt, wp, wr = c["will"]
                self.log(f"  will for {cid}: {wt} {wp!r}")
                self.forward(wt, wp.encode(), wr, None)
            self.log(f"closed {cid}")

def publish(host, port, topic, payload, qos):
    s = socket.create_connection((host, port), timeout=5)
    cid = b"tc002-test-pub"
    body = b"\x00\x04MQTT\x04\x02\x00\x1e" + struct.pack(">H", len(cid)) + cid
    s.sendall(b"\x10" + enc_len(len(body)) + body)
    assert read_packet(s)[0] >> 4 == 2
    first = 0x30 | (qos << 1)
    body = struct.pack(">H", len(topic)) + topic.encode() + (b"\x00\x07" if qos else b"") + payload
    s.sendall(bytes([first]) + enc_len(len(body)) + body)
    if qos: read_packet(s)
    s.sendall(b"\xe0\x00"); s.close()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=1883)
    ap.add_argument("--user"); ap.add_argument("--password")
    ap.add_argument("--publish", nargs=3, metavar=("HOST", "TOPIC", "PAYLOAD"))
    ap.add_argument("--qos", type=int, default=0)
    a = ap.parse_args()
    if a.publish:
        host, topic, payload = a.publish
        data = open(payload[1:], "rb").read() if payload.startswith("@") else payload.encode()
        publish(host, a.port, topic, data, a.qos); return
    b = Broker(a.user, a.password)
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", a.port)); srv.listen(8)
    b.log(f"test broker listening on {a.port}")
    while True:
        c, addr = srv.accept()
        threading.Thread(target=b.serve, args=(c, addr), daemon=True).start()

if __name__ == "__main__":
    main()
