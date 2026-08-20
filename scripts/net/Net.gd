extends Node
# ============================================================
# Net.gd — autoload singleton ("Net")  ·  online co-op session spine (Run N+1)
# ============================================================
# Owns the connection and nothing else. No gameplay logic lives here: this file
# gets two machines talking, proves they are who they say they are, and hands
# later runs a clean, authenticated pipe.
#
#   Run N+1 (this file)  session + handshake + ping          ← you are here
#   Run N+2              input pipe  -> InputRouter device 900
#   Run N+3              snapshots + replicas + prediction
#   Run N+4              shared systems (boons, gates, pause, revive)
#   Run N+5              security hardening + malicious-client fuzz
#
# ------------------------------------------------------------
# THE LOCK — the rule the whole design rests on
# ------------------------------------------------------------
# The client sends INTENT ONLY. Button state, stick vectors, menu choices.
# It never sends, and the host never accepts, a position, an HP value, a damage
# number, a boon effect, or a kill. Every one of those is computed on the host.
# If a future run adds a client->host RPC carrying game state, that run has
# introduced a cheat, not a feature.
#
# ------------------------------------------------------------
# RPC RULES (each of these is a real Godot 4 footgun)
# ------------------------------------------------------------
#  1. allow_object_decoding stays false. With it on, an RPC argument can
#     instantiate an arbitrary object with an arbitrary script — that is remote
#     code execution on the other player's PC. It is set explicitly below so
#     nobody "helpfully" turns it on later.
#  2. Never bytes_to_var(data, true). Same hole, different door.
#  3. Every @rpc("any_peer") handler's FIRST line is a sender check. No
#     exceptions. An any_peer RPC without one should fail review.
#  4. Host -> client RPCs are @rpc("authority") so a client cannot invoke them.
#  5. Never index an array with a client-supplied integer without a bounds
#     check. This is the single most likely real exploit in the design.
#  6. No paths, no NodePaths, no load() targets from the wire. Entities are
#     referenced by integer net_id through a host-owned registry.
# ============================================================

const NetProtocol := preload("res://scripts/net/NetProtocol.gd")
const NetSecurity := preload("res://scripts/net/NetSecurity.gd")
const NetTransport := preload("res://scripts/net/NetTransport.gd")

# Skip packet MAC verification. ONLY for single-machine loopback debugging.
# Must be false in anything that leaves Bruno's desk.
const LOOPBACK_UNSAFE: bool = false

# The host is always peer id 1 in Godot's high-level multiplayer.
const HOST_ID: int = 1


enum State { OFFLINE, HOSTING, JOINING, CONNECTED, FAILED }

signal state_changed(state: int)
signal log_line(text: String)
signal guest_joined(peer_id: int)
signal guest_left(reason: String)
signal session_failed(reason: String)
# Run N+2b — a validated input packet from the guest (host side only).
signal input_packet(pkt: Dictionary)
# Run N+2b — host -> client menu/UI state. Host-authoritative by construction:
# this is an @rpc("authority") channel, so a client can never send one.
signal menu_message(kind: String, data: Dictionary)

# --- Session ---------------------------------------------------------------
var state: int = State.OFFLINE
var mode: int = NetSecurity.Mode.DIRECT
var hosting: bool = false
var ticket: String = ""                     # host only: the string you paste to a friend
var rtt_ms: int = -1                        # client only: last measured round trip
var last_error: String = ""

var _secret: PackedByteArray = PackedByteArray()        # from/for the ticket
var _session_key: PackedByteArray = PackedByteArray()   # per-session packet MAC key
var _authorised_client: int = 0                         # host only: the one legal guest
var _host_nonces: Dictionary = {}                       # peer_id -> host nonce (host side)
var _client_nonce: PackedByteArray = PackedByteArray()  # client side
var _strikes: Dictionary = {}                           # peer_id -> int
var _input_limiter: Dictionary = {}                     # peer_id -> RateLimiter
var _control_limiter: Dictionary = {}                   # peer_id -> RateLimiter
var _pending_reject: int = 0                            # client side: why the host said no

