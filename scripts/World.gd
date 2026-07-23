extends Node2D

# ============================================================
# World.gd — Arena controller (Run 27 — physical multi-door rewrite)
# ============================================================
# Phase 5/6 — handles wave flow, gate opening, boon offer overlay,
# and room transitions. Used by World.tscn / ArenaN.tscn — every
# arena scene shares this single script with different @export
# values (arena_name, next_scene_path, is_final_in_loop).
#
# RUN 27 (2026-06-03): PHYSICAL DOORWAY REWRITE.
#   - Replaced DoorChoice CanvasLayer overlay with physical exit
#     gates in the arena. Each arena can have N gates (>=1).
#   - Each gate's name must start with "Gate" (e.g. Gate, GateA,
#     GateB, GateC). World.gd auto-discovers them under $Walls.
#   - After the in-room boon is picked, World.gd calls
#     RunState.roll_door_pair(next_arena_number) and assigns one
#     preview per gate (in discovery order). All gates open
#     simultaneously and reveal their preview label.
#   - Player walks into ANY gate's DoorTrigger → that gate's
#     preview is committed via RunState.commit_door_choice() →
#     fade transition fires → next scene loads.
#   - Single-gate arenas still work (gate gets preview[0]; the
#     second preview is silently discarded). This is the graceful
#     degradation path for the legacy "one gate per arena" setup.
#
# Each gate node SHOULD have these child nodes (auto-discovered):
#   - CollisionShape2D  (the blocking shape; disabled when gate opens)
#   - Visual            (a ColorRect that recolors green when open)
#   - DoorTrigger       (Area2D — body_entered triggers the commit)
#
# A gate's preview-label Control is OPTIONAL in the scene tree.
# If a label node named "DoorPreviewLabel" exists as a child of
# the gate, World.gd will populate its text + colors. If not,
# World.gd creates one at runtime (positioned above the gate
# visual) so previews still render even in legacy arenas.
# ============================================================

## Path to the next arena scene.
@export var next_scene_path: String = "res://scenes/Arena2.tscn"

## Display name used in log messages and ControlsLabel updates.
@export var arena_name: String = "Arena 1"

## True if this arena is the final stop in a loop (Arena3 → wrap back to Arena1).
@export var is_final_in_loop: bool = false

@onready var spawner:       Node2D = $EnemySpawner
@onready var cleared_label: Label  = $DebugHUD/WaveClearedLabel
@onready var boons_label:   Label  = get_node_or_null("DebugHUD/BoonsLabel")

# Run 27 — Physical doors. Each entry of `_gates` is a Dictionary:
#   {
#     "name":    String,            # the node name (e.g. "Gate", "GateA")
#     "node":    Node,              # the gate body (StaticBody2D usually)
#     "shape":   CollisionShape2D,  # collision to disable on open (may be null)
#     "visual":  ColorRect,         # tinted on open (may be null)
#     "trigger": Area2D,            # body_entered signal source (may be null)
#     "label":   Control,           # preview label above the gate (auto-created if absent)
#     "preview": Dictionary,        # committed preview dict from roll_door_pair
#     "opened":  bool,              # true once visually opened
#   }
var _gates: Array = []

var _boon_picked_this_arena: bool = false
var _wave_cleared: bool = false
var _transitioning: bool = false      # true once fade-out starts; prevents double-fire
var _pending_next_scene: String = ""  # holds next_scene_path during the fade callback
var _boon_collected: bool = false     # gates stay locked until boon is collected
# Per-gate proximity tracking (gate name → bool). Shino and Bea tracked separately.
# Exit fires only when BOTH are in the trigger zone (or only Shino if no Bea in scene).
var _player_near_gate: Dictionary = {}   # Shino (or active player-controlled char)
var _bea_near_gate: Dictionary = {}      # Bea (AI or player-controlled)

const GATE_CLOSED_COLOR: Color = Color(0.4, 0.3, 0.22, 1)
const GATE_OPEN_COLOR:   Color = Color(0.2, 0.8, 0.3, 1)

const BOON_OFFER_SCENE_PATH: String = "res://scenes/BoonOffer.tscn"
# Run 27 — DoorChoice CanvasLayer is DEPRECATED. The scene file remains in
# the project as an inspection/fallback artifact but World.gd no longer
# instantiates it. See scripts/DoorChoice.gd header for details.


