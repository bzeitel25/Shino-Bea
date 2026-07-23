extends Node2D

# ============================================================
# TestArena.gd — Run 23 (2026-06-01)
# ============================================================
# Single-arena 10-wave gauntlet. Replaces the Arena1→Arena2→Arena3
# chain from earlier prototype. Flow:
#
#   wave 1 spawns on _ready
#   on wave_cleared signal:
#     - present a between-waves reward overlay
#         random: ~75% chance regular BoonOffer card / ~25% Apple Pie
#         (BoonOffer's own internal 12% Pie chance still rolls inside
#          the boon path, so true split is ~75% boon, ~25% pie roughly)
#     - on reward picked: advance wave_index, spawn next wave
#     - on wave 5 + wave 10: ALSO trigger Apple Juice (50% HP heal, both heroes)
#   after wave 10 reward picked: fade-to-black, transition to BossArena.tscn
#
# Spawn logic is owned by this script directly (no EnemySpawner dependency),
# so each wave can have a unique composition (mix of melee/shooter/scout).
#
# Author note: a future iteration could spawn Apple Juice as a walk-to-pickup
# item with a sprite, but for Run 23 it auto-applies on the +5/+10 wave clears
# (with a banner + particle burst on both heroes) — per Bruno's brief.
# ============================================================

const BOON_OFFER_SCENE_PATH: String = "res://scenes/BoonOffer.tscn"
const BOSS_ARENA_PATH: String = "res://scenes/BossArena.tscn"

# Probability of dropping an Apple Pie *instead of* a normal boon offer.
# Note: BoonOffer.gd internally has its own ~12% Pie chance when rolling a
# boon offer. The combined effective Pie rate per cleared wave is therefore
# higher than this raw value. Tune via playtest.
const REWARD_PIE_CHANCE: float = 0.18

# Waves on which to also award Apple Juice (50% HP heal to both heroes).
const APPLE_JUICE_WAVE_INDICES: Array = [5, 10]

const TOTAL_WAVES: int = 10

const POLL_INTERVAL: float = 0.25

# Spawn distance bounds (mirrors EnemySpawner conventions; clamp inside walls)
const MIN_SPAWN_DIST: float = 140.0
const MAX_SPAWN_DIST: float = 280.0
const SPAWN_CLAMP_X: float = 440.0
const SPAWN_CLAMP_Y: float = 310.0

# Resolved on _ready by preloading per-wave scenes.
var DUMMY_SCENE:   PackedScene = preload("res://scenes/DummyEnemy.tscn")
var SHOOTER_SCENE: PackedScene = preload("res://scenes/RangedShooter.tscn")
var SCOUT_SCENE:   PackedScene = preload("res://scenes/FastScout.tscn")

# Wave compositions: dict per wave with primary/secondary/tertiary counts.
# Index 0 = wave 1, index 9 = wave 10. Difficulty ramps via count + variety.
var WAVE_DEFS: Array = [
	{"dummies": 3, "shooters": 0, "scouts": 0, "label": "Wave 1 — easy melee"},
	{"dummies": 4, "shooters": 0, "scouts": 0, "label": "Wave 2 — more melee"},
	{"dummies": 3, "shooters": 1, "scouts": 0, "label": "Wave 3 — first shooter"},
	{"dummies": 2, "shooters": 0, "scouts": 2, "label": "Wave 4 — scout rush"},
	{"dummies": 4, "shooters": 1, "scouts": 1, "label": "Wave 5 — mixed force ★"},
	{"dummies": 3, "shooters": 2, "scouts": 0, "label": "Wave 6 — twin shooters"},
	{"dummies": 4, "shooters": 0, "scouts": 2, "label": "Wave 7 — speed gauntlet"},
	{"dummies": 4, "shooters": 1, "scouts": 2, "label": "Wave 8 — combined arms"},
	{"dummies": 5, "shooters": 2, "scouts": 1, "label": "Wave 9 — heavy assault"},
	{"dummies": 4, "shooters": 2, "scouts": 3, "label": "Wave 10 — final stand ★"},
]

@onready var enemies_root:  Node2D = $Enemies
@onready var cleared_label: Label  = $DebugHUD/WaveClearedLabel
@onready var wave_label:    Label  = get_node_or_null("DebugHUD/WaveLabel")
@onready var boons_label:   Label  = get_node_or_null("DebugHUD/BoonsLabel")
@onready var controls_hint: Label  = get_node_or_null("DebugHUD/ControlsHint")

var wave_index: int = 0          # 1-indexed once first wave spawns
var _wave_active: bool = false
var _poll_timer: float = 0.0
var _reward_in_progress: bool = false
var _transitioning_to_boss: bool = false
var _hint_visible: bool = true


