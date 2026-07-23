extends Node2D

# ============================================================
# DreamHub.gd — Run 43 (2026-06-10) — Dream Seedy City Town Square
# ============================================================
# The street outside the Dream-Dojo (GDD §7 Town-Square model).
# Run start drops the ninjas here; it is the between-biome hub:
#
#   * 5 CITY GATES at the compass points (DreamBiomes.HUB_GATE_POS):
#     walk up + [E] to enter that biome (8-room run). Cleansed
#     biomes show ✓ and stay closed.
#   * SHOP STANDS (Run 45) — 3 random picks out of {Juice 75c,
#     DragonFruit 100c, Pie 100c, Mystery Boon 100c}, one purchase
#     each per hub visit (restock every return). Low chance a
#     DRAGON SOUL stand appears (300c) — once bought it never
#     restocks again this run.
#   * TOWN-SQUARE DEFENSE — once all 5 biomes are cleansed, a
#     5-wave gauntlet of mixed-biome monsters pours into the
#     plaza. Clearing it opens the CAKE PORTAL (center-north)
#     and restocks the shops for a final spend.
#   * CAKE PORTAL → CakeAscend.tscn (load screen) → finale climb.
#
# Combat-less until the gauntlet. Bea follows normally.
# ============================================================

const DB = preload("res://scripts/DreamBiomes.gd")
const DT = preload("res://scripts/DreamTerrain.gd")
const DreamSpawnerScript = preload("res://scripts/DreamSpawner.gd")
# Run 151 — hand-drawn torii gate sprites + swirling portal effects.
const TORII = preload("res://scripts/ToriiGate.gd")

const DREAM_ROOM_PATH: String = "res://scenes/DreamRoom.tscn"
const CAKE_ASCEND_PATH: String = "res://scenes/CakeAscend.tscn"
const BOON_OFFER_SCENE: String = "res://scenes/BoonOffer.tscn"

const HALF_W: float = 710.0
const HALF_H: float = 400.0

const SHOP_JUICE_COST: int = 75
const SHOP_PIE_COST:   int = 100
const SHOP_BOON_COST:  int = 100
const SHOP_DF_COST:    int = 100
const SHOP_SPARK_COST: int = 300
const SHOP_SPARK_CHANCE: float = 0.15   # low chance the spark stand appears
const GAUNTLET_REWARD_COINS: int = 100
const GAUNTLET_WAVES: int = 5

const PLAZA_COLOR: Color      = Color(0.30, 0.28, 0.34)   # night-street cobbles
const PLAZA_ALT_COLOR: Color  = Color(0.34, 0.32, 0.38)
const WALL_COLOR: Color       = Color(0.22, 0.20, 0.26)

var _interactables: Array = []   # [{zone, kind, id, label, prompt, in_range}]
var _busy: bool = false          # true during fades / gauntlet wave spawns
var _gauntlet_active: bool = false
var _gauntlet_wave: int = 0
var _poll_timer: float = 0.0
var _shop_used: Dictionary = {}   # filled by _build_shops() per stocked stand
var _shop_stands: Dictionary = {} # id -> {booth, lbl, title, col, entry} for SOLD-OUT visuals

@onready var banner: Label = $DebugHUD/BannerLabel
@onready var hint: Label = $DebugHUD/HintLabel


func _ready() -> void:
	# Stray pending rewards (hub/boss doors) must not leak into the next biome.
	if RunState.has_pending_reward():
		RunState.consume_pending_reward()
	RunState.dream_world_mode = true
	RunState.current_biome = ""
	RunState.biome_room = 1

	# Leaving a biome → switch off biome music. Plays Town Square music if/when
	# tracks are dropped into Assets/Music/TownSquare/, otherwise fades to silence.
	MusicManager.play_area("town")

	_build_plaza()
	_build_gates()
	_build_shops()
	if RunState.gauntlet_cleared:
		_build_cake_portal()

	_refresh_banner()

	# Autosave checkpoint — resuming a slot lands back in the Square.
	RunState.resume_scene_path = "res://scenes/DreamHub.tscn"
	if get_node_or_null("/root/SaveManager") and SaveManager.active_slot >= 0:
		SaveManager.save_active_slot()

	FX.fade_from_black(0.5)
	_apply_night_overlay()

	# Run 146 — framed beginner tooltip.
	const HINT = preload("res://scripts/HintPopup.gd")
	HINT.show_hint(self, "Dream Hub — The Dream World",
		"Choose a biome gate to begin  •  Spend coins at the merchants  •  Clear all five biomes to unlock the summit")

	# All five cleansed and gauntlet not yet fought → it begins after a beat.
	if RunState.all_biomes_cleared() and not RunState.gauntlet_cleared:
		await get_tree().create_timer(1.6).timeout
		_start_gauntlet()