func _ready() -> void:
	print("[World] %s — Phase 5/6: wave + boon flow + physical doors" % arena_name)
	# Run 39 — group lookup so AI characters (BeaAI) can query the arena
	# controller for the consensus-exit rally point without a hard node path.
	add_to_group("world")

	# Connect wave-cleared signal from the EnemySpawner.
	if spawner and spawner.has_signal("wave_cleared"):
		spawner.wave_cleared.connect(_on_wave_cleared)
	else:
		push_warning("[World] EnemySpawner not found or missing wave_cleared signal.")

	# Run 33 — ensure 3 gate nodes exist (most arena scenes only ship with 1).
	# Runtime gates are spawned along the bottom wall BEFORE discovery so the
	# rest of the gate pipeline treats them identically to scene gates.
	_ensure_gate_nodes()
	# Discover all gate nodes under $Walls (any node name starting with "Gate").
	_discover_gates()
	if _gates.is_empty():
		push_warning("[World] No gate nodes discovered under $Walls — exits will not function.")

	# Initial visual state: every gate visually closed (brown) with a LOCKED
	# indicator. Preview labels stay hidden until the boon is picked.
	if cleared_label:
		cleared_label.visible = false
		_dock_cleared_label_top_right()
	for g in _gates:
		if g.visual:
			g.visual.color = GATE_CLOSED_COLOR
		if g.label:
			g.label.visible = false
		# Build a "🔒 LOCKED" overlay on each gate so the player can see the door
		# exists but can't pass. Removed (queue_free) when the gate opens.
		_build_locked_indicator(g)

	_refresh_boons_label()

	# Fade in from black — every new arena starts from full black.
	FX.fade_from_black(0.35)


# ---------------------------------------------------------------------------
# Run 33 — Runtime gate spawning. Every arena needs 3 gates so the room-exit
# roll (2-3 exits) always has somewhere to land. Most arena scenes only ship
# with a single bottom-center gate, so we spawn the missing ones at standard
# slots along the bottom wall. The wall collision behind a runtime gate stays
# solid, but exits fire from the DoorTrigger zone (inside the arena) via [E],
# so passage through the wall is never required.
# ---------------------------------------------------------------------------
const RUNTIME_GATE_SLOTS: Array = [
	Vector2(-256.0, 368.0),
	Vector2(0.0, 368.0),
	Vector2(256.0, 368.0),
]

func _ensure_gate_nodes() -> void:
	var walls := get_node_or_null("Walls")
	if walls == null:
		return
	var existing_positions: Array = []
	var gate_count: int = 0
	for child in walls.get_children():
		if String(child.name).begins_with("Gate"):
			gate_count += 1
			if child is Node2D:
				existing_positions.append((child as Node2D).position)
	var spawn_idx: int = 1
	for slot in RUNTIME_GATE_SLOTS:
		if gate_count >= 3:
			break
		var occupied: bool = false
		for p in existing_positions:
			if (p as Vector2).distance_to(slot) < 48.0:
				occupied = true
				break
		if occupied:
			continue
		walls.add_child(_build_runtime_gate("GateR%d" % spawn_idx, slot))
		spawn_idx += 1
		gate_count += 1
	if spawn_idx > 1:
		print("[World] Spawned %d runtime gate(s) to reach 3 total." % (spawn_idx - 1))


# Mirrors the scene-file gate structure: StaticBody2D + Visual (ColorRect)
# + CollisionShape2D (64x32) + DoorTrigger (Area2D, 64x48, offset y-16).
func _build_runtime_gate(gate_name: String, pos: Vector2) -> StaticBody2D:
	var gate := StaticBody2D.new()
	gate.name = gate_name
	gate.position = pos
	gate.collision_layer = 1
	gate.collision_mask = 0
	gate.add_to_group("leap_blocker")   # Run 110 — arena boundary gate; Meteor leap stops here

	var vis := ColorRect.new()
	vis.name = "Visual"
	vis.offset_left = -32.0
	vis.offset_top = -16.0
	vis.offset_right = 32.0
	vis.offset_bottom = 16.0
	vis.color = GATE_CLOSED_COLOR
	gate.add_child(vis)

	var col := CollisionShape2D.new()
	col.name = "CollisionShape2D"
	var shape := RectangleShape2D.new()
	shape.size = Vector2(64, 32)
	col.shape = shape
	gate.add_child(col)

	var trigger := Area2D.new()
	trigger.name = "DoorTrigger"
	trigger.position = Vector2(0, -16)
	trigger.collision_layer = 0
	trigger.collision_mask = 2
	var tcol := CollisionShape2D.new()
	tcol.name = "CollisionShape2D"
	var tshape := RectangleShape2D.new()
	tshape.size = Vector2(64, 48)
	tcol.shape = tshape
	trigger.add_child(tcol)
	gate.add_child(trigger)

	return gate


