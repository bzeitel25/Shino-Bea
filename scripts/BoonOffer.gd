extends CanvasLayer
# ============================================================
# BoonOffer.gd — modal overlay showing 3 boon cards (Phase 5 Task 4)
# ============================================================
# Spawned by World.gd when a wave is cleared. Reads the offer from
# RunState.roll_offer(), populates 3 cards, pauses the game tree,
# and emits `boon_picked(boon_id)` when the player clicks a card.
#
# Cards are pure Control nodes built procedurally — no .tscn needed
# for the card layout. Keeps everything in one script for simplicity.
# ============================================================

signal boon_picked(boon_id: String)

# Configurable visuals
const CARD_WIDTH: float  = 220.0
const CARD_HEIGHT: float = 280.0
const CARD_SPACING: float = 30.0
const TITLE_TEXT: String = "✦ CHOOSE A BOON ✦"
const SUBTITLE_TEXT: String = "(Click a card to take it)"

# Consumable / upgrade sentinel IDs (not in BOON_POOL).
# "Pie" = permanent max-HP increase (was "Apple Pie").
# "Juice" = auto-heal (granted automatically at arenas 5/10/15/20 — never shown as a card).
# "Dragon Fruit" = Pom upgrade: pick 1 of 3 boons to level up.
const PIE_ID: String                = "__apple_pie__"   # internal ID kept for door-system compat
const DRAGON_FRUIT_ID: String       = "__dragon_fruit__"
const DRAGON_FRUIT_RARE_ID: String  = "__dragon_fruit_rare__"  # +2 levels (fiery variant)
# Legacy alias kept so existing code that references APPLE_PIE_ID still compiles.
const APPLE_PIE_ID: String     = PIE_ID

var _offer: Array = []
var _picked: bool = false
var _legendary_locked: bool = false   # Run 46 — door-pick Legendary: no rerolling it away

# Run 29 — keyboard/gamepad navigation
var _cards: Array = []          # all card Buttons in current phase
var _focused_idx: int = 0       # which card is highlighted

# Run 68b — reroll "are you sure?" confirm prompt (gated by Settings.safety_confirmations)
var _confirm_panel: Control = null
var _confirm_btns: Array = []   # [No, Yes]
var _confirm_focus: int = 0     # 0 = No (default), 1 = Yes

# ── Stick nav gating (same pattern as MenuFocusNav) ──────────
const NAV_INITIAL_DELAY: float = 1.5
const NAV_REPEAT_RATE:   float = 0.3
const NAV_MOVE_COOLDOWN: float = 0.18   # min seconds between any two nav steps
var _nav_held_dir: int   = 0
var _nav_hold_time: float = 0.0
var _nav_repeat_acc: float = 0.0
var _nav_cooldown: float = 0.0          # counts down after each move

# Run 29 — two-phase boon offer (Shino first, then Bea)
# Phase 0 = Shino's pick, Phase 1 = Bea's pick. Same family, fresh roll each phase.
var _phase: int = 0
var _phase_family: String = ""  # set on _ready, reused for Bea's roll

# Dragon Fruit two-phase: _df_phase 0 = Shino upgrades, 1 = Bea upgrades.
var _df_phase: int = 0

# Run 32 — upgrade door auto-picks. When the door type already committed the
# player to an upgrade, skip the card step and apply it automatically.
var _auto_grant_pie: bool = false      # apple_pie door → auto-pick pie
var _auto_dragon_fruit: bool = false   # dragon_fruit door → straight to upgrade selection
var _df_levels_up: int = 1             # +1 normal, +2 rare fiery Dragon Fruit

# Run 141 — tutorial forces exactly 3 Broccoli attack-slot boons (Y/X/A).
var _tutorial_mode: bool = false


func _ready() -> void:
	layer = 100  # ensure on top of HUD (layer 5/10)

	# Run 141 — Tutorial boon mode: force exactly 3 Broccoli attack-slot boons.
	if RunState.has_meta("tutorial_boon_mode") and RunState.get_meta("tutorial_boon_mode"):
		_tutorial_mode = true
		_offer = ["heavy_stalk", "brute_force", "slugshot"]   # Y, X, A
		_room_family = "Broccoli"
		_phase_family = "Broccoli"   # allows Shino→Bea two-phase flow
		_phase = 0
		_build_overlay()
		get_tree().paused = true
		process_mode = Node.PROCESS_MODE_ALWAYS
		return

	# Run 26c — Family-locked room reward.
	# Determine THIS room's family. Priority:
	#   1. Pending door pick from previous room (RunState.pending_reward via has/consume API)
	#   2. Random family (e.g. Arena 1, where there's no prior door)
	# All 3 BoonOffer slots come from that family (with prereq gating applied).
	# Apple Pie and Legendary types from the door pick are honored specially.
	var room_family: String = ""
	var force_legendary: bool = false
	if RunState.has_pending_reward():
		var pending: Dictionary = RunState.consume_pending_reward()
		var ptype: String = String(pending.get("type", ""))
		room_family = String(pending.get("family", "")).capitalize()
		match ptype:
			"apple_pie":
				# Door choice WAS the pick — auto-grant pie, skip in-room card.
				_auto_grant_pie = true
				_room_family = "__upgrade__"
				_phase_family = "__upgrade__"
			"dragon_fruit":
				# Door choice WAS the pick — go straight to upgrade selection.
				_auto_dragon_fruit = true
				_df_levels_up = 1
				_room_family = "__upgrade__"
				_phase_family = "__upgrade__"
			"dragon_fruit_rare":
				# Rare fiery +2 Dragon Fruit.
				_auto_dragon_fruit = true
				_df_levels_up = 2
				_room_family = "__upgrade__"
				_phase_family = "__upgrade__"
			"legendary":
				force_legendary = true
				# room_family stays whatever family the legendary previewed
			"boon":
				pass   # plain family lock — no special slot
			# "apple_juice" / "boss" → fall through (room_family may still be set)
			_:
				pass
		print("[BoonOffer] Pending door pick consumed — type=%s family=%s" % [ptype, room_family])

	if room_family == "":
		# Arena 1 (or any door-less entry): random family from the door-eligible list.
		room_family = String(RunState.DOOR_FAMILIES[randi() % RunState.DOOR_FAMILIES.size()]).capitalize()
		print("[BoonOffer] No door pick — random room family rolled: %s" % room_family)

	# Upgrade auto-picks: show a single card so there's a visual for 1 frame,
	# then the deferred auto-pick fires immediately (connected signal is ready by then).
	if _auto_grant_pie:
		_offer = [PIE_ID]
		print("[BoonOffer] apple_pie door — auto-granting pie (no card choice).")
	elif _auto_dragon_fruit:
		_offer = [DRAGON_FRUIT_ID]
		print("[BoonOffer] dragon_fruit door — auto-triggering upgrade selection.")
	else:
		# Normal family boon room.
		if RunState.current_offer.is_empty():
			_offer = RunState.roll_family_offer(room_family, "shino")
		else:
			_offer = RunState.current_offer
	# Door-pick forced Legendary — strictly from the room's family only.
	if force_legendary and not _offer.is_empty():
		var leg_id: String = RunState.pick_legendary_for_family(room_family)
		if leg_id != "":
			_offer[0] = leg_id
			_legendary_locked = true   # Run 46 — guaranteed offers can't be rerolled
			print("[BoonOffer] Door pick = Legendary → slot 0 locked to %s." % leg_id)

	if _room_family == "":
		_room_family = room_family   # remember for the header label
	if _phase_family == "":
		_phase_family = room_family  # locked for both phases
	_build_overlay()
	# Pause the tree so combat is frozen during the choice.
	# (We use process_mode=ALWAYS on this CanvasLayer so we keep ticking.)
	get_tree().paused = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Upgrade auto-picks — deferred so signal receivers have time to connect
	# (BoonPickup connects boon_picked AFTER add_child, i.e. after _ready runs).
	if _auto_grant_pie:
		call_deferred("_pick_pie")
	elif _auto_dragon_fruit:
		call_deferred("_pick_dragon_fruit")


var _room_family: String = ""


func _finish_with_no_offer() -> void:
	# Graceful fallback: no cards to show — close and unlock exits.
	emit_signal("boon_picked", "")
	get_tree().paused = false
	queue_free()


