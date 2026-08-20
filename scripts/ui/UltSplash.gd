extends Node

# ============================================================
# UltSplash.gd — Run 168. Per-hero ultimate splash frames + the duo window.
# ============================================================
# Autoload singleton. Registered in project.godot as:
#     UltSplash="*res://scripts/ui/UltSplash.gd"
#
# ---- WHAT THIS IS ----------------------------------------------------------
# Run 150 gave the DUO ult a split-frame: two diagonal manga panels, one per
# ninja, portraits slamming in from opposite sides. It only ever existed for the
# combined ult, and there was no window in which to DECIDE to combine — the duo
# was triggered by hijacking an ult that was already mid-swing.
#
# Run 168 pulls that split-frame out into this file and makes it the FRONT DOOR
# of every ultimate:
#
#     press ult  ->  [ SPLASH: 1.75s, one panel ]  ->  attack animation
#                          ^
#                          |  partner presses ult HERE (and only here)
#                          v
#                    [ SPLASH: both panels, duo banner ]  ->  duo cinematic
#
#   • Shino's panel is ALWAYS the LEFT half and slides DOWN from above.
#   • Bea's panel is ALWAYS the RIGHT half and slides UP from below.
#     Fixed sides are the whole point: when one panel is up, the other player
#     instantly knows which half is "theirs" and that it is empty.
#   • If the partner has a full Chi meter and is on their feet, a pulsing
#     "ULT NOW!" call-to-action appears on the EMPTY half in their colour. It is
#     an invitation, never a requirement — ignore it and the solo ult fires.
#   • The window is 1.75s of real hold on top of the slide-in, which is inside
#     Bruno's "a good 1.5-2 sec" ask and long enough to shout across a couch.
#
# ---- THE LOCK-IN CONTRACT (this is the important bit) ----------------------
# RunState.ult_locked_in flips TRUE the instant this splash finishes. From that
# moment the ult belongs to whoever cast it and NOTHING can convert it — the
# partner's ult button does nothing, and DuoUlt.request() hard-refuses. That is
# what kills the old "hijack an ult already in flight" path, which was the
# source of the half-transitioned states where Bea ended up frozen mid-cinematic
# with her own ult flags still set.
#
# ---- NAMES + KANJI (Bruno's picks, Run 168) --------------------------------
#   Shino  FINAL KI BLAST   気弾      KIDAN     "ki-bullet" — the established
#                                               anime term for an energy blast.
#   Bea    THOUSAND CUTS    千斬      SENZAN    千 thousand + 斬 (the sword-
#                                               specific "cut down").
#   Duo    KI PRISM MIRROR CUT
#                           気稜鏡斬  KI-RYOKYO-ZAN
#          Built as Shino's FIRST character + Bea's LAST character with the
#          prism-mirror compound between them:  気 |稜鏡| 斬
#          So the duo name literally opens with his ult and closes with hers.
#          (稜鏡 is the Sino-Japanese word for prism — lit. "edged mirror".)
#
# Romaji is deliberately written WITHOUT macrons (RYOKYO, not RYŌKYŌ): Ō/ō
# (U+014C/U+014D) are absent from Press Start 2P, Silkscreen AND DotGothic16 —
# verified against the font cmaps — so a macron would render as a tofu box.
#
# ---- ART ------------------------------------------------------------------
# No new assets. Every panel is built from what already ships: the hero's LIVE
# sprite frame as the portrait (via duo_ult_face_texture()), procedural manga
# speed-lines, Polygon2D panels, and the three OFL pixel fonts already loaded by
# UISkin. Kanji come from DotGothic16 (the only shipped font with CJK coverage).
# Drop real splash art in later by replacing _add_portrait() — nothing else
# needs to change.
# ============================================================

# ---- Timing ---------------------------------------------------------------
const SLIDE_IN: float   = 0.20   # panel flies into its slot
const HOLD_DUR: float   = 1.75   # <-- the duo window. Bruno asked for 1.5-2s.
const DUO_HOLD: float   = 1.00   # extra beat after the second panel lands
const SLIDE_OUT: float  = 0.16   # panels leave the way they came

