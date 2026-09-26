extends RefCounted

# ============================================================
# CakeDojoRoom.gd — Run 171 (2026-09-02) — the Cake Dojo
# ============================================================
# The summit of the Dragon Cake Fortress is not a generic boss box: it is
# Shino & Bea's OWN DOJO, rebuilt in sugar. Same footprint, same walls, same
# doorways, same scroll on the same nail — and Shadow Sensei Z sits in the
# shrine alcove exactly where the real Sensei Z sits back home. That mirror
# IS the fight's staging.
#
# Run 173 — the room-building code moved to DojoRoomBuild.gd when the dream
# Training Room became a THIRD instance of the same building. Three
# hand-maintained copies of one wall table would drift; this file is now just
# the cake DRESS (which art folder, what colour the sky is). Nothing about the
# summit changed.
#
# Usage (ShadowSenseiArena.gd) — unchanged:
#     const ROOM = preload("res://scripts/CakeDojoRoom.gd")
#     ROOM.build(self)
# ============================================================

const BUILD = preload("res://scripts/DojoRoomBuild.gd")

const ART_DIR: String   = "res://Assets/Tilesets/CakeDojo_props/"
const FLOOR_DIR: String = ART_DIR + "floor/"
const WALL_DIR: String  = ART_DIR + "wall/"

# Deep berry-dark "outside" instead of the dojo's soot black: past these walls
# is open sky over the fortress, not another room.
const BACKDROP: Color = Color(0.09, 0.05, 0.10)

# Same seed as home ⇒ the same plank layout underfoot.
const TERRAIN_SEED: int = 4242


static func build(host: Node2D) -> void:
	BUILD.build(host, ART_DIR, FLOOR_DIR, WALL_DIR, BACKDROP, TERRAIN_SEED)
