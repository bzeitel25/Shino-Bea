extends Node2D

# ============================================================
# DreamHub.gd — Dream Seedy City Town Square (Run 43, rebuilt Run 167)
# ============================================================
# Run 167 (Bruno): "make the night island square match the daytime
# one, with a nighttime overlay over the world like the biomes have."
#
# So this scene no longer builds a plaza of its own. It calls the
# SAME builder the waking-world Town Square calls (TownBuild.gd) with
# the SAME RunState.town_visual_tier(), which means:
#   * identical ground bake, border walls, building fronts,
#     central Dojo, torii gates, carnival arch, props and townsfolk;
#   * healing the town upgrades BOTH squares at once, because the
#     tier is read from the same place;
#   * the only night-side difference is the CanvasModulate night
#     tint (Run 113) + the street lamps burning at night strength.
#
# On top of the shared square the dream layer adds:
# The street outside the Dream-Dojo (GDD §7 Town-Square model).
# Run start drops the ninjas here; it is the between-biome hub:
#
#   * 5 CITY GATES at the compass points (DreamBiomes.HUB_GATE_POS):
#     walk up + [E] to enter that biome (8-room run). Cleansed
#     biomes show ✓ and stay closed.
#   * SHOP STANDS (Run 45; rebuilt Run 167) — 3 random picks out of
#     {Juice 75c, DragonFruit 100c, Pie 100c, Mystery Boon 100c},
#     one purchase each per hub visit (restock every return). Low
#     chance a DRAGON SOUL stand appears (300c) — once bought it
#     never restocks again this run. The stands are now real vendor
#     tables set up just north of the south carnival torii, run by
#     the DRAGON FRUIT family, with the boon icons as their goods.
#   * TOWN-SQUARE DEFENSE — once all 5 biomes are cleansed, a
#     5-wave gauntlet of mixed-biome monsters pours into the
#     plaza. Clearing it opens the CAKE PORTAL (center-north)
#     and restocks the shops for a final spend.
#   * CAKE PORTAL → CakeAscend.tscn (load screen) → finale climb.
#
# Combat-less until the gauntlet. Bea follows normally.
# ============================================================

const DB = preload("res://scripts/DreamBiomes.gd")
const DreamSpawnerScript = preload("res://scripts/DreamSpawner.gd")
# Run 151 — hand-drawn torii gate sprites + swirling portal effects.
const TORII = preload("res://scripts/ToriiGate.gd")
# Run 167 — the square itself is built by the SHARED builder, so the dream
# hub and the waking-world Town Square are the same town. See TownBuild.gd.
const TB = preload("res://scripts/TownBuild.gd")
const SHOP = preload("res://scripts/ShopStand.gd")

const DREAM_ROOM_PATH: String = "res://scenes/DreamRoom.tscn"
const CAKE_ASCEND_PATH: String = "res://scenes/CakeAscend.tscn"
const BOON_OFFER_SCENE: String = "res://scenes/BoonOffer.tscn"

# Arena geometry is TownBuild's — never diverge from the day square.
const HALF_W: float = TB.HALF_W
const HALF_H: float = TB.HALF_H

const SHOP_JUICE_COST: int = 75
const SHOP_PIE_COST:   int = 100
const SHOP_BOON_COST:  int = 100
const SHOP_DF_COST:    int = 100
const SHOP_SPARK_COST: int = 300
const SHOP_SPARK_CHANCE: float = 0.15   # low chance the spark stand appears
const GAUNTLET_REWARD_COINS: int = 100
const GAUNTLET_WAVES: int = 5


var _interactables: Array = []   # [{zone, kind, id, label, prompt, in_range}]
var _busy: bool = false          # true during fades / gauntlet wave spawns
var _gauntlet_active: bool = false
var _gauntlet_wave: int = 0
var _poll_timer: float = 0.0
var _shop_used: Dictionary = {}   # filled by _build_shops() per stocked stand
var _shop_slot_count: int = 0     # how many TB.SHOP_SLOTS are occupied this visit
var _shop_stands: Dictionary = {} # id -> ShopStand parts dict + entry (SOLD-OUT visuals)

@onready var banner: Label = $DebugHUD/BannerLabel
@onready var hint: Label = $DebugHUD/HintLabel


