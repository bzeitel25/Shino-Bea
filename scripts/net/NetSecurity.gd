extends RefCounted
# ============================================================
# NetSecurity.gd — join tickets, mutual auth, flood control  (Run N+1)
# ============================================================
# Preload, don't class_name:
#     const NetSecurity := preload("res://scripts/net/NetSecurity.gd")
#
# ------------------------------------------------------------
# WHAT THIS PROTECTS AGAINST (and what it does not)
# ------------------------------------------------------------
# ✔ A stranger who port-scans the host and finds the socket cannot join: the
#   handshake needs an 80-bit secret that only exists inside the ticket Bruno
#   pastes to his friend.
# ✔ A fake "host" cannot lure the guest: auth is MUTUAL — the host must also
#   prove it knows the secret before the guest completes the connection.
# ✔ Packets cannot be tampered with or injected in flight: every input packet
#   carries an HMAC over a per-session key.
# ✔ Replay across sessions is dead: the session key is derived from two fresh
#   random nonces, so a captured packet is worthless in the next lobby.
# ✔ Mismatched builds are refused at the door with a readable message.
#
# ✘ NOT CONFIDENTIAL in v1. Traffic is authenticated but not encrypted.
#   Godot 4 cannot set up DTLS on the ENet *client* side —
#   ENetConnection.dtls_client_setup() must run before connect_to_host(), which
#   ENetMultiplayerPeer.create_client() does internally
#   (godotengine/godot-proposals#10627). Server-side DTLS works; client-side
#   does not, so a half-configured DTLS link is not an option.
#   Mitigation: nothing sensitive ever crosses the wire (no accounts, no
#   passwords, no PII — just button presses and enemy coordinates), and relay
#   mode keeps both IPs private. The Steam transport (Tier 3) and the WebRTC
#   web build (Tier 4) are both encrypted by their platform for free.
#   Adding AES-CBC encrypt-then-MAC over this same session key is a contained
#   Run N+5 task if we ever want it.
# ============================================================

const NetProtocol := preload("res://scripts/net/NetProtocol.gd")


# --- Ticket ("join code") --------------------------------------------------
# The ticket is the single copy-pasteable string the host sends their friend.
# It is designed to be PASTED, not typed, so entropy is free — hence an 80-bit
# secret rather than a cute 6-character code.
#
# Byte layout before encoding:
#   0      u8   transport mode (see Mode)
#   1      u16  port
#   3..12  10B  shared secret (80 bits)
#   13     u16  protocol version
#   15     u8   address length
#   16..   N    address (UTF-8: IPv4, IPv6, hostname, or a relay peer id)
#
# Encoded with Crockford base32 (no I/L/O/U — nothing that reads as 1 or 0),
# uppercased, dash-grouped, prefixed "SB1".
const TICKET_PREFIX: String = "SB1"
const SECRET_LEN: int = 10
const B32_ALPHABET: String = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

enum Mode {
	DIRECT = 0,   # ENet straight to an IP:port (LAN, or WAN with a forwarded port)
	RELAY  = 1,   # ENet via noray punchthrough/relay — the default for internet play
	STEAM  = 2,   # Steam Sockets (Steam build only, Tier 3)
}


# --- Handshake -------------------------------------------------------------
const NONCE_LEN: int = 16
const AUTH_TAG_LEN: int = 32          # full HMAC-SHA256 for the handshake
const AUTH_TIMEOUT_SEC: float = 8.0

# Domain-separation labels. Using a different label for each direction means a
# challenge captured from the host can never be replayed back at the host as if
# it were the client's answer.
#
# ⚠ THESE MUST BE `static var`, NOT `const`.
# GDScript only folds VALUE types (Color, Vector2, Rect2, ...) into constant
# expressions. PackedByteArray is a heap-allocated container, so
# `const X: PackedByteArray = PackedByteArray([...])` is a constructor CALL in a
# constant initialiser and fails to parse with:
#     "Assigned value for constant "LABEL_CLIENT" isn't a constant expression."
# Because this script is an autoload dependency, that parse error stopped the
# whole game booting, not just the netcode. (Found and fixed 2026-07-31.)
#
# `static var` initialisers are evaluated at class-load time, so a constructor
# call is fine there. Read syntax at every call site is identical, so nothing
# downstream changed. Treat these as read-only.
static var LABEL_CLIENT: PackedByteArray = PackedByteArray([83, 66, 45, 67])  # "SB-C"
static var LABEL_HOST:   PackedByteArray = PackedByteArray([83, 66, 45, 72])  # "SB-H"
static var LABEL_KEY:    PackedByteArray = PackedByteArray([83, 66, 45, 75])  # "SB-K"

