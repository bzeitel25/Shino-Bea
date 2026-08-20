extends Node
# ============================================================
# Bootstrap.gd — autoload singleton "Bootstrap"  (Phase 1)
# ============================================================
# FIRST autoload in the list. Owns process-level setup that has to happen
# before anything else wakes up.
#
# Two jobs:
#   1. Strip developer-only autoloads out of RELEASE builds.
#   2. Re-assert the Run 160 display lock at runtime.
#
# ============================================================
# JOB 1 — strip dev autoloads from release builds
# ============================================================
# The MCP plugin INJECTS three autoloads into project.godot at runtime
# (see the header of addons/godot_mcp/mcp_screenshot_service.gd):
#
#     MCPScreenshot     — runs FileAccess.file_exists() EVERY FRAME
#     MCPInputService   — synthesises input via Input.parse_input_event()
#     MCPGameInspector  — reads/dumps live scene state
#
# Those are editor tools. Shipping them means every player's copy does a
# filesystem stat every frame forever, and carries a remote input injector.
# Because the plugin re-adds them whenever the editor runs, deleting the lines
# from project.godot by hand does not stick — verified: they were re-added
# during this very session. So this guard is belt-and-braces with the export
# exclude_filter in export_presets.cfg.
#
# NetDebug (the F9 netcode overlay) is stripped too — its own header says
# "This is scaffolding, not the shipping UI".
#
# ⚠ EXACT-NAME matching is used for NetDebug, NOT a prefix, because `Net` and
# `NetDiscovery` are gameplay-critical online-multiplayer autoloads that must
# survive into release. A "Net" prefix rule would silently kill online play.
#
# In editor / debug builds this does nothing at all, so both the MCP workflow
# and the F9 net console are completely unaffected.
#
# ============================================================
# JOB 2 — enforce the Run 160 display lock
# ============================================================
# Run 160 fixed blurry/stretched fullscreen by setting three project settings:
#     stretch/mode = "canvas_items", aspect = "keep", scale_mode = "fractional"
#
# PROBLEM DISCOVERED 2026-07-31: Godot prunes any project setting whose value
# equals the engine default when it rewrites project.godot. `aspect="keep"`,
# `scale_mode="fractional"` and `size/resizable=true` ARE the Godot 4 defaults,
# so the editor silently deleted all three lines from the file mid-session.
# Behaviour is unchanged TODAY — but the lock is now invisible, and a future
# engine default change or a stray editor edit would break fullscreen with
# nothing in the project to show it ever mattered.
#
# Asserting it here makes the lock real instead of implied. Cheap (three
# property writes at boot) and self-documenting.
# ============================================================

## Autoloads removed in release builds, matched by NAME PREFIX.
const DEV_AUTOLOAD_PREFIXES: Array[String] = ["MCP"]

## Autoloads removed in release builds, matched by EXACT NAME.
## Exact match matters — see the Net/NetDiscovery warning above.
const DEV_AUTOLOAD_NAMES: Array[String] = ["NetDebug"]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_enforce_display_lock()
	# Phase 3c — intercept the window's X button so we can save first.
	get_tree().set_auto_accept_quit(false)
	# Deferred: /root's autoload children are still being added while the first
	# autoload's _ready() runs. Waiting one frame guarantees we see all of them.
	call_deferred("_strip_dev_autoloads")


# ---------------------------------------------------------------------------
# JOB 3 — save on window close  (Phase 3c)
# ---------------------------------------------------------------------------
# Closing the window used to drop everything since the last checkpoint, because
# saves only happened at gates, the Dojo, and run end.
#
# No confirmation dialog here on purpose: clicking the X is an unambiguous
# instruction. We just make sure it isn't destructive. The confirm prompt lives
# on the in-game QUIT buttons, where a mis-click is plausible.
#
# set_auto_accept_quit(false) in _ready() is what routes the close request here
# instead of letting the engine exit immediately — so this handler MUST call
# quit() itself or the window would refuse to close.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_and_quit()


func _save_and_quit() -> void:
	var sm: Node = get_node_or_null("/root/SaveManager")
	if sm != null and sm.has_method("save_active_slot") \
			and "active_slot" in sm and int(sm.active_slot) >= 0:
		# Atomic since Phase 3a — a crash during this write cannot corrupt the slot.
		sm.save_active_slot()
	get_tree().quit()


# ---------------------------------------------------------------------------
# Run 160 display lock
# ---------------------------------------------------------------------------
func _enforce_display_lock() -> void:
	var w: Window = get_tree().root
	if w == null:
		return
	# Equivalent to stretch/aspect="keep" + scale_mode="fractional".
	# stretch/mode="canvas_items" is still written in project.godot (it is NOT
	# a default) so it does not need re-asserting — but we check it and shout
	# in debug if something ever changes it.
	w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	w.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL

	if OS.is_debug_build():
		if w.content_scale_mode != Window.CONTENT_SCALE_MODE_CANVAS_ITEMS:
			push_warning("[Bootstrap] Run 160 LOCK VIOLATED: stretch mode is not "
				+ "canvas_items. Fullscreen will look soft/blurry. "
				+ "Fix project.godot -> [display] window/stretch/mode=\"canvas_items\".")


# ---------------------------------------------------------------------------
# Dev-autoload strip
# ---------------------------------------------------------------------------
func _strip_dev_autoloads() -> void:
	if OS.is_debug_build():
		return   # editor + debug exports keep the full dev toolchain

	var root: Node = get_tree().root
	if root == null:
		return

	var removed: Array[String] = []
	for child in root.get_children():
		if _is_dev_autoload(child.name):
			removed.append(child.name)
			# Stop it ticking now, so it cannot run again between here and the
			# queue_free landing at end of frame.
			child.set_process(false)
			child.set_physics_process(false)
			child.queue_free()

	if removed.size() > 0:
		var lg: Node = get_node_or_null("/root/Log")
		if lg and lg.has_method("dbg"):
			lg.dbg("[Bootstrap] Stripped dev autoloads: %s" % str(removed))


func _is_dev_autoload(node_name: String) -> bool:
	# Exact matches first — narrowest rule wins.
	if DEV_AUTOLOAD_NAMES.has(node_name):
		return true
	for prefix in DEV_AUTOLOAD_PREFIXES:
		if node_name.begins_with(prefix):
			return true
	return false