# ---------------------------------------------------------------------------
# Gate discovery — collects any child of $Walls whose name starts with "Gate".
# Names ending in A/B/C are conventional (GateA on right wall, GateB on bottom,
# GateC for rare 3-door arenas), but any "Gate*" name works.
# ---------------------------------------------------------------------------
func _discover_gates() -> void:
	_gates.clear()
	var walls := get_node_or_null("Walls")
	if walls == null:
		push_warning("[World] $Walls node not found — cannot discover gates.")
		return
	for child in walls.get_children():
		var nm: String = String(child.name)
		if not nm.begins_with("Gate"):
			continue
		var entry := {
			"name":    nm,
			"node":    child,
			"shape":   child.get_node_or_null("CollisionShape2D") as CollisionShape2D,
			"visual":  child.get_node_or_null("Visual") as ColorRect,
			"trigger": child.get_node_or_null("DoorTrigger") as Area2D,
			"label":   null,
			"preview": {},
			"opened":  false,
		}
		# Re-acquire a preview label if the scene already has one as a child.
		var existing_label: Control = child.get_node_or_null("DoorPreviewLabel") as Control
		if existing_label:
			entry.label = existing_label
			# Same z-fix as runtime labels: keep scene-authored labels above the
			# arches/totems (BARRIER_OVERHANG_Z) so they aren't occluded.
			existing_label.z_as_relative = false
			existing_label.z_index = 18
		else:
			entry.label = _build_preview_label(child)
		# Track proximity for Shino and Bea separately.
		# Exit only fires when both are near (consensus exit — see _can_exit_gate).
		if entry.trigger:
			entry.trigger.body_entered.connect(_on_gate_player_entered.bind(entry.name))
			entry.trigger.body_exited.connect(_on_gate_player_exited.bind(entry.name))
		_player_near_gate[entry.name] = false
		_bea_near_gate[entry.name] = false
		_gates.append(entry)
	# Stable ordering — discovery order from scene file is fine, but we sort
	# by node name to make GateA / GateB / GateC predictable.
	_gates.sort_custom(func(a, b): return String(a.name) < String(b.name))
	print("[World] Discovered %d gate(s): %s" % [_gates.size(), _gate_names_csv()])


func _gate_names_csv() -> String:
	var parts: Array = []
	for g in _gates:
		parts.append(String(g.name))
	return ", ".join(parts)


# Build a runtime DoorPreviewLabel above the given gate node so even legacy
# arena scenes (with no scene-tree label) still get a visible preview tag.
# The label is parented to the gate so it moves with it if the gate ever moves.
func _build_preview_label(gate_node: Node) -> Control:
	var panel := PanelContainer.new()
	panel.name = "DoorPreviewLabel"
	# Style the backdrop — dim translucent panel for readability.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.08, 0.82)
	sb.border_color = Color(0.8, 0.8, 0.8, 0.9)
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", sb)
	# Push the label toward the OUTSIDE of the arena (the next room the door leads
	# into), inferred from the gate's offset from center. Falls back to "above".
	var outward: Vector2 = Vector2(0, -1)
	if gate_node is Node2D:
		var gp: Vector2 = (gate_node as Node2D).position
		if absf(gp.y) >= absf(gp.x):
			outward = Vector2(0.0, signf(gp.y)) if gp.y != 0.0 else Vector2(0, -1)
		else:
			outward = Vector2(signf(gp.x), 0.0)
	panel.position = Vector2(-80, -68) + outward * 168.0
	panel.custom_minimum_size = Vector2(160, 56)
	# Render the exit label ABOVE every prop. Arches/totems/cave lintels now draw at
	# RunState.BARRIER_OVERHANG_Z (heroes run UNDER them), so a label left at the
	# gate's depth gets occluded. Pin it to an absolute, near-top z (well over the
	# barrier band; just under nameplates at z 20) so it's always clearly visible.
	panel.z_as_relative = false
	panel.z_index = 18
	# Inner Label — big, high-contrast.
	var label := Label.new()
	label.name = "Text"
	label.text = ""
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(label)
	gate_node.add_child(panel)
	# Run 113 — exit/reward preview text stays full-bright under the Dream-World
	# night CanvasModulate (no-op outside dream_world_mode).
	RunState.apply_night_exemption(panel)
	panel.visible = false
	return panel


# ---------------------------------------------------------------------------
# Wave cleared handler — fires when EnemySpawner reports empty enemy group.
# ---------------------------------------------------------------------------
func _on_wave_cleared() -> void:
	if _wave_cleared:
		return
	_wave_cleared = true
	RunState.arenas_cleared += 1
	print("[World] All enemies defeated — %s cleared!" % arena_name)

	# Apple Sweet Dreams — heal 5% max HP on room clear, per-character (§8.1).
	for p in get_tree().get_nodes_in_group("player"):
		if p.has_method("apply_sweet_dreams_heal"):
			var healed: int = p.apply_sweet_dreams_heal()
			if healed > 0:
				print("[World] Sweet Dreams healed %s for %d HP." % [p.name, healed])
	for b in get_tree().get_nodes_in_group("bea"):
		if b.is_in_group("player"):
			continue
		if b.has_method("apply_sweet_dreams_heal"):
			var healed_b: int = b.apply_sweet_dreams_heal()
			if healed_b > 0:
				print("[World] Sweet Dreams healed Bea for %d HP." % healed_b)

	if cleared_label:
		cleared_label.visible = true
		var tween: Tween = create_tween()
		cleared_label.modulate.a = 0.0
		tween.tween_property(cleared_label, "modulate:a", 1.0, 0.4)
		cleared_label.text = "✦ WAVE CLEARED! ✦\nChoose a boon to continue..."

	# Defer one frame so any death anims / damage numbers spawn before the modal.
	call_deferred("_present_boon_offer")


