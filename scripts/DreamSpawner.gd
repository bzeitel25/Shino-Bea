extends Node2D

# ============================================================
# DreamSpawner.gd — Run 43 (2026-06-10) — Dream World wave spawner
# Run 56 (2026-06-13) — rolling reinforcements + rise-from-ground
# ============================================================
# Drop-in replacement for EnemySpawner inside DreamRoom.tscn (node
# MUST be named "EnemySpawner" so World.gd's $EnemySpawner lookup
# and wave_cleared connection keep working).
#
# Reads RunState.current_biome / RunState.biome_room and spawns:
#   rooms 1-3, 5-7 → a mixed wave from the biome roster
#   room 4         → MINI-BOSS (+DB.MINIBOSS_ESCORTS escorts)  (DB.MINIBOSS_ROOM)
#   room 8         → BIOME BOSS (+DB.BOSS_ADDS adds)           (DB.ROOMS_PER_BIOME)
#   (Run 176: was +1 / +3.)
# Cake climb (current_biome == "cake", rooms 1-5) → mixed wave from
# all rosters; wave size and tier scaling crank upward.
#
# ── Run 56 rolling reinforcements ──────────────────────────
# The FIRST wave is pre-placed (already "polluting" the arena, no
# emergence). After that the room keeps a REINFORCEMENT BUDGET:
#   * each time a mob dies, 1-2 fresh mobs burrow up to replace it
#   * a slow random trickle also burrows up over time
#   * concurrent count is capped so the arena never overcrowds
# Reinforcements rise FROM THE GROUND (paused ~0.5s, fade + lift,
# dirt burst) and spawn both AHEAD of the heroes (toward the exit)
# and BEHIND them (entry side) so the players get surrounded.
# The room only truly clears — and the boon/door gate opens — once
# the budget is spent AND the field is empty.
# Boss & mini-boss rooms keep their tuned fights (no extra budget).
# ============================================================

signal wave_cleared

const DB = preload("res://scripts/DreamBiomes.gd")
# Run 173 — boss / mini-boss AI host (move pool, phases, positioning).
const BOSS_SCENE: String = "res://scenes/BossBrainEnemy.tscn"
const ESG = preload("res://scripts/EnemySpriteGen.gd")

const POLL_INTERVAL: float = 0.2
var _poll_timer: float = 0.0
var _wave_active: bool = false

# ── Reinforcement tuning ───────────────────────────────────
# Extra "waves" worth of mobs spawned over the life of the room,
# expressed as a multiplier on the room's base wave size.
const REINFORCE_WAVES_MIN: float = 1.0
const REINFORCE_WAVES_MAX: float = 2.0
# How many mobs burrow up per kill (base 1, chance of a 2nd).
const DOUBLE_SPAWN_CHANCE: float = 0.35
# Random ambient trickle: one mob burrows up every N seconds.
const TRICKLE_MIN: float = 3.5
const TRICKLE_MAX: float = 7.0
# Concurrent cap = initial wave + this, so density rises but never floods.
const EXTRA_CONCURRENT: int = 3
const CONCURRENT_FLOOR: int = 6
const CONCURRENT_CEIL: int = 13
# Arrival animation timing.
const EMERGE_TIME: float = 0.5     # burrow: rise up from below
const EMERGE_RISE: float = 28.0
const DROP_TIME: float = 0.45      # sky: fall in from above
const DROP_HEIGHT: float = 240.0
# Chance a reinforcement drops from the sky instead of burrowing up.
# (Later: drive this per-enemy off cfg, e.g. flyers always drop.)
const SKY_DROP_CHANCE: float = 0.5

var _biome_id: String = ""
var _room: int = 1
var _tier: int = 0
var _is_special: bool = false          # boss / mini-boss room — no reinforcements
var _reinforce_budget: int = 0
var _max_concurrent: int = 8
var _trickle_timer: float = 0.0
var _baseline_set: bool = false
var _alive_ids: Dictionary = {}        # instance_id -> true, enemies we've seen


