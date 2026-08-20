extends Node

# ============================================================
# InputGlyphs.gd — Run 158 — LIVE INPUT-DEVICE GLYPH SWAPPING
# ============================================================
# Bruno's ask: "if I'm on controller it should only show controller buttons;
# if I suddenly press a key, the whole game adapts and every prompt becomes
# keyboard keys."
#
# This autoload is the single source of truth for BOTH halves of that:
#
#   1. DETECTION — watches every input event and flips `gamepad` the instant
#      the player touches a different device. Emits `device_changed`.
#   2. RENDERING — owns the one table mapping a semantic action ("dash",
#      "interact", "swap") to its keyboard label and its gamepad label, and
#      renders whichever half is currently live.
#
# ── How to use it ────────────────────────────────────────────
# Write prompt copy with {tokens} instead of hardcoded keys:
#
#     "Press {dash} to dodge, then {interact} at the gate."
#
# Then either render it once...
#
#     lbl.text = InputGlyphs.plain(template)     # plain Label
#     rtl.text = InputGlyphs.rich(template)      # RichTextLabel (badges)
#
# ...or, better, BIND it, and it re-renders itself forever:
#
#     InputGlyphs.bind_label(my_label, "Press {interact} to collect")
#     InputGlyphs.bind_rich(my_rtl,   "{move} — Move")
#
# Bound nodes are refreshed automatically on every device change and are
# pruned when they leave the tree, so there is nothing to disconnect.
#
# ── Adding a new prompt ──────────────────────────────────────
# Add one row to GLYPHS below. Never hardcode a key name in UI copy again.
# ============================================================

signal device_changed(is_gamepad: bool)

## True when the player's most recent input came from a gamepad.
var gamepad: bool = false

const STICK_DEADZONE: float = 0.40
## Poll backup runs at this cadence (seconds) — cheap safety net for events
## that a focused Control consumed before our _input() could see them.
const POLL_INTERVAL: float = 0.10

# ── The table ────────────────────────────────────────────────
# One row per semantic action. "kb" = keyboard/mouse label, "pad" = gamepad
# label. Keep labels SHORT — they render inside badges.
const GLYPHS: Dictionary = {
	# Movement / aim
	"move":         {"kb": "WASD",              "pad": "Left Stick"},
	"menu_nav":     {"kb": "Arrow Keys / WASD", "pad": "D-Pad / Left Stick"},
	# PAD-ONLY. aim_left/right/up/down are bound to joypad axes 2/3 and nothing
	# else — there is no keyboard or mouse equivalent for twin-stick auto-fire.
	# Wrap any copy that mentions it in a [pad]...[/pad] block so keyboard players
	# are never told about a control they don't have.
	"aim":          {"kb": "(gamepad only)",    "pad": "Right Stick"},

	# Combat
	"dash":         {"kb": "Space",     "pad": "B"},
	"attack_y":     {"kb": "J",         "pad": "Y"},
	"attack_x":     {"kb": "K",         "pad": "X"},
	"attack_a":     {"kb": "L",         "pad": "A"},
	"ult":          {"kb": "U",         "pad": "RT"},
	"charge":       {"kb": "J / K / L", "pad": "Y / X / A"},
	"charge_tight": {"kb": "J/K/L",     "pad": "Y/X/A"},

	# World / system
	# interact = key E / joypad button 10 (RIGHT_SHOULDER). Older copy called this
	# "R"; every other pad label here uses Xbox naming, so RB it is.
	"interact":     {"kb": "E",       "pad": "RB"},
	"swap":         {"kb": "Q",       "pad": "LB"},
	"swap2":        {"kb": "Q + Q",   "pad": "LB + LB"},
	"accept":       {"kb": "Enter",   "pad": "A"},
	"cancel":       {"kb": "Esc",     "pad": "B"},
	"pause":        {"kb": "Esc",     "pad": "Start"},
	"close_tip":    {"kb": "Esc",     "pad": "Start / −"},
	"reroll":       {"kb": "R",       "pad": "LB"},
}

# ── Badge styling (moved here from TutorialPrompt so every UI matches) ──
const KB_BG: String  = "#2a2a48"
const KB_FG: String  = "#b0d0ff"
const PAD_BG: String = "#1a3a1a"
const PAD_FG: String = "#7ce87c"

# instance_id -> { "node": Node, "template": String, "rich": bool, "prop": String }
var _bound: Dictionary = {}
var _poll_t: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # must keep working while paused
	# Sensible cold start: if a pad is plugged in, assume the player reached for
	# it. The first real input from either device corrects this within a frame.
	gamepad = not Input.get_connected_joypads().is_empty()


# ── Detection ────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	_note_event(event)


# Belt-and-suspenders: a focused Control can call set_input_as_handled() before
# our _input() runs (HintPopup does exactly this), so poll the pad directly too.
# Keyboard needs no poll — key events are effectively never consumed that early.
func _process(delta: float) -> void:
	if gamepad:
		return   # already in pad mode; the _input path handles the flip back
	_poll_t -= delta
	if _poll_t > 0.0:
		return
	_poll_t = POLL_INTERVAL
	for dev in Input.get_connected_joypads():
		for axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y]:
			if absf(Input.get_joy_axis(dev, axis)) >= STICK_DEADZONE:
				_set_device(true)
				return
		for btn in range(JOY_BUTTON_SDL_MAX):
			if Input.is_joy_button_pressed(dev, btn):
				_set_device(true)
				return


