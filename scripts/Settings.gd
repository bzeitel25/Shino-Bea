extends Node
# ============================================================
# Settings.gd — autoload singleton "Settings"  (Run 54)
# ============================================================
# Central store for all player-facing options. Persisted to
# user://settings.cfg so choices survive between sessions.
#
# Reached from anywhere as `Settings.<field>` and changed through the
# setters so audio/brightness/etc. apply live and save immediately.
#
# Fields:
#   master_volume / music_volume / sfx_volume  (0.0 .. 1.0 linear)
#   brightness                                 (0.5 .. 1.5, 1.0 = neutral)
#   shake_enabled                              (bool)
#   shake_intensity                            (0.0 .. 1.5, 1.0 = default)
#   nameplates_enabled                         (bool)
#
# Other systems consume these as follows:
#   FX.screen_shake()  multiplies magnitude by get_shake_mult()
#   Player/BeaAI       show/hide their NameLabel on nameplates_changed
#   Audio buses        Master/Music/SFX set from the volume fields
#   Brightness         a fullscreen overlay parented to the tree root
#
# ============================================================
# ⚠ TWO INVARIANTS — READ BEFORE ADDING A SETTING
# ============================================================
#
# 1. SETTINGS ARE CLIENT-LOCAL AND ARE NEVER NETWORKED.
#    Everything here lives in user://settings.cfg on the machine it runs on. It
#    is NOT in RunState, NOT in the save slot, and NOT sent over the wire, so in
#    LAN/online 2P each player keeps their own preferences: one can show all
#    damage numbers while the other shows crits only, one can run rumble off and
#    the other on. Verified 2026-08-01 — scripts/net/ contains zero references
#    to Settings.
#
#    ⚠ Do NOT "fix" a settings mismatch between host and client by syncing it.
#    A mismatch is the intended behaviour.
#
# 2. SETTINGS MUST NOT AFFECT GAMEPLAY. NOT AT ALL.
#    Audio, visuals, haptics, HUD and prompts only. A setting may never change
#    damage, timing, difficulty, AI behaviour, or the READABILITY of information
#    the player has to react to.
#
#    The readability half is the subtle one and it has already bitten once:
#    flash_intensity originally scaled the telegraph fire-flash alpha to 0,
#    which made an incoming-attack cue invisible at the lowest setting — an
#    accessibility option quietly becoming a difficulty increase. It now maps
#    onto a floored range (Telegraph.MIN_FLASH_MULT). Apply the same rule to any
#    future visual setting that touches a danger cue.
#
#    THE ONE DELIBERATE EXCEPTION is ai_helper_tier, which is a difficulty
#    choice by design. It only reads on AI-controlled heroes (every consumer is
#    gated behind `not player_controlled`), so it is inert in 2P where both
#    ninjas are human.
# ============================================================

signal nameplates_changed(enabled: bool)
signal settings_changed
# Run 160 — fired whenever the window flips between windowed and fullscreen,
# from ANY source (settings menu, F11, Alt+Enter). Menus listen so their
# toggle never drifts out of sync with the real window state.
signal display_changed(is_fullscreen: bool)
# Run 61 — fired when the player swaps AI Helper Tier in any menu.
# RunState.set_ai_helper_tier() is called from the setter; listeners (HUD,
# pause overlay) can connect for live "current tier" badges.
signal ai_helper_tier_changed(tier: int)

const CFG_PATH: String = "user://settings.cfg"

# Run 175 — filter for HD gen-art that is drawn heavily DOWNSCALED (monsters ~0.15-0.25,
# family NPCs ~0.16, houses/Dojo/torii ~0.1-0.3). NEAREST at those ratios skips source
# pixels → jagged, shimmering "fuzzy" edges. Mipmapped linear gives a clean downsample.
# The PNGs' .import files have mipmaps/generate=true for this to work.
# One switch: set back to CanvasItem.TEXTURE_FILTER_NEAREST to restore the old look.
# (Pixel-art heroes, tiles and UI are NOT routed through this — they stay crisp.)
const HD_SPRITE_FILTER = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

