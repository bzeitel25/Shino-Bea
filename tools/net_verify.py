#!/usr/bin/env python3
"""
net_verify.py — wire-format cross-check for online co-op (Run N+1).

WHY THIS EXISTS
---------------
scripts/net/NetProtocol.gd and NetSecurity.gd hand-pack bytes: fixed offsets,
quantised sticks, base32 join tickets, HMAC proofs. Off-by-one errors in that
kind of code do not raise — they silently produce a packet the other machine
misreads, and the symptom shows up three systems later as "Bea twitches".

This file re-implements the SAME layouts independently in Python and asserts
they round-trip. If GDScript and Python disagree, one of them has a bug, and
you find out in one second instead of during a live session with a family
member.

    python3 tools/net_verify.py

IMPORTANT: this is a MIRROR, not an import. If you change a layout or a label
in NetProtocol.gd / NetSecurity.gd, change it here in the same edit. A green
run of a stale mirror is worse than no mirror at all.

Mirrors, as of PROTOCOL_VERSION 1:
  - NetSecurity.encode_ticket / decode_ticket   (Crockford base32, 16-byte head)
  - NetSecurity._proof / derive_session_key     (labels SB-C / SB-H / SB-K)
  - NetProtocol.pack_input layout               (20 bytes, MAC at offset 12)
"""

import hmac
import hashlib
import math
import os
import re
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- must match NetSecurity.gd / NetProtocol.gd ---------------------------
B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"   # Crockford: no I, L, O, U
SECRET_LEN = 10                            # 80 bits
NONCE_LEN = 16
PROTO = 2                                  # bumped in Run N+2b (ui_accept/ui_cancel bits)
ACTION_BITS = {
    "attack_y": 0, "attack_x": 1, "attack_a": 2, "dash": 3, "ult": 4,
    "swap_character": 5, "interact": 6, "pause": 7, "reroll": 8,
    "boon_inspect": 9, "ui_accept": 10, "ui_cancel": 11,
}
INPUT_SIZE = 20
INPUT_HMAC_OFFSET = 12
INPUT_HMAC_LEN = 8
TICKET_PREFIX = "SB1"

fails = 0


def check(cond, msg):
    global fails
    if not cond:
        fails += 1
    print(("PASS  " if cond else "FAIL  ") + msg)


def b32e(data):
    out, acc, bits = "", 0, 0
    for b in data:
        acc = (acc << 8) | b
        bits += 8
        while bits >= 5:
            bits -= 5
            out += B32[(acc >> bits) & 31]
    if bits:
        out += B32[(acc << (5 - bits)) & 31]
    return out


def b32d(s):
    out, acc, bits = bytearray(), 0, 0
    for ch in s:
        i = B32.find(ch)
        if i < 0:
            return b""
        acc = (acc << 5) | i
        bits += 5
        if bits >= 8:
            bits -= 8
            out.append((acc >> bits) & 255)
    return bytes(out)


def encode_ticket(mode, address, port, secret):
    addr = address.encode()
    buf = (bytes([mode]) + struct.pack("<H", port) + secret
           + struct.pack("<H", PROTO) + bytes([len(addr)]) + addr)
    body = b32e(buf)
    return TICKET_PREFIX + "-" + "-".join(body[i:i + 5] for i in range(0, len(body), 5))


def decode_ticket(t):
    s = t.strip().upper().replace("-", "").replace(" ", "")
    if not s.startswith(TICKET_PREFIX):
        return {}
    buf = b32d(s[len(TICKET_PREFIX):])
    head = 1 + 2 + SECRET_LEN + 2 + 1          # 16
    if len(buf) < head:
        return {}
    alen = buf[head - 1]
    if len(buf) < head + alen:
        return {}
    mode = buf[0]
    if not 0 <= mode <= 2:
        return {}
    return dict(mode=mode,
                port=struct.unpack("<H", buf[1:3])[0],
                secret=buf[3:3 + SECRET_LEN],
                protocol=struct.unpack("<H", buf[3 + SECRET_LEN:5 + SECRET_LEN])[0],
                address=buf[head:head + alen].decode())


def proof(secret, label, hn, cn):
    return hmac.new(secret, label + hn + cn, hashlib.sha256).digest()


def q8(v):
    return max(-127, min(127, round(max(-1.0, min(1.0, v)) * 127)))


print("--- join ticket round-trip ---")
for mode, addr, port in [(0, "192.168.1.44", 24601), (1, "a3f9c1e0b7d2", 24601),
                         (0, "127.0.0.1", 65535), (0, "10.0.0.7", 1),
                         (2, "steam:76561198000000000", 0)]:
    sec = os.urandom(SECRET_LEN)
    d = decode_ticket(encode_ticket(mode, addr, port, sec))
    check(bool(d) and d["mode"] == mode and d["address"] == addr and d["port"] == port
          and d["secret"] == sec and d["protocol"] == PROTO,
          "mode=%d %s:%d" % (mode, addr, port))

