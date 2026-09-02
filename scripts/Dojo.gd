extends Node2D

# ============================================================
# Dojo.gd — Pre-run hub scene (Run 38, 2026-06-10)
# ============================================================
# Shino & Bea's dojo room. Both characters are present and the
# player can hot-swap between them freely (Q+Q / LB), exactly
# like in any Dream arena.
#
# Two sleep spots:
#   ShinoBed (top-right)  — Shino's bed
#   BeaBed   (east wall, a good way down) — Bea's mat
# EITHER character can start the run from EITHER bed (for now).
# The character being controlled at sleep time carries into the
# run via RunState.carry_player_controlled_char.
#
# Dojo AI: the character NOT being controlled walks to the
# middle of the room (the Training Mat) and sits there, waiting
# until swapped to. See _tick_dojo_wait() in Player.gd / BeaAI.gd.
#
# Both characters can hit the TrainingDummy and talk to Sensei Z
# (SenseiZ.gd is controlled-char aware as of Run 38).
#
# Scene tree expected:
#   Dojo (Node2D, this script)
#   ├ Player   (Player.tscn — Shino)
#   ├ Bea      (Bea.tscn)
#   ├ ShinoBed (Area2D — sleep trigger; child Prompt label)
#   ├ BeaBed   (Area2D — sleep trigger; child Prompt label)
#   ├ TrainingDummy / SenseiZ / HUD / Camera2D / Walls
# ============================================================

const ARENA1_PATH: String = "res://scenes/World.tscn"
# Run 43 — Dream World: sleeping now offers a destination choice.
const DREAM_HUB_PATH: String = "res://scenes/DreamHub.tscn"
# Run 136 — Night loading screen: shows Night Start art before the dream begins.
const NIGHT_LOAD_SCREEN_PATH: String = "res://scenes/NightLoadScreen.tscn"
# Run 117 — the Dojo is the landmark building at the CENTER of the waking-world
# Town Square; its front door (south wall) steps out into the square.
const TOWN_SQUARE_PATH: String = "res://scenes/TownSquare.tscn"

# Run 141 — DialogBox for tutorial cutscene
const DB_SCRIPT = preload("res://scripts/DialogBox.gd")

# Run 72 — procedural traditional flooring (wooden planks + tatami),
# matching the Dream World's DreamTerrain art language.
const DT = preload("res://scripts/DojoTerrain.gd")
# Run 154 — real Wood_Scaffolding art for the interior wall beams.
const WS = preload("res://scripts/WoodScaffolding.gd")
# Run 171 — north-wall face baker, shared with the Cake Dojo summit room.
const WA = preload("res://scripts/DojoWallArt.gd")

# ── Room footprints (interior, world coords) ──────────────────────────
# Main training hall, plus two medium side rooms tucked against the NE
# corner: Shino's room extends NORTH (door in the north wall), Bea's room
# extends EAST (door in the east wall). Distinct directions, same corner.
const MAIN_RECT:  Rect2 = Rect2(-480, -280, 960, 560)   # x[-480,480] y[-280,280]
const SHINO_RECT: Rect2 = Rect2(180, -560, 300, 280)    # x[180,480]  y[-560,-280]
const BEA_RECT:   Rect2 = Rect2(480, -280, 280, 280)    # x[480,760]  y[-280,0]
const WALL_T: float = 32.0
const WALL_COLOR: Color = Color(0.27, 0.19, 0.12)

# Where the off-duty character sits and waits (middle of the room,
# on the Training Mat). Two spots so they don't stack on each other.
const SHINO_WAIT_POS: Vector2 = Vector2(-50, 120)
const BEA_WAIT_POS:   Vector2 = Vector2(50, 120)

var _sleeping: bool = false
var _leaving: bool = false        # Run 117 — walking out the front door
var _near_shino_bed: Array = []   # bodies currently inside ShinoBed area
var _near_bea_bed:   Array = []   # bodies currently inside BeaBed area
var _near_front_door: Array = []  # Run 117 — bodies at the front door
var _front_door_prompt: Label = null

@onready var shino_bed: Area2D = $ShinoBed
@onready var bea_bed:   Area2D = $BeaBed
@onready var shino_bed_prompt: Label = $ShinoBed/Prompt
@onready var bea_bed_prompt:   Label = $BeaBed/Prompt