func _build_overlay() -> void:
	# --- Dimmed full-screen backdrop (click-blocker) ---
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.65)
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(backdrop)

	# --- Title label (top) ---
	var title := Label.new()
	title.add_theme_font_size_override("font_size", 38)
	var phase_tag: String = "SHINO" if _phase == 0 else "BEA"
	var phase_col: Color  = Color(1.0, 0.85, 0.30) if _phase == 0 else Color(0.70, 0.55, 1.0)
	if _room_family == "__upgrade__":
		title.text = "✦ UPGRADE ROOM ✦"
		title.add_theme_color_override("font_color", Color(1.0, 0.78, 0.20))
	elif _room_family != "":
		title.text = "✦ %s'S BOON  —  %s ROOM ✦" % [phase_tag, _room_family.to_upper()]
		title.add_theme_color_override("font_color", phase_col)
	else:
		title.text = "✦ %s'S BOON ✦" % phase_tag
		title.add_theme_color_override("font_color", phase_col)
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.anchor_top = 0.0
	title.offset_top = 90.0
	title.offset_bottom = 140.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Arrow keys / WASD to choose  •  Enter / A to confirm  •  (or click)"
	# Run 46 — Fated Reroll (Sensei Z): advertise the R key when charges remain.
	if _can_reroll():
		subtitle.text += "  •  🎲 R / LB = Reroll (%d left)" % RunState.rerolls_left
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	subtitle.anchor_left = 0.0
	subtitle.anchor_right = 1.0
	subtitle.anchor_top = 0.0
	subtitle.offset_top = 140.0
	subtitle.offset_bottom = 170.0
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(subtitle)

	# --- Boons-taken summary (top-right) ---
	if not RunState.boons_taken.is_empty():
		var summary := Label.new()
		summary.text = "Active: " + _format_boons_summary()
		summary.add_theme_font_size_override("font_size", 14)
		summary.add_theme_color_override("font_color", Color(0.7, 0.85, 0.9))
		summary.anchor_left = 0.0
		summary.anchor_right = 1.0
		summary.anchor_top = 0.0
		summary.offset_top = 24.0
		summary.offset_bottom = 60.0
		summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		summary.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(summary)

	# --- Duo Boons active (Run 19) — family-pairing passives ---
	var duo_summary: String = RunState.get_active_duos_summary()
	if duo_summary != "":
		var duo_label := Label.new()
		duo_label.text = "✦ " + duo_summary + " ✦"
		duo_label.add_theme_font_size_override("font_size", 14)
		duo_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.55))
		duo_label.anchor_right = 1.0
		duo_label.offset_left = 0
		duo_label.offset_right = 0
		duo_label.offset_top = 48.0
		duo_label.offset_bottom = 76.0
		duo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		duo_label.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(duo_label)

	# --- Elemental Synergies active (Run 19) — cross-status reactions ---
	var syn_summary: String = RunState.get_active_synergies_summary()
	if syn_summary != "":
		var syn_label := Label.new()
		syn_label.text = "⚡ " + syn_summary + " ⚡"
		syn_label.add_theme_font_size_override("font_size", 14)
		syn_label.add_theme_color_override("font_color", Color(0.65, 0.90, 1.0))
		syn_label.anchor_right = 1.0
		syn_label.offset_left = 0
		syn_label.offset_right = 0
		syn_label.offset_top = 72.0
		syn_label.offset_bottom = 96.0
		syn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		syn_label.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(syn_label)

	# --- Cards (centered horizontally, vertically near middle) ---
	var card_count: int = _offer.size()
	if card_count == 0:
		_finish_with_no_offer()
		return

	var total_w: float = card_count * CARD_WIDTH + (card_count - 1) * CARD_SPACING
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var start_x: float = (viewport_size.x - total_w) * 0.5
	var card_y: float = (viewport_size.y - CARD_HEIGHT) * 0.5 + 20.0

	_cards.clear()
	_focused_idx = 0
	for i in range(card_count):
		var boon_id: String = _offer[i]
		var card: Button
		if boon_id == PIE_ID:
			card = _build_pie_card()
		elif boon_id == DRAGON_FRUIT_ID:
			card = _build_dragon_fruit_card()
		elif String(boon_id).begins_with(RunState.DUO_OFFER_PREFIX):
			card = _build_duo_card(boon_id)   # Run 41 — duos are picked cards
		else:
			card = _build_card(boon_id)
		card.position = Vector2(start_x + i * (CARD_WIDTH + CARD_SPACING), card_y)
		add_child(card)
		_cards.append(card)
	# Auto-highlight first card after all children are in tree.
	call_deferred("_set_focused", 0)


# Pie consumable card (formerly "Apple Pie" — renamed to avoid Apple family confusion).
# Gold/red gradient bg, CONSUMABLE badge, stylized pie wedge polygon.
func _build_pie_card() -> Button:
	var card := Button.new()
	card.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.process_mode = Node.PROCESS_MODE_ALWAYS
	card.flat = false
	card.text = ""

	# Stylebox: warm gold base with a bright crust-orange border, drop shadow.
	var gold: Color = Color(1.0, 0.78, 0.20)
	var crust: Color = Color(0.85, 0.40, 0.15)
	var stylebox := StyleBoxFlat.new()
	stylebox.bg_color = Color(0.22, 0.12, 0.06)
	stylebox.border_color = gold
	stylebox.border_width_left = 6
	stylebox.border_width_right = 6
	stylebox.border_width_top = 6
	stylebox.border_width_bottom = 6
	stylebox.corner_radius_top_left = 14
	stylebox.corner_radius_top_right = 14
	stylebox.corner_radius_bottom_left = 14
	stylebox.corner_radius_bottom_right = 14
	stylebox.shadow_color = Color(gold.r, gold.g, gold.b, 0.75)
	stylebox.shadow_size = 10
	card.add_theme_stylebox_override("normal", stylebox)
	var hover := stylebox.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.32, 0.18, 0.08)
	card.add_theme_stylebox_override("hover", hover)
	var pressed := stylebox.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.14, 0.07, 0.03)
	card.add_theme_stylebox_override("pressed", pressed)

	# Gradient overlay (gold → red) via two stacked ColorRect strips.
	var grad_top := ColorRect.new()
	grad_top.color = Color(gold.r, gold.g, gold.b, 0.55)
	grad_top.anchor_left = 0.0
	grad_top.anchor_right = 1.0
	grad_top.offset_left = 6
	grad_top.offset_right = -6
	grad_top.offset_top = 6
	grad_top.offset_bottom = 70
	grad_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grad_top.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(grad_top)

	var grad_bot := ColorRect.new()
	grad_bot.color = Color(crust.r, crust.g, crust.b, 0.40)
	grad_bot.anchor_left = 0.0
	grad_bot.anchor_right = 1.0
	grad_bot.offset_left = 6
	grad_bot.offset_right = -6
	grad_bot.offset_top = 70
	grad_bot.offset_bottom = CARD_HEIGHT - 8
	grad_bot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grad_bot.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(grad_bot)

	# CONSUMABLE badge — small label above the name.
	var badge := Label.new()
	badge.text = "✦ CONSUMABLE ✦"
	badge.add_theme_font_size_override("font_size", 13)
	badge.add_theme_color_override("font_color", Color(0.10, 0.05, 0.0))
	badge.add_theme_color_override("font_outline_color", gold)
	badge.add_theme_constant_override("outline_size", 4)
	badge.anchor_right = 1.0
	badge.offset_left = 0
	badge.offset_right = 0
	badge.offset_top = 12
	badge.offset_bottom = 36
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(badge)

	# Stylized pie wedge — Polygon2D in the middle of the card.
	# A quarter-circle wedge (270°) with a triangular slice cut out, in pie gold.
	var wedge := Polygon2D.new()
	wedge.position = Vector2(CARD_WIDTH * 0.5, 100.0)
	wedge.color = gold
	var pts: PackedVector2Array = PackedVector2Array()
	pts.append(Vector2.ZERO)
	var radius: float = 36.0
	# Build a 270° arc (top-right to bottom-right, clockwise) — leaves a wedge cut.
	var start_a: float = deg_to_rad(-135.0)
	var end_a: float = deg_to_rad(135.0)
	var seg: int = 18
	for i in range(seg + 1):
		var t: float = float(i) / float(seg)
		var a: float = lerp(start_a, end_a, t)
		pts.append(Vector2(cos(a), sin(a)) * radius)
	wedge.polygon = pts
	# Polygon2D (Node2D) has no mouse_filter property — only Controls do. The
	# Run 17 line that tried to set this always crashed on the truthy `in` branch
	# (Apple Pie offer trigger). Polygon2D is non-interactive by default; the
	# parent `card` Control already absorbs the click. (Run 26b crash fix.)
	card.add_child(wedge)

	# Crust ring (slight crust color around the wedge).
	var crust_outline := Line2D.new()
	crust_outline.position = wedge.position
	crust_outline.width = 3.0
	crust_outline.default_color = crust
	var ring_seg: int = 28
	for i in range(ring_seg + 1):
		var t: float = float(i) / float(ring_seg)
		var a: float = lerp(start_a, end_a, t)
		crust_outline.add_point(Vector2(cos(a), sin(a)) * radius)
	crust_outline.add_point(Vector2.ZERO)   # close back through center for the wedge cut
	card.add_child(crust_outline)

	# Steam (3 tiny ColorRect puffs above the wedge).
	for j in range(3):
		var puff := ColorRect.new()
		puff.color = Color(1.0, 0.95, 0.85, 0.65)
		puff.size = Vector2(6, 6)
		puff.position = Vector2(CARD_WIDTH * 0.5 - 12 + j * 12, 50.0)
		puff.mouse_filter = Control.MOUSE_FILTER_IGNORE
		puff.process_mode = Node.PROCESS_MODE_ALWAYS
		card.add_child(puff)

	# Name
	var pie_name := Label.new()
	pie_name.text = "Pie"
	pie_name.add_theme_font_size_override("font_size", 26)
	pie_name.add_theme_color_override("font_color", gold)
	pie_name.add_theme_color_override("font_outline_color", Color(0.10, 0.05, 0.0))
	pie_name.add_theme_constant_override("outline_size", 4)
	pie_name.anchor_right = 1.0
	pie_name.offset_left = 0
	pie_name.offset_right = 0
	pie_name.offset_top = 150
	pie_name.offset_bottom = 184
	pie_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pie_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pie_name.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(pie_name)

	var pct_now: int = int(round(RunState.get_apple_pie_max_hp_pct() * 100.0))
	var pct_after: int = int(round((RunState.get_apple_pie_max_hp_pct() + RunState.APPLE_PIE_HP_PER_STACK) * 100.0))
	var desc := Label.new()
	desc.text = "+%d%% Max HP (permanent)\nPies so far: %d" % [
		int(RunState.APPLE_PIE_HP_PER_STACK * 100.0), RunState.apple_pie_stacks,
	]
	desc.add_theme_font_size_override("font_size", 14)
	desc.add_theme_color_override("font_color", Color(0.98, 0.92, 0.75))
	desc.anchor_right = 1.0
	desc.offset_left = 12
	desc.offset_right = -12
	desc.offset_top = 188
	desc.offset_bottom = 240
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(desc)
	# Quiet usage warning suppression
	var _suppress_pct_now: int = pct_now
	var _suppress_pct_after: int = pct_after

	# Hint
	var hint := Label.new()
	hint.text = "→ eat ←"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", crust)
	hint.anchor_right = 1.0
	hint.offset_left = 0
	hint.offset_right = 0
	hint.offset_top = 245
	hint.offset_bottom = 270
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(hint)

	card.pressed.connect(_pick_pie)
	return card


