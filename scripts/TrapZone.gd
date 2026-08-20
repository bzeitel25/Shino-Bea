extends Area2D

# ============================================================
# TrapZone.gd — Run 51 (2026-06-11) — biome floor hazards
# ============================================================
# One node per trap, spawned by DreamRoom from DreamLayout.trap_spots.
# Affects heroes only (collision_mask 2; enemies ignored).
#
# Types:
#   "root"   — Sand Pit / Entangling Vines: roots the hero 0.9s on
#              entry (2.5s per-hero re-trigger cooldown). Dash escapes.
#   "slow"   — Brine Pool / Deep Snow / Frosting Glaze: ×0.45 move
#              speed while standing in it.
#   "poison" — Poison Pool: 3s DoT (3 ticks) + slow while it lasts.
#   "burn"   — Magma Fissure: 2 quick ticks on entry.
#
# Speed handling is multiplicative on body.move_speed so it composes
# with everything else; root saves/restores the exact value.
# ============================================================

const TEXEL: int = 2

var trap_type: String = "slow"
var trap_name: String = "Trap"
var visual: String = "brine"
var accent: Color = Color(0.8, 0.8, 0.4)
var floor_col: Color = Color(0.4, 0.4, 0.3)
var radius: float = 34.0
# When false, the zone draws NO sprite — used by biomes (e.g. swamp) that bake
# the trap's pool straight into the ground, so the only visual is the baked
# pool and the collision is sized to fill it (no green placeholder disc on top).
var draw_sprite: bool = true
# pool_wob = [a1, a2, a3, p1, p2, p3]: the SHARED outline harmonics the swamp
# ground baker used to draw this pool. When set, the collision is a blob polygon
# tracing radius*wob(angle) — the exact pool curve — instead of a plain circle.
var pool_wob: Array = []
# Lava-river mode (Run 100, Bruno): when rect_runs is set the zone is a row of rectangle
# hazards over the river cells. The hero can WALK across, taking periodic burn ticks, but
# DASHING over does NO damage. No sprite — the animated bubbling-lava tiles are the visual.
var rect_runs: Array = []
var is_lava_river: bool = false
# Run 102 — caverns lava POOLS (circle/blob collision, not river runs) burn
# continuously like the rivers: a hit on contact + another every interval while
# the hero stands in the molten pool. Swamp poison POOLS apply the hero-side 3s
# purple-outline poison and refresh it while the hero remains in the pool.
var is_lava_pool: bool = false
var is_poison_pool: bool = false
const POISON_REFRESH_INTERVAL: float = 0.5
var _poison_refresh_t: float = 0.0

const SLOW_MULT: float = 0.45
const LAVA_RIVER_INTERVAL: float = 0.5      # seconds between burn ticks while standing in lava
const ROOT_TIME: float = 0.9
const RETRIGGER_CD: float = 2.5
const POISON_TICKS: int = 3
const POISON_TICK_DMG: int = 4
const POISON_SLOW: float = 0.65
const BURN_TICK_DMG: int = 5
const CHOMP_DMG: int = 9            # swamp carnivorous plant bite
const CHOMP_CD: float = 1.1         # per-hero re-bite cooldown

var _slowed: Dictionary = {}      # instance_id → applied mult (restore on exit)
var _cd_until: Dictionary = {}    # instance_id → msec when re-trigger allowed
var _spr: Sprite2D = null
var _t: float = 0.0
var _lava_t: float = 0.0          # lava-river burn-tick accumulator


func _ready() -> void:
	collision_layer = 0
	collision_mask = 2
	z_index = -33                  # above terrain (-35), below entities
	# Lava river: walkable burn strip (no blocking, no sprite). Periodic ticks via _process,
	# plus an immediate tick on stepping in; dashing across is immune.
	if not rect_runs.is_empty():
		is_lava_river = true
		_build_rect_collision()
		body_entered.connect(_on_river_enter)
		return
	# Run 61 — AI partner trap-avoidance: every TrapZone advertises itself as
	# a hazard so partner AI heuristics can steer around it (universal rule).
	add_to_group("hazard_zone")
	set_meta("hazard_status", trap_type)
	# Run 102 — pools that need continuous behavior while a hero stands in them.
	is_lava_pool = (trap_type == "burn")
	is_poison_pool = (trap_type == "poison")
	if pool_wob.size() >= 6:
		# Blob collision tracing the baked pool's exact curve (radius*wob(angle)),
		# so the trap border lines up with the pool's lobes and dents.
		_build_blob_collision()
	else:
		set_meta("hazard_radius", radius)
		var cs := CollisionShape2D.new()
		var sh := CircleShape2D.new()
		# Baked-pool zones fill more of their radius (the pool body ≈ radius); the
		# procedural-sprite zones keep the tighter 0.8 fit they were tuned with.
		sh.radius = radius * (0.9 if not draw_sprite else 0.8)
		cs.shape = sh
		add_child(cs)
	if draw_sprite:
		_spr = Sprite2D.new()
		_spr.texture = _make_visual()
		_spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_spr.scale = Vector2(TEXEL, TEXEL)
		add_child(_spr)
	body_entered.connect(_on_enter)
	body_exited.connect(_on_exit)