func _ready() -> void:
	# Only reset run if no save slot is loaded (e.g. dev launch straight to Dojo).
	# When returning from a completed or failed run, reset_run() was already called
	# by Player._reload_arena1() or RunComplete._do_return() before navigating here,
	# and the slot was saved — so active_slot >= 0 and we skip the redundant reset.
	var sm: Node = get_node_or_null("/root/SaveManager")
	if sm == null or sm.active_slot < 0:
		RunState.reset_run()

	_build_environment()

	if shino_bed:
		shino_bed.body_entered.connect(_on_bed_entered.bind(_near_shino_bed))
		shino_bed.body_exited.connect(_on_bed_exited.bind(_near_shino_bed))
	if bea_bed:
		bea_bed.body_entered.connect(_on_bed_entered.bind(_near_bea_bed))
		bea_bed.body_exited.connect(_on_bed_exited.bind(_near_bea_bed))

	# Flag both characters as "in the dojo" — switches their AI from
	# combat follow / auto-defend to sit-on-the-mat-and-wait.
	# Deferred one frame so Player/Bea _ready() (incl. Bea's own deferred
	# Shino lookup) has finished.
	_setup_dojo_mode.call_deferred()

	# Run 117 — arriving from the Town Square: appear just inside the front door.
	if RunState.day_spawn_hint == "from_town":
		RunState.day_spawn_hint = ""
		var pl := get_node_or_null("Player")
		if pl:
			pl.position = Vector2(-26, 200)
		var be := get_node_or_null("Bea")
		if be:
			be.position = Vector2(26, 200)

	FX.fade_from_black(0.5)

	# Run 146 — framed beginner tooltip (replaces old floating header text).
	const HINT = preload("res://scripts/HintPopup.gd")
	HINT.show_hint(self, "Dojo — Shino & Bea's Home",
		"Sleep in a bed to enter the dream world  •  Talk to Sensei Z for guidance")
	# Combat tips — separate category; shows after the beginner tip fades.
	var _host := self
	get_tree().create_timer(2.0).timeout.connect(func():
		if not is_instance_valid(_host):
			return
		var H = load("res://scripts/HintPopup.gd")
		H.show_combat_hint(_host, "Combat Controls",
			"Tap {attack_y} for combos  •  Hold {attack_y} to charge  •  {attack_x} for heavy attacks  •  {swap2} swaps ninja  •  Hit the Training Dummy to practise")
	)

	# Run 141 — Post-tutorial cutscene: plays once when arriving from the
	# tutorial for the first time. Both ninjas wake up, tell Sensei about
	# the shared dream, and receive the quest to check on the townspeople.
	if RunState.tutorial_completed and RunState.sensei_lore_tier == 0:
		call_deferred("_play_post_tutorial_cutscene")


# ── Cutscene walk helper ─────────────────────────────────────────────
# Walks a hero through a sequence of waypoints using their existing
# dojo_wait_pos / velocity system so walk animations play naturally.
# Each waypoint is reached before moving to the next.
func _cutscene_walk_to(hero: Node, target: Vector2, arrival_radius: float = 10.0) -> void:
	await _cutscene_walk_path(hero, [target], arrival_radius)

func _cutscene_walk_path(hero: Node, waypoints: Array, arrival_radius: float = 10.0) -> void:
	if hero == null or not is_instance_valid(hero):
		return
	for wp in waypoints:
		hero.dojo_wait_pos = wp
		while is_instance_valid(hero) and hero.global_position.distance_to(wp) > arrival_radius:
			await get_tree().physics_frame
	# Snap to final spot + zero velocity so idle pose kicks in cleanly.
	if is_instance_valid(hero) and waypoints.size() > 0:
		hero.position = waypoints[-1]
		hero.velocity = Vector2.ZERO

# Doorway waypoints — characters must path through these to exit their rooms.
# Shino's door: gap in north wall x[320,400] at y=-280.
# Bea's door:   gap in east wall  y[-220,-140] at x=480.
const SHINO_DOOR_WP := Vector2(360, -260)   # just south of Shino's doorway
const BEA_DOOR_WP   := Vector2(460, -180)   # just west of Bea's doorway