# --- Values (defaults) ---
var master_volume: float = 1.0
var music_volume: float = 1.0
var sfx_volume: float = 1.0
# When true, pausing the game also pauses the music. Default OFF — music keeps
# playing through the pause menu. MusicManager reads this each frame.
var pause_music_with_game: bool = false
var brightness: float = 1.0
var shake_enabled: bool = true
## Local 2P gets its own toggle, DEFAULT OFF — see get_shake_mult().
var shake_enabled_2p: bool = false
var shake_intensity: float = 1.0

# ---------------------------------------------------------------------------
# Phase 6a — feel / accessibility (OUTPUT ONLY — no input behaviour changes)
# ---------------------------------------------------------------------------
# Every default below reproduces the pre-Phase-6 build exactly, so a player who
# never opens the menu sees no change at all.

## Damage number visibility. 0 = All, 1 = Crits only, 2 = Off.
## Read by DamageNumber.show_damage() — a single funnel every spawn site
## already goes through, so this needs no per-enemy wiring.
var damage_number_mode: int = 0
const DAMAGE_NUMBER_LABELS: Array = ["All", "Crits only", "Off"]

## Photosensitivity control. Scales the ALPHA of bright flash effects
## (telegraph fires, danger-circle flashes, the HUD break-bar red flash).
## 1.0 = current build, 0.0 = flashes fully suppressed.
##
## Deliberately separate from shake_intensity: they are different triggers for
## different people, and screen shake was already adjustable while flashes
## were not covered by anything.
var flash_intensity: float = 1.0

## Controller rumble. The game had none at all — this is new output, not a
## changed control. Routed through FX.screen_shake(), which every impact in the
## game already calls, so intensity stays consistent with what's on screen.
var rumble_enabled: bool = true
var rumble_strength: float = 1.0
var nameplates_enabled: bool = true
# Run 68 — safety confirmations (e.g. "are you sure?" before spending a reroll).
# On by default; players can disable for faster, no-prompt play.
var safety_confirmations: bool = true
# Run 61 — AI Helper Tier (1..5). Default 3 (Helpful / Balanced).
# Mirrored into RunState.ai_helper_tier on load + on every set.
var ai_helper_tier: int = 3
# Run 146 — beginner tooltips (HintPopup). On by default; veterans can
# disable in Settings to suppress the framed scene-entry tips.
var beginner_tips: bool = true
# Run 146 — combat tooltips: swap-hero reminder, attack controls, etc.
# Separate from beginner_tips so veterans can keep location tips but
# silence combat reminders (or vice versa).
var combat_tips: bool = true
# ---------------------------------------------------------------------------
# Run 160 — Display / fullscreen
# ---------------------------------------------------------------------------
# Fullscreen toggle. Default OFF (windowed).
#
# HOW THE "NO STRETCH, NO BLUR" GUARANTEE WORKS
# ---------------------------------------------
# Almost none of it lives here — the crispness comes from three project
# settings (project.godot -> [display]), and this file only flips the window
# mode. Documented here because this is where anyone looking for it will land:
#
#   window/stretch/mode   = "canvas_items"
#       2D is RENDERED at the monitor's real pixel resolution. The old
#       "viewport" mode drew a single 1280x720 image and blew it up to fill
#       the screen — that upscale is what made fullscreen look soft/blurry,
#       especially on HUD text. canvas_items has no upscale step at all.
#
#   window/stretch/aspect = "keep"
#       The 16:9 base is never squashed to match a differently-shaped screen.
#       On a 16:10 / 21:9 / 4:3 display you get black bars, NEVER distortion.
#
#   window/stretch/scale  = "fractional"
#       Allows non-integer scale factors (1.5x for 1080p, 2.25x for 1440p) so
#       the picture fills the screen instead of sitting in a huge black frame.
#
# Game code is unaffected by the mode switch: with canvas_items + keep,
# get_viewport_rect().size still reports the 1280x720 base size exactly as it
# did under "viewport", so every HUD/BoonOffer/DuoUlt layout keeps working.
#
# The window mode itself is WINDOW_MODE_FULLSCREEN — Godot's *borderless*
# fullscreen (a screen-sized undecorated window), NOT exclusive fullscreen.
# It alt-tabs instantly and never asks the OS to change the desktop's display
# mode, which is the other common source of a stretched-looking picture.
var fullscreen: bool = false

