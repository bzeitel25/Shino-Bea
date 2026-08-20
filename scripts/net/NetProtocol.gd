extends RefCounted
# ============================================================
# NetProtocol.gd — wire format for online co-op  (Run N+1, netcode spine)
# ============================================================
# Pure static helpers. NO class_name on purpose: this project has been bitten
# before by the global class cache failing to resolve on first load
# (see HeroBase.gd Batch-5 notes). Every consumer preloads this file:
#
#     const NetProtocol := preload("res://scripts/net/NetProtocol.gd")
#
# This file owns EVERY byte that crosses the wire. If a layout changes here,
# PROTOCOL_VERSION must be bumped in the same edit — mismatched builds are then
# refused at the handshake instead of desyncing three rooms later.
#
# Endianness: PackedByteArray.encode_* / decode_* are little-endian on every
# platform Godot targets, so no manual byte-swapping is needed.
# ============================================================

# --- Version ---------------------------------------------------------------
# Bump on ANY change to a packet layout, field meaning, or action bit order.
# v2 (Run N+2b) — added ui_accept / ui_cancel to ACTION_BITS so menus can route
#                 a remote player's confirm and back presses.
const PROTOCOL_VERSION: int = 2

# Bump on every release build whose GAMEPLAY differs (boon values, hero stats,
# spawn tables). Two builds with the same PROTOCOL_VERSION but different
# BUILD_TAG can still talk, but the host warns — because host-authoritative
# means the guest would silently be playing the host's balance numbers.
const BUILD_TAG: String = "2026.07.30-a"

# Default UDP port. Chosen high and uncommon; overridable in the lobby UI.
const DEFAULT_PORT: int = 24601


# --- Message types ---------------------------------------------------------
# First byte of every raw payload. Lets one channel carry several packet kinds
# and gives us a cheap sanity check before we trust any offsets.
enum Msg {
	INPUT    = 1,   # client -> host, unreliable ordered, 30 Hz
	SNAPSHOT = 2,   # host -> client, unreliable ordered, 20 Hz   (Run N+3)
	EVENT    = 3,   # host -> client, reliable, on change         (Run N+3)
	PING     = 4,   # either direction, unreliable
	PONG     = 5,
}


# --- ENet channels ---------------------------------------------------------
# Separate channels stop a big reliable EVENT burst from head-of-line blocking
# the 30 Hz input stream.
const CH_CONTROL: int  = 0   # reliable: handshake, events
const CH_INPUT: int    = 1   # unreliable ordered: client input
const CH_SNAPSHOT: int = 2   # unreliable ordered: world snapshots
const CHANNEL_COUNT: int = 3


# ============================================================
# Input packet
# ============================================================
# Layout (20 bytes, fixed — size is itself a validity check):
#   0   u8   msg   (Msg.INPUT)
#   1   u16  tick
#   3   u16  buttons  (bitfield, see ACTION_BITS)
#   5   i8   move_x     quantised -127..127
#   6   i8   move_y
#   7   i8   aim_x
#   8   i8   aim_y
#   9   u8   ui_choice  (UI_CHOICE_NONE = 255 when no menu answer)
#   10  u8   flags      (reserved)
#   11  u8   reserved
#   12  8B   hmac tag   (truncated HMAC-SHA256 over bytes 0..11)
# ============================================================

const INPUT_SIZE: int = 20
const INPUT_HMAC_OFFSET: int = 12
const INPUT_HMAC_LEN: int = 8
const UI_CHOICE_NONE: int = 255

# Bit index per action. MUST stay in the same order as the wire format forever
# (append new actions at the end, never reorder). These names match
# InputRouter.TRACKED_ACTIONS exactly so the host can replay them verbatim.
const ACTION_BITS: Dictionary = {
	"attack_y":      0,
	"attack_x":      1,
	"attack_a":      2,
	"dash":          3,
	"ult":           4,
	"swap_character": 5,
	"interact":      6,
	"pause":         7,
	"reroll":        8,
	"boon_inspect":  9,
	"ui_accept":    10,
	"ui_cancel":    11,
}
# 4 bits still free in the u16 buttons field. Append new actions at 12, 13, 14,
# 15 and bump PROTOCOL_VERSION; never reorder the existing ones.


# Quantise a -1..1 float to a signed byte.
static func q8(v: float) -> int:
	return int(round(clampf(v, -1.0, 1.0) * 127.0))


# Dequantise a signed byte back to -1..1.
static func dq8(v: int) -> float:
	return clampf(float(v) / 127.0, -1.0, 1.0)


# Pack a held-action dictionary ("action" -> bool) into the bitfield.
static func pack_buttons(held: Dictionary) -> int:
	var bits: int = 0
	for action in ACTION_BITS.keys():
		if bool(held.get(action, false)):
			bits |= (1 << int(ACTION_BITS[action]))
	return bits


