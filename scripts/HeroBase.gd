class_name HeroBase
extends CharacterBody2D
# ============================================================
# HeroBase.gd — Batch 1 of the architecture refactor (2026-07-23)
# ============================================================
# Shared base for the two playable heroes:
#   Player.gd (Shino)  and  BeaAI.gd (Bea)
# Both extend this class BY PATH (extends "res://scripts/HeroBase.gd")
# so no global-class-cache scan is required for a correct first load.
#
# Extraction plan: shared functions/vars migrate here batch-by-batch per
# Hero_Diff_Map.md §7 (project root docs folder). Rules:
#   - A function moves here ONLY when its behavior is verified identical
#     (or made identical) in both heroes, and every var/const it touches
#     either moves with it or already lives here.
#   - Hero-specific values become vars set by the child in _init/_ready
#     (e.g. hero_id, sprite scale) — never hardcoded here.
#   - Public API names, signal names, group memberships must NOT change
#     (Wiring_Map.md contracts).
# ============================================================

# --- Hero identity (set by each child before/at _ready) -------------
# "shino" or "bea" — the key used across RunState per-hero gating
# (shino_has/bea_has, get_*_for(hero_id), etc.).
var hero_id: String = ""

# --- Frost / chill status (shared; Run 92 slippery-ice + frost stacks) -----
# Stacking movement slow. Each stack shaves FROST_SLOW_PER_STACK off move speed.
const FROST_SLOW_PER_STACK: float = 0.08   # 5 stacks → ×0.60 move speed (40% slow)
var frost_stacks: int = 0


# ============================================================
# Batch 2 extraction (2026-07-23) — shared leaf helpers.
# Migrated verbatim from Player.gd / BeaAI.gd (verified identical).
# Per-hero differences resolved via hero_id or child-overridable stubs.
# ============================================================

# --- Per-device input routing (Run 73, local 2-player) --------------
# _input_device() stays child-implemented (Shino → RunState.shino_device,
# Bea → RunState.bea_device). This neutral stub lets the shared wrappers
# below compile in HeroBase; each child overrides it with its own device.
func _input_device() -> int:
	return 0

func _act_p(action: String) -> bool:
	if RunState.two_player:
		return InputRouter.pressed(_input_device(), action)
	return Input.is_action_pressed(action)

func _act_jp(action: String) -> bool:
	if RunState.two_player:
		return InputRouter.just_pressed(_input_device(), action)
	return Input.is_action_just_pressed(action)

func _act_jr(action: String) -> bool:
	if RunState.two_player:
		return InputRouter.just_released(_input_device(), action)
	return Input.is_action_just_released(action)

func _move_axis() -> Vector2:
	if RunState.two_player:
		return InputRouter.move_vector(_input_device())
	return Vector2(Input.get_axis("move_left", "move_right"), Input.get_axis("move_up", "move_down"))

func _aim_vec() -> Vector2:
	if RunState.two_player:
		return InputRouter.aim_vector(_input_device())
	return Input.get_vector("aim_left", "aim_right", "aim_up", "aim_down")


# --- Slot attack-tint helper (per-hero via hero_id) -----------------
func _fx_col(base: Color, slot: String) -> Color:
	var tint: Color = RunState.get_attack_tint(hero_id, slot)
	if tint.a <= 0.0:
		return base
	var mixed: Color = base.lerp(tint, 0.65)
	mixed.a = base.a
	return mixed


# --- Frost movement multiplier --------------------------------------
func _frost_move_mult() -> float:
	if frost_stacks <= 0:
		return 1.0
	return maxf(0.25, 1.0 - FROST_SLOW_PER_STACK * float(frost_stacks))
