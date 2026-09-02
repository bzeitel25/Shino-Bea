extends Node2D

# ============================================================
# ShadowSenseiArena.gd — Run 43 (2026-06-10) — Summit duel
# ============================================================
# Top of the Dragon Cake Fortress.
#
# Run 171 — THE SUMMIT IS THE DOJO. The flat ColorRect box is gone;
# the room is now built by CakeDojoRoom.gd, which is Shino & Bea's
# own dojo rebuilt in sugar: identical footprint, identical walls and
# doorways, identical decor placements, every prop swapped for its
# Cake-Dojo twin. Shadow Sensei Z waits in the shrine alcove at the
# exact spot where the real Sensei Z sits at home (0,-190), and the
# heroes walk in through the south end where their own front door is.
# Geometry contract (shared with Dojo.gd):
#     main hall  x[-480,480] y[-280,280]
#     Shino's    x[ 180,480] y[-560,-280]
#     Bea's      x[ 480,760] y[-280,   0]
#
# Flow:
#   1. Heroes arrive — calm summit, no enemies.
#   2. A FINAL JUICE pickup sits mid-arena (last heal — [E], free).
#   3. Walking into the challenge zone (top-center) spawns
#      SHADOW SENSEI Z — placeholder kit: the proven Boss.tscn
#      (Shadow Commander 3-phase AI) buffed and renamed, tinted
#      shadow-purple. Swap in a bespoke moveset later.
#   4. Victory → +3 Dragon Souls → RunComplete.
#
# GDD §9.5: Phase-2 "duel mirroring the player's own kit" comes
# when the real Shadow Sensei moveset is built.
# ============================================================

# Run 171 — the summit room: a cake-dessert replica of the Dojo.
const ROOM = preload("res://scripts/CakeDojoRoom.gd")

const BOSS_SCENE_PATH: String = "res://scenes/Boss.tscn"
const RUN_COMPLETE_PATH: String = "res://scenes/RunComplete.tscn"

# Run 71 — Shadow Sensei Z now wears Bruno's hand-animated GIF. The .gif was
# keyed (cream background flood-filled to transparent) and packed into a
# 7-frame horizontal sheet; the fiery aura is baked into the frames.
const SENSEI_SHEET_PATH: String = "res://Assets/Sprites/sensei_z_sheet.png"
const SENSEI_FRAME_W: int   = 56
const SENSEI_FRAME_H: int   = 75
const SENSEI_FRAMES: int    = 7
const SENSEI_SCALE: float   = 1.9
const SENSEI_FPS: float     = 6.667   # GIF was 150ms/frame
const POLL_INTERVAL: float = 0.30
const VICTORY_HOLD: float = 2.6
const VICTORY_SPARKS: int = 1   # Run 45 spark economy — 1 per boss, everywhere

# Landmarks inside the cake dojo (world coords, mirroring the real one).
const SENSEI_SEAT: Vector2 = Vector2(0, -190)    # where Sensei Z sits back home
const JUICE_SPOT: Vector2 = Vector2(0, 60)       # centre of the training mat

var _boss_alive: bool = false
var _fight_started: bool = false
var _victory_started: bool = false
var _poll_timer: float = 0.0
var _heal_taken: bool = false
var _heal_in_range: bool = false
var _heal_node: Node2D = null
var _challenge_zone: Area2D = null

@onready var banner: Label = $DebugHUD/BannerLabel


func _ready() -> void:
	# Final-fight theme (Assets/Music/SenseiZ_FinalFight/).
	MusicManager.play_area("sensei")
	_build_arena()
	_build_heal_pickup()
	_build_challenge_zone()
	if banner:
		banner.text = "THE SUMMIT — YOUR OWN DOJO, IN SUGAR\nTake the final Juice, then step into the shadow..."
	FX.fade_from_black(0.6)


func _build_arena() -> void:
	# One call — floor bake, walls + scaffolding joints, north-wall faces and
	# the full decor pass, all from CakeDojo_props. See CakeDojoRoom.gd.
	ROOM.build(self)