func _ready() -> void:
	# Stray pending rewards (hub/boss doors) must not leak into the next biome.
	if RunState.has_pending_reward():
		RunState.consume_pending_reward()
	RunState.dream_world_mode = true
	RunState.current_biome = ""
	RunState.biome_room = 1

	# Leaving a biome → switch off biome music. Plays the nighttime Dream World
	# hub music if/when tracks are dropped into Assets/Music/Town_Night/,
	# otherwise fades to silence.
	MusicManager.play_area("town_night")

	# Run 167 — the square is the DAY square, built from the shared builder at
	# the live healing tier, then tinted to night. Order matters: terrain →
	# landmark → gates/arch → props (they need the shop keepouts) → folk.
	y_sort_enabled = true
	var tier: int = RunState.town_visual_tier()
	Log.dbg("[DreamHub] Town visual tier: %d (0=delap 1=healing 2=perfect)." % tier)
	TB.build_terrain(self, tier, true)
	TB.build_dojo_landmark(self, "THE DREAM DOJO")
	_build_gates()
	_build_carnival_arch()
	_build_shops()
	TB.build_props(self, tier, TB.prop_keepouts() + TB.shop_keepouts(_shop_slot_count), true)
	TB.build_townsfolk(self)   # Run 167b: parked until generic townsfolk art lands
	if RunState.gauntlet_cleared:
		_build_cake_portal()
	_place_heroes()

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
	TB.apply_night_overlay(self)


# Heroes start on the Dojo doorstep, exactly where the day square puts them.
func _place_heroes() -> void:
	var spawn: Vector2 = TB.doorstep()
	var pl := get_node_or_null("Player")
	if pl:
		(pl as Node2D).position = spawn + Vector2(-26, 0)
	var be := get_node_or_null("Bea")
	if be:
		(be as Node2D).position = spawn + Vector2(26, 0)


# ---------------------------------------------------------------------------
# Build — biome gates
# ---------------------------------------------------------------------------

func _build_gates() -> void:
	for biome_id in DB.BIOME_ORDER:
		var biome: Dictionary = DB.get_biome(biome_id)
		var cleared: bool = bool(RunState.biomes_cleared.get(biome_id, false))

		# Run 167 — same builder, same anchor, same torii the day square uses.
		# Portal active only for uncleansed biomes; a cleansed gate shows the
		# architecture alone (no swirl — the path is closed).
		var gate: Node2D = TB.build_gate(self, String(biome_id), not cleared, "HubGate")
		if cleared:
			var spr := gate.get_node_or_null("ToriiGate_%s/GateSprite" % biome_id)
			if spr is CanvasItem:
				(spr as CanvasItem).modulate = Color(0.6, 0.7, 0.6, 0.85)

		var tier: int = RunState.biomes_cleared_count()
		TB.add_gate_label(gate, "%s\n%s %s" % [
				String(biome["direction"]),
				String(biome["display"]),
				("\u2713 CLEANSED" if cleared else "\u2014 Tier %s" % _roman(tier + 1))],
			Color(0.55, 0.85, 0.55) if cleared else Color(1, 1, 1))

		if not cleared:
			_add_interactable(gate, "gate", String(biome_id), "Enter %s" % String(biome["display"]))