# Run 52 — wave-cleared banner: small, docked top-right near Bea's boon bar
# instead of plastered across mid-screen (Bruno's request). Inherited by
# DreamRoom.gd and every Arena scene that runs this script.
func _dock_cleared_label_top_right() -> void:
	if cleared_label == null:
		return
	cleared_label.anchor_left = 1.0
	cleared_label.anchor_right = 1.0
	cleared_label.anchor_top = 0.0
	cleared_label.anchor_bottom = 0.0
	cleared_label.offset_left = -460.0
	cleared_label.offset_right = -16.0
	cleared_label.offset_top = 40.0
	cleared_label.offset_bottom = 120.0
	cleared_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	cleared_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cleared_label.add_theme_font_size_override("font_size", 15)


func _present_boon_offer() -> void:
	# Spawn a world-space BoonPickup icon instead of immediately opening the overlay.
	# The player must walk to it and press [E] to collect — gates stay locked
	# until this happens. If BoonPickup script is missing, fall back to auto-offer.
	if get_tree().current_scene.has_node("BoonPickup"):
		return   # already spawned this wave
	if not ResourceLoader.exists("res://scripts/BoonPickup.gd"):
		# Fallback: legacy auto-offer
		if not ResourceLoader.exists(BOON_OFFER_SCENE_PATH):
			push_warning("[World] BoonOffer.tscn missing — skipping boon offer.")
			_after_boon_picked("")
			return
		var overlay: CanvasLayer = load(BOON_OFFER_SCENE_PATH).instantiate()
		overlay.name = "BoonOffer"
		get_tree().current_scene.add_child(overlay)
		overlay.boon_picked.connect(_after_boon_picked)
		return

	# Determine the family for this room's boon.
	# IMPORTANT: if there's no pending door reward (e.g. Arena 1), we roll a
	# random family here AND commit it as a synthetic pending reward so BoonOffer
	# reads the exact same family — preventing the mismatch where the pickup icon
	# shows "Broccoli" but the offer cards are "Potato".
	var room_family: String = ""
	if RunState.has_pending_reward():
		var pending: Dictionary = RunState.peek_pending_reward()
		var ptype: String = String(pending.get("type", ""))
		if ptype == "apple_pie":
			room_family = "__pie__"
		elif ptype == "dragon_fruit":
			room_family = "__upgrade__"
		elif ptype == "dragon_fruit_rare":
			room_family = "__upgrade_rare__"
		else:
			room_family = String(pending.get("family", "")).capitalize()
	else:
		# No prior door pick — roll a family and lock it as the pending reward
		# so BoonOffer consumes this exact family (no second independent roll).
		# Run 27c FIX: must go through commit_door_choice() → pending_reward.
		# The old line wrote to the legacy `pending_room_reward` var, which
		# BoonOffer never reads — so BoonOffer rolled its OWN random family and
		# the pickup label could mismatch the offered cards (Coconut vs Grape bug).
		var families: Array = RunState.DOOR_FAMILIES
		var rolled: String = families[randi() % families.size()]
		room_family = rolled.capitalize()
		RunState.commit_door_choice({"type": "boon", "family": rolled, "rarity": ""})
		print("[World] No prior door pick — rolled family '%s' and locked as pending." % rolled)

	# Spawn the pickup at world-space center of the arena (0,0).
	# NOTE: vp * 0.5 is a SCREEN-space value and must NOT be used as a
	# world_position — that was the cause of the outside-arena softlock bug.
	var pickup := BoonPickup.new()
	pickup.name = "BoonPickup"
	pickup.setup(room_family)
	get_tree().current_scene.add_child(pickup)
	pickup.global_position = Vector2(0, -60)   # slightly above arena center, always reachable
	pickup.boon_collected.connect(_after_boon_picked)
	print("[World] BoonPickup spawned for family '%s' at arena center." % room_family)