func _pick_pie() -> void:
	if _picked:
		return
	_picked = true
	# Apply the consumable stack.
	RunState.grant_apple_pie()
	# Run 17 — feel: gold sparkle FX. apply_runstate_modifiers picks up the
	# new max-HP cap from RunState.get_apple_pie_max_hp_pct() and already heals
	# the delta on increase, so the bar visibly widens AND fills. No additional
	# heal needed here — that path is shared with Orchard Bloom etc.
	var players: Array = get_tree().get_nodes_in_group("player")
	for p in players:
		if p.has_method("apply_runstate_modifiers"):
			p.apply_runstate_modifiers()
		if p is Node2D and "global_position" in p:
			FX.spawn_burst_particles(p.global_position, Color(1.0, 0.85, 0.30, 1.0), 22)
			FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_SHORT)
	# Bea mirror — she shares the % so apply her runstate too.
	var beas: Array = get_tree().get_nodes_in_group("bea")
	for b in beas:
		if b.has_method("apply_runstate_modifiers"):
			b.apply_runstate_modifiers()
		if b is Node2D and "global_position" in b:
			FX.spawn_burst_particles(b.global_position, Color(1.0, 0.85, 0.30, 1.0), 14)
	FX.play_sound("apple_pie_eat", 1.0)
	_refresh_hud_boon_panel()
	emit_signal("boon_picked", PIE_ID)
	get_tree().paused = false
	queue_free()


# -------------------------------------------------------
# Dragon Fruit card (Pom-equivalent: level up one boon)
# -------------------------------------------------------
func _build_dragon_fruit_card() -> Button:
	var card := Button.new()
	card.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.process_mode = Node.PROCESS_MODE_ALWAYS
	card.flat = false
	card.text = ""

	# Green + purple gradient — "power-up" feeling distinct from Pie gold.
	var df_green: Color  = Color(0.35, 0.85, 0.45)
	var df_purple: Color = Color(0.55, 0.25, 0.80)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.12, 0.10)
	sb.border_color = df_green
	sb.border_width_left = 6; sb.border_width_right = 6
	sb.border_width_top = 6;  sb.border_width_bottom = 6
	sb.corner_radius_top_left = 14;    sb.corner_radius_top_right = 14
	sb.corner_radius_bottom_left = 14; sb.corner_radius_bottom_right = 14
	sb.shadow_color = Color(df_green.r, df_green.g, df_green.b, 0.60)
	sb.shadow_size = 10
	card.add_theme_stylebox_override("normal", sb)
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = Color(0.14, 0.20, 0.16)
	card.add_theme_stylebox_override("hover", sb_h)

	# UPGRADE badge
	var badge := Label.new()
	badge.text = "✦ UPGRADE ✦"
	badge.add_theme_font_size_override("font_size", 13)
	badge.add_theme_color_override("font_color", Color(0.10, 0.05, 0.0))
	badge.add_theme_color_override("font_outline_color", df_green)
	badge.add_theme_constant_override("outline_size", 4)
	badge.anchor_right = 1.0; badge.offset_left = 0; badge.offset_right = 0
	badge.offset_top = 12; badge.offset_bottom = 36
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(badge)

	# Dragon fruit icon — stylized diamond polygon in green+purple
	var gem := Polygon2D.new()
	gem.position = Vector2(CARD_WIDTH * 0.5, 100.0)
	gem.color = df_green
	var pts := PackedVector2Array()
	pts.append(Vector2(0, -38))   # top
	pts.append(Vector2(26, 0))    # right
	pts.append(Vector2(0, 38))    # bottom
	pts.append(Vector2(-26, 0))   # left
	gem.polygon = pts
	card.add_child(gem)
	var gem2 := Polygon2D.new()   # inner highlight
	gem2.position = gem.position
	gem2.color = df_purple
	var pts2 := PackedVector2Array()
	pts2.append(Vector2(0, -18))
	pts2.append(Vector2(12, 0))
	pts2.append(Vector2(0, 18))
	pts2.append(Vector2(-12, 0))
	gem2.polygon = pts2
	card.add_child(gem2)

	# Name
	var nm := Label.new()
	nm.text = "Dragon Fruit"
	nm.add_theme_font_size_override("font_size", 24)
	nm.add_theme_color_override("font_color", df_green)
	nm.add_theme_color_override("font_outline_color", Color(0.05, 0.10, 0.05))
	nm.add_theme_constant_override("outline_size", 4)
	nm.anchor_right = 1.0; nm.offset_left = 0; nm.offset_right = 0
	nm.offset_top = 148; nm.offset_bottom = 184
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nm.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(nm)

	# Description
	var has_boons: bool = not RunState.boons_taken.is_empty()
	var desc := Label.new()
	var df_lvl_txt: String = "+%d level%s" % [_df_levels_up, "s" if _df_levels_up > 1 else ""]
	desc.text = "%s to a boon\nyou choose.\n(+10–20%% effect per level,\nby boon rarity)\n\n%s" % [
		df_lvl_txt,
		"Choose 1 of 3 boons\nto power up!" if has_boons else "(No boons yet —\npick a boon first!)"
	]
	desc.add_theme_font_size_override("font_size", 15)
	desc.add_theme_color_override("font_color", Color(0.85, 0.95, 0.85))
	desc.anchor_right = 1.0; desc.offset_left = 12; desc.offset_right = -12
	desc.offset_top = 188; desc.offset_bottom = 244
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(desc)

	var hint := Label.new()
	hint.text = "→ level up ←"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", df_purple)
	hint.anchor_right = 1.0; hint.offset_left = 0; hint.offset_right = 0
	hint.offset_top = 245; hint.offset_bottom = 270
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(hint)

	card.pressed.connect(_pick_dragon_fruit)
	return card


func _pick_dragon_fruit() -> void:
	if _picked:
		return
	_picked = true
	_df_phase = 0
	_show_dragon_fruit_phase()