var _ping_accum: float = 0.0
const PING_INTERVAL: float = 0.5


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # networking must survive tree pauses
	set_process(false)


# ============================================================
# Public API
# ============================================================
func is_online() -> bool:
	return state == State.CONNECTED or state == State.HOSTING or state == State.JOINING


func is_connected_pair() -> bool:
	return state == State.CONNECTED


func is_host() -> bool:
	return hosting


# The ONE authority check. Every client->host RPC calls this on its first line.
func is_authorised_client(peer_id: int) -> bool:
	return hosting and peer_id != 0 and peer_id == _authorised_client


# The connected guest's peer id, or 0. Used when something needs to name the
# guest — striking them, addressing an RPC at them.
func client_id() -> int:
	return _authorised_client


func state_name() -> String:
	match state:
		State.OFFLINE:   return "Offline"
		State.HOSTING:   return "Hosting — waiting for a friend"
		State.JOINING:   return "Connecting…"
		State.CONNECTED: return "Connected"
		State.FAILED:    return "Failed"
	return "?"


# --- Host ------------------------------------------------------------------
# Returns {ok: bool, error: String}. On success `ticket` holds the join code.
func host_online(p_mode: int = NetSecurity.Mode.DIRECT,
		port: int = NetProtocol.DEFAULT_PORT) -> Dictionary:
	leave()
	var made: Dictionary = NetTransport.create_host(p_mode, port)
	if not bool(made.get("ok", false)):
		return _fail_session(str(made.get("error", "Could not start hosting.")))

	mode = p_mode
	hosting = true
	_secret = NetSecurity.make_secret()
	ticket = NetSecurity.encode_ticket(p_mode, str(made.get("address", "")), port, _secret)

	_configure_multiplayer()
	multiplayer.multiplayer_peer = made["peer"]
	_set_state(State.HOSTING)
	_log("Hosting on %s:%d (%s)" % [made.get("address", "?"), port, NetTransport.mode_name(p_mode)])
	_log("Join code ready — send it to your friend.")
	set_process(true)
	return {"ok": true, "error": ""}


# --- Join ------------------------------------------------------------------
func join_online(ticket_string: String) -> Dictionary:
	leave()
	var t: Dictionary = NetSecurity.decode_ticket(ticket_string)
	if t.is_empty():
		return _fail_session("That does not look like a join code. It should start with SB1- .")
	if int(t.get("protocol", -1)) != NetProtocol.PROTOCOL_VERSION:
		return _fail_session(NetSecurity.reason_text(NetSecurity.Reject.PROTOCOL_MISMATCH))

	var made: Dictionary = NetTransport.create_client(
		int(t["mode"]), str(t["address"]), int(t["port"]))
	if not bool(made.get("ok", false)):
		return _fail_session(str(made.get("error", "Could not connect.")))

	mode = int(t["mode"])
	hosting = false
	_secret = t["secret"]
	_client_nonce = NetSecurity.make_nonce()
	ticket = ""

	_configure_multiplayer()
	multiplayer.multiplayer_peer = made["peer"]
	_set_state(State.JOINING)
	_log("Connecting to %s:%d…" % [t["address"], t["port"]])
	set_process(true)
	return {"ok": true, "error": ""}


# --- Leave -----------------------------------------------------------------
func leave() -> void:
	set_process(false)
	var mpeer: MultiplayerPeer = multiplayer.multiplayer_peer
	if mpeer != null and not (mpeer is OfflineMultiplayerPeer):
		mpeer.close()
	multiplayer.multiplayer_peer = null
	_disconnect_signals()
	hosting = false
	ticket = ""
	rtt_ms = -1
	_secret = PackedByteArray()
	_session_key = PackedByteArray()
	_authorised_client = 0
	_host_nonces.clear()
	_client_nonce = PackedByteArray()
	_strikes.clear()
	_input_limiter.clear()
	_control_limiter.clear()
	_pending_reject = 0
	if state != State.OFFLINE:
		_set_state(State.OFFLINE)