# ---------------------------------------------------------------------------
# Run 113 — Night fell over the Dream World. Same removable CanvasModulate
# tint as DreamRoom: one node over the layer-0 world canvas (plaza, dojo
# facade, gates, shops, heroes). HUD ($DebugHUD CanvasLayer) stays bright.
# Pure overlay — changes nothing about the built hub; tune RunState.NIGHT_TINT.
# ---------------------------------------------------------------------------
func _apply_night_overlay() -> void:
	if get_node_or_null("NightOverlay") != null:
		return
	var night := CanvasModulate.new()
	night.name = "NightOverlay"
	night.color = RunState.NIGHT_TINT
	add_child(night)


# ---------------------------------------------------------------------------
# Build — plaza, dojo facade, walls
# ---------------------------------------------------------------------------

func _build_plaza() -> void:
	# Run 44: procedural pixel cobbles + dream-night void replace the flat rects.
	var hub_biome: Dictionary = {
		"floor": PLAZA_COLOR,
		"floor_alt": PLAZA_ALT_COLOR,
		"wall": WALL_COLOR,
		"accent": Color(0.95, 0.75, 0.35),   # lantern glow
	}
	DT.build(self, "hub", hub_biome, Vector2(HALF_W, HALF_H), 7770, 0.0, "void")

	# Dream-Dojo facade — center of the square (where the run "begins").
	var dojo := ColorRect.new()
	dojo.offset_left = -90; dojo.offset_top = -64
	dojo.offset_right = 90; dojo.offset_bottom = 30
	dojo.color = Color(0.16, 0.12, 0.18)
	dojo.z_index = -10
	add_child(dojo)
	# Run 146 — "DREAM DOJO" floating label removed; replaced by framed
	# HintPopup tooltip on scene entry (see _ready below).

	var walls := Node2D.new()
	walls.name = "Walls"
	add_child(walls)
	_make_wall(walls, Vector2(0, -HALF_H - 16), Vector2(HALF_W * 2 + 64, 32))
	_make_wall(walls, Vector2(0, HALF_H + 16), Vector2(HALF_W * 2 + 64, 32))
	_make_wall(walls, Vector2(-HALF_W - 16, 0), Vector2(32, HALF_H * 2 + 64))
	_make_wall(walls, Vector2(HALF_W + 16, 0), Vector2(32, HALF_H * 2 + 64))


func _make_wall(parent: Node, pos: Vector2, size: Vector2) -> void:
	var w := StaticBody2D.new()
	w.position = pos
	w.collision_layer = 1
	w.collision_mask = 0
	var vis := ColorRect.new()
	vis.offset_left = -size.x * 0.5; vis.offset_top = -size.y * 0.5
	vis.offset_right = size.x * 0.5; vis.offset_bottom = size.y * 0.5
	vis.color = WALL_COLOR
	w.add_child(vis)
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = size
	cs.shape = shape
	w.add_child(cs)
	parent.add_child(w)


# ---------------------------------------------------------------------------
# Build — biome gates
# ---------------------------------------------------------------------------

