extends Node
# ============================================================
# SFX.gd — autoload singleton "SFX"  (Phase 2a)
# ============================================================
# The sound-effect playback engine. Reads SoundBank.gd for its data.
#
# ── HOW IT PLUGS IN ─────────────────────────────────────────
# You almost never call this directly. FX.play_sound() forwards to it, and
# all 110 existing combat call sites already go through FX.play_sound().
# So wiring a sound is purely a SoundBank.gd data edit.
#
#     FX.play_sound("hit_light")        <- existing combat code, unchanged
#     SFX.play("ui_confirm")            <- direct, for new UI wiring
#
# ── AUTOLOAD ORDER MATTERS ──────────────────────────────────
# This node MUST be declared AFTER Settings in project.godot, because
# Settings._apply_audio() is what creates the "SFX" and "Music" buses and
# applies the saved volumes. If SFX loaded first it would fall back to the
# Master bus and the SFX volume slider would do nothing until the player
# opened the settings menu once.
#
# _ensure_bus() below is a second line of defence: it creates the bus if it
# somehow isn't there yet, so a future autoload reshuffle cannot silently
# break the volume slider again.
#
# ── VOICE POOL ──────────────────────────────────────────────
# A fixed pool of AudioStreamPlayer nodes, allocated once at boot and
# recycled. No runtime node allocation, no GC churn during combat.
# When every voice is busy the oldest is stolen.
#
# ── WHY NOT POSITIONAL (AudioStreamPlayer2D)? ───────────────
# The camera follows the pair and there is no split-screen, so everything
# audible is on-screen. Panning would add complexity and stereo-flipping
# artefacts during dashes for no real gain. If a wide arena later needs it,
# play_at() below is the seam to extend.
#
# ── GRACEFUL DEGRADATION (the important bit) ────────────────
# Nothing here ever hard-fails:
#   * event not in SoundBank            -> no-op + one debug warning (typo catcher)
#   * event declared with streams: []   -> silent, NO warning (expected pre-Phase-2b)
#   * file missing / import not run yet -> no-op + one debug warning, path cached
#                                          as bad so it never retries
# That is what allows the bank to ship mostly empty and fill in over time.
# ============================================================

const VOICE_COUNT: int = 20
const FALLBACK_BUS: String = "Master"

## Master kill-switch. Settings' SFX volume slider is the player-facing
## control (it drives the bus); this is for debugging.
var enabled: bool = true

## Auto-play "ui_move" whenever UI focus moves to a new control.
##
## This is hooked to the viewport's gui_focus_changed signal, which means ONE
## connection covers every menu in the game — main menu, settings, pause, save
## select, boon offer, controls — with no per-menu wiring and nothing to keep
## in sync as menus are added. Controller and keyboard navigation both route
## through focus, so both are covered.
##
## Side effect worth knowing: a menu that grab_focus()es on open produces one
## tick as it appears. That reads as normal UI feedback, but set this false if
## it ever doubles up awkwardly with menu_open.
var ui_focus_sounds: bool = true

## Auto-play "ui_confirm" whenever any Button in the game is pressed.
## Hooked via SceneTree.node_added — see _on_node_added for the rationale and
## the cost analysis. Set false to fall back to per-menu wiring.
var ui_button_sounds: bool = true

var _voices: Array[AudioStreamPlayer] = []
var _voice_event: Array[String] = []      # parallel: which event each voice is playing
var _voice_started_ms: Array[int] = []    # parallel: when it started (for stealing)
var _next_voice: int = 0

var _last_played_ms: Dictionary = {}      # event -> ticks_msec of last play
var _stream_cache: Dictionary = {}        # res:// path -> AudioStream, or null if bad


func _ready() -> void:
	# Must keep working while the tree is paused — menus, boon offers and the
	# pause overlay all live under a paused tree.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_bus(SoundBank.DEFAULT_BUS)
	_build_voice_pool()
	# One connection = UI navigation audio in every menu, present and future.
	var root: Window = get_tree().root
	if root != null and not root.gui_focus_changed.is_connected(_on_gui_focus_changed):
		root.gui_focus_changed.connect(_on_gui_focus_changed)
	# Likewise for button presses — see _on_node_added.
	var tree: SceneTree = get_tree()
	if tree != null and not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)


func _on_gui_focus_changed(node: Control) -> void:
	if ui_focus_sounds and node != null:
		play("ui_move")


## Auto-attach a confirm sound to every button in the game.
##
## Same reasoning as the focus hook: the alternative is editing every menu, and
## then remembering to edit every menu added later. Buttons are created in code
## all over this project (PauseManager, SettingsMenu, SaveFileSelect, BoonOffer,
## BoonDispenser), so a central hook is the only version that stays true.
##
## Cost check: node_added fires for EVERY node instantiated, including combat
## particles and damage numbers. The body is a single `is BaseButton` type test,
## which is a handful of nanoseconds — negligible even at heavy spawn rates.
func _on_node_added(node: Node) -> void:
	if not ui_button_sounds:
		return
	if node is BaseButton:
		var b := node as BaseButton
		if not b.pressed.is_connected(_on_any_button_pressed):
			b.pressed.connect(_on_any_button_pressed)


func _on_any_button_pressed() -> void:
	play("ui_confirm")


# ---------------------------------------------------------------------------
# Voice pool
# ---------------------------------------------------------------------------
func _build_voice_pool() -> void:
	var bus: String = SoundBank.DEFAULT_BUS
	if AudioServer.get_bus_index(bus) == -1:
		bus = FALLBACK_BUS
	for i in range(VOICE_COUNT):
		var p := AudioStreamPlayer.new()
		p.name = "Voice%02d" % i
		p.bus = bus
		p.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(p)
		_voices.append(p)
		_voice_event.append("")
		_voice_started_ms.append(0)