# Entry point for each DF phase. Phase 0 = Shino, Phase 1 = Bea.
func _show_dragon_fruit_phase() -> void:
	var who: String = "shino" if _df_phase == 0 else "bea"
	var candidates: Array = RunState.get_dragon_fruit_candidates_for(3, who)
	if candidates.is_empty():
		# This character has no boons yet — skip their phase.
		print("[BoonOffer] Dragon Fruit: no boons for %s, skipping." % who)
		if _df_phase == 0:
			_df_phase = 1
			_picked = false
			_show_dragon_fruit_phase()
		else:
			emit_signal("boon_picked", DRAGON_FRUIT_ID)
			get_tree().paused = false
			queue_free()
		return
	_show_dragon_fruit_upgrade(candidates)


func _show_dragon_fruit_upgrade(candidates: Array) -> void:
	# Remove all existing children and rebuild with the upgrade-choice layout.
	for ch in get_children():
		ch.queue_free()
	await get_tree().process_frame   # let queue_free flush before rebuilding

	# Reset pick/nav state so keyboard/gamepad input works in this phase.
	_picked = false
	_cards.clear()
	_focused_idx = 0

	# Backdrop
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.70)
	backdrop.anchor_right = 1.0; backdrop.anchor_bottom = 1.0
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(backdrop)

	# Title — show which ninja is picking
	var df_who_tag: String = "SHINO" if _df_phase == 0 else "BEA"
	var df_who_col: Color  = Color(1.0, 0.85, 0.30) if _df_phase == 0 else Color(0.70, 0.55, 1.0)
	var title := Label.new()
	var lvl_tag: String = "+%d LEVEL%s" % [_df_levels_up, "S" if _df_levels_up > 1 else ""]
	title.text = "✦ %s'S DRAGON FRUIT — %s ✦" % [df_who_tag, lvl_tag]
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", df_who_col)
	title.anchor_left = 0.0; title.anchor_right = 1.0
	title.offset_top = 90; title.offset_bottom = 140
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(title)

	var sub := Label.new()
	sub.text = "Arrow keys / WASD to choose  •  Enter / A to confirm  •  (or click)"
	sub.add_theme_font_size_override("font_size", 18)
	sub.add_theme_color_override("font_color", Color(0.75, 0.90, 0.75))
	sub.anchor_left = 0.0; sub.anchor_right = 1.0
	sub.offset_top = 138; sub.offset_bottom = 168
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(sub)

	# Build one upgrade card per candidate boon.
	var total_w: float = candidates.size() * CARD_WIDTH + (candidates.size() - 1) * CARD_SPACING
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var sx: float = (vp.x - total_w) * 0.5
	var cy: float = (vp.y - CARD_HEIGHT) * 0.5 + 20.0

	for i in range(candidates.size()):
		var boon_id: String = candidates[i]
		var card := _build_upgrade_choice_card(boon_id)
		card.position = Vector2(sx + i * (CARD_WIDTH + CARD_SPACING), cy)
		add_child(card)
		_cards.append(card)   # register for keyboard/gamepad nav
	call_deferred("_set_focused", 0)


func _build_upgrade_choice_card(boon_id: String) -> Button:
	var b: Dictionary = RunState.BOON_POOL.get(boon_id, {})
	var nm: String  = b.get("name", boon_id)
	var col: Color  = b.get("color", Color(0.55, 0.55, 0.55))
	var dsc: String = b.get("desc", "")
	var cur_lvl: int = RunState.get_boon_level(boon_id)

	var card := Button.new()
	card.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.process_mode = Node.PROCESS_MODE_ALWAYS
	card.flat = false; card.text = ""

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.12)
	sb.border_color = col
	sb.border_width_left = 5; sb.border_width_right = 5
	sb.border_width_top = 5;  sb.border_width_bottom = 5
	sb.corner_radius_top_left = 12;    sb.corner_radius_top_right = 12
	sb.corner_radius_bottom_left = 12; sb.corner_radius_bottom_right = 12
	sb.shadow_color = Color(col.r, col.g, col.b, 0.50); sb.shadow_size = 8
	card.add_theme_stylebox_override("normal", sb)
	var sbh := sb.duplicate() as StyleBoxFlat
	sbh.bg_color = Color(0.18, 0.18, 0.22)
	card.add_theme_stylebox_override("hover", sbh)

	# Family strip
	var strip := ColorRect.new()
	strip.color = col; strip.anchor_left = 0.0; strip.anchor_right = 1.0
	strip.offset_left = 4; strip.offset_right = -4
	strip.offset_top = 4; strip.offset_bottom = 36
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(strip)

	var fam_lbl := Label.new()
	fam_lbl.text = b.get("family", "?").to_upper()
	fam_lbl.add_theme_font_size_override("font_size", 14)
	fam_lbl.add_theme_color_override("font_color", Color(0.05, 0.05, 0.05))
	fam_lbl.anchor_right = 1.0; fam_lbl.offset_top = 8; fam_lbl.offset_bottom = 36
	fam_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fam_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fam_lbl.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(fam_lbl)

	# Current level chip
	var lvl_lbl := Label.new()
	lvl_lbl.text = "Level %d  →  Level %d" % [cur_lvl, cur_lvl + _df_levels_up]
	lvl_lbl.add_theme_font_size_override("font_size", 13)
	lvl_lbl.add_theme_color_override("font_color", Color(0.55, 1.0, 0.60))
	lvl_lbl.anchor_right = 1.0; lvl_lbl.offset_top = 40; lvl_lbl.offset_bottom = 62
	lvl_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lvl_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lvl_lbl.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(lvl_lbl)

	# Boon name
	var nm_lbl := Label.new()
	nm_lbl.text = nm
	nm_lbl.add_theme_font_size_override("font_size", 22)
	nm_lbl.add_theme_color_override("font_color", Color(1, 1, 1))
	nm_lbl.anchor_right = 1.0; nm_lbl.offset_top = 68; nm_lbl.offset_bottom = 118
	nm_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nm_lbl.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(nm_lbl)

	# Run 127 — controller slot badge on Dragon Fruit cards too.
	_add_slot_badge(card, boon_id, 116.0)

	# Desc
	var desc_lbl := Label.new()
	desc_lbl.text = dsc
	desc_lbl.add_theme_font_size_override("font_size", 14)
	desc_lbl.add_theme_color_override("font_color", Color(0.80, 0.80, 0.80))
	desc_lbl.anchor_right = 1.0; desc_lbl.offset_left = 10; desc_lbl.offset_right = -10
	desc_lbl.offset_top = 138; desc_lbl.offset_bottom = 230
	desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_lbl.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(desc_lbl)

	# Effect preview — per-level bonus depends on the boon's rolled rarity (Run 40).
	var eff_lbl := Label.new()
	var per_lvl: float = float(RunState.RARITY_LEVEL_BONUS.get(RunState.get_boon_rarity(boon_id), 0.10))
	var new_pct: int = int(round(float(cur_lvl) * per_lvl * 100.0))
	eff_lbl.text = "+%d%% effect" % new_pct
	eff_lbl.add_theme_font_size_override("font_size", 16)
	eff_lbl.add_theme_color_override("font_color", Color(0.45, 1.0, 0.55))
	eff_lbl.anchor_right = 1.0; eff_lbl.offset_top = 232; eff_lbl.offset_bottom = 256
	eff_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	eff_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	eff_lbl.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(eff_lbl)

	var hint_lbl := Label.new()
	hint_lbl.text = "→ level up ←"
	hint_lbl.add_theme_font_size_override("font_size", 13)
	hint_lbl.add_theme_color_override("font_color", col)
	hint_lbl.anchor_right = 1.0; hint_lbl.offset_top = 255; hint_lbl.offset_bottom = 275
	hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_lbl.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(hint_lbl)

	card.pressed.connect(func(): _apply_dragon_fruit_upgrade(boon_id))
	return card


