extends RefCounted
# ============================================================
# NetTransport.gd — peer creation per transport tier  (Run N+1)
# ============================================================
# Preload, don't class_name:
#     const NetTransport := preload("res://scripts/net/NetTransport.gd")
#
# Everything above this file is transport-blind. Net.gd asks for "a host peer
# in mode X" and gets back a MultiplayerPeer; the RPC layer, the input pipe and
# the snapshot system never learn which tier produced it. That is the whole
# reason we can add Steam later without touching gameplay code.
#
# Tier 1  RELAY   ENet via noray punchthrough/relay — no port forwarding.  ← default for internet
# Tier 2  DIRECT  ENet straight to ip:port — LAN, or WAN with a forwarded port.
# Tier 3  STEAM   Steam Sockets (Steam build only).                        ← last
# Tier 4  WEBRTC  browser build only; lives in the separate Glitch project.
# ============================================================

const NetSecurity := preload("res://scripts/net/NetSecurity.gd")
const NetProtocol := preload("res://scripts/net/NetProtocol.gd")

# Only ever one guest. ENet itself refuses the third connection, before a
# single byte reaches our code — cheapest possible lobby cap.
const MAX_CLIENTS: int = 1

# Addon detection. noray ships as a Godot Asset Library addon; until Bruno
# installs it, RELAY mode reports a readable error instead of crashing.
const NORAY_SCRIPT: String = "res://addons/netfox.noray/noray.gd"


static func has_noray() -> bool:
	return ResourceLoader.exists(NORAY_SCRIPT)


static func mode_name(mode: int) -> String:
	match mode:
		NetSecurity.Mode.DIRECT: return "Direct / LAN"
		NetSecurity.Mode.RELAY:  return "Relay (no port forwarding)"
		NetSecurity.Mode.STEAM:  return "Steam"
		_: return "Unknown"


# ============================================================
# Host
# ============================================================
# Returns {ok: bool, peer: MultiplayerPeer, address: String, error: String}
# `address` is what should go into the join ticket.
static func create_host(mode: int, port: int) -> Dictionary:
	match mode:
		NetSecurity.Mode.DIRECT:
			return _host_enet(port)
		NetSecurity.Mode.RELAY:
			if not has_noray():
				return _fail("Relay mode needs the netfox.noray addon.\n" +
					"Install it from the Godot Asset Library into addons/, then restart the editor.\n" +
					"Direct / LAN mode works right now with no addon.")
			return _fail("Relay host path is wired in Run N+2 — see Online_Multiplayer_Spec.md §8.")
		NetSecurity.Mode.STEAM:
			return _fail("Steam transport is Tier 3 and is deliberately last. Use Direct or Relay.")
	return _fail("Unknown transport mode %d." % mode)


static func _host_enet(port: int) -> Dictionary:
	var peer := ENetMultiplayerPeer.new()
	var err: int = peer.create_server(port, MAX_CLIENTS, NetProtocol.CHANNEL_COUNT)
	if err != OK:
		if err == ERR_ALREADY_IN_USE or err == ERR_CANT_CREATE:
			return _fail("Could not open port %d — something else is already using it.\n" % port +
				"Try a different port, or close the other copy of the game.")
		return _fail("Could not start hosting (error %d)." % err)

	# Server-side DTLS is possible here (peer.host.dtls_server_setup) but is
	# useless on its own: Godot 4 cannot configure DTLS on the ENet CLIENT side,
	# because dtls_client_setup() must run before connect_to_host() and
	# create_client() does that internally (godot-proposals#10627). A one-sided
	# DTLS setup just refuses every connection. See NetSecurity.gd header for
	# the full reasoning and what we do instead.

	return {"ok": true, "peer": peer, "address": best_local_address(), "error": ""}


# ============================================================
# Join
# ============================================================
static func create_client(mode: int, address: String, port: int) -> Dictionary:
	match mode:
		NetSecurity.Mode.DIRECT:
			return _join_enet(address, port)
		NetSecurity.Mode.RELAY:
			if not has_noray():
				return _fail("This join code needs the netfox.noray addon. It is not installed.")
			return _fail("Relay join path is wired in Run N+2 — see Online_Multiplayer_Spec.md §8.")
		NetSecurity.Mode.STEAM:
			return _fail("Steam transport is Tier 3 and is deliberately last.")
	return _fail("Unknown transport mode %d." % mode)


static func _join_enet(address: String, port: int) -> Dictionary:
	if address.strip_edges().is_empty():
		return _fail("That join code has no address in it.")
	var peer := ENetMultiplayerPeer.new()
	var err: int = peer.create_client(address, port, NetProtocol.CHANNEL_COUNT)
	if err != OK:
		return _fail("Could not reach %s:%d (error %d).\n" % [address, port, err] +
			"If you are not on the same network as the host, you need Relay mode —\n" +
			"Direct mode only works on a LAN or with a forwarded port.")
	return {"ok": true, "peer": peer, "address": address, "error": ""}


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "peer": null, "address": "", "error": msg}


# ============================================================
# Address helpers
# ============================================================
# Best guess at the LAN address to put in a Direct-mode ticket. Prefers a
# private IPv4 (192.168.x / 10.x / 172.16-31.x) because that is what a friend
# on the same network needs; skips loopback, link-local and IPv6.
static func best_local_address() -> String:
	var fallback: String = ""
	for a in IP.get_local_addresses():
		var s: String = str(a)
		if s.contains(":"):
			continue                      # IPv6
		if s.begins_with("127.") or s.begins_with("169.254."):
			continue                      # loopback / link-local
		if _is_private_v4(s):
			return s
		if fallback.is_empty():
			fallback = s
	if not fallback.is_empty():
		return fallback
	return "127.0.0.1"


static func _is_private_v4(s: String) -> bool:
	if s.begins_with("192.168.") or s.begins_with("10."):
		return true
	if s.begins_with("172."):
		var parts: PackedStringArray = s.split(".")
		if parts.size() > 1:
			var second: int = int(parts[1])
			return second >= 16 and second <= 31
	return false


static func all_local_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	for a in IP.get_local_addresses():
		var s: String = str(a)
		if s.contains(":") or s.begins_with("127."):
			continue
		out.append(s)
	return out
