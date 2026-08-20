extends CanvasLayer

# ============================================================
# HUD.gd — Phase 3 meters + Phase 6 Bea bars
# ============================================================
# Shino bars: HP (red), CHI (blue), COMBO (gold)
# Bea bars:   BEA HP (purple), BEA CHI (teal)
#
# Connects to Player and Bea signals via groups.
# ============================================================

const BAR_MAX_WIDTH: float = 200.0   # pixel width of a fully-filled bar

# ── Combo speedometer gauges ─────────────────────────────────────────────────
# Replaces the old gold combo bar. One radial gauge per hero, sitting just
# inside their HP-bar cluster (Shino's on the right of his bars, Bea's on the
# left of hers). Fill sweeps a 270° arc and shifts white→yellow→orange→RED.
class ComboGauge extends Control:
	var count: int = 0
	var cap: int = 30
	var _num: Label = null

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_num = Label.new()
		_num.anchor_right = 1.0
		_num.anchor_bottom = 1.0
		_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_num.add_theme_font_size_override("font_size", 16)
		_num.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		_num.add_theme_constant_override("outline_size", 3)
		_num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_num)

	static func _gauge_color(pct: float) -> Color:
		if pct < 0.33:
			return Color.WHITE.lerp(Color(1.0, 0.88, 0.20), pct / 0.33)
		elif pct < 0.66:
			return Color(1.0, 0.88, 0.20).lerp(Color(1.0, 0.55, 0.10), (pct - 0.33) / 0.33)
		return Color(1.0, 0.55, 0.10).lerp(Color(1.0, 0.08, 0.08), clampf((pct - 0.66) / 0.34, 0.0, 1.0))

	func set_count(c: int) -> void:
		count = clampi(c, 0, cap)
		var pct: float = float(count) / float(cap)
		_num.text = str(count) if count > 0 else ""
		_num.add_theme_color_override("font_color", _gauge_color(pct))
		queue_redraw()

	func _draw() -> void:
		var ctr: Vector2 = size * 0.5
		var r: float = minf(size.x, size.y) * 0.5 - 4.0
		var start: float = deg_to_rad(135.0)
		var span: float = deg_to_rad(270.0)
		# Background track.
		draw_arc(ctr, r, start, start + span, 40, Color(1, 1, 1, 0.14), 5.0, true)
		var pct: float = float(count) / float(cap)
		var col: Color = _gauge_color(pct)
		if pct > 0.0:
			draw_arc(ctr, r, start, start + span * pct, 40, col, 5.0, true)
		# Speedometer needle at the current fill angle.
		var ang: float = start + span * pct
		var dir := Vector2(cos(ang), sin(ang))
		draw_line(ctr + dir * (r * 0.45), ctr + dir * (r - 2.0), col if pct > 0.0 else Color(1, 1, 1, 0.35), 2.0, true)

# ── Boon panels ──────────────────────────────────────────────────────────────
# Two slim transparent strips pinned to the screen edges.  They are designed
# to sit OUTSIDE the active play area so they never obscure the arena.
# The background is a near-black tint at ~40 % opacity; a 2-px accent line
# and a coloured header bar tie each panel to its character.
const BOON_PANEL_W:      float = 118.0   # column width (px)
const BOON_PANEL_MARGIN: float = 2.0     # gap from absolute screen edge
const BOON_FONT_SIZE:    int   = 12
const SHINO_BOON_COL:    Color = Color(1.00, 0.87, 0.32, 1.0)   # warm gold
const BEA_BOON_COL:      Color = Color(0.78, 0.58, 1.00, 1.0)   # lavender
const BOON_BG_COL:       Color = Color(0.04, 0.03, 0.08, 0.42)  # dark navy tint
# Run 166 — washi ofuda chips for the active-boon rails.
const BOON_CHIP_PAPER:   Color = Color(0.90, 0.83, 0.66, 0.96)   # aged washi
const BOON_CHIP_PAPER_HL:Color = Color(1.00, 0.93, 0.72, 0.99)   # brighter on inspect
const BOON_CHIP_BORDER:  Color = Color(0.11, 0.09, 0.08, 0.85)   # sumi ink keyline
const BOON_CHIP_INK:     Color = Color(0.12, 0.10, 0.08, 1.0)    # boon name on paper
const BOON_CHIP_HL_EDGE: Color = Color(0.96, 0.82, 0.35, 1.0)    # cinnabar-gold focus edge

var _shino_boon_panel: VBoxContainer = null   # repopulated on refresh
var _bea_boon_panel:   VBoxContainer = null

# ── Run 39 — Boon inspection mode ────────────────────────────────────────────
# Press [Tab] / controller Start to freeze the game and move a highlight over
# the CONTROLLED character's boon panel (Shino = left, Bea = right).
# W/S (or d-pad / arrows) steps through owned boons; a tooltip shows the full
# description + level. [Esc] or [Tab] again returns control to the character.
const INSPECT_TT_W: float = 260.0
var _inspect_active: bool   = false
var _inspect_who:    String = "shino"
var _inspect_idx:    int    = 0
var _shino_rows: Array = []   # [{id, nm: Label, col: Color}] rebuilt on refresh
var _bea_rows:   Array = []
var _inspect_tooltip: PanelContainer = null

# ── Stick nav gating (boon inspect) ──────────────────────────
const NAV_INITIAL_DELAY: float = 1.5
const NAV_REPEAT_RATE:   float = 0.3
var _nav_held_dir: int   = 0
var _nav_hold_time: float = 0.0
var _nav_repeat_acc: float = 0.0

# Shino bars
@onready var hp_fill: ColorRect       = $HPSection/HPBarBG/HPBarFill
@onready var chi_fill: ColorRect      = $ChiSection/ChiBarBG/ChiBarFill
@onready var combo_fill: ColorRect    = $ComboSection/ComboBarBG/ComboBarFill
@onready var combo_label: Label       = $ComboSection/ComboCountLabel
@onready var hp_value_label: Label    = get_node_or_null("HPSection/HPValueLabel")
@onready var chi_value_label: Label   = get_node_or_null("ChiSection/ChiValueLabel")

# Ult-ready flash label — created lazily when Chi first fills
var _ult_ready_label: Label = null
var _ult_pulse_tween: Tween = null