# Remembered windowed geometry so leaving fullscreen restores a sane window
# instead of dumping a screen-sized one at (0,0) with its title bar off-screen.
var windowed_size: Vector2i = Vector2i(1280, 720)

# ---------------------------------------------------------------------------
# Phase 3f — V-Sync + frame cap
# ---------------------------------------------------------------------------
# The game had no frame-rate controls at all, so a 2D game would render as fast
# as the GPU allowed — fans at full tilt, laptops draining, and screen tearing
# for anyone who wanted vsync off at the driver level but on in-game.
#
# vsync_mode indexes VSYNC_MODES below (kept as an int so the settings menu can
# cycle it and the config file stays human-readable).
#   0 Off       — lowest latency, may tear
#   1 On        — default; frame rate follows the monitor
#   2 Adaptive  — vsync until the frame budget is missed, then off (less stutter)
var vsync_mode: int = 1

const VSYNC_MODES: Array = [
	DisplayServer.VSYNC_DISABLED,
	DisplayServer.VSYNC_ENABLED,
	DisplayServer.VSYNC_ADAPTIVE,
]
const VSYNC_LABELS: Array = ["Off", "On", "Adaptive"]

# 0 = uncapped. Anything else is passed straight to Engine.max_fps.
# Note a cap is useful even WITH vsync on: it bounds CPU work on machines whose
# refresh rate is far above what the game needs.
var max_fps: int = 0
const FPS_OPTIONS: Array = [0, 30, 60, 120, 144, 240]

# 16:9 presets — every one of these is pixel-exact for the 1280x720 base, so
# windowed mode has zero letterboxing at any of them.
const WINDOW_PRESETS: Array = [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]
const MIN_WINDOW: Vector2i = Vector2i(960, 540)

# Debounce for the fullscreen hotkey — swallows key repeat and protects against
# a platform that also handles Alt+Enter itself (which would double-toggle).
const TOGGLE_DEBOUNCE_MS: int = 250
var _last_toggle_ms: int = -100000

# --- Brightness overlay (created once, persists across scene changes) ---
var _brightness_layer: CanvasLayer = null
var _brightness_rect: ColorRect = null


func _ready() -> void:
	# Run even while the tree is paused (pause menu changes settings live).
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()
	call_deferred("_ensure_brightness_overlay")
	_apply_audio()
	# Run 61 — push the persisted tier into RunState on boot (before any
	# arena scene reads it). Mirror via call_deferred so the RunState
	# autoload is guaranteed initialised.
	call_deferred("_apply_ai_tier_to_runstate")
	# Run 160 — deferred so the main window exists before we resize/mode it.
	call_deferred("_apply_display_on_boot")
	# Phase 3f — frame pacing. Engine.max_fps needs no window, but
	# window_set_vsync_mode does, so defer it for the same reason as above
	# rather than betting on autoload timing.
	_apply_max_fps()
	call_deferred("_apply_vsync")


# ---------------------------------------------------------------------------
# Shake helper — FX.screen_shake() asks for the active multiplier.
# ---------------------------------------------------------------------------
## Active shake multiplier — 0.0 when shake is off for the current mode.
##
## Phase 6a: local 2P reads a SEPARATE toggle, defaulting OFF. On a shared
## screen two ninjas both shaking the camera on every hit is genuinely too
## much (Bruno, 2026-08-01) — but it stays a player choice, and the 1P
## preference is remembered independently so turning it off for couch co-op
## never touches the solo setting.
##
## Rumble is entirely unaffected by this: haptics are per-player and per-pad,
## so each player keeps their own feedback even with the shared camera calm.
func get_shake_mult() -> float:
	var rs: Node = get_node_or_null("/root/RunState")
	if rs != null and "two_player" in rs and bool(rs.two_player):
		return shake_intensity if shake_enabled_2p else 0.0
	return shake_intensity if shake_enabled else 0.0