# ---------------------------------------------------------------------------
# Build — the south carnival arch. Shut at night in both directions: the fair
# doesn't run after dark, and the troupe's merchants are camped in front of it.
# ---------------------------------------------------------------------------
func _build_carnival_arch() -> void:
	# Run 167b (Bruno): no portal in the night arch, and walking up to it tells
	# you so. The fair never runs after dark — the road south is simply shut.
	# (Something may open here later: a secret night biome is the standing idea.)
	var open_by_day: bool = RunState.carnival_open()
	var blurb: String = "The lanterns are dark \u2014 the fair sleeps." if open_by_day \
		else "The Dragon Fruit troupe hasn't come to town yet."
	var arch: Node2D = TB.build_carnival_arch(self, "S \u2014 CARNIVAL ROAD\n%s" % blurb,
		Color(0.95, 0.65, 0.75), false)
	_add_interactable(arch, "carnival", "carnival", "Try the carnival road")


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
	# Run 167 — each pick becomes a real carnival vendor table north of the
	# south torii, staffed by the Dragon Fruit family (ShopStand.gd).
	var catalog: Array = [
		{"id": "juice",       "title": "JUICE STAND",  "desc": "Heal both 50%%  \u2014  %dc" % RunState.get_shop_price(SHOP_JUICE_COST)},
		{"id": "dragonfruit", "title": "POM STAND",    "desc": "Level up a boon  \u2014  %dc" % RunState.get_shop_price(SHOP_DF_COST)},
		{"id": "pie",         "title": "PIE STAND",    "desc": "+Max HP  \u2014  %dc" % RunState.get_shop_price(SHOP_PIE_COST)},
		{"id": "boon",        "title": "MYSTERY BOON", "desc": "???  \u2014  %dc" % RunState.get_shop_price(SHOP_BOON_COST)},
	]
	# DragonFruit needs something to level — same gate as the dream doors.
	if RunState.shino_boon_set.is_empty() or RunState.bea_boon_set.is_empty():
		catalog = catalog.filter(func(c): return String(c.id) != "dragonfruit")
	catalog.shuffle()
	var stands: Array = catalog.slice(0, min(3, catalog.size()))
	if not RunState.shop_spark_bought and randf() < SHOP_SPARK_CHANCE:
		stands.append({"id": "spark", "title": "DRAGON SOUL",
			"desc": "Permanent power  \u2014  %dc" % RunState.get_shop_price(SHOP_SPARK_COST)})
	stands = stands.slice(0, min(stands.size(), TB.SHOP_SLOTS.size()))
	_shop_slot_count = stands.size()

	# One y-sorted host for the whole market row so the tables, the keeper and
	# the heroes all share the square's foot-Y sort space.
	var row := Node2D.new()
	row.name = "ShopRow"
	row.y_sort_enabled = true
	add_child(row)

	# Run 167b (Bruno): ONE Dragon Fruit boy minds the whole row. Tally stands
	# behind the counters; the rest of the troupe stay at the Carnival.
	const FOLK = preload("res://scripts/TownFolk.gd")
	FOLK.make(row, SHOP.KEEPER, TB.SHOP_KEEPER_POS, false, SHOP.KEEPER_SCALE)

	_shop_used.clear()
	_shop_stands.clear()
	for i in range(stands.size()):
		var st: Dictionary = stands[i]
		var sid: String = String(st.id)
		var pos: Vector2 = TB.SHOP_SLOTS[i]
		_shop_used[sid] = false
		var parts: Dictionary = SHOP.build(row, sid, pos, String(st.title),
			String(st.desc), pos.x > 0.0)
		var entry: Dictionary = _add_interactable(parts["root"], "shop", sid, "Buy",
			Vector2(-84, -212))
		parts["entry"] = entry
		_shop_stands[sid] = parts


# ---------------------------------------------------------------------------
# Build — cake portal (post-gauntlet)
# ---------------------------------------------------------------------------

func _build_cake_portal() -> void:
	# Run 167 — the Fortress opens in the NORTH TORII rather than floating in
	# the middle of the plaza: with the Dojo now standing at the centre of the
	# square (day-parity) there is no room for a free-standing ring, and by the
	# time the gauntlet is cleared every biome gate is shut anyway — so the
	# north gate is free to become the way up. The dirt spine already runs to
	# its foot, which makes it read as the road out of town.
	if get_node_or_null("CakePortal") != null:
		return
	var gate := get_node_or_null("HubGate_peaks") as Node2D
	var anchor: Vector2 = TB.gate_pos("peaks")
	if gate != null:
		# Re-light the cleansed gate and hide its "CLEANSED" plate.
		var spr := gate.get_node_or_null("ToriiGate_peaks/GateSprite")
		if spr is CanvasItem:
			(spr as CanvasItem).modulate = Color(1, 1, 1, 1)
		var old_lbl := gate.get_node_or_null("GateLabel")
		if old_lbl is CanvasItem:
			(old_lbl as CanvasItem).visible = false

	var portal := Node2D.new()
	portal.name = "CakePortal"
	portal.position = anchor + Vector2(0, 34)
	add_child(portal)

	var ring := Line2D.new()
	ring.width = 6.0
	ring.default_color = Color(0.95, 0.55, 0.65, 0.9)
	for i in range(33):
		var a: float = TAU * float(i) / 32.0
		ring.add_point(Vector2(cos(a), sin(a)) * 46.0)
	ring.z_as_relative = false
	ring.z_index = 3
	portal.add_child(ring)

	var lbl := Label.new()
	lbl.text = "DRAGON CAKE FORTRESS\nThe finale awaits above..."
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.95, 0.65, 0.75))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-90, 56)
	lbl.custom_minimum_size = Vector2(180, 0)
	lbl.z_as_relative = false
	lbl.z_index = 12
	portal.add_child(lbl)

	_add_interactable(portal, "portal", "cake", "Ascend to the Dragon Cake Fortress",
		Vector2(-90, 96))