func _play_post_tutorial_cutscene() -> void:
	var pl := get_node_or_null("Player")
	var be := get_node_or_null("Bea")

	# Lock both heroes from player input for the duration of the cutscene.
	# dojo_mode is already true from _setup_dojo_mode — with player_controlled
	# off, both will use _tick_dojo_wait() which walks to dojo_wait_pos using
	# velocity + move_and_slide, triggering walk animations naturally.
	var pl_was_controlled: bool = pl.player_controlled if pl else true
	var be_was_controlled: bool = be.player_controlled if be else false
	if pl:
		pl.player_controlled = false
	if be:
		be.player_controlled = false

	# Position heroes in their beds (they're "waking up").
	# Set dojo_wait_pos to the same spot so _tick_dojo_wait doesn't fight us.
	if pl:
		pl.position = Vector2(290, -460)   # Shino's bed nook
		pl.dojo_wait_pos = pl.position
	if be:
		be.position = Vector2(600, -160)   # Bea's mat nook
		be.dojo_wait_pos = be.position

	# Wait a beat for the scene to settle
	await get_tree().create_timer(1.0).timeout

	# Shino wakes up
	var dlg1 := DB_SCRIPT.new_box(self)
	dlg1.open("Shino", [
		"*gasp* ...I'm awake. That dream...",
		"It was so real. The shadows, the fighting... Bea was there too.",
		"I need to find her — now!",
	])
	await dlg1.finished

	# Walk Shino out through his doorway, then toward center
	await _cutscene_walk_path(pl, [SHINO_DOOR_WP, Vector2(20, 40)])

	await get_tree().create_timer(0.3).timeout

	# Bea wakes up
	var dlg2 := DB_SCRIPT.new_box(self)
	dlg2.open("Bea", [
		"Shino?! You're here — I just had the wildest dream—",
	])
	await dlg2.finished

	# Walk Bea out through her doorway, then toward center
	await _cutscene_walk_path(be, [BEA_DOOR_WP, Vector2(60, 40)])

	# They bump into each other
	var dlg3 := DB_SCRIPT.new_box(self)
	dlg3.open("Shino", [
		"Wait — you had the dream too? The dark streets, the shadow monsters?",
	])
	await dlg3.finished

	var dlg4 := DB_SCRIPT.new_box(self)
	dlg4.open("Bea", [
		"YES! And we were fighting them together! I could feel the island's pain...",
		"It wasn't just a dream, Shino. Something is very wrong.",
	])
	await dlg4.finished

	var dlg5 := DB_SCRIPT.new_box(self)
	dlg5.open("Shino", [
		"We need to tell Sensei. Now.",
	])
	await dlg5.finished

	# Walk both to stand just south of Sensei Z (scene pos 0, -190)
	var shino_target := Vector2(-30, -120)   # south of Sensei, slightly left
	var bea_target   := Vector2(30, -120)    # south of Sensei, slightly right
	if pl:
		pl.dojo_wait_pos = shino_target
	if be:
		be.dojo_wait_pos = bea_target
	# Wait until both arrive
	while true:
		var pl_done: bool = (pl == null or not is_instance_valid(pl)
				or pl.global_position.distance_to(shino_target) <= 10.0)
		var be_done: bool = (be == null or not is_instance_valid(be)
				or be.global_position.distance_to(bea_target) <= 10.0)
		if pl_done and be_done:
			break
		await get_tree().physics_frame
	if is_instance_valid(pl):
		pl.position = shino_target
		pl.velocity = Vector2.ZERO
	if is_instance_valid(be):
		be.position = bea_target
		be.velocity = Vector2.ZERO

	await get_tree().create_timer(0.3).timeout

	# Sensei's response
	var dlg6 := DB_SCRIPT.new_box(self)
	dlg6.open("Sensei Z", [
		"...I know. I felt it too.",
		"A shadow has fallen over our island. The Dream World — the realm that mirrors our waking world — has been corrupted.",
		"What you experienced was no ordinary dream. You were fighting in the Dream World itself.",
	])
	await dlg6.finished

	var dlg7 := DB_SCRIPT.new_box(self)
	dlg7.open("Sensei Z", [
		"The corruption is spreading. I can feel it reaching into the waking world too.",
		"Before anything else — go outside. Check on the townspeople. Visit each part of the island.",
		"The guardian families who protect each biome... I fear the corruption has already reached them.",
	])
	await dlg7.finished

	var dlg8 := DB_SCRIPT.new_box(self)
	dlg8.open("Bea", [
		"The guardian families? You mean the Apple family, the Broccoli elders, the Coconut monks...?",
	])
	await dlg8.finished

	var dlg9 := DB_SCRIPT.new_box(self)
	dlg9.open("Sensei Z", [
		"All of them. Every family that tends to their corner of the island.",
		"Go through the front door and check on the town. Report back what you find.",
	])
	await dlg9.finished

	var dlg10 := DB_SCRIPT.new_box(self)
	dlg10.open("Shino", [
		"We're on it, Sensei!",
	])
	await dlg10.finished

	# After the cutscene — give the player a hint about going outside
	RunState.sensei_lore_tier = 1

	# Save progress
	var sm: Node = get_node_or_null("/root/SaveManager")
	if sm and sm.has_method("save_active_slot"):
		sm.save_active_slot()

	# Walk heroes to normal dojo positions + restore player control
	var final_shino := Vector2(-50, 0)
	var final_bea   := Vector2(50, 0)
	if pl:
		pl.dojo_wait_pos = final_shino
	if be:
		be.dojo_wait_pos = final_bea
	while true:
		var pd: bool = (pl == null or not is_instance_valid(pl)
				or pl.global_position.distance_to(final_shino) <= 10.0)
		var bd: bool = (be == null or not is_instance_valid(be)
				or be.global_position.distance_to(final_bea) <= 10.0)
		if pd and bd:
			break
		await get_tree().physics_frame
	if is_instance_valid(pl):
		pl.position = final_shino
		pl.velocity = Vector2.ZERO
		pl.dojo_wait_pos = SHINO_WAIT_POS
		pl.player_controlled = pl_was_controlled
	if is_instance_valid(be):
		be.position = final_bea
		be.velocity = Vector2.ZERO
		be.dojo_wait_pos = BEA_WAIT_POS
		be.player_controlled = be_was_controlled


