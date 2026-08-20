extends Node
# ============================================================
# InputRouter.gd — autoload singleton ("InputRouter")  (Run 73)
# ============================================================
# Per-device input state for LOCAL 2-PLAYER co-op.
#
# Godot's Input.is_action_* singleton merges every device into one global
# state, which is fine for 1P but useless when two humans share one machine.
# This router buckets input by the originating device so each ninja can read
# ONLY its own controller.
#
# Device convention used everywhere in the project:
#     -1  → keyboard (and mouse)
#    >=0  → joypad, by its Godot device id
#
# Usage (only in 2P; 1P keeps reading the global Input singleton):
#     InputRouter.pressed(device, "dash")
#     InputRouter.just_pressed(device, "attack_y")
#     InputRouter.just_released(device, "attack_x")
#     InputRouter.move_vector(device)   # left stick / WASD
#     InputRouter.aim_vector(device)    # right stick (empty for keyboard)
#
# Implementation: button-style actions are latched from _input() events
# (each event carries .device). A snapshot of the held-state is taken at the
# very END of every physics frame (this node has a high physics priority so
# it ticks AFTER the ninjas), so just_pressed/just_released stay valid for the
# whole physics frame and fire exactly once. Movement / aim are polled live
# straight from the device each frame.
# ============================================================

const KEYBOARD_DEVICE: int = -1

# ---------------------------------------------------------------------------
# Run N+2b — THE REMOTE DEVICE
# ---------------------------------------------------------------------------
# An online partner is just another device id. The host receives their input
# packet, calls inject_remote(), and from that moment Bea reads device 900
# through the exact same pressed()/move_vector() calls she uses for a gamepad
# plugged into the host's own PC. No hero code knows the difference.
#
# 900 is chosen to sit far above any plausible real joypad id so it can never
# collide with hardware Godot enumerates.
#
# Unlike a real device, 900 is NOT polled from hardware — it is PUSHED in from
# the network at ~30 Hz. move_vector()/aim_vector() therefore read the stored
# values below instead of calling Input.get_joy_axis().
const NET_DEVICE_REMOTE: int = 900

var _remote_move: Vector2 = Vector2.ZERO
var _remote_aim: Vector2 = Vector2.ZERO

# Button-style actions tracked per device (edge + held). Movement and aim are
# polled directly (see move_vector / aim_vector) and are NOT in this list.
#
# ui_accept / ui_cancel were added in Run N+2b: menus (character select in
# particular) need to route a remote player's confirm and back presses, and a
# remote player produces no InputEvents to read them from.
const TRACKED_ACTIONS: Array = [
	"attack_y", "attack_x", "attack_a", "dash", "ult",
	"swap_character", "interact", "pause", "reroll", "boon_inspect",
	"ui_accept", "ui_cancel",
]

const MOVE_DEADZONE: float = 0.2
const AIM_DEADZONE:  float = 0.5

# "device|action" -> bool currently held
var _held: Dictionary = {}
# snapshot of _held taken at the end of the previous physics frame
var _prev: Dictionary = {}


func _ready() -> void:
	# Tick AFTER the player characters so the just_pressed window covers the
	# whole physics frame before we snapshot.
	process_priority = 1000
	process_physics_priority = 1000
	# Run 151 — MUST keep tracking input during tree pauses (boon offers, menus)
	# so _held stays in sync with physical button state. Without this, releasing
	# a charge button during a boon offer is invisible to InputRouter — _held
	# stays stale, and the hero gets stuck in a charge state on unpause.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _key(device: int, action: String) -> String:
	return str(device) + "|" + action


# Normalise a raw event to our device convention: keyboard/mouse → -1,
# joypad events keep their real device id.
func _event_device(event: InputEvent) -> int:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return event.device
	return KEYBOARD_DEVICE


func _input(event: InputEvent) -> void:
	# Echoes are filtered automatically by is_action_pressed(action, false).
	var dev: int = _event_device(event)
	for action in TRACKED_ACTIONS:
		if not InputMap.has_action(action):
			continue
		if event.is_action_pressed(action):
			_held[_key(dev, action)] = true
		elif event.is_action_released(action):
			_held[_key(dev, action)] = false


func _physics_process(_delta: float) -> void:
	# Snapshot at end-of-frame (high priority => runs after consumers).
	_prev = _held.duplicate(true)


# ---------------------------------------------------------------------------
# Button queries
# ---------------------------------------------------------------------------
func pressed(device: int, action: String) -> bool:
	return bool(_held.get(_key(device, action), false))


func just_pressed(device: int, action: String) -> bool:
	var k: String = _key(device, action)
	return bool(_held.get(k, false)) and not bool(_prev.get(k, false))


func just_released(device: int, action: String) -> bool:
	var k: String = _key(device, action)
	return (not bool(_held.get(k, false))) and bool(_prev.get(k, false))