func _ready() -> void:
	print("[TestArena] _ready — booting 10-wave gauntlet.")

	# Run 52 — wave-cleared banner: small, docked top-right (matches World.gd).
	if cleared_label:
		cleared_label.anchor_left = 1.0
		cleared_label.anchor_right = 1.0
		cleared_label.anchor_top = 0.0
		cleared_label.anchor_bottom = 0.0
		cleared_label.offset_left = -460.0
		cleared_label.offset_right = -16.0
		cleared_label.offset_top = 40.0
		cleared_label.offset_bottom = 120.0
		cleared_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		cleared_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		cleared_label.add_theme_font_size_override("font_size", 15)

	# Fade in (FX autoload handles overlay).
	if get_node_or_null("/root/FX") and FX.has_method("fade_from_black"):
		FX.fade_from_black(0.35)

	# Run 146 — combat tip for the training arena.
	const HINT = preload("res://scripts/HintPopup.gd")
	HINT.show_combat_hint(self, "Training Arena",
		"Tap Y for combos  •  Hold Y to charge  •  X for heavy attacks  •  Q+Q swaps ninja  •  Survive all 10 waves")

	# Begin wave 1 after one frame so player/Bea have time to add to groups.
	call_deferred("_start_next_wave")


func _process(delta: float) -> void:
	if not _wave_active:
		return
	_poll_timer -= delta
	if _poll_timer <= 0.0:
		_poll_timer = POLL_INTERVAL
		_check_wave_cleared()


func _input(event: InputEvent) -> void:
	# H toggles controls-hint overlay. Gamepad Start (button 6) also toggles.
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_H:
		_toggle_hint()
	elif event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_START:
		_toggle_hint()


func _toggle_hint() -> void:
	if controls_hint == null:
		return
	_hint_visible = not _hint_visible
	controls_hint.visible = _hint_visible


# ---------------------------------------------------------------------------
# Wave control
# ---------------------------------------------------------------------------

func _start_next_wave() -> void:
	if _transitioning_to_boss:
		return
	wave_index += 1
	if wave_index > TOTAL_WAVES:
		# Should already have transitioned at wave 10 reward — this is a guard.
		_begin_transition_to_boss()
		return

	var def: Dictionary = WAVE_DEFS[wave_index - 1]
	if wave_label:
		wave_label.text = "Wave %d / %d" % [wave_index, TOTAL_WAVES]
	if cleared_label:
		cleared_label.visible = false
	print("[TestArena] Spawning %s" % str(def.get("label", "wave")))

	_spawn_wave_composition(def)
	_wave_active = true
	_poll_timer = POLL_INTERVAL


func _spawn_wave_composition(def: Dictionary) -> void:
	var d_n: int = int(def.get("dummies", 0))
	var s_n: int = int(def.get("shooters", 0))
	var c_n: int = int(def.get("scouts", 0))
	var total: int = d_n + s_n + c_n
	if total <= 0:
		push_warning("[TestArena] Empty wave def — skipping spawn.")
		return

	var idx: int = 0
	for i in d_n:
		_spawn_enemy(DUMMY_SCENE, idx, total, "dummy")
		idx += 1
	for i in s_n:
		_spawn_enemy(SHOOTER_SCENE, idx, total, "shooter")
		idx += 1
	for i in c_n:
		_spawn_enemy(SCOUT_SCENE, idx, total, "scout")
		idx += 1

	print("[TestArena] Wave %d spawned — %d dummy / %d shooter / %d scout (total %d)" % [
		wave_index, d_n, s_n, c_n, total,
	])


func _spawn_enemy(scene: PackedScene, slot: int, total: int, kind: String) -> void:
	if scene == null:
		return
	var e: Node = scene.instantiate()
	enemies_root.add_child(e)
	var base_angle: float = (TAU / max(1, total)) * slot
	var jitter: float = randf_range(-0.4, 0.4)
	var angle: float = base_angle + jitter
	var dist: float = randf_range(MIN_SPAWN_DIST, MAX_SPAWN_DIST)
	# Position kind-tuning: shooters outer, scouts inner.
	if kind == "shooter":
		dist = max(dist, (MIN_SPAWN_DIST + MAX_SPAWN_DIST) * 0.5 + 30.0)
	elif kind == "scout":
		dist = min(dist, MIN_SPAWN_DIST + 60.0)
	var pos: Vector2 = Vector2(cos(angle) * dist, sin(angle) * dist)
	pos.x = clamp(pos.x, -SPAWN_CLAMP_X, SPAWN_CLAMP_X)
	pos.y = clamp(pos.y, -SPAWN_CLAMP_Y, SPAWN_CLAMP_Y)
	e.global_position = pos


func _check_wave_cleared() -> void:
	var living: Array = get_tree().get_nodes_in_group("enemy")
	if living.is_empty():
		_wave_active = false
		_on_wave_cleared()


func _on_wave_cleared() -> void:
	if _reward_in_progress:
		return
	_reward_in_progress = true
	print("[TestArena] Wave %d cleared!" % wave_index)
	RunState.arenas_cleared += 1

	# Sweet Dreams + similar per-clear effects (Apple §8.1).
	for p in get_tree().get_nodes_in_group("player"):
		if p.has_method("apply_sweet_dreams_heal"):
			p.apply_sweet_dreams_heal()
	for b in get_tree().get_nodes_in_group("bea"):
		if b.is_in_group("player"):
			continue
		if b.has_method("apply_sweet_dreams_heal"):
			b.apply_sweet_dreams_heal()

	if cleared_label:
		cleared_label.visible = true
		var is_final: bool = (wave_index == TOTAL_WAVES)
		if is_final:
			cleared_label.text = "✦ WAVE %d / %d CLEARED ✦\nPrepare for the BOSS..." % [wave_index, TOTAL_WAVES]
		else:
			cleared_label.text = "✦ WAVE %d / %d CLEARED ✦\nChoose your reward..." % [wave_index, TOTAL_WAVES]

	# Defer one frame so any death anims spawn first.
	call_deferred("_present_reward")