# Run 62 — Beast Mode "guarded" HP-bar pulse (tier-5 AI sitting at the floor).
var _shino_guard_tween: Tween = null
var _bea_guard_tween: Tween = null
const _GUARD_TINT: Color = Color(0.45, 0.85, 1.0, 1.0)   # steely shield cyan

# Bea bars
@onready var bea_hp_fill: ColorRect   = get_node_or_null("BeaHPSection/BeaHPBarBG/BeaHPBarFill")
@onready var bea_chi_fill: ColorRect  = get_node_or_null("BeaChiSection/BeaChiBarBG/BeaChiBarFill")
@onready var bea_hp_val_label: Label  = get_node_or_null("BeaHPSection/BeaHPValueLabel")
@onready var bea_chi_val_label: Label = get_node_or_null("BeaChiSection/BeaChiValueLabel")

# Boss bar (Run 15) — hidden by default
@onready var boss_section: Control     = get_node_or_null("BossBarSection")
@onready var boss_name_label: Label    = get_node_or_null("BossBarSection/BossNameLabel")
@onready var boss_value_label: Label   = get_node_or_null("BossBarSection/BossValueLabel")
@onready var boss_bar_fill: ColorRect  = get_node_or_null("BossBarSection/BossBarBG/BossBarFill")
@onready var boss_bar_border: ColorRect= get_node_or_null("BossBarSection/BossBarBorder")

# --- Breakbar (Run 117) — built dynamically below the boss HP bar ---
var _breakbar_bg: ColorRect = null
var _breakbar_fill: ColorRect = null
var _breakbar_label: Label = null
const BREAKBAR_HEIGHT: float = 8.0
const BREAKBAR_FILL_COLOR: Color = Color(0.85, 0.75, 0.15, 0.95)   # gold
const BREAKBAR_BROKEN_COLOR: Color = Color(0.95, 0.25, 0.15, 0.95) # red flash
const BREAKBAR_BG_COLOR: Color = Color(0.15, 0.12, 0.10, 0.75)


# Run 27f — live buff/duo/synergy visibility (Bruno's HUD pass).
var _buff_label_shino: Label = null
var _buff_label_bea: Label = null
var _duo_label: Label = null
var _buff_refresh_accum: float = 0.0

func _make_status_label(pos: Vector2, align_right: bool) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.95, 0.92, 0.70, 0.92))
	l.add_theme_constant_override("outline_size", 3)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	if align_right:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		l.size = Vector2(360.0, 16.0)
		l.position.x -= 360.0
	add_child(l)
	return l

func _process(delta: float) -> void:
	# ── Polling-based stick nav for boon inspect (immune to wobble) ──
	if _inspect_active:
		var want: int = 0
		if Input.is_action_pressed("move_up") or Input.is_action_pressed("ui_up") \
		or Input.is_action_pressed("move_left") or Input.is_action_pressed("ui_left"):
			want = -1
		elif Input.is_action_pressed("move_down") or Input.is_action_pressed("ui_down") \
		or Input.is_action_pressed("move_right") or Input.is_action_pressed("ui_right"):
			want = 1

		if want == 0:
			_nav_held_dir = 0; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		elif want != _nav_held_dir:
			_nav_held_dir = want; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
			_inspect_step(want)
		else:
			_nav_hold_time += delta
			if _nav_hold_time >= NAV_INITIAL_DELAY:
				_nav_repeat_acc += delta
				while _nav_repeat_acc >= NAV_REPEAT_RATE:
					_nav_repeat_acc -= NAV_REPEAT_RATE
					_inspect_step(_nav_held_dir)

	_buff_refresh_accum += delta
	if _buff_refresh_accum < 0.4:
		return
	_buff_refresh_accum = 0.0
	var vp: Vector2 = get_viewport().get_visible_rect().size
	if _buff_label_shino == null:
		_buff_label_shino = _make_status_label(Vector2(18.0, vp.y - 118.0), false)
		_buff_label_bea   = _make_status_label(Vector2(vp.x - 18.0, vp.y - 118.0), true)
		_duo_label        = _make_status_label(Vector2(18.0, vp.y - 14.0), false)
		_duo_label.add_theme_color_override("font_color", Color(0.75, 0.60, 0.95, 0.9))
	_buff_label_shino.text = _compose_buff_text(get_tree().get_first_node_in_group("player"), "shino")
	_buff_label_bea.text   = _compose_buff_text(get_tree().get_first_node_in_group("bea"), "bea")
	# Active duo + synergy chips (names, comma-joined).
	var parts: Array = []
	for d_id in RunState.get_active_duos():
		parts.append(String(RunState.DUO_DEFS.get(d_id, {}).get("name", d_id)))
	for s_id in RunState.SYNERGY_DEFS.keys():
		if RunState.is_synergy_active(s_id):
			parts.append(String(RunState.SYNERGY_DEFS[s_id].get("name", s_id)))
	_duo_label.text = ("◆ " + ", ".join(parts)) if not parts.is_empty() else ""

# Compact live-buff readout for one hero. Duck-typed property reads — any
# missing property simply doesn't render.
func _compose_buff_text(hero: Node, who: String = "shino") -> String:
	if hero == null or not is_instance_valid(hero):
		return ""
	var bits: Array = []
	var v: Variant = hero.get("_combat_fury_tier")
	if v != null and int(v) > 0:
		bits.append("Fury x%d" % int(v))
	v = hero.get("_critical_mass_stacks")
	if v != null and int(v) > 0:
		bits.append("CritMass x%d" % int(v))
	v = hero.get("overshield_charges")
	if v != null and int(v) > 0:
		bits.append("Shell x%d" % int(v))
	v = hero.get("_ingrained_time")
	if v != null and float(v) >= RunState.INGRAINED_THRESHOLD and RunState.hero_uses_ingrained(who):
		bits.append("Ingrained")
	v = hero.get("_peel_out_timer")
	if v != null and float(v) > 0.0:
		bits.append("PeelOut")
	v = hero.get("_hot_footed_timer")
	if v != null and float(v) > 0.0:
		bits.append("HotFoot")
	v = hero.get("_candy_apple_bonus")
	if v != null and int(v) > 0:
		bits.append("+%dHP" % int(v))
	v = hero.get("_titans_roar_window")
	if v != null and float(v) > 0.0:
		bits.append("Roar")
	v = hero.get("_bullseye_finale_window")
	if v != null and float(v) > 0.0:
		bits.append("Finale")
	return " • ".join(bits)