## Creates the bus if the project/Settings hasn't yet. Mirrors the helper in
## Settings.gd:416 so both agree on the routing.
func _ensure_bus(bus_name: String) -> int:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")
	return idx


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
## Play a named event. `vol_scale` is a LINEAR multiplier (1.0 = as authored),
## matching what the existing FX.play_sound() call sites already pass.
func play(event_name: String, vol_scale: float = 1.0) -> void:
	if not enabled or event_name == "":
		return

	if not SoundBank.has_event(event_name):
		# Genuine typo or a new event nobody declared — worth surfacing.
		_warn_once("sfx_unknown_" + event_name,
			"[SFX] Unknown sound event '%s' — add it to SoundBank.EVENTS." % event_name)
		return

	var def: Dictionary = SoundBank.get_event(event_name)
	var streams: Array = def.get("streams", [])
	if streams.is_empty():
		return   # declared but not yet authored — silent BY DESIGN, no warning

	# --- Per-event rate limit ---
	var now: int = Time.get_ticks_msec()
	var limit: int = int(def.get("limit_ms", SoundBank.DEFAULT_LIMIT_MS))
	var last: int = int(_last_played_ms.get(event_name, -1000000))
	if now - last < limit:
		return

	# --- Per-event concurrency cap ---
	var max_voices: int = int(def.get("max_voices", SoundBank.DEFAULT_MAX_VOICES))
	if _count_active(event_name) >= max_voices:
		return

	# --- Resolve a stream (random pick = variation) ---
	var path: String = String(streams[randi() % streams.size()])
	var stream: AudioStream = _get_stream(path)
	if stream == null:
		return

	# --- Allocate a voice ---
	var vi: int = _acquire_voice()
	if vi < 0:
		return
	var p: AudioStreamPlayer = _voices[vi]

	# --- Configure + fire ---
	p.stream = stream
	p.volume_db = float(def.get("vol_db", SoundBank.DEFAULT_VOL_DB)) + _scale_to_db(vol_scale)
	var pitch: Array = def.get("pitch", SoundBank.DEFAULT_PITCH)
	if pitch.size() >= 2 and float(pitch[0]) != float(pitch[1]):
		p.pitch_scale = randf_range(float(pitch[0]), float(pitch[1]))
	else:
		p.pitch_scale = float(pitch[0]) if pitch.size() > 0 else 1.0
	var bus: String = String(def.get("bus", SoundBank.DEFAULT_BUS))
	p.bus = bus if AudioServer.get_bus_index(bus) != -1 else FALLBACK_BUS

	_voice_event[vi] = event_name
	_voice_started_ms[vi] = now
	_last_played_ms[event_name] = now
	p.play()


## Positional seam. Non-positional today (see header); accepts a position so
## call sites written now don't need changing if 2D audio is added later.
func play_at(event_name: String, _world_pos: Vector2, vol_scale: float = 1.0) -> void:
	play(event_name, vol_scale)


## Stop everything — used on scene transitions if a lingering tail is unwanted.
func stop_all() -> void:
	for i in range(_voices.size()):
		_voices[i].stop()
		_voice_event[i] = ""


## Debug helper: how many declared events still have no audio.
func report_coverage() -> String:
	var total: int = SoundBank.EVENTS.size()
	var missing: int = SoundBank.unwired_count()
	return "[SFX] %d/%d events wired (%d still silent)" % [total - missing, total, missing]


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------
func _count_active(event_name: String) -> int:
	var n: int = 0
	for i in range(_voices.size()):
		if _voice_event[i] == event_name and _voices[i].playing:
			n += 1
	return n


## Prefers a free voice; steals the oldest busy one if the pool is saturated.
func _acquire_voice() -> int:
	for step in range(_voices.size()):
		var i: int = (_next_voice + step) % _voices.size()
		if not _voices[i].playing:
			_next_voice = (i + 1) % _voices.size()
			return i
	# All busy — steal the one that started longest ago.
	var oldest: int = 0
	var oldest_ms: int = _voice_started_ms[0]
	for i in range(1, _voices.size()):
		if _voice_started_ms[i] < oldest_ms:
			oldest_ms = _voice_started_ms[i]
			oldest = i
	_voices[oldest].stop()
	_next_voice = (oldest + 1) % _voices.size()
	return oldest


## Loads and caches. A failed load caches `null` so we never retry it —
## important because these calls sit in combat hot paths.
func _get_stream(path: String) -> AudioStream:
	if _stream_cache.has(path):
		return _stream_cache[path]
	var s: AudioStream = null
	if ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is AudioStream:
			s = res
		else:
			_warn_once("sfx_nottream_" + path, "[SFX] '%s' is not an AudioStream." % path)
	else:
		_warn_once("sfx_missing_" + path,
			"[SFX] Missing audio file '%s' (open the project in Godot once so it imports)." % path)
	_stream_cache[path] = s
	return s


## Linear volume multiplier -> dB offset. Guards log(0).
func _scale_to_db(vol_scale: float) -> float:
	if vol_scale <= 0.0001:
		return -80.0
	if is_equal_approx(vol_scale, 1.0):
		return 0.0
	return linear_to_db(vol_scale)


func _warn_once(key: String, msg: String) -> void:
	var lg: Node = get_node_or_null("/root/Log")
	if lg and lg.has_method("warn_once"):
		lg.warn_once(key, msg)
	elif OS.is_debug_build():
		push_warning(msg)