func _apply_dragon_fruit_upgrade(boon_id: String) -> void:
	if _picked:
		return
	_picked = true
	RunState.apply_dragon_fruit_to_boon(boon_id, _df_levels_up)
	var b_data: Dictionary = RunState.BOON_POOL.get(boon_id, {})
	var lvl: int = RunState.get_boon_level(boon_id)
	var who: String = "shino" if _df_phase == 0 else "bea"
	print("[BoonOffer] Dragon Fruit +%d (%s) applied: %s → level %d" % [_df_levels_up, who, b_data.get("name", boon_id), lvl])
	# Apply stat refresh only to the picking character.
	if who == "shino":
		for p in get_tree().get_nodes_in_group("player"):
			if p.has_method("apply_runstate_modifiers"):
				p.apply_runstate_modifiers()
			if p is Node2D and "global_position" in p:
				FX.spawn_burst_particles(p.global_position, Color(0.35, 0.90, 0.45, 1.0), 18)
	else:
		for bea in get_tree().get_nodes_in_group("bea"):
			if bea.has_method("apply_runstate_modifiers"):
				bea.apply_runstate_modifiers()
			if bea is Node2D and "global_position" in bea:
				FX.spawn_burst_particles(bea.global_position, Color(0.70, 0.45, 1.0, 1.0), 18)
	FX.screen_shake(FX.SHAKE_LIGHT, FX.SHAKE_DUR_SHORT)
	FX.play_sound("apple_pie_eat", 0.90)
	_refresh_hud_boon_panel()
	# Phase 0 done → advance to Bea's DF phase.
	if _df_phase == 0:
		_df_phase = 1
		_picked = false
		for ch in get_children():
			ch.queue_free()
		_cards.clear()
		_focused_idx = 0
		await get_tree().process_frame
		_show_dragon_fruit_phase()
	else:
		emit_signal("boon_picked", DRAGON_FRUIT_ID)
		get_tree().paused = false
		queue_free()


# ---------------------------------------------------------------------------
# Run 41 — Duo boon card. Duos live in RunState.DUO_DEFS (not BOON_POOL) and
# arrive in the offer as "duo:<duo_id>". Hades-style: dual family banner,
# DUO badge, fixed "duo" tier (no rarity roll). Picking activates the duo
# for BOTH ninjas (duo effects are team passives).
# ---------------------------------------------------------------------------
func _build_duo_card(offer_id: String) -> Button:
	var duo_id: String = String(offer_id).trim_prefix(RunState.DUO_OFFER_PREFIX)
	var d: Dictionary = RunState.DUO_DEFS.get(duo_id, {})
	var nm: String  = d.get("name", duo_id)
	var dsc: String = d.get("desc", "")
	var fams: Array = d.get("required_any", [])
	var duo_col: Color = RunState.RARITY_COLOR.get("duo", Color(1.0, 0.62, 0.25))
	var col_a: Color = RunState.FAM_COLOR.get(fams[0] if fams.size() > 0 else "", duo_col)
	var col_b: Color = RunState.FAM_COLOR.get(fams[1] if fams.size() > 1 else "", duo_col)

	var card := Button.new()
	card.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.process_mode = Node.PROCESS_MODE_ALWAYS
	card.flat = false
	card.text = ""

	# Thick duo-orange border + glow (legendary-grade pop).
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.10, 0.08)
	sb.border_color = duo_col
	sb.border_width_left = 7; sb.border_width_right = 7
	sb.border_width_top = 7;  sb.border_width_bottom = 7
	sb.corner_radius_top_left = 12;    sb.corner_radius_top_right = 12
	sb.corner_radius_bottom_left = 12; sb.corner_radius_bottom_right = 12
	sb.shadow_color = Color(duo_col.r, duo_col.g, duo_col.b, 0.60)
	sb.shadow_size = 8
	card.add_theme_stylebox_override("normal", sb)
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = Color(0.20, 0.16, 0.12)
	card.add_theme_stylebox_override("hover", sb_h)
	var sb_p := sb.duplicate() as StyleBoxFlat
	sb_p.bg_color = Color(0.08, 0.06, 0.05)
	card.add_theme_stylebox_override("pressed", sb_p)

	# DUO badge above the banner.
	var badge := Label.new()
	badge.text = "✦ DUO ✦"
	badge.add_theme_font_size_override("font_size", 13)
	badge.add_theme_color_override("font_color", duo_col)
	badge.add_theme_color_override("font_outline_color", Color(0.15, 0.08, 0.0))
	badge.add_theme_constant_override("outline_size", 4)
	badge.anchor_right = 1.0
	badge.offset_left = 0; badge.offset_right = 0
	badge.offset_top = -8; badge.offset_bottom = 14
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(badge)

	# Split family banner: left half family A color, right half family B.
	var half_w: float = (CARD_WIDTH - 8.0) * 0.5
	var strip_a := ColorRect.new()
	strip_a.color = col_a
	strip_a.position = Vector2(4, 4)
	strip_a.size = Vector2(half_w, 34)
	strip_a.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip_a.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(strip_a)
	var strip_b := ColorRect.new()
	strip_b.color = col_b
	strip_b.position = Vector2(4 + half_w, 4)
	strip_b.size = Vector2(half_w, 34)
	strip_b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip_b.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(strip_b)

	var fam_lbl := Label.new()
	fam_lbl.text = " + ".join(fams).to_upper() if not fams.is_empty() else "DUO"
	fam_lbl.add_theme_font_size_override("font_size", 13)
	fam_lbl.add_theme_color_override("font_color", Color(0.05, 0.05, 0.05))
	fam_lbl.anchor_right = 1.0
	fam_lbl.offset_left = 0; fam_lbl.offset_right = 0
	fam_lbl.offset_top = 10; fam_lbl.offset_bottom = 38
	fam_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fam_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fam_lbl.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(fam_lbl)

	# Tier chip.
	var chip := Label.new()
	chip.text = "DUO"
	chip.add_theme_font_size_override("font_size", 12)
	chip.add_theme_color_override("font_color", duo_col)
	chip.anchor_right = 1.0
	chip.offset_left = 0; chip.offset_right = 0
	chip.offset_top = 42; chip.offset_bottom = 64
	chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(chip)

	# Name
	var name_lbl := Label.new()
	name_lbl.text = nm
	name_lbl.add_theme_font_size_override("font_size", 22)
	name_lbl.add_theme_color_override("font_color", Color(1, 1, 1))
	name_lbl.anchor_right = 1.0
	name_lbl.offset_left = 0; name_lbl.offset_right = 0
	name_lbl.offset_top = 70; name_lbl.offset_bottom = 120
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(name_lbl)

	# Description
	var desc_lbl := Label.new()
	desc_lbl.text = dsc
	desc_lbl.add_theme_font_size_override("font_size", 14)
	desc_lbl.add_theme_color_override("font_color", Color(0.92, 0.85, 0.75))
	desc_lbl.anchor_right = 1.0
	desc_lbl.offset_left = 12; desc_lbl.offset_right = -12
	desc_lbl.offset_top = 128; desc_lbl.offset_bottom = 238
	desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_lbl.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(desc_lbl)

	# Hint
	var hint_lbl := Label.new()
	hint_lbl.text = "→ both ninjas ←"
	hint_lbl.add_theme_font_size_override("font_size", 13)
	hint_lbl.add_theme_color_override("font_color", duo_col)
	hint_lbl.anchor_right = 1.0
	hint_lbl.offset_left = 0; hint_lbl.offset_right = 0
	hint_lbl.offset_top = 245; hint_lbl.offset_bottom = 270
	hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_lbl.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(hint_lbl)

	card.pressed.connect(func(): _pick(offer_id))
	return card


# ---------------------------------------------------------------------------
# Run 127 — controller slot badge. Boons with a "boon_slot" tag get a small
# Xbox-style button icon + caption row between the name and the description
# (replaces the old "Y slot." text prefix that cluttered every desc).
# ---------------------------------------------------------------------------
func _add_slot_badge(card: Button, boon_id: String, y_top: float) -> void:
	var slot: String = String(RunState.BOON_POOL.get(boon_id, {}).get("boon_slot", ""))
	if slot == "":
		return
	var btn_col: Color = Color(0.5, 0.5, 0.5)
	var btn_txt: String = slot
	var caption: String = ""
	var txt_col: Color = Color(0.05, 0.05, 0.05)
	var pill: bool = false
	match slot:
		"Y":
			btn_col = Color(0.93, 0.76, 0.18); caption = "PRIMARY"
		"X":
			btn_col = Color(0.27, 0.45, 0.87); caption = "SECONDARY"
			txt_col = Color(1, 1, 1)
		"A":
			btn_col = Color(0.24, 0.72, 0.29); caption = "RANGED"
		"B":
			btn_col = Color(0.85, 0.25, 0.25); caption = "DASH"
			txt_col = Color(1, 1, 1)
		"Charge":
			btn_col = Color(0.25, 0.25, 0.32); btn_txt = "HOLD"
			caption = "CHARGE"; txt_col = Color(0.92, 0.92, 0.98); pill = true
		"Ult":
			btn_col = Color(0.85, 0.70, 0.15); btn_txt = "ULT"
			caption = "ULTIMATE"; pill = true
		_:
			return

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.anchor_left = 0.0; row.anchor_right = 1.0
	row.offset_left = 8; row.offset_right = -8
	row.offset_top = y_top; row.offset_bottom = y_top + 22.0
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(row)

	var badge := Label.new()
	badge.text = btn_txt
	badge.add_theme_font_size_override("font_size", 13)
	badge.add_theme_color_override("font_color", txt_col)
	var bsb := StyleBoxFlat.new()
	bsb.bg_color = btn_col
	bsb.corner_radius_top_left = 11;    bsb.corner_radius_top_right = 11
	bsb.corner_radius_bottom_left = 11; bsb.corner_radius_bottom_right = 11
	bsb.border_width_left = 1; bsb.border_width_right = 1
	bsb.border_width_top = 1;  bsb.border_width_bottom = 1
	bsb.border_color = Color(btn_col.r * 0.55, btn_col.g * 0.55, btn_col.b * 0.55)
	badge.add_theme_stylebox_override("normal", bsb)
	badge.custom_minimum_size = Vector2(48.0 if pill else 22.0, 22.0)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.process_mode = Node.PROCESS_MODE_ALWAYS
	row.add_child(badge)

	var cap := Label.new()
	cap.text = caption
	cap.add_theme_font_size_override("font_size", 12)
	cap.add_theme_color_override("font_color", Color(0.65, 0.65, 0.70))
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.process_mode = Node.PROCESS_MODE_ALWAYS
	row.add_child(cap)


