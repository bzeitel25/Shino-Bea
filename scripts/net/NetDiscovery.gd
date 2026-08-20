extends Node
# ============================================================
# NetDiscovery.gd — autoload singleton ("NetDiscovery")  ·  LAN lobby beacon
# ============================================================
# Makes same-network co-op zero-typing: the host shouts "I am here" on the
# local network once a second, and the joiner sees a live list of games to
# pick from. No join code, no IP address, no port number.
#
# This is a plain UDP broadcast on a fixed port, entirely separate from the
# game connection itself. Discovery only tells the joiner WHERE to connect;
# the actual connection still goes through Net.join_online() and still passes
# the full mutual-HMAC handshake in NetSecurity.gd. Discovery is convenience,
# never authority.
#
# ------------------------------------------------------------
# SECURITY NOTE — read before shipping
# ------------------------------------------------------------
# The beacon carries the full join ticket, INCLUDING the lobby secret. That is
# a deliberate trade: it is what makes LAN play one-button. It means anyone who
# can receive broadcast packets on your local network can join your game.
#
# That is the same trust boundary as handing someone a controller in your
# living room, which is exactly the situation LAN mode is for. It is NOT
# suitable for an untrusted network (a dorm, an office, a coffee shop) — on
# those, use Online mode, where the ticket only reaches the person you send it
# to. The lobby UI says this in plain language rather than hiding it.
#
# The host still sees exactly who connected and can leave at any time, and the
# lobby caps at one guest (ENet refuses the third connection outright).
# ============================================================

const NetProtocol := preload("res://scripts/net/NetProtocol.gd")

# Separate from the game port so a host can broadcast and a browser can listen
# on the same machine without fighting over a socket.
const BEACON_PORT: int = 24602
const MAGIC: String = "SBLAN"

const BROADCAST_INTERVAL: float = 1.0
# A lobby disappears from the list this long after its last beacon. Three
# missed beacons — long enough to ride out wifi jitter, short enough that a
# host who quit vanishes before anyone tries to join them.
const LOBBY_TIMEOUT: float = 3.5

signal lobbies_changed(lobbies: Array)

var _advertising: bool = false
var _browsing: bool = false
var _adv_socket: PacketPeerUDP = null
var _listen_socket: PacketPeerUDP = null
var _adv_accum: float = 0.0
var _adv_name: String = ""
var _adv_ticket: String = ""
var _broadcast_targets: PackedStringArray = PackedStringArray()

# address -> {name, ticket, address, last_seen_msec}
var _found: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


# ============================================================
# Host side
# ============================================================
func advertise(lobby_name: String, ticket: String) -> void:
	stop_advertising()
	_adv_name = lobby_name.substr(0, 24)
	_adv_ticket = ticket
	_adv_socket = PacketPeerUDP.new()
	_adv_socket.set_broadcast_enabled(true)
	_broadcast_targets = _compute_broadcast_targets()
	_advertising = true
	_adv_accum = BROADCAST_INTERVAL   # send one immediately
	set_process(true)
	Log.dbg("[NetDiscovery] Advertising '%s' on %s" % [_adv_name, ", ".join(_broadcast_targets)])


func stop_advertising() -> void:
	_advertising = false
	if _adv_socket != null:
		_adv_socket.close()
		_adv_socket = null
	_maybe_idle()


# ============================================================
# Joiner side
# ============================================================
func start_browsing() -> void:
	stop_browsing()
	_listen_socket = PacketPeerUDP.new()
	var err: int = _listen_socket.bind(BEACON_PORT, "*")
	if err != OK:
		push_warning("[NetDiscovery] Could not bind %d (error %d) — LAN browsing disabled."
			% [BEACON_PORT, err])
		_listen_socket = null
		return
	_browsing = true
	_found.clear()
	lobbies_changed.emit([])
	set_process(true)


func stop_browsing() -> void:
	_browsing = false
	if _listen_socket != null:
		_listen_socket.close()
		_listen_socket = null
	_found.clear()
	_maybe_idle()


# Sorted, stable list of what is currently visible.
func lobbies() -> Array:
	var out: Array = _found.values().duplicate()
	out.sort_custom(func(a, b) -> bool: return str(a["name"]) < str(b["name"]))
	return out


func _maybe_idle() -> void:
	if not _advertising and not _browsing:
		set_process(false)


# ============================================================
# Tick
# ============================================================
func _process(delta: float) -> void:
	if _advertising:
		_adv_accum += delta
		if _adv_accum >= BROADCAST_INTERVAL:
			_adv_accum = 0.0
			_send_beacon()
	if _browsing:
		_poll_beacons()
		_expire_stale()


