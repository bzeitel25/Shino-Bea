extends Node2D
# ============================================================
# SealedBarrier.gd — Run 109 (2026-06-22)
# ============================================================
# Rubble that plugs a CLOSED dream-room exit. Flips its own z each frame
# against the nearest hero so the pile occludes correctly:
#
#   * Hero on the OPEN (interior) side  → pile draws BEHIND the hero (z = -1).
#   * Hero DEEPER than the pile         → pile draws IN FRONT (z = 3).
#
# `occ_offset_y` is the pile's centre Y relative to the gate line.
# ============================================================

@export var occ_offset_y: float = 0.0

const Z_BEHIND: int = -1  # below hero sprite (z=0)
const Z_FRONT:  int = 3   # RunState.BARRIER_OVERHANG_Z

func _ready() -> void:
	z_as_relative = false
	z_index = Z_BEHIND

func _process(_dt: float) -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var ref_y: float = global_position.y + occ_offset_y
	var best_d: float = INF
	var chosen_y: float = ref_y + 1.0   # default → behind when no hero found
	for nm in ["Player", "Bea"]:
		var h: Node = scene.get_node_or_null(nm)
		if h is Node2D:
			var d: float = ((h as Node2D).global_position - global_position).length_squared()
			if d < best_d:
				best_d = d
				chosen_y = (h as Node2D).global_position.y
	z_index = Z_BEHIND if chosen_y >= ref_y else Z_FRONT
