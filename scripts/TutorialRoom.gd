extends Node2D

# ============================================================
# TutorialRoom.gd — Run 141 — Intro tutorial (5-room dream street)
# ============================================================
# First scene on a new save file. Shino "wakes up" alone in a
# shadowy dream version of the town's street. Five horizontal
# hallway rooms teach the player controls step by step:
#
#   Room 1 — Movement (WASD / stick) + Dash (Space / B)
#   Room 2 — Y combo → X combo → A ranged → Charged attacks
#   Room 3 — Meet Bea, learn tag-in (Q+Q / LB+LB)
#   Room 4 — Free practice, Ult, first Boon, pickup explanation
#   Room 5 — Shadow miniboss fight (HP floored at 1)
#
# After defeating the miniboss, fades to the post-tutorial
# cutscene in the Dojo (TutorialCutscene.gd handles that).
#
# All enemies are generic shadow dummies. No biome theming.
# Player HP is floored at 1 (can't die during tutorial).
# ============================================================

const TT = preload("res://scripts/TutorialTerrain.gd")
const TP = preload("res://scripts/TutorialPrompt.gd")
const DB_SCRIPT = preload("res://scripts/DialogBox.gd")

const WALL_T: float = 32.0
const WALL_COLOR: Color = Color(0.12, 0.09, 0.18)
const GATE_COLOR_CLOSED: Color = Color(0.25, 0.18, 0.32)
const GATE_COLOR_OPEN: Color = Color(0.35, 0.75, 0.55)
const SHADOW_TINT: Color = Color(0.18, 0.18, 0.18, 0.9)
# Tutorial slime tint — near-black neutral grey, colourless shadow slimes.
const TUTORIAL_SLIME_TINT: Color = Color(0.20, 0.20, 0.22, 1.0)
# Miniboss slightly brighter so it pops as a threat, still grey.
const TUTORIAL_BOSS_TINT: Color = Color(0.28, 0.28, 0.30, 1.0)

const TUTORIAL_SCENE_PATH: String = "res://scenes/TutorialRoom.tscn"
const DOJO_PATH: String = "res://scenes/Dojo.tscn"

# ── State ────────────────────────────────────────────────────
var _room: int = 1
var _half: Vector2 = Vector2.ZERO
var _gate_node: StaticBody2D = null
var _gate_open: bool = false
var _transitioning: bool = false

# Room 2 combat lesson tracking
var _lesson_step: int = 0
# Steps: 0=Y combo, 1=X combo, 2=ranged(A), 3=charged attack
var _y_kill: bool = false
var _x_kill: bool = false
var _a_kill: bool = false
var _charge_kill: bool = false
var _current_prompt: CanvasLayer = null
var _enemies_alive: int = 0

# Room 3 — Bea tag
var _bea_spawned: bool = false
var _tagged_in_bea: bool = false
var _room3_cleared: bool = false
var _revive_practice: bool = false   # true while partner is auto-downed for revive lesson
var _revive_done: bool = false

# Room 4 — free practice
var _room4_wave: int = 0  # 0=pre, 1=wave1 active, 2=wave2 active
var _boon_taken: bool = false
var _controls_shown: bool = false

# Room 5 — miniboss
var _boss_dead: bool = false

# Post-clear delay — wait 1 second after last enemy dies before showing the
# next tutorial prompt so the player isn't interrupted mid-ult / mid-action.
var _clear_pending: bool = false
var _clear_timer: float = 0.0
const CLEAR_DELAY: float = 1.0

# Gate interaction — press E/R to proceed (same as dream world doors)
var _player_in_gate: bool = false
var _gate_prompt: Label = null


func _ready() -> void:
	y_sort_enabled = true
	_room = RunState.get("tutorial_room") if "tutorial_room" in RunState else 1
	if _room < 1 or _room > 5:
		_room = 1
	_half = TT.room_half(_room)

	# Build the room
	TT.build(self, _half, _room)
	_build_walls()
	_build_exit_gate()
	_position_heroes()
	_apply_night_overlay()

	# Start the room's lesson after a brief settle
	call_deferred("_start_room_lesson")


# ── Night overlay (same as DreamRoom) ────────────────────────
func _apply_night_overlay() -> void:
	if get_node_or_null("NightOverlay") != null:
		return
	var night := CanvasModulate.new()
	night.name = "NightOverlay"
	night.color = Color(0.55, 0.55, 0.78, 1.0)   # dreamy blue tint
	add_child(night)


# ── Wall + gate construction ─────────────────────────────────

func _build_walls() -> void:
	var walls := Node2D.new()
	walls.name = "Walls"
	add_child(walls)

	var wx: float = _half.x + WALL_T * 0.5
	var wy: float = _half.y + WALL_T * 0.5

	# Top wall — solid
	_add_wall_segment(walls, Vector2(0, -wy), Vector2((_half.x + WALL_T) * 2, WALL_T))
	# Bottom wall — solid
	_add_wall_segment(walls, Vector2(0, wy), Vector2((_half.x + WALL_T) * 2, WALL_T))
	# Left wall — solid (room 1) or with entry gap (rooms 2-5)
	if _room == 1:
		_add_wall_segment(walls, Vector2(-wx, 0), Vector2(WALL_T, (_half.y + WALL_T) * 2))
	else:
		# Gap on the left for entry
		_add_wall_segment(walls, Vector2(-wx, -wy + WALL_T * 0.5), Vector2(WALL_T, _half.y - 32))
		_add_wall_segment(walls, Vector2(-wx, wy - WALL_T * 0.5), Vector2(WALL_T, _half.y - 32))
	# Right wall — gap for exit gate (all rooms)
	_add_wall_segment(walls, Vector2(wx, -wy + WALL_T * 0.5), Vector2(WALL_T, _half.y - 32))
	_add_wall_segment(walls, Vector2(wx, wy - WALL_T * 0.5), Vector2(WALL_T, _half.y - 32))