func _build_gates() -> void:
	for biome_id in DB.BIOME_ORDER:
		var biome: Dictionary = DB.get_biome(biome_id)
		var raw: Vector2 = DB.HUB_GATE_POS[biome_id]
		# Position flush against the perimeter wall.
		var pos := Vector2(
			clamp(raw.x, -HALF_W + 10, HALF_W - 10),
			clamp(raw.y, -HALF_H + 10, HALF_H - 10))
		var cleared: bool = bool(RunState.biomes_cleared.get(biome_id, false))

		var gate := Node2D.new()
		gate.name = "HubGate_%s" % biome_id
		gate.position = pos
		add_child(gate)

		# Run 151 — hand-drawn torii sprite + swirling portal.
		# Portal active only for uncleansed biomes; cleansed gates show the
		# torii architecture alone (no swirl — the path is closed).
		var torii := TORII.build(biome_id, not cleared)
		gate.add_child(torii)
		# Dim the gate sprite when cleansed so it reads as "done".
		if cleared:
			var spr := torii.get_node_or_null("GateSprite")
			if spr:
				spr.modulate = Color(0.6, 0.7, 0.6, 0.85)

		var tier: int = RunState.biomes_cleared_count()
		var name_label := Label.new()
		name_label.text = "%s\n%s %s" % [
			String(biome["direction"]),
			String(biome["display"]),
			("✓ CLEANSED" if cleared else "— Tier %s" % _roman(tier + 1))]
		name_label.add_theme_font_size_override("font_size", 13)
		name_label.add_theme_color_override("font_color",
			Color(0.55, 0.85, 0.55) if cleared else Color(1, 1, 1))
		name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		name_label.add_theme_constant_override("outline_size", 3)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# Label points inward from the wall so it stays inside the arena.
		var lbl_off := Vector2(-100, -150)
		if pos.y < -HALF_H + 60:       # north wall — label below
			lbl_off = Vector2(-100, 50)
		elif pos.x > HALF_W - 60:      # east wall — label to the left
			lbl_off = Vector2(-240, -36)
		elif pos.x < -HALF_W + 60:     # west wall — label to the right
			lbl_off = Vector2(40, -36)
		name_label.position = lbl_off
		name_label.custom_minimum_size = Vector2(200, 0)
		gate.add_child(name_label)

		if not cleared:
			_add_interactable(gate, "gate", biome_id, "Enter %s" % String(biome["display"]))


func _roman(n: int) -> String:
	return ["I", "II", "III", "IV", "V", "V"][clamp(n - 1, 0, 5)]


# ---------------------------------------------------------------------------
# Build — shop stands
# ---------------------------------------------------------------------------

func _build_shops() -> void:
	# Run 45 — rotating stock: 3 random picks from the 4-item catalog, each
	# buyable ONCE per visit. The Mystery Boon's family stays hidden until
	# purchase. Low chance a Dragon Soul stand joins (never again this run
	# once bought; keeps re-rolling until you do buy it).
	# Run 46 — Haggler's Tongue (Sensei Z): prices shown and charged via
	# RunState.get_shop_price() (-5%/rank).
	var catalog: Array = [
		{"id": "juice",       "icon": "🧃", "title": "JUICE STAND",  "desc": "Heal both 50%%  —  %dc" % RunState.get_shop_price(SHOP_JUICE_COST), "col": Color(0.30, 0.80, 0.95)},
		{"id": "dragonfruit", "icon": "🐉", "title": "DRAGONFRUIT",  "desc": "Level up a boon  —  %dc" % RunState.get_shop_price(SHOP_DF_COST),   "col": Color(0.95, 0.35, 0.55)},
		{"id": "pie",         "icon": "🥧", "title": "PIE STAND",    "desc": "+Max HP  —  %dc" % RunState.get_shop_price(SHOP_PIE_COST),          "col": Color(0.95, 0.75, 0.25)},
		{"id": "boon",        "icon": "✦",  "title": "MYSTERY BOON", "desc": "???  —  %dc" % RunState.get_shop_price(SHOP_BOON_COST),             "col": Color(0.75, 0.40, 0.95)},
	]
	# DragonFruit needs something to level — same gate as the dream doors.
	if RunState.shino_boon_set.is_empty() or RunState.bea_boon_set.is_empty():
		catalog = catalog.filter(func(c): return String(c.id) != "dragonfruit")
	catalog.shuffle()
	var stands: Array = catalog.slice(0, min(3, catalog.size()))
	var positions: Array = [Vector2(-170, 150), Vector2(0, 170), Vector2(170, 150)]
	if not RunState.shop_spark_bought and randf() < SHOP_SPARK_CHANCE:
		stands.append({"id": "spark", "icon": "✨", "title": "DRAGON SOUL",
			"desc": "Permanent power  —  %dc" % RunState.get_shop_price(SHOP_SPARK_COST), "col": Color(1.0, 0.85, 0.30)})
		positions.append(Vector2(340, 110))
	_shop_used.clear()
	_shop_stands.clear()
	for i in range(stands.size()):
		var s: Dictionary = stands[i]
		s["pos"] = positions[i]
		_shop_used[String(s.id)] = false
		var stand := Node2D.new()
		stand.name = "Shop_%s" % String(s.id)
		stand.position = s.pos
		add_child(stand)

		var booth := ColorRect.new()
		booth.offset_left = -34; booth.offset_top = -26
		booth.offset_right = 34; booth.offset_bottom = 26
		booth.color = (s.col as Color).darkened(0.45)
		stand.add_child(booth)

		var icon := Label.new()
		icon.text = String(s.icon)
		icon.add_theme_font_size_override("font_size", 30)
		icon.position = Vector2(-16, -22)
		stand.add_child(icon)

		var lbl := Label.new()
		lbl.text = "%s\n%s" % [String(s.title), String(s.desc)]
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", s.col)
		lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		lbl.add_theme_constant_override("outline_size", 3)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.position = Vector2(-70, 32)
		lbl.custom_minimum_size = Vector2(140, 0)
		stand.add_child(lbl)

		var entry: Dictionary = _add_interactable(stand, "shop", String(s.id), "Buy")
		_shop_stands[String(s.id)] = {"booth": booth, "lbl": lbl, "title": String(s.title), "orig_text": lbl.text, "col": s.col, "entry": entry}