# --- Outbound helpers used by later runs -----------------------------------
# Run N+2 calls this 30x/sec from the client. Kept here so the MAC key never
# has to leave this file.
func send_input(buf: PackedByteArray) -> void:
	if hosting or state != State.CONNECTED:
		return
	# Node.rpc_id(peer, "method", args) form — works on every Godot 4.x point
	# release, unlike the Callable.rpc_id() shorthand.
	rpc_id(HOST_ID, "_rx_input", buf)


func session_key() -> PackedByteArray:
	# Empty during loopback debugging; NetProtocol treats empty as "no MAC".
	if LOOPBACK_UNSAFE:
		return PackedByteArray()
	return _session_key


# ============================================================
# Multiplayer wiring
# ============================================================
func _configure_multiplayer() -> void:
	var mp := multiplayer
	# RULE 1 — set explicitly, never flipped. See header.
	if mp is SceneMultiplayer:
		var sm := mp as SceneMultiplayer
		sm.allow_object_decoding = false
		sm.auth_timeout = NetSecurity.AUTH_TIMEOUT_SEC
		# Godot holds ALL other RPCs to a peer until auth completes, so the
		# entire game RPC surface stays shut to an unauthenticated stranger.
		# That is why we use the engine hook instead of a hand-rolled handshake.
		sm.auth_callback = Callable(self, "_on_auth_data")
		if not sm.peer_authenticating.is_connected(_on_peer_authenticating):
			sm.peer_authenticating.connect(_on_peer_authenticating)
		if not sm.peer_authentication_failed.is_connected(_on_peer_auth_failed):
			sm.peer_authentication_failed.connect(_on_peer_auth_failed)

	if not mp.peer_connected.is_connected(_on_peer_connected):
		mp.peer_connected.connect(_on_peer_connected)
	if not mp.peer_disconnected.is_connected(_on_peer_disconnected):
		mp.peer_disconnected.connect(_on_peer_disconnected)
	if not mp.connection_failed.is_connected(_on_connection_failed):
		mp.connection_failed.connect(_on_connection_failed)
	if not mp.server_disconnected.is_connected(_on_server_disconnected):
		mp.server_disconnected.connect(_on_server_disconnected)


func _disconnect_signals() -> void:
	var mp := multiplayer
	if mp is SceneMultiplayer:
		var sm := mp as SceneMultiplayer
		sm.auth_callback = Callable()
		if sm.peer_authenticating.is_connected(_on_peer_authenticating):
			sm.peer_authenticating.disconnect(_on_peer_authenticating)
		if sm.peer_authentication_failed.is_connected(_on_peer_auth_failed):
			sm.peer_authentication_failed.disconnect(_on_peer_auth_failed)
	if mp.peer_connected.is_connected(_on_peer_connected):
		mp.peer_connected.disconnect(_on_peer_connected)
	if mp.peer_disconnected.is_connected(_on_peer_disconnected):
		mp.peer_disconnected.disconnect(_on_peer_disconnected)
	if mp.connection_failed.is_connected(_on_connection_failed):
		mp.connection_failed.disconnect(_on_connection_failed)
	if mp.server_disconnected.is_connected(_on_server_disconnected):
		mp.server_disconnected.disconnect(_on_server_disconnected)


# ============================================================
# Handshake (SceneMultiplayer auth)
# ============================================================
# Sequence:
#   host  -> client   CHALLENGE(host_nonce, protocol, build_tag)
#   client-> host     RESPONSE(client_nonce, HMAC(secret, "SB-C"|hn|cn), protocol, build_tag)
#   host  -> client   ACCEPT(HMAC(secret, "SB-H"|hn|cn))        [or REJECT(code)]
#
# Auth is MUTUAL. The host proving itself back in ACCEPT is what stops a fake
# lobby from harvesting a guest's connection.
func _on_peer_authenticating(id: int) -> void:
	if not hosting:
		return   # client waits for the host to speak first
	if _authorised_client != 0:
		# Lobby already full. Tell them why, then hang up.
		_send_auth(id, NetSecurity.build_reject(NetSecurity.Reject.LOBBY_FULL))
		_kick_soon(id, "lobby full")
		return
	var nonce: PackedByteArray = NetSecurity.make_nonce()
	_host_nonces[id] = nonce
	_control_limiter[id] = NetSecurity.RateLimiter.new(
		NetSecurity.CONTROL_RATE, NetSecurity.CONTROL_BURST)
	_send_auth(id, NetSecurity.build_challenge(nonce))