# ---- Per-hero presentation -------------------------------------------------
const COL_SHINO: Color = Color(0.30, 0.85, 1.00)   # cyan ki
const COL_BEA: Color   = Color(1.00, 0.50, 0.95)   # magenta blade
const COL_DUO: Color   = Color(1.00, 0.97, 0.78)   # golden prism light

const DUO_KANJI: String  = "気稜鏡斬"
const DUO_ROMAJI: String = "KI-RYOKYO-ZAN"
const DUO_NAME: String   = "KI PRISM MIRROR CUT"

# ---- Live state ------------------------------------------------------------
var active: bool = false          # a splash is on screen right now
var _hero_id: String = ""         # who opened it
var _promoted: bool = false       # partner joined -> this is a duo
var _layer: CanvasLayer = null
var _panels: Dictionary = {}      # hero_id -> panel root Node2D
var _panel_text: Dictionary = {}  # hero_id -> Array[Control] (kanji/name/romaji)
var _prompt_root: Node2D = null   # the "ULT NOW!" call-to-action
var _slash: Line2D = null         # energy line down the diagonal seam
var _duo_banner: Node2D = null


func _ready() -> void:
	# The splash must animate even if something pauses the tree underneath it.
	process_mode = Node.PROCESS_MODE_ALWAYS


# --------------------------------------------------------------------------
# Static presentation lookup
# --------------------------------------------------------------------------
func _info(hero_id: String) -> Dictionary:
	if hero_id == "bea":
		return {
			"kanji": "千斬",
			"romaji": "SENZAN",
			"name": "THOUSAND CUTS",
			"who": "BEA",
			"color": COL_BEA,
			"bg": Color(0.14, 0.05, 0.16, 0.96),
		}
	return {
		"kanji": "気弾",
		"romaji": "KIDAN",
		"name": "FINAL KI BLAST",
		"who": "SHINO",
		"color": COL_SHINO,
		"bg": Color(0.05, 0.10, 0.16, 0.96),
	}


# --------------------------------------------------------------------------
# PUBLIC — play the splash for one hero. Awaited by _start_ult().
# Returns "duo" if the partner joined during the window, else "solo".
# --------------------------------------------------------------------------
func play(hero_id: String) -> String:
	if active:
		return "solo"   # never stack two splashes
	active = true
	_hero_id = hero_id
	_promoted = false
	RunState.ult_splash_active = true
	RunState.ult_splash_hero = hero_id
	RunState.ult_splash_joiner = ""
	RunState.ult_locked_in = false

	_build_layer()
	_build_panel(hero_id)
	_build_seam_slash()
	var partner: String = "bea" if hero_id == "shino" else "shino"
	if _partner_can_join(partner):
		_build_ult_now_prompt(partner)

	# A distinct CHARGE sting for the splash. Deliberately not "ult_fire" — the
	# heroes each play their own fire sound when the attack actually starts
	# (Shino "ult_fire", Bea "bea_ult_fire"), and using it here too made every
	# solo ult trigger the same cue twice a couple of seconds apart.
	FX.play_sound("duo_ult_charge", 1.1)
	FX.screen_shake(FX.SHAKE_MEDIUM, FX.SHAKE_DUR_SHORT)
	await _slide_panel_in(hero_id)

	# ---- THE WINDOW ----
	# Poll rather than one long await so promote() can cut it short the frame
	# the partner presses. get_process_delta_time() is correct here: this node
	# is PROCESS_MODE_ALWAYS, so it ticks even through a pause.
	var t: float = 0.0
	while t < HOLD_DUR and not _promoted:
		await get_tree().process_frame
		# Bail on ANY of: an explicit force_close, or the frame being torn out
		# from under us. This node is an autoload at PROCESS_MODE_ALWAYS, so this
		# loop keeps running straight through a scene change while _layer and the
		# panels — children of the OLD current_scene — get freed. Without this
		# check the loop would run to full duration and then touch dead nodes on
		# the way out, leaving `active` stuck true and killing every future
		# splash (and therefore every future duo) for the rest of the session.
		if not active or _layer == null or not is_instance_valid(_layer):
			_abandon()
			return "solo"
		t += get_process_delta_time()

	if _promoted:
		await get_tree().create_timer(DUO_HOLD).timeout

	# ---- LOCK IN ----
	# From this line on the ult cannot be converted. Order matters: clear the
	# splash flags BEFORE the slide-out await, so a partner button-mash during
	# the 0.16s exit animation can't sneak a late promote() through.
	RunState.ult_locked_in = true
	RunState.ult_splash_active = false

	await _slide_all_panels_out()
	_teardown()
	var outcome: String = "duo" if _promoted else "solo"
	active = false

	# The duo cinematic starts HERE, not inside DuoUlt.request(). request() only
	# validates and arms; kicking the cinematic off from the splash's tail means
	# it begins on a clean frame with the frame fully torn down and no solo
	# coroutine still unwinding underneath it. Fire-and-forget on purpose — the
	# caster's _start_ult() returns the moment it sees "duo", and DuoUlt owns
	# both ninjas from that point until its own _cleanup().
	if outcome == "duo":
		DuoUlt.start_cinematic()
	return outcome