func _setup_dojo_mode() -> void:
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		if "dojo_mode" in p:
			p.dojo_mode = true
			p.dojo_wait_pos = BEA_WAIT_POS if p.is_in_group("bea") else SHINO_WAIT_POS


# ============================================================
# Environment — procedural floor, walls, backdrop, decor (Run 72)
# ============================================================
func _build_environment() -> void:
	_build_backdrop()
	# Wooden plank floor across all three rooms; tatami where it matters.
	DT.build(self, [MAIN_RECT, SHINO_RECT, BEA_RECT], [
		{"rect": Rect2(-240, -40, 480, 280), "kind": "training"},  # central training mat
		{"rect": Rect2(255, -520, 170, 150), "kind": "tan"},        # Shino's sleeping nook
		{"rect": Rect2(555, -205, 170, 150), "kind": "tan"},        # Bea's sleeping nook
	], 4242)
	_build_walls()
	_build_wall_faces()
	_build_decor()
	_build_front_door()


# Run 117 — the front door in the SOUTH wall: the Dojo's exit into the
# waking-world Town Square (the Dojo is the square's central landmark).
func _build_front_door() -> void:
	var door := Node2D.new()
	door.name = "FrontDoor"
	door.position = Vector2(0, 280)   # centered on the south wall
	add_child(door)

	# Door slab over the wall + threshold mat.
	var slab := ColorRect.new()
	slab.offset_left = -26
	slab.offset_top = -20
	slab.offset_right = 26
	slab.offset_bottom = 18
	slab.color = Color(0.16, 0.11, 0.08)
	slab.z_index = 1
	door.add_child(slab)
	var mat_rect := ColorRect.new()
	mat_rect.offset_left = -30
	mat_rect.offset_top = -50
	mat_rect.offset_right = 30
	mat_rect.offset_bottom = -22
	mat_rect.color = Color(0.50, 0.38, 0.24)
	mat_rect.z_index = -3
	door.add_child(mat_rect)

	var lbl := Label.new()
	lbl.text = "Front Door — Town Square"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.modulate = Color(0.80, 0.72, 0.52)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-80, -74)
	lbl.custom_minimum_size = Vector2(160, 0)
	door.add_child(lbl)

	_front_door_prompt = Label.new()
	InputGlyphs.bind_label(_front_door_prompt, "[{interact}]  Step out to the Town Square")   # Run 158
	_front_door_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_front_door_prompt.add_theme_font_size_override("font_size", 13)
	_front_door_prompt.modulate = Color(1.0, 0.95, 0.50, 1)
	_front_door_prompt.position = Vector2(-110, -98)
	_front_door_prompt.custom_minimum_size = Vector2(220, 0)
	_front_door_prompt.visible = false
	door.add_child(_front_door_prompt)

	var zone := Area2D.new()
	zone.collision_layer = 0
	zone.collision_mask = 2
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 64.0
	cs.shape = shape
	zone.add_child(cs)
	door.add_child(zone)
	zone.body_entered.connect(_on_bed_entered.bind(_near_front_door))
	zone.body_exited.connect(_on_bed_exited.bind(_near_front_door))


func _build_backdrop() -> void:
	# Dark "outside the building" so the void past the walls reads as shadow.
	var bg := ColorRect.new()
	bg.name = "Backdrop"
	bg.z_index = -50
	bg.color = Color(0.05, 0.045, 0.035)
	bg.offset_left = -760.0
	bg.offset_top = -760.0
	bg.offset_right = 1020.0
	bg.offset_bottom = 520.0
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)


