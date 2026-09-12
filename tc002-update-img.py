#!/usr/bin/env python3
"""tc002-update-img.py: inspect, unpack and build the tc002's `update.img`.

the ulanzi tc002 runs the flythings (zkswe) stack, and its firmware update
container is the "ZKSWEV1.0" format that `libzkupgrade.so` flashes. it is a
572-byte header followed by the partition image (a squashfs for the `res`
partition), with the image's first 16 bytes moved into the header and replaced
by the md5 of the whole image. there is no signature. the full layout, the
checks the device performs and how they were established are in FIRMWARE.md.

    tc002-update-img.py inspect update.img                 # parse and verify every field
    tc002-update-img.py unpack  update.img res.sqsh        # the squashfs, ready for unsquashfs
    tc002-update-img.py pack    res.sqsh update.img        # a new image (device checks all pass)
    tc002-update-img.py pack    res.sqsh update.img --template stock-update.img   # byte-exact metadata

`pack --template stock.img` copies the bytes the device never reads (the date
tail of the magic, three reserved bytes and a 509-byte opaque region) from a
vendor image, so an unchanged squashfs rebuilds the vendor image byte for byte;
without a template those bytes are constants and the image still passes every
check the linux flasher makes. the payload is padded to a 4 KiB multiple, as
the vendor tool does.

established against a device with `ro.product.model = Zkswe_SSD21X_SPINOR`,
app 1.1.1, by disassembling libzkupgrade.so and recomputing every checksum
against the vendor's own update.img.
"""
import argparse
import binascii
import hashlib
import struct
import sys

HDR_SIZE = 0x23C       # header length; also the payload offset
PREFIX_LEN = 0x30      # bytes 0x00..0x2f: magic, control bytes and entry[0]
BLOCK_OFF = 0x30       # the 524-byte info block
BLOCK_LEN = 0x20C
CRC_OFF = 0x238        # last four bytes of the info block: crc32 of everything before
MAGIC = b"ZKSWEV1.0-180127"   # only the first nine bytes are compared
ENTRY_OFF = 0x14
ENTRY_LEN = 0x1C
PAD = 0x1000

# ro.product.model -> (device code at 0x35, device flag at 0x39), from the model table in
# libzkupgrade.so. a flag of 0xf1 is stored as 0 (the checker maps 0 to 0xf1).
DEVICES = {
    "Zkswe_Z11": (0xAA550101, 0xF1),
    "Zkswe_Z6S": (0xAA550202, 0xF1),
    "Zkswe_A33_SPINOR": (0xAA550303, 0xF1),
    "Zkswe_A33_EMMC": (0xAA550303, 0xF4),
    "Zkswe_SSD20X_SPINOR": (0xAA550404, 0xF1),
    "Zkswe_H500s_SPINOR": (0xAA550505, 0xF1),
    "Zkswe_SSD21X_SPINOR": (0xAA550606, 0xF1),
    "Zkswe_F133_SPINOR": (0xAA550707, 0xF1),
    "Zkswe_F133_EMMC": (0xAA550707, 0xF4),
    "Zkswe_T113_SPINOR": (0xAA550808, 0xF1),
    "Zkswe_T113_EMMC": (0xAA550808, 0xF4),
    "Zkswe_SSD26X_SPINOR": (0xAA550909, 0xF1),
    "Zkswe_F136_SPINOR": (0xAA550B0B, 0xF1),
    "Zkswe_F136_EMMC": (0xAA550B0B, 0xF4),
}

# the tc002's mtdparts, for naming the partition index
PARTITIONS = ["BOOT0", "KERNEL", "rootfs", "res", "config", "MISC", "data", "UDISK"]
PARTITION_SIZES = [0x50000, 0x1F0000, 0x450000, 0x800000, 0xB0000, 0x40000, 0x800000, 0x880000]


def parse(img):
    """return a dict of every header field, plus the verification results."""
    if len(img) < HDR_SIZE + 16:
        raise SystemExit("too short to be an update.img")
    h = img[:HDR_SIZE]
    f = {
        "magic": h[:16],
        "magic_ok": h[:9] == MAGIC[:9],
        "prefix_len": h[0x10],
        "entry_count": h[0x11],
        "block_off": h[0x12],
        "reserved_13": h[0x13],
        "block_len": struct.unpack_from("<I", h, 0x30)[0],
        "byte_34": h[0x34],
        "device_code": struct.unpack_from("<I", h, 0x35)[0],
        "device_flag": h[0x39] or 0xF1,
        "crc_stored": struct.unpack_from("<I", h, CRC_OFF)[0],
        "crc_computed": binascii.crc32(h[:CRC_OFF]) & 0xFFFFFFFF,
        "entries": [],
    }
    f["device"] = next((n for n, (c, fl) in DEVICES.items() if c == f["device_code"] and fl == f["device_flag"]), None)
    for i in range(f["entry_count"]):
        o = ENTRY_OFF + i * ENTRY_LEN
        partn = h[o]
        data_offset, img_size = struct.unpack_from("<II", h, o + 4)
        first16 = h[o + 0x0C:o + 0x1C]
        stored_md5 = img[data_offset:data_offset + 16]
        payload = first16 + img[data_offset + 16:data_offset + img_size]
        f["entries"].append({
            "partn": partn,
            "name": PARTITIONS[partn] if partn < len(PARTITIONS) else "?",
            "mtd_size": PARTITION_SIZES[partn] if partn < len(PARTITION_SIZES) else None,
            "reserved": h[o + 1:o + 4],
            "data_offset": data_offset,
            "img_size": img_size,
            "first16": first16,
            "md5_stored": stored_md5,
            "md5_computed": hashlib.md5(payload).digest(),
            "payload": payload,
            "truncated": len(payload) != img_size,
        })
    return f


