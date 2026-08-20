extends Node
# ============================================================
# NetInput.gd — autoload singleton ("NetInput")  ·  the input pipe (Run N+2b)
# ============================================================
# The client's half of THE LOCK: this is the only thing a guest ever sends.
# Button state and two stick vectors. No positions, no damage, no HP, no boons.
#
#   GUEST                                        HOST
#   local pad/keyboard                           InputRouter device 900
#        │  InputRouter.pressed(local_dev, …)         ▲
#        ▼                                            │
#   _collect()  ──►  NetProtocol.pack_input  ──►  Net  │
#        30 Hz, 20 bytes, HMAC'd                       │
#                                          Net.input_packet ─► inject_remote()
#
# Once injected, Bea reads device 900 through the same InputRouter calls she
# uses for a gamepad plugged into the host's own machine. Nothing in Bea.gd,
# Shino.gd or HeroBase.gd changed to make this work.
#
# ------------------------------------------------------------
# WHY PRESS-LATCHING EXISTS (the subtle bug this avoids)
# ------------------------------------------------------------
# Physics runs at 60 Hz; we send at 30. A fast tap — press and release inside
# one 33 ms window — would be invisible to a naive "sample the held state when
# it is time to send" implementation, and the guest's dash would silently eat
# inputs. So every physics frame we latch any button that went down, and OR
# that into the next outgoing packet. The tap arrives as one frame of "held"
# followed by a release: a real, clean press on the host.
# ============================================================

const NetProtocol := preload("res://scripts/net/NetProtocol.gd")

const SEND_HZ: float = 30.0
const SEND_INTERVAL: float = 1.0 / SEND_HZ

# How far a tick may jump forward before we treat it as garbage rather than
# jitter. 30 Hz means 60 ticks is two seconds — far beyond any real hiccup.
const MAX_TICK_JUMP: int = 60

# The device this machine's local player is actually using. Self-correcting:
# whatever they last touched becomes their device, so a guest can start on the
# keyboard and pick up a controller mid-menu without any settings screen.
var local_device: int = InputRouter.KEYBOARD_DEVICE

var _accum: float = 0.0
var _tick: int = 0
var _latched: Dictionary = {}      # action -> true if pressed since last send

# Host side: last accepted tick from the guest, for replay/duplicate rejection.
var _last_rx_tick: int = -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # menus pause the tree; input must not stop
	Net.input_packet.connect(_on_host_packet)
	Net.guest_left.connect(_on_peer_gone)
	Net.state_changed.connect(_on_state_changed)


# ============================================================
# Local device tracking
# ============================================================
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		if event is InputEventJoypadMotion and absf(event.axis_value) < 0.5:
			return   # ignore stick drift, only real deflection claims the device
		local_device = event.device
	elif event is InputEventKey and event.pressed:
		local_device = InputRouter.KEYBOARD_DEVICE


# ============================================================
# Guest: collect and send
# ============================================================
func _physics_process(delta: float) -> void:
	if not Net.is_connected_pair() or Net.is_host():
		return

	# Latch every press as it happens, at full physics rate.
	for action in InputRouter.TRACKED_ACTIONS:
		if InputRouter.just_pressed(local_device, action):
			_latched[action] = true

	_accum += delta
	if _accum < SEND_INTERVAL:
		return
	_accum = 0.0
	_send()


func _send() -> void:
	var held: Dictionary = {}
	for action in InputRouter.TRACKED_ACTIONS:
		held[action] = InputRouter.pressed(local_device, action) or bool(_latched.get(action, false))
	_latched.clear()

	_tick = (_tick + 1) & 0xFFFF
	var buf: PackedByteArray = NetProtocol.pack_input(
		_tick,
		NetProtocol.pack_buttons(held),
		InputRouter.move_vector(local_device),
		InputRouter.aim_vector(local_device),
		NetProtocol.UI_CHOICE_NONE,
		Net.session_key())
	Net.send_input(buf)


# ============================================================
# Host: validate and inject
# ============================================================
# Net has already checked the sender, the rate limit, the packet size and the
# MAC before this runs. What is left is ordering — and ordering is a security
# check too: without it, a captured packet can be replayed to make the guest
# appear to press a button they never pressed.
func _on_host_packet(pkt: Dictionary) -> void:
	if not Net.is_host():
		return
	var tick: int = int(pkt.get("tick", 0))

	if _last_rx_tick >= 0:
		# Wraparound-safe "is this newer?": the u16 tick rolls over every ~36
		# minutes at 30 Hz, and a naive tick > _last_rx_tick would deadlock the
		# guest's input for the rest of the session when it does.
		var diff: int = (tick - _last_rx_tick) & 0xFFFF
		if diff == 0 or diff >= 32768:
			return                      # duplicate or stale — drop quietly
		if diff > MAX_TICK_JUMP:
			Net.strike(Net.client_id(), "input tick jumped %d" % diff)
			return
	_last_rx_tick = tick

	InputRouter.inject_remote(
		NetProtocol.unpack_buttons(int(pkt.get("buttons", 0))),
		pkt.get("move", Vector2.ZERO),
		pkt.get("aim", Vector2.ZERO))


# ============================================================
# Teardown
# ============================================================
func _on_peer_gone(_reason: String) -> void:
	_reset()


func _on_state_changed(_s: int) -> void:
	if not Net.is_connected_pair():
		_reset()


# A friend who drops mid-dash must not leave the dash button stuck down.
func _reset() -> void:
	InputRouter.clear_remote()
	_latched.clear()
	_accum = 0.0
	_tick = 0
	_last_rx_tick = -1