# ---------------------------------------------------------------------------
# Setters — apply live + persist.
# ---------------------------------------------------------------------------
func set_master_volume(v: float) -> void:
	master_volume = clampf(v, 0.0, 1.0)
	_apply_audio()
	save_settings()


func set_music_volume(v: float) -> void:
	music_volume = clampf(v, 0.0, 1.0)
	_apply_audio()
	save_settings()


func set_sfx_volume(v: float) -> void:
	sfx_volume = clampf(v, 0.0, 1.0)
	_apply_audio()
	save_settings()


func set_pause_music_with_game(on: bool) -> void:
	pause_music_with_game = on
	save_settings()
	emit_signal("settings_changed")


func set_brightness(v: float) -> void:
	brightness = clampf(v, 0.5, 1.5)
	_apply_brightness()
	save_settings()


func set_shake_enabled(on: bool) -> void:
	shake_enabled = on
	save_settings()
	emit_signal("settings_changed")


func set_shake_enabled_2p(on: bool) -> void:
	shake_enabled_2p = on
	save_settings()
	emit_signal("settings_changed")


func set_shake_intensity(v: float) -> void:
	shake_intensity = clampf(v, 0.0, 1.5)
	save_settings()
	emit_signal("settings_changed")


# ---------------------------------------------------------------------------
# Phase 6a setters
# ---------------------------------------------------------------------------
func set_damage_number_mode(m: int) -> void:
	damage_number_mode = clampi(m, 0, DAMAGE_NUMBER_LABELS.size() - 1)
	save_settings()
	emit_signal("settings_changed")


func cycle_damage_number_mode() -> void:
	set_damage_number_mode((damage_number_mode + 1) % DAMAGE_NUMBER_LABELS.size())


func get_damage_number_label() -> String:
	return String(DAMAGE_NUMBER_LABELS[clampi(damage_number_mode, 0,
		DAMAGE_NUMBER_LABELS.size() - 1)])


func set_flash_intensity(v: float) -> void:
	flash_intensity = clampf(v, 0.0, 1.0)
	save_settings()
	emit_signal("settings_changed")


## Multiplier for any bright-flash alpha. FX and HUD call this rather than
## reading the field, so the clamp lives in one place.
func get_flash_mult() -> float:
	return clampf(flash_intensity, 0.0, 1.0)


func set_rumble_enabled(on: bool) -> void:
	rumble_enabled = on
	if not on:
		_stop_all_rumble()
	save_settings()
	emit_signal("settings_changed")


func set_rumble_strength(v: float) -> void:
	rumble_strength = clampf(v, 0.0, 1.5)
	save_settings()
	emit_signal("settings_changed")


## Active rumble multiplier — 0.0 when disabled, mirroring get_shake_mult().
func get_rumble_mult() -> float:
	return rumble_strength if rumble_enabled else 0.0


## Kills any in-flight vibration the moment the player turns rumble off, so the
## setting takes effect immediately instead of after the current buzz decays.
## Routed through FX so its priority bookkeeping is cleared too.
func _stop_all_rumble() -> void:
	var fx: Node = get_node_or_null("/root/FX")
	if fx != null and fx.has_method("stop_rumble"):
		fx.stop_rumble()
		return
	for dev in Input.get_connected_joypads():
		Input.stop_joy_vibration(dev)


func set_nameplates_enabled(on: bool) -> void:
	nameplates_enabled = on
	save_settings()
	emit_signal("nameplates_changed", nameplates_enabled)
	emit_signal("settings_changed")


