extends Node

# ============================================================
# UltFreeze.gd — Run 168. THE global "everything stops" freeze for ultimates.
# ============================================================
# Autoload singleton. Registered in project.godot as:
#     UltFreeze="*res://scripts/UltFreeze.gd"
#
# ---- WHY THIS EXISTS -------------------------------------------------------
# Before Run 168, each hero froze enemies itself, like this:
#
#     for e in get_tree().get_nodes_in_group("enemy"):
#         e.process_mode = Node.PROCESS_MODE_DISABLED
#         _ult_freeze_targets.append(e)
#
# That is a ONE-SHOT SNAPSHOT taken at the instant the ult starts, and it had
# four holes that together caused Bruno's 2P bug report ("my ult kills Bea, or
# freezes her while enemies keep attacking her"):
#
#   1. ENEMIES THAT SPAWN MID-ULT were never in the snapshot, so they were never
#      frozen. They ran at full speed against a partner who was pinned by the
#      freeze-block and could not move, dodge or block. Free hits, every time.
#   2. PROJECTILES ALREADY IN FLIGHT (EnemyProjectile / PopsicleProjectile /
#      SnowballProjectile) are their OWN nodes parented to the scene, not
#      children of the enemy that fired them. Disabling the shooter does nothing
#      to a kunai that has already left the hand — it kept flying and hit the
#      frozen partner.
#   3. GROUND HAZARDS (TrapZone / IcyPatch / IceField / lava) are scene-level
#      Area2Ds too. Same story: they kept ticking damage onto someone standing
#      still because the game told her to stand still.
#   4. TWO OWNERS, ONE FLAG. Shino's snapshot, Bea's snapshot and DuoUlt's
#      snapshot could all hold the same enemy. Whoever finished first wrote
#      process_mode = INHERIT and un-froze enemies the other cinematic still
#      wanted frozen — or, in the duo hand-off, an enemy got restored twice and
#      an enemy that spawned between the two never got restored at all.
#
# ---- WHAT THIS DOES INSTEAD ------------------------------------------------
# ONE owner, and it RE-SCANS EVERY FRAME instead of snapshotting once:
#
#   • begin() marks the freeze active. _process() then sweeps the freeze groups
#     every single frame, so anything that spawns DURING the cinematic gets
#     caught on the very next frame instead of running free.
#   • For each node it freezes, it remembers that node's EXACT previous
#     process_mode, so end() restores the true prior value rather than blanket-
#     assigning PROCESS_MODE_INHERIT (which would silently "un-disable" a node
#     some other system had deliberately disabled).
#   • It NEVER touches a node that was already disabled when it first saw it —
#     that node belongs to someone else, and stealing it would mean restoring it
#     to the wrong state later.
#   • begin()/end() are reference-counted-ish via `active`: calling begin()
#     twice is a no-op, and end() is safe to call from every bail path.
#   • A WATCHDOG in _process force-ends the freeze if it is somehow still active
#     while no ult is running (scene change mid-ult, hero death mid-cinematic,
#     an await that never resumed because its node was freed). This is the same
#     defensive idea as RunState.validate_ult_freeze(), applied to the freeze
#     itself, so a leaked freeze can never permanently brick a room.
#
# ---- WHAT IT DELIBERATELY DOES NOT DO --------------------------------------
# It does not freeze the heroes. Heroes live in groups "player" / "bea", which
# are not in FREEZE_GROUPS. Hero stillness is handled by the freeze-block in
# Shino.gd / Bea.gd, and hero SAFETY is handled by the hard invulnerability gate
# in HeroBase.take_damage(). This node only stops the world.
# ============================================================

# Groups swept every frame while the freeze is active. "boss" / "miniboss" /
# "tutorial_enemy" are usually also in "enemy", which is harmless — the seen-set
# de-duplicates. They are listed explicitly so a future enemy type that forgets
# to join "enemy" still gets caught.
const FREEZE_GROUPS: Array[String] = [
	"enemy",
	"boss",
	"miniboss",
	"tutorial_enemy",
	"tutorial_boss",
	"enemy_attack",   # Run 168 — enemy projectiles now join this on _ready()
	"hazard_zone",
	"ice_field",
]

var active: bool = false