# --------------------------------------------------------------------------
# PUBLIC — the partner pressed ult inside the window. Called by DuoUlt.request().
# Returns false if the window has closed (caller must then NOT start a duo).
# --------------------------------------------------------------------------
func promote(joiner_id: String) -> bool:
	if not active or _promoted or RunState.ult_locked_in:
		return false
	if joiner_id == _hero_id:
		return false
	_promoted = true
	RunState.ult_splash_joiner = joiner_id

	# The invitation has been accepted — retire the prompt.
	if _prompt_root != null and is_instance_valid(_prompt_root):
		var pt := create_tween()
		pt.tween_property(_prompt_root, "modulate:a", 0.0, 0.10)
		pt.tween_callback(Callable(_prompt_root, "queue_free"))
		_prompt_root = null

	# Second panel flies into ITS slot from ITS side.
	_build_panel(joiner_id)
	_slide_panel_in(joiner_id)

	# The seam detonates as the two frames meet.
	_flare_seam()
	_screen_flash(Color(1.0, 1.0, 1.0, 0.65), 0.22)
	FX.screen_shake(FX.SHAKE_HEAVY, FX.SHAKE_DUR_MED)
	FX.play_sound("duo_ult_activate", 1.4)

	# Per-hero titles fade out; the combined banner takes the centre.
	_fade_out_panel_text()
	_build_duo_banner()
	return true


# --------------------------------------------------------------------------
# PUBLIC — emergency close (room change, hero died mid-splash, scene teardown).
# Leaves RunState clean so nothing downstream sees a half-open window.
# --------------------------------------------------------------------------
func force_close() -> void:
	if not active:
		return
	# If the duo was ARMED (partner pressed in the window) but its cinematic has
	# not started yet, disarm it — otherwise DuoUlt.active sticks true forever and
	# every future duo request bounces off its own re-entry guard. See
	# DuoUlt.abort().
	if _promoted:
		var duo: Node = get_node_or_null("/root/DuoUlt")
		if duo != null and duo.has_method("abort"):
			duo.call("abort")
	active = false
	_promoted = false
	RunState.ult_splash_active = false
	RunState.ult_locked_in = true
	_teardown()


# Internal sibling of force_close() for the case where the splash's own frame
# was destroyed under it (room change) rather than someone asking it to close.
# Same teardown, but it does NOT set ult_locked_in — the caller's _start_ult()
# is about to bail anyway, and leaving the latch clear means the NEXT ult's duo
# window opens normally instead of being refused by a stale lock.
func _abandon() -> void:
	if _promoted:
		var duo: Node = get_node_or_null("/root/DuoUlt")
		if duo != null and duo.has_method("abort"):
			duo.call("abort")
	active = false
	_promoted = false
	RunState.ult_splash_active = false
	RunState.ult_locked_in = false
	_teardown()