func _add_wall_segment(parent: Node2D, center: Vector2, extent: Vector2) -> void:
	var body := StaticBody2D.new()
	body.position = center
	body.collision_layer = 1
	body.collision_mask = 0

	var vis := ColorRect.new()
	vis.color = WALL_COLOR
	vis.offset_left = -extent.x * 0.5
	vis.offset_top = -extent.y * 0.5
	vis.offset_right = extent.x * 0.5
	vis.offset_bottom = extent.y * 0.5
	body.add_child(vis)

	var col := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = extent
	col.shape = shape
	body.add_child(col)

	parent.add_child(body)


func _build_exit_gate() -> void:
	var wx: float = _half.x + WALL_T * 0.5
	_gate_node = StaticBody2D.new()
	_gate_node.name = "ExitGate"
	_gate_node.position = Vector2(wx, 0)
	_gate_node.collision_layer = 1
	_gate_node.collision_mask = 0

	var vis := ColorRect.new()
	vis.name = "Visual"
	vis.offset_left = -WALL_T * 0.5
	vis.offset_top = -32.0
	vis.offset_right = WALL_T * 0.5
	vis.offset_bottom = 32.0
	vis.color = GATE_COLOR_CLOSED
	_gate_node.add_child(vis)

	var col := CollisionShape2D.new()
	col.name = "GateCollision"
	var shape := RectangleShape2D.new()
	shape.size = Vector2(WALL_T, 64.0)
	col.shape = shape
	_gate_node.add_child(col)

	# Door trigger — area just outside the gate
	var trigger := Area2D.new()
	trigger.name = "DoorTrigger"
	trigger.position = Vector2(20.0, 0.0)
	trigger.collision_layer = 0
	trigger.collision_mask = 2

	var tcol := CollisionShape2D.new()
	var tshape := RectangleShape2D.new()
	tshape.size = Vector2(60, 80)
	tcol.shape = tshape
	trigger.add_child(tcol)
	trigger.body_entered.connect(_on_exit_trigger_entered)
	trigger.body_exited.connect(_on_exit_trigger_exited)
	_gate_node.add_child(trigger)

	# "Press E / R" prompt label (hidden until player enters trigger zone)
	_gate_prompt = Label.new()
	_gate_prompt.name = "GatePrompt"
	_gate_prompt.text = "[E] / [R]"
	_gate_prompt.add_theme_font_size_override("font_size", 16)
	_gate_prompt.add_theme_color_override("font_color", Color(1.0, 0.88, 0.35))
	_gate_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_gate_prompt.add_theme_constant_override("outline_size", 3)
	_gate_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gate_prompt.position = Vector2(-40, -52)
	_gate_prompt.size = Vector2(80, 24)
	_gate_prompt.visible = false
	_gate_node.add_child(_gate_prompt)

	var walls: Node2D = get_node_or_null("Walls")
	if walls:
		walls.add_child(_gate_node)
	else:
		add_child(_gate_node)


func _open_gate() -> void:
	if _gate_open:
		return
	_gate_open = true
	var vis: ColorRect = _gate_node.get_node_or_null("Visual")
	if vis:
		vis.color = GATE_COLOR_OPEN
	var col: CollisionShape2D = _gate_node.get_node_or_null("GateCollision")
	if col:
		col.set_deferred("disabled", true)
	# Show interact prompt if player already in the zone
	if _player_in_gate and _gate_prompt:
		_gate_prompt.visible = true
	print("[Tutorial] Room %d gate opened." % _room)


func _on_exit_trigger_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	_player_in_gate = true
	if _gate_open and _gate_prompt:
		_gate_prompt.visible = true