func _on_auth_data(id: int, data: PackedByteArray) -> void:
	# Flood guard on the handshake itself.
	var lim = _control_limiter.get(id, null)
	if lim != null and not lim.allow():
		_kick_soon(id, "handshake flood")
		return

	var stage: int = NetSecurity.peek_stage(data)
	if stage == 0:
		if hosting:
			_send_auth(id, NetSecurity.build_reject(NetSecurity.Reject.MALFORMED))
			_kick_soon(id, "malformed auth")
		else:
			_abort_client(NetSecurity.reason_text(NetSecurity.Reject.MALFORMED))
		return

	if hosting:
		_host_auth(id, stage, data)
	else:
		_client_auth(id, stage, data)


# --- Host side -------------------------------------------------------------
func _host_auth(id: int, stage: int, data: PackedByteArray) -> void:
	if stage != NetSecurity.Auth.RESPONSE:
		_send_auth(id, NetSecurity.build_reject(NetSecurity.Reject.MALFORMED))
		_kick_soon(id, "unexpected auth stage")
		return

	var r: Dictionary = NetSecurity.read_response(data)
	if r.is_empty():
		_send_auth(id, NetSecurity.build_reject(NetSecurity.Reject.MALFORMED))
		_kick_soon(id, "bad response shape")
		return
	if int(r["protocol"]) != NetProtocol.PROTOCOL_VERSION:
		_send_auth(id, NetSecurity.build_reject(NetSecurity.Reject.PROTOCOL_MISMATCH))
		_kick_soon(id, "protocol mismatch")
		return

	var hn: PackedByteArray = _host_nonces.get(id, PackedByteArray())
	if hn.is_empty():
		_kick_soon(id, "no challenge on record")
		return
	if not NetSecurity.verify_client(_secret, hn, r["client_nonce"], r["proof"]):
		_send_auth(id, NetSecurity.build_reject(NetSecurity.Reject.BAD_SECRET))
		_kick_soon(id, "wrong join code")
		_log("Refused a connection: wrong join code.")
		return

	# Same protocol but different gameplay build: allow, but say so loudly —
	# host-authoritative means the guest silently plays the HOST's numbers.
	if str(r["build_tag"]) != NetProtocol.BUILD_TAG:
		_log("⚠ Guest build is [%s] and host is [%s]. Playing the host build." %
			[r["build_tag"], NetProtocol.BUILD_TAG])

	_session_key = NetSecurity.derive_session_key(_secret, hn, r["client_nonce"])
	_authorised_client = id
	_input_limiter[id] = NetSecurity.RateLimiter.new(
		NetSecurity.INPUT_RATE, NetSecurity.INPUT_BURST)
	_send_auth(id, NetSecurity.build_accept(_secret, hn, r["client_nonce"]))
	if multiplayer is SceneMultiplayer:
		(multiplayer as SceneMultiplayer).complete_auth(id)