func _after_boon_picked(_boon_id: String) -> void:
	_boon_picked_this_arena = true
	_boon_collected = true
	_refresh_boons_label()

	# Run 23 / 26f — Apple Juice on rooms 5/10/15/20. Both characters auto-heal
	# 50% of effective max HP. Banner persists until player commits to a door.
	if RunState.arenas_cleared == 5 or RunState.arenas_cleared == 10 \
			or RunState.arenas_cleared == 15 or RunState.arenas_cleared == 20:
		# Run 43 — Dragon Souls no longer drop in Dream Arena (training mode).
		# Sparks are earned in the Dream World (mini-boss +1 / biome boss +2).
		var healed_total: int = RunState.grant_apple_juice(get_tree())
		if cleared_label:
			cleared_label.text = "🧃 JUICE — both heroes restored (+%d HP)\nChoose a door to continue!" % healed_total
		print("[World] Apple Juice after Arena %d clear (+%d HP)." % [RunState.arenas_cleared, healed_total])
	else:
		if cleared_label:
			if next_scene_path != "":
				cleared_label.text = "✦ BOON ACQUIRED ✦\nChoose a door to continue!"
			else:
				cleared_label.text = "✦ RUN COMPLETE ✦\n(no further arenas configured)"

	# Run 27 — physical doors. If we have a next_scene_path and at least one
	# gate, roll the door pair, assign previews per gate, and open them all.
	# If no next_scene_path, fall through to legacy single-gate open (no-op).
	if next_scene_path != "":
		_assign_door_previews_and_open()
	else:
		# Open any gates anyway so the player isn't trapped (no transition though).
		for g in _gates:
			_open_gate(g)


# Run 33 — Roll ALL room exits from RunState in one pass, assign each preview
# to a random gate, open those gates, and seal the unused ones. Boon rooms get
# 2-3 distinct-family doors, upgrade rooms get exactly Pie + DragonFruit, and
# forced rooms (Juice/Boss) get a single door.
func _assign_door_previews_and_open() -> void:
	if _gates.is_empty():
		# No gates to assign — silently do nothing. Player has no way out
		# of this room; designers should add at least one Gate node.
		return
	var previews: Array = RunState.roll_room_exits(RunState.arenas_cleared + 1)
	var open_count: int = min(previews.size(), _gates.size())
	# Randomize WHICH gates open so the single Juice/Boss door and the 2-exit
	# layouts don't always occupy the same spots.
	var indices: Array = range(_gates.size())
	indices.shuffle()
	var chosen: Array = indices.slice(0, open_count)
	chosen.sort()
	var p: int = 0
	for i in range(_gates.size()):
		var g: Dictionary = _gates[i]
		if chosen.has(i):
			g.preview = previews[p].duplicate()
			p += 1
			_apply_preview_label(g, g.preview)
			_open_gate(g)
		else:
			_seal_gate(g)
		# Dictionaries pass by reference in Godot 4, so g already mutated
		# _gates[i]; assignment kept for readability.
		_gates[i] = g
	print("[World] %d/%d doors opened with previews: %s" % [open_count, _gates.size(), _summarize_gate_previews()])


# Run 33 — a gate that received no preview this room: remove its LOCKED tag
# and darken it so it reads as a sealed wall, not a openable door.
func _seal_gate(g: Dictionary) -> void:
	if g.node:
		var lock_lbl: Node = g.node.get_node_or_null("LockedIndicator")
		if lock_lbl:
			lock_lbl.queue_free()
	if g.visual:
		g.visual.color = Color(0.22, 0.18, 0.15, 1)
	if g.label:
		g.label.visible = false


func _summarize_gate_previews() -> String:
	var parts: Array = []
	for g in _gates:
		var lbl: String = String(g.preview.get("label", "?")).replace("\n", " ")
		parts.append("%s=[%s]" % [String(g.name), lbl])
	return " / ".join(parts)