# --------------------------------------------------------------------------
# Can the partner realistically join? Drives the "ULT NOW!" prompt only —
# DuoUlt.request() re-validates authoritatively before anything commits.
# --------------------------------------------------------------------------
func _partner_can_join(partner_id: String) -> bool:
	var p: Node = _find_hero(partner_id)
	if p == null or not is_instance_valid(p):
		return false
	if "current_hp" in p and int(p.current_hp) <= 0:
		return false
	# is_downed() is the REAL predicate — heroes have a "semi-alive" DOWNED state
	# at positive HP, and nothing in the codebase ever calls add_to_group("downed"),
	# so the group test this replaces was permanently false.
	if p.has_method("is_downed") and p.is_downed():
		return false
	if not ("current_chi" in p):
		return false
	var cost: int = max(1, int(round(100.0 * RunState.tide_master_ult_cost_mult(partner_id))))
	return int(p.current_chi) >= cost


func _find_hero(hero_id: String) -> Node:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	if hero_id == "bea":
		for n in tree.get_nodes_in_group("bea"):
			if is_instance_valid(n):
				return n
		return null
	# Shino is in "player" but NOT in "bea" (Bea joins "player" so door triggers
	# see her, so the group alone is not enough to identify him).
	for n in tree.get_nodes_in_group("player"):
		if is_instance_valid(n) and not n.is_in_group("bea"):
			return n
	return null


# ==========================================================================
# Build
# ==========================================================================
func _build_layer() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 60
	# UISkin's theme walker must never touch these hand-built labels — the
	# Run 166 boon-card bug was exactly this (the walker clobbered hand-set
	# styles and a later cast came back null).
	_layer.set_meta("_uiskin_skip", true)
	var scene: Node = get_tree().current_scene
	if scene == null:
		scene = get_tree().root
	scene.add_child(_layer)
	_panels.clear()
	_panel_text.clear()


func _vp() -> Vector2:
	return get_viewport().get_visible_rect().size


# Diagonal seam x-positions. The panel is a parallelogram, not a rectangle —
# that slight lean is what makes it read as a manga action frame.
func _seam() -> Vector2:
	var w: float = _vp().x
	return Vector2(w * 0.56, w * 0.44)   # (top_x, bottom_x)


func _build_panel(hero_id: String) -> void:
	if _panels.has(hero_id):
		return
	var vp: Vector2 = _vp()
	var W: float = vp.x
	var H: float = vp.y
	var seam: Vector2 = _seam()
	var inf: Dictionary = _info(hero_id)
	var col: Color = inf["color"]
	var is_left: bool = (hero_id == "shino")

	var root := Node2D.new()
	_layer.add_child(root)
	_panels[hero_id] = root

	# --- panel background ---
	var bg := Polygon2D.new()
	if is_left:
		bg.polygon = PackedVector2Array([
			Vector2(0, 0), Vector2(seam.x, 0), Vector2(seam.y, H), Vector2(0, H)])
	else:
		bg.polygon = PackedVector2Array([
			Vector2(seam.x, 0), Vector2(W, 0), Vector2(W, H), Vector2(seam.y, H)])
	bg.color = inf["bg"]
	root.add_child(bg)

	# --- manga speed-lines radiating behind the figure ---
	var focus: Vector2 = Vector2(W * 0.26, H * 0.50) if is_left else Vector2(W * 0.74, H * 0.50)
	_add_speed_lines(root, focus, col, 1.0 if is_left else -1.0)

	# --- portrait (hero's live sprite frame) ---
	var portrait_pos: Vector2 = Vector2(W * 0.27, H * 0.56) if is_left else Vector2(W * 0.73, H * 0.56)
	_add_portrait(root, hero_id, portrait_pos, H, col, not is_left)

	# --- text block ---
	var half_left: float = 0.0 if is_left else W * 0.50
	var half_w: float = W * 0.50
	var texts: Array = []

	# Kanji — the hero read. DotGothic16 is the only shipped font with CJK.
	var kanji := _mk_label(String(inf["kanji"]), UISkin.font_body,
		int(clamp(H * 0.21, 44.0, 168.0)), Color(1, 1, 1, 0.98), col, 12)
	kanji.position = Vector2(half_left, H * 0.06)
	kanji.size = Vector2(half_w, H * 0.26)
	root.add_child(kanji)
	texts.append(kanji)

	# English ult name.
	var nm := _mk_label(String(inf["name"]), UISkin.font_display,
		int(clamp(W * 0.020, 10.0, 30.0)), Color(1, 1, 1, 0.95), col, 8)
	nm.position = Vector2(half_left, H * 0.78)
	nm.size = Vector2(half_w, H * 0.08)
	root.add_child(nm)
	texts.append(nm)

	# Romaji reading, one notch quieter.
	var rj := _mk_label(String(inf["romaji"]), UISkin.font_micro,
		int(clamp(W * 0.014, 8.0, 20.0)), Color(col.r, col.g, col.b, 0.90),
		Color(0, 0, 0, 0.9), 5)
	rj.position = Vector2(half_left, H * 0.86)
	rj.size = Vector2(half_w, H * 0.06)
	root.add_child(rj)
	texts.append(rj)

	_panel_text[hero_id] = texts

	# Park it off-screen on ITS OWN axis: Shino above, Bea below.
	root.position = _offscreen_offset(hero_id)