func set_safety_confirmations(on: bool) -> void:
	safety_confirmations = on
	save_settings()
	emit_signal("settings_changed")


func set_beginner_tips(on: bool) -> void:
	beginner_tips = on
	save_settings()
	emit_signal("settings_changed")


func set_combat_tips(on: bool) -> void:
	combat_tips = on
	save_settings()
	emit_signal("settings_changed")


# ---------------------------------------------------------------------------
# Run 160 — Fullscreen / windowed
# ---------------------------------------------------------------------------
func set_fullscreen(on: bool) -> void:
	if on == fullscreen and on == _display_is_fullscreen():
		return
	fullscreen = on
	_apply_fullscreen()
	save_settings()
	emit_signal("display_changed", fullscreen)
	emit_signal("settings_changed")


## Public flip — used by the settings menu, the F11 / Alt+Enter hotkey, and
## anything else that wants to switch modes. Always reads the REAL window
## state first so the flag can't drift.
func toggle_fullscreen() -> void:
	sync_fullscreen_from_display()
	set_fullscreen(not fullscreen)


## True when the actual OS window is fullscreen (borderless or exclusive) —
## not just what our saved flag believes.
func _display_is_fullscreen() -> bool:
	if OS.has_feature("web"):
		return fullscreen
	var m: int = DisplayServer.window_get_mode()
	return m == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or m == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


## Menus call this before drawing their toggle. Pulls the real window state
## back into `fullscreen` (silently — no save, no signal storm) so a checkbox
## can never show "off" while the game is actually fullscreen.
func sync_fullscreen_from_display() -> void:
	var real: bool = _display_is_fullscreen()
	if real != fullscreen:
		fullscreen = real


func is_fullscreen() -> bool:
	return _display_is_fullscreen()


# ---------------------------------------------------------------------------
# Phase 3f — V-Sync / frame cap setters
# ---------------------------------------------------------------------------
func set_vsync_mode(idx: int) -> void:
	vsync_mode = clampi(idx, 0, VSYNC_MODES.size() - 1)
	_apply_vsync()
	save_settings()
	emit_signal("settings_changed")


## Cycles Off -> On -> Adaptive -> Off, for the settings menu's cycle row.
func cycle_vsync_mode() -> void:
	set_vsync_mode((vsync_mode + 1) % VSYNC_MODES.size())


func get_vsync_label() -> String:
	return String(VSYNC_LABELS[clampi(vsync_mode, 0, VSYNC_LABELS.size() - 1)])


func _apply_vsync() -> void:
	# The web export has no control over the browser's compositor.
	if OS.has_feature("web"):
		return
	var m: int = int(VSYNC_MODES[clampi(vsync_mode, 0, VSYNC_MODES.size() - 1)])
	DisplayServer.window_set_vsync_mode(m)


func set_max_fps(v: int) -> void:
	max_fps = maxi(0, v)
	_apply_max_fps()
	save_settings()
	emit_signal("settings_changed")


func cycle_max_fps() -> void:
	var idx: int = FPS_OPTIONS.find(max_fps)
	if idx == -1:
		idx = 0
	set_max_fps(int(FPS_OPTIONS[(idx + 1) % FPS_OPTIONS.size()]))


func get_max_fps_label() -> String:
	return "Uncapped" if max_fps <= 0 else str(max_fps)


func _apply_max_fps() -> void:
	Engine.max_fps = max_fps


func _apply_fullscreen() -> void:
	# Web builds: the browser owns the canvas and only grants fullscreen from a
	# real user gesture. Leave the page alone rather than fighting it.
	if OS.has_feature("web"):
		return
	if fullscreen:
		# Snapshot the window we're leaving so BACK restores it exactly.
		_remember_windowed_geometry()
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		# Deferred: on Windows the mode change lands a frame later, and sizing
		# before it does gets silently clobbered back to the screen size.
		call_deferred("_apply_windowed_size")