# Run 43 — Dream World coin counter (top-right chip). Built at runtime so
# HUD.tscn needs no edit. Refreshed via RunState.add_coins() group-call.
var _coin_label: Label = null

func _build_coin_counter() -> void:
	_coin_label = Label.new()
	_coin_label.name = "CoinCounterLabel"
	_coin_label.add_theme_font_size_override("font_size", 18)
	_coin_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.30))
	_coin_label.add_theme_color_override("font_outline_color", Color(0.08, 0.06, 0.0))
	_coin_label.add_theme_constant_override("outline_size", 4)
	_coin_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_coin_label.offset_left = -170.0
	_coin_label.offset_top = 14.0
	_coin_label.offset_right = -16.0
	_coin_label.offset_bottom = 40.0
	_coin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_coin_label)
	refresh_coin_counter()


func refresh_coin_counter() -> void:
	if _coin_label == null:
		return
	_coin_label.visible = RunState.dream_world_mode
	_coin_label.text = "💰 %d" % RunState.run_coins


func _ready() -> void:
	add_to_group("hud")   # lets BoonOffer find us via get_nodes_in_group("hud")
	# Run 164 — "Ink & Washi" reskin. This only DECORATES the existing nodes:
	# it hangs a wooden 9-slice frame behind each bar track and lays a colourless
	# pixel-gloss overlay on each fill. Every size/colour tween below (boss phase
	# recolours, break-bar flash, guard tint) keeps working untouched, because
	# the gloss is alpha-only and rides on top of whatever colour is set.
	UISkin.skin_hud(self)
	_build_coin_counter()
	_build_combo_gauges()
	# Run 39 — keep processing while the tree is paused so boon-inspect mode
	# (which pauses the game) can still receive input and update the tooltip.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Wait one physics frame so the World scene finishes adding all children
	await get_tree().process_frame

	# --- Connect Shino ---
	var players: Array = get_tree().get_nodes_in_group("player")
	var shino: Node = null
	for p in players:
		if p.has_method("get_current_hp") and not p.is_in_group("bea"):
			shino = p
			break

	if shino == null:
		push_warning("[HUD] No Shino node found in group 'player' — Shino bars static.")
	else:
		shino.hp_changed.connect(_on_hp_changed)
		shino.chi_changed.connect(_on_chi_changed)
		shino.combo_count_changed.connect(_on_combo_count_changed)
		var eff_max_hp: int  = shino.get_effective_max_hp() if shino.has_method("get_effective_max_hp") else shino.max_hp
		var eff_max_chi: int = shino.get_effective_max_chi() if shino.has_method("get_effective_max_chi") else shino.MAX_CHI
		_on_hp_changed(shino.current_hp, eff_max_hp)
		_on_chi_changed(shino.current_chi, eff_max_chi)
		_on_combo_count_changed(shino.combo_count)

	# --- Connect Bea ---
	var bea_nodes: Array = get_tree().get_nodes_in_group("bea")
	if bea_nodes.size() == 0:
		push_warning("[HUD] No node in group 'bea' — Bea bars hidden.")
		_hide_bea_bars()
	else:
		var bea: Node = bea_nodes[0]
		if bea.has_signal("bea_hp_changed"):
			bea.bea_hp_changed.connect(_on_bea_hp_changed)
		if bea.has_signal("bea_chi_changed"):
			bea.bea_chi_changed.connect(_on_bea_chi_changed)
		if bea.has_signal("combo_count_changed"):
			bea.combo_count_changed.connect(_on_bea_combo_count_changed)
			_on_bea_combo_count_changed(bea.combo_count)
		var bea_max: int = bea.get_effective_max_hp() if bea.has_method("get_effective_max_hp") else bea.max_hp
		_on_bea_hp_changed(bea.current_hp, bea_max)
		_on_bea_chi_changed(bea.current_chi, bea.MAX_CHI)

	# --- Boss bar (Run 15) ---
	# Subscribe to the FX bus. BossEnemy emits boss_registered on _ready and
	# notify_boss_hp on each take_damage; we mirror that into the HUD bar.
	# Section starts hidden; first registered boss reveals it.
	var fx: Node = get_node_or_null("/root/FX")
	if fx != null:
		if fx.has_signal("boss_registered"):
			fx.boss_registered.connect(_on_boss_registered)
		if fx.has_signal("boss_unregistered"):
			fx.boss_unregistered.connect(_on_boss_unregistered)
		if fx.has_signal("boss_hp_changed"):
			fx.boss_hp_changed.connect(_on_boss_hp_changed)
		if fx.has_signal("boss_phase_changed"):
			fx.boss_phase_changed.connect(_on_boss_phase_changed)
		if fx.has_signal("boss_breakbar_changed"):
			fx.boss_breakbar_changed.connect(_on_boss_breakbar_changed)
		# Edge case: HUD might initialise AFTER the boss is already in scene
		# (load order isn't guaranteed). If FX already has a current_boss,
		# seed our bar from it.
		if "current_boss" in fx and fx.current_boss != null and is_instance_valid(fx.current_boss):
			_on_boss_registered(fx.current_boss)
			var b: Node = fx.current_boss
			if "current_hp" in b and "max_hp" in b:
				_on_boss_hp_changed(b.current_hp, b.max_hp, b._display_name() if b.has_method("_display_name") else "Boss")
			if "current_phase" in b:
				_on_boss_phase_changed(b.current_phase, 3)
	if boss_section != null:
		boss_section.visible = false

	# --- Boon panels ---
	_build_boon_panels()
	refresh_boon_panel()


func _build_boon_panels() -> void:
	# Each side gets a Panel (bg container) + VBoxContainer (rows) inside.
	var l_panel := _make_side_panel(false)
	add_child(l_panel)
	_shino_boon_panel = _make_boon_vbox()
	l_panel.add_child(_shino_boon_panel)

	var r_panel := _make_side_panel(true)
	add_child(r_panel)
	_bea_boon_panel = _make_boon_vbox()
	r_panel.add_child(_bea_boon_panel)