# Shino drops DOWN from above; Bea rises UP from below. (Bruno, Run 168.)
func _offscreen_offset(hero_id: String) -> Vector2:
	var H: float = _vp().y
	return Vector2(0.0, -H) if hero_id == "shino" else Vector2(0.0, H)


func _slide_panel_in(hero_id: String) -> void:
	# NOTE: fetched UNTYPED and validity-checked before any typed use. Assigning a
	# freed instance to a `: Node2D` local raises "Trying to assign invalid
	# previously freed instance" in a debug build and aborts the coroutine BEFORE
	# the is_instance_valid() guard can run. These panels are children of a
	# CanvasLayer parented to current_scene, so a room change frees them out from
	# under us — exactly the case this has to survive.
	var raw: Variant = _panels.get(hero_id, null)
	if raw == null or not is_instance_valid(raw):
		return
	var root: Node2D = raw as Node2D
	if root == null:
		return
	var tw := create_tween()
	tw.tween_property(root, "position", Vector2.ZERO, SLIDE_IN) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if _slash != null and is_instance_valid(_slash):
		tw.parallel().tween_property(_slash, "default_color:a", 0.95, SLIDE_IN * 0.7)
	await tw.finished


func _slide_all_panels_out() -> void:
	var tw := create_tween()
	tw.set_parallel(true)
	var any: bool = false
	for hid in _panels.keys():
		# Untyped fetch + validity check first — see the note in _slide_panel_in.
		var raw: Variant = _panels[hid]
		if raw == null or not is_instance_valid(raw):
			continue
		var root: Node2D = raw as Node2D
		if root == null:
			continue
		any = true
		tw.tween_property(root, "position", _offscreen_offset(hid), SLIDE_OUT) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	if _slash != null and is_instance_valid(_slash):
		any = true
		tw.tween_property(_slash, "default_color:a", 0.0, SLIDE_OUT)
	if _duo_banner != null and is_instance_valid(_duo_banner):
		any = true
		tw.tween_property(_duo_banner, "modulate:a", 0.0, SLIDE_OUT)
	if not any:
		tw.kill()
		return
	await tw.finished


func _teardown() -> void:
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_panels.clear()
	_panel_text.clear()
	_prompt_root = null
	_slash = null
	_duo_banner = null


# --------------------------------------------------------------------------
# Seam — the energy line down the diagonal, and its duo detonation
# --------------------------------------------------------------------------
func _build_seam_slash() -> void:
	var H: float = _vp().y
	var seam: Vector2 = _seam()
	_slash = Line2D.new()
	_slash.width = 10.0
	_slash.default_color = Color(1.0, 1.0, 1.0, 0.0)
	_slash.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_slash.end_cap_mode = Line2D.LINE_CAP_ROUND
	_slash.points = PackedVector2Array([Vector2(seam.x, -20.0), Vector2(seam.y, H + 20.0)])
	_layer.add_child(_slash)


func _flare_seam() -> void:
	if _slash == null or not is_instance_valid(_slash):
		return
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_slash, "width", 42.0, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_slash, "default_color", Color(1.0, 1.0, 1.0, 1.0), 0.10)
	tw.set_parallel(false)
	tw.tween_property(_slash, "width", 12.0, 0.30).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(_slash, "default_color",
		Color(COL_DUO.r, COL_DUO.g, COL_DUO.b, 0.95), 0.30)