def cmd_inspect(a):
    img = open(a.image, "rb").read()
    f = parse(img)
    ok = True

    def line(label, value, good=None):
        nonlocal ok
        mark = "" if good is None else ("  ok" if good else "  MISMATCH")
        if good is False:
            ok = False
        print(f"{label:<22}{value}{mark}")

    line("file size", f"{len(img)} bytes")
    line("magic", repr(f["magic"]), f["magic_ok"])
    line("entry count", f["entry_count"])
    line("control bytes", f"prefix_len=0x{f['prefix_len']:02x} block_off=0x{f['block_off']:02x} reserved=0x{f['reserved_13']:02x}")
    line("device code / flag", f"0x{f['device_code']:08x} / 0x{f['device_flag']:02x} -> {f['device'] or 'unknown model'}", f["device"] is not None)
    line("header crc32", f"stored 0x{f['crc_stored']:08x} computed 0x{f['crc_computed']:08x}", f["crc_stored"] == f["crc_computed"])
    for i, e in enumerate(f["entries"]):
        print(f"entry {i}")
        line("  partition", f"{e['partn']} ({e['name']})", e["partn"] <= 8)
        line("  payload", f"offset 0x{e['data_offset']:x} size {e['img_size']} bytes (0x{e['img_size']:x})", not e["truncated"])
        if e["mtd_size"]:
            line("  fits partition", f"{e['img_size']} <= {e['mtd_size']}", e["img_size"] <= e["mtd_size"])
        line("  first 16 bytes", e["first16"].hex() + ("  (squashfs)" if e["first16"][:4] == b"hsqs" else ""))
        line("  payload md5", f"stored {e['md5_stored'].hex()}")
        line("", f"computed {e['md5_computed'].hex()}", e["md5_stored"] == e["md5_computed"])
    print("verdict:", "the device would accept this image" if ok else "the device would REJECT this image")
    return 0 if ok else 1


def cmd_unpack(a):
    img = open(a.image, "rb").read()
    f = parse(img)
    e = f["entries"][a.entry]
    if e["md5_stored"] != e["md5_computed"]:
        print("warning: payload md5 does not match; the file may be damaged", file=sys.stderr)
    open(a.output, "wb").write(e["payload"])
    print(f"wrote {a.output}: {len(e['payload'])} bytes from entry {a.entry} ({e['name']}); unsquashfs -d dir {a.output}")


def build(squashfs, template=None, partn=3, device="Zkswe_SSD21X_SPINOR"):
    if len(squashfs) % PAD:
        squashfs = squashfs + b"\0" * (PAD - len(squashfs) % PAD)
    hdr = bytearray(HDR_SIZE)
    if template is not None:
        hdr[:] = template[:HDR_SIZE]
    else:
        hdr[0x13] = 0x23
        hdr[0x15:0x18] = bytes([0x10, 0x60, 0x6C])
        hdr[0x34] = 0x02
    hdr[0x00:0x10] = MAGIC
    hdr[0x10] = PREFIX_LEN
    hdr[0x11] = 1
    hdr[0x12] = BLOCK_OFF
    hdr[ENTRY_OFF] = partn
    struct.pack_into("<II", hdr, ENTRY_OFF + 4, HDR_SIZE, len(squashfs))
    hdr[ENTRY_OFF + 0x0C:ENTRY_OFF + 0x1C] = squashfs[:16]
    struct.pack_into("<I", hdr, 0x30, BLOCK_LEN)
    code, flag = DEVICES[device]
    struct.pack_into("<I", hdr, 0x35, code)
    hdr[0x39] = 0 if flag == 0xF1 else flag
    struct.pack_into("<I", hdr, CRC_OFF, binascii.crc32(bytes(hdr[:CRC_OFF])) & 0xFFFFFFFF)
    return bytes(hdr) + hashlib.md5(squashfs).digest() + squashfs[16:]


def cmd_pack(a):
    sq = open(a.squashfs, "rb").read()
    if sq[:4] != b"hsqs":
        print("warning: input does not start with a squashfs superblock", file=sys.stderr)
    if a.partn < len(PARTITION_SIZES) and len(sq) > PARTITION_SIZES[a.partn]:
        raise SystemExit(f"{len(sq)} bytes does not fit partition {a.partn} ({PARTITIONS[a.partn]}, {PARTITION_SIZES[a.partn]} bytes)")
    tmpl = open(a.template, "rb").read() if a.template else None
    out = build(sq, template=tmpl, partn=a.partn, device=a.device)
    open(a.output, "wb").write(out)
    print(f"wrote {a.output}: {len(out)} bytes (header {HDR_SIZE} + payload {len(out) - HDR_SIZE}) for partition {a.partn} ({PARTITIONS[a.partn]}), {a.device}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("inspect", help="parse the header and verify every check the device makes")
    p.add_argument("image")
    p.set_defaults(fn=cmd_inspect)
    p = sub.add_parser("unpack", help="write the partition image (squashfs) out of an update.img")
    p.add_argument("image")
    p.add_argument("output")
    p.add_argument("--entry", type=int, default=0)
    p.set_defaults(fn=cmd_unpack)
    p = sub.add_parser("pack", help="build an update.img from a partition image")
    p.add_argument("squashfs")
    p.add_argument("output")
    p.add_argument("--template", help="a vendor update.img to copy the unchecked metadata bytes from")
    p.add_argument("--partn", type=int, default=3, help="target partition index (default 3 = res)")
    p.add_argument("--device", default="Zkswe_SSD21X_SPINOR", choices=sorted(DEVICES))
    p.set_defaults(fn=cmd_pack)
    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    main()