# ---------------------------------------------------------------------------
# Build — cake portal (post-gauntlet)
# ---------------------------------------------------------------------------

func _build_cake_portal() -> void:
	if get_node_or_null("CakePortal") != null:
		return
	var portal := Node2D.new()
	portal.name = "CakePortal"
	portal.position = Vector2(0, -HALF_H + 90)
	add_child(portal)

	var ring := Line2D.new()
	ring.width = 6.0
	ring.default_color = Color(0.95, 0.55, 0.65, 0.9)
	for i in range(33):
		var a: float = TAU * float(i) / 32.0
		ring.add_point(Vector2(cos(a), sin(a)) * 46.0)
	portal.add_child(ring)

	var icon := Label.new()
	icon.text = "🍰"
	icon.add_theme_font_size_override("font_size", 44)
	icon.position = Vector2(-26, -34)
	portal.add_child(icon)

	var lbl := Label.new()
	lbl.text = "DRAGON CAKE FORTRESS\nThe finale awaits above..."
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.95, 0.65, 0.75))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-90, 52)
	lbl.custom_minimum_size = Vector2(180, 0)
	portal.add_child(lbl)

	_add_interactable(portal, "portal", "cake", "Ascend to the Dragon Cake Fortress")


# ---------------------------------------------------------------------------
# Interactables — proximity + [E]
# ---------------------------------------------------------------------------

func _add_interactable(host: Node2D, kind: String, id: String, action: String) -> Dictionary:
	var zone := Area2D.new()
	zone.collision_layer = 0
	zone.collision_mask = 2
	var shape := CircleShape2D.new()
	shape.radius = 64.0
	var cs := CollisionShape2D.new()
	cs.shape = shape
	zone.add_child(cs)
	host.add_child(zone)

	var prompt := Label.new()
	prompt.text = "[E] %s" % action
	prompt.add_theme_font_size_override("font_size", 14)
	prompt.add_theme_color_override("font_color", Color(1.0, 1.0, 0.7))
	prompt.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.0))
	prompt.add_theme_constant_override("outline_size", 3)
	prompt.position = Vector2(-70, 42)   # below the gate, always inside the arena
	prompt.visible = false
	prompt.z_index = 20
	host.add_child(prompt)

	var entry: Dictionary = {"zone": zone, "kind": kind, "id": id, "prompt": prompt, "in_range": false}
	zone.body_entered.connect(func(body: Node):
		if _is_active_player(body):
			entry.in_range = true
			prompt.visible = true)
	zone.body_exited.connect(func(body: Node):
		if _is_active_player(body):
			entry.in_range = false
			prompt.visible = false)
	_interactables.append(entry)
	return entry


func _is_active_player(body: Node) -> bool:
	if body.is_in_group("player") and not body.is_in_group("bea"):
		return true
	if body.is_in_group("bea") and body.get("player_controlled") == true:
		return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if _busy or _gauntlet_active:
		return
	if not event.is_action_pressed("interact") or event.is_echo():
		return
	for entry in _interactables:
		if not bool(entry.in_range):
			continue
		match String(entry.kind):
			"gate":   _enter_biome(String(entry.id))
			"shop":   _try_buy(String(entry.id))
			"portal": _ascend()
		return


# ---------------------------------------------------------------------------
# Gates → biome runs
# ---------------------------------------------------------------------------

func _enter_biome(biome_id: String) -> void:
	if bool(RunState.biomes_cleared.get(biome_id, false)):
		return
	_busy = true
	RunState.current_biome = biome_id
	RunState.biome_room = 1
	if RunState.has_pending_reward():
		RunState.consume_pending_reward()
	var biome: Dictionary = DB.get_biome(biome_id)
	print("[DreamHub] Entering %s." % String(biome["display"]))
	FX.fade_to_black(0.45, 0.05, 1.0, Callable(self, "_goto_dream_room"))