# Unpack the bitfield back into an "action" -> bool dictionary.
static func unpack_buttons(bits: int) -> Dictionary:
	var out: Dictionary = {}
	for action in ACTION_BITS.keys():
		out[action] = (bits & (1 << int(ACTION_BITS[action]))) != 0
	return out


# Build an input packet. `hmac_key` may be empty during local loopback tests,
# in which case the tag is left zeroed and the host's verify step is skipped
# (only ever allowed when Net.LOOPBACK_UNSAFE is true).
static func pack_input(tick: int, buttons: int, move: Vector2, aim: Vector2,
		ui_choice: int, hmac_key: PackedByteArray) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(INPUT_SIZE)
	buf.encode_u8(0, Msg.INPUT)
	buf.encode_u16(1, tick & 0xFFFF)
	buf.encode_u16(3, buttons & 0xFFFF)
	buf.encode_s8(5, q8(move.x))
	buf.encode_s8(6, q8(move.y))
	buf.encode_s8(7, q8(aim.x))
	buf.encode_s8(8, q8(aim.y))
	buf.encode_u8(9, clampi(ui_choice, 0, 255))
	buf.encode_u8(10, 0)
	buf.encode_u8(11, 0)
	if not hmac_key.is_empty():
		var tag: PackedByteArray = _hmac(hmac_key, buf.slice(0, INPUT_HMAC_OFFSET))
		for i in range(INPUT_HMAC_LEN):
			buf.encode_u8(INPUT_HMAC_OFFSET + i, tag[i])
	return buf


# Parse + validate an input packet.
# Returns {} on ANY problem — the caller treats an empty dict as "bad packet,
# strike this peer". Never returns partially-filled data.
#
# LOCK: this function is the ONLY place raw client bytes are interpreted. It
# validates size, message type and MAC BEFORE reading any field, and clamps
# every value it returns. Nothing downstream may re-parse the raw buffer.
static func unpack_input(buf: PackedByteArray, hmac_key: PackedByteArray) -> Dictionary:
	if buf.size() != INPUT_SIZE:
		return {}
	if buf.decode_u8(0) != Msg.INPUT:
		return {}
	if not hmac_key.is_empty():
		var want: PackedByteArray = _hmac(hmac_key, buf.slice(0, INPUT_HMAC_OFFSET))
		for i in range(INPUT_HMAC_LEN):
			if want[i] != buf.decode_u8(INPUT_HMAC_OFFSET + i):
				return {}

	var move := Vector2(dq8(buf.decode_s8(5)), dq8(buf.decode_s8(6)))
	var aim := Vector2(dq8(buf.decode_s8(7)), dq8(buf.decode_s8(8)))
	# A modified client can send (127,127) => length 1.41. Clamp, don't reject:
	# rejecting would let a cheater cause their own packet loss on purpose.
	if move.length() > 1.0:
		move = move.normalized()
	if aim.length() > 1.0:
		aim = aim.normalized()

	return {
		"tick":      buf.decode_u16(1),
		"buttons":   buf.decode_u16(3),
		"move":      move,
		"aim":       aim,
		"ui_choice": buf.decode_u8(9),
		"flags":     buf.decode_u8(10),
	}


# ============================================================
# Ping / pong (liveness + RTT)
# ============================================================
const PING_SIZE: int = 9   # u8 msg + u64 client monotonic microseconds

static func pack_ping(stamp_usec: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(PING_SIZE)
	buf.encode_u8(0, Msg.PING)
	buf.encode_u64(1, stamp_usec)
	return buf


static func pack_pong(stamp_usec: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(PING_SIZE)
	buf.encode_u8(0, Msg.PONG)
	buf.encode_u64(1, stamp_usec)
	return buf


# Returns the echoed stamp, or -1 if the packet is malformed / wrong type.
static func unpack_ping(buf: PackedByteArray, expect: int) -> int:
	if buf.size() != PING_SIZE:
		return -1
	if buf.decode_u8(0) != expect:
		return -1
	return buf.decode_u64(1)


# ============================================================
# HMAC-SHA256 (shared by packets and the handshake)
# ============================================================
static func _hmac(key: PackedByteArray, msg: PackedByteArray) -> PackedByteArray:
	var crypto := Crypto.new()
	return crypto.hmac_digest(HashingContext.HASH_SHA256, key, msg)


# Public wrapper so NetSecurity/Net can MAC the handshake with the same code.
static func hmac(key: PackedByteArray, msg: PackedByteArray) -> PackedByteArray:
	return _hmac(key, msg)


# Constant-time compare. Using == on PackedByteArray short-circuits on the
# first differing byte, which leaks how much of a forged tag was correct.
# Not a serious threat over a 30 Hz UDP link, but this costs us nothing.
static func const_time_eq(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var diff: int = 0
	for i in range(a.size()):
		diff |= (a[i] ^ b[i])
	return diff == 0
