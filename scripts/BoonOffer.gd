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

# ── Run 166 — "Ink & Washi" ofuda boon cards (kanji + scroll look) ──────────
# Every glyph below is verified present in DotGothic16 (no tofu). See the
# kanji-audit memory: meaning AND glyph coverage both checked.
# Rarity ribbon kanji (the tier's flavour glyph).
const RARITY_KANJI: Dictionary = {
	"common": "常", "uncommon": "良", "rare": "稀", "epic": "極",
	"legendary": "伝", "duo": "双", "corrupt": "呪",
}
# Per-family element / vegetable kanji, painted in the family colour.
const FAM_KANJI: Dictionary = {
	"Apple": "命", "Coconut": "殻", "Broccoli": "力", "Carrot": "矢",
	"Grape": "房", "Watermelon": "水", "Pepper": "火", "Potato": "芋",
	"Banana": "雷", "Onion": "毒", "Corrupt": "呪",
}
# Ink palette (mirrors UISkin) — kept local so cards read on the washi paper.
const INK_DARK:   Color = Color(0.10980, 0.09020, 0.07843)   # 1c1714 headings on paper
const INK_BODY:   Color = Color(0.22745, 0.19216, 0.15686)   # 3a3128 description ink
const PAPER_DIM:  Color = Color(0.41961, 0.35294, 0.23529)   # 6b5a3c captions on paper
const CREAM_H:    Color = Color(0.95686, 0.91373, 0.80392)   # f4e9cd ribbon text
const GOLD_FOCUS: Color = Color(1.0, 0.85098, 0.47843)       # ffd97a focus ring

# Run 166 — restore the OS pointer while the overlay is up (combat may hide it).
var _prev_mouse_mode: int = Input.MOUSE_MODE_VISIBLE

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

	# Run 166 — combat can hide/capture the pointer; force it visible so the
	# player can actually see (and click) the boon cards. Restored on close.
	_prev_mouse_mode = Input.mouse_mode
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

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
		Log.dbg("[BoonOffer] Pending door pick consumed — type=%s family=%s" % [ptype, room_family])

	if room_family == "":
		# Arena 1 (or any door-less entry): random family from the door-eligible list.
		room_family = String(RunState.DOOR_FAMILIES[randi() % RunState.DOOR_FAMILIES.size()]).capitalize()
		Log.dbg("[BoonOffer] No door pick — random room family rolled: %s" % room_family)

	# Upgrade auto-picks: show a single card so there's a visual for 1 frame,
	# then the deferred auto-pick fires immediately (connected signal is ready by then).
	if _auto_grant_pie:
		_offer = [PIE_ID]
		Log.dbg("[BoonOffer] apple_pie door — auto-granting pie (no card choice).")
	elif _auto_dragon_fruit:
		_offer = [DRAGON_FRUIT_ID]
		Log.dbg("[BoonOffer] dragon_fruit door — auto-triggering upgrade selection.")
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
			Log.dbg("[BoonOffer] Door pick = Legendary → slot 0 locked to %s." % leg_id)

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


func _exit_tree() -> void:
	# Run 166 — hand the pointer back to whatever state combat wants.
	Input.mouse_mode = _prev_mouse_mode


