extends Control

# ============================================================
# NightLoadScreen.gd — Run 136 (2026-07-09) — Night transition
# ============================================================
# Shown between the Dojo sleep cinematic and the DreamHub.
# Displays one of the "Night Start" loading-screen images
# (picked at random) with atmospheric text, then fades into
# the Dream Hub (or the Training Room, depending on dream_world_mode).
#
# ART SLOTS (drop PNGs here):
#   res://Assets/Loading Screens/Night Start 1.png
#   res://Assets/Loading Screens/Night Start 2.png
#   res://Assets/Loading Screens/Shino and Bea Capsule Image.png
# ============================================================

const DREAM_HUB_PATH:  String = "res://scenes/DreamHub.tscn"
# Run 173 — the non-DreamWorld destination is now the Training Room (dream
# Dojo), not the old Arena1-20 gauntlet.
const TRAINING_ROOM_PATH: String = "res://scenes/DreamDojo.tscn"
const HOLD_SECONDS:    float  = 3.5

const ART_PATHS: Array = [
	"res://Assets/Loading Screens/Night Start 1.png",
	"res://Assets/Loading Screens/Night Start 2.png",
]

func _ready() -> void:
	# Run 164c — apply the "Ink & Washi" skin to everything built below.
	UISkin.skin_tree_deferred(self)
	_build_screen()
	FX.fade_from_black(0.8)
	await get_tree().create_timer(HOLD_SECONDS).timeout
	FX.fade_to_black(0.8, 0.1, 1.0, Callable(self, "_goto_dream"))


func _goto_dream() -> void:
	# Phase 4 — this is the one gate every run passes through on its way out of
	# the Dojo, so it is where the run clock starts. begin_run() is idempotent
	# (only the first call sticks), so a mid-run scene reload can't restart it.
	StatsState.begin_run(RunState.run_stats)
	var target: String = DREAM_HUB_PATH if RunState.dream_world_mode else TRAINING_ROOM_PATH
	if not ResourceLoader.exists(target):
		push_error("[NightLoadScreen] Target scene not found: %s" % target)
		return
	get_tree().change_scene_to_file(target)


func _build_screen() -> void:
	# Deep night-sky backdrop.
	var sky := ColorRect.new()
	sky.color = Color(0.04, 0.03, 0.08)
	# NOTE: `anchors_preset` is an editor-only property — assigning it from code
	# is a silent no-op (Run 137 grey-screen bug). Use the real method instead.
	sky.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(sky)

	# Try to load one of the Night Start images at random.
	var tex: Texture2D = null
	var shuffled: Array = ART_PATHS.duplicate()
	shuffled.shuffle()
	for path in shuffled:
		if ResourceLoader.exists(path):
			tex = load(path)
			if tex:
				break
		elif FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img:
				tex = ImageTexture.create_from_image(img)
				break

	if tex:
		var rect := TextureRect.new()
		rect.texture = tex
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(rect)

	# Title text overlay.
	var title := Label.new()
	title.text = "THE DREAM BEGINS..."
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 1.0))
	title.add_theme_color_override("font_outline_color", Color(0.05, 0.02, 0.10))
	title.add_theme_constant_override("outline_size", 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	title.offset_top = -140.0
	title.offset_left = -400.0
	title.offset_right = 400.0
	add_child(title)

	var sub := Label.new()
	sub.text = "Shadows creep across Starfruit Island...\nThe ninjas must fight to restore the light."
	sub.add_theme_font_size_override("font_size", 18)
	sub.add_theme_color_override("font_color", Color(0.80, 0.78, 0.92, 0.9))
	sub.add_theme_color_override("font_outline_color", Color(0.05, 0.02, 0.10))
	sub.add_theme_constant_override("outline_size", 4)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	sub.offset_top = -90.0
	sub.offset_left = -400.0
	sub.offset_right = 400.0
	add_child(sub)