func _build_walls() -> void:
	var walls := Node2D.new()
	walls.name = "Walls"
	add_child(walls)
	# (center, size). Two door gaps: north wall x[320,400] (to Shino's room),
	# east wall y[-220,-140] (to Bea's room).
	var segs: Array = [
		# Main hall — north wall split around Shino's doorway.
		[Vector2(-80, -280), Vector2(800, WALL_T)],   # x[-480,320]
		[Vector2(440, -280), Vector2(80, WALL_T)],    # x[400,480]
		# Main hall — south + west.
		[Vector2(0, 280),    Vector2(960, WALL_T)],
		[Vector2(-480, 0),   Vector2(WALL_T, 560)],
		# Main hall — east wall split around Bea's doorway.
		[Vector2(480, -250), Vector2(WALL_T, 60)],    # y[-280,-220]
		[Vector2(480, 70),   Vector2(WALL_T, 420)],   # y[-140,280]
		# Shino's north room — west / north / east.
		[Vector2(180, -420), Vector2(WALL_T, 280)],
		[Vector2(330, -560), Vector2(332, WALL_T)],
		[Vector2(480, -420), Vector2(WALL_T, 280)],
		# Bea's east room — north / east / south.
		[Vector2(620, -280), Vector2(280, WALL_T)],
		[Vector2(760, -140), Vector2(WALL_T, 280)],
		[Vector2(620, 0),    Vector2(280, WALL_T)],
	]
	for s in segs:
		_make_wall(walls, s[0], s[1])

	# Run 154 — bracket sprites at wall junctions. Run 162: every call passes the
	# INTERSECTION OF THE TWO WALL CENTRELINES; WoodScaffolding anchors the piece
	# by its ARMS so the joint beams continue the rails exactly.
	# "tl" = walls extend right + down; "tr" = left + down;
	# "bl" = right + up; "br" = left + up.
	# Main hall corners:
	WS.place_corner(walls, Vector2(-480, -280), "tl", -6)   # NW
	WS.place_corner(walls, Vector2(-480,  280), "bl", -6)   # SW
	WS.place_corner(walls, Vector2( 480,  280), "br", -6)   # SE
	# Shino's north room corners:
	WS.place_corner(walls, Vector2( 180, -560), "tl", -6)   # NW (wall 7 top meets wall 8 left)
	WS.place_corner(walls, Vector2( 480, -560), "tr", -6)   # NE (wall 8 right meets wall 9 top)
	# Bea's east room corners:
	WS.place_corner(walls, Vector2( 760, -280), "tr", -6)   # NE (wall 10 right meets wall 11 top)
	WS.place_corner(walls, Vector2( 760,    0), "br", -6)   # SE (wall 12 right meets wall 11 bottom)

	# Run 162 — the two junctions that are NOT simple L-corners.
	# (480,-280): the main hall's NE is really a 4-WAY crossing — the north wall
	# runs on east into Bea's room, the east wall runs on north into Shino's.
	# It used to wear a "tr" elbow, which read as a broken corner.
	WS.place_cross(walls, Vector2( 480, -280), -6)
	# (180,-280): Shino's west wall drops onto the main north wall, which keeps
	# running both ways past it — a TEE with the branch going up.
	WS.place_tee(walls, Vector2( 180, -280), "up", -6)


func _make_wall(parent: Node, pos: Vector2, size: Vector2) -> void:
	# Run 154 — visuals replaced with real Wood_Scaffolding art (tiled planks +
	# posts). Collision is UNCHANGED (still WALL_T thick).
	# z=-6: over floor bake (-30) and wall faces (-12), under decor (-1+).
	var w := StaticBody2D.new()
	w.position = pos
	w.collision_layer = 1
	w.collision_mask = 0
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = size
	cs.shape = shape
	w.add_child(cs)
	var vis_root := Node2D.new()
	w.add_child(vis_root)
	WS.dress_wall(vis_root, size, -6)
	parent.add_child(w)


# ---------------------------------------------------------------------------
# Run 145 — real NORTH WALL faces from the Dojo Tileset wall auto-tile
# (Assets/Tilesets/Dojo_props/wall/). Each run bakes one Sprite2D: a feature
# section (tokonoma alcove behind Sensei Z, arched windows in the bedrooms)
# centered on its landmark, the rest filled with shoji screens / plaster /
# posts. Faces rise INTO the void above each room's top edge, so nothing
# overlaps the walkable floor.
#
# Run 171 — the baker itself (and the Run 163b padding LOCK) now lives in
# DojoWallArt.gd, shared with the Cake Dojo summit room so the two can never
# drift apart. Only the art folder differs between them.
# ---------------------------------------------------------------------------
func _build_wall_faces() -> void:
	var host := Node2D.new()
	host.name = "WallFaces"
	host.z_index = -12   # over the floor bake (-30), under all decor (-1)
	add_child(host)
	# Main hall north wall — tokonoma alcove centered behind Sensei Z (x=0).
	WA.bake_run(host, -480.0, 180.0, -280.0, "wall_alcove", 0.0)
	# Shino's room north wall — arched window over his sleeping nook.
	WA.bake_run(host, 180.0, 480.0, -560.0, "wall_arch", 330.0)
	# Bea's room north wall — matching arched window.
	WA.bake_run(host, 480.0, 760.0, -280.0, "wall_arch", 620.0)