func _build_overlay() -> void:
	# Run 164c — apply the "Ink & Washi" skin to everything built below.
	UISkin.skin_tree_deferred(self)
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

	# Run 166 — kanji subtitle under the title (mock's "恩恵を選べ" = "choose a boon").
	var kanji_sub := Label.new()
	kanji_sub.text = "恩 恵 を 選 べ"
	kanji_sub.add_theme_font_override("font", UISkin.font_body)
	kanji_sub.add_theme_font_size_override("font_size", 18)
	kanji_sub.add_theme_color_override("font_color", Color(0.63, 0.55, 0.38))
	kanji_sub.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.04))
	kanji_sub.add_theme_constant_override("outline_size", 3)
	kanji_sub.anchor_left = 0.0; kanji_sub.anchor_right = 1.0
	kanji_sub.offset_top = 138.0; kanji_sub.offset_bottom = 162.0
	kanji_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kanji_sub.process_mode = Node.PROCESS_MODE_ALWAYS
	kanji_sub.set_meta("_uiskin_done", true)
	add_child(kanji_sub)

	var subtitle := Label.new()
	# Run 158 — bound template, so the whole line swaps device on the fly.
	var sub_tpl: String = "{menu_nav} to choose  •  {accept} to confirm  •  (or click)"
	# Run 46 — Fated Reroll (Sensei Z): advertise the reroll button when charges remain.
	if _can_reroll():
		sub_tpl += "  •  🎲 {reroll} = Reroll (%d left)" % RunState.rerolls_left
	InputGlyphs.bind_label(subtitle, sub_tpl)
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	subtitle.anchor_left = 0.0
	subtitle.anchor_right = 1.0
	subtitle.anchor_top = 0.0
	subtitle.offset_top = 166.0
	subtitle.offset_bottom = 192.0
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
		_register_card(card, i)
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
		Log.dbg("[BoonOffer] Dragon Fruit: no boons for %s, skipping." % who)
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
	InputGlyphs.bind_label(sub, "{menu_nav} to choose  •  {accept} to confirm  •  (or click)")   # Run 158
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
		_register_card(card, i)
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
	Log.dbg("[BoonOffer] Dragon Fruit +%d (%s) applied: %s → level %d" % [_df_levels_up, who, b_data.get("name", boon_id), lvl])
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
	var col: Color  = b.get("color", RunState.FAM_COLOR.get(fam, Color(0.5, 0.5, 0.5)))
	# Run 40 — rarity is the OFFER ROLL for this card (Hades-style), not the pool entry.
	var rarity: String = RunState.get_offer_rarity(boon_id)
	var rarity_col: Color = RunState.RARITY_COLOR.get(rarity, col)
	var rarity_label: String = RunState.RARITY_LABEL.get(rarity, rarity.to_upper())
	var is_corrupt: bool = bool(b.get("corrupt", false)) or fam == "Corrupt"

	# Run 166 — the element kanji + its colour for the talisman plate. Corrupt
	# cards take the curse mark; everything else takes its family element glyph.
	var kanji: String = FAM_KANJI.get(fam, "忍")
	var elem_col: Color = col
	var ribbon_key: String = rarity
	if is_corrupt:
		kanji = FAM_KANJI.get("Corrupt", "呪")
		elem_col = RunState.RARITY_COLOR.get("corrupt", Color(0.55, 0.20, 0.55))
		ribbon_key = "corrupt"

	# ── The ofuda (washi talisman) itself ────────────────────────────────────
	var card := _make_ofuda_card()

	# Ribbon: "RARE ・ 稀" in the tier colour (corrupt → purple).
	var ribbon_col: Color = elem_col if is_corrupt else rarity_col
	_add_ribbon(card, "%s ・ %s" % [rarity_label, RARITY_KANJI.get(ribbon_key, "")], ribbon_col)

	# Element kanji plate.
	_add_kanji_plate(card, kanji, elem_col)

	# Name — dark sumi ink on the washi, faux-bold, wraps if long.
	var name_label := _paper_label(nm, 18, INK_DARK)
	name_label.offset_left = 8; name_label.offset_right = -8
	name_label.offset_top = 80; name_label.offset_bottom = 118
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.add_theme_color_override("font_outline_color", INK_DARK)
	name_label.add_theme_constant_override("outline_size", 1)   # faux-bold, not a dark ring
	card.add_child(name_label)

	# Picker + slot caption ("SHINO - PRIMARY").
	var picker_tag: String = "SHINO" if _phase == 0 else "BEA"
	var slot: String = String(b.get("boon_slot", ""))
	var cap_txt: String = picker_tag
	if slot != "":
		cap_txt += " - %s" % _slot_word(slot)
	var cap := _paper_label(cap_txt, 14, PAPER_DIM)
	cap.add_theme_font_override("font", UISkin.font_micro)   # Silkscreen micro-caps (ASCII only)
	cap.offset_top = 120; cap.offset_bottom = 136
	card.add_child(cap)

	# Run 44 — slot trade-up indicator.
	var trade_picker: String = "shino" if _phase == 0 else "bea"
	if RunState.is_slot_replacement_for(trade_picker, boon_id):
		var old_id: String = String(RunState.owned_slots_by_char.get(trade_picker, {}).get(RunState.get_slot_for_boon(boon_id), ""))
		var old_nm: String = String(RunState.BOON_POOL.get(old_id, {}).get("name", old_id))
		var trade_chip := _paper_label("REPLACES %s (+1)" % old_nm.to_upper(), 11, Color(0.60, 0.36, 0.10))
		trade_chip.offset_top = 136; trade_chip.offset_bottom = 150
		card.add_child(trade_chip)

	# Brush divider.
	var div := UISkin.make_divider(150.0)
	div.anchor_left = 0.0; div.anchor_right = 1.0
	div.offset_left = 34; div.offset_right = -34
	div.offset_top = 152; div.offset_bottom = 166
	div.process_mode = Node.PROCESS_MODE_ALWAYS
	card.add_child(div)

	# Description — softer ink.
	var desc_label := _paper_label(dsc, 15, INK_BODY)
	desc_label.offset_left = 14; desc_label.offset_right = -14
	desc_label.offset_top = 170; desc_label.offset_bottom = 248
	desc_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card.add_child(desc_label)

	# Footer: corrupt warning, else the take hint.
	if is_corrupt:
		var warn := _paper_label("CANNOT BE REMOVED", 11, Color(0.55, 0.13, 0.11))
		warn.add_theme_font_override("font", UISkin.font_micro)
		warn.offset_top = 250; warn.offset_bottom = 272
		card.add_child(warn)
	else:
		var hint_label := Label.new()
		InputGlyphs.bind_label(hint_label, "{accept} / click")   # Run 158
		hint_label.add_theme_font_override("font", UISkin.font_body)
		hint_label.add_theme_font_size_override("font_size", 13)
		hint_label.add_theme_color_override("font_color", PAPER_DIM)
		hint_label.add_theme_constant_override("outline_size", 0)
		hint_label.anchor_right = 1.0
		hint_label.offset_left = 0; hint_label.offset_right = 0
		hint_label.offset_top = 250; hint_label.offset_bottom = 272
		hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hint_label.process_mode = Node.PROCESS_MODE_ALWAYS
		card.add_child(hint_label)

	# Wire the click → pick this boon
	card.pressed.connect(func(): _pick(boon_id))
	return card