# Run 173 — the Boss Test Arena hosts a DreamSpawner purely to reuse
# apply_config()/placement, and must start EMPTY. Live rooms leave this true.
@export var autospawn: bool = true


func _ready() -> void:
	if autospawn:
		call_deferred("_spawn_wave")


func _process(delta: float) -> void:
	if not _wave_active:
		return
	_poll_timer -= delta
	if _poll_timer <= 0.0:
		_poll_timer = POLL_INTERVAL
		_tick_reinforcements(POLL_INTERVAL)
		_check_wave_cleared()


# ---------------------------------------------------------------------------
# Initial wave (pre-placed — these are "already there", no emergence)
# ---------------------------------------------------------------------------

func _spawn_wave() -> void:
	_biome_id = RunState.current_biome
	_room = RunState.biome_room
	var biome: Dictionary = DB.get_biome(_biome_id)
	if biome.is_empty():
		push_warning("[DreamSpawner] Unknown biome '%s' — nothing to spawn." % _biome_id)
		return

	# Tier scaling: biomes cleansed so far (cake climb is always max tier).
	_tier = 5 if _biome_id == "cake" else RunState.biomes_cleared_count()

	var configs: Array = []
	if _biome_id != "cake" and _room >= DB.ROOMS_PER_BIOME:
		# BIOME BOSS + DB.BOSS_ADDS adds (Run 176: was 3). The opening adds join
		# the "boss_add" group so the boss's summon caps count them too - the
		# room fills up, it never floods.
		_is_special = true
		var boss_cfg: Dictionary = (biome["boss"] as Dictionary).duplicate(true)
		boss_cfg["is_boss"] = true
		configs.append(boss_cfg)
		var adds: Array = boss_cfg.get("adds", [])
		for _i in range(DB.BOSS_ADDS):
			if not adds.is_empty():
				var add_cfg: Dictionary = (adds[randi() % adds.size()] as Dictionary).duplicate()
				add_cfg["_boss_add"] = true
				configs.append(add_cfg)
	elif _biome_id != "cake" and _room == DB.MINIBOSS_ROOM:
		# MINI-BOSS + DB.MINIBOSS_ESCORTS escorts from the roster (Run 176: was 1).
		_is_special = true
		var mb_cfg: Dictionary = (biome["miniboss"] as Dictionary).duplicate(true)
		mb_cfg["is_miniboss"] = true
		configs.append(mb_cfg)
		for _i in range(DB.MINIBOSS_ESCORTS):
			configs.append(DB.random_enemy(_biome_id))
	else:
		var n: int = DB.wave_size(_room)
		if _biome_id == "cake":
			n += 2   # finale pressure
		for _i in range(n):
			configs.append(DB.random_enemy(_biome_id))

	# Spawn area respects the narrowed room footprint. Run 51: when the room
	# has an organic layout, spawn on walkable cells away from the entry.
	var half: Vector2 = DB.room_half_extents(_room, _biome_id)
	var max_x: float = half.x - 40.0
	var max_y: float = half.y - 40.0
	var total: int = configs.size()
	var lay = get_parent().get("dream_layout")

	for i in range(total):
		var cfg: Dictionary = configs[i]
		var e: Node = _make_enemy(cfg)
		if e == null:
			continue
		if cfg.get("_boss_add", false):
			e.add_to_group("boss_add")
		# Bosses spawn in the central chamber so the entrance reads as an
		# encounter; everyone else scatters across the walkable layout.
		var pos: Vector2 = Vector2(0, -60)
		if cfg.get("is_boss", false) or cfg.get("is_miniboss", false):
			if lay != null:
				pos = lay.chamber_world() + Vector2(0, -40)
		elif lay != null:
			pos = lay.random_walkable(180.0)
		else:
			var base_angle: float = (TAU / float(total)) * float(i) + randf_range(-0.4, 0.4)
			var dist: float = randf_range(120.0, min(max_x, max_y) - 30.0)
			pos = Vector2(cos(base_angle) * dist, sin(base_angle) * dist)
			pos.x = clamp(pos.x, -max_x, max_x)
			pos.y = clamp(pos.y, -max_y, max_y)
		get_parent().add_child(e)
		if e is Node2D:
			(e as Node2D).global_position = pos

	# Reinforcement budget — normal & cake rooms only (boss/mini stay tuned).
	if not _is_special:
		var extra: float = randf_range(REINFORCE_WAVES_MIN, REINFORCE_WAVES_MAX)
		_reinforce_budget = int(round(float(DB.wave_size(_room)) * extra))
		_max_concurrent = clampi(total + EXTRA_CONCURRENT, CONCURRENT_FLOOR, CONCURRENT_CEIL)
		_trickle_timer = randf_range(TRICKLE_MIN, TRICKLE_MAX)

	_wave_active = true
	_poll_timer = POLL_INTERVAL
	Log.dbg("[DreamSpawner] %s room %d — %d enemies (tier %d), reinforcement budget %d, cap %d." % [
		_biome_id, _room, total, _tier, _reinforce_budget, _max_concurrent])