# Update a single gate's preview label (text + colors) from the preview dict.
# Adds a leading emoji icon based on the preview type/family for at-a-glance
# readability from across the arena.
func _apply_preview_label(g: Dictionary, preview: Dictionary) -> void:
	if g.label == null:
		return
	var ptype: String = String(preview.get("type", "boon"))
	var fam_raw: String = String(preview.get("family", ""))
	var fam: String = fam_raw.capitalize() if fam_raw != "" else ""
	var rarity: String = String(preview.get("rarity", ""))
	var icon: String = _icon_for_preview(ptype, fam)
	var fam_color: Color = RunState.get_family_color(fam) if fam != "" else Color(0.85, 0.85, 0.85)
	# Special-case override colors for non-boon types — mirrors DoorChoice.gd.
	if ptype == "boss":
		fam_color = Color(0.95, 0.30, 0.20)
	elif ptype == "apple_juice":
		fam_color = Color(0.30, 0.80, 0.95)
	elif ptype == "apple_pie":
		fam_color = Color(0.95, 0.75, 0.25)   # gold for Pie exit
	elif ptype == "dragon_fruit":
		fam_color = Color(0.35, 0.88, 0.45)   # green for DragonFruit exit
	elif ptype == "legendary":
		fam_color = Color(1.00, 0.85, 0.20)
	# Build label text. Two-line: icon+family/header on line 1, rarity on line 2.
	var line1: String
	var line2: String = ""
	if ptype == "boss":
		line1 = "%s BOSS" % icon
		line2 = String(preview.get("label", "")).replace("★ BOSS — ", "").replace("🐉 BOSS — ", "")
	elif ptype == "apple_juice":
		line1 = "%s JUICE" % icon
		line2 = "heals both heroes"
	elif ptype == "apple_pie":
		line1 = "%s PIE EXIT" % icon
		line2 = "+Max HP"
	elif ptype == "dragon_fruit":
		line1 = "%s DRAGONFRUIT" % icon
		line2 = "Level Up a Boon"
	elif ptype == "legendary":
		line1 = "%s LEGENDARY" % icon
		line2 = fam.to_upper()
	else:
		line1 = "%s %s" % [icon, fam.to_upper()]
		line2 = RunState.RARITY_LABEL.get(rarity, rarity.to_upper())
	# Look up the inner Label child we created (or the user-provided one).
	var inner: Label = g.label.get_node_or_null("Text") as Label
	if inner == null:
		# User-provided label might BE the Label itself.
		if g.label is Label:
			inner = g.label
	if inner:
		inner.text = "%s\n%s" % [line1, line2]
		# Color the text by family/type so each door reads as a different category.
		inner.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	# Style the backdrop panel border with the family color, if it's a PanelContainer.
	if g.label is PanelContainer:
		var sb: StyleBoxFlat = g.label.get_theme_stylebox("panel") as StyleBoxFlat
		if sb:
			var sb_copy: StyleBoxFlat = sb.duplicate() as StyleBoxFlat
			sb_copy.border_color = fam_color
			g.label.add_theme_stylebox_override("panel", sb_copy)
	g.label.visible = true


func _build_locked_indicator(g: Dictionary) -> void:
	if g.node == null:
		return
	var lbl := Label.new()
	lbl.name = "LockedIndicator"
	lbl.text = "🔒 LOCKED"
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.3, 1.0))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.position = Vector2(-48, -40)
	g.node.add_child(lbl)


func _spawn_depth_wall(g: Dictionary) -> void:
	# Adds a thin invisible StaticBody2D wall 12px past the gate's center so
	# characters can step a few pixels into the doorway but can't escape the arena.
	# Orientation is inferred from the gate's Visual aspect ratio:
	#   wider than tall  → horizontal gate (N/S wall) → wall blocks Y-axis movement
	#   taller than wide → vertical gate  (E/W wall) → wall blocks X-axis movement
	if g.node == null:
		return
	var gate_pos: Vector2 = (g.node as Node2D).global_position
	# Outward = away from the arena center (origin), snapped to the wall axis.
	var outward: Vector2
	if absf(gate_pos.y) >= absf(gate_pos.x):
		outward = Vector2(0.0, signf(gate_pos.y))
	else:
		outward = Vector2(signf(gate_pos.x), 0.0)
	var perp: Vector2 = Vector2(-outward.y, outward.x)   # runs ALONG the wall

	var open_half: float = 32.0    # half the doorway width (matches the wall gap)
	var depth: float = 50.0        # how far the back wall sits past the gate center
	var thick: float = 16.0

	# Goal-shaped pocket: a BACK wall caps the doorway (no escape into the void)
	# and two SIDE walls funnel it, so a hero can step a little way into the
	# doorway and press [E] there but can't slip out around the opening.
	var pocket := StaticBody2D.new()
	pocket.name = "DoorPocket"
	pocket.collision_layer = 1
	pocket.collision_mask = 0
	pocket.add_to_group("leap_blocker")   # Run 110 — exit pocket is a boundary; the Meteor leap stops here too

	var back := CollisionShape2D.new()
	var bshape := RectangleShape2D.new()
	bshape.size = Vector2(absf(perp.x) * (open_half * 2.0 + thick * 2.0) + absf(outward.x) * thick,
		absf(perp.y) * (open_half * 2.0 + thick * 2.0) + absf(outward.y) * thick)
	back.shape = bshape
	back.position = outward * depth
	pocket.add_child(back)

	for s in [-1.0, 1.0]:
		var side := CollisionShape2D.new()
		var sshape := RectangleShape2D.new()
		sshape.size = Vector2(absf(outward.x) * depth + absf(perp.x) * thick,
			absf(outward.y) * depth + absf(perp.y) * thick)
		side.shape = sshape
		side.position = outward * (depth * 0.5) + perp * (s * (open_half + thick * 0.5))
		pocket.add_child(side)

	pocket.global_position = gate_pos
	# Parent to scene root so it persists if the gate node ever moves.
	var scene_root: Node = get_tree().current_scene
	if scene_root:
		scene_root.add_child(pocket)