# Handshake stages, as the first byte of each auth payload.
enum Auth {
	CHALLENGE = 1,   # host -> client
	RESPONSE  = 2,   # client -> host
	ACCEPT    = 3,   # host -> client
	REJECT    = 4,   # host -> client
}

# Reject reasons — sent as a code, rendered as plain English by reason_text().
enum Reject {
	BAD_SECRET       = 1,
	PROTOCOL_MISMATCH = 2,
	BUILD_MISMATCH   = 3,
	LOBBY_FULL       = 4,
	MALFORMED        = 5,
	TIMEOUT          = 6,
	FLOOD            = 7,
}


static func reason_text(code: int) -> String:
	match code:
		Reject.BAD_SECRET:
			return "That join code is not right — ask for a fresh one."
		Reject.PROTOCOL_MISMATCH:
			return "You and the host are running different versions of the game."
		Reject.BUILD_MISMATCH:
			return "Your game build does not match the host build. Both of you need the same copy."
		Reject.LOBBY_FULL:
			return "That game is already full."
		Reject.MALFORMED:
			return "The connection sent something the game did not understand."
		Reject.TIMEOUT:
			return "The connection timed out before it finished setting up."
		Reject.FLOOD:
			return "Connection dropped: too much traffic from that peer."
		_:
			return "The connection was refused."


# ============================================================
# Secrets and keys
# ============================================================
static func make_secret() -> PackedByteArray:
	return Crypto.new().generate_random_bytes(SECRET_LEN)


static func make_nonce() -> PackedByteArray:
	return Crypto.new().generate_random_bytes(NONCE_LEN)


# Per-session packet key. Derived from the ticket secret plus BOTH nonces, so:
#   - every lobby gets a different key (captured packets never replay forward)
#   - neither side alone controls the key
static func derive_session_key(secret: PackedByteArray,
		host_nonce: PackedByteArray, client_nonce: PackedByteArray) -> PackedByteArray:
	var msg := PackedByteArray()
	msg.append_array(LABEL_KEY)
	msg.append_array(host_nonce)
	msg.append_array(client_nonce)
	return NetProtocol.hmac(secret, msg)


static func _proof(secret: PackedByteArray, label: PackedByteArray,
		host_nonce: PackedByteArray, client_nonce: PackedByteArray) -> PackedByteArray:
	var msg := PackedByteArray()
	msg.append_array(label)
	msg.append_array(host_nonce)
	msg.append_array(client_nonce)
	return NetProtocol.hmac(secret, msg)


# ============================================================
# Handshake payloads
# ============================================================
# All four are fixed-shape PackedByteArrays. They are handed to
# SceneMultiplayer.send_auth(), which means Godot will NOT deliver any other
# RPC to this peer until authentication completes — the entire game RPC surface
# stays closed to an unauthenticated stranger. That is the main reason we use
# the engine's auth_callback instead of hand-rolling a handshake over RPCs.

# host -> client:  [u8 CHALLENGE][16B host_nonce][u16 proto][u8 taglen][tag utf8]
static func build_challenge(host_nonce: PackedByteArray) -> PackedByteArray:
	var tag := NetProtocol.BUILD_TAG.to_utf8_buffer()
	var buf := PackedByteArray()
	buf.append(Auth.CHALLENGE)
	buf.append_array(host_nonce)
	var p := PackedByteArray(); p.resize(2); p.encode_u16(0, NetProtocol.PROTOCOL_VERSION)
	buf.append_array(p)
	buf.append(mini(tag.size(), 255))
	buf.append_array(tag)
	return buf