func _process(delta: float) -> void:
	_t += delta
	if is_lava_river:
		_lava_t += delta
		if _lava_t >= LAVA_RIVER_INTERVAL:
			_lava_t = 0.0
			for b in get_overlapping_bodies():
				_river_burn(b)
		return
	# Run 102 — caverns lava POOL: same continuous burn cadence as the rivers.
	if is_lava_pool:
		_lava_t += delta
		if _lava_t >= LAVA_RIVER_INTERVAL:
			_lava_t = 0.0
			for b in get_overlapping_bodies():
				_river_burn(b)
	# Run 102 — swamp poison POOL: keep refreshing the hero's 3s poison while
	# they stand in it (refresh never stacks; the hero ticks the damage itself).
	elif is_poison_pool:
		_poison_refresh_t += delta
		if _poison_refresh_t >= POISON_REFRESH_INTERVAL:
			_poison_refresh_t = 0.0
			for b in get_overlapping_bodies():
				_apply_trap_poison_to(b)
	if _spr:
		_spr.modulate.a = 0.92 + sin(_t * 2.2) * 0.08


# Immediate burn the instant a (non-dashing) hero steps into the lava river.
func _on_river_enter(body: Node) -> void:
	_lava_t = 0.0
	_river_burn(body)


func _river_burn(body: Node) -> void:
	if body == null or body.is_in_group("enemy"):
		return
	if _is_dash_immune(body):
		return
	# Run 102 — "lava" source → hero shows an orange outline flash + ember burst.
	if body.has_method("take_damage"):
		body.take_damage(BURN_TICK_DMG, Vector2.ZERO, "lava")


# Run 102 — apply / refresh the hero-side swamp poison (purple outline + 3s
# per-second tick). The hero owns the tick + visual; this just (re)triggers it.
func _apply_trap_poison_to(body: Node) -> void:
	if body == null or body.is_in_group("enemy"):
		return
	if body.has_method("is_downed") and body.is_downed():
		return   # downed bodies wait for revive untouched
	if body.has_method("apply_trap_poison"):
		body.apply_trap_poison()


# Dashing (or otherwise i-framed) heroes take no lava damage — the DASH carries
# them over. A DOWNED body is also immune: it waits for revive untouched.
func _is_dash_immune(body: Node) -> bool:
	if body.has_method("is_downed") and body.is_downed():
		return true
	if "is_invulnerable" in body and bool(body.is_invulnerable):
		return true
	if "dash_timer" in body and float(body.dash_timer) > 0.0:
		return true
	return false


func _build_rect_collision() -> void:
	for run in rect_runs:
		var cs := CollisionShape2D.new()
		var sh := RectangleShape2D.new()
		sh.size = run.size
		cs.shape = sh
		cs.position = run.pos
		add_child(cs)


