class_name SoundBank
extends RefCounted
# ============================================================
# SoundBank.gd — pure data table for SFX  (Phase 2a)
# ============================================================
# Plain data class, NOT an autoload — same pattern as BoonDB.gd.
# SFX.gd (the autoload) reads this and does the playing.
#
# ── HOW TO ADD A SOUND ──────────────────────────────────────
# 1. Drop the file(s) into Assets/SFX/<category>/
# 2. Open Godot once so the importer generates the .import file
# 3. Put the res:// path(s) into the matching entry's "streams" array
# That's it. No code changes anywhere else — all 110 existing
# FX.play_sound() call sites already route here.
#
# ── ENTRY SCHEMA ────────────────────────────────────────────
#   "streams":    Array[String]  res:// paths. One is picked at random per
#                                play, which is what stops repeated hits
#                                sounding like a machine gun. EMPTY = silent
#                                (intentional, no warning).
#   "vol_db":     float   offset in dB. Default 0.0. Negative = quieter.
#   "pitch":      [min, max]  randomised per play. Default [1.0, 1.0].
#                             [0.94, 1.06] is a good default for impacts.
#   "limit_ms":   int   minimum gap between two plays of THIS event.
#                       Default 40. Raise for anything that fires per-frame.
#   "max_voices": int   how many copies of this event may overlap.
#                       Default 3. Keep low for rapid events.
#   "bus":        String  audio bus. Default "SFX".
#
# ── DESIGN NOTE: empty vs unknown ───────────────────────────
# An event declared here with streams:[] is SILENT AND EXPECTED — no
# warning. An event NOT declared here at all warns once in debug builds.
# That distinction is what lets the combat set stay empty (Phase 2b)
# while still catching genuine typos in event names.
#
# Every event name below was extracted from the live call sites; the
# comment on each says where it fires and what sound it wants.
# ============================================================

# --- Defaults applied by SFX.gd when a key is absent ---
const DEFAULT_VOL_DB: float     = 0.0
const DEFAULT_PITCH: Array      = [1.0, 1.0]
const DEFAULT_LIMIT_MS: int     = 40
const DEFAULT_MAX_VOICES: int   = 3
const DEFAULT_BUS: String       = "SFX"

const SFX_ROOT: String = "res://Assets/SFX/"