func _build_card(boon_id: String) -> Button:
	var b: Dictionary = RunState.BOON_POOL.get(boon_id, {})
	var fam: String = b.get("family", "?")
	var nm:  String = b.get("name", boon_id)
	var dsc: String = b.get("desc", "")
	var col: Color  = b.get("color", Color(0.5, 0.5, 0.5))
	# Run 40 — rarity is the OFFER ROLL for this card (Hades-style), not the
	# pool entry. Legendary/corrupt pass through as fixed tiers.
	var rarity: String = RunState.get_offer_rarity(boon_id)
	# Run 16 — rarity-colored border ring (separate from family banner color).
	# Falls back to family color if the rarity key isn't in the table.
	var rarity_col: Color = RunState.RARITY_COLOR.get(rarity, col)
	var rarity_label: String = RunState.RARITY_LABEL.get(rarity, rarity.to_upper())

	# Use a single Button at card size; layer custom labels on top for richer look.
	var card := Button.new()
	card.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.process_mode = Node.PROCESS_MODE_ALWAYS
	card.flat = false
	card.text = ""   # we'll add labels manually
	# Style overrides — outer border = RARITY color (Hades-style tier signal),
	# inner accent line on bg = family color (mostly hidden behind the family banner).
	# Border thickness scales with rarity tier so legendaries pop visually.
	var border_w: int = 4
	match rarity:
		"common":    border_w = 3
		"uncommon":  border_w = 4
		"rare":      border_w = 5
		"epic":      border_w = 6
		"legendary": border_w = 7
		_:           border_w = 4
	var stylebox := StyleBoxFlat.new()
	stylebox.bg_color = Color(0.10, 0.10, 0.13)
	stylebox.border_color = rarity_col
	stylebox.border_width_left = border_w
	stylebox.border_width_right = border_w
	stylebox.border_width_top = border_w
	stylebox.border_width_bottom = border_w
	stylebox.corner_radius_top_left = 12
	stylebox.corner_radius_top_right = 12
	stylebox.corner_radius_bottom_left = 12
	stylebox.corner_radius_bottom_right = 12
	# Drop-shadow + glow on epic/legendary for extra pop.
	if rarity == "epic" or rarity == "legendary":
		stylebox.shadow_color = Color(rarity_col.r, rarity_col.g, rarity_col.b, 0.60)
		stylebox.shadow_size = 8
	card.add_theme_stylebox_override("normal", stylebox)
	var stylebox_hover := stylebox.duplicate() as StyleBoxFlat
	stylebox_hover.bg_color = Color(0.18, 0.18, 0.22)
	card.add_theme_stylebox_override("hover", stylebox_hover)
	var stylebox_pressed := stylebox.duplicate() as StyleBoxFlat
	stylebox_pressed.bg_color = Color(0.05, 0.05, 0.07)
	card.add_theme_stylebox_override("pressed", stylebox_pressed)

	# Run 19 — Corrupt boon: overlay magenta→purple-black gradient (two strips)
	# before the family banner so the card reads as a hostile alternative.
	var is_corrupt: bool = bool(b.get("corrupt", false)) or fam == "Corrupt"
	if is_corrupt:
		var c_top := ColorRect.new()
		c_top.color = Color(0.85, 0.20, 0.85, 0.55)
		c_top.anchor_left = 0.0; c_top.anchor_right = 1.0
		c_top.offset_left = 4; c_top.offset_right = -4
		c_top.offset_top = 4; c_top.offset_bottom = 100
		c_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c_top.process_mode = Node.PROCESS_MODE_ALWAYS
		card.add_child(c_top)
		var c_bot := ColorRect.new()
		c_bot.color = Color(0.18, 0.05, 0.22, 0.85)
		c_bot.anchor_left = 0.0; c_bot.anchor_right = 1.0
		c_bot.offset_left = 4; c_bot.offset_right = -4
		c_bot.offset_top = 100; c_bot.offset_bottom = CARD_HEIGHT - 8
		c_bot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c_bot.process_mode = Node.PROCESS_MODE_ALWAYS
		card.add_child(c_bot)
		# CORRUPT badge
		var c_badge := Label.new()
		c_badge.text = "☠ CORRUPT ☠"
		c_badge.add_theme_font_size_override("font_size", 13)
		c_badge.add_theme_color_override("font_color", Color(1.0, 0.55, 1.0))
		c_badge.add_theme_color_override("font_outline_color", Color(0.1, 0.0, 0.1))
		c_badge.add_theme_constant_override("outline_size", 4)
		c_badge.anchor_right = 1.0
		c_badge.offset_left = 0; c_badge.offset_right = 0
		c_badge.offset_top = -8; c_badge.offset_bottom = 14
		c_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		c_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c_badge.process_mode = Node.PROCESS_MODE_ALWAYS
		card.add_child(c_badge)

	# Run 19 — Legendary banner: gilded ✦ LEGENDARY ✦ above family banner.
	if rarity == "legendary" and not is_corrupt:
		var l_badge := Label.new()
		l_badge.text = "✦ LEGENDARY ✦"
		l_badge.add_theme_font_size_override("font_size", 13)
		l_badge.add_theme_color_override("font_color", Color(1.0, 0.92, 0.40))
		l_badge.add_theme_color_override("font_outline_color", Color(0.20, 0.10, 0.0))
		l_badge.add_theme_constant_override("outline_size", 4)
		l_badge.anchor_right = 1.0
		l_badge.offset_left = 0; l_badge.offset_right = 0
		l_badge.offset_top = -8; l_badge.offset_bottom = 14
		l_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l_badge.process_mode = Node.PROCESS_MODE_ALWAYS
		card.add_child(l_badge)

	# Family banner (colored strip at the top of the card).
	var family_strip := ColorRect.new()
	family_strip.color = col
	family_strip.anchor_left = 0.0; family_strip.anchor_right = 1.0
	family_strip.offset_left = 4; family_strip.offset_right = -4
	family_strip.offset_top = 4; family_strip.offset_bottom = 38
	family_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	family_strip.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(family_strip)

	var family_label := Label.new()
	family_label.text = fam.to_upper()
	family_label.add_theme_font_size_override("font_size", 16)
	family_label.add_theme_color_override("font_color", Color(0.05, 0.05, 0.05))
	family_label.anchor_right = 1.0
	family_label.offset_left = 0
	family_label.offset_right = 0
	family_label.offset_top = 8
	family_label.offset_bottom = 38
	family_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	family_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	family_label.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(family_label)

	# Rarity tier label (Run 16) — slim chip under the family banner.
	var rarity_chip := Label.new()
	rarity_chip.text = rarity_label
	rarity_chip.add_theme_font_size_override("font_size", 12)
	rarity_chip.add_theme_color_override("font_color", rarity_col)
	rarity_chip.anchor_right = 1.0
	rarity_chip.offset_left = 0
	rarity_chip.offset_right = 0
	rarity_chip.offset_top = 42
	rarity_chip.offset_bottom = 64
	rarity_chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rarity_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rarity_chip.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(rarity_chip)

	# Run 44 — slot trade-up indicator: this pick would replace the picker's
	# current boon in that slot (old one traded out, new one +1 level; the
	# rarity shown above was already bumped +1 by the offer roll).
	var _trade_picker: String = "shino" if _phase == 0 else "bea"
	if RunState.is_slot_replacement_for(_trade_picker, boon_id):
		var _old_id: String = String(RunState.owned_slots_by_char.get(_trade_picker, {}).get(RunState.get_slot_for_boon(boon_id), ""))
		var _old_nm: String = String(RunState.BOON_POOL.get(_old_id, {}).get("name", _old_id))
		var trade_chip := Label.new()
		trade_chip.text = "⇄ REPLACES %s (+1 LVL)" % _old_nm.to_upper()
		trade_chip.add_theme_font_size_override("font_size", 11)
		trade_chip.add_theme_color_override("font_color", Color(1.0, 0.72, 0.30))
		trade_chip.anchor_right = 1.0
		trade_chip.offset_left = 0
		trade_chip.offset_right = 0
		trade_chip.offset_top = 56
		trade_chip.offset_bottom = 72
		trade_chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		trade_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		trade_chip.process_mode = Node.PROCESS_MODE_ALWAYS
		card.add_child(trade_chip)

	# Name
	var name_label := Label.new()
	name_label.text = nm
	name_label.add_theme_font_size_override("font_size", 22)
	name_label.add_theme_color_override("font_color", Color(1, 1, 1))
	name_label.anchor_right = 1.0
	name_label.offset_left = 0
	name_label.offset_right = 0
	name_label.offset_top = 70
	name_label.offset_bottom = 120
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(name_label)

	# Run 127 — controller slot badge (Y/X/A/B/Charge/Ult) under the name.
	_add_slot_badge(card, boon_id, 118.0)

	# Description (multi-line, centered)
	var desc_label := Label.new()
	desc_label.text = dsc
	desc_label.add_theme_font_size_override("font_size", 16)
	desc_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	desc_label.anchor_right = 1.0
	desc_label.offset_left = 12
	desc_label.offset_right = -12
	desc_label.offset_top = 140
	desc_label.offset_bottom = 240
	desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_label.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(desc_label)

	# "Click to take" hint
	var hint_label := Label.new()
	hint_label.text = "→ Enter / click ←"
	hint_label.add_theme_font_size_override("font_size", 13)
	hint_label.add_theme_color_override("font_color", col)
	hint_label.anchor_right = 1.0
	hint_label.offset_left = 0
	hint_label.offset_right = 0
	hint_label.offset_top = 245
	hint_label.offset_bottom = 270
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_label.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(hint_label)

	# Wire the click → pick this boon
	card.pressed.connect(func(): _pick(boon_id))
	return card