func _on_enter(body: Node) -> void:
	if body.is_in_group("enemy"):
		return
	if not ("move_speed" in body):
		return
	var id: int = body.get_instance_id()
	match trap_type:
		"slow":
			if not _slowed.has(id):
				body.move_speed = float(body.move_speed) * SLOW_MULT
				_slowed[id] = SLOW_MULT
		"root":
			if _off_cooldown(id):
				_arm_cooldown(id, ROOT_TIME + RETRIGGER_CD)
				# Reference-count overlapping root traps. A jungle vine cluster
				# fires several roots in quick succession; the previous timestamp
				# guard could still let a later root snapshot an already-zeroed (or
				# just-restored) move_speed and strand the hero at 0 forever.
				# Counting fixes that cleanly: snapshot the clean speed ONLY on the
				# 0->1 transition, restore ONLY after the last overlapping root
				# releases. (Run 67 fix, rebuilt as a ref-count Run 69.)
				var rc: int = int(body.get_meta("trap_root_count", 0))
				if rc == 0:
					# move_speed is the clean BASE; MS buffs (Peel Out, Hot-Footed,
					# Zip Dash, Critical Mass, sensei move-speed mult) are runtime
					# multipliers applied at move time — banking this scalar makes
					# every active buff reapply automatically the moment the root
					# lifts. trap_root_safe is a durable known-good copy used as a
					# floor so a cluster can never leave the hero immobile.
					var clean: float = float(body.move_speed)
					if clean > 0.0:
						body.set_meta("trap_root_safe", clean)
					else:
						clean = float(body.get_meta("trap_root_safe", 220.0))
					body.set_meta("trap_root_base", clean)
				body.set_meta("trap_root_count", rc + 1)
				body.move_speed = 0.0
				_flash(body)
				get_tree().create_timer(ROOT_TIME).timeout.connect(func():
					if not is_instance_valid(body):
						return
					var c: int = int(body.get_meta("trap_root_count", 0)) - 1
					if c > 0:
						body.set_meta("trap_root_count", c)
						return
					# Last root released → restore the clean base (never 0).
					var base: float = float(body.get_meta("trap_root_base", 0.0))
					if base <= 0.0:
						base = float(body.get_meta("trap_root_safe", 220.0))
					body.move_speed = base
					body.remove_meta("trap_root_base")
					body.remove_meta("trap_root_count"))
		"poison":
			# Run 102 — swamp poison: hand off to the hero's 3s purple-outline
			# poison on contact. Standing in the pool refreshes it via _process;
			# re-touching also refreshes (the hero's start_poison never stacks).
			_apply_trap_poison_to(body)
		"burn":
			# Run 102 — caverns lava: medium burn on contact (orange flash + embers
			# come from the "lava" source inside take_damage). Continued ticks while
			# standing are handled by the is_lava_pool branch in _process. Dashing
			# across takes no damage (_river_burn checks dash immunity).
			_river_burn(body)
		"chomp":
			# Swamp carnivorous plant: a single BITE on contact, then a short
			# per-hero cooldown so brushing past costs HP, not a death loop.
			if _off_cooldown(id):
				_arm_cooldown(id, CHOMP_CD)
				_flash(body)
				if body.has_method("take_damage"):
					body.take_damage(CHOMP_DMG)


func _on_exit(body: Node) -> void:
	var id: int = body.get_instance_id()
	if _slowed.has(id):
		if is_instance_valid(body) and ("move_speed" in body):
			body.move_speed = float(body.move_speed) / float(_slowed[id])
		_slowed.erase(id)


# Run 155 (Bruno fix — Bea "wiggle-in-place" softlock) — restore any body still
# standing in this "slow" pool when the trap is torn down. Godot does NOT emit
# body_exited when an Area2D is freed, so a slow trap that vanishes on a room
# change would leave the hero's move_speed permanently multiplied by 0.45 — and
# it COMPOUNDS every room she ends a fight in a pool, dragging move_speed toward
# 0 until she can no longer walk (looks alive, animates, never translates). Root
# traps self-heal via their SceneTreeTimer (survives the node free); the revive
# path also hard-resets move_speed. This closes the slow-compounding leak.
func _exit_tree() -> void:
	for id in _slowed.keys():
		var body: Object = instance_from_id(id)
		if body != null and is_instance_valid(body) and ("move_speed" in body):
			body.move_speed = float(body.move_speed) / float(_slowed[id])
	_slowed.clear()


func _off_cooldown(id: int) -> bool:
	return Time.get_ticks_msec() >= int(_cd_until.get(id, 0))


func _arm_cooldown(id: int, seconds: float) -> void:
	_cd_until[id] = Time.get_ticks_msec() + int(seconds * 1000.0)


# Concave blob polygon matching the baked swamp pool. The ground baker drew the
# pool edge at  radius * wob(angle)  with these same harmonics; tracing the same
# curve makes the hazard border follow the pool's exact silhouette (every lobe
# and dent). CollisionPolygon2D decomposes the concave shape for Area2D overlap.
func _build_blob_collision() -> void:
	var a1: float = float(pool_wob[0])
	var a2: float = float(pool_wob[1])
	var a3: float = float(pool_wob[2])
	var p1: float = float(pool_wob[3])
	var p2: float = float(pool_wob[4])
	var p3: float = float(pool_wob[5])
	var n: int = 64
	var pts := PackedVector2Array()
	var max_r: float = radius
	for i in range(n):
		var ang: float = TAU * float(i) / float(n)
		var wob: float = 1.0 + a1 * sin(3.0 * ang + p1) + a2 * sin(5.0 * ang + p2) + a3 * sin(7.0 * ang + p3)
		var rr: float = radius * wob
		max_r = maxf(max_r, rr)
		pts.append(Vector2(cos(ang), sin(ang)) * rr)
	set_meta("hazard_radius", max_r)        # AI steers around the widest lobe
	var cp := CollisionPolygon2D.new()
	cp.polygon = pts
	add_child(cp)


