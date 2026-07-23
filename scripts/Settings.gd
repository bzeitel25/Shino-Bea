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
# ============================================================

signal nameplates_changed(enabled: bool)
signal settings_changed
# Run 61 — fired when the player swaps AI Helper Tier in any menu.
# RunState.set_ai_helper_tier() is called from the setter; listeners (HUD,
# pause overlay) can connect for live "current tier" badges.
signal ai_helper_tier_changed(tier: int)

const CFG_PATH: String = "user://settings.cfg"

# --- Values (defaults) ---
var master_volume: float = 1.0
var music_volume: float = 1.0
var sfx_volume: float = 1.0
# When true, pausing the game also pauses the music. Default OFF — music keeps
# playing through the pause menu. MusicManager reads this each frame.
var pause_music_with_game: bool = false
var brightness: float = 1.0
var shake_enabled: bool = true
var shake_intensity: float = 1.0
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
# Fullscreen toggle. Default OFF (windowed).
var fullscreen: bool = false

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
	call_deferred("_apply_fullscreen")


# ---------------------------------------------------------------------------
# Shake helper — FX.screen_shake() asks for the active multiplier.
# ---------------------------------------------------------------------------
func get_shake_mult() -> float:
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


func set_shake_intensity(v: float) -> void:
	shake_intensity = clampf(v, 0.0, 1.5)
	save_settings()
	emit_signal("settings_changed")


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


func set_fullscreen(on: bool) -> void:
	fullscreen = on
	_apply_fullscreen()
	save_settings()
	emit_signal("settings_changed")


func _apply_fullscreen() -> void:
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


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
	cfg.set_value("feel", "shake_intensity", shake_intensity)
	cfg.set_value("hud", "nameplates", nameplates_enabled)
	cfg.set_value("ui", "safety_confirmations", safety_confirmations)
	cfg.set_value("ai", "helper_tier", ai_helper_tier)
	cfg.set_value("ui", "beginner_tips", beginner_tips)
	cfg.set_value("ui", "combat_tips", combat_tips)
	cfg.set_value("video", "fullscreen", fullscreen)
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
	shake_intensity = float(cfg.get_value("feel", "shake_intensity", shake_intensity))
	nameplates_enabled = bool(cfg.get_value("hud", "nameplates", nameplates_enabled))
	safety_confirmations = bool(cfg.get_value("ui", "safety_confirmations", safety_confirmations))
	ai_helper_tier = clampi(int(cfg.get_value("ai", "helper_tier", ai_helper_tier)), 1, 5)
	beginner_tips = bool(cfg.get_value("ui", "beginner_tips", beginner_tips))
	combat_tips = bool(cfg.get_value("ui", "combat_tips", combat_tips))
	fullscreen = bool(cfg.get_value("video", "fullscreen", fullscreen))