# ── Run 166 — ofuda card builder helpers ────────────────────────────────────

## A washi talisman Button at card size, using the ofuda 9-slice. Marked so the
## UISkin walker leaves it alone (we style the whole subtree by hand for paper).
func _make_ofuda_card() -> Button:
	var card := Button.new()
	card.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.process_mode = Node.PROCESS_MODE_ALWAYS
	card.flat = false
	card.text = ""
	card.clip_contents = false
	card.set_meta("_uiskin_skip", true)
	card.add_theme_stylebox_override("normal", UISkin.ofuda_box())
	var hov := UISkin.ofuda_box()
	hov.modulate_color = Color(1.08, 1.05, 0.98)
	card.add_theme_stylebox_override("hover", hov)
	card.add_theme_stylebox_override("pressed", UISkin.ofuda_box())
	card.add_theme_stylebox_override("focus", UISkin.ofuda_box())
	return card


## Rarity/tier ribbon across the top of a card.
func _add_ribbon(card: Control, text: String, bg: Color) -> void:
	var ribbon := Panel.new()
	ribbon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ribbon.process_mode = Node.PROCESS_MODE_ALWAYS
	ribbon.anchor_left = 0.0; ribbon.anchor_right = 1.0
	ribbon.offset_left = -2; ribbon.offset_right = 2
	ribbon.offset_top = -12; ribbon.offset_bottom = 18
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = INK_DARK
	sb.set_border_width_all(2)
	ribbon.add_theme_stylebox_override("panel", sb)
	card.add_child(ribbon)

	var lab := Label.new()
	lab.text = text
	lab.add_theme_font_override("font", UISkin.font_body)
	lab.add_theme_font_size_override("font_size", 13)
	# Dark ink on light ribbons (gold/yellow), cream on dark ones.
	lab.add_theme_color_override("font_color", INK_DARK if bg.get_luminance() > 0.5 else CREAM_H)
	lab.add_theme_constant_override("outline_size", 0)
	lab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lab.process_mode = Node.PROCESS_MODE_ALWAYS
	ribbon.add_child(lab)