func _icon_for_preview(ptype: String, family: String) -> String:
	if ptype == "boss":
		return "👑"
	if ptype == "apple_juice":
		return "🧃"
	if ptype == "apple_pie":
		return "🥧"   # Pie exit
	if ptype == "dragon_fruit":
		return "🐉"   # DragonFruit exit
	if ptype == "legendary":
		return "✦"
	# Boon — pick by family.
	match family:
		"Apple":      return "🍎"
		"Coconut":    return "🥥"
		"Broccoli":   return "🥦"
		"Carrot":     return "🥕"
		"Grape":      return "🍇"
		"Watermelon": return "🍉"
		"Pepper":     return "🌶️"
		"Potato":     return "🥔"
		"Banana":     return "🍌"
		"Onion":      return "🧅"
		"Corrupt":    return "🔥"
	return "•"


# Run 23 — H key toggles controls hint; E key enters a nearby open gate.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_H:
		_toggle_controls_hint()
	elif event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_START:
		_toggle_controls_hint()


func _toggle_controls_hint() -> void:
	var hint: Label = get_node_or_null("DebugHUD/ControlsLabel")
	if hint:
		hint.visible = not hint.visible


# ---------------------------------------------------------------------------
# Gate control
# ---------------------------------------------------------------------------

func _open_gate(g: Dictionary) -> void:
	if g.opened:
		return
	g.opened = true
	if g.shape:
		g.shape.set_deferred("disabled", true)
	if g.visual:
		var tween: Tween = create_tween()
		tween.tween_property(g.visual, "color", GATE_OPEN_COLOR, 0.3)
	# Remove the LOCKED indicator and show the door preview label.
	if g.node:
		var lock_lbl: Node = g.node.get_node_or_null("LockedIndicator")
		if lock_lbl:
			lock_lbl.queue_free()
	if g.label:
		g.label.visible = true
	# Spawn a thin depth-wall 12px past the gate so characters can peek into the
	# doorway without escaping the arena. The wall is invisible but physically solid.
	_spawn_depth_wall(g)
	# If a player is already standing in the trigger zone and boon is collected,
	# show the E prompt immediately (body_entered already fired before gate opened).
	if _boon_collected and bool(_player_near_gate.get(String(g.name), false)):
		_show_gate_prompt(g, true)
	print("[World] Gate '%s' opened." % String(g.name))


func _open_all_gates() -> void:
	for g in _gates:
		_open_gate(g)


# ---------------------------------------------------------------------------
# Door trigger — body_entered fires when the player steps into a gate's
# DoorTrigger Area2D. The gate name is bound at signal-connect time so we
# can look up which preview was committed.
# ---------------------------------------------------------------------------

# -------------------------------------------------------
# Gate proximity tracking (body_entered / body_exited)
# -------------------------------------------------------
# Show "Press [E] to enter" prompt when player is near an OPEN gate.
# Actual transition requires pressing E — no walk-through accidents.

func _on_gate_player_entered(body: Node2D, gate_name: String) -> void:
	# Track Shino and Bea separately.
	if body.is_in_group("bea"):
		_bea_near_gate[gate_name] = true
	elif body.is_in_group("player"):
		_player_near_gate[gate_name] = true
	else:
		return
	var g: Dictionary = _find_gate_by_name(gate_name)
	if not g.is_empty() and g.opened and _boon_collected:
		_show_gate_prompt(g, _can_exit_gate(gate_name))


func _on_gate_player_exited(body: Node2D, gate_name: String) -> void:
	if body.is_in_group("bea"):
		_bea_near_gate[gate_name] = false
	elif body.is_in_group("player"):
		_player_near_gate[gate_name] = false
	else:
		return
	var g: Dictionary = _find_gate_by_name(gate_name)
	if not g.is_empty():
		_show_gate_prompt(g, _can_exit_gate(gate_name))


# Run 39 — AI rally point for the consensus exit. When Shino is standing in
# an OPEN gate's trigger zone, AI Bea should walk INTO that zone (the exit
# needs both heroes inside) instead of hovering at her usual follow distance.
# Returns the trigger's global position, or Vector2.INF when nobody's waiting.
func get_ai_gate_rally_pos() -> Vector2:
	if _transitioning or not _boon_collected:
		return Vector2.INF
	for g in _gates:
		if g.opened and bool(_player_near_gate.get(String(g.name), false)):
			if g.trigger != null:
				return (g.trigger as Node2D).global_position
			return (g.node as Node2D).global_position
	return Vector2.INF