# --- Client side -----------------------------------------------------------
func _client_auth(id: int, stage: int, data: PackedByteArray) -> void:
	if id != HOST_ID:
		return   # only the host talks to us during auth

	match stage:
		NetSecurity.Auth.CHALLENGE:
			var c: Dictionary = NetSecurity.read_challenge(data)
			if c.is_empty():
				_abort_client(NetSecurity.reason_text(NetSecurity.Reject.MALFORMED))
				return
			if int(c["protocol"]) != NetProtocol.PROTOCOL_VERSION:
				_abort_client(NetSecurity.reason_text(NetSecurity.Reject.PROTOCOL_MISMATCH))
				return
			_host_nonces[HOST_ID] = c["host_nonce"]
			if str(c["build_tag"]) != NetProtocol.BUILD_TAG:
				_log("⚠ Host build is [%s] and yours is [%s]." % [c["build_tag"], NetProtocol.BUILD_TAG])
			_send_auth(HOST_ID, NetSecurity.build_response(_secret, c["host_nonce"], _client_nonce))

		NetSecurity.Auth.ACCEPT:
			var hn: PackedByteArray = _host_nonces.get(HOST_ID, PackedByteArray())
			if hn.is_empty() or data.size() != 1 + NetSecurity.AUTH_TAG_LEN:
				_abort_client(NetSecurity.reason_text(NetSecurity.Reject.MALFORMED))
				return
			var proof: PackedByteArray = data.slice(1)
			# The host must prove it knows the secret too, or we hang up.
			if not NetSecurity.verify_host(_secret, hn, _client_nonce, proof):
				_abort_client("The host could not prove it owns this join code — connection refused.")
				return
			_session_key = NetSecurity.derive_session_key(_secret, hn, _client_nonce)
			if multiplayer is SceneMultiplayer:
				(multiplayer as SceneMultiplayer).complete_auth(HOST_ID)

		NetSecurity.Auth.REJECT:
			var code: int = data.decode_u8(1) if data.size() >= 2 else 0
			_pending_reject = code
			_abort_client(NetSecurity.reason_text(code))


func _send_auth(id: int, payload: PackedByteArray) -> void:
	if multiplayer is SceneMultiplayer:
		(multiplayer as SceneMultiplayer).send_auth(id, payload)


func _on_peer_auth_failed(id: int) -> void:
	if hosting:
		_log("A connection failed authentication and was dropped.")
		_forget_peer(id)
	else:
		var msg: String = NetSecurity.reason_text(_pending_reject) if _pending_reject != 0 \
			else NetSecurity.reason_text(NetSecurity.Reject.TIMEOUT)
		_abort_client(msg)


# ============================================================
# Connection lifecycle
# ============================================================
func _on_peer_connected(id: int) -> void:
	if hosting:
		if not is_authorised_client(id):
			# Should be unreachable — auth gates this — but never trust that.
			_kick_soon(id, "unauthorised peer reached connected state")
			return
		_set_state(State.CONNECTED)
		_log("Friend connected. Two players online.")
		# Third-party attempts stop at the door from here on.
		if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
			(multiplayer.multiplayer_peer as ENetMultiplayerPeer).refuse_new_connections = true
		guest_joined.emit(id)
	else:
		if id == HOST_ID:
			_set_state(State.CONNECTED)
			_log("Connected to host.")


func _on_peer_disconnected(id: int) -> void:
	if hosting and id == _authorised_client:
		_authorised_client = 0
		_forget_peer(id)
		if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
			(multiplayer.multiplayer_peer as ENetMultiplayerPeer).refuse_new_connections = false
		_set_state(State.HOSTING)
		_log("Friend disconnected. (Run N+4: Bea reverts to AI and the run continues.)")
		guest_left.emit("disconnected")
	else:
		_forget_peer(id)


func _on_connection_failed() -> void:
	_abort_client("Could not reach the host. Check the join code and that they are still hosting.")


func _on_server_disconnected() -> void:
	_abort_client("The host ended the game.")


# ============================================================
# Discipline: strikes, kicks, cleanup
# ============================================================
# Everything that earns a strike is something a legitimate client never does,
# so the threshold is deliberately low.
func strike(peer_id: int, reason: String) -> void:
	if not hosting:
		return
	var n: int = int(_strikes.get(peer_id, 0)) + 1
	_strikes[peer_id] = n
	_log("Strike %d/%d for peer %d — %s" % [n, NetSecurity.MAX_STRIKES, peer_id, reason])
	if n >= NetSecurity.MAX_STRIKES:
		_kick_soon(peer_id, "too many bad packets")


func _kick_soon(peer_id: int, reason: String) -> void:
	_log("Dropping peer %d — %s" % [peer_id, reason])
	# Small delay so a REJECT payload actually makes it onto the wire first.
	var t := get_tree().create_timer(0.75, true, false, true)
	t.timeout.connect(func() -> void:
		if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
			(multiplayer.multiplayer_peer as ENetMultiplayerPeer).disconnect_peer(peer_id)
		_forget_peer(peer_id))