func _goto_dream_room() -> void:
	get_tree().change_scene_to_file(DREAM_ROOM_PATH)


# ---------------------------------------------------------------------------
# Shops
# ---------------------------------------------------------------------------

func _try_buy(shop_id: String) -> void:
	if bool(_shop_used.get(shop_id, false)):
		_flash_hint("Sold out — restocks next visit.")
		return
	# Spark is once per run, period — guards against the post-gauntlet restock.
	if shop_id == "spark" and RunState.shop_spark_bought:
		_flash_hint("The spark merchant has nothing left this run.")
		return
	var cost: int = RunState.get_shop_price({"juice": SHOP_JUICE_COST, "pie": SHOP_PIE_COST,
		"boon": SHOP_BOON_COST, "dragonfruit": SHOP_DF_COST, "spark": SHOP_SPARK_COST}[shop_id])
	if RunState.run_coins < cost:
		_flash_hint("Not enough coins (%d needed, %d held)." % [cost, RunState.run_coins])
		return
	RunState.add_coins(-cost)
	_shop_used[shop_id] = true
	_mark_stand_sold(shop_id)
	_refresh_banner()   # keep the top-center coin count in sync with the purchase
	match shop_id:
		"juice":
			var healed: int = RunState.grant_apple_juice(get_tree())
			_flash_hint("🧃 Both heroes restored (+%d HP)." % healed)
		"pie":
			RunState.grant_apple_pie()
			_flash_hint("🥧 Max HP increased!")
		"dragonfruit":
			RunState.commit_door_choice({"type": "dragon_fruit", "family": "", "rarity": ""})
			_spawn_boon_overlay()
			_flash_hint("🐉 Dragonfruit — choose a boon to level up!")
		"boon":
			var fam: String = RunState.DOOR_FAMILIES[randi() % RunState.DOOR_FAMILIES.size()]
			RunState.commit_door_choice({"type": "boon", "family": fam, "rarity": ""})
			_spawn_boon_overlay()
			_flash_hint("✦ A %s boon manifests..." % fam.capitalize())
		"spark":
			RunState.dragon_souls += 1
			RunState.shop_spark_bought = true
			_flash_hint("✨ +1 Dragon Soul (%d total) — spend it at Sensei Z." % RunState.dragon_souls)
	FX.play_sound("boon_pickup_spawn", 1.0)


func _mark_stand_sold(shop_id: String) -> void:
	# Grey the booth, relabel "SOLD OUT", and kill the [E] Buy prompt so a bought
	# stand can't be re-purchased and clearly reads as unavailable this visit.
	var s: Dictionary = _shop_stands.get(shop_id, {})
	if s.is_empty():
		return
	var booth := s.get("booth") as ColorRect
	if booth:
		booth.color = Color(0.18, 0.18, 0.20)
	var lbl := s.get("lbl") as Label
	if lbl:
		lbl.text = "%s\nSOLD OUT" % String(s.get("title", ""))
		lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.58))
	var entry: Dictionary = s.get("entry", {})
	if not entry.is_empty():
		entry.in_range = false
		var prompt := entry.get("prompt") as Label
		if prompt:
			prompt.visible = false


func _restock_stand_visual(shop_id: String) -> void:
	# Inverse of _mark_stand_sold — restore a stand's available look (used by the
	# post-gauntlet restock; the per-biome restock rebuilds stands from scratch).
	var s: Dictionary = _shop_stands.get(shop_id, {})
	if s.is_empty():
		return
	var col: Color = s.get("col", Color.WHITE)
	var booth := s.get("booth") as ColorRect
	if booth:
		booth.color = col.darkened(0.45)
	var lbl := s.get("lbl") as Label
	if lbl:
		lbl.text = String(s.get("orig_text", lbl.text))
		lbl.add_theme_color_override("font_color", col)


func _spawn_boon_overlay() -> void:
	if ResourceLoader.exists(BOON_OFFER_SCENE):
		var overlay: CanvasLayer = (load(BOON_OFFER_SCENE) as PackedScene).instantiate()
		overlay.name = "BoonOffer"
		get_tree().current_scene.add_child(overlay)


func _flash_hint(text: String) -> void:
	if hint == null:
		return
	hint.text = text
	hint.visible = true
	hint.modulate.a = 1.0
	var tw: Tween = create_tween()
	tw.tween_interval(2.2)
	tw.tween_property(hint, "modulate:a", 0.0, 0.8)