func _on_exit_trigger_exited(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	_player_in_gate = false
	if _gate_prompt:
		_gate_prompt.visible = false


func _transition_to_next_room() -> void:
	if _transitioning:
		return
	_transitioning = true

	if _room >= 5:
		# Tutorial complete — transition to the dojo cutscene
		_finish_tutorial()
		return

	# Save the next room number
	if "tutorial_room" in RunState:
		RunState.tutorial_room = _room + 1
	else:
		RunState.set_meta("tutorial_room", _room + 1)

	# Carry HP/Chi
	var player: Node = _find_player()
	if player:
		RunState.carry_hp = player.current_hp
		RunState.carry_chi = player.current_chi
	var bea: Node = _find_bea()
	if bea and "current_hp" in bea:
		RunState.bea_carry_hp = bea.current_hp
		RunState.bea_carry_chi = bea.current_chi if "current_chi" in bea else 0

	if get_node_or_null("/root/FX") and FX.has_method("fade_to_black"):
		FX.fade_to_black(0.25, 0.1, 1.0, func():
			get_tree().change_scene_to_file(TUTORIAL_SCENE_PATH)
		)
	else:
		get_tree().change_scene_to_file(TUTORIAL_SCENE_PATH)


func _finish_tutorial() -> void:
	RunState.tutorial_completed = true
	# Clear the tutorial room tracker
	if "tutorial_room" in RunState:
		RunState.tutorial_room = 1

	# Wipe any boons picked up during the tutorial so they don't carry
	# into the dojo or the first real dream-world run.
	RunState.reset_run()

	# Save
	var sm: Node = get_node_or_null("/root/SaveManager")
	if sm and sm.has_method("save_active_slot"):
		sm.save_active_slot()

	if get_node_or_null("/root/FX") and FX.has_method("fade_to_black"):
		FX.fade_to_black(0.5, 0.3, 1.0, func():
			get_tree().change_scene_to_file(DOJO_PATH)
		)
	else:
		get_tree().change_scene_to_file(DOJO_PATH)


# ── Hero positioning ─────────────────────────────────────────

func _position_heroes() -> void:
	var player: Node = _find_player()
	if player == null:
		# Spawn Shino
		var player_scene: PackedScene = load("res://scenes/Shino.tscn")   # renamed from Player.tscn (Phase-1 close)
		if player_scene:
			player = player_scene.instantiate()
			add_child(player)
	if player:
		player.position = Vector2(-_half.x + 80, 0)

	# Bea only present from room 3 onward
	if _room >= 3:
		_spawn_bea()
	else:
		# Hide/remove Bea if she exists
		var bea: Node = _find_bea()
		if bea:
			bea.queue_free()

	# Camera — CameraFollow.gd auto-finds the player via groups.
	# The .tscn already has a Camera2D with CameraFollow; if missing, add one.
	var cam: Camera2D = get_node_or_null("Camera2D")
	if cam == null:
		cam = Camera2D.new()
		cam.name = "Camera2D"
		cam.zoom = Vector2(1.5, 1.5)
		var cam_script: GDScript = load("res://scripts/CameraFollow.gd")
		if cam_script:
			cam.set_script(cam_script)
			cam.follow_speed = 8.0
		add_child(cam)


func _spawn_bea() -> void:
	if _bea_spawned:
		return
	_bea_spawned = true
	var bea: Node = _find_bea()
	if bea != null:
		return
	var bea_scene: PackedScene = load("res://scenes/Bea.tscn")
	if bea_scene == null:
		push_warning("[Tutorial] Bea.tscn not found.")
		return
	bea = bea_scene.instantiate()
	add_child(bea)

	if _room == 3:
		# Bea enters from the right side of the room — the player "meets" her
		bea.position = Vector2(_half.x - 80, 0)
	else:
		# Rooms 4-5: Bea starts near Shino
		var player: Node = _find_player()
		bea.position = Vector2(-_half.x + 120, 30) if player == null else player.position + Vector2(40, 30)


# ── Room lessons ─────────────────────────────────────────────

func _start_room_lesson() -> void:
	match _room:
		1: _room1_movement()
		2: _room2_combat()
		3: _room3_meet_bea()
		4: _room4_free_practice()
		5: _room5_miniboss()


# ── ROOM 1: Movement + Dash ──────────────────────────────────

func _room1_movement() -> void:
	var prompt := TP.show_prompt(self, "The Dream Begins...",
		"Shino... you're dreaming. But this feels real.\n\nUse " + TP.kb("WASD") + " or " + TP.pad("Left Stick") + " to move around. Explore this strange place.",
		"[center]" + TP.keys("WASD", "Left Stick") + "  — Move[/center]")
	prompt.finished.connect(func():
		_show_dash_lesson()
	)


func _show_dash_lesson() -> void:
	var prompt := TP.show_prompt(self, "Dash",
		"Press " + TP.kb("Space") + " or " + TP.pad("B") + " to dash! Dashing makes you briefly invulnerable and lets you dodge through danger.",
		"[center]" + TP.keys("Space", "B") + "  — Dash[/center]")
	prompt.finished.connect(func():
		_open_gate()
		if _current_prompt:
			_current_prompt.dismiss()
		_current_prompt = TP.show_objective(self, "Head east — press " + TP.kb("E") + " " + TP.pad("R") + " at the gate!")
	)


# ── ROOM 2: Combat training ─────────────────────────────────

func _room2_combat() -> void:
	_lesson_step = 0
	_start_y_lesson()


func _start_y_lesson() -> void:
	var prompt := TP.show_prompt(self, "Combo Attacks",
		"An enemy approaches! Press " + TP.kb("J") + " or " + TP.pad("Y") + " repeatedly to perform a combo attack. Land all hits to take it down!",
		"[center]" + TP.keys("J", "Y") + "  — Punch Combo (tap repeatedly)[/center]")
	prompt.finished.connect(func():
		_spawn_combat_enemy("y_lesson", 3)
		_current_prompt = TP.show_objective(self, "Defeat the enemies with Y combo!", "[center]" + TP.keys("J", "Y") + "  — Punch combo[/center]")
	)


func _on_y_lesson_kill() -> void:
	_y_kill = true
	if _current_prompt:
		_current_prompt.dismiss()
		_current_prompt = null
	_start_x_lesson()


func _start_x_lesson() -> void:
	var prompt := TP.show_prompt(self, "Heavy Attacks",
		"Another shadow appears! Use " + TP.kb("K") + " or " + TP.pad("X") + " for heavy attacks — slower but more powerful kicks that hit hard.",
		"[center]" + TP.keys("K", "X") + "  — Kick Combo (tap repeatedly)[/center]")
	prompt.finished.connect(func():
		_spawn_combat_enemy("x_lesson", 3)
		_current_prompt = TP.show_objective(self, "Defeat the enemies with X combo!", "[center]" + TP.keys("K", "X") + "  — Kick combo[/center]")
	)


func _on_x_lesson_kill() -> void:
	_x_kill = true
	if _current_prompt:
		_current_prompt.dismiss()
		_current_prompt = null
	_start_ranged_lesson()


func _start_ranged_lesson() -> void:
	var prompt := TP.show_prompt(self, "Ranged Attacks",
		"Shadows surround you! Press " + TP.kb("L") + " or " + TP.pad("A") + " to throw ki blasts at range. You can also use " + TP.pad("Right Stick") + " to auto-fire in any direction.",
		"[center]" + TP.keys("L", "A") + "  — Ranged    " + TP.pad("Right Stick") + "  — Auto-fire[/center]")
	prompt.finished.connect(func():
		_spawn_ranged_enemies()
		_current_prompt = TP.show_objective(self, "Defeat the ranged enemies!", "[center]" + TP.keys("L", "A") + "  or  " + TP.pad("Right Stick") + "[/center]")
	)


func _on_ranged_lesson_clear() -> void:
	_a_kill = true
	if _current_prompt:
		_current_prompt.dismiss()
		_current_prompt = null
	_start_charge_lesson()


func _start_charge_lesson() -> void:
	var prompt := TP.show_prompt(self, "Charged Attacks",
		"Hold any attack button (" + TP.kb("J") + " " + TP.kb("K") + " " + TP.kb("L") + " or " + TP.pad("Y") + " " + TP.pad("X") + " " + TP.pad("A") + ") to charge up a powerful version! A glow appears when charged — release to unleash it.",
		"[center]Hold " + TP.keys("J / K / L", "Y / X / A") + "  — Charge Attack[/center]")
	prompt.finished.connect(func():
		# Run 150 (Bruno fix 4): 3 enemies for the charge lesson (was 1) —
		# charged attacks shine vs groups, so give the player a real target set.
		_spawn_combat_enemy("charge_lesson", 3)
		_current_prompt = TP.show_objective(self, "Defeat the enemies with charged attacks!", "[center]Hold " + TP.keys("J / K / L", "Y / X / A") + " then release[/center]")
	)


func _on_charge_lesson_kill() -> void:
	_charge_kill = true
	if _current_prompt:
		_current_prompt.dismiss()
		_current_prompt = null
	# All combat lessons complete — open gate
	var prompt := TP.show_prompt(self, "Well Done!",
		"You've mastered the basics of combat! Every attack has a tap combo and a charged version. Mix them up to deal with different threats.",
		"")
	prompt.finished.connect(func():
		_open_gate()
		_current_prompt = TP.show_objective(self, "Proceed east — " + TP.kb("E") + " " + TP.pad("R") + " at the gate!")
	)


# ── ROOM 3: Meet Bea ─────────────────────────────────────────

func _room3_meet_bea() -> void:
	var is_2p: bool = RunState.two_player
	# Dialogue: Shino encounters Bea in the dream
	var dlg := DB_SCRIPT.new_box(self)
	dlg.open("Shino", [
		"Wait— Bea?! What are you doing in my dream?",
	])
	dlg.finished.connect(func():
		dlg.queue_free()
		var dlg2 := DB_SCRIPT.new_box(self)
		dlg2.open("Bea", [
			"YOUR dream? I've been running through these streets for ages!",
			"...Actually, I think we're sharing this dream. I can feel it.",
			"These shadows... they feel WRONG. Like the island itself is sick.",
		])
		dlg2.finished.connect(func():
			dlg2.queue_free()
			var dlg3 := DB_SCRIPT.new_box(self)
			if is_2p:
				dlg3.open("Shino", [
					"Then let's fight through them together. Two ninjas are better than one!",
					"Player 2 — Bea is yours! Let's do this!",
				])
			else:
				dlg3.open("Shino", [
					"Then let's fight through them together. Two ninjas are better than one!",
					"Press Q (or LB) twice quickly to tag in and take control of Bea!",
				])
			dlg3.finished.connect(func():
				dlg3.queue_free()
				_teach_tag_in()
			)
		)
	)


func _teach_tag_in() -> void:
	if RunState.two_player:
		_teach_tag_in_2p()
	else:
		_teach_tag_in_1p()


func _teach_tag_in_1p() -> void:
	var prompt := TP.show_prompt(self, "Tag In — Switch Characters!",
		"Press " + TP.kb("Q") + " or " + TP.pad("LB") + " twice quickly to swap between Shino and Bea! Each ninja fights with their own style. Your partner follows along and fights automatically.",
		"[center]" + TP.keys("Q + Q", "LB + LB") + "  — Tag In (double-tap)[/center]")
	prompt.finished.connect(func():
		_current_prompt = TP.show_objective(self, "Tag in Bea! Double-tap to swap!", "[center]" + TP.keys("Q + Q", "LB + LB") + "  — Tag In[/center]")
		_monitor_tag_in()
	)


func _teach_tag_in_2p() -> void:
	# In 2P, Bea is already player-controlled by P2. Teach the swap mechanic.
	var prompt := TP.show_prompt(self, "Player 2 — Meet Bea!",
		"Player 2 now controls Bea! She fights with swift katana slashes (" + TP.pad("Y") + ") and powerful naginata sweeps (" + TP.pad("X") + "), plus kunai (" + TP.pad("A") + ").\n\nWant to trade characters? Both players press " + TP.kb("Q") + " or " + TP.pad("LB") + " at the same time to swap.",
		"[center]Both press " + TP.keys("Q", "LB") + "  — Swap Characters[/center]")
	prompt.finished.connect(func():
		# Skip the tag-in monitor — go straight to fighting together
		_tagged_in_bea = true
		_spawn_room3_enemies()
		_current_prompt = TP.show_objective(self, "Clear the room together!")
	)


func _monitor_tag_in() -> void:
	# We'll check each frame if the controlled character changed (1P only)
	set_process(true)
	_tagged_in_bea = false


func _on_bea_tagged_in() -> void:
	_tagged_in_bea = true
	if _current_prompt:
		_current_prompt.dismiss()
		_current_prompt = null

	var prompt := TP.show_prompt(self, "Bea is in!",
		"Bea fights with swift katana slashes (" + TP.keys("J", "Y") + ") and powerful naginata sweeps (" + TP.keys("K", "X") + "). She also throws kunai (" + TP.keys("L", "A") + ")! Clear this room with Bea to prove you've got it.",
		"")
	prompt.finished.connect(func():
		# Spawn enemies for Bea to clear
		_spawn_room3_enemies()
		_current_prompt = TP.show_objective(self, "Clear the room with Bea!")
	)


func _spawn_room3_enemies() -> void:
	_enemies_alive = 3
	for i in range(3):
		var angle: float = TAU * float(i) / 3.0
		var pos: Vector2 = Vector2(cos(angle), sin(angle)) * 140.0
		_spawn_shadow_enemy(pos, 50, "room3")


func _on_room3_cleared() -> void:
	_room3_cleared = true
	if _current_prompt:
		_current_prompt.dismiss()
		_current_prompt = null

	# Teach downed/revive before the miniboss
	var revive_body: String
	if RunState.two_player:
		revive_body = "If a ninja's HP hits zero, they go down! The other player can revive them by standing close. If both ninjas go down... it's game over.\n\nLet's practice — your partner has been downed. Walk up to them to revive!"
	else:
		revive_body = "If a ninja's HP hits zero, they go down! Your partner can revive them by standing close. If both ninjas go down... it's game over.\n\nLet's practice — your partner has been downed. Walk up to them to revive!"
	var prompt := TP.show_prompt(self, "Downed & Revive",
		revive_body,
		"[Stand near downed ally to revive]")
	prompt.finished.connect(func():
		_start_revive_practice()
	)


func _start_revive_practice() -> void:
	_revive_practice = true
	_revive_done = false
	# Determine which ninja the player is NOT controlling, and down them.
	var player: Node = _find_player()
	var bea: Node = _find_bea()
	if bea and "player_controlled" in bea and bea.player_controlled:
		# Player is controlling Bea → down Shino
		if player and player.has_method("_enter_downed_state"):
			player.current_hp = 0
			player._enter_downed_state()
		_current_prompt = TP.show_objective(self, "Revive Shino! Walk up to him.")
	else:
		# Player is controlling Shino → down Bea
		if bea and bea.has_method("_enter_downed_state"):
			bea.current_hp = 0
			bea._enter_downed_state()
		_current_prompt = TP.show_objective(self, "Revive Bea! Walk up to her.")


func _on_revive_done() -> void:
	_revive_practice = false
	_revive_done = true
	if _current_prompt:
		_current_prompt.dismiss()
		_current_prompt = null
	# Run 150 (Bruno fix 5): the tutorial is generous — top BOTH ninjas back to
	# full HP after the revive lesson (a normal revive only restores ~30%).
	var player: Node = _find_player()
	if player and "current_hp" in player:
		var p_max: int = player.get_effective_max_hp() if player.has_method("get_effective_max_hp") else player.max_hp
		player.current_hp = p_max
		if player.has_signal("hp_changed"):
			player.hp_changed.emit(p_max, p_max)
	var bea: Node = _find_bea()
	if bea and "current_hp" in bea:
		var b_max: int = bea.get_effective_max_hp() if bea.has_method("get_effective_max_hp") else bea.get("max_hp")
		bea.current_hp = b_max
		if bea.has_signal("bea_hp_changed"):
			bea.bea_hp_changed.emit(b_max, b_max)
	var prompt := TP.show_prompt(self, "Great Work!",
		"You revived your partner! Remember — always stay close enough to save each other.\n\nThe dream was kind this time and restored FULL health. Out in the real Dream World, a revive only brings your partner back at around 30% HP — so protect each other after a rescue!",
		"")
	prompt.finished.connect(func():
		_open_gate()
		_current_prompt = TP.show_objective(self, "Proceed east — " + TP.kb("E") + " " + TP.pad("R") + " at the gate!")
	)


# ── ROOM 4: Free practice + Ult + Boon ───────────────────────

func _room4_free_practice() -> void:
	# Show full controls refresher popup
	var swap_kb: String = "Q" if not RunState.two_player else "Q"
	var swap_pad: String = "LB" if not RunState.two_player else "LB"
	var swap_label: String = "Tag In" if not RunState.two_player else "Swap"
	var swap_note: String = "Both players can swap who controls each ninja!" if RunState.two_player else "You can freely switch between Shino and Bea!"
	var body: String = (
		TP.keys("J", "Y") + " Punch   " + TP.keys("K", "X") + " Kick   " + TP.keys("L", "A") + " Ranged\n" +
		TP.keys("Space", "B") + " Dash   " + TP.keys(swap_kb, swap_pad) + " " + swap_label + "\n" +
		"Hold " + TP.keys("J/K/L", "Y/X/A") + " Charge   " + TP.pad("Right Stick") + " Auto-fire\n\n" +
		swap_note
	)
	var prompt := TP.show_prompt(self, "Controls Refresher", body,
		"Take a moment to practice — enemies incoming!")
	prompt.finished.connect(func():
		_controls_shown = true
		_spawn_room4_wave1()
	)


func _spawn_room4_wave1() -> void:
	_room4_wave = 1
	_enemies_alive = 4
	for i in range(4):
		var pos := Vector2(randf_range(-_half.x * 0.6, _half.x * 0.6),
						   randf_range(-_half.y * 0.5, _half.y * 0.5))
		_spawn_shadow_enemy(pos, 55, "room4")
	_current_prompt = TP.show_objective(self, "Defeat all enemies!")


func _on_room4_wave1_clear() -> void:
	if _current_prompt:
		_current_prompt.dismiss()
		_current_prompt = null

	# Teach Ultimate
	var prompt := TP.show_prompt(self, "Ultimate Attack!",
		"Your Chi meter fills as you fight! When it's full, press " + TP.kb("U") + " or " + TP.pad("RT") + " to unleash a devastating Ultimate attack that hits all nearby enemies!\n\nHere — have a full Chi bar to try it out.",
		"[center]" + TP.keys("U", "RT") + "  — Ultimate Attack (when Chi is full)[/center]")
	prompt.finished.connect(func():
		# Grant full chi to both
		var player: Node = _find_player()
		if player and "current_chi" in player:
			player.current_chi = player.MAX_CHI
			if player.has_signal("chi_changed"):
				player.chi_changed.emit(player.current_chi, player.MAX_CHI)
		var bea: Node = _find_bea()
		if bea and "current_chi" in bea:
			bea.current_chi = bea.get("MAX_CHI") if "MAX_CHI" in bea else 100
		# Spawn wave 2 for ult practice
		_spawn_room4_wave2()
	)


func _spawn_room4_wave2() -> void:
	_room4_wave = 2
	_enemies_alive = 5
	for i in range(5):
		var pos := Vector2(randf_range(-_half.x * 0.5, _half.x * 0.5),
						   randf_range(-_half.y * 0.4, _half.y * 0.4))
		_spawn_shadow_enemy(pos, 40, "room4_w2")
	_current_prompt = TP.show_objective(self, "Try your Ultimate! Clear all enemies!")


func _on_room4_wave2_clear() -> void:
	if _current_prompt:
		_current_prompt.dismiss()
		_current_prompt = null
	# Drop a Broccoli boon — forced simple attack boon
	_drop_tutorial_boon()


func _drop_tutorial_boon() -> void:
	var prompt := TP.show_prompt(self, "Boon of Power!",
		"After clearing rooms in the Dream World, you'll earn Boons — permanent power-ups for the current run! Each boon belongs to a food family on the island.\n\nBoth ninjas get to pick a Boon — Shino chooses first, then Bea.\n\nYou'll also find other pickups along the way:\n  Pie — restores HP\n  Dragonfruit — upgrades a boon you already have\n  Juice — auto-heal between rooms\n  Sparks — permanent stat boosts across ALL runs!",
		"[Pick a boon to power up!]")
	prompt.finished.connect(func():
		# Force a simple Broccoli attack boon offer
		_show_tutorial_boon_offer()
	)


func _show_tutorial_boon_offer() -> void:
	# Run 150 (Bruno fix 6): drop a PHYSICAL boon pickup like real combat rooms
	# — the player walks up and presses E/R at the pedestal, which then opens
	# the (Broccoli-forced) BoonOffer. Previously the offer opened automatically
	# on room clear, which taught the wrong loop.
	RunState.set_meta("tutorial_boon_mode", true)
	var pickup_script: GDScript = load("res://scripts/BoonPickup.gd")
	if pickup_script == null:
		# Fallback — legacy direct-offer path.
		push_warning("[Tutorial] BoonPickup.gd not found — opening offer directly.")
		var offer_scene: PackedScene = load("res://scenes/BoonOffer.tscn")
		if offer_scene == null:
			push_warning("[Tutorial] BoonOffer.tscn not found — skipping boon.")
			RunState.remove_meta("tutorial_boon_mode")
			_on_boon_picked()
			return
		var offer: Node = offer_scene.instantiate()
		add_child(offer)
		if offer.has_signal("boon_picked"):
			offer.boon_picked.connect(func(_id: String):
				RunState.remove_meta("tutorial_boon_mode")
				_on_boon_picked()
			)
		return
	var pickup: Node2D = pickup_script.new()
	pickup.setup("Broccoli")   # tutorial forces the Broccoli family (Run 141)
	pickup.position = Vector2.ZERO   # center of the room
	add_child(pickup)
	pickup.boon_collected.connect(func(_id: String):
		if RunState.has_meta("tutorial_boon_mode"):
			RunState.remove_meta("tutorial_boon_mode")
		_on_boon_picked()
	)
	_current_prompt = TP.show_objective(self, "A boon dropped! Press " + TP.kb("E") + " " + TP.pad("R") + " at the pedestal to collect it.")


func _on_boon_picked() -> void:
	_boon_taken = true
	if _current_prompt:
		_current_prompt.dismiss()
		_current_prompt = null
	_open_gate()
	_current_prompt = TP.show_objective(self, "Proceed to the final room — " + TP.kb("E") + " " + TP.pad("R") + " at the gate!")


# ── ROOM 5: Shadow Miniboss ──────────────────────────────────

func _room5_miniboss() -> void:
	var prompt := TP.show_prompt(self, "A Powerful Shadow Awaits...",
		"Something dark stirs ahead. A powerful shadow creature blocks your path! Use everything you've learned to defeat it.\n\nDon't worry — the dream won't let you fall. Not yet.",
		"")
	prompt.finished.connect(func():
		_spawn_miniboss()
		_current_prompt = TP.show_objective(self, "Defeat the Shadow!")
	)


func _spawn_miniboss() -> void:
	_enemies_alive = 1
	# Miniboss = a BIG seasalt jelly. Same sprite, scaled up, can leap
	# occasionally so players practice dodging the telegraphed AoE.
	var enemy_scene: PackedScene = load("res://scenes/SlimeEnemy.tscn")
	if enemy_scene == null:
		push_warning("[Tutorial] SlimeEnemy.tscn not found.")
		return
	var boss: Node = enemy_scene.instantiate()
	boss.name = "ShadowBoss"
	boss.position = Vector2(_half.x * 0.4, 0)
	boss.max_hp = 250
	boss.current_hp = 250
	boss.move_speed = 50.0
	boss.attack_damage = 12
	# Scale up visually — big chunky shadow slime
	boss.scale = Vector2(1.6, 1.6)
	# Wire MonsterRig with seasalt config BEFORE entering tree
	_wire_slime_rig(boss, "seasalt")
	boss.add_to_group("enemy")
	boss.add_to_group("tutorial_enemy")
	boss.add_to_group("tutorial_boss")
	add_child(boss)
	# Boss tint — same desaturation shader, slightly brighter so it pops.
	_apply_boss_shadow_tint(boss)
	var nm: Label = boss.get_node_or_null("NameLabel") as Label
	if nm:
		nm.text = "★ Dark Shadow"
		nm.add_theme_color_override("font_color", Color(1.0, 0.75, 0.25))
	# Allow leaps — the normal COOLDOWN_MIN/MAX (1.6-2.8s) provide decent
	# spacing for the player to practice dodging the landing circle.
	# First leap after ~3s so the player has time to read the room.
	# No elemental breath — keep it simple.
	boss.set("_cooldown", 3.0)
	boss.set("_elem_cd", 999.0)

	# Also spawn 2 small adds
	for i in range(2):
		var add_pos := Vector2(_half.x * 0.3 + randf_range(-60, 60),
							   randf_range(-80, 80))
		_spawn_shadow_enemy(add_pos, 40, "boss_add")
	_enemies_alive += 2


func _on_boss_defeated() -> void:
	_boss_dead = true
	if _current_prompt:
		_current_prompt.dismiss()
		_current_prompt = null

	var dlg := DB_SCRIPT.new_box(self)
	dlg.open("Shino", [
		"We did it... the shadow is fading...",
	])
	dlg.finished.connect(func():
		dlg.queue_free()
		var dlg2 := DB_SCRIPT.new_box(self)
		dlg2.open("Bea", [
			"Shino... I'm waking up. I can feel it...",
			"This dream... it's real, isn't it?",
		])
		dlg2.finished.connect(func():
			dlg2.queue_free()
			_open_gate()
		)
	)


# ── Enemy spawning ───────────────────────────────────────────

func _spawn_shadow_enemy(pos: Vector2, hp: int, tag: String) -> void:
	# Tutorial enemies are Seasalt Jellies (water slimes) tinted dark/shadowy.
	# They move slowly, rarely attack, and NEVER leap — the tutorial is about
	# the player learning THEIR moves, not dodging AoE splats.
	var enemy_scene: PackedScene = load("res://scenes/SlimeEnemy.tscn")
	if enemy_scene == null:
		push_warning("[Tutorial] SlimeEnemy.tscn not found — falling back to DummyEnemy.")
		enemy_scene = load("res://scenes/DummyEnemy.tscn")
		if enemy_scene == null:
			_enemies_alive = maxi(_enemies_alive - 1, 0)
			return
	var enemy: Node = enemy_scene.instantiate()
	enemy.position = pos
	enemy.max_hp = hp
	enemy.current_hp = hp
	enemy.move_speed = 45.0       # slower than normal slimes
	enemy.attack_damage = 5
	# Wire the MonsterRig with "seasalt" (water jelly) config BEFORE entering tree.
	_wire_slime_rig(enemy, "seasalt")
	enemy.add_to_group("enemy")
	enemy.add_to_group("tutorial_enemy")
	enemy.add_to_group("tutorial_" + tag)
	add_child(enemy)
	# Apply dark shadow tint AFTER adding to tree (modulate on the root).
	_apply_shadow_tint(enemy)
	# Update name label
	var nm: Label = enemy.get_node_or_null("NameLabel") as Label
	if nm:
		nm.text = "Shadow"
		nm.add_theme_color_override("font_color", Color(0.6, 0.55, 0.75))
	# Nerf attack behaviour: enormous cooldowns so they almost never leap/breathe.
	# The slime will just hop-drift toward the player as a gentle punching bag.
	enemy.set("_cooldown", 999.0)     # effectively disables leap
	enemy.set("_elem_cd", 999.0)      # effectively disables elemental breath


func _spawn_combat_enemy(tag: String, count: int = 1) -> void:
	_enemies_alive = count
	for i in range(count):
		var pos: Vector2 = Vector2(100 + i * 70, randf_range(-60, 60))
		_spawn_shadow_enemy(pos, 45, tag)


func _spawn_ranged_enemies() -> void:
	_enemies_alive = 3
	var positions := [
		Vector2(160, -80),
		Vector2(200, 40),
		Vector2(100, 100),
	]
	for p in positions:
		_spawn_shadow_enemy(p, 30, "ranged_lesson")


func _wire_slime_rig(enemy: Node, rig_id: String) -> void:
	# Swap the $Body node's script to MonsterRig and assign the config id
	# BEFORE the node enters the tree, so MonsterRig._ready() builds the
	# correct sprite from the strip sheets. Same pattern as DreamSpawner.
	var body: Node = enemy.get_node_or_null("Body")
	if body == null:
		return
	var rig_script: GDScript = load("res://scripts/MonsterRig.gd")
	if rig_script == null:
		return
	body.set_script(rig_script)
	body.set("_cfg_id", rig_id)
	# Resize the flash-tint overlay so it covers the jelly body.
	var ov: ColorRect = enemy.get_node_or_null("Sprite") as ColorRect
	if ov:
		ov.offset_left = -34.0
		ov.offset_top = -52.0
		ov.offset_right = 34.0
		ov.offset_bottom = 8.0


func _apply_shadow_tint(enemy: Node) -> void:
	# Desaturate + darken the enemy so it reads as a colourless shadow slime.
	# Plain modulate only multiplies channels, so a blue sprite stays blue.
	# A tiny shader converts to greyscale first, then multiplies by our dark tint.
	if not (enemy is CanvasItem):
		return
	# Reset modulate so the shader does all the work.
	enemy.modulate = Color.WHITE
	# Target the actual AnimatedSprite2D ("MonsterSprite") that MonsterRig builds
	# inside Body. The shader must sit on the node that owns the texture.
	var target: CanvasItem = enemy
	var sprite: Node = enemy.get_node_or_null("Body/MonsterSprite")
	if sprite is CanvasItem:
		target = sprite as CanvasItem
	elif enemy.get_node_or_null("Body") is CanvasItem:
		target = enemy.get_node_or_null("Body") as CanvasItem
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
uniform vec4 shadow_tint : source_color = vec4(0.20, 0.20, 0.22, 1.0);
void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	// Convert to greyscale (luminance weights).
	float grey = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
	COLOR = vec4(vec3(grey) * shadow_tint.rgb, tex.a * shadow_tint.a);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("shadow_tint", TUTORIAL_SLIME_TINT)
	target.material = mat


func _apply_boss_shadow_tint(boss: Node) -> void:
	# Same desaturation shader as regular slimes but with the brighter boss tint.
	if not (boss is CanvasItem):
		return
	boss.modulate = Color.WHITE
	var target: CanvasItem = boss as CanvasItem
	var sprite: Node = boss.get_node_or_null("Body/MonsterSprite")
	if sprite is CanvasItem:
		target = sprite as CanvasItem
	elif boss.get_node_or_null("Body") is CanvasItem:
		target = boss.get_node_or_null("Body") as CanvasItem
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
uniform vec4 shadow_tint : source_color = vec4(0.28, 0.28, 0.30, 1.0);
void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float grey = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
	COLOR = vec4(vec3(grey) * shadow_tint.rgb, tex.a * shadow_tint.a);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("shadow_tint", TUTORIAL_BOSS_TINT)
	target.material = mat


# ── Process: monitor game state ──────────────────────────────

func _process(delta: float) -> void:
	_enforce_hp_floor()
	_check_enemy_deaths()

	# Post-clear delay: tick down and fire the deferred callback.
	if _clear_pending:
		_clear_timer -= delta
		if _clear_timer <= 0.0:
			_clear_pending = false
			_fire_clear_callback()

	# Room 3: monitor tag-in — 1P only (2P skips this; _tagged_in_bea set directly)
	if _room == 3 and not _tagged_in_bea and not RunState.two_player:
		var bea: Node = _find_bea()
		if bea and "player_controlled" in bea and bea.player_controlled:
			_on_bea_tagged_in()

	# Gate interact — press E/R to proceed
	if _gate_open and _player_in_gate and not _transitioning:
		if Input.is_action_just_pressed("interact"):
			_transition_to_next_room()

	# Room 3: monitor revive practice completion
	if _room == 3 and _revive_practice and not _revive_done:
		var player: Node = _find_player()
		var bea2: Node = _find_bea()
		# Check if the downed ninja has been revived (no longer downed)
		var shino_ok: bool = player == null or not (player.has_method("is_downed") and player.is_downed())
		var bea_ok: bool = bea2 == null or not (bea2.has_method("is_downed") and bea2.is_downed())
		if shino_ok and bea_ok:
			_on_revive_done()


func _enforce_hp_floor() -> void:
	# Tutorial HP floor — player can never die.
	# Skip flooring during revive practice so the auto-downed ninja stays downed.
	var player: Node = _find_player()
	if player and "current_hp" in player and player.current_hp < 1:
		if not (_revive_practice and player.has_method("is_downed") and player.is_downed()):
			player.current_hp = 1
			if player.has_signal("hp_changed"):
				player.hp_changed.emit(1, player.max_hp)
	# Protect Bea's HP: rooms 3-4 floor at 1 (she can be downed in room 5 for teaching).
	# In 2P, Bea is human-controlled from Room 3 so she needs the same safety net.
	if _room >= 3 and _room <= 4:
		var bea: Node = _find_bea()
		if bea and "current_hp" in bea and bea.current_hp < 1:
			if not (_revive_practice and bea.has_method("is_downed") and bea.is_downed()):
				bea.current_hp = 1


func _check_enemy_deaths() -> void:
	# Count live tutorial enemies
	var alive: int = 0
	for node in get_tree().get_nodes_in_group("tutorial_enemy"):
		if node is CharacterBody2D and "current_hp" in node and node.current_hp > 0:
			alive += 1

	if alive >= _enemies_alive:
		return   # nothing died yet

	_enemies_alive = alive

	if alive > 0:
		return   # still some alive

	# All enemies dead — start the post-clear delay (unless already pending).
	if not _clear_pending:
		_clear_pending = true
		_clear_timer = CLEAR_DELAY


func _fire_clear_callback() -> void:
	# Called after the post-clear delay expires.
	match _room:
		2:
			if not _y_kill:
				_on_y_lesson_kill()
			elif not _x_kill:
				_on_x_lesson_kill()
			elif not _a_kill:
				_on_ranged_lesson_clear()
			elif not _charge_kill:
				_on_charge_lesson_kill()
		3:
			if not _room3_cleared:
				_on_room3_cleared()
		4:
			if not _controls_shown:
				return
			if not _boon_taken:
				if _room4_wave == 2:
					_on_room4_wave2_clear()
				elif _room4_wave == 1:
					_on_room4_wave1_clear()
		5:
			if not _boss_dead:
				_on_boss_defeated()


# ── Helpers ──────────────────────────────────────────────────

func _find_player() -> Node:
	# Shino = in group "player" but NOT in group "bea"
	var players := get_tree().get_nodes_in_group("player")
	for p in players:
		if not p.is_in_group("bea"):
			return p
	return players[0] if players.size() > 0 else null


func _find_bea() -> Node:
	var beas := get_tree().get_nodes_in_group("bea")
	if beas.size() > 0:
		return beas[0]
	return get_node_or_null("Bea")