func _build_heal_pickup() -> void:
	_heal_node = Node2D.new()
	_heal_node.name = "FinalJuice"
	_heal_node.position = JUICE_SPOT
	add_child(_heal_node)

	var icon := Label.new()
	icon.text = "🧃"
	icon.add_theme_font_size_override("font_size", 48)
	icon.position = Vector2(-24, -40)
	_heal_node.add_child(icon)

	var lbl := Label.new()
	InputGlyphs.bind_label(lbl, "[{interact}] FINAL JUICE — full restock before the duel")   # Run 158
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.40, 0.85, 0.95))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.position = Vector2(-160, 18)
	_heal_node.add_child(lbl)

	var zone := Area2D.new()
	zone.collision_layer = 0
	zone.collision_mask = 2
	var shape := CircleShape2D.new()
	shape.radius = 64.0
	var cs := CollisionShape2D.new()
	cs.shape = shape
	zone.add_child(cs)
	zone.body_entered.connect(func(body: Node):
		if body.is_in_group("player"):
			_heal_in_range = true)
	zone.body_exited.connect(func(body: Node):
		if body.is_in_group("player"):
			_heal_in_range = false)
	_heal_node.add_child(zone)


func _build_challenge_zone() -> void:
	_challenge_zone = Area2D.new()
	_challenge_zone.name = "ChallengeZone"
	_challenge_zone.position = SENSEI_SEAT
	_challenge_zone.collision_layer = 0
	_challenge_zone.collision_mask = 2
	var shape := RectangleShape2D.new()
	shape.size = Vector2(260, 110)
	var cs := CollisionShape2D.new()
	cs.shape = shape
	_challenge_zone.add_child(cs)
	add_child(_challenge_zone)

	var marker := Label.new()
	marker.text = "👤 someone is sitting in Sensei's place..."
	marker.add_theme_font_size_override("font_size", 15)
	marker.add_theme_color_override("font_color", Color(0.75, 0.45, 0.90))
	marker.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	marker.add_theme_constant_override("outline_size", 3)
	marker.position = Vector2(-110, -16)
	_challenge_zone.add_child(marker)

	_challenge_zone.body_entered.connect(func(body: Node):
		if not _fight_started and body.is_in_group("player"):
			_start_fight())


func _unhandled_input(event: InputEvent) -> void:
	if _heal_taken or not _heal_in_range:
		return
	if event.is_action_pressed("interact") and not event.is_echo():
		_heal_taken = true
		var healed: int = RunState.grant_apple_juice(get_tree())
		if banner:
			banner.text = "🧃 Restored (+%d HP). No more holding back." % healed
		FX.spawn_burst_particles(_heal_node.global_position, Color(0.30, 0.80, 0.95), 24)
		FX.play_sound("apple_pie_eat", 1.0)
		_heal_node.queue_free()


func _start_fight() -> void:
	_fight_started = true
	if _challenge_zone:
		_challenge_zone.queue_free()
	if not _heal_taken and _heal_node and is_instance_valid(_heal_node):
		_heal_node.queue_free()   # the duel begins — the offer expires
	if not ResourceLoader.exists(BOSS_SCENE_PATH):
		push_error("[ShadowSenseiArena] Boss.tscn missing — cannot spawn Shadow Sensei Z.")
		return
	var boss: Node = (load(BOSS_SCENE_PATH) as PackedScene).instantiate()
	# Placeholder buff pass: Shadow Commander kit, Sensei Z scale.
	boss.set("max_hp", 1500)
	boss.set("move_speed", 75.0)
	boss.set("phase2_speed", 95.0)
	boss.set("phase3_speed", 125.0)
	var nm: Label = boss.get_node_or_null("NameLabel") as Label
	if nm:
		nm.text = "Shadow Sensei Z"
	# Run 71 — swap the placeholder purple square for the animated GIF sprite
	# (meditating master + fiery aura). Falls back to the tinted box if the
	# sheet hasn't imported yet.
	_attach_sensei_sprite(boss)
	add_child(boss)
	if boss is Node2D:
		(boss as Node2D).global_position = SENSEI_SEAT
	_boss_alive = true
	_poll_timer = POLL_INTERVAL
	if banner:
		banner.text = "⚔️ SHADOW SENSEI Z ⚔️\n\"You carry my teachings... let's see if you understood them.\""
	FX.screen_shake(FX.SHAKE_LIGHT, 0.4)
	Log.dbg("[ShadowSenseiArena] Shadow Sensei Z spawned.")