func _flash(body: Node) -> void:
	if body is CanvasItem:
		var ci := body as CanvasItem
		var prev: Color = ci.modulate
		ci.modulate = accent.lightened(0.3)
		get_tree().create_timer(0.18).timeout.connect(func():
			if is_instance_valid(ci):
				ci.modulate = prev)


# ---------------------------------------------------------------------------
# Procedural trap visuals (36×26 texels, drawn at 2× — ~72×52 px pools)
# ---------------------------------------------------------------------------
func _make_visual() -> ImageTexture:
	var w: int = 36
	var h: int = 26
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(visual) + hash(trap_name)
	var cx: float = float(w) * 0.5
	var cy: float = float(h) * 0.5
	var rx: float = cx - 1.0
	var ry: float = cy - 1.0
	match visual:
		"sandpit":
			for y in range(h):
				for x in range(w):
					var d: float = pow((float(x) - cx) / rx, 2) + pow((float(y) - cy) / ry, 2)
					if d > 1.0:
						continue
					var col: Color = floor_col.darkened(0.12)
					if d < 0.20:
						col = floor_col.darkened(0.48)
					elif d < 0.45:
						col = floor_col.darkened(0.34)
					elif d < 0.75:
						col = floor_col.darkened(0.22)
					if int(float(x) + float(y) * 0.5) % 5 == 0 and d > 0.2:
						col = col.darkened(0.10)          # spiral-ish slip lines
					img.set_pixel(x, y, col)
		"brine", "poison", "glaze":
			var deep: Color
			var mid: Color
			var rim: Color
			match visual:
				"poison":
					deep = Color(0.18, 0.36, 0.10)
					mid = Color(0.30, 0.52, 0.14)
					rim = Color(0.55, 0.80, 0.25)
				"glaze":
					deep = Color(0.85, 0.45, 0.65)
					mid = Color(0.95, 0.60, 0.78)
					rim = Color(1.00, 0.85, 0.92)
				_:
					deep = Color(0.10, 0.30, 0.45)
					mid = Color(0.16, 0.42, 0.58)
					rim = Color(0.75, 0.90, 0.95)
			for y in range(h):
				for x in range(w):
					var d2: float = pow((float(x) - cx) / rx, 2) + pow((float(y) - cy) / ry, 2)
					if d2 > 1.0:
						continue
					var col2: Color = rim
					if d2 < 0.30:
						col2 = deep
					elif d2 < 0.65:
						col2 = mid
					if int(float(x) + float(y) * 0.5) % 6 == 0 and d2 > 0.25:
						col2 = col2.lightened(0.08)   # faint ripple sheen
					img.set_pixel(x, y, col2)
		"magma":
			for y in range(h):
				for x in range(w):
					var dm: float = pow((float(x) - cx) / rx, 2) + pow((float(y) - cy) / ry, 2)
					if dm > 1.0:
						continue
					var col3: Color = Color(0.20, 0.05, 0.03)
					if dm < 0.25:
						col3 = Color(1.00, 0.85, 0.25)
					elif dm < 0.50:
						col3 = Color(0.95, 0.45, 0.10)
					elif dm < 0.78:
						col3 = Color(0.70, 0.18, 0.06)
					if rng.randf() < 0.10 and dm < 0.7:
						col3 = col3.lightened(0.20)   # ember flecks
					img.set_pixel(x, y, col3)
		"vines":
			for y in range(h):
				for x in range(w):
					var dv: float = pow((float(x) - cx) / rx, 2) + pow((float(y) - cy) / ry, 2)
					if dv > 1.0:
						continue
					var col4: Color = floor_col.darkened(0.10)
					var strand: int = int(float(x) * 0.7 + sin(float(y) * 0.6) * 3.0) % 5
					if strand == 0:
						col4 = Color(0.20, 0.42, 0.16)
					elif strand == 2:
						col4 = Color(0.28, 0.52, 0.20)
					if dv < 0.18:
						col4 = col4.darkened(0.25)
					img.set_pixel(x, y, col4)
		_:
			for y in range(h):
				for x in range(w):
					var dd: float = pow((float(x) - cx) / rx, 2) + pow((float(y) - cy) / ry, 2)
					if dd > 1.0:
						continue
					var colf: Color = floor_col.darkened(0.18)
					if dd < 0.5:
						colf = floor_col.darkened(0.34)
					img.set_pixel(x, y, colf)
	return ImageTexture.create_from_image(img)