func _send_beacon() -> void:
	if _adv_socket == null:
		return
	var pkt: PackedByteArray = _pack_beacon(_adv_name, _adv_ticket)
	for target in _broadcast_targets:
		_adv_socket.set_dest_address(target, BEACON_PORT)
		_adv_socket.put_packet(pkt)


func _poll_beacons() -> void:
	if _listen_socket == null:
		return
	var changed: bool = false
	# Bound the loop: a flood of packets must never stall the menu.
	var budget: int = 32
	while _listen_socket.get_available_packet_count() > 0 and budget > 0:
		budget -= 1
		var raw: PackedByteArray = _listen_socket.get_packet()
		var from_ip: String = _listen_socket.get_packet_ip()
		var info: Dictionary = _unpack_beacon(raw)
		if info.is_empty():
			continue   # not ours, or malformed — ignore silently
		var key: String = from_ip + "|" + str(info["name"])
		if not _found.has(key):
			changed = true
		_found[key] = {
			"name":    info["name"],
			"ticket":  info["ticket"],
			"address": from_ip,
			"seen":    Time.get_ticks_msec(),
		}
	if changed:
		lobbies_changed.emit(lobbies())


func _expire_stale() -> void:
	var now: int = Time.get_ticks_msec()
	var drop: Array = []
	for key in _found.keys():
		if now - int(_found[key]["seen"]) > int(LOBBY_TIMEOUT * 1000.0):
			drop.append(key)
	if drop.is_empty():
		return
	for key in drop:
		_found.erase(key)
	lobbies_changed.emit(lobbies())


# ============================================================
# Beacon packet
# ============================================================
# [MAGIC 5][u8 protocol][u8 name_len][name][u8 ticket_len][ticket]
func _pack_beacon(lobby_name: String, ticket: String) -> PackedByteArray:
	var nm: PackedByteArray = lobby_name.to_utf8_buffer()
	var tk: PackedByteArray = ticket.to_utf8_buffer()
	var buf := PackedByteArray()
	buf.append_array(MAGIC.to_utf8_buffer())
	buf.append(NetProtocol.PROTOCOL_VERSION & 0xFF)
	buf.append(mini(nm.size(), 255))
	buf.append_array(nm)
	buf.append(mini(tk.size(), 255))
	buf.append_array(tk)
	return buf


# Returns {} for anything that is not a beacon we understand. This parses
# unsolicited packets from the network, so it validates every length before
# reading and never trusts a declared size.
func _unpack_beacon(buf: PackedByteArray) -> Dictionary:
	var magic: PackedByteArray = MAGIC.to_utf8_buffer()
	var head: int = magic.size() + 1 + 1
	if buf.size() < head:
		return {}
	for i in range(magic.size()):
		if buf.decode_u8(i) != magic[i]:
			return {}
	if buf.decode_u8(magic.size()) != (NetProtocol.PROTOCOL_VERSION & 0xFF):
		return {}   # a neighbour running a different build — not a match
	var nlen: int = buf.decode_u8(magic.size() + 1)
	var nstart: int = head
	if buf.size() < nstart + nlen + 1:
		return {}
	var tlen: int = buf.decode_u8(nstart + nlen)
	var tstart: int = nstart + nlen + 1
	if buf.size() < tstart + tlen:
		return {}
	return {
		"name":   buf.slice(nstart, nstart + nlen).get_string_from_utf8(),
		"ticket": buf.slice(tstart, tstart + tlen).get_string_from_utf8(),
	}


# ============================================================
# Broadcast targets
# ============================================================
# 255.255.255.255 is the obvious choice but some routers and some Windows
# configurations drop it. Directed subnet broadcasts (192.168.1.255) get
# through more reliably, so we send to both and let duplicates be deduplicated
# by the receiver.
func _compute_broadcast_targets() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("255.255.255.255")
	for a in IP.get_local_addresses():
		var s: String = str(a)
		if s.contains(":") or s.begins_with("127.") or s.begins_with("169.254."):
			continue
		var parts: PackedStringArray = s.split(".")
		if parts.size() != 4:
			continue
		# Assumes a /24, which is what essentially every home router hands out.
		var directed: String = "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]
		if not out.has(directed):
			out.append(directed)
	return out


# Friendly default lobby name from the OS user, so the list reads
# "Bruno's game" rather than "192.168.1.44".
func default_lobby_name() -> String:
	var user: String = OS.get_environment("USERNAME")
	if user.is_empty():
		user = OS.get_environment("USER")
	if user.is_empty():
		user = "Ninja"
	return user.substr(0, 16) + " — Shino & Bea"