# Run 143 — real spliced art (Assets/Tilesets/Dojo_props/) replaces the old
# ColorRect placeholders. Scene fixtures to respect: TrainingDummy (-340,-180),
# BoonDispenser (-200,-228), SenseiZ (0,-190), ShinoBed (340,-450),
# BeaBed (640,-130), front door (0,280), training mat rect (-240,-40,480,280).
# Run 145 — wall hangings moved UP onto the baked wall faces (foot y above
# the room's top edge) so they hang cleanly on the wall, not over the floor.
func _build_decor() -> void:
	var deco := Node2D.new()
	deco.name = "Decor"
	add_child(deco)

	# ── Main hall, north wall hangings (west → east) — on the wall FACE
	# (face spans y[-440,-280]; the alcove sits x[-60,60] behind Sensei) ──
	_deco(deco, "scroll_kanji_a", Vector2(-420, -300), 64.0)
	_hang_paper_lantern(deco, Vector2(-310, -336), 56.0)
	_deco(deco, "scroll_dragon", Vector2(-140, -292), 112.0)   # place of honor by Sensei
	_deco(deco, "scroll_kanji_b", Vector2(100, -300), 64.0)
	_hang_paper_lantern(deco, Vector2(155, -336), 56.0)
	_deco(deco, "rack_katana_a", Vector2(255, -240), 58.0)

	# Run 163b — light energies dimmed ~28% from the first pass: this is an
	# INDOOR dojo lit by paper and stone lanterns, not a lit street. Breath
	# depth raised in exchange, so they read as candlelight rather than bulbs.
	# ── Main hall, west wall ──
	_deco(deco, "lantern_stone_a", Vector2(-445, -130), 52.0)
	GlowLight.attach(deco, Vector2(-445, -168), GlowLight.WARM_STONE, 118.0, 0.50, 0.12)
	_deco(deco, "bamboo_a", Vector2(-445, -40), 86.0)
	_deco(deco, "bamboo_c", Vector2(-445, 60), 78.0)

	# ── Main hall, east wall (around Bea's doorway gap y[-220,-140]) ──
	_deco(deco, "banner_map", Vector2(450, -70), 62.0)
	_deco(deco, "lantern_stone_c", Vector2(447, 110), 52.0)
	GlowLight.attach(deco, Vector2(447, 72), GlowLight.WARM_STONE, 118.0, 0.50, 0.12)
	_deco(deco, "bamboo_cut_a", Vector2(450, 215), 66.0)

	# ── SW tea corner ──
	_deco(deco, "table_low_b", Vector2(-360, 195), 46.0)
	_deco_collide(deco, Vector2(-360, 190), 16.0)
	_deco(deco, "cushion_b", Vector2(-425, 200), 20.0, -25)
	_deco(deco, "cushion_c", Vector2(-298, 200), 20.0, -25)
	_deco(deco, "go_board", Vector2(-362, 248), 32.0, -25)

	# ── SE zen garden corner ──
	_deco(deco, "zen_sand_a", Vector2(390, 212), 88.0, -25)
	_deco(deco, "lantern_stone_d", Vector2(448, 180), 54.0)
	GlowLight.attach(deco, Vector2(448, 141), GlowLight.WARM_STONE, 118.0, 0.50, 0.12)
	_deco(deco, "bonsai_f", Vector2(336, 228), 56.0)

	# ── Hall floor accents ──
	_deco(deco, "brazier", Vector2(-262, 62), 50.0)
	GlowLight.attach(deco, Vector2(-262, 26), GlowLight.EMBER, 180.0, 0.88, 0.20)
	_deco_collide(deco, Vector2(-262, 58), 13.0)
	_deco(deco, "rug_red", Vector2(0, 236), 42.0, -25)        # front-door mat
	_deco(deco, "trap_door", Vector2(285, -246), 44.0, -25)   # ninja secret, NE corner

	# ── Shino's room (north) — kanji scrolls hang on his wall face
	# (face y[-720,-560], arched window at x[289,371]) ──
	_deco(deco, "scroll_kanji_c", Vector2(225, -568), 64.0)
	_deco(deco, "scroll_kanji_e", Vector2(430, -568), 64.0)
	_deco(deco, "rack_stand", Vector2(448, -482), 72.0)
	_deco(deco, "bedroll_a", Vector2(340, -432), 64.0, -25)   # on the sleeping tatami
	_deco(deco, "lantern_stone_b", Vector2(212, -372), 50.0)
	GlowLight.attach(deco, Vector2(212, -409), GlowLight.WARM_STONE, 118.0, 0.50, 0.12)
	_deco(deco, "bonsai_d", Vector2(215, -318), 52.0)

	# ── Bea's room (east) — scrolls flank her arched window (x[579,661]) ──
	_deco(deco, "scroll_kanji_d", Vector2(543, -288), 62.0)
	_deco(deco, "scroll_kanji_f", Vector2(700, -288), 62.0)
	_deco(deco, "rug_green", Vector2(640, -118), 58.0, -26)   # under her bed mat
	_deco(deco, "bedroll_a", Vector2(640, -122), 60.0, -25)
	_deco(deco, "table_low_c", Vector2(560, -42), 42.0)
	_deco(deco, "cushion_a", Vector2(514, -26), 20.0, -25)
	_deco(deco, "bonsai_b", Vector2(735, -42), 56.0)


# ---------------------------------------------------------------------------
# Run 143 — Dojo_props art loader + placement helpers
# ---------------------------------------------------------------------------
const DOJO_ART_DIR: String = "res://Assets/Tilesets/Dojo_props/"
var _art_cache: Dictionary = {}