# ---------------------------------------------------------------------------
# Rolling reinforcements (Run 56)
# ---------------------------------------------------------------------------

func _tick_reinforcements(delta: float) -> void:
	if _is_special:
		return

	var living: Array = get_tree().get_nodes_in_group("enemy")
	var current_ids: Dictionary = {}
	for e in living:
		current_ids[e.get_instance_id()] = true

	# First tick just establishes the baseline (no death miscount on entry).
	if not _baseline_set:
		_alive_ids = current_ids
		_baseline_set = true
		return

	# Count how many tracked enemies vanished since last tick = kills.
	var deaths: int = 0
	for id in _alive_ids.keys():
		if not current_ids.has(id):
			deaths += 1
	_alive_ids = current_ids

	if _reinforce_budget <= 0:
		return

	var living_count: int = living.size()

	# Kill-driven reinforcements: each fallen mob calls up 1 (sometimes 2).
	for _d in range(deaths):
		if _reinforce_budget <= 0:
			break
		var n: int = 1
		if randf() < DOUBLE_SPAWN_CHANCE:
			n = 2
		for _k in range(n):
			if _reinforce_budget <= 0 or living_count >= _max_concurrent:
				break
			_spawn_reinforcement()
			living_count += 1

	# Ambient trickle: a stray mob keeps the pressure on even mid-fight.
	_trickle_timer -= delta
	if _trickle_timer <= 0.0:
		_trickle_timer = randf_range(TRICKLE_MIN, TRICKLE_MAX)
		if _reinforce_budget > 0 and living_count < _max_concurrent:
			_spawn_reinforcement()
			living_count += 1


func _spawn_reinforcement() -> void:
	var cfg: Dictionary = DB.random_enemy(_biome_id)
	if cfg.is_empty():
		return
	var e: Node = _make_enemy(cfg)
	if e == null:
		return
	# Roughly half rise up behind the heroes (blocking retreat), half ahead.
	var behind: bool = randf() < 0.5
	var pos: Vector2 = _pick_spawn_pos(behind)
	get_parent().add_child(e)
	if e is Node2D:
		(e as Node2D).global_position = pos
	# Track it immediately so the next tick doesn't read it as a fresh kill.
	_alive_ids[e.get_instance_id()] = true
	_reinforce_budget -= 1
	_arrive(e, cfg)


# Which scene hosts this config. Run 173 — bosses and mini-bosses host on
# BossBrainEnemy.tscn instead of the basic-grunt DummyEnemy.tscn. BossBrain
# EXTENDS DummyEnemy, so a boss with no BossMoves entry resolves to
# BossMoves.legacy_pool() and behaves exactly as it did before. Only the melee
# archetype is re-hosted: BossBrain is a melee host, so re-pointing the ranged
# Mustard Marauder at it would strip its gun (it gets its own script when the
# swamp is redesigned).
#
# STATIC on purpose: BossTestArena.gd spawns through this same call, so the
# sandbox can never host a boss differently from a live run.
static func scene_for_config(cfg: Dictionary) -> String:
	var arch: String = String(cfg.get("arch", "melee"))
	var scene_path: String = DB.ARCH_SCENES.get(arch, DB.ARCH_SCENES["melee"])
	# Run 176 — "boss_brain": true re-hosts a non-melee big on BossBrain too
	# (Mustard Marauder: its gun is now the moveset's volleys / mortars).
	if (arch == "melee" or bool(cfg.get("boss_brain", false))) \
	and (cfg.get("is_boss", false) or cfg.get("is_miniboss", false)) \
	and ResourceLoader.exists(BOSS_SCENE):
		scene_path = BOSS_SCENE
	return scene_path