# Builds the transparent side strip (Panel node).
func _make_side_panel(right_side: bool) -> Panel:
	var p := Panel.new()
	p.name = "BeaBoonBg" if right_side else "ShinoBoonBg"

	# Span the vertical play area — leave the top ~10 % for the ULT-READY bar
	# and debug panel, and the bottom ~20 % for HP / Chi / Combo bars.
	p.anchor_top    = 0.10
	p.anchor_bottom = 0.82
	p.anchor_left   = 1.0 if right_side else 0.0
	p.anchor_right  = 1.0 if right_side else 0.0
	if right_side:
		p.offset_left  = -(BOON_PANEL_W + BOON_PANEL_MARGIN)
		p.offset_right = -BOON_PANEL_MARGIN
	else:
		p.offset_left  = BOON_PANEL_MARGIN
		p.offset_right = BOON_PANEL_W + BOON_PANEL_MARGIN
	p.offset_top    = 0
	p.offset_bottom = 0

	var accent: Color = SHINO_BOON_COL if not right_side else BEA_BOON_COL
	var sb := StyleBoxFlat.new()
	sb.bg_color    = BOON_BG_COL
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.50)
	# 2-px accent line on the inner edge only.
	sb.border_width_top    = 0
	sb.border_width_bottom = 0
	sb.border_width_left   = 2 if right_side else 0
	sb.border_width_right  = 0 if right_side else 2
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Coloured header bar pinned to the top of the panel.
	var hdr_bar := ColorRect.new()
	hdr_bar.color = Color(accent.r, accent.g, accent.b, 0.18)
	hdr_bar.anchor_left  = 0.0;  hdr_bar.anchor_right = 1.0
	hdr_bar.offset_left  = 0;    hdr_bar.offset_right = 0
	hdr_bar.offset_top   = 0;    hdr_bar.offset_bottom = 20
	hdr_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(hdr_bar)

	# Character name inside the header bar. Run 166 — pair with 恩恵 ("boon").
	var hdr_lbl := Label.new()
	hdr_lbl.text = ("BEA 恩恵" if right_side else "SHINO 恩恵")
	hdr_lbl.add_theme_font_size_override("font_size", 11)
	hdr_lbl.add_theme_color_override("font_color", Color(accent.r, accent.g, accent.b, 0.85))
	hdr_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.90))
	hdr_lbl.add_theme_constant_override("outline_size", 3)
	hdr_lbl.anchor_left  = 0.0;  hdr_lbl.anchor_right = 1.0
	hdr_lbl.offset_top   = 2;    hdr_lbl.offset_bottom = 20
	hdr_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hdr_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(hdr_lbl)

	return p


# VBoxContainer that lives inside the panel and holds the boon rows.
func _make_boon_vbox() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.anchor_right  = 1.0
	vb.anchor_bottom = 1.0
	vb.offset_left   = 5
	vb.offset_right  = -4
	vb.offset_top    = 22   # below the header bar
	vb.offset_bottom = -4
	vb.add_theme_constant_override("separation", 2)
	vb.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	return vb


func refresh_boon_panel() -> void:
	if _shino_boon_panel == null or _bea_boon_panel == null:
		return
	_populate_boon_column(_shino_boon_panel, RunState.shino_boon_set, SHINO_BOON_COL, _shino_rows)
	_populate_boon_column(_bea_boon_panel,   RunState.bea_boon_set,   BEA_BOON_COL,   _bea_rows)
	# Run 39 — if a refresh lands while inspect mode is open, re-apply the
	# highlight/tooltip onto the freshly rebuilt rows.
	if _inspect_active:
		_inspect_apply()


func _populate_boon_column(panel: VBoxContainer, boon_set: Dictionary, col: Color, rows: Array = []) -> void:
	rows.clear()
	for ch in panel.get_children():
		ch.queue_free()

	if boon_set.is_empty():
		# Show a faint placeholder so the panel doesn't look broken at run start.
		var empty_lbl := Label.new()
		empty_lbl.text = "—"
		empty_lbl.add_theme_font_size_override("font_size", BOON_FONT_SIZE)
		empty_lbl.add_theme_color_override("font_color", Color(col.r, col.g, col.b, 0.25))
		empty_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		panel.add_child(empty_lbl)
		return

	for boon_id in boon_set.keys():
		var b:   Dictionary = RunState.BOON_POOL.get(boon_id, {})
		var nm:  String     = b.get("name", boon_id)
		var lvl: int        = RunState.get_boon_level(boon_id)
		var fam: String     = String(b.get("family", ""))
		var fam_col: Color  = RunState.FAM_COLOR.get(fam, col)
		# Level numeral in the element colour, darkened so it reads on the washi.
		var lvl_col: Color  = fam_col.lerp(Color(0.12, 0.09, 0.07), 0.32)

		# Run 166 — washi ofuda chip: name (ink) left, Roman-numeral level right.
		var chip := Panel.new()
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.custom_minimum_size = Vector2(0, 22)
		chip.add_theme_stylebox_override("panel", _boon_chip_style(false))
		panel.add_child(chip)

		var row := HBoxContainer.new()
		row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 6; row.offset_right = -5
		row.offset_top = 1;  row.offset_bottom = -1
		row.add_theme_constant_override("separation", 4)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(row)

		var nm_lbl := Label.new()
		nm_lbl.text = nm
		nm_lbl.add_theme_font_size_override("font_size", BOON_FONT_SIZE)
		nm_lbl.add_theme_color_override("font_color", BOON_CHIP_INK)
		nm_lbl.add_theme_constant_override("outline_size", 0)
		nm_lbl.clip_text = true
		nm_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		nm_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(nm_lbl)

		var lvl_lbl := Label.new()
		lvl_lbl.text = _roman(lvl)
		lvl_lbl.add_theme_font_size_override("font_size", 13)
		lvl_lbl.add_theme_color_override("font_color", lvl_col)
		lvl_lbl.add_theme_constant_override("outline_size", 0)
		lvl_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lvl_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(lvl_lbl)

		rows.append({ "id": boon_id, "nm": nm_lbl, "chip": chip, "col": fam_col })

		# Small gap between chips.
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(0, 3)
		gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(gap)