func _art_tex(name: String) -> ImageTexture:
	if _art_cache.has(name):
		var c = _art_cache[name]
		return c if c is ImageTexture else null
	var p: String = DOJO_ART_DIR + name + ".png"
	var img: Image = null
	if ResourceLoader.exists(p):
		var r: Resource = ResourceLoader.load(p)
		if r is Texture2D:
			img = (r as Texture2D).get_image()
	if img == null:
		var abs_path: String = ProjectSettings.globalize_path(p)
		if FileAccess.file_exists(abs_path):
			var im := Image.new()
			if im.load(abs_path) == OK:
				img = im
	if img == null:
		push_warning("[Dojo] Missing decor art: %s" % p)
		_art_cache[name] = false
		return null
	img.convert(Image.FORMAT_RGBA8)
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_art_cache[name] = tex
	return tex


# Foot-anchored decor sprite. z=-1 keeps standing props under the heroes
# (old placeholder behavior); z=-25/-26 for flat floor pieces (rugs, mats).
func _deco(parent: Node, name: String, foot: Vector2, world_h: float, z: int = -1) -> Sprite2D:
	var tex: ImageTexture = _art_tex(name)
	if tex == null:
		return null
	var s: float = world_h / float(tex.get_height())
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.scale = Vector2(s, s)
	spr.position = foot + Vector2(0, -world_h * 0.5)
	spr.z_index = z
	parent.add_child(spr)
	return spr


func _deco_collide(parent: Node, pos: Vector2, r: float) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = pos
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = r
	cs.shape = shape
	body.add_child(cs)
	parent.add_child(body)


# Hanging paper lantern. Run 163 — this used to swap between lantern_paper_f0
# and _f1 on a 0.65s Timer, which read as the texture popping between two
# different lanterns rather than as a flame. LOCK: the SPRITE IS STATIC. The
# "flicker" is a real PointLight2D (GlowLight) breathing its energy, and the
# halo that used to be baked into the PNG as a khaki disc was stripped out of
# lantern_paper_f0.png in the same run. See scripts/GlowLight.gd.
func _hang_paper_lantern(parent: Node, foot: Vector2, world_h: float) -> void:
	var spr: Sprite2D = _deco(parent, "lantern_paper_f0", foot, world_h)
	if spr == null:
		return
	# NOTE: parented to `parent`, NOT to `spr` — decor sprites carry a scale
	# and a light under one would inherit it (halo silently shrinks).
	GlowLight.attach(parent, foot + Vector2(0.0, -world_h * 0.52),
		GlowLight.WARM_PAPER, 158.0, 0.76, 0.16)


func _on_bed_entered(body: Node, bucket: Array) -> void:
	if not body.is_in_group("player"):
		return
	if not bucket.has(body):
		bucket.append(body)


func _on_bed_exited(body: Node, bucket: Array) -> void:
	bucket.erase(body)


# Whichever character the human is currently driving (Shino or Bea).
func _controlled_char() -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and "player_controlled" in p and bool(p.player_controlled):
			return p
	return null


func _process(_delta: float) -> void:
	if _sleeping or _leaving:
		return
	# Re-evaluated every frame: a hot-swap can happen while standing
	# inside a bed zone, so prompts follow the CONTROLLED character.
	var c: Node = _controlled_char()
	if shino_bed_prompt:
		shino_bed_prompt.visible = (c != null and _near_shino_bed.has(c))
	if bea_bed_prompt:
		bea_bed_prompt.visible = (c != null and _near_bea_bed.has(c))
	if _front_door_prompt:
		_front_door_prompt.visible = (c != null and _near_front_door.has(c))


func _unhandled_input(event: InputEvent) -> void:
	if _sleeping or _leaving:
		return
	if not event.is_action_pressed("interact") or event.is_echo():
		return
	var c: Node = _controlled_char()
	if c == null:
		return
	if _near_shino_bed.has(c):
		_start_sleep(c, shino_bed_prompt)
	elif _near_bea_bed.has(c):
		_start_sleep(c, bea_bed_prompt)
	elif _near_front_door.has(c):
		_leave_to_town()


# Run 117 — out the front door into the waking-world Town Square.
func _leave_to_town() -> void:
	_leaving = true
	RunState.day_spawn_hint = "from_dojo"
	Log.dbg("[Dojo] Stepping out to the Town Square.")
	FX.fade_to_black(0.4, 0.05, 1.0, Callable(self, "_goto_town_square"))


func _goto_town_square() -> void:
	if not ResourceLoader.exists(TOWN_SQUARE_PATH):
		push_error("[Dojo] TownSquare scene not found at: %s" % TOWN_SQUARE_PATH)
		_leaving = false
		return
	get_tree().change_scene_to_file(TOWN_SQUARE_PATH)


# Run 43 — sleep destination chosen on the bed:
#   DREAM WORLD  → the real adventure (Town Square hub, 5 biomes, finale)
#   DREAM ARENA  → training mode (the original Arena1-20 chain, no sparks)
var _dream_target: String = ""
var _choice_layer: CanvasLayer = null