# ---------------------------------------------------------------------------
# Run 29 — Keyboard / gamepad navigation
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _picked or _cards.is_empty() or is_instance_valid(_confirm_panel):
		_nav_held_dir = 0
		return
	# Tick cooldown.
	if _nav_cooldown > 0.0:
		_nav_cooldown -= delta

	# In 2P, only the active phase's device may navigate.
	var want: int = 0
	if RunState.two_player:
		var dev: int = _phase_device()
		var mv: Vector2 = InputRouter.move_vector(dev)
		if mv.x < -0.3:
			want = -1
		elif mv.x > 0.3:
			want = 1
	else:
		if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
			want = -1
		elif Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
			want = 1

	if want == 0:
		_nav_held_dir = 0; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		return
	if want != _nav_held_dir:
		_nav_held_dir = want; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		if _nav_cooldown <= 0.0:
			_nav_cooldown = NAV_MOVE_COOLDOWN
			_set_focused((_focused_idx + want + _cards.size()) % _cards.size())
		return
	_nav_hold_time += delta
	if _nav_hold_time >= NAV_INITIAL_DELAY:
		_nav_repeat_acc += delta
		while _nav_repeat_acc >= NAV_REPEAT_RATE:
			_nav_repeat_acc -= NAV_REPEAT_RATE
			if _nav_cooldown <= 0.0:
				_nav_cooldown = NAV_MOVE_COOLDOWN
				_set_focused((_focused_idx + _nav_held_dir + _cards.size()) % _cards.size())


# Which physical device owns the current phase. Shino's player picks phase 0,
# Bea's player picks phase 1. Dragon Fruit has its own _df_phase (0=Shino,
# 1=Bea) that overrides when active. In 1P this is unused (global Input).
func _phase_device() -> int:
	# Dragon Fruit upgrade flow uses _df_phase instead of _phase.
	if _room_family == "__upgrade__":
		return RunState.shino_device if _df_phase == 0 else RunState.bea_device
	if _phase == 0:
		return RunState.shino_device
	return RunState.bea_device


func _event_device(event: InputEvent) -> int:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return event.device
	return -1   # keyboard


func _input(event: InputEvent) -> void:
	if _picked or _cards.is_empty():
		return
	# In 2P, ignore input from the non-active player's device.
	if RunState.two_player:
		var ev_dev: int = _event_device(event)
		if ev_dev != _phase_device():
			return
	# Run 68b — reroll confirm prompt intercepts all input while it's open.
	if is_instance_valid(_confirm_panel):
		if event.is_action_pressed("ui_cancel"):
			_cancel_reroll_confirm()
		elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right") \
		or (event is InputEventKey and event.pressed and event.physical_keycode in [KEY_A, KEY_D]):
			_confirm_focus = 1 - _confirm_focus
			_update_confirm_focus()
		elif event.is_action_pressed("ui_accept") and not event.is_echo():
			_confirm_btns[_confirm_focus].emit_signal("pressed")
		get_viewport().set_input_as_handled()
		return
	# Consume L/R nav events so built-in focus nav doesn't double-fire.
	if event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right") \
	or (event is InputEventKey and event.pressed and event.physical_keycode in [KEY_A, KEY_D]):
		get_viewport().set_input_as_handled()
	# Enter / Space / gamepad A  →  confirm focused card.
	elif event.is_action_pressed("ui_accept") and not event.is_echo():
		if _focused_idx < _cards.size():
			_cards[_focused_idx].emit_signal("pressed")
		get_viewport().set_input_as_handled()
	# Run 46 — Fated Reroll (Sensei Z): R / gamepad R-shoulder rerolls the current offer.
	elif (event.is_action_pressed("reroll") and not event.is_echo()) \
	or (event is InputEventKey and event.pressed and not event.is_echo() \
	and event.physical_keycode == KEY_R):
		_request_reroll()
		get_viewport().set_input_as_handled()


# Run 46 — Fated Reroll eligibility: charges left, normal boon offer only
# (no pie/Dragon-Fruit upgrade phases, no door-guaranteed Legendaries).
func _can_reroll() -> bool:
	if RunState.rerolls_left <= 0 or _picked or _legendary_locked:
		return false
	if _offer.has(PIE_ID) or _offer.has(DRAGON_FRUIT_ID):
		return false
	return true


func _do_reroll() -> void:
	RunState.rerolls_left -= 1
	print("[BoonOffer] Fated Reroll — %s offer rerolled (%d left)." % [
		"Shino's" if _phase == 0 else "Bea's", RunState.rerolls_left])
	for child in get_children():
		child.queue_free()
	_cards.clear()
	_focused_idx = 0
	RunState.current_offer.clear()
	_offer = RunState.roll_family_offer(_phase_family, "shino" if _phase == 0 else "bea")
	FX.play_sound("boon_offer", 1.2)
	await get_tree().process_frame   # let queue_free flush
	_build_overlay()


# Run 68b — reroll gate: prompt "are you sure?" unless safety confirmations are off.
func _request_reroll() -> void:
	if not _can_reroll() or is_instance_valid(_confirm_panel):
		return
	var s: Node = get_node_or_null("/root/Settings")
	var safety_on: bool = true
	if s and "safety_confirmations" in s:
		safety_on = bool(s.safety_confirmations)
	if safety_on:
		_show_reroll_confirm()
	else:
		_do_reroll()


func _show_reroll_confirm() -> void:
	_confirm_panel = Control.new()
	_confirm_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_confirm_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_confirm_panel.process_mode = Node.PROCESS_MODE_ALWAYS

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	_confirm_panel.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_confirm_panel.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.07, 0.11, 0.99)
	sb.border_color = Color(0.96, 0.82, 0.32, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 18)
	panel.add_child(vb)

	var msg := Label.new()
	msg.text = "Reroll this offer?\nSpends 1 charge (%d left)." % RunState.rerolls_left
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.add_theme_color_override("font_color", Color(0.92, 0.92, 0.96))
	msg.add_theme_font_size_override("font_size", 20)
	vb.add_child(msg)

	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 22)
	vb.add_child(hb)

	var no_btn := Button.new()
	no_btn.text = "No"
	_style_confirm_btn(no_btn)
	no_btn.pressed.connect(_cancel_reroll_confirm)
	hb.add_child(no_btn)

	var yes_btn := Button.new()
	yes_btn.text = "Yes — Reroll"
	_style_confirm_btn(yes_btn)
	yes_btn.pressed.connect(_confirm_reroll)
	hb.add_child(yes_btn)

	_confirm_btns = [no_btn, yes_btn]
	add_child(_confirm_panel)
	_confirm_focus = 0   # default to the safe choice
	_update_confirm_focus()