# Returns true when it's OK to exit this gate.
# In 2-player: BOTH Shino and Bea must be in the trigger zone.
# In solo (no Bea in scene): only Shino required.
func _can_exit_gate(gate_name: String) -> bool:
	if not _boon_collected:
		return false
	var shino_near: bool = bool(_player_near_gate.get(gate_name, false))
	if not shino_near:
		return false
	# Check if Bea is present in scene.
	var beas: Array = get_tree().get_nodes_in_group("bea")
	if beas.is_empty():
		return true   # solo run — only Shino needed
	return bool(_bea_near_gate.get(gate_name, false))


func _show_gate_prompt(g: Dictionary, can_exit: bool) -> void:
	# Find or create a prompt label on the gate node.
	if g.node == null:
		return
	var prompt: Label = g.node.get_node_or_null("GateEnterPrompt") as Label
	if prompt == null:
		prompt = Label.new()
		prompt.name = "GateEnterPrompt"
		prompt.add_theme_font_size_override("font_size", 14)
		prompt.add_theme_color_override("font_color", Color(1.0, 1.0, 0.7))
		prompt.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.0))
		prompt.add_theme_constant_override("outline_size", 3)
		prompt.position = Vector2(-60, -52)
		prompt.z_index = 15
		g.node.add_child(prompt)

	# Show either the enter prompt or a "waiting for partner" hint.
	var beas: Array = get_tree().get_nodes_in_group("bea")
	var has_bea: bool = not beas.is_empty()
	var shino_near: bool = bool(_player_near_gate.get(String(g.name), false))
	var bea_near: bool   = bool(_bea_near_gate.get(String(g.name), false))
	var anyone_near: bool = shino_near or bea_near

	if not anyone_near or not _boon_collected:
		prompt.visible = false
	elif can_exit:
		prompt.text = "[E]  Enter"
		prompt.add_theme_color_override("font_color", Color(1.0, 1.0, 0.7))
		prompt.visible = true
	elif has_bea:
		# One player is near but not both — show waiting hint.
		prompt.text = "Waiting for partner..."
		prompt.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		prompt.visible = true
	else:
		prompt.visible = false


# -------------------------------------------------------
# E key → enter the nearest open gate
# -------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact") and not event.is_echo() and not _transitioning:
		for g in _gates:
			if g.opened and _can_exit_gate(String(g.name)):
				_commit_gate_transition(g)
				break


func _commit_gate_transition(g: Dictionary) -> void:
	if _transitioning:
		return
	_transitioning = true

	if not g.preview.is_empty():
		RunState.commit_door_choice(g.preview)

	# Cache HP/Chi carry-state and which character the human was controlling.
	for p in get_tree().get_nodes_in_group("player"):
		if not p.is_in_group("bea"):
			if p.has_method("get_current_hp") and p.has_method("get_current_chi"):
				RunState.cache_player_carry(p.get_current_hp(), p.get_current_chi())
			break
	var bea_nodes: Array = get_tree().get_nodes_in_group("bea")
	if bea_nodes.size() > 0:
		var bea: Node = bea_nodes[0]
		if bea.has_method("get_current_hp") and bea.has_method("get_current_chi"):
			RunState.cache_bea_carry(bea.get_current_hp(), bea.get_current_chi())
		# Run 30 — cache which character the human controls so next arena restores it.
		var bea_controlled: bool = bea.get("player_controlled") == true
		RunState.carry_player_controlled_char = 1 if bea_controlled else 0

	if is_final_in_loop:
		RunState.loops_completed += 1
		print("[World] Loop %d completed — wrapping back to Arena 1." % RunState.loops_completed)

	_pending_next_scene = next_scene_path
	print("[World] Gate '%s' entered via E — fading to: %s" % [String(g.name), _pending_next_scene])
	FX.fade_to_black(0.35, 0.05, 1.0, Callable(self, "_execute_transition"))


func _find_gate_by_name(gate_name: String) -> Dictionary:
	for g in _gates:
		if String(g.name) == gate_name:
			return g
	return {}


# Called by the FX fade_to_black tween when the screen is fully black.
func _execute_transition() -> void:
	# Record where we're headed so a resume load skips the Dojo and lands here.
	RunState.resume_scene_path = _pending_next_scene
	# Autosave into the active slot before the scene changes.
	if get_node_or_null("/root/SaveManager"):
		SaveManager.save_active_slot()
	get_tree().change_scene_to_file(_pending_next_scene)


# ---------------------------------------------------------------------------
# UI: active-boons label (optional — scene may or may not have one)
# ---------------------------------------------------------------------------

func _refresh_boons_label() -> void:
	# Old flat "Boons: ..." label replaced by the split per-character HUD panels.
	if boons_label != null:
		boons_label.visible = false
	# Delegate to HUD's split boon panel.
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("refresh_boon_panel"):
			h.refresh_boon_panel()
			break