## Boot path — applies the persisted mode AND the persisted window size.
func _apply_display_on_boot() -> void:
	if OS.has_feature("web"):
		return
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_apply_windowed_size()
	emit_signal("display_changed", fullscreen)


## Pick a windowed resolution. All presets are exact 16:9, so the 1280x720
## base scales to fill them with no black bars at all.
func set_windowed_size(s: Vector2i) -> void:
	windowed_size = Vector2i(maxi(s.x, MIN_WINDOW.x), maxi(s.y, MIN_WINDOW.y))
	save_settings()
	if not fullscreen:
		_apply_windowed_size()
	emit_signal("display_changed", fullscreen)
	emit_signal("settings_changed")


## Index of the current windowed size within WINDOW_PRESETS (0 if it matches
## none — e.g. the player dragged the window edge by hand).
func windowed_preset_index() -> int:
	for i in range(WINDOW_PRESETS.size()):
		if WINDOW_PRESETS[i] == windowed_size:
			return i
	return 0


## Cycles to the next preset that actually fits on the current monitor, so the
## menu can never hand the player a 1440p window on a 1080p screen.
func cycle_windowed_size() -> void:
	var usable: Vector2i = _usable_rect().size
	var start: int = windowed_preset_index()
	for step in range(1, WINDOW_PRESETS.size() + 1):
		var cand: Vector2i = WINDOW_PRESETS[(start + step) % WINDOW_PRESETS.size()]
		if cand.x <= usable.x and cand.y <= usable.y:
			set_windowed_size(cand)
			return
	set_windowed_size(WINDOW_PRESETS[0])


func _usable_rect() -> Rect2i:
	if OS.has_feature("web"):
		return Rect2i(Vector2i.ZERO, Vector2i(1280, 720))
	return DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())


## Records the current window size while we're still windowed, so a manual
## resize is what gets restored after a fullscreen round-trip.
func _remember_windowed_geometry() -> void:
	if OS.has_feature("web") or _display_is_fullscreen():
		return
	var s: Vector2i = DisplayServer.window_get_size()
	if s.x >= MIN_WINDOW.x and s.y >= MIN_WINDOW.y:
		windowed_size = s


## Resizes + re-centres the window, clamped to the monitor's usable area so
## the title bar is never pushed off the top of the screen.
func _apply_windowed_size() -> void:
	if OS.has_feature("web") or _display_is_fullscreen():
		return
	var usable: Rect2i = _usable_rect()
	var s := Vector2i(
		clampi(windowed_size.x, MIN_WINDOW.x, maxi(MIN_WINDOW.x, usable.size.x)),
		clampi(windowed_size.y, MIN_WINDOW.y, maxi(MIN_WINDOW.y, usable.size.y)))
	DisplayServer.window_set_size(s)
	var pos: Vector2i = usable.position + (usable.size - s) / 2
	# Leave room for the title bar — window_set_position places the CLIENT
	# area, so a centred y of 0 would hide the decoration above the screen.
	pos.y = maxi(pos.y, usable.position.y + 36)
	pos.x = maxi(pos.x, usable.position.x)
	DisplayServer.window_set_position(pos)


## Global hotkeys: F11 and Alt+Enter both flip fullscreen, from any scene —
## including while paused (process_mode is ALWAYS).
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	# Check keycode AND physical_keycode — depending on layout/platform only one
	# of the two is populated.
	var code: int = k.keycode if k.keycode != 0 else k.physical_keycode
	var phys: int = k.physical_keycode
	var is_enter: bool = code == KEY_ENTER or code == KEY_KP_ENTER \
		or phys == KEY_ENTER or phys == KEY_KP_ENTER
	var wants_toggle: bool = code == KEY_F11 or phys == KEY_F11 \
		or (k.alt_pressed and is_enter)
	if not wants_toggle:
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_toggle_ms < TOGGLE_DEBOUNCE_MS:
		get_viewport().set_input_as_handled()
		return
	_last_toggle_ms = now
	toggle_fullscreen()
	get_viewport().set_input_as_handled()