func _note_event(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		if (event as InputEventJoypadButton).pressed:
			_set_device(true)
	elif event is InputEventJoypadMotion:
		if absf((event as InputEventJoypadMotion).axis_value) >= STICK_DEADZONE:
			_set_device(true)
	elif event is InputEventKey:
		if (event as InputEventKey).pressed:
			_set_device(false)
	elif event is InputEventMouseButton:
		if (event as InputEventMouseButton).pressed:
			_set_device(false)
	# Mouse MOTION is deliberately ignored: a nudged mouse (or a mouse resting on
	# a shaky desk) must not yank a controller player back to keyboard glyphs.


func _set_device(is_pad: bool) -> void:
	if gamepad == is_pad:
		return
	gamepad = is_pad
	_refresh_bound()
	device_changed.emit(gamepad)


# ── Rendering ────────────────────────────────────────────────

## Plain-text label for one action id, e.g. label("dash") -> "Space" or "B".
func label(id: String) -> String:
	var row: Variant = GLYPHS.get(id, null)
	if row == null:
		push_warning("[InputGlyphs] Unknown glyph id '%s'." % id)
		return id
	return String((row as Dictionary).get("pad" if gamepad else "kb", id))


## BBCode badge for one action id — styled chip, device-coloured.
func badge(id: String) -> String:
	var txt: String = label(id)
	if gamepad:
		return "[bgcolor=%s][color=%s] %s [/color][/bgcolor]" % [PAD_BG, PAD_FG, txt]
	return "[bgcolor=%s][color=%s] %s [/color][/bgcolor]" % [KB_BG, KB_FG, txt]


## Replace every {token} in `text` with its PLAIN label (for Label nodes).
func plain(text: String) -> String:
	return _substitute(text, false)


## Replace every {token} in `text` with its BBCode badge (for RichTextLabel).
func rich(text: String) -> String:
	return _substitute(text, true)


func _substitute(text: String, as_badge: bool) -> String:
	var out: String = _resolve_blocks(text)
	if not out.contains("{"):
		return out
	for id in GLYPHS.keys():
		var token: String = "{%s}" % id
		if out.contains(token):
			out = out.replace(token, badge(id) if as_badge else label(id))
	return out


## Device-conditional copy. Some controls only EXIST on one device — twin-stick
## auto-fire is bound to joypad axes and has no keyboard equivalent at all — so
## copy that mentions them must disappear rather than lie. Wrap it:
##
##     "Press {attack_a} to throw.[pad] Or hold {aim} to auto-fire.[/pad]"
##
## The matching device keeps the inner text (tags removed); the other device
## loses the whole block. Both [pad]/[/pad] and [kb]/[/kb] are supported.
func _resolve_blocks(text: String) -> String:
	var out: String = text
	out = _resolve_one_block(out, "pad", gamepad)
	out = _resolve_one_block(out, "kb", not gamepad)
	return out


func _resolve_one_block(text: String, tag: String, keep: bool) -> String:
	var open_tag: String = "[%s]" % tag
	var close_tag: String = "[/%s]" % tag
	var out: String = text
	# Bounded loop — one pass per block, and every pass strictly shrinks `out`.
	var guard: int = 0
	while out.contains(open_tag) and guard < 32:
		guard += 1
		var a: int = out.find(open_tag)
		var b: int = out.find(close_tag, a)
		if b < 0:
			# Unclosed tag — drop the marker so it can't leak into the UI.
			# (substr concat rather than String.erase, whose in-place vs.
			# returning signature has shifted between Godot versions.)
			out = out.substr(0, a) + out.substr(a + open_tag.length())
			break
		var inner: String = out.substr(a + open_tag.length(), b - a - open_tag.length())
		var replacement: String = inner if keep else ""
		out = out.substr(0, a) + replacement + out.substr(b + close_tag.length())
	return out


# ── Binding (auto re-render on device change) ────────────────

## Bind a plain Label / Button — its `text` re-renders on every device change.
func bind_label(node: Node, template: String) -> void:
	_bind(node, template, false, "text")


## Bind a RichTextLabel — its `text` re-renders with badges on device change.
func bind_rich(node: Node, template: String) -> void:
	_bind(node, template, true, "text")


func _bind(node: Node, template: String, as_rich: bool, prop: String) -> void:
	if node == null or not is_instance_valid(node):
		return
	_bound[node.get_instance_id()] = {
		"node": node, "template": template, "rich": as_rich, "prop": prop,
	}
	node.set(prop, _substitute(template, as_rich))
	if not node.tree_exited.is_connected(_on_bound_exited):
		node.tree_exited.connect(_on_bound_exited.bind(node.get_instance_id()))


## Re-point an already-bound node at new copy (e.g. an objective line updating).
func update_binding(node: Node, template: String) -> void:
	if node == null or not is_instance_valid(node):
		return
	var key: int = node.get_instance_id()
	if _bound.has(key):
		var e: Dictionary = _bound[key]
		e["template"] = template
		node.set(String(e.get("prop", "text")), _substitute(template, bool(e.get("rich", false))))
	else:
		_bind(node, template, node is RichTextLabel, "text")


func _on_bound_exited(key: int) -> void:
	_bound.erase(key)


func _refresh_bound() -> void:
	var dead: Array = []
	for key in _bound.keys():
		var e: Dictionary = _bound[key]
		var n: Node = e.get("node", null)
		if n == null or not is_instance_valid(n):
			dead.append(key)
			continue
		n.set(String(e.get("prop", "text")), _substitute(String(e.get("template", "")), bool(e.get("rich", false))))
	for key in dead:
		_bound.erase(key)