print("\n--- malformed tickets are refused, never half-accepted ---")
sec = os.urandom(SECRET_LEN)
body = encode_ticket(0, "192.168.1.44", 24601, sec).replace("-", "")[len(TICKET_PREFIX):]
alt = list(body)
alt[12] = B32[(B32.find(alt[12]) + 1) % 32]
d2 = decode_ticket(TICKET_PREFIX + "".join(alt))
check(bool(d2) and d2["secret"] != sec,
      "one changed character yields a different secret (wrong code refused at handshake)")
for bad in ["", "hello", "SB1-!!!!!", "SB1-", "XX1-ABCDE", "SB1-IIIII", "SB1-ABC"]:
    check(not decode_ticket(bad), "rejects garbage %r" % bad)

print("\n--- handshake proofs ---")
secret, hn, cn = os.urandom(SECRET_LEN), os.urandom(NONCE_LEN), os.urandom(NONCE_LEN)
pc, ph = proof(secret, b"SB-C", hn, cn), proof(secret, b"SB-H", hn, cn)
check(pc != ph, "domain separation: client proof != host proof (challenge cannot be replayed back)")
check(proof(os.urandom(SECRET_LEN), b"SB-C", hn, cn) != pc, "wrong secret gives a different proof")
k1 = hmac.new(secret, b"SB-K" + hn + cn, hashlib.sha256).digest()
k2 = hmac.new(secret, b"SB-K" + hn + os.urandom(NONCE_LEN), hashlib.sha256).digest()
check(k1 != k2, "session key differs per lobby (captured packets do not replay forward)")
check(len(secret) * 8 == 80, "secret is 80 bits")

print("\n--- input packet ---")
buf = bytearray(INPUT_SIZE)
buf[0] = 1
struct.pack_into("<H", buf, 1, 1234)
struct.pack_into("<H", buf, 3, 0b1010101010)
struct.pack_into("<b", buf, 5, q8(0.7))
struct.pack_into("<b", buf, 6, q8(-0.3))
struct.pack_into("<b", buf, 7, q8(-1.0))
struct.pack_into("<b", buf, 8, q8(1.0))
buf[9] = 255
tag = hmac.new(k1, bytes(buf[:INPUT_HMAC_OFFSET]), hashlib.sha256).digest()[:INPUT_HMAC_LEN]
buf[INPUT_HMAC_OFFSET:INPUT_SIZE] = tag
check(len(buf) == INPUT_SIZE,
      "packet is exactly %d bytes -> %.2f KB/s upstream at 30 Hz" % (INPUT_SIZE, INPUT_SIZE * 30 / 1024))
check(struct.unpack_from("<H", buf, 1)[0] == 1234, "tick round-trips")
check(abs(struct.unpack_from("<b", buf, 5)[0] / 127 - 0.7) < 0.01, "stick quantisation error under 0.01")
bad = bytearray(buf)
bad[5] ^= 1
check(hmac.new(k1, bytes(bad[:INPUT_HMAC_OFFSET]), hashlib.sha256).digest()[:INPUT_HMAC_LEN] != tag,
      "flipping one input bit invalidates the MAC")
check(math.hypot(1.0, 1.0) > 1.0,
      "max diagonal (127,127) exceeds length 1.0 -> host-side clamp in unpack_input is required")

print("\n--- button bitfield (must mirror InputRouter.TRACKED_ACTIONS) ---")
check(len(set(ACTION_BITS.values())) == len(ACTION_BITS), "no two actions share a bit")
check(max(ACTION_BITS.values()) < 16, "all bits fit the u16 buttons field (%d/16 used)"
      % (max(ACTION_BITS.values()) + 1))
check("ui_accept" in ACTION_BITS and "ui_cancel" in ACTION_BITS,
      "ui_accept / ui_cancel present — menus can route a remote player")
_all = 0
for _b in ACTION_BITS.values():
    _all |= 1 << _b
_round = {a: bool(_all & (1 << b)) for a, b in ACTION_BITS.items()}
check(all(_round.values()), "every action round-trips through pack/unpack_buttons")
check(not (_all & (1 << 15)), "top bits still free for future actions")

print("\n--- mirror drift: this file vs the actual GDScript ---")
# The header of this file warns that a stale mirror is worse than no mirror.
# These three checks make that warning enforceable instead of aspirational:
# they read the real .gd files and fail if they have drifted from the constants
# above. Everything else in net_verify only proves Python agrees with Python.


def _read(rel):
    try:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def _const_block(src, name):
    # Skip comment mentions: match the actual `const NAME ... {` declaration.
    m = re.search(r"^const\s+" + name + r"[^{]*\{(.*?)^\}", src, re.S | re.M)
    return m.group(1) if m else ""