# ---------------------------------------------------------------------------
# Interactables — proximity + [E]
# ---------------------------------------------------------------------------

func _add_interactable(host: Node2D, kind: String, id: String, action: String,
		prompt_off: Vector2 = Vector2(-70, 42)) -> Dictionary:
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
	InputGlyphs.bind_label(prompt, "[{interact}] %s" % action)   # Run 158 — live device glyph
	prompt.add_theme_font_size_override("font_size", 14)
	prompt.add_theme_color_override("font_color", Color(1.0, 1.0, 0.7))
	prompt.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.0))
	prompt.add_theme_constant_override("outline_size", 3)
	prompt.position = prompt_off   # below a gate, above a shop counter
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
			"gate":     _enter_biome(String(entry.id))
			"shop":     _try_buy(String(entry.id))
			"portal":   _ascend()
			"carnival": _flash_hint("The road south is shut \u2014 the fair doesn't run at night.")
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
	Log.dbg("[DreamHub] Entering %s." % String(biome["display"]))
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
	# Grey the goods, relabel "SOLD OUT", and kill the [E] Buy prompt so a bought
	# stand can't be re-purchased and clearly reads as unavailable this visit.
	var parts: Dictionary = _shop_stands.get(shop_id, {})
	if parts.is_empty():
		return
	SHOP.set_sold(parts, true)
	var entry: Dictionary = parts.get("entry", {})
	if not entry.is_empty():
		entry.in_range = false
		var prompt := entry.get("prompt") as Label
		if prompt:
			prompt.visible = false


func _restock_stand_visual(shop_id: String) -> void:
	# Inverse of _mark_stand_sold — used by the post-gauntlet restock (the
	# per-biome restock rebuilds the whole row from scratch).
	var parts: Dictionary = _shop_stands.get(shop_id, {})
	if not parts.is_empty():
		SHOP.set_sold(parts, false)


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
		# Run 167 — the Dojo landmark now fills the middle of the square, so the
		# old 220-360px ring would drop half the wave inside the building. Spawn
		# on the OUTER ring instead (an ellipse just outside the ring road) and
		# push anything that still lands on the Dojo footprint clear of it.
		var a: float = TAU * float(i) / float(n) + randf_range(-0.3, 0.3)
		var r: float = randf_range(1.0, 1.28)
		var pos := TB.DOJO_CENTER + Vector2(cos(a) * 420.0 * r, sin(a) * 268.0 * r)
		var d: Vector2 = pos - TB.DOJO_CENTER
		var keep := Vector2(TB.DOJO_BODY_SIZE.x * 0.5 + 60.0, TB.DOJO_BODY_SIZE.y * 0.5 + 60.0)
		if absf(d.x) < keep.x and absf(d.y) < keep.y:
			pos = TB.DOJO_CENTER + Vector2(
				keep.x * signf(d.x if absf(d.x) > 0.01 else 1.0),
				keep.y * signf(d.y if absf(d.y) > 0.01 else 1.0))
		pos.x = clamp(pos.x, -HALF_W + 50, HALF_W - 50)
		pos.y = clamp(pos.y, -HALF_H + 50, HALF_H - 50)
		(e as Node2D).global_position = pos
	if banner:
		banner.text = "⚔️ WAVE %d / %d ⚔️" % [_gauntlet_wave, GAUNTLET_WAVES]
	_poll_timer = 0.5
	Log.dbg("[DreamHub] Gauntlet wave %d — %d enemies." % [_gauntlet_wave, n])


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
	Log.dbg("[DreamHub] Gauntlet cleared — Cake Portal open.")


# ---------------------------------------------------------------------------
# Finale ascent
# ---------------------------------------------------------------------------

func _ascend() -> void:
	_busy = true
	RunState.current_biome = "cake"
	RunState.biome_room = 1
	if RunState.has_pending_reward():
		RunState.consume_pending_reward()
	Log.dbg("[DreamHub] Ascending to the Dragon Cake Fortress.")
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