# Instantiate an archetype scene and apply its DreamBiomes config preset.
func _make_enemy(cfg: Dictionary) -> Node:
	var scene_path: String = scene_for_config(cfg)
	if not ResourceLoader.exists(scene_path):
		push_warning("[DreamSpawner] Missing archetype scene: %s" % scene_path)
		return null
	var e: Node = (load(scene_path) as PackedScene).instantiate()
	apply_config(e, cfg, _tier)
	return e


# ---------------------------------------------------------------------------
# Spawn placement — ahead of / behind the hero group
# ---------------------------------------------------------------------------

# Pick a walkable spawn point along the biome travel axis: `behind` = on the
# side the heroes came from (entry-ward), else ahead toward the exit/star tip.
func _pick_spawn_pos(behind: bool) -> Vector2:
	var lay = get_parent().get("dream_layout")
	var centroid: Vector2 = _hero_centroid()
	var ed: Vector2 = _exit_dir()
	var axis: Vector2 = -ed if behind else ed
	var half: Vector2 = DB.room_half_extents(_room, _biome_id)
	var max_x: float = half.x - 40.0
	var max_y: float = half.y - 40.0

	var anchor: Vector2 = centroid + axis * randf_range(150.0, 260.0)
	for _i in range(40):
		var ang: float = randf() * TAU
		var r: float = randf_range(20.0, 110.0)
		var p: Vector2 = anchor + Vector2(cos(ang), sin(ang)) * r
		p.x = clamp(p.x, -max_x, max_x)
		p.y = clamp(p.y, -max_y, max_y)
		if lay != null and not lay.is_walkable_world(p):
			continue
		if _too_close_to_hero(p, 110.0):
			continue
		return p

	# Fallbacks: entry cove for "behind", far walkable cell for "ahead".
	if behind and lay != null:
		return lay.entry_world()
	if lay != null:
		return lay.random_walkable(200.0)
	return Vector2(clamp(anchor.x, -max_x, max_x), clamp(anchor.y, -max_y, max_y))


func _hero_centroid() -> Vector2:
	var sum: Vector2 = Vector2.ZERO
	var n: int = 0
	for p in get_tree().get_nodes_in_group("player"):
		if p is Node2D and p.visible:
			sum += (p as Node2D).global_position
			n += 1
	for b in get_tree().get_nodes_in_group("bea"):
		if b.is_in_group("player"):
			continue
		if b is Node2D and b.visible:
			sum += (b as Node2D).global_position
			n += 1
	if n == 0:
		return Vector2.ZERO
	return sum / float(n)


func _too_close_to_hero(p: Vector2, min_dist: float) -> bool:
	for h in get_tree().get_nodes_in_group("player"):
		if h is Node2D and p.distance_to((h as Node2D).global_position) < min_dist:
			return true
	for b in get_tree().get_nodes_in_group("bea"):
		if b is Node2D and p.distance_to((b as Node2D).global_position) < min_dist:
			return true
	return false


# Travel axis for the current biome (heroes enter opposite, exit toward this).
func _exit_dir() -> Vector2:
	var biome: Dictionary = DB.get_biome(_biome_id)
	var ed: Vector2 = biome.get("exit_dir", Vector2(0, -1))
	if ed == Vector2.ZERO:
		ed = Vector2(0, -1)
	return ed.normalized()


# ---------------------------------------------------------------------------
# Arrival animations — burrow up from the ground OR drop in from the sky
# ---------------------------------------------------------------------------