## The coloured element-kanji square, centred near the top of the card.
func _add_kanji_plate(card: Control, glyph: String, bg: Color) -> void:
	var plate := Panel.new()
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.process_mode = Node.PROCESS_MODE_ALWAYS
	plate.size = Vector2(56, 56)
	plate.position = Vector2((CARD_WIDTH - 56.0) * 0.5, 22.0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = INK_DARK
	sb.set_border_width_all(3)
	plate.add_theme_stylebox_override("panel", sb)
	card.add_child(plate)

	var lab := Label.new()
	lab.text = glyph
	lab.add_theme_font_override("font", UISkin.font_body)
	lab.add_theme_font_size_override("font_size", 40)
	# Light glyph on saturated/dark plates; dark glyph on pale ones (banana etc.).
	if bg.get_luminance() > 0.62:
		lab.add_theme_color_override("font_color", INK_DARK)
	else:
		lab.add_theme_color_override("font_color", bg.lerp(Color(1, 1, 1), 0.80))
	lab.add_theme_constant_override("outline_size", 0)
	lab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lab.process_mode = Node.PROCESS_MODE_ALWAYS
	plate.add_child(lab)


## A full-width, centred label styled for dark ink on washi paper.
func _paper_label(text: String, px: int, col: Color) -> Label:
	var lab := Label.new()
	lab.text = text
	lab.add_theme_font_override("font", UISkin.font_body)
	lab.add_theme_font_size_override("font_size", px)
	lab.add_theme_color_override("font_color", col)
	lab.add_theme_constant_override("outline_size", 0)
	lab.anchor_left = 0.0; lab.anchor_right = 1.0
	lab.offset_left = 0; lab.offset_right = 0
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lab.process_mode = Node.PROCESS_MODE_ALWAYS
	return lab


## Slot letter → human caption for the picker line.
func _slot_word(slot: String) -> String:
	match slot:
		"Y":      return "PRIMARY"
		"X":      return "SECONDARY"
		"A":      return "RANGED"
		"B":      return "DASH"
		"Charge": return "CHARGE"
		"Ult":    return "ULTIMATE"
		_:        return slot.to_upper()


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
	Log.dbg("[BoonOffer] Fated Reroll — %s offer rerolled (%d left)." % [
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


# Run 166 — register a freshly-built card for the pointer + focus system.
# Marks it off-limits to the UISkin walker (each card is hand-styled) and lets
# the mouse pick it up: hovering a card focuses it, so the cursor and the
# keyboard/gamepad selection always agree.
func _register_card(card: Control, idx: int) -> void:
	if card == null or not is_instance_valid(card):
		return
	card.set_meta("_uiskin_skip", true)
	card.set_meta("_card_idx", idx)
	if not card.mouse_entered.is_connected(_on_card_hovered):
		card.mouse_entered.connect(_on_card_hovered.bind(idx))


func _on_card_hovered(idx: int) -> void:
	if _picked or is_instance_valid(_confirm_panel):
		return
	if idx >= 0 and idx < _cards.size():
		_set_focused(idx)


# Run 166 — focus is now carried by a gold ring + a cinnabar 忍 seal + a small
# lift, NOT by mutating the card's own stylebox. That was the bug: once the
# UISkin walker swapped a card's StyleBoxFlat for a texture plaque, the old
# `as StyleBoxFlat` cast returned null and the highlight silently vanished —
# so nothing showed which card was selected. This works for ANY card type.
func _set_focused(idx: int) -> void:
	_focused_idx = clamp(idx, 0, _cards.size() - 1)
	for i in range(_cards.size()):
		var card: Control = _cards[i]
		if is_instance_valid(card):
			_apply_card_focus(card, i == _focused_idx)


func _apply_card_focus(card: Control, on: bool) -> void:
	# Remember the resting Y once, so repeated focus toggles don't drift.
	if not card.has_meta("_base_y"):
		card.set_meta("_base_y", card.position.y)
	var base_y: float = float(card.get_meta("_base_y"))
	card.position.y = base_y - (10.0 if on else 0.0)

	# Gold glow ring — drawn BEHIND the card so it reads as a frame around it.
	var ring: Panel = card.get_node_or_null("FocusRing") as Panel
	if ring == null:
		ring = Panel.new()
		ring.name = "FocusRing"
		ring.show_behind_parent = true
		ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ring.process_mode = Node.PROCESS_MODE_ALWAYS
		ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ring.offset_left = -8.0
		ring.offset_top = -16.0
		ring.offset_right = 8.0
		ring.offset_bottom = 8.0
		var rsb := StyleBoxFlat.new()
		rsb.bg_color = Color(0, 0, 0, 0)
		rsb.border_color = GOLD_FOCUS
		rsb.set_border_width_all(5)
		rsb.set_corner_radius_all(6)
		rsb.shadow_color = Color(GOLD_FOCUS.r, GOLD_FOCUS.g, GOLD_FOCUS.b, 0.55)
		rsb.shadow_size = 12
		ring.add_theme_stylebox_override("panel", rsb)
		card.add_child(ring)
		card.move_child(ring, 0)
	ring.visible = on

	# Cinnabar 忍 focus seal in the top-left corner (the mock's hanko marker).
	var seal: TextureRect = card.get_node_or_null("FocusSeal") as TextureRect
	if seal == null:
		seal = TextureRect.new()
		seal.name = "FocusSeal"
		seal.texture = UISkin.seal_tex("nin")
		seal.custom_minimum_size = Vector2(52, 52)
		seal.size = Vector2(52, 52)
		seal.stretch_mode = TextureRect.STRETCH_KEEP
		seal.mouse_filter = Control.MOUSE_FILTER_IGNORE
		seal.process_mode = Node.PROCESS_MODE_ALWAYS
		seal.position = Vector2(-22, -26)
		card.add_child(seal)
	seal.visible = on


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
		Log.dbg("[BoonOffer] %s traded out %s for %s." % [picker.capitalize(), old_name, boon_id])

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