# Run 61 — AI Helper Tier setter (1..5). Mirrors into RunState (which
# also tracks the per-run high-water mark for the RunComplete accolade).
func set_ai_helper_tier(t: int) -> void:
	ai_helper_tier = clampi(t, 1, 5)
	_apply_ai_tier_to_runstate()
	save_settings()
	emit_signal("ai_helper_tier_changed", ai_helper_tier)
	emit_signal("settings_changed")


## Called by SaveManager after loading a save file — mirrors RunState's
## per-save tier into Settings WITHOUT writing to the global config (so
## the global config stays as the "default for new files" value).
func sync_ai_tier_from_runstate() -> void:
	var rs: Node = get_node_or_null("/root/RunState")
	if rs == null:
		return
	var t: int = int(rs.ai_helper_tier) if "ai_helper_tier" in rs else ai_helper_tier
	if t != ai_helper_tier:
		ai_helper_tier = clampi(t, 1, 5)
		emit_signal("ai_helper_tier_changed", ai_helper_tier)
		# Intentionally no save_settings() — global config keeps the menu default.


func _apply_ai_tier_to_runstate() -> void:
	var rs: Node = get_node_or_null("/root/RunState")
	if rs == null:
		return
	if rs.has_method("set_ai_helper_tier"):
		rs.set_ai_helper_tier(ai_helper_tier)
	elif "ai_helper_tier" in rs:
		rs.ai_helper_tier = ai_helper_tier


# ---------------------------------------------------------------------------
# Audio — Master/Music/SFX buses. Buses are created at runtime if the project
# doesn't define them, so this works even before any real audio is wired.
# ---------------------------------------------------------------------------
func _ensure_bus(bus_name: String) -> int:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")
	return idx


func _set_bus_volume(idx: int, linear: float) -> void:
	if idx < 0:
		return
	if linear <= 0.0005:
		AudioServer.set_bus_mute(idx, true)
	else:
		AudioServer.set_bus_mute(idx, false)
		AudioServer.set_bus_volume_db(idx, linear_to_db(clampf(linear, 0.0005, 1.0)))


func _apply_audio() -> void:
	var music_idx: int = _ensure_bus("Music")
	var sfx_idx: int = _ensure_bus("SFX")
	_set_bus_volume(0, master_volume)   # bus 0 is always Master
	_set_bus_volume(music_idx, music_volume)
	_set_bus_volume(sfx_idx, sfx_volume)


# ---------------------------------------------------------------------------
# Brightness — fullscreen overlay on a very high CanvasLayer. Darkens below
# 1.0 (black overlay) and lightens above 1.0 (white overlay). Parented to the
# tree root so it survives change_scene_to_file().
# ---------------------------------------------------------------------------
func _ensure_brightness_overlay() -> void:
	if is_instance_valid(_brightness_layer):
		_apply_brightness()
		return
	_brightness_layer = CanvasLayer.new()
	_brightness_layer.layer = 128
	_brightness_rect = ColorRect.new()
	_brightness_rect.anchor_right = 1.0
	_brightness_rect.anchor_bottom = 1.0
	_brightness_rect.offset_left = 0.0
	_brightness_rect.offset_top = 0.0
	_brightness_rect.offset_right = 0.0
	_brightness_rect.offset_bottom = 0.0
	_brightness_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_brightness_layer.add_child(_brightness_rect)
	get_tree().root.add_child(_brightness_layer)
	_apply_brightness()