# --------------------------------------------------------------------------
# "ULT NOW!" — the invitation on the empty half
# --------------------------------------------------------------------------
func _build_ult_now_prompt(partner_id: String) -> void:
	var vp: Vector2 = _vp()
	var W: float = vp.x
	var H: float = vp.y
	var inf: Dictionary = _info(partner_id)
	var col: Color = inf["color"]
	var on_left: bool = (partner_id == "shino")

	_prompt_root = Node2D.new()
	_layer.add_child(_prompt_root)

	# Soft scrim so the text reads over live gameplay without hiding it.
	var scrim := Polygon2D.new()
	var seam: Vector2 = _seam()
	if on_left:
		scrim.polygon = PackedVector2Array([
			Vector2(0, 0), Vector2(seam.x, 0), Vector2(seam.y, H), Vector2(0, H)])
	else:
		scrim.polygon = PackedVector2Array([
			Vector2(seam.x, 0), Vector2(W, 0), Vector2(W, H), Vector2(seam.y, H)])
	scrim.color = Color(col.r * 0.25, col.g * 0.25, col.b * 0.25, 0.32)
	_prompt_root.add_child(scrim)

	var half_left: float = 0.0 if on_left else W * 0.50
	var half_w: float = W * 0.50

	var big := _mk_label("ULT NOW!", UISkin.font_display,
		int(clamp(W * 0.030, 14.0, 46.0)), Color(1, 1, 1, 1), col, 10)
	big.position = Vector2(half_left, H * 0.44)
	big.size = Vector2(half_w, H * 0.10)
	_prompt_root.add_child(big)

	var sub := _mk_label("%s READY  —  PRESS ULT TO COMBINE" % String(inf["who"]),
		UISkin.font_micro, int(clamp(W * 0.012, 8.0, 18.0)),
		Color(col.r, col.g, col.b, 0.95), Color(0, 0, 0, 0.9), 5)
	sub.position = Vector2(half_left, H * 0.55)
	sub.size = Vector2(half_w, H * 0.06)
	_prompt_root.add_child(sub)

	# Heartbeat pulse — reads as urgent without being an epileptic strobe.
	var pulse := create_tween()
	pulse.set_loops()
	pulse.tween_property(big, "modulate:a", 0.35, 0.28).set_trans(Tween.TRANS_SINE)
	pulse.tween_property(big, "modulate:a", 1.00, 0.28).set_trans(Tween.TRANS_SINE)


# --------------------------------------------------------------------------
# Duo banner — replaces the two per-hero titles once the partner joins
# --------------------------------------------------------------------------
func _fade_out_panel_text() -> void:
	for hid in _panel_text.keys():
		for c in _panel_text[hid]:
			if c == null or not is_instance_valid(c):
				continue
			var tw := create_tween()
			tw.tween_property(c, "modulate:a", 0.0, 0.18)


func _build_duo_banner() -> void:
	var vp: Vector2 = _vp()
	var W: float = vp.x
	var H: float = vp.y

	_duo_banner = Node2D.new()
	_duo_banner.modulate = Color(1, 1, 1, 0.0)
	_layer.add_child(_duo_banner)

	# Ink band behind the banner so the kanji never fight the two portraits.
	var band := Polygon2D.new()
	band.polygon = PackedVector2Array([
		Vector2(0, H * 0.30), Vector2(W, H * 0.24),
		Vector2(W, H * 0.62), Vector2(0, H * 0.68)])
	band.color = Color(0.03, 0.02, 0.06, 0.82)
	_duo_banner.add_child(band)

	var kanji := _mk_label(DUO_KANJI, UISkin.font_body,
		int(clamp(H * 0.22, 44.0, 180.0)), Color(1, 1, 1, 1.0), COL_DUO, 14)
	kanji.position = Vector2(0, H * 0.30)
	kanji.size = Vector2(W, H * 0.24)
	_duo_banner.add_child(kanji)

	var nm := _mk_label(DUO_NAME, UISkin.font_display,
		int(clamp(W * 0.024, 12.0, 38.0)), Color(1, 1, 1, 0.97), COL_DUO, 9)
	nm.position = Vector2(0, H * 0.545)
	nm.size = Vector2(W, H * 0.07)
	_duo_banner.add_child(nm)

	var rj := _mk_label(DUO_ROMAJI, UISkin.font_micro,
		int(clamp(W * 0.014, 8.0, 22.0)), Color(COL_DUO.r, COL_DUO.g, COL_DUO.b, 0.95),
		Color(0, 0, 0, 0.9), 5)
	rj.position = Vector2(0, H * 0.615)
	rj.size = Vector2(W, H * 0.06)
	_duo_banner.add_child(rj)

	var tw := create_tween()
	tw.tween_property(_duo_banner, "modulate:a", 1.0, 0.18)
	# Scale-punch the whole banner in from slightly oversized.
	_duo_banner.scale = Vector2(1.14, 1.14)
	var origin: Vector2 = Vector2(W, H) * 0.5
	_duo_banner.position = -origin * 0.14
	tw.parallel().tween_property(_duo_banner, "scale", Vector2.ONE, 0.24) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(_duo_banner, "position", Vector2.ZERO, 0.24) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# ==========================================================================