static func read_challenge(buf: PackedByteArray) -> Dictionary:
	if buf.size() < 1 + NONCE_LEN + 2 + 1:
		return {}
	if buf.decode_u8(0) != Auth.CHALLENGE:
		return {}
	var taglen: int = buf.decode_u8(1 + NONCE_LEN + 2)
	var start: int = 1 + NONCE_LEN + 2 + 1
	if buf.size() != start + taglen:
		return {}
	return {
		"host_nonce": buf.slice(1, 1 + NONCE_LEN),
		"protocol":   buf.decode_u16(1 + NONCE_LEN),
		"build_tag":  buf.slice(start, start + taglen).get_string_from_utf8(),
	}


# client -> host:  [u8 RESPONSE][16B client_nonce][32B proof][u16 proto][u8 taglen][tag utf8]
static func build_response(secret: PackedByteArray, host_nonce: PackedByteArray,
		client_nonce: PackedByteArray) -> PackedByteArray:
	var tag := NetProtocol.BUILD_TAG.to_utf8_buffer()
	var buf := PackedByteArray()
	buf.append(Auth.RESPONSE)
	buf.append_array(client_nonce)
	buf.append_array(_proof(secret, LABEL_CLIENT, host_nonce, client_nonce))
	var p := PackedByteArray(); p.resize(2); p.encode_u16(0, NetProtocol.PROTOCOL_VERSION)
	buf.append_array(p)
	buf.append(mini(tag.size(), 255))
	buf.append_array(tag)
	return buf


static func read_response(buf: PackedByteArray) -> Dictionary:
	var head: int = 1 + NONCE_LEN + AUTH_TAG_LEN + 2 + 1
	if buf.size() < head:
		return {}
	if buf.decode_u8(0) != Auth.RESPONSE:
		return {}
	var taglen: int = buf.decode_u8(head - 1)
	if buf.size() != head + taglen:
		return {}
	return {
		"client_nonce": buf.slice(1, 1 + NONCE_LEN),
		"proof":        buf.slice(1 + NONCE_LEN, 1 + NONCE_LEN + AUTH_TAG_LEN),
		"protocol":     buf.decode_u16(1 + NONCE_LEN + AUTH_TAG_LEN),
		"build_tag":    buf.slice(head, head + taglen).get_string_from_utf8(),
	}


# host -> client:  [u8 ACCEPT][32B host proof]
# The host proving itself back is what stops a fake lobby from harvesting a
# guest's connection — the guest hangs up if this proof is wrong.
static func build_accept(secret: PackedByteArray, host_nonce: PackedByteArray,
		client_nonce: PackedByteArray) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append(Auth.ACCEPT)
	buf.append_array(_proof(secret, LABEL_HOST, host_nonce, client_nonce))
	return buf