# ---------------------------------------------------------------------------
# Analog / movement queries (polled live)
# ---------------------------------------------------------------------------
func move_vector(device: int) -> Vector2:
	# Pushed in from the network, not polled from hardware.
	if device == NET_DEVICE_REMOTE:
		return _remote_move
	if device == KEYBOARD_DEVICE:
		var x: float = 0.0
		var y: float = 0.0
		if Input.is_physical_key_pressed(KEY_D): x += 1.0
		if Input.is_physical_key_pressed(KEY_A): x -= 1.0
		if Input.is_physical_key_pressed(KEY_S): y += 1.0
		if Input.is_physical_key_pressed(KEY_W): y -= 1.0
		return Vector2(x, y)
	var v := Vector2(
		Input.get_joy_axis(device, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(device, JOY_AXIS_LEFT_Y))
	if v.length() < MOVE_DEADZONE:
		return Vector2.ZERO
	return v


func aim_vector(device: int) -> Vector2:
	if device == NET_DEVICE_REMOTE:
		return _remote_aim
	# Keyboard has no right stick — callers fall back to facing/movement.
	if device == KEYBOARD_DEVICE:
		return Vector2.ZERO
	var v := Vector2(
		Input.get_joy_axis(device, JOY_AXIS_RIGHT_X),
		Input.get_joy_axis(device, JOY_AXIS_RIGHT_Y))
	if v.length() < AIM_DEADZONE:
		return Vector2.ZERO
	return v


# ---------------------------------------------------------------------------
# Run N+2b — remote input injection (HOST SIDE ONLY)
# ---------------------------------------------------------------------------
# Called by NetInput once per received packet. `held` is action -> bool for the
# actions in TRACKED_ACTIONS; anything absent is treated as released.
#
# Writing straight into _held means the existing edge detection just works: the
# end-of-physics-frame snapshot in _physics_process() gives device 900 the same
# just_pressed / just_released semantics as any pad, for free.
#
# NOTE: packets arrive at ~30 Hz while physics runs at 60, so a press and its
# release can land in the same packet. NetInput handles that on the sending
# side by latching any press that happened since the last send, so a fast tap is
# never swallowed — see NetInput._collect().
func inject_remote(held: Dictionary, move: Vector2, aim: Vector2) -> void:
	for action in TRACKED_ACTIONS:
		_held[_key(NET_DEVICE_REMOTE, action)] = bool(held.get(action, false))
	# Defensive: the network layer clamps these too, but a stray value here would
	# hand a hero an impossible movement vector.
	_remote_move = move.limit_length(1.0)
	_remote_aim = aim.limit_length(1.0)


# On disconnect, release everything the remote player was holding. Without this
# a friend who drops mid-dash leaves the dash button stuck down forever.
func clear_remote() -> void:
	for action in TRACKED_ACTIONS:
		_held[_key(NET_DEVICE_REMOTE, action)] = false
	_remote_move = Vector2.ZERO
	_remote_aim = Vector2.ZERO


# ---------------------------------------------------------------------------
# Convenience: resolve the two physical "player slots" from connected pads.
# P1 / P2 each get a device id. Keyboard always also works as a slot if there
# aren't enough pads, so the feature is testable with 1 pad + keyboard.
#   2+ pads : P1 = pad0, P2 = pad1
#   1  pad  : P1 = keyboard(-1), P2 = pad0
#   0  pads : P1 = keyboard(-1), P2 = keyboard(-1)  (degenerate, share kb)
# ---------------------------------------------------------------------------
func resolve_player_devices() -> Dictionary:
	var pads: Array = Input.get_connected_joypads()
	if pads.size() >= 2:
		return {"p1": int(pads[0]), "p2": int(pads[1])}
	elif pads.size() == 1:
		return {"p1": KEYBOARD_DEVICE, "p2": int(pads[0])}
	return {"p1": KEYBOARD_DEVICE, "p2": KEYBOARD_DEVICE}


# ---------------------------------------------------------------------------
# Diagnostics — let the setup screen show what Godot actually sees. If this
# reports 0 controllers while pads are physically plugged in, the controllers
# are being intercepted before Godot (almost always Steam Input) — no code
# change can bind a device Godot can't see.
# ---------------------------------------------------------------------------
func connected_pads() -> Array:
	return Input.get_connected_joypads()


# Human-readable name for a device id (-1 = keyboard, >=0 = joypad).
func device_label(device: int) -> String:
	if device == KEYBOARD_DEVICE:
		return "Keyboard"
	var nm: String = Input.get_joy_name(device)
	if nm == "":
		nm = "Gamepad"
	return "%s (pad %d)" % [nm, device]


# One-line summary of every joypad Godot currently enumerates.
func pad_summary() -> String:
	var pads: Array = Input.get_connected_joypads()
	if pads.is_empty():
		return "Controllers detected: 0  (keyboard only)"
	var parts: PackedStringArray = PackedStringArray()
	for d in pads:
		parts.append(device_label(int(d)))
	return "Controllers detected: %d  —  %s" % [pads.size(), ", ".join(parts)]