func _style_confirm_btn(btn: Button) -> void:
	btn.custom_minimum_size = Vector2(150, 46)
	btn.add_theme_font_size_override("font_size", 20)


func _update_confirm_focus() -> void:
	if _confirm_focus < _confirm_btns.size():
		(_confirm_btns[_confirm_focus] as Button).grab_focus()


func _cancel_reroll_confirm() -> void:
	if is_instance_valid(_confirm_panel):
		_confirm_panel.queue_free()
	_confirm_panel = null
	_confirm_btns.clear()


func _confirm_reroll() -> void:
	_cancel_reroll_confirm()
	if _can_reroll():
		_do_reroll()


func _set_focused(idx: int) -> void:
	_focused_idx = clamp(idx, 0, _cards.size() - 1)
	# Use StyleBox border override — no overlay that obscures card content.
	for i in range(_cards.size()):
		var card: Button = _cards[i]
		# Retrieve the card's existing normal stylebox to re-use its geometry.
		var base_sb: StyleBoxFlat = card.get_theme_stylebox("normal") as StyleBoxFlat
		if base_sb == null:
			continue
		if i == _focused_idx:
			# Bright gold thick border — replaces normal border, no fill change.
			var focused_sb: StyleBoxFlat = base_sb.duplicate() as StyleBoxFlat
			focused_sb.border_color    = Color(1.0, 0.92, 0.35, 1.0)
			focused_sb.border_width_left   = base_sb.border_width_left   + 4
			focused_sb.border_width_right  = base_sb.border_width_right  + 4
			focused_sb.border_width_top    = base_sb.border_width_top    + 4
			focused_sb.border_width_bottom = base_sb.border_width_bottom + 4
			focused_sb.shadow_color = Color(1.0, 0.92, 0.35, 0.55)
			focused_sb.shadow_size  = 10
			card.add_theme_stylebox_override("normal",  focused_sb)
			card.add_theme_stylebox_override("hover",   focused_sb)
		else:
			# Restore original styleboxes (remove the override so base shows through).
			card.remove_theme_stylebox_override("normal")
			card.remove_theme_stylebox_override("hover")


# ---------------------------------------------------------------------------
# Run 29 — Two-phase pick: Shino first, then Bea from same family
# ---------------------------------------------------------------------------

func _rebuild_for_bea() -> void:
	# Clear ALL children (backdrop, title, labels, cards).
	for child in get_children():
		child.queue_free()
	_cards.clear()
	_picked = false
	_phase = 1
	_focused_idx = 0

	# Roll a fresh set of boon offers for Bea from the SAME family.
	RunState.current_offer.clear()
	if _tutorial_mode:
		# Tutorial: same curated Broccoli attack boons for Bea.
		_offer = ["heavy_stalk", "brute_force", "slugshot"]
	else:
		_offer = RunState.roll_family_offer(_phase_family, "bea")

	# Rebuild the overlay (will now show "BEA'S BOON" header).
	await get_tree().process_frame   # let queue_free flush
	_build_overlay()


func _format_boons_summary() -> String:
	# Compact label like "Heavy Stalk x2, Tough Shell, Quickfoot"
	var counts: Dictionary = {}
	for id in RunState.boons_taken:
		counts[id] = counts.get(id, 0) + 1
	var parts: Array = []
	for id in counts.keys():
		var b: Dictionary = RunState.BOON_POOL.get(id, {})
		var nm: String = b.get("name", id)
		var c: int = counts[id]
		if c > 1:
			parts.append("%s x%d" % [nm, c])
		else:
			parts.append(nm)
	return ", ".join(parts)


func _pick(boon_id: String) -> void:
	if _picked:
		return
	_picked = true

	# Run 41 — Duo card: activate for BOTH ninjas (team passive), then run
	# the same refresh + phase flow. No per-character ownership, no DD map.
	if String(boon_id).begins_with(RunState.DUO_OFFER_PREFIX):
		RunState.take_duo(String(boon_id).trim_prefix(RunState.DUO_OFFER_PREFIX))
		for grp in ["player", "bea"]:
			for p in get_tree().get_nodes_in_group(grp):
				if p.has_method("apply_runstate_modifiers"):
					p.apply_runstate_modifiers()
		_refresh_hud_boon_panel()
		if _phase == 0 and _phase_family != "" and _phase_family != "__upgrade__":
			_rebuild_for_bea()
		else:
			emit_signal("boon_picked", boon_id)
			get_tree().paused = false
			queue_free()
		return

	# Run 139 — apply_boon arms that need the taker's identity (Poison Apple's
	# Golden Apple DD) read pending_picker; set it BEFORE apply_boon runs.
	var picker: String = "shino" if _phase == 0 else "bea"
	RunState.pending_picker = picker
	RunState.apply_boon(boon_id)

	# Record ownership so boon effects only apply to the picking ninja.
	RunState.add_boon_for(picker, boon_id)

	# Run 44 — slot exclusivity: one boon per X/Y/A/B/Charge/Ult slot per ninja.
	# If this pick replaces an occupied slot, the old boon is traded out and
	# the new one starts at +1 level (it was also offered at +1 rarity).
	var traded_out: String = RunState.register_slot_pick(picker, boon_id)
	if traded_out != "":
		var old_name: String = String(RunState.BOON_POOL.get(traded_out, {}).get("name", traded_out))
		print("[BoonOffer] %s traded out %s for %s." % [picker.capitalize(), old_name, boon_id])

	# DD boons: grant charge to the picker specifically (not global pool).
	# Run 40 — use the rarity the boon was TAKEN at (rolled on the offer card).
	var rarity: String = RunState.get_boon_rarity(boon_id)
	match boon_id:
		"cider_mercy":    RunState.grant_dd_to_char(picker, "apple_cider_mercy",      rarity)
		"iron_husk":      RunState.grant_dd_to_char(picker, "coconut_iron_husk",      rarity)
		"green_vengeance":RunState.grant_dd_to_char(picker, "broccoli_green_vengeance", rarity)
		"heart_shot":     RunState.grant_dd_to_char(picker, "carrot_heart_shot",      rarity)
		"vintage_surge":  RunState.grant_dd_to_char(picker, "grape_vintage_surge",    rarity)
		"tide_pool":      RunState.grant_dd_to_char(picker, "watermelon_tide_pool",   rarity)
		"phoenix_pepper": RunState.grant_dd_to_char(picker, "pepper_phoenix_pepper",  rarity)
		"stone_form":     RunState.grant_dd_to_char(picker, "potato_stone_form",      rarity)
		"banana_splits":  RunState.grant_dd_to_char(picker, "banana_banana_splits",   rarity)
		"death_bloom":    RunState.grant_dd_to_char(picker, "onion_death_bloom",      rarity)

	# Only apply_runstate_modifiers to the picking character.
	if picker == "shino":
		for p in get_tree().get_nodes_in_group("player"):
			if p.has_method("apply_runstate_modifiers"):
				p.apply_runstate_modifiers()
	else:
		for b in get_tree().get_nodes_in_group("bea"):
			if b.has_method("apply_runstate_modifiers"):
				b.apply_runstate_modifiers()

	_refresh_hud_boon_panel()
	# Run 29 — Two-phase: Phase 0 = Shino picks, then rebuild for Bea.
	if _phase == 0 and _phase_family != "" and _phase_family != "__upgrade__":
		_rebuild_for_bea()
	else:
		emit_signal("boon_picked", boon_id)
		get_tree().paused = false
		queue_free()


# (duplicate _finish_with_no_offer removed — canonical definition is above _build_overlay)



func _refresh_hud_boon_panel() -> void:
	# Find the HUD node and call its refresh method so the split boon panel updates.
	var hud_nodes: Array = get_tree().get_nodes_in_group("hud")
	for h in hud_nodes:
		if h.has_method("refresh_boon_panel"):
			h.refresh_boon_panel()
			return
	# Fallback: search by class name if not in group.
	var root: Node = get_tree().current_scene
	if root == null:
		return
	for ch in root.get_children():
		if ch.has_method("refresh_boon_panel"):
			ch.refresh_boon_panel()
			return