# node instance id -> the process_mode that node had BEFORE we froze it.
# Keyed by id (not the node) so a freed node can't keep a reference alive.
var _restore: Dictionary = {}
# Parallel list of the actual node refs, so end() can validate + restore them.
var _frozen: Array = []

# Run 168 — the scene this freeze belongs to. Used to detect a room change under
# a running ult (see _process). Weak by design: we only ever compare identity
# and validity, never dereference it.
var _owner_scene: Node = null


func _ready() -> void:
	# Must keep sweeping even if something pauses the tree mid-cinematic
	# (a boon offer, the pause menu) — otherwise the watchdog can't recover.
	process_mode = Node.PROCESS_MODE_ALWAYS


# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------

# Start the world-freeze. Idempotent: calling it again while already active
# just keeps the existing freeze (the duo hand-off relies on this — the solo
# ult's freeze carries straight through into the duo cinematic with no gap
# where enemies get a free frame of movement).
func begin() -> void:
	if active:
		_sweep()
		return
	active = true
	_restore.clear()
	_frozen.clear()
	_owner_scene = get_tree().current_scene if get_tree() != null else null
	_sweep()


# Release everything this node froze, restoring each node's true prior mode.
# Safe to call when not active, and safe to call twice.
func end() -> void:
	if not active and _frozen.is_empty():
		return
	active = false
	for n in _frozen:
		if not is_instance_valid(n):
			continue
		var key: int = n.get_instance_id()
		if _restore.has(key):
			n.process_mode = int(_restore[key])
		else:
			n.process_mode = Node.PROCESS_MODE_INHERIT
	_restore.clear()
	_frozen.clear()
	_owner_scene = null


# --------------------------------------------------------------------------
# Per-frame sweep + watchdog
# --------------------------------------------------------------------------
func _process(_delta: float) -> void:
	if not active:
		return
	# ------------------------------------------------------------------
	# ROOM-CHANGE HOOK. This is the ONE central place a scene swap during an
	# ultimate is caught.
	# ------------------------------------------------------------------
	# There are ~20 change_scene_to_file() call sites across the codebase (doors,
	# boss arenas, the death screen, the pause menu, the dream hub…). Patching a
	# reset into every one of them would be 20 chances to miss one, and the one
	# that got missed would be the one that ships. Polling current_scene from the
	# single autoload that already has a _process costs one comparison per frame
	# and covers every present and FUTURE transition site for free.
	#
	# What it prevents: an ult interrupted by a room change leaves the splash
	# CanvasLayer over the new scene, every enemy in the OLD room still recorded
	# as frozen, and RunState.ult_cinematic_active() stuck true — which, via the
	# invulnerability gate in HeroBase.take_damage(), would make the entire next
	# room un-damageable for both heroes and every enemy target.
	var tree: SceneTree = get_tree()
	if tree != null and _owner_scene != null:
		if not is_instance_valid(_owner_scene) or tree.current_scene != _owner_scene:
			Log.dbg("[UltFreeze] Scene changed during an ult — hard-resetting all ult state.")
			RunState.reset_ult_state()
			return
	# WATCHDOG — if the freeze is somehow still up but nothing is actually
	# ulting, drop it. Without this, one bad await (hero freed mid-cinematic,
	# an ult that died between phases) would leave every enemy in the run
	# disabled with no way back.
	if not RunState.ult_cinematic_active():
		Log.dbg("[UltFreeze] Watchdog: freeze was active with no ult running — releasing.")
		end()
		return
	_sweep()


# Freeze anything in the freeze groups that isn't frozen yet. Runs every frame
# so mid-cinematic spawns are caught within one frame.
func _sweep() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	for g in FREEZE_GROUPS:
		for n in tree.get_nodes_in_group(g):
			if not is_instance_valid(n) or not (n is Node):
				continue
			var key: int = n.get_instance_id()
			if _restore.has(key):
				continue   # already ours
			# Never adopt a node somebody else has already disabled — we would
			# restore it to the wrong state when the cinematic ends.
			if n.process_mode == Node.PROCESS_MODE_DISABLED:
				continue
			_restore[key] = n.process_mode
			_frozen.append(n)
			n.process_mode = Node.PROCESS_MODE_DISABLED