# Run 71 — build an AnimatedSprite2D from the keyed GIF sheet and hang it on
# the boss. The flame aura is part of the art, so no extra particles needed.
# The boss's separate "Sprite" flash overlay and ground danger-circles still
# drive hit/telegraph feedback, so hiding the placeholder "Body" is safe.
func _attach_sensei_sprite(boss: Node) -> void:
	if not ResourceLoader.exists(SENSEI_SHEET_PATH):
		push_warning("[ShadowSenseiArena] sensei_z_sheet.png not imported yet — keeping placeholder body. Open the Godot editor once to import it.")
		var body_fallback: Node = boss.get_node_or_null("Body")
		if body_fallback and body_fallback is CanvasItem:
			(body_fallback as CanvasItem).modulate = Color(0.55, 0.30, 0.75)
		return

	var tex: Texture2D = load(SENSEI_SHEET_PATH) as Texture2D
	if tex == null:
		return

	var sf := SpriteFrames.new()
	sf.remove_animation("default")
	sf.add_animation("blaze")
	sf.set_animation_loop("blaze", true)
	sf.set_animation_speed("blaze", SENSEI_FPS)
	for i in range(SENSEI_FRAMES):
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(i * SENSEI_FRAME_W, 0, SENSEI_FRAME_W, SENSEI_FRAME_H)
		sf.add_frame("blaze", at)

	var anim := AnimatedSprite2D.new()
	anim.name = "SenseiZSprite"
	anim.sprite_frames = sf
	anim.animation = "blaze"
	anim.centered = true
	anim.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp pixels
	anim.scale = Vector2(SENSEI_SCALE, SENSEI_SCALE)
	# Character base sits at frame-y 61 (center 37.5) → +23.5px below center;
	# nudge up so the seated figure grounds near the boss origin and the flame
	# towers above. z_index -1 keeps the name/HP labels and flash overlay on top.
	anim.position = Vector2(0, -17)
	anim.z_index = -1
	boss.add_child(anim)
	anim.play("blaze")

	# Hide the placeholder purple square; the GIF is the body now.
	var body_rect: Node = boss.get_node_or_null("Body")
	if body_rect and body_rect is CanvasItem:
		(body_rect as CanvasItem).visible = false


func _process(delta: float) -> void:
	if not _boss_alive or _victory_started:
		return
	_poll_timer -= delta
	if _poll_timer <= 0.0:
		_poll_timer = POLL_INTERVAL
		if get_tree().get_nodes_in_group("enemy").is_empty():
			_boss_alive = false
			_on_victory()


func _on_victory() -> void:
	if _victory_started:
		return
	_victory_started = true
	RunState.dragon_souls += VICTORY_SPARKS
	# Run 143 — Perfect-Town gate: the full ending has been beaten on this save.
	RunState.full_ending_beaten = true
	if banner:
		banner.text = "✦ THE SHADOW LIFTS ✦\n🐉 +%d Dragon Souls (%d total) — the island sleeps easy tonight." % [
			VICTORY_SPARKS, RunState.dragon_souls]
	Log.dbg("[ShadowSenseiArena] Shadow Sensei Z defeated — run WON. +%d sparks." % VICTORY_SPARKS)
	# Run 70 — clear the resume path BEFORE this save so the few seconds of
	# victory-hold + fade (before RunComplete loads and fully finalizes) can't be
	# closed-then-relaunched back into this duel to re-farm the spark. From the
	# instant the boss dies, the saved run no longer points here.
	RunState.resume_scene_path = ""
	if get_node_or_null("/root/SaveManager") and SaveManager.active_slot >= 0:
		SaveManager.save_active_slot()
	await get_tree().create_timer(VICTORY_HOLD).timeout
	FX.fade_to_black(0.8, 0.2, 1.0, Callable(self, "_goto_complete"))


func _goto_complete() -> void:
	get_tree().change_scene_to_file(RUN_COMPLETE_PATH)
