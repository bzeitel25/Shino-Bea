extends Control

# ============================================================
# CakeAscend.gd — Run 43 (2026-06-10) — Finale ascent load screen
# ============================================================
# Shown between the Town Square and the Cake climb. Displays the
# Dragon Cake Fortress floating above Starfruit Island.
#
# ART SLOT: drop the fortress art at
#     res://Assets/Loading Screens/Cake Dragon Fortress.png
# and it auto-fills the screen. Until then a drawn placeholder
# (pastel sky + cake silhouette text) stands in.
# ============================================================

const DREAM_ROOM_PATH: String = "res://scenes/DreamRoom.tscn"
const ART_PATH: String = "res://Assets/Loading Screens/Cake Dragon Fortress.png"
const HOLD_SECONDS: float = 4.0

func _ready() -> void:
	RunState.current_biome = "cake"
	RunState.biome_room = 1
	# Cake Fortress theme (Assets/Music/CakeDragon_Climb/) — also carries into the
	# climb rooms, since DreamRoom plays the "cake" playlist too.
	MusicManager.play_area("cake")
	_build_screen()
	FX.fade_from_black(0.8)
	await get_tree().create_timer(HOLD_SECONDS).timeout
	FX.fade_to_black(0.8, 0.1, 1.0, Callable(self, "_goto_climb"))


func _goto_climb() -> void:
	get_tree().change_scene_to_file(DREAM_ROOM_PATH)


func _build_screen() -> void:
	# Pastel sunset sky backdrop (placeholder-friendly).
	var sky := ColorRect.new()
	sky.color = Color(0.62, 0.58, 0.78)
	# NOTE: `anchors_preset` is an editor-only property — assigning it from code
	# is a silent no-op (Run 137 grey-screen bug). Use the real method instead.
	sky.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(sky)
	var band := ColorRect.new()
	band.color = Color(0.85, 0.65, 0.75, 0.55)
	band.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	band.anchor_top = 0.55
	add_child(band)

	# Fortress art if present, otherwise a placeholder silhouette.
	var tex: Texture2D = null
	if ResourceLoader.exists(ART_PATH):
		tex = load(ART_PATH)
	elif FileAccess.file_exists(ART_PATH):
		var img := Image.load_from_file(ART_PATH)
		if img:
			tex = ImageTexture.create_from_image(img)
	if tex:
		var rect := TextureRect.new()
		rect.texture = tex
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(rect)
	else:
		var cake := Label.new()
		cake.text = "🍰🐉"
		cake.add_theme_font_size_override("font_size", 120)
		cake.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		cake.offset_top = -130.0
		add_child(cake)

	var title := Label.new()
	title.text = "THE DRAGON CAKE FORTRESS"
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(1.0, 0.95, 0.98))
	title.add_theme_color_override("font_outline_color", Color(0.25, 0.10, 0.20))
	title.add_theme_constant_override("outline_size", 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	title.offset_top = -150.0
	title.offset_left = -400.0
	title.offset_right = 400.0
	add_child(title)

	var sub := Label.new()
	sub.text = "Ascending above Starfruit Island...\nEvery biome's corruption flows from this place."
	sub.add_theme_font_size_override("font_size", 18)
	sub.add_theme_color_override("font_color", Color(0.95, 0.90, 1.0, 0.9))
	sub.add_theme_color_override("font_outline_color", Color(0.2, 0.1, 0.2))
	sub.add_theme_constant_override("outline_size", 4)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	sub.offset_top = -96.0
	sub.offset_left = -400.0
	sub.offset_right = 400.0
	add_child(sub)