static func build_reject(code: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append(Auth.REJECT)
	buf.append(clampi(code, 0, 255))
	return buf


# Which stage is this payload? Returns 0 for anything unrecognisable.
static func peek_stage(buf: PackedByteArray) -> int:
	if buf.is_empty():
		return 0
	var s: int = buf.decode_u8(0)
	if s < Auth.CHALLENGE or s > Auth.REJECT:
		return 0
	return s


static func verify_client(secret: PackedByteArray, host_nonce: PackedByteArray,
		client_nonce: PackedByteArray, proof: PackedByteArray) -> bool:
	return NetProtocol.const_time_eq(
		_proof(secret, LABEL_CLIENT, host_nonce, client_nonce), proof)


static func verify_host(secret: PackedByteArray, host_nonce: PackedByteArray,
		client_nonce: PackedByteArray, proof: PackedByteArray) -> bool:
	return NetProtocol.const_time_eq(
		_proof(secret, LABEL_HOST, host_nonce, client_nonce), proof)


# ============================================================
# Ticket encode / decode
# ============================================================
static func encode_ticket(mode: int, address: String, port: int,
		secret: PackedByteArray) -> String:
	var addr := address.to_utf8_buffer()
	var buf := PackedByteArray()
	buf.append(clampi(mode, 0, 255))
	var p := PackedByteArray(); p.resize(2); p.encode_u16(0, clampi(port, 0, 65535))
	buf.append_array(p)
	buf.append_array(secret)
	var v := PackedByteArray(); v.resize(2); v.encode_u16(0, NetProtocol.PROTOCOL_VERSION)
	buf.append_array(v)
	buf.append(mini(addr.size(), 255))
	buf.append_array(addr)

	var body: String = _b32_encode(buf)
	# Dash-group in 5s so a human can read it back over voice if they must.
	var grouped := PackedStringArray()
	var i: int = 0
	while i < body.length():
		grouped.append(body.substr(i, 5))
		i += 5
	return TICKET_PREFIX + "-" + "-".join(grouped)


# Returns {} if the ticket is malformed. Never throws — this is fed directly
# from a paste box, so it sees garbage constantly.
static func decode_ticket(ticket: String) -> Dictionary:
	var s: String = ticket.strip_edges().to_upper().replace("-", "").replace(" ", "")
	if not s.begins_with(TICKET_PREFIX):
		return {}
	s = s.substr(TICKET_PREFIX.length())
	var buf: PackedByteArray = _b32_decode(s)
	var head: int = 1 + 2 + SECRET_LEN + 2 + 1
	if buf.size() < head:
		return {}
	var alen: int = buf.decode_u8(head - 1)
	if buf.size() < head + alen:
		return {}
	var mode: int = buf.decode_u8(0)
	if mode < Mode.DIRECT or mode > Mode.STEAM:
		return {}
	return {
		"mode":     mode,
		"port":     buf.decode_u16(1),
		"secret":   buf.slice(3, 3 + SECRET_LEN),
		"protocol": buf.decode_u16(3 + SECRET_LEN),
		"address":  buf.slice(head, head + alen).get_string_from_utf8(),
	}


static func _b32_encode(data: PackedByteArray) -> String:
	var out: String = ""
	var acc: int = 0
	var bits: int = 0
	for b in data:
		acc = (acc << 8) | int(b)
		bits += 8
		while bits >= 5:
			bits -= 5
			out += B32_ALPHABET[(acc >> bits) & 0x1F]
	if bits > 0:
		out += B32_ALPHABET[(acc << (5 - bits)) & 0x1F]
	return out


static func _b32_decode(s: String) -> PackedByteArray:
	var out := PackedByteArray()
	var acc: int = 0
	var bits: int = 0
	for i in range(s.length()):
		var idx: int = B32_ALPHABET.find(s[i])
		if idx < 0:
			return PackedByteArray()   # any stray character invalidates the whole ticket
		acc = (acc << 5) | idx
		bits += 5
		if bits >= 8:
			bits -= 8
			out.append((acc >> bits) & 0xFF)
	return out


# ============================================================
# Flood control — token bucket, one per peer
# ============================================================
# A modified client can send as fast as its NIC allows. Without this, 5000
# packets/sec of well-formed input would pin the host's main thread parsing
# them. The bucket costs one float per peer.
class RateLimiter extends RefCounted:
	var _tokens: float
	var _rate: float
	var _burst: float
	var _last_usec: int

	func _init(rate_per_sec: float, burst: float) -> void:
		_rate = rate_per_sec
		_burst = burst
		_tokens = burst
		_last_usec = Time.get_ticks_usec()

	# true = allowed, false = over budget (caller should strike the peer)
	func allow() -> bool:
		var now: int = Time.get_ticks_usec()
		var dt: float = float(now - _last_usec) / 1_000_000.0
		_last_usec = now
		_tokens = minf(_burst, _tokens + dt * _rate)
		if _tokens < 1.0:
			return false
		_tokens -= 1.0
		return true


# Budgets. Input runs at 30 Hz; 45/s leaves headroom for jitter bursts without
# leaving room for abuse.
const INPUT_RATE: float = 45.0
const INPUT_BURST: float = 20.0
const CONTROL_RATE: float = 20.0
const CONTROL_BURST: float = 10.0

# Strikes before a peer is dropped. Deliberately small: everything that earns a
# strike is something a legitimate client never does.
const MAX_STRIKES: int = 3