# Run 166 — washi chip stylebox for a boon rail row (highlighted while inspected).
func _boon_chip_style(highlight: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = BOON_CHIP_PAPER_HL if highlight else BOON_CHIP_PAPER
	sb.border_color = BOON_CHIP_HL_EDGE if highlight else BOON_CHIP_BORDER
	sb.set_border_width_all(2 if highlight else 1)
	sb.set_corner_radius_all(3)
	return sb


# Run 166 — Roman numeral for a boon level (1..~12). 0/none → an em dash.
func _roman(n: int) -> String:
	if n <= 0:
		return "—"
	var vals: Array = [10, 9, 5, 4, 1]
	var syms: Array = ["X", "IX", "V", "IV", "I"]
	var out: String = ""
	var x: int = n
	for i in range(vals.size()):
		while x >= vals[i]:
			out += syms[i]
			x -= vals[i]
	return out


func _hide_bea_bars() -> void:
	var bea_hp_section: Node = get_node_or_null("BeaHPSection")
	var bea_chi_section: Node = get_node_or_null("BeaChiSection")
	if bea_hp_section:
		bea_hp_section.visible = false
	if bea_chi_section:
		bea_chi_section.visible = false
	if _bea_gauge != null:
		_bea_gauge.visible = false


# -------------------------------------------------------
# Shino signal handlers
# -------------------------------------------------------
func _on_hp_changed(new_hp: int, max_hp_val: int) -> void:
	var pct: float = float(new_hp) / float(max_hp_val) if max_hp_val > 0 else 0.0
	hp_fill.offset_right = BAR_MAX_WIDTH * clampf(pct, 0.0, 1.0)
	if hp_value_label:
		hp_value_label.text = "%d / %d" % [new_hp, max_hp_val]
	_apply_hp_guard_visual(hp_fill, hp_value_label, "shino", pct, new_hp, max_hp_val)


# Run 62 — paint the "guarded" state on a hero HP bar when that hero is the
# tier-5 AI partner pinned at the Beast Mode damage floor: steely-cyan pulsing
# fill + cyan "GUARDED" value text. Reads RunState for tier + the hero node's
# player_controlled flag, so it follows control on hot-swap. who = shino|bea.
func _apply_hp_guard_visual(fill: ColorRect, value_label: Label, who: String, pct: float, new_hp: int, max_hp_val: int) -> void:
	if fill == null:
		return
	var floored: bool = _hero_is_beastmode_floored(who) and pct <= RunState.BEASTMODE_HP_FLOOR + 0.01
	var tw: Tween = _shino_guard_tween if who == "shino" else _bea_guard_tween
	if floored:
		fill.modulate = _GUARD_TINT
		if value_label:
			value_label.text = "GUARDED  %d / %d" % [new_hp, max_hp_val]
			value_label.add_theme_color_override("font_color", _GUARD_TINT)
		if tw == null or not tw.is_valid():
			tw = create_tween().set_loops()
			tw.tween_property(fill, "modulate:a", 0.5, 0.5)
			tw.tween_property(fill, "modulate:a", 1.0, 0.5)
	else:
		fill.modulate = Color(1.0, 1.0, 1.0, 1.0)
		if value_label:
			value_label.remove_theme_color_override("font_color")
		if tw != null and tw.is_valid():
			tw.kill()
			tw = null
	if who == "shino":
		_shino_guard_tween = tw
	else:
		_bea_guard_tween = tw


# True when the named hero is currently the tier-5 AI partner (not player-
# controlled). The HP floor only applies in that exact state.
func _hero_is_beastmode_floored(who: String) -> bool:
	if RunState.ai_helper_tier != 5:
		return false
	var grp: String = "player" if who == "shino" else "bea"
	var nodes: Array = get_tree().get_nodes_in_group(grp) if get_tree() else []
	if nodes.is_empty() or not ("player_controlled" in nodes[0]):
		return false
	return not bool(nodes[0].player_controlled)


func _on_chi_changed(new_chi: int, max_chi: int) -> void:
	var pct: float = float(new_chi) / float(max_chi) if max_chi > 0 else 0.0
	chi_fill.offset_right = BAR_MAX_WIDTH * clampf(pct, 0.0, 1.0)
	if chi_value_label:
		chi_value_label.text = "%d / %d" % [new_chi, max_chi]
	# Ult-ready indicator: only relevant when Shino is the controlled character.
	var bea_controlled: bool = false
	var bea_nodes: Array = get_tree().get_nodes_in_group("bea") if get_tree() else []
	if bea_nodes.size() > 0 and "player_controlled" in bea_nodes[0]:
		bea_controlled = bool(bea_nodes[0].player_controlled)
	if not bea_controlled:
		_set_ult_ready(new_chi >= max_chi and max_chi > 0)


func _set_ult_ready(ready: bool) -> void:
	if ready:
		if _ult_ready_label == null:
			_ult_ready_label = Label.new()
			_ult_ready_label.name = "UltReadyLabel"
			_ult_ready_label.text = "⚡ ULT READY  [U] ⚡"
			_ult_ready_label.add_theme_font_size_override("font_size", 18)
			_ult_ready_label.add_theme_color_override("font_color", Color(0.40, 0.90, 1.0, 1.0))
			_ult_ready_label.add_theme_color_override("font_outline_color", Color(0.0, 0.15, 0.30, 1.0))
			_ult_ready_label.add_theme_constant_override("outline_size", 4)
			# Position in center-top of screen using anchor/offset layout.
			_ult_ready_label.anchor_left  = 0.0
			_ult_ready_label.anchor_right = 1.0
			_ult_ready_label.anchor_top   = 0.0
			_ult_ready_label.offset_top   = 6.0
			_ult_ready_label.offset_bottom = 32.0
			_ult_ready_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_ult_ready_label.z_index = 12
			_ult_ready_label.process_mode = Node.PROCESS_MODE_ALWAYS
			add_child(_ult_ready_label)
		_ult_ready_label.visible = true
		# Pulsing alpha tween so it catches the eye.
		if _ult_pulse_tween == null or not _ult_pulse_tween.is_valid():
			_ult_pulse_tween = create_tween().set_loops()
			_ult_pulse_tween.tween_property(_ult_ready_label, "modulate:a", 0.35, 0.55)
			_ult_pulse_tween.tween_property(_ult_ready_label, "modulate:a", 1.0, 0.55)
	else:
		if _ult_ready_label != null:
			_ult_ready_label.visible = false
		if _ult_pulse_tween != null and _ult_pulse_tween.is_valid():
			_ult_pulse_tween.kill()
			_ult_pulse_tween = null


# Combo gauges — built at runtime so HUD.tscn needs no edit. The old gold
# combo bar (ComboSection) is hidden in favour of the radial gauges.
var _shino_gauge: ComboGauge = null
var _bea_gauge: ComboGauge = null

func _build_combo_gauges() -> void:
	var old: Node = get_node_or_null("ComboSection")
	if old != null:
		(old as CanvasItem).visible = false
	_shino_gauge = _make_combo_gauge(false)
	_bea_gauge = _make_combo_gauge(true)

func _make_combo_gauge(right_side: bool) -> ComboGauge:
	var g := ComboGauge.new()
	g.name = "BeaComboGauge" if right_side else "ShinoComboGauge"
	# Bottom corners, just INSIDE each hero's HP/Chi bar cluster (which spans
	# x 10..360 from its screen edge): Shino's gauge to the right of his bars,
	# Bea's to the left of hers — both toward screen centre.
	g.anchor_top = 1.0;  g.anchor_bottom = 1.0
	g.anchor_left = 1.0 if right_side else 0.0
	g.anchor_right = g.anchor_left
	# Run 164 — the framed bars are wider and taller than the old flat ones.
	# A hero's cluster now occupies x 12..400 from its screen edge (the value
	# label ends at 400), and the frames span y -120..-38. The gauge sits just
	# outside that, vertically centred on the two-bar stack.
	if right_side:
		g.offset_left = -482.0;  g.offset_right = -424.0
	else:
		g.offset_left = 424.0;   g.offset_right = 482.0
	g.offset_top = -108.0;  g.offset_bottom = -50.0
	add_child(g)
	g.set_count(0)
	return g

func _on_combo_count_changed(count: int) -> void:
	if _shino_gauge != null:
		_shino_gauge.set_count(count)

func _on_bea_combo_count_changed(count: int) -> void:
	if _bea_gauge != null:
		_bea_gauge.set_count(count)


# -------------------------------------------------------
# Bea signal handlers
# -------------------------------------------------------
func _on_bea_hp_changed(new_hp: int, max_hp_val: int) -> void:
	if bea_hp_fill == null:
		return
	var pct: float = float(new_hp) / float(max_hp_val) if max_hp_val > 0 else 0.0
	bea_hp_fill.offset_right = BAR_MAX_WIDTH * clampf(pct, 0.0, 1.0)
	if bea_hp_val_label:
		bea_hp_val_label.text = "%d / %d" % [new_hp, max_hp_val]
	_apply_hp_guard_visual(bea_hp_fill, bea_hp_val_label, "bea", pct, new_hp, max_hp_val)


func _on_bea_chi_changed(new_chi: int, max_chi_val: int) -> void:
	if bea_chi_fill == null:
		return
	var pct: float = float(new_chi) / float(max_chi_val) if max_chi_val > 0 else 0.0
	bea_chi_fill.offset_right = BAR_MAX_WIDTH * clampf(pct, 0.0, 1.0)
	if bea_chi_val_label:
		bea_chi_val_label.text = "%d / %d" % [new_chi, max_chi_val]
	# Show ult-ready indicator when Bea (the controlled character) has full Chi.
	# Only trigger if Bea is currently player-controlled so the indicator isn't
	# misleading when the player is on Shino.
	var bea_nodes: Array = get_tree().get_nodes_in_group("bea")
	if bea_nodes.size() > 0:
		var bea: Node = bea_nodes[0]
		if "player_controlled" in bea and bool(bea.player_controlled):
			_set_ult_ready(new_chi >= max_chi_val and max_chi_val > 0)


# -------------------------------------------------------
# Boss bar handlers (Run 15) — driven by FX bus signals.
# -------------------------------------------------------
# Phase color palette: P1 purple → P2 orange → P3 blood red. Tick marks
# stay static (they mark threshold positions, not current phase).
const BOSS_FILL_P1: Color = Color(0.78, 0.18, 0.85, 1.0)   # purple — base
const BOSS_FILL_P2: Color = Color(1.00, 0.55, 0.05, 1.0)   # orange — Phase 2
const BOSS_FILL_P3: Color = Color(1.00, 0.15, 0.15, 1.0)   # blood red — Phase 3


func _on_boss_registered(_boss: Node) -> void:
	if boss_section != null:
		boss_section.visible = true


func _on_boss_unregistered(_boss: Node) -> void:
	# Hide the bar. If a second boss exists (future encounters), the next
	# boss_registered call will reveal it again.
	if boss_section != null:
		boss_section.visible = false
	if _breakbar_bg and is_instance_valid(_breakbar_bg):
		_breakbar_bg.visible = false
	if _breakbar_label and is_instance_valid(_breakbar_label):
		_breakbar_label.visible = false


func _on_boss_hp_changed(new_hp: int, max_hp_val: int, boss_name: String) -> void:
	if boss_section == null:
		return
	# Defensive: ensure section is visible — first hp update may arrive before
	# the registered signal in some edit orders.
	boss_section.visible = true
	var pct: float = float(new_hp) / float(max_hp_val) if max_hp_val > 0 else 0.0
	pct = clampf(pct, 0.0, 1.0)
	if boss_bar_fill != null:
		# Bar fill uses anchor stretch — modulate anchor_right to scale width.
		boss_bar_fill.anchor_right = pct
	if boss_value_label != null:
		boss_value_label.text = "%d%%  (%d / %d)" % [int(round(pct * 100.0)), new_hp, max_hp_val]
	if boss_name_label != null and not boss_name.is_empty():
		boss_name_label.text = boss_name


func _on_boss_phase_changed(phase: int, _max_phase: int) -> void:
	if boss_bar_fill == null:
		return
	match phase:
		1:
			boss_bar_fill.color = BOSS_FILL_P1
			if boss_bar_border:
				boss_bar_border.color = Color(0.55, 0.05, 0.65, 0.85)
		2:
			boss_bar_fill.color = BOSS_FILL_P2
			if boss_bar_border:
				boss_bar_border.color = Color(0.75, 0.35, 0.05, 0.95)
		3:
			boss_bar_fill.color = BOSS_FILL_P3
			if boss_bar_border:
				boss_bar_border.color = Color(0.85, 0.10, 0.10, 1.0)


# -------------------------------------------------------
# Breakbar handlers (Run 117)
# -------------------------------------------------------

func _ensure_breakbar_nodes() -> void:
	if _breakbar_bg != null and is_instance_valid(_breakbar_bg):
		return
	if boss_section == null:
		return
	# Build a thin bar below the boss HP bar. Uses the same width as the HP bar.
	var hp_bg: Control = boss_section.get_node_or_null("BossBarBG")
	if hp_bg == null:
		return
	_breakbar_bg = ColorRect.new()
	_breakbar_bg.color = BREAKBAR_BG_COLOR
	_breakbar_bg.anchor_left = hp_bg.anchor_left
	_breakbar_bg.anchor_right = hp_bg.anchor_right
	_breakbar_bg.anchor_top = 0.0
	_breakbar_bg.anchor_bottom = 0.0
	_breakbar_bg.offset_left = hp_bg.offset_left
	_breakbar_bg.offset_right = hp_bg.offset_right
	_breakbar_bg.offset_top = hp_bg.offset_bottom + 4.0
	_breakbar_bg.offset_bottom = hp_bg.offset_bottom + 4.0 + BREAKBAR_HEIGHT
	boss_section.add_child(_breakbar_bg)
	_breakbar_fill = ColorRect.new()
	_breakbar_fill.color = BREAKBAR_FILL_COLOR
	_breakbar_fill.anchor_left = 0.0
	_breakbar_fill.anchor_right = 1.0
	_breakbar_fill.anchor_top = 0.0
	_breakbar_fill.anchor_bottom = 1.0
	_breakbar_fill.offset_left = 1.0
	_breakbar_fill.offset_right = -1.0
	_breakbar_fill.offset_top = 1.0
	_breakbar_fill.offset_bottom = -1.0
	_breakbar_bg.add_child(_breakbar_fill)
	_breakbar_label = Label.new()
	_breakbar_label.text = "BREAK"
	_breakbar_label.add_theme_font_size_override("font_size", 9)
	_breakbar_label.add_theme_color_override("font_color", Color(0.95, 0.90, 0.60, 0.85))
	_breakbar_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_breakbar_label.add_theme_constant_override("outline_size", 2)
	_breakbar_label.anchor_left = 0.0
	_breakbar_label.anchor_top = 0.0
	_breakbar_label.offset_left = hp_bg.offset_left - 38.0
	_breakbar_label.offset_top = hp_bg.offset_bottom + 1.0
	boss_section.add_child(_breakbar_label)


func _on_boss_breakbar_changed(current: float, max_val: float, is_broken: bool) -> void:
	_ensure_breakbar_nodes()
	if _breakbar_fill == null:
		return
	var pct: float = clampf(current / maxf(max_val, 1.0), 0.0, 1.0)
	_breakbar_fill.anchor_right = pct
	if is_broken:
		_breakbar_fill.color = BREAKBAR_BROKEN_COLOR
		if _breakbar_label:
			_breakbar_label.text = "BROKEN!"
			_breakbar_label.add_theme_color_override("font_color", Color(1.0, 0.30, 0.15, 1.0))
	else:
		_breakbar_fill.color = BREAKBAR_FILL_COLOR
		if _breakbar_label:
			_breakbar_label.text = "BREAK"
			_breakbar_label.add_theme_color_override("font_color", Color(0.95, 0.90, 0.60, 0.85))
	if _breakbar_bg:
		_breakbar_bg.visible = true


# ============================================================
# Run 39 — Boon inspection mode
# ============================================================

func _unhandled_input(event: InputEvent) -> void:
	if not _inspect_active:
		# Don't open if some other overlay (BoonOffer, pie, etc.) owns the pause.
		if event.is_action_pressed("boon_inspect") and not event.is_echo() \
		and not get_tree().paused:
			_open_inspect(event)
			get_viewport().set_input_as_handled()
		return

	# --- Inspect mode active ---
	if (event.is_action_pressed("boon_inspect") or event.is_action_pressed("ui_cancel")) \
	and not event.is_echo():
		_close_inspect()
		get_viewport().set_input_as_handled()
		return
	# Consume nav events — _process handles movement via polling.
	if event.is_action_pressed("move_up") or event.is_action_pressed("ui_up") \
	or event.is_action_pressed("move_left") or event.is_action_pressed("ui_left") \
	or event.is_action_pressed("move_down") or event.is_action_pressed("ui_down") \
	or event.is_action_pressed("move_right") or event.is_action_pressed("ui_right"):
		get_viewport().set_input_as_handled()


func _open_inspect(event: InputEvent = null) -> void:
	# Inspect the panel of whoever pressed the button.
	_inspect_who = "shino"
	if RunState.two_player and event != null:
		# In 2P, match the event's device to figure out which ninja's player hit minus.
		var dev: int = event.device if (event is InputEventJoypadButton or event is InputEventJoypadMotion) else -1
		if dev == RunState.bea_device:
			_inspect_who = "bea"
	else:
		# 1P: show the panel of whoever the human is currently controlling.
		var bea_nodes: Array = get_tree().get_nodes_in_group("bea")
		if bea_nodes.size() > 0 and "player_controlled" in bea_nodes[0] \
		and bool(bea_nodes[0].player_controlled):
			_inspect_who = "bea"
	_inspect_idx = 0
	_inspect_active = true
	get_tree().paused = true     # controls "switch" to the panel — world freezes
	refresh_boon_panel()         # rebuild rows fresh, then _inspect_apply() runs
	# Container layout settles a frame later — re-apply so the tooltip lands
	# next to the right row instead of at y=0 on the opening frame.
	_inspect_apply.call_deferred()


func _close_inspect() -> void:
	_inspect_active = false
	get_tree().paused = false
	if _inspect_tooltip != null and is_instance_valid(_inspect_tooltip):
		_inspect_tooltip.queue_free()
	_inspect_tooltip = null
	refresh_boon_panel()         # rebuild clean (clears highlight overrides)


func _inspect_rows() -> Array:
	return _bea_rows if _inspect_who == "bea" else _shino_rows


func _inspect_step(dir: int) -> void:
	var rows: Array = _inspect_rows()
	if rows.is_empty():
		return
	_inspect_idx = (_inspect_idx + dir + rows.size()) % rows.size()
	_inspect_apply()


# Re-applies highlight + tooltip onto current rows. Safe to call repeatedly.
func _inspect_apply() -> void:
	# Run 166 — highlight the washi CHIP (not the ink text), so the boon name
	# stays legible on paper while a gold edge marks the inspected row.
	for side_rows in [_shino_rows, _bea_rows]:
		for r in side_rows:
			var chip: Panel = r.get("chip", null)
			if is_instance_valid(chip):
				chip.add_theme_stylebox_override("panel", _boon_chip_style(false))

	var rows: Array = _inspect_rows()
	if rows.is_empty():
		_inspect_idx = 0
		_build_inspect_tooltip("", null)
		return
	_inspect_idx = clampi(_inspect_idx, 0, rows.size() - 1)
	var row: Dictionary = rows[_inspect_idx]
	var sel_chip: Panel = row.get("chip", null)
	if is_instance_valid(sel_chip):
		sel_chip.add_theme_stylebox_override("panel", _boon_chip_style(true))
	var nm_lbl: Label = row["nm"]
	_build_inspect_tooltip(String(row["id"]), nm_lbl if is_instance_valid(nm_lbl) else null)


# Builds (or rebuilds) the tooltip panel next to the inspected column.
# boon_id == "" → "no boons yet" placeholder.
func _build_inspect_tooltip(boon_id: String, anchor_lbl: Label) -> void:
	if _inspect_tooltip != null and is_instance_valid(_inspect_tooltip):
		_inspect_tooltip.queue_free()
	_inspect_tooltip = null

	var accent: Color = BEA_BOON_COL if _inspect_who == "bea" else SHINO_BOON_COL
	var tt := PanelContainer.new()
	tt.custom_minimum_size = Vector2(INSPECT_TT_W, 0)
	tt.z_index = 20
	tt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.04, 0.09, 0.96)
	sb.border_width_left = 2;  sb.border_width_right  = 2
	sb.border_width_top  = 2;  sb.border_width_bottom = 2
	sb.border_color = Color(accent.r, accent.g, accent.b, 0.75)
	sb.corner_radius_top_left = 6;    sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6; sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 10; sb.content_margin_right  = 10
	sb.content_margin_top  = 8;  sb.content_margin_bottom = 8
	tt.add_theme_stylebox_override("panel", sb)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	tt.add_child(vb)

	if boon_id == "":
		var none := Label.new()
		none.text = "No boons yet"
		none.add_theme_font_size_override("font_size", 15)
		none.add_theme_color_override("font_color", accent)
		vb.add_child(none)
		var tip := Label.new()
		tip.text = "Pick boons in the Dream —\nor test some from the\nDojo's Boon Dispenser."
		tip.add_theme_font_size_override("font_size", 12)
		tip.add_theme_color_override("font_color", Color(0.75, 0.72, 0.68, 1.0))
		vb.add_child(tip)
	else:
		var b: Dictionary = RunState.BOON_POOL.get(boon_id, {})
		var fam: String = String(b.get("family", "?"))
		var fam_col: Color = RunState.FAM_COLOR.get(fam, accent)
		# Run 40 — show the rarity this boon was TAKEN at (rolled on the card).
		var rarity: String = RunState.get_boon_rarity(boon_id)

		var nm := Label.new()
		nm.text = String(b.get("name", boon_id))
		nm.add_theme_font_size_override("font_size", 16)
		nm.add_theme_color_override("font_color", fam_col)
		nm.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		nm.add_theme_constant_override("outline_size", 3)
		vb.add_child(nm)

		var meta := Label.new()
		meta.text = "%s  •  %s" % [fam.to_upper(), RunState.RARITY_LABEL.get(rarity, rarity.to_upper())]
		meta.add_theme_font_size_override("font_size", 11)
		meta.add_theme_color_override("font_color", RunState.RARITY_COLOR.get(rarity, Color(0.8, 0.8, 0.8)))
		vb.add_child(meta)

		var lvl: int = RunState.get_boon_level(boon_id)
		var boon_set: Dictionary = RunState.bea_boon_set if _inspect_who == "bea" else RunState.shino_boon_set
		var stacks: int = int(boon_set.get(boon_id, 1))
		var lvl_lbl := Label.new()
		var lvl_txt: String = "Level %d" % lvl
		if lvl > 1:
			lvl_txt += "  (+%d%% effect)" % int(round((RunState.get_boon_level_mult(boon_id) - 1.0) * 100.0))
		if stacks > 1:
			lvl_txt += "   x%d stacks" % stacks
		lvl_lbl.text = lvl_txt
		lvl_lbl.add_theme_font_size_override("font_size", 12)
		lvl_lbl.add_theme_color_override("font_color", Color(0.95, 0.88, 0.55, 1.0))
		vb.add_child(lvl_lbl)

		var sep := HSeparator.new()
		vb.add_child(sep)

		var desc := Label.new()
		desc.text = String(b.get("desc", "(no description)"))
		desc.add_theme_font_size_override("font_size", 13)
		desc.add_theme_color_override("font_color", Color(0.88, 0.86, 0.82, 1.0))
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size = Vector2(INSPECT_TT_W - 24, 0)
		vb.add_child(desc)

	var hint := Label.new()
	InputGlyphs.bind_label(hint, "{menu_nav} browse  •  {cancel} close")   # Run 158
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.55, 0.52, 0.48, 1.0))
	vb.add_child(hint)

	add_child(tt)
	_inspect_tooltip = tt
	tt.reset_size()

	# Position beside the inspected column: Shino (left panel) → tooltip on its
	# right; Bea (right panel) → tooltip on its left. Y follows the highlighted
	# row, clamped to the screen.
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var x: float
	if _inspect_who == "bea":
		x = vp.x - BOON_PANEL_W - BOON_PANEL_MARGIN - 8.0 - tt.size.x
	else:
		x = BOON_PANEL_W + BOON_PANEL_MARGIN + 8.0
	var y: float = vp.y * 0.12
	if anchor_lbl != null and is_instance_valid(anchor_lbl):
		y = anchor_lbl.global_position.y - 4.0
	y = clampf(y, 8.0, max(8.0, vp.y - tt.size.y - 8.0))
	tt.position = Vector2(x, y)