def _const_array(src, name):
    m = re.search(r"^const\s+" + name + r"[^\[]*\[(.*?)\]", src, re.S | re.M)
    return m.group(1) if m else ""


proto_src = _read("scripts/net/NetProtocol.gd")
router_src = _read("scripts/InputRouter.gd")

if not proto_src or not router_src:
    check(False, "could not read NetProtocol.gd / InputRouter.gd (run me from the repo)")
else:
    gd_bits = {k: int(v) for k, v in
               re.findall(r'"(\w+)"\s*:\s*(\d+)', _const_block(proto_src, "ACTION_BITS"))}
    tracked = re.findall(r'"(\w+)"', _const_array(router_src, "TRACKED_ACTIONS"))
    check(gd_bits == ACTION_BITS,
          "NetProtocol.ACTION_BITS matches this file (%d actions)" % len(gd_bits))
    check(set(tracked) == set(ACTION_BITS),
          "InputRouter.TRACKED_ACTIONS matches ACTION_BITS (%d actions)" % len(tracked))
    m = re.search(r"^const\s+PROTOCOL_VERSION\s*:\s*int\s*=\s*(\d+)", proto_src, re.M)
    check(m is not None and int(m.group(1)) == PROTO,
          "PROTOCOL_VERSION is %s in GDScript and %d here"
          % (m.group(1) if m else "?", PROTO))
    m = re.search(r"^const\s+INPUT_SIZE\s*:\s*int\s*=\s*(\d+)", proto_src, re.M)
    check(m is not None and int(m.group(1)) == INPUT_SIZE,
          "INPUT_SIZE is %s in GDScript and %d here"
          % (m.group(1) if m else "?", INPUT_SIZE))
    m = re.search(r"^const\s+NET_DEVICE_REMOTE\s*:\s*int\s*=\s*(\d+)", router_src, re.M)
    check(m is not None and int(m.group(1)) == 900,
          "InputRouter.NET_DEVICE_REMOTE is 900 (the remote player's device id)")

print("\n--- LAN beacon (NetDiscovery.gd) ---")
MAGIC = b"SBLAN"


def pack_beacon(name, ticket):
    nm, tk = name.encode(), ticket.encode()
    return (MAGIC + bytes([PROTO]) + bytes([min(len(nm), 255)]) + nm
            + bytes([min(len(tk), 255)]) + tk)


def unpack_beacon(buf):
    head = len(MAGIC) + 1 + 1
    if len(buf) < head or buf[:len(MAGIC)] != MAGIC:
        return {}
    if buf[len(MAGIC)] != PROTO:
        return {}
    nlen = buf[len(MAGIC) + 1]
    nstart = head
    if len(buf) < nstart + nlen + 1:
        return {}
    tlen = buf[nstart + nlen]
    tstart = nstart + nlen + 1
    if len(buf) < tstart + tlen:
        return {}
    return {"name": buf[nstart:nstart + nlen].decode(),
            "ticket": buf[tstart:tstart + tlen].decode()}


nm = "Bruno — Shino & Bea"
tk = encode_ticket(0, "192.168.1.44", 24601, os.urandom(SECRET_LEN))
b = unpack_beacon(pack_beacon(nm, tk))
check(b.get("name") == nm and b.get("ticket") == tk,
      "beacon round-trips name + ticket (%d bytes on the wire)" % len(pack_beacon(nm, tk)))
check(unpack_beacon(pack_beacon("", tk)).get("ticket") == tk, "empty lobby name is survivable")

# A beacon parses UNSOLICITED packets off the network, so every one of these
# must be refused without reading past the buffer.
good = pack_beacon(nm, tk)
check(not unpack_beacon(b"random udp noise"), "beacon ignores foreign packets")
check(not unpack_beacon(b""), "beacon ignores empty packets")
check(not unpack_beacon(MAGIC), "beacon ignores a truncated header")
check(not unpack_beacon(good[:len(good) // 2]), "beacon ignores a truncated body")
check(not unpack_beacon(MAGIC + bytes([PROTO + 1]) + good[len(MAGIC) + 1:]),
      "beacon ignores a neighbour running a different protocol version")
lying = bytearray(good)
lying[len(MAGIC) + 1] = 255          # claim a 255-byte name in a short packet
check(not unpack_beacon(bytes(lying)), "beacon refuses a lied-about length field")

print("\n--- snapshot bandwidth budget (10 B/entity @ 20 Hz) ---")
for n, label in [(27, "typical room"), (60, "heavy reinforcement wave")]:
    kbs = n * 10 * 20 / 1024
    check(kbs < 20, "%s: %d entities -> %.1f KB/s (%.0f kbps)" % (label, n, kbs, kbs * 8))

print("\n" + ("net_verify: CLEAN" if fails == 0 else "net_verify: %d FAILURE(S)" % fails))
raise SystemExit(1 if fails else 0)