# ---------------------------------------------------------------------------
# Town-Square Defense — 5-wave gauntlet
# ---------------------------------------------------------------------------

func _start_gauntlet() -> void:
	_gauntlet_active = true
	_gauntlet_wave = 0
	if banner:
		banner.text = "⚔️ TOWN-SQUARE DEFENSE ⚔️\nThe shadows pour into the plaza!"
		banner.visible = true
	await get_tree().create_timer(1.8).timeout
	_spawn_gauntlet_wave()


func _spawn_gauntlet_wave() -> void:
	_gauntlet_wave += 1
	var n: int = 4 + _gauntlet_wave * 2   # 6 / 8 / 10 / 12 / 14
	for i in range(n):
		# Mixed-biome pull — random biome roster each spawn.
		var src: String = DB.BIOME_ORDER[randi() % DB.BIOME_ORDER.size()]
		var cfg: Dictionary = DB.random_enemy(src)
		var scene_path: String = DB.ARCH_SCENES.get(String(cfg.get("arch", "melee")), DB.ARCH_SCENES["melee"])
		if not ResourceLoader.exists(scene_path):
			continue
		var e: Node = (load(scene_path) as PackedScene).instantiate()
		DreamSpawnerScript.apply_config(e, cfg, 5)
		add_child(e)
		var a: float = TAU * float(i) / float(n) + randf_range(-0.3, 0.3)
		var pos := Vector2(cos(a), sin(a)) * randf_range(220.0, 360.0)
		pos.x = clamp(pos.x, -HALF_W + 50, HALF_W - 50)
		pos.y = clamp(pos.y, -HALF_H + 50, HALF_H - 50)
		(e as Node2D).global_position = pos
	if banner:
		banner.text = "⚔️ WAVE %d / %d ⚔️" % [_gauntlet_wave, GAUNTLET_WAVES]
	_poll_timer = 0.5
	print("[DreamHub] Gauntlet wave %d — %d enemies." % [_gauntlet_wave, n])


func _process(delta: float) -> void:
	if not _gauntlet_active:
		return
	_poll_timer -= delta
	if _poll_timer > 0.0:
		return
	_poll_timer = 0.4
	if get_tree().get_nodes_in_group("enemy").is_empty():
		if _gauntlet_wave >= GAUNTLET_WAVES:
			_finish_gauntlet()
		else:
			_spawn_gauntlet_wave()


func _finish_gauntlet() -> void:
	_gauntlet_active = false
	RunState.gauntlet_cleared = true
	RunState.add_coins(GAUNTLET_REWARD_COINS)
	# Shops restock for the final purchase before the ascent.
	for k in _shop_used.keys():
		_shop_used[k] = false
		_restock_stand_visual(String(k))
	if banner:
		banner.text = "✦ THE SQUARE HOLDS! ✦\n💰 +%d coins — shops restocked.\nThe Dragon Cake Fortress rises above..." % GAUNTLET_REWARD_COINS
	_build_cake_portal()
	if get_node_or_null("/root/SaveManager") and SaveManager.active_slot >= 0:
		SaveManager.save_active_slot()
	FX.screen_shake(FX.SHAKE_LIGHT, 0.5)
	print("[DreamHub] Gauntlet cleared — Cake Portal open.")


# ---------------------------------------------------------------------------
# Finale ascent
# ---------------------------------------------------------------------------

func _ascend() -> void:
	_busy = true
	RunState.current_biome = "cake"
	RunState.biome_room = 1
	if RunState.has_pending_reward():
		RunState.consume_pending_reward()
	print("[DreamHub] Ascending to the Dragon Cake Fortress.")
	FX.fade_to_black(0.6, 0.1, 1.0, Callable(self, "_goto_cake"))


func _goto_cake() -> void:
	get_tree().change_scene_to_file(CAKE_ASCEND_PATH)


func _refresh_banner() -> void:
	if banner == null:
		return
	var cleared: int = RunState.biomes_cleared_count()
	if RunState.gauntlet_cleared:
		banner.text = "The Cake Portal shimmers to the north. Final purchases, then ascend!"
	elif cleared >= 5:
		banner.text = "All five biomes cleansed..."
	else:
		banner.text = "DREAM SEEDY CITY — TOWN SQUARE\nBiomes cleansed: %d / 5   💰 %d coins" % [cleared, RunState.run_coins]
	banner.visible = true