# Pick how this reinforcement enters. Random for now; the cfg hook is here so
# later we can force specific enemy types (e.g. flyers always drop).
func _arrive(e: Node, cfg: Dictionary) -> void:
	if not is_instance_valid(e):
		return
	e.set_physics_process(false)   # held until the entrance finishes
	var mode: String = String(cfg.get("arrival", ""))
	if mode == "":
		mode = "drop" if randf() < SKY_DROP_CHANCE else "burrow"
	if mode == "drop":
		_descend(e)
	else:
		_emerge(e)


# Burrow: lift the body up from below with a fade, kick up dirt.
func _emerge(e: Node) -> void:
	var body: Node = e.get_node_or_null("Body")
	if body and body is Node2D:
		var b: Node2D = body as Node2D
		var base_y: float = b.position.y
		b.position.y = base_y + EMERGE_RISE
		(body as CanvasItem).modulate.a = 0.3
		var tw: Tween = e.create_tween()
		tw.set_parallel(true)
		tw.tween_property(b, "position:y", base_y, EMERGE_TIME) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(body, "modulate:a", 1.0, EMERGE_TIME * 0.8)
		tw.chain().tween_callback(_activate.bind(e))
	else:
		var t: SceneTreeTimer = get_tree().create_timer(EMERGE_TIME)
		t.timeout.connect(_activate.bind(e))

	# Dirt burst at the mob's feet.
	if e is Node2D:
		var dirt: Color = (DB.get_biome(_biome_id).get("floor", Color(0.45, 0.32, 0.18)) as Color).darkened(0.3)
		FX.spawn_burst_particles((e as Node2D).global_position + Vector2(0, 8), dirt, 14)