# ---------------------------------------------------------------------------
# Reward overlay (BoonOffer with reroll for Apple Pie path)
# ---------------------------------------------------------------------------

func _present_reward() -> void:
	if not ResourceLoader.exists(BOON_OFFER_SCENE_PATH):
		push_warning("[TestArena] BoonOffer.tscn missing — skipping reward.")
		_after_reward(true)
		return
	if get_tree().current_scene.has_node("BoonOffer"):
		return

	# Pre-roll: if reward is Apple Pie, force the BoonOffer to display the
	# pie sentinel by populating RunState.current_offer with a single-id list
	# containing the APPLE_PIE sentinel. BoonOffer reads it on _ready.
	var roll: float = randf()
	if roll < REWARD_PIE_CHANCE:
		# Run 32 fix: Upgrade Room shows ONLY Pie + Dragon Fruit — no random family
		# boons mixed in. The old path leaked Apple (or other family) boons alongside
		# the Pie card because roll_offer() could return any family. Now we use the same
		# sentinel-only path as BoonOffer's `force_apple_pie` branch: current_offer
		# intentionally left empty so BoonOffer's _ready detects it as a door-pick-Pie
		# room. We push a synthetic "apple_pie" pending reward instead.
		RunState.current_offer.clear()
		# Synthesise a pending reward so BoonOffer enters the upgrade-room path.
		# Run 27c FIX: route through commit_door_choice() (the legacy
		# pending_room_reward var is never read by BoonOffer).
		RunState.commit_door_choice({"type": "apple_pie", "family": ""})
		print("[TestArena] Reward: Upgrade Room (Pie + Dragon Fruit only).")
	else:
		# Normal path: let BoonOffer roll its own boon offer.
		RunState.current_offer.clear()
		print("[TestArena] Reward: normal boon offer roll.")

	var overlay: CanvasLayer = load(BOON_OFFER_SCENE_PATH).instantiate()
	overlay.name = "BoonOffer"
	get_tree().current_scene.add_child(overlay)
	overlay.boon_picked.connect(_on_reward_picked)


func _on_reward_picked(_boon_id: String) -> void:
	# Apple Juice on +5 / +10 — auto-apply heal after reward pick.
	if wave_index in APPLE_JUICE_WAVE_INDICES:
		var healed_total: int = RunState.grant_apple_juice(get_tree())
		# Visual banner: re-use cleared_label briefly.
		if cleared_label:
			cleared_label.text = "🧃 APPLE JUICE +50%% HP\n(both heroes restored — %d HP total)" % healed_total
		# Slight delay so player can see banner before next wave loads.
		await get_tree().create_timer(1.4).timeout

	_after_reward(false)


func _after_reward(_skipped: bool) -> void:
	_reward_in_progress = false
	_refresh_boons_label()

	if wave_index >= TOTAL_WAVES:
		# Wave 10 reward complete → transition to boss arena.
		_begin_transition_to_boss()
	else:
		_start_next_wave()


# ---------------------------------------------------------------------------
# Boss transition
# ---------------------------------------------------------------------------

func _begin_transition_to_boss() -> void:
	if _transitioning_to_boss:
		return
	_transitioning_to_boss = true
	# Cache carry-state so boss arena spawns with the same HP / Chi.
	var players: Array = get_tree().get_nodes_in_group("player")
	for p in players:
		if p.is_in_group("bea"):
			continue
		if p.has_method("get_current_hp") and p.has_method("get_current_chi"):
			RunState.cache_player_carry(p.get_current_hp(), p.get_current_chi())
			break
	var beas: Array = get_tree().get_nodes_in_group("bea")
	if beas.size() > 0:
		var bea: Node = beas[0]
		if bea.has_method("get_current_hp") and bea.has_method("get_current_chi"):
			RunState.cache_bea_carry(bea.get_current_hp(), bea.get_current_chi())

	print("[TestArena] All 10 waves cleared — fading to BossArena.")
	if get_node_or_null("/root/FX") and FX.has_method("fade_to_black"):
		FX.fade_to_black(0.45, 0.10, 1.0, Callable(self, "_execute_boss_transition"))
	else:
		_execute_boss_transition()


func _execute_boss_transition() -> void:
	get_tree().change_scene_to_file(BOSS_ARENA_PATH)


# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------

func _refresh_boons_label() -> void:
	# Old flat "Boons: ..." label replaced by the split per-character HUD panels.
	if boons_label != null:
		boons_label.visible = false
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("refresh_boon_panel"):
			h.refresh_boon_panel()
			break