func _start_sleep(controlled: Node, prompt: Label) -> void:
	_show_dream_choice(controlled, prompt)


func _show_dream_choice(controlled: Node, prompt: Label) -> void:
	_sleeping = true   # block re-trigger while the menu is up
	_choice_layer = CanvasLayer.new()
	_choice_layer.layer = 55
	# Freeze both heroes (and everything else) while the menu is up so the
	# player can't wander the dojo while picking. The layer (and its children)
	# runs while paused so its buttons stay interactive.
	_choice_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_choice_layer)
	get_tree().paused = true

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.06, 0.65)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_choice_layer.add_child(dim)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(420, 0)
	box.add_theme_constant_override("separation", 14)
	_choice_layer.add_child(box)

	var title := Label.new()
	title.text = "Where will the dream take you?"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var world_btn := Button.new()
	world_btn.text = "🌙 DREAM WORLD\nThe real fight — cleanse the five biomes of Starfruit Island"
	var arena_btn := Button.new()
	arena_btn.text = "🥋 DREAM ARENA\nTraining mode — the endless arena gauntlet (no Dragon Souls)"
	var cancel_btn := Button.new()
	cancel_btn.text = "Stay awake"
	for b in [world_btn, arena_btn, cancel_btn]:
		b.add_theme_font_size_override("font_size", 16)
		box.add_child(b)

	# WASD / left-stick navigation (arrows + D-pad already work via the built-in
	# focus chain; Enter / gamepad A confirm the focused button natively).
	var nav := preload("res://scripts/MenuFocusNav.gd").new()
	_choice_layer.add_child(nav)
	nav.buttons = [world_btn, arena_btn, cancel_btn]
	# B / Esc backs out — same as choosing "Stay awake".
	nav.on_cancel = func():
		_close_choice()
		_sleeping = false

	world_btn.pressed.connect(func():
		RunState.dream_world_mode = true
		_dream_target = DREAM_HUB_PATH
		_close_choice()
		_begin_sleep_cinematic(controlled, prompt))
	arena_btn.pressed.connect(func():
		RunState.dream_world_mode = false
		_dream_target = ARENA1_PATH
		_close_choice()
		_begin_sleep_cinematic(controlled, prompt))
	cancel_btn.pressed.connect(func():
		_close_choice()
		_sleeping = false)
	world_btn.grab_focus()


func _close_choice() -> void:
	# Unpause BEFORE any sleep cinematic runs — the cinematic relies on
	# SceneTreeTimers and tweens, which don't advance while the tree is paused.
	get_tree().paused = false
	if _choice_layer:
		_choice_layer.queue_free()
		_choice_layer = null


func _begin_sleep_cinematic(controlled: Node, prompt: Label) -> void:
	if prompt:
		prompt.text = "Zzz..."
		prompt.visible = true

	# Run 39 — if the Boon Dispenser handed out any sandbox boons this visit,
	# wipe them now so test builds never carry into a real run. Must happen
	# BEFORE the carry flag below (reset_run clears carry_player_controlled_char).
	if RunState.dojo_sandbox_used:
		RunState.reset_run()

	# Carry the controlled character into the run — whoever falls asleep
	# in control wakes up in control in the dream world.
	RunState.carry_player_controlled_char = 1 if controlled.is_in_group("bea") else 0

	# Brief pause then fade out with dream text.
	await get_tree().create_timer(0.4).timeout

	# Overlay "You drift off to sleep..." text on the fade.
	var canvas := CanvasLayer.new()
	canvas.layer = 60
	add_child(canvas)
	var dream_label := Label.new()
	dream_label.text = "You drift off to sleep..."
	dream_label.add_theme_font_size_override("font_size", 32)
	dream_label.add_theme_color_override("font_color", Color(0.85, 0.85, 1.0, 0.0))
	dream_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dream_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	dream_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(dream_label)

	# Fade text in.
	var tw1: Tween = create_tween()
	tw1.tween_property(dream_label, "modulate:a", 1.0, 0.6)
	await tw1.finished

	await get_tree().create_timer(0.8).timeout

	# Fade to black + load arena.
	FX.fade_to_black(0.6, 0.1, 0.5, Callable(self, "_load_arena"))


func _load_arena() -> void:
	# Run 136 — route through the Night Loading Screen so the player sees the
	# Night Start art before the dream begins. The NightLoadScreen reads
	# RunState.dream_world_mode to decide whether to go to DreamHub or Arena.
	if ResourceLoader.exists(NIGHT_LOAD_SCREEN_PATH):
		get_tree().change_scene_to_file(NIGHT_LOAD_SCREEN_PATH)
		return
	# Fallback: skip loading screen if scene is missing.
	var target: String = _dream_target if _dream_target != "" else ARENA1_PATH
	if not ResourceLoader.exists(target):
		push_error("[Dojo] Dream scene not found at: %s" % target)
		return
	get_tree().change_scene_to_file(target)
