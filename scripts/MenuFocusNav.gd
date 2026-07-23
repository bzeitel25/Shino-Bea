extends Node
## Lightweight focus cycler for code-built button menus.
##
## Godot's built-in focus navigation only covers arrows + D-pad. This adds the
## move_* actions (WASD + left stick) so any pop-up menu is navigable the same
## way the player moves in-game. It consumes the event so the built-in nav does
## not ALSO move focus on the same press (which would skip every other button).
##
## Stick gating: first deflection moves one step instantly. Must hold 1.5 s
## before the next step fires, then slow auto-repeat at NAV_REPEAT_RATE.
##
## Usage: add as a child of the menu's CanvasLayer (which should be
## PROCESS_MODE_ALWAYS so it works while the tree is paused), then set
## `buttons` to the ordered Array[Button].

var buttons: Array = []          # ordered Array[Button]
var wrap: bool = true            # cycle past the ends

# ── Stick gating ─────────────────────────────────────────────
const NAV_INITIAL_DELAY: float = 1.5   # hold time before first repeat
const NAV_REPEAT_RATE:   float = 0.3   # seconds between repeats after delay
const NAV_COOLDOWN:      float = 0.18  # min seconds between any two steps
var _nav_held_dir: int   = 0           # -1 or +1 while stick/key held, 0 = idle
var _nav_hold_time: float = 0.0        # seconds since first press
var _nav_repeat_acc: float = 0.0       # accumulator for repeat ticks
var _nav_cooldown_t: float = 0.0       # time remaining before next step allowed


func _ready() -> void:
	# Receive input even while get_tree().paused == true.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	if buttons.is_empty():
		return

	# Tick cooldown regardless of input state.
	if _nav_cooldown_t > 0.0:
		_nav_cooldown_t -= delta

	# Poll the Input singleton each frame — immune to stick wobble.
	var want: int = 0
	if Input.is_action_pressed("move_up") or Input.is_action_pressed("move_left"):
		want = -1
	elif Input.is_action_pressed("move_down") or Input.is_action_pressed("move_right"):
		want = 1

	if want == 0:
		_nav_held_dir = 0
		_nav_hold_time = 0.0
		_nav_repeat_acc = 0.0
		return
	if want != _nav_held_dir:
		# New direction (or first press) — move once, start hold timer.
		_nav_held_dir = want
		_nav_hold_time = 0.0
		_nav_repeat_acc = 0.0
		if _nav_cooldown_t <= 0.0:
			_cycle(want)
			_nav_cooldown_t = NAV_COOLDOWN
		return
	# Same direction still held — run the hold timer.
	_nav_hold_time += delta
	if _nav_hold_time >= NAV_INITIAL_DELAY:
		_nav_repeat_acc += delta
		while _nav_repeat_acc >= NAV_REPEAT_RATE:
			_nav_repeat_acc -= NAV_REPEAT_RATE
			if _nav_cooldown_t <= 0.0:
				_cycle(_nav_held_dir)
				_nav_cooldown_t = NAV_COOLDOWN


func _input(event: InputEvent) -> void:
	# Consume move events so Godot's built-in focus nav doesn't double-fire.
	if buttons.is_empty():
		return
	if event.is_action_pressed("move_up") or event.is_action_pressed("move_left") \
	or event.is_action_pressed("move_down") or event.is_action_pressed("move_right"):
		get_viewport().set_input_as_handled()


func _cycle(dir: int) -> void:
	var cur: int = 0
	for i in range(buttons.size()):
		var b := buttons[i] as Button
		if b != null and b.has_focus():
			cur = i
			break
	var idx: int = cur + dir
	if wrap:
		idx = (idx + buttons.size()) % buttons.size()
	else:
		idx = clampi(idx, 0, buttons.size() - 1)
	var nxt := buttons[idx] as Button
	if nxt != null:
		nxt.grab_focus()