func _forget_peer(peer_id: int) -> void:
	_host_nonces.erase(peer_id)
	_strikes.erase(peer_id)
	_input_limiter.erase(peer_id)
	_control_limiter.erase(peer_id)
	if _authorised_client == peer_id:
		_authorised_client = 0


# ============================================================
# RPCs
# ============================================================
# Client -> host. Channel 1 (input), unreliable ordered.
# RULE 3: sender check on the first line, always.
@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rx_input(buf: PackedByteArray) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if not is_authorised_client(sender):
		return
	var lim = _input_limiter.get(sender, null)
	if lim != null and not lim.allow():
		strike(sender, "input flood")
		return
	var pkt: Dictionary = NetProtocol.unpack_input(buf, session_key())
	if pkt.is_empty():
		strike(sender, "bad input packet")
		return
	# Run N+2 hands `pkt` to InputRouter as device 900. Nothing consumes it yet.
	_on_input_packet(pkt)


# Named seam so the RPC above never has to change again. NetInput listens.
func _on_input_packet(pkt: Dictionary) -> void:
	input_packet.emit(pkt)


# ---------------------------------------------------------------------------
# Host -> client menu state (Run N+2b)
# ---------------------------------------------------------------------------
# Used by the networked character-select screen. @rpc("authority") means only
# the host can invoke it, so a guest cannot fake menu state at the host or at
# itself. The RECEIVING side still range-checks every value it reads out of
# `data` — an authoritative sender is not the same as a trusted one.
func send_menu(kind: String, data: Dictionary) -> void:
	if not hosting or state != State.CONNECTED:
		return
	rpc_id(_authorised_client, "_rx_menu", kind, data)


@rpc("authority", "call_remote", "reliable", 0)
func _rx_menu(kind: String, data: Dictionary) -> void:
	if hosting:
		return   # hosts do not take menu state from anyone
	if multiplayer.get_remote_sender_id() != HOST_ID:
		return
	menu_message.emit(kind, data)


# Ping: either direction, control channel, reliable enough at this rate.
@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_ping(buf: PackedByteArray) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if hosting and not is_authorised_client(sender):
		return
	if not hosting and sender != HOST_ID:
		return
	var stamp: int = NetProtocol.unpack_ping(buf, NetProtocol.Msg.PING)
	if stamp < 0:
		if hosting:
			strike(sender, "bad ping")
		return
	rpc_id(sender, "_rx_pong", NetProtocol.pack_pong(stamp))


@rpc("any_peer", "call_remote", "reliable", 0)
func _rx_pong(buf: PackedByteArray) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if hosting and not is_authorised_client(sender):
		return
	if not hosting and sender != HOST_ID:
		return
	var stamp: int = NetProtocol.unpack_ping(buf, NetProtocol.Msg.PONG)
	if stamp < 0:
		return
	rtt_ms = int((Time.get_ticks_usec() - stamp) / 1000)


func _process(delta: float) -> void:
	if state != State.CONNECTED or hosting:
		return
	_ping_accum += delta
	if _ping_accum >= PING_INTERVAL:
		_ping_accum = 0.0
		rpc_id(HOST_ID, "_rx_ping", NetProtocol.pack_ping(Time.get_ticks_usec()))


# ============================================================
# Internals
# ============================================================
func _set_state(s: int) -> void:
	if state == s:
		return
	state = s
	state_changed.emit(s)


func _fail_session(msg: String) -> Dictionary:
	last_error = msg
	_set_state(State.FAILED)
	_log("✖ " + msg)
	session_failed.emit(msg)
	return {"ok": false, "error": msg}


func _abort_client(msg: String) -> void:
	last_error = msg
	_log("✖ " + msg)
	leave()
	_set_state(State.FAILED)
	session_failed.emit(msg)


func _log(text: String) -> void:
	Log.dbg(str("[Net] ", text))
	log_line.emit(text)
