extends Node
# ============================================================
# Log.gd — autoload singleton "Log"  (Phase 1 — build hygiene)
# ============================================================
# Debug-gated logging. Replaces bare print() so that release builds
# ship quiet.
#
# WHY THIS EXISTS
# ---------------
# The project had 131 bare print() calls plus FX's SOUND_VERBOSE flag, all of
# which ran in exported builds. Console output in a shipping game is wasted
# CPU (the string is formatted even when nobody reads it) and leaks internal
# state to anyone who opens the console build.
#
# USAGE
# -----
#   Log.dbg("[Player] dashed")        # debug — EDITOR/DEBUG BUILDS ONLY
#   Log.info("[Save] slot 2 written") # info  — debug builds only
#   Log.warn("[Boon] unknown id")     # warning — ALWAYS (push_warning)
#   Log.err("[Save] write failed")    # error   — ALWAYS (push_error)
#
# dbg/info compile down to a single bool check in release. warn/err stay live
# in all builds because they surface real problems and Godot routes them to
# the crash log rather than stdout.
#
# ⚠ NAMING — DO NOT SHORTEN THESE TO d/i/w/e
# ------------------------------------------
# The obvious short names (d, i, w, e) are a trap in this codebase.
# tools/gdcheck.py resolves call sites by BARE FUNCTION NAME across all
# scripts. Every `print("... %d ..." % x)` in the project looks like a call to
# `d(...)` to its regex. Defining `func d()` anywhere therefore makes gdcheck
# report a false arity failure on every %d format specifier in the codebase —
# it flagged Boss2Enemy.gd:488 and RunState.gd:2517 immediately when this file
# first used the short names. Same trap applies to %s → s(), %f → f().
# Keep these names at 3+ letters. (Found and fixed 2026-07-31.)
#
# ONE-TIME LOGGING
# ----------------
#   Log.once("sfx_missing_hit_light", "no stream for hit_light")
# For per-frame code paths that would otherwise spam. The key is remembered
# for the lifetime of the process.
# ============================================================

## True in editor runs and debug exports, false in release exports.
var verbose: bool = OS.is_debug_build()

# Keys already emitted via once() / warn_once().
var _seen: Dictionary = {}


func _ready() -> void:
	# Must survive scene changes and keep working while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS


# ---------------------------------------------------------------------------
# Debug / info — stripped in release
# ---------------------------------------------------------------------------
func dbg(msg) -> void:
	if verbose:
		print(msg)


func info(msg) -> void:
	if verbose:
		print(msg)


# ---------------------------------------------------------------------------
# Warnings / errors — always live
# ---------------------------------------------------------------------------
func warn(msg) -> void:
	push_warning(str(msg))


func err(msg) -> void:
	push_error(str(msg))


# ---------------------------------------------------------------------------
# One-shot variants — safe to call from _process / per-frame code
# ---------------------------------------------------------------------------
## Prints once per unique key, debug builds only.
func once(key: String, msg) -> void:
	if not verbose:
		return
	if _seen.has(key):
		return
	_seen[key] = true
	print(msg)


## Warns once per unique key, in all builds.
func warn_once(key: String, msg) -> void:
	if _seen.has(key):
		return
	_seen[key] = true
	push_warning(str(msg))


## Clears the one-shot memory (useful when reloading a scene during testing).
func reset_once_keys() -> void:
	_seen.clear()