# Small builders
# ==========================================================================

# One centred, outlined pixel-font label. Every label in this file goes through
# here so outline/alignment/skip-meta stay consistent.
func _mk_label(text: String, font: Font, size_px: int, col: Color,
		outline: Color, outline_px: int) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		lbl.add_theme_font_override("font", font)
	lbl.add_theme_font_size_override("font_size", max(6, size_px))
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_color_override("font_outline_color", outline)
	lbl.add_theme_constant_override("outline_size", max(0, outline_px))
	lbl.set_meta("_uiskin_skip", true)
	return lbl


func _add_speed_lines(root: Node2D, focus: Vector2, col: Color, dir_sign: float) -> void:
	for i in range(14):
		var line := Line2D.new()
		line.width = randf_range(2.0, 5.0)
		line.default_color = Color(col.r, col.g, col.b, randf_range(0.10, 0.30))
		var ang: float = randf_range(-1.2, 1.2)
		var d: Vector2 = Vector2(cos(ang) * dir_sign, sin(ang))
		line.points = PackedVector2Array([
			focus + d * randf_range(120.0, 220.0),
			focus + d * randf_range(520.0, 900.0)])
		root.add_child(line)


# Portrait = the hero's CURRENT animation frame, blown up. Placeholder-friendly:
# swap the texture source here when real splash art lands, nothing else changes.
func _add_portrait(root: Node2D, hero_id: String, pos: Vector2, screen_h: float,
		rim: Color, flip: bool) -> void:
	var hero: Node = _find_hero(hero_id)
	var tex: Texture2D = null
	if hero != null and is_instance_valid(hero) and hero.has_method("duo_ult_face_texture"):
		tex = hero.call("duo_ult_face_texture")
	if tex == null:
		# Fallback so the panel still reads if the sprite is mid-swap.
		var poly := Polygon2D.new()
		poly.polygon = PackedVector2Array([
			Vector2(0, -screen_h * 0.28), Vector2(screen_h * 0.22, 0),
			Vector2(0, screen_h * 0.28), Vector2(-screen_h * 0.22, 0)])
		poly.color = Color(rim.r, rim.g, rim.b, 0.55)
		poly.position = pos
		root.add_child(poly)
		return
	var s: float = (screen_h * 0.62) / max(1.0, float(tex.get_height()))
	# Rim glow sits behind the figure and separates it from the panel colour.
	var glow := Sprite2D.new()
	glow.texture = tex
	glow.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	glow.flip_h = flip
	glow.position = pos
	glow.scale = Vector2(s * 1.07, s * 1.07)
	glow.modulate = Color(rim.r, rim.g, rim.b, 0.55)
	root.add_child(glow)
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.flip_h = flip
	spr.position = pos
	spr.scale = Vector2(s, s)
	root.add_child(spr)


func _screen_flash(col: Color, dur: float) -> void:
	if _layer == null or not is_instance_valid(_layer):
		return
	var rect := ColorRect.new()
	rect.color = col
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_meta("_uiskin_skip", true)
	_layer.add_child(rect)
	var tw := create_tween()
	tw.tween_property(rect, "color:a", 0.0, dur)
	tw.tween_callback(Callable(rect, "queue_free"))