const EVENTS: Dictionary = {

# ===========================================================
# UI / MENU  — WIRED (Phase 2a placeholders, procedurally generated)
# ===========================================================
"ui_move": {
	"streams": ["res://Assets/SFX/ui/ui_move.wav"],
	"vol_db": -14.0, "pitch": [0.98, 1.02], "limit_ms": 45, "max_voices": 2,
},
"ui_confirm": {
	"streams": ["res://Assets/SFX/ui/ui_confirm.wav"],
	"vol_db": -10.0, "limit_ms": 80, "max_voices": 2,
},
"ui_back": {
	"streams": ["res://Assets/SFX/ui/ui_back.wav"],
	"vol_db": -11.0, "limit_ms": 80, "max_voices": 2,
},
"ui_error": {
	"streams": ["res://Assets/SFX/ui/ui_error.wav"],
	"vol_db": -10.0, "limit_ms": 150, "max_voices": 1,
},
"menu_open": {
	"streams": ["res://Assets/SFX/ui/menu_open.wav"],
	"vol_db": -10.0, "limit_ms": 120, "max_voices": 1,
},
"menu_close": {
	"streams": ["res://Assets/SFX/ui/menu_close.wav"],
	"vol_db": -10.0, "limit_ms": 120, "max_voices": 1,
},
"coin_pickup": {
	"streams": ["res://Assets/SFX/ui/coin_pickup.wav"],
	"vol_db": -13.0, "pitch": [0.96, 1.10], "limit_ms": 30, "max_voices": 4,
},

# ===========================================================
# HERO MELEE / IMPACT   (Phase 2b — Kenney "Impact Sounds" fits these)
# ===========================================================
# Shino PUNCHES (Y-combo connect). Kicks use kick_light/kick_heavy below —
# Shino.gd branches on AttackType.X so a kick never plays a punch sound.
# Bruno's picks (CC0 retro-arcade Impacts): Y1-3 hit = Impact3, Y4 finisher = Impact4.
"hit_light":      {"streams": ["res://Assets/SFX/combat/hit_light_01.wav"], "vol_db": -6.0, "pitch": [0.97, 1.03], "limit_ms": 35, "max_voices": 4},  # Shino punch connect Y1-3 (Retro Impact 3)
"hit_heavy":      {"streams": ["res://Assets/SFX/combat/hit_heavy_01.wav"], "vol_db": -3.0, "pitch": [0.98, 1.02], "limit_ms": 60, "max_voices": 3},  # Shino uppercut Y4 (Retro Impact 4)
# Shino KICKS (X-combo connect). X1-2 = Impact2, X3 finisher = Impact1.
"kick_light":     {"streams": ["res://Assets/SFX/combat/kick_light_01.wav"], "vol_db": -6.0, "pitch": [0.97, 1.03], "limit_ms": 35, "max_voices": 4},  # X1/X2 kick connect (Retro Impact 2)
"kick_heavy":     {"streams": ["res://Assets/SFX/combat/kick_heavy_01.wav"], "vol_db": -3.0, "pitch": [0.98, 1.02], "limit_ms": 60, "max_voices": 3},  # X3 kick finisher (Retro Impact 1)
# NEW — melee whiff: plays when a Y or X swing connects with NOTHING (Shino.gd miss-detect). Retro Impact 15.
"melee_whiff":    {"streams": ["res://Assets/SFX/combat/melee_whiff_01.wav"], "vol_db": -12.0, "pitch": [0.97, 1.05], "limit_ms": 40, "max_voices": 3},
"hit_impact":     {"streams": [], "vol_db": -4.0, "pitch": [0.93, 1.05], "limit_ms": 45, "max_voices": 3},  # generic meaty impact
"enemy_hit":      {"streams": [], "vol_db": -8.0, "pitch": [0.95, 1.08], "limit_ms": 30, "max_voices": 5},  # enemy takes damage
"crane_kick":     {"streams": ["res://Assets/SFX/combat/crane_kick_01.wav"], "vol_db": -4.0, "pitch": [0.98, 1.02], "limit_ms": 90, "max_voices": 2},  # kick charge release (Retro Impact 5)
"ground_pound":   {"streams": [], "vol_db": -2.0, "pitch": [0.95, 1.05], "limit_ms": 90, "max_voices": 2},  # 7 call sites — heavy thud
"flurry_tick":    {"streams": [], "vol_db": -13.0, "pitch": [0.90, 1.12], "limit_ms": 25, "max_voices": 4}, # rapid — keep quiet + capped
"flurry_finisher":{"streams": [], "vol_db": -4.0, "limit_ms": 120, "max_voices": 1},
"hulk_smash":     {"streams": [], "vol_db": -2.0, "limit_ms": 120, "max_voices": 1},
"coco_slam":      {"streams": [], "vol_db": -3.0, "limit_ms": 100, "max_voices": 2},

# ===========================================================
# BEA KIT   (katana / naginata / dive / whirl)
# ===========================================================
# NOTE: bea_katana_%d is format-built at the call site → literal 1..4 keys.
# Bea KATANA SWING = Classic Swish 1 (all steps; the bank's ascending pitch keeps combo progression).
"bea_katana_1":   {"streams": ["res://Assets/SFX/bea/bea_katana_1.wav"], "vol_db": -7.0, "pitch": [0.97, 1.03], "limit_ms": 40, "max_voices": 3},
"bea_katana_2":   {"streams": ["res://Assets/SFX/bea/bea_katana_2.wav"], "vol_db": -7.0, "pitch": [0.99, 1.05], "limit_ms": 40, "max_voices": 3},
"bea_katana_3":   {"streams": ["res://Assets/SFX/bea/bea_katana_3.wav"], "vol_db": -7.0, "pitch": [1.01, 1.07], "limit_ms": 40, "max_voices": 3},
"bea_katana_4":   {"streams": ["res://Assets/SFX/bea/bea_katana_4.wav"], "vol_db": -6.0, "pitch": [1.03, 1.09], "limit_ms": 40, "max_voices": 3},
"bea_katana_finisher":      {"streams": ["res://Assets/SFX/bea/bea_katana_finisher.wav"], "vol_db": -4.0, "limit_ms": 120, "max_voices": 1},
# NEW — Bea katana IMPACT (plays when a katana swing hits ≥1 enemy; Bea.gd). Organic Slash.
"bea_katana_hit":  {"streams": ["res://Assets/SFX/bea/bea_katana_hit.wav"], "vol_db": -4.0, "pitch": [0.97, 1.04], "limit_ms": 40, "max_voices": 3},
# Bea NAGINATA — thrust(swing1)=Swish5, sweep(swing2)=Swish6, spin=Twirl1, overhead_slam(finisher impact)=Retro Impact4.
"bea_naginata_sweep":       {"streams": ["res://Assets/SFX/bea/bea_naginata_sweep_01.wav"], "vol_db": -5.0, "pitch": [0.97, 1.03], "limit_ms": 60, "max_voices": 2},
"bea_naginata_spin":        {"streams": ["res://Assets/SFX/bea/bea_naginata_spin.wav"], "vol_db": -6.0, "limit_ms": 90, "max_voices": 2},
"bea_naginata_thrust_1":    {"streams": ["res://Assets/SFX/bea/bea_naginata_thrust_1.wav"], "vol_db": -6.0, "limit_ms": 60, "max_voices": 2},
"bea_naginata_overhead_slam":{"streams": ["res://Assets/SFX/bea/bea_naginata_overhead_slam.wav"], "vol_db": -3.0, "limit_ms": 110, "max_voices": 1},
"bea_dash":           {"streams": [], "vol_db": -12.0, "pitch": [0.96, 1.06], "limit_ms": 90, "max_voices": 2},
"bea_charge_start":   {"streams": [], "vol_db": -12.0, "limit_ms": 150, "max_voices": 1},
"bea_charge_ready":   {"streams": [], "vol_db": -8.0,  "limit_ms": 200, "max_voices": 1},
"bea_whirl_start":    {"streams": [], "vol_db": -8.0,  "limit_ms": 150, "max_voices": 1},
"bea_whirl_end":      {"streams": [], "vol_db": -8.0,  "limit_ms": 150, "max_voices": 1},
"bea_meteor_dive_start": {"streams": [], "vol_db": -6.0, "limit_ms": 150, "max_voices": 1},
"bea_meteor_dive_end":   {"streams": [], "vol_db": -1.0, "limit_ms": 150, "max_voices": 1},
"bea_shuriken_flurry":   {"streams": [], "vol_db": -9.0, "pitch": [0.94, 1.08], "limit_ms": 35, "max_voices": 4},
"bea_ult_fire":          {"streams": [], "vol_db": -2.0, "limit_ms": 250, "max_voices": 1},

# ===========================================================
# PROJECTILES / ULTS
# ===========================================================
# Kunai (Bea) — throw = Whistle 2, impact = Gentle Swish.
"kunai_hit":        {"streams": ["res://Assets/SFX/projectiles/kunai_hit_01.wav"], "vol_db": -9.0, "pitch": [0.96, 1.05], "limit_ms": 30, "max_voices": 4},
"kunai_throw":      {"streams": ["res://Assets/SFX/projectiles/kunai_throw_01.wav"], "vol_db": -13.0, "pitch": [0.97, 1.05], "limit_ms": 40, "max_voices": 4},
# Ki blast (Shino) — fire = sci-fi 07 (NEW ki_blast_fire, wired in Shino._fire_ki_blast); impact = Retro Impact 7.
"ki_blast_fire":    {"streams": ["res://Assets/SFX/projectiles/ki_blast_fire.wav"], "vol_db": -8.0, "pitch": [0.97, 1.05], "limit_ms": 60, "max_voices": 3},
"ki_blast_hit":     {"streams": ["res://Assets/SFX/projectiles/ki_blast_hit_01.wav"], "vol_db": -7.0, "pitch": [0.96, 1.05], "limit_ms": 35, "max_voices": 4},
"kamehameha_fire":  {"streams": ["res://Assets/SFX/projectiles/kamehameha_fire.wav"], "vol_db": -2.0, "limit_ms": 300, "max_voices": 1},
"ult_fire":         {"streams": [], "vol_db": -2.0, "limit_ms": 250, "max_voices": 1},
"shino_ai_fire":    {"streams": ["res://Assets/SFX/projectiles/shino_ai_fire.wav"], "vol_db": -12.0, "pitch": [0.95, 1.06], "limit_ms": 60, "max_voices": 2},
"laser_charge":     {"streams": [], "vol_db": -9.0, "limit_ms": 200, "max_voices": 2},
"laser_zap":        {"streams": [], "vol_db": -6.0, "limit_ms": 100, "max_voices": 2},
"duo_ult_activate": {"streams": [], "vol_db": 0.0,  "limit_ms": 400, "max_voices": 1},
"duo_ult_charge":   {"streams": [], "vol_db": -4.0, "limit_ms": 300, "max_voices": 1},
"duo_ult_beam":     {"streams": [], "vol_db": -2.0, "limit_ms": 300, "max_voices": 1},
"duo_ult_slice":    {"streams": [], "vol_db": -3.0, "limit_ms": 120, "max_voices": 2},
"duo_ult_meteor":   {"streams": [], "vol_db": -2.0, "limit_ms": 150, "max_voices": 2},

# ===========================================================
# ENEMIES / BOSSES
# ===========================================================
"enemy_die":            {"streams": [], "vol_db": -8.0, "pitch": [0.92, 1.10], "limit_ms": 40, "max_voices": 5},
"enemy_projectile_hit": {"streams": [], "vol_db": -8.0, "pitch": [0.95, 1.06], "limit_ms": 40, "max_voices": 4},
"slime_windup":         {"streams": [], "vol_db": -11.0, "limit_ms": 120, "max_voices": 2},
"slime_leap":           {"streams": [], "vol_db": -9.0,  "limit_ms": 120, "max_voices": 2},
"scout_fuse":           {"streams": [], "vol_db": -11.0, "limit_ms": 200, "max_voices": 2},
"scout_fuse_fizz":      {"streams": [], "vol_db": -12.0, "limit_ms": 200, "max_voices": 2},
"scout_boom":           {"streams": [], "vol_db": -3.0,  "pitch": [0.94, 1.06], "limit_ms": 60, "max_voices": 3},
"charger_aim":          {"streams": [], "vol_db": -10.0, "limit_ms": 150, "max_voices": 2},
"charger_go":           {"streams": [], "vol_db": -6.0,  "limit_ms": 150, "max_voices": 2},
"boss_slam":            {"streams": [], "vol_db": -1.0,  "limit_ms": 150, "max_voices": 2},
"boss_fly_slam":        {"streams": [], "vol_db": -1.0,  "limit_ms": 150, "max_voices": 2},
"boss_fireball":        {"streams": [], "vol_db": -5.0,  "pitch": [0.96, 1.05], "limit_ms": 90, "max_voices": 3},
"boss_death":           {"streams": [], "vol_db":  0.0,  "limit_ms": 500, "max_voices": 1},

# ===========================================================
# SURVIVAL — hurt / downed / revive / shields
# ===========================================================
# player_hurt / player_downed are HeroBase defaults (:503, :508);
# bea_hurt / bea_down are Bea's overrides (Bea.gd:490, :494).
"player_hurt":    {"streams": [], "vol_db": -5.0, "pitch": [0.96, 1.04], "limit_ms": 250, "max_voices": 1},
"player_downed":  {"streams": [], "vol_db": -3.0, "limit_ms": 400, "max_voices": 1},
"player_death":   {"streams": [], "vol_db":  0.0, "limit_ms": 600, "max_voices": 1},
"bea_hurt":       {"streams": [], "vol_db": -5.0, "pitch": [0.98, 1.06], "limit_ms": 250, "max_voices": 1},
"bea_down":       {"streams": [], "vol_db": -3.0, "limit_ms": 400, "max_voices": 1},
"partner_revive": {"streams": [], "vol_db": -4.0, "limit_ms": 300, "max_voices": 1},
"dd_revive":      {"streams": [], "vol_db": -2.0, "limit_ms": 400, "max_voices": 1},
"revive_channel_start":    {"streams": [], "vol_db": -10.0, "limit_ms": 200, "max_voices": 1},
"revive_channel_complete": {"streams": [], "vol_db": -5.0,  "limit_ms": 200, "max_voices": 1},
"overshield_gain":  {"streams": [], "vol_db": -8.0, "limit_ms": 120, "max_voices": 2},
"overshield_break": {"streams": [], "vol_db": -5.0, "limit_ms": 120, "max_voices": 2},
"iron_will_proc":   {"streams": [], "vol_db": -4.0, "limit_ms": 300, "max_voices": 1},

# ===========================================================
# BOONS / PROCS
# ===========================================================
"boon_offer":         {"streams": [], "vol_db": -7.0, "limit_ms": 250, "max_voices": 1},
"boon_pickup":        {"streams": [], "vol_db": -5.0, "limit_ms": 150, "max_voices": 2},
"boon_pickup_spawn":  {"streams": [], "vol_db": -11.0, "limit_ms": 100, "max_voices": 3},
"apple_pie_eat":      {"streams": [], "vol_db": -7.0, "limit_ms": 200, "max_voices": 2},
"vinewrap_proc":      {"streams": [], "vol_db": -11.0, "pitch": [0.95, 1.08], "limit_ms": 60, "max_voices": 3},
"bash_proc":          {"streams": [], "vol_db": -8.0,  "pitch": [0.95, 1.06], "limit_ms": 60, "max_voices": 3},
"shell_breaker_crack":{"streams": [], "vol_db": -6.0,  "limit_ms": 90,  "max_voices": 2},
"thaw_burst":         {"streams": [], "vol_db": -8.0,  "limit_ms": 90,  "max_voices": 2},
"steam_burst":        {"streams": [], "vol_db": -9.0,  "limit_ms": 90,  "max_voices": 2},

# ===========================================================
# RESERVED — declared for Phase 3/4 wiring, no assets yet
# ===========================================================
"pause_open":   {"streams": [], "vol_db": -10.0, "limit_ms": 120, "max_voices": 1},
"pause_close":  {"streams": [], "vol_db": -10.0, "limit_ms": 120, "max_voices": 1},
"gate_open":    {"streams": [], "vol_db": -8.0,  "limit_ms": 200, "max_voices": 1},
"boss_intro":   {"streams": [], "vol_db": -1.0,  "limit_ms": 800, "max_voices": 1},
"run_win":      {"streams": [], "vol_db": -2.0,  "limit_ms": 800, "max_voices": 1},
"run_lose":     {"streams": [], "vol_db": -2.0,  "limit_ms": 800, "max_voices": 1},
"shop_buy":     {"streams": [], "vol_db": -8.0,  "limit_ms": 150, "max_voices": 2},
"level_up":     {"streams": [], "vol_db": -5.0,  "limit_ms": 300, "max_voices": 1},

}


# ---------------------------------------------------------------------------
# Helpers (static — no instance needed)
# ---------------------------------------------------------------------------
static func has_event(event_name: String) -> bool:
	return EVENTS.has(event_name)


## Returns the definition dict, or an empty dict for unknown events.
static func get_event(event_name: String) -> Dictionary:
	return EVENTS.get(event_name, {})


## True when the event exists but has no audio wired yet — the normal state
## for everything outside the UI set until Phase 2b lands.
static func is_silent(event_name: String) -> bool:
	var def: Dictionary = EVENTS.get(event_name, {})
	if def.is_empty():
		return true
	var streams: Array = def.get("streams", [])
	return streams.is_empty()


## Count of events that still need assets — handy for a quick progress check.
static func unwired_count() -> int:
	var n: int = 0
	for k in EVENTS.keys():
		if is_silent(k):
			n += 1
	return n