# Sky drop: body starts high above its landing spot and falls in, accelerating,
# then kicks up an impact puff + tiny shake on touchdown.
func _descend(e: Node) -> void:
	var body: Node = e.get_node_or_null("Body")
	if body and body is Node2D:
		var b: Node2D = body as Node2D
		var base_y: float = b.position.y
		b.position.y = base_y - DROP_HEIGHT
		var tw: Tween = e.create_tween()
		tw.tween_property(b, "position:y", base_y, DROP_TIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_callback(_land.bind(e))
	else:
		var t: SceneTreeTimer = get_tree().create_timer(DROP_TIME)
		t.timeout.connect(_land.bind(e))


# Touchdown for a sky-dropped mob: dust puff, small shake, wake the AI.
func _land(e: Node) -> void:
	if e is Node2D:
		var dust: Color = (DB.get_biome(_biome_id).get("floor", Color(0.7, 0.7, 0.7)) as Color).lightened(0.15)
		FX.spawn_burst_particles((e as Node2D).global_position + Vector2(0, 8), dust, 16)
	if FX.has_method("screen_shake"):
		FX.screen_shake(3.0, 0.12)
	_activate(e)


func _activate(e: Node) -> void:
	if is_instance_valid(e):
		e.set_physics_process(true)


# ---------------------------------------------------------------------------
# Config application (unchanged) — STATIC so DreamHub/ShadowSenseiArena reuse.
# ---------------------------------------------------------------------------

# Apply a DreamBiomes config preset onto an instantiated archetype scene.
# Must run BEFORE add_child so the enemy's _ready() picks up max_hp.
static func apply_config(e: Node, cfg: Dictionary, tier: int) -> void:
	# Run 46 — group tags so target-aware boons (Boss Hunter, Bash the Big
	# Ones) recognize dream bosses/mini-bosses. Groups persist into the tree.
	if cfg.get("is_boss", false):
		e.add_to_group("boss")
	elif cfg.get("is_miniboss", false):
		e.add_to_group("miniboss")
	var hp: int = int(round(float(cfg.get("hp", 60)) * DB.tier_hp_mult(tier)))
	var dmg: int = int(round(float(cfg.get("dmg", 8)) * DB.tier_dmg_mult(tier)))
	e.set("max_hp", hp)
	e.set("move_speed", float(cfg.get("speed", 80.0)))
	# Melee/scout use attack_damage; ranged uses shot_damage. set() on a
	# nonexistent property is a silent no-op, so apply both.
	e.set("attack_damage", dmg)
	e.set("shot_damage", dmg)
	# Run 57 — "boom" scouts: light a fuse and self-destruct on reach. The
	# blast scales off the same dmg figure. set() is a no-op on archetypes that
	# don't expose these, so it's safe to apply unconditionally.
	if String(cfg.get("behavior", "")) == "boom":
		e.set("explode_on_reach", true)
		e.set("explode_damage", maxi(dmg + 6, dmg))   # blast hits a bit harder than a swipe
	# Run 120 — melee bite that inflicts Burn (e.g. Churro Chomper). set() is a
	# silent no-op on archetypes that don't expose these, so apply unconditionally.
	var burn: Dictionary = cfg.get("on_hit_burn", {})
	if not burn.is_empty():
		e.set("on_hit_burn_stacks", int(burn.get("stacks", 1)))
		e.set("on_hit_burn_duration", float(burn.get("duration", 3.0)))
	# Run 122 — generic on-hit status hooks (poison / slow / stun). Mirror the
	# burn plumbing above: set() is a silent no-op on hosts that don't expose the
	# field, so applying unconditionally is safe. StatusComponent.inflict_hero_status
	# (called from each host's damage path) reads these off the enemy at hit time.
	var poison: Dictionary = cfg.get("on_hit_poison", {})
	if not poison.is_empty():
		e.set("on_hit_poison_stacks", int(poison.get("stacks", 1)))
		e.set("on_hit_poison_duration", float(poison.get("duration", 4.0)))
	var slow: Dictionary = cfg.get("on_hit_slow", {})
	if not slow.is_empty():
		e.set("on_hit_slow_stacks", int(slow.get("stacks", 1)))
	var stun: Dictionary = cfg.get("on_hit_stun", {})
	if not stun.is_empty():
		e.set("on_hit_stun_duration", float(stun.get("duration", 0.6)))
	# Run 140 — custom projectile sprite for ranged enemies (e.g. chocofrog dart).
	var proj_sprite: String = String(cfg.get("projectile_sprite", ""))
	if proj_sprite != "":
		e.set("projectile_sprite_path", proj_sprite)
	# Run 141 — death explosion (e.g. Expired-Egg Bloater, Popcorn Popper).
	# Charger hosts expose export vars; set() is a silent no-op on hosts that
	# don't have them. PopcornPopper handles its own boom internally.
	var dex: Dictionary = cfg.get("death_explosion", {})
	if not dex.is_empty():
		e.set("death_explosion", true)
		if dex.has("radius"):
			e.set("death_explosion_radius", float(dex["radius"]))
		if dex.has("delay"):
			e.set("death_explosion_delay", float(dex["delay"]))
		if dex.has("dmg_mult"):
			e.set("death_explosion_dmg_mult", float(dex["dmg_mult"]))
		if dex.has("status"):
			e.set("death_explosion_status", String(dex["status"]))
		if dex.has("status_duration"):
			e.set("death_explosion_status_duration", float(dex["status_duration"]))
		if dex.has("status_stacks"):
			e.set("death_explosion_status_stacks", int(dex["status_stacks"]))
	# Run 122 — secondary attack flag (e.g. Nacho-Slag Golem's smash shockwave).
	if String(cfg.get("secondary", "")) == "smash":
		e.set("secondary_smash", true)
	# Run 173 — boss move pool. set() is a silent no-op on non-BossBrain hosts,
	# so this is safe to apply to every enemy. An empty moveset_id falls through
	# to BossMoves.legacy_pool() (pre-Run-173 chase/bite/smash).
	e.set("moveset_id", String(cfg.get("moveset", "")))
	e.set("boss_display_name", String(cfg.get("name", "Boss")))
	e.set("is_big_boss", bool(cfg.get("is_boss", false)))
	e.set("spawn_tier", tier)
	if cfg.has("adds"):
		e.set("add_configs", cfg.get("adds", []))
	# Run 122 — melee bite knockback (e.g. Marshmallow Mauler).
	if bool(cfg.get("on_hit_knockback", false)):
		e.set("on_hit_knockback", true)
	var s: float = float(cfg.get("scale", 1.0))
	if e is Node2D and s != 1.0:
		(e as Node2D).scale = Vector2(s, s)
	# Run 44: generate a unique pixel-art junk-food monster sprite (seeded
	# by name). Falls back to the tinted stick figure if generation fails.
	var tint: Color = cfg.get("tint", Color(1, 1, 1))
	var body: Node = e.get_node_or_null("Body")
	if body:
		# Run 119 — bespoke hand-authored sprite rigs (e.g. the Onion-Ring
		# Rollick beach charger). Swap the $Body script to the rig BEFORE the
		# node enters the tree so only the rig's _ready() runs, then let the
		# host drive it via the same set_anim_state()/set_motion_speed() API.
		# Falls through to procedural generation for every other enemy.
		var rig: String = String(cfg.get("sprite_rig", ""))
		if rig == "onion":
			body.set_script(load("res://scripts/OnionRingRig.gd"))
			# Also size/anchor the flash overlay so aim/hit tint covers the wheel.
			var ov: ColorRect = e.get_node_or_null("Sprite") as ColorRect
			if ov:
				ov.offset_left = -34.0
				ov.offset_top = -60.0
				ov.offset_right = 34.0
				ov.offset_bottom = 6.0
		elif rig == "jawbreaker":
			# Run 150 — Jawbreaker Juggernaut rolls like a ball (same pattern as OnionRingRig).
			body.set_script(load("res://scripts/JawbreakerRig.gd"))
			var jov: ColorRect = e.get_node_or_null("Sprite") as ColorRect
			if jov:
				jov.offset_left = -36.0
				jov.offset_top = -62.0
				jov.offset_right = 36.0
				jov.offset_bottom = 8.0
		elif rig != "":
			# Run 120 — generic strip-based MonsterRig, config-driven. The roster's
			# "sprite_rig" value names the CONFIGS entry (e.g. "churro"). Set the
			# script AND the config id BEFORE the node enters the tree so the rig's
			# _ready()/_build() picks the right monster. Adding the next of the 25
			# planned monsters is a new CONFIGS entry + a roster "sprite_rig" tag —
			# no spawner change needed here.
			body.set_script(load("res://scripts/MonsterRig.gd"))
			body.set("_cfg_id", rig)
			# Size/anchor the flash overlay so aim/hit tint covers the body.
			var mov: ColorRect = e.get_node_or_null("Sprite") as ColorRect
			if mov:
				mov.offset_left = -34.0
				mov.offset_top = -52.0
				mov.offset_right = 34.0
				mov.offset_bottom = 8.0
		elif not ESG.apply_to(e, body, cfg) and body is CanvasItem:
			(body as CanvasItem).modulate = tint
	# Display name above the enemy.
	var nm: Label = e.get_node_or_null("NameLabel") as Label
	if nm:
		nm.text = String(cfg.get("name", "Junk Shadow"))
		if cfg.get("is_boss", false):
			nm.text = "👑 " + nm.text
			nm.add_theme_color_override("font_color", Color(1.0, 0.45, 0.25))
		elif cfg.get("is_miniboss", false):
			nm.text = "★ " + nm.text
			nm.add_theme_color_override("font_color", Color(1.0, 0.75, 0.25))


# ---------------------------------------------------------------------------
# Completion — only after the reinforcement budget is spent AND field is empty.
# ---------------------------------------------------------------------------

func _check_wave_cleared() -> void:
	if _reinforce_budget > 0:
		return
	var living: Array = get_tree().get_nodes_in_group("enemy")
	if living.is_empty():
		_wave_active = false
		# Coin drip on every dream wave clear.
		var drip: int = randi_range(RunState.COIN_WAVE_DRIP_MIN, RunState.COIN_WAVE_DRIP_MAX)
		RunState.add_coins(drip)
		Log.dbg("[DreamSpawner] Wave cleared (+%d coins, %d total)." % [drip, RunState.run_coins])
		emit_signal("wave_cleared")