func _apply_brightness() -> void:
	if not is_instance_valid(_brightness_rect):
		return
	if brightness < 1.0:
		_brightness_rect.color = Color(0.0, 0.0, 0.0, 1.0 - brightness)
	elif brightness > 1.0:
		_brightness_rect.color = Color(1.0, 1.0, 1.0, (brightness - 1.0) * 0.6)
	else:
		_brightness_rect.color = Color(0.0, 0.0, 0.0, 0.0)


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------
func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.set_value("audio", "pause_music_with_game", pause_music_with_game)
	cfg.set_value("video", "brightness", brightness)
	cfg.set_value("feel", "shake_enabled", shake_enabled)
	cfg.set_value("feel", "shake_enabled_2p", shake_enabled_2p)
	cfg.set_value("feel", "shake_intensity", shake_intensity)
	cfg.set_value("feel", "flash_intensity", flash_intensity)
	cfg.set_value("feel", "rumble_enabled", rumble_enabled)
	cfg.set_value("feel", "rumble_strength", rumble_strength)
	cfg.set_value("hud", "damage_number_mode", damage_number_mode)
	cfg.set_value("hud", "nameplates", nameplates_enabled)
	cfg.set_value("ui", "safety_confirmations", safety_confirmations)
	cfg.set_value("ai", "helper_tier", ai_helper_tier)
	cfg.set_value("ui", "beginner_tips", beginner_tips)
	cfg.set_value("ui", "combat_tips", combat_tips)
	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.set_value("video", "window_w", windowed_size.x)
	cfg.set_value("video", "window_h", windowed_size.y)
	cfg.set_value("video", "vsync_mode", vsync_mode)
	cfg.set_value("video", "max_fps", max_fps)
	cfg.save(CFG_PATH)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return   # no file yet — keep defaults
	master_volume = float(cfg.get_value("audio", "master", master_volume))
	music_volume = float(cfg.get_value("audio", "music", music_volume))
	sfx_volume = float(cfg.get_value("audio", "sfx", sfx_volume))
	pause_music_with_game = bool(cfg.get_value("audio", "pause_music_with_game", pause_music_with_game))
	brightness = float(cfg.get_value("video", "brightness", brightness))
	shake_enabled = bool(cfg.get_value("feel", "shake_enabled", shake_enabled))
	shake_enabled_2p = bool(cfg.get_value("feel", "shake_enabled_2p", shake_enabled_2p))
	shake_intensity = float(cfg.get_value("feel", "shake_intensity", shake_intensity))
	# Phase 6a — absent from configs written before this, so existing players
	# pick up the defaults, which reproduce the old behaviour exactly.
	flash_intensity = clampf(float(cfg.get_value("feel", "flash_intensity", flash_intensity)), 0.0, 1.0)
	rumble_enabled = bool(cfg.get_value("feel", "rumble_enabled", rumble_enabled))
	rumble_strength = clampf(float(cfg.get_value("feel", "rumble_strength", rumble_strength)), 0.0, 1.5)
	damage_number_mode = clampi(int(cfg.get_value("hud", "damage_number_mode", damage_number_mode)),
		0, DAMAGE_NUMBER_LABELS.size() - 1)
	nameplates_enabled = bool(cfg.get_value("hud", "nameplates", nameplates_enabled))
	safety_confirmations = bool(cfg.get_value("ui", "safety_confirmations", safety_confirmations))
	ai_helper_tier = clampi(int(cfg.get_value("ai", "helper_tier", ai_helper_tier)), 1, 5)
	beginner_tips = bool(cfg.get_value("ui", "beginner_tips", beginner_tips))
	combat_tips = bool(cfg.get_value("ui", "combat_tips", combat_tips))
	fullscreen = bool(cfg.get_value("video", "fullscreen", fullscreen))
	# Phase 3f — absent in configs written before this existed, so the defaults
	# (vsync On, uncapped) apply automatically to existing players.
	vsync_mode = clampi(int(cfg.get_value("video", "vsync_mode", vsync_mode)),
		0, VSYNC_MODES.size() - 1)
	max_fps = maxi(0, int(cfg.get_value("video", "max_fps", max_fps)))
	windowed_size = Vector2i(
		maxi(int(cfg.get_value("video", "window_w", windowed_size.x)), MIN_WINDOW.x),
		maxi(int(cfg.get_value("video", "window_h", windowed_size.y)), MIN_WINDOW.y))
