extends Node2D

# ============================================================
# SenseiZ.gd — Dojo NPC (Run 30, 2026-06-06)
# ============================================================
# Sensei Z sits in the dojo corner. Approach and press [E]
# to open his upgrade shop. Spend Dragon Souls (earned every
# 5 rooms + boss) on permanent run-spanning passive bonuses.
#
# Upgrades are stored in RunState.sensei_* vars and persist
# across runs via the save system (they survive reset_run).
#
# Scene tree expected (added to Dojo.tscn):
#   SenseiZ (Node2D, this script)
#   ├ Body (ColorRect — placeholder NPC art)
#   ├ NameLabel (Label — "Sensei Z")
#   ├ SenseiArea (Area2D — proximity trigger)
#   │  └ CollisionShape2D
#   └ InteractPrompt (Label — "[E] Train")
# ============================================================

const COLOR_BG:        Color = Color(0.06, 0.05, 0.09, 0.96)
const COLOR_PANEL:     Color = Color(0.10, 0.09, 0.14, 0.98)
const COLOR_GOLD:      Color = Color(0.85, 0.70, 0.25, 1.0)
const COLOR_GOLD_DIM:  Color = Color(0.50, 0.40, 0.15, 1.0)
const COLOR_BRIGHT:    Color = Color(1.00, 0.88, 0.40, 1.0)
const COLOR_SPARK:     Color = Color(0.85, 0.45, 0.10, 1.0)
const COLOR_MAXED:     Color = Color(0.35, 0.35, 0.35, 1.0)
const COLOR_BOUGHT:    Color = Color(0.30, 0.60, 0.30, 1.0)

# Each entry: id, display name, description, cost (sparks),
# RunState field name, amount added per purchase, max purchases.
const UPGRADES: Array = [
	# Run 46 — stat-upgrade rebalance: 5 tiers @ 5%/2% per tier, escalating
	# 1/2/3/4/5 spark costs (matches Dragon's Fortune). Shadow Dash 3 tiers
	# @ 1/3/5. Deathless Will single rank @ 3 sparks.
	{
		"id": "dragon_vigor",
		"name": "Dragon Vigor",
		"desc": "Both heroes deal +5% more damage per tier (max +25%).",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_damage_pct",
		"amount": 0.05,
		"max": 5,
		"fmt": "pct",
	},
	{
		"id": "iron_skin",
		"name": "Iron Skin",
		"desc": "Both heroes take 5% less damage per tier (max -25%).",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_dr_pct",
		"amount": 0.05,
		"max": 5,
		"fmt": "pct_minus",
	},
	{
		"id": "shadow_dash",
		"name": "Shadow Dash",
		"desc": "Both heroes gain +1 dash charge per tier (max +3).",
		"cost": 1,
		"costs": [1, 3, 5],
		"field": "sensei_extra_dash",
		"amount": 1,
		"max": 3,
		"fmt": "int_plus",
	},
	{
		"id": "deathless_will",
		"name": "Deathless Will",
		"desc": "Each ninja gains +1 Death Defiance charge.",
		"cost": 3,
		"field": "sensei_extra_dd",
		"amount": 1,
		"max": 1,
		"fmt": "int_plus",
	},
	{
		"id": "dragon_chi",
		"name": "Dragon Chi",
		"desc": "Both heroes passively regenerate Chi: +1 Chi per 5s per tier.",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_chi_regen",
		"amount": 1,
		"max": 5,
		"fmt": "chi_regen",
	},
	{
		"id": "vital_core",
		"name": "Vital Core",
		"desc": "Both heroes gain +5% max HP per tier (max +25%).",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_hp_pct",
		"amount": 0.05,
		"max": 5,
		"fmt": "pct",
	},
	{
		"id": "hunters_eye",
		"name": "Hunter's Eye",
		"desc": "+2% critical hit chance per tier for both heroes (max +10%).",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_crit_pct",
		"amount": 0.02,
		"max": 5,
		"fmt": "pct",
	},
	{
		"id": "swift_wings",
		"name": "Swift Wings",
		"desc": "+5% movement speed per tier for both heroes (max +25%).",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_speed_pct",
		"amount": 0.05,
		"max": 5,
		"fmt": "pct",
	},
	# Run 46 — five new nodes: economy, agency and co-op.
	{
		"id": "boss_hunter",
		"name": "Boss Hunter",
		"desc": "+5% damage per tier against mini-bosses and bosses (max +25%).",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_boss_dmg_pct",
		"amount": 0.05,
		"max": 5,
		"fmt": "pct",
	},
	{
		"id": "deep_pockets",
		"name": "Deep Pockets",
		"desc": "Start each Dream run with +25 coins per tier.",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_pocket_ranks",
		"amount": 1,
		"max": 5,
		"fmt": "coins25",
	},
	{
		"id": "hagglers_tongue",
		"name": "Haggler's Tongue",
		"desc": "Town Square shop prices are 5% lower per tier (max -25%).",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_haggle_ranks",
		"amount": 1,
		"max": 5,
		"fmt": "pct5_minus",
	},
	{
		"id": "fated_reroll",
		"name": "Fated Reroll",
		"desc": "Once per run per tier: reroll a boon offer (press R on the boon screen).",
		"cost": 3,
		"costs": [3, 4, 5],
		"field": "sensei_reroll_ranks",
		"amount": 1,
		"max": 3,
		"fmt": "int_plus",
	},
	{
		"id": "sibling_bond",
		"name": "Sibling Bond",
		"desc": "Revive your partner 15% faster per tier (circle and channel).",
		"cost": 1,
		"costs": [1, 3, 5],
		"field": "sensei_revive_ranks",
		"amount": 1,
		"max": 3,
		"fmt": "pct15",
	},
	# Run 41 — Dragon's Fortune: boon rarity push. Each rank adds +5% to the
	# Uncommon, Rare AND Epic roll chances (RunState.roll_rarity). Escalating
	# cost per rank: 1/2/3/4/5 sparks ("costs" array overrides flat "cost").
	{
		"id": "dragons_fortune",
		"name": "Dragon's Fortune",
		"desc": "Boons are more likely to appear at higher rarity (+5% to Uncommon, Rare and Epic chances per rank).",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_rarity_ranks",
		"amount": 1,
		"max": 5,
		"fmt": "rarity_pct",
	},
	# Run 42 — Legendary / Duo room-chance pushes (+2%/rank, 5% base → 15% max).
	# Corrupt chance is deliberately NOT purchasable — it stays tied to
	# family boons taken per run.
	{
		"id": "legend_seeker",
		"name": "Legend Seeker",
		"desc": "Legendary boons are more likely to appear in room offers (+2% chance per rank, 5% up to 15%).",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_legendary_ranks",
		"amount": 1,
		"max": 5,
		"fmt": "pct2_per_rank",
	},
	{
		"id": "twin_spirits",
		"name": "Twin Spirits",
		"desc": "Duo boons are more likely to appear in room offers (+2% chance per rank, 5% up to 15%).",
		"cost": 1,
		"costs": [1, 2, 3, 4, 5],
		"field": "sensei_duo_ranks",
		"amount": 1,
		"max": 5,
		"fmt": "pct2_per_rank",
	},
]


# Per-rank cost: "costs" array (indexed by purchases made) wins over flat "cost".
func _cost_for(upg: Dictionary, purchases: int) -> int:
	if upg.has("costs"):
		var costs: Array = upg["costs"]
		return int(costs[clampi(purchases, 0, costs.size() - 1)])
	return int(upg["cost"])

var _player_near: bool    = false
var _bodies_near: Array   = []   # Run 38 — every "player"-group body inside the area (Shino AND Bea)
var _shop_open:   bool    = false
var _sel_idx:     int     = 0

# ── Stick nav gating ─────────────────────────────────────────
const NAV_INITIAL_DELAY: float = 1.5
const NAV_REPEAT_RATE:   float = 0.3
var _nav_held_dir: int   = 0
var _nav_hold_time: float = 0.0
var _nav_repeat_acc: float = 0.0

# UI nodes (built in _open_shop)
var _overlay:     CanvasLayer
var _card_nodes:  Array   = []   # Array of Control (one per upgrade)

# Run 71 — static "old master" portrait: frame 0 of Sensei Z.gif (no flame),
# hair/beard recolored white-grey so the shopkeeper reads as the aged sensei.
const DOJO_SPRITE_PATH: String = "res://Assets/Sprites/sensei_z_dojo.png"
const DOJO_SPRITE_SCALE: float = 1.7

@onready var interact_prompt: Label  = $InteractPrompt
@onready var sensei_area: Area2D     = $SenseiArea


@onready var spark_label: Label = $SparkLabel


func _ready() -> void:
	# Run 39 — shop pauses the tree (full player freeze); keep processing so
	# the menu still receives input while paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if interact_prompt:
		interact_prompt.visible = false
	if sensei_area:
		sensei_area.body_entered.connect(_on_area_entered)
		sensei_area.body_exited.connect(_on_area_exited)
	_build_npc_sprite()
	_update_spark_label()


# Run 71 — swap the blue/tan placeholder rects for the recolored old-master
# still. Import-safe: if the PNG hasn't been imported yet, keep the placeholders.
func _build_npc_sprite() -> void:
	if not ResourceLoader.exists(DOJO_SPRITE_PATH):
		push_warning("[SenseiZ] sensei_z_dojo.png not imported yet — keeping placeholder. Open the Godot editor once to import it.")
		return
	var tex: Texture2D = load(DOJO_SPRITE_PATH) as Texture2D
	if tex == null:
		return
	var spr := Sprite2D.new()
	spr.name = "PortraitSprite"
	spr.texture = tex
	spr.centered = true
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp pixels
	spr.scale = Vector2(DOJO_SPRITE_SCALE, DOJO_SPRITE_SCALE)
	# Feet land near the NPC origin (placeholder spanned y -48..+16).
	spr.position = Vector2(0, -15)
	add_child(spr)
	# Hide the placeholder Body/Head rects.
	for n in ["Body", "Head"]:
		var rect: Node = get_node_or_null(n)
		if rect and rect is CanvasItem:
			(rect as CanvasItem).visible = false


func _process(_delta: float) -> void:
	_update_spark_label()
	_refresh_player_near()
	# ── Polling-based stick nav for shop (immune to wobble) ──────
	if _shop_open:
		var want: int = 0
		if Input.is_action_pressed("ui_up") or Input.is_action_pressed("move_up"):
			want = -1
		elif Input.is_action_pressed("ui_down") or Input.is_action_pressed("move_down"):
			want = 1

		if want == 0:
			_nav_held_dir = 0; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
		elif want != _nav_held_dir:
			_nav_held_dir = want; _nav_hold_time = 0.0; _nav_repeat_acc = 0.0
			_sel_idx = (_sel_idx + want + UPGRADES.size()) % UPGRADES.size()
			_refresh_cards()
		else:
			_nav_hold_time += _delta
			if _nav_hold_time >= NAV_INITIAL_DELAY:
				_nav_repeat_acc += _delta
				while _nav_repeat_acc >= NAV_REPEAT_RATE:
					_nav_repeat_acc -= NAV_REPEAT_RATE
					_sel_idx = (_sel_idx + _nav_held_dir + UPGRADES.size()) % UPGRADES.size()
					_refresh_cards()


# Run 38 — controlled-char aware proximity. Both Shino and Bea can talk to
# Sensei Z; the prompt (and [E]) responds to whichever character the human
# is CURRENTLY controlling. Re-checked per frame because a hot-swap can
# happen while standing inside the area.
func _refresh_player_near() -> void:
	_player_near = false
	for b in _bodies_near:
		if not is_instance_valid(b):
			continue
		if "player_controlled" in b and bool(b.player_controlled):
			_player_near = true
			break
	if interact_prompt and not _shop_open:
		interact_prompt.visible = _player_near


func _update_spark_label() -> void:
	if spark_label:
		var s: int = RunState.dragon_souls
		spark_label.text = "🐉 %d spark%s" % [s, "s" if s != 1 else ""]
		spark_label.visible = (s > 0 or _shop_open)


func _on_area_entered(body: Node) -> void:
	# Run 38 — Bea is welcome too. Track every player-group body inside;
	# _refresh_player_near() decides per frame if the CONTROLLED one is here.
	if not body.is_in_group("player"):
		return
	if not _bodies_near.has(body):
		_bodies_near.append(body)


func _on_area_exited(body: Node) -> void:
	_bodies_near.erase(body)


func _unhandled_input(event: InputEvent) -> void:
	if _shop_open:
		if event.is_action_pressed("ui_cancel") or event.is_action_pressed("interact"):
			_close_shop()
			get_viewport().set_input_as_handled()
			return
		# Consume nav events — _process handles movement via polling.
		if event.is_action_pressed("ui_up") or event.is_action_pressed("move_up") \
		or event.is_action_pressed("ui_down") or event.is_action_pressed("move_down"):
			get_viewport().set_input_as_handled()
			return
		if event.is_action_pressed("ui_accept") or event.is_action_pressed("attack_a"):
			_try_purchase(_sel_idx)
			get_viewport().set_input_as_handled()
			return
	else:
		# Don't open on top of another pause-owning overlay (BoonOffer,
		# boon-inspect, dispenser…).
		if _player_near and event.is_action_pressed("interact") and not event.is_echo() \
		and not get_tree().paused:
			# Run 142 — progressive story dialogue, then greeting + choice.
			if _check_lore_dialogue():
				get_viewport().set_input_as_handled()
				return
			_show_sensei_greeting()
			get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Run 142 — Progressive Sensei lore dialogue, driven by island healing score.
# Each lore tier plays ONCE per Dojo visit, then the shop opens normally.
# Tier 1 = post-town-visit (set in Dojo cutscene).
# Tiers 2+ = driven by RunState.island_healing_score() thresholds:
#   Tier 2: score >= 2   (first families starting to heal)
#   Tier 3: score >= 8   (several families recovering)
#   Tier 4: score >= 18  (majority healing, some at Ripe)
#   Tier 5: score >= 30  (nearly all families deep into healing)
#   Tier 6: score >= 40  (all 10 families fully Restored — finale unlock)
# ---------------------------------------------------------------------------
const _DB = preload("res://scripts/DialogBox.gd")

var _lore_played_this_visit: Dictionary = {}

func _check_lore_dialogue() -> bool:
	# Re-evaluate from healing score in case families healed since last check
	RunState.update_sensei_lore_from_healing()
	var tier: int = RunState.sensei_lore_tier
	# Lore tier 1: player returned from checking townspeople (everyone's fruit/veg)
	if tier == 1 and not _lore_played_this_visit.get("tier1_return", false):
		_lore_played_this_visit["tier1_return"] = true
		_play_lore_tier1()
		return true
	if tier >= 2 and not _lore_played_this_visit.get("tier%d" % tier, false):
		_lore_played_this_visit["tier%d" % tier] = true
		_play_lore_generic(tier)
		return true
	return false


func _play_lore_tier1() -> void:
	var dlg := _DB.new_box(self)
	dlg.open("Sensei Z", [
		"You've seen it, then. The corruption has twisted everyone.",
		"The guardian families... their very forms have been changed. They've been turned into the foods they once cultivated.",
		"Orchardmother of the Apple family, Gnarls of the Coconut wave monks... all of them, transformed.",
	])
	dlg.finished.connect(func():
		dlg.queue_free()
		var dlg2 := _DB.new_box(self)
		dlg2.open("Sensei Z", [
			"I've been meditating on this. The shadow that fell over the island originates in the Dream World.",
			"Each night, the Dream World manifests over the island, extending to the edges of our 5 natural biomes — corrupted, overrun with shadow monsters.",
			"If you two can fight through each of the biomes in the dream version of our island and defeat the shadow at its heart... the corruption should begin to lift.",
		])
		dlg2.finished.connect(func():
			dlg2.queue_free()
			var dlg3 := _DB.new_box(self)
			dlg3.open("Sensei Z", [
				"I'll keep investigating from my end while you both Keep pushing through the dream. Each time you return from your dreams, come speak with me — I may have uncovered more.",
				"The guardian families will also heal as you drive back the corruption and discover their life force that was fragmented in the shadows. Visit them each day, and they'll share what they know.",
				"The Boons you collect in the Dream World are real power — fragments of the island guardians' life force, fighting back against the shadow.",
				"Now go - rest in your beds. The Dream World awaits.",
			])
			dlg3.finished.connect(func():
				dlg3.queue_free()
				# Don't force tier 2 — let island_healing_score() drive it.
				# Tier 1 is "played"; tier 2 unlocks at healing score >= 2.
				var sm: Node = get_node_or_null("/root/SaveManager")
				if sm and sm.has_method("save_active_slot"):
					sm.save_active_slot()
			)
		)
	)


func _play_lore_generic(tier: int) -> void:
	var lines: Array = []
	match tier:
		2:
			# Healing score >= 2  (a few families starting to heal)
			lines = [
				"You've returned. The shadow weakens — I can feel it! But it still wasn't enough... You will need to keep returning to the dream each night to fully cleanse our island.",
				"The guardian families you've helped will remember your kindness. Their boons grow stronger with gratitude. Remember to speak with them and bring back their life force you recovered in the dream.",
				"Keep pushing deeper. Each biome you cleanse brings us closer to the source.",
			]
		3:
			# Healing score >= 8  (several families recovering)
			lines = [
				"More biomes cleared! The corruption is retreating faster now.",
				"I've been studying the ancient texts. This shadow... it's not random. Something sinister is directing it.",
				"Be exceedingly careful as you proceed through the dream... The deeper you go, the more the shadow will resist.",
			]
		4:
			# Healing score >= 18  (majority recovering, some at Ripe)
			lines = [
				"Even more shadows cleared! It's working, I can feel the darkness weakening. We are pushing closer to the source...",
				"I can almost see it now — a presence at the peak of the Dream World. The source of all this darkness.",
				"Continue collecting the life force of each guardian family within the dream - as we strengthen their spirits, the path to the summit will open. That's where this ends.",
			]
		5:
			# Healing score >= 30  (nearly all families deep into healing)
			lines = [
				"The guardian families are almost fully healed! Keep up the good work, my young Ninjas...",
				"The shadow knows you're coming. It will throw everything it has at you to stop you from healing the corruption",
				"But I believe in you both. You've grown so much stronger since the first dream... and even more so since the day I found you as wee babies on the dojo's doorstep",
			]
		_:
			# Healing score >= 40  (all 10 families fully Restored — finale)
			lines = [
				"The guardian families are cleansed. The corruption is wiped out. One final push to the summit and we should drive him off for good!",
				"The source of the shadow awaits you there... by now you must realized what he is... my biggest shame... This is the final battle.",
				"Everything you've learned, every boon you've gathered... it all leads to this.",
				"Go, my students. Save our island. Defeat my broken shadow half once and for all...",
				"...and please forgive an old man for his foolishness...",
			]
	var dlg := _DB.new_box(self)
	dlg.open("Sensei Z", lines)
	dlg.finished.connect(func():
		dlg.queue_free()
		# Don't force-advance tier — healing score drives it via
		# RunState.update_sensei_lore_from_healing() at each karma deposit.
		var sm: Node = get_node_or_null("/root/SaveManager")
		if sm and sm.has_method("save_active_slot"):
			sm.save_active_slot()
	)


# ---------------------------------------------------------------------------
# Run 142 — Generic encouragement (no new lore tier to show).
# Rotates through the pool by a persistent visit counter so the player
# gets variety. {hero} is replaced with the controlled hero's name.
# ---------------------------------------------------------------------------

var _sensei_greet_idx: int = 0
var _greeting_choice_layer: CanvasLayer = null

const SENSEI_GREETINGS: Array = [
	# ── Lore / warmth ──
	"You've both become so strong since you were children. It feels like yesterday I found you on that doorstep.",
	"The dream stirs again tonight, {hero}. Stay sharp out there.",
	"Every shadow you fell brings this island closer to the light. I'm proud of you both.",
	"Rest when you need to, fight when you must. That's the whole lesson, really.",
	"I've been meditating on the corruption's flow. It's weakening — slowly, but truly.",
	"The guardian families speak well of you. That means more than any technique I could teach.",
	"The island remembers kindness, {hero}. Every boon you return is a seed planted.",
	"Some nights the dream is crueler than others. That's when the island needs you most.",
	"Pace yourselves. The corruption didn't arrive in one night, and it won't leave in one either.",
	"I remember when Shino could barely hold a stance and Bea tripped over her own naginata. Look at you now.",
	"An old sensei's advice: eat before you dream. Empty stomachs make sloppy combos.",
	"This dojo has stood for three generations. You two will make it stand for three more.",

	# ── Praise + constructive advice (Praise > Correct > Praise) ──
	"Bea, your naginata sweeps are getting fierce. Work on aiming your Meteor Crash landing — hold the direction while charging X. The precision will come.",
	"Shino, your combos are tighter every run. Try mixing in a charged {attack_y} dash to close distance before your opener — you'll catch them off guard.",
	"Good instincts throwing kunai at range, Bea. Next step: hold {attack_a} to charge a Shuriken Flurry for groups. Spread damage is your friend.",
	"Your dodge timing has improved, {hero}. Now try dashing THROUGH attacks instead of away — you're invulnerable during the dash, use it.",
	"I see you both using your Ultimates well. Remember — your Chi builds faster when you vary your attacks. Don't just spam one button.",
	"Shino, your crane kick is devastating. Try catching enemies in a group first, then sweep — one big crane kick clears a room.",
	"Bea, your Vortex Spin pulls enemies in beautifully. Follow it with a Meteor Crash for a devastating combination.",
	"Good use of tag-ins, you two. The partner who's resting recovers Chi faster — swap often and you'll have Ultimates ready sooner.",
	"{hero}, when you see a charged enemy winding up a big attack, that's your opening — dash behind them and punish the recovery.",

	# ── General encouragement ──
	"The dream will test you differently each night. Adapt, don't memorize.",
	"Every boon you carry is a piece of a family's spirit fighting alongside you. Choose wisely.",
	"I've watched you stumble, fall, and get back up. That's not failure — that's training.",
	"The corruption fears you now. I can feel it pulling away from the edges of the island.",
]


func _show_sensei_greeting() -> void:
	# Pick a rotating line
	var hero_name: String = "ninja"
	var player: Node = null
	for p in get_tree().get_nodes_in_group("player"):
		if not p.is_in_group("bea"):
			player = p
			break
	if player and "display_name" in player:
		hero_name = player.display_name
	elif player and player.name == "Bea":
		hero_name = "Bea"
	else:
		# Check if Bea is controlled
		for b in get_tree().get_nodes_in_group("bea"):
			if "player_controlled" in b and b.player_controlled:
				hero_name = "Bea"
				break
		if hero_name == "ninja":
			hero_name = "Shino"

	var line: String = SENSEI_GREETINGS[_sensei_greet_idx % SENSEI_GREETINGS.size()]
	line = line.replace("{hero}", hero_name)
	_sensei_greet_idx += 1

	var dlg := _DB.new_box(self)
	dlg.open("Sensei Z", [line, "Shall we train?"])
	dlg.finished.connect(func():
		dlg.queue_free()
		_show_train_choice()
	)


func _show_train_choice() -> void:
	_greeting_choice_layer = CanvasLayer.new()
	_greeting_choice_layer.layer = 55
	_greeting_choice_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_greeting_choice_layer)
	get_tree().paused = true

	# Dim background
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.06, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_greeting_choice_layer.add_child(dim)

	# Choice box
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(320, 0)
	box.position = Vector2(-160, -50)
	box.add_theme_constant_override("separation", 12)
	_greeting_choice_layer.add_child(box)

	var yes_btn := Button.new()
	yes_btn.text = "Yes, let's train"
	yes_btn.custom_minimum_size = Vector2(300, 44)
	box.add_child(yes_btn)

	var no_btn := Button.new()
	no_btn.text = "Not right now"
	no_btn.custom_minimum_size = Vector2(300, 44)
	box.add_child(no_btn)

	# Focus navigation (gamepad / keyboard)
	var nav := preload("res://scripts/MenuFocusNav.gd").new()
	_greeting_choice_layer.add_child(nav)
	nav.buttons = [yes_btn, no_btn]
	# B / Esc backs out — same as choosing "Not right now".
	nav.on_cancel = func():
		_close_greeting_choice()

	yes_btn.pressed.connect(func():
		_close_greeting_choice()
		_open_shop()
	)
	no_btn.pressed.connect(func():
		_close_greeting_choice()
	)
	yes_btn.grab_focus()


func _close_greeting_choice() -> void:
	get_tree().paused = false
	if _greeting_choice_layer:
		_greeting_choice_layer.queue_free()
		_greeting_choice_layer = null


# ---------------------------------------------------------------------------
# Shop open / close
# ---------------------------------------------------------------------------

func _open_shop() -> void:
	_shop_open = true
	get_tree().paused = true   # Run 39 — fully freeze both heroes while shopping
	if interact_prompt:
		interact_prompt.visible = false

	_overlay = CanvasLayer.new()
	_overlay.layer = 50
	add_child(_overlay)

	# Dark background
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.70)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(bg)

	# Central panel
	var panel_root := Control.new()
	panel_root.set_anchors_preset(Control.PRESET_CENTER)
	panel_root.custom_minimum_size = Vector2(780, 560)
	panel_root.position = Vector2(-390, -280)
	_overlay.add_child(panel_root)

	var panel_bg := StyleBoxFlat.new()
	panel_bg.bg_color = COLOR_PANEL
	panel_bg.border_width_left   = 2
	panel_bg.border_width_right  = 2
	panel_bg.border_width_top    = 2
	panel_bg.border_width_bottom = 2
	panel_bg.border_color        = COLOR_GOLD
	panel_bg.corner_radius_top_left     = 8
	panel_bg.corner_radius_top_right    = 8
	panel_bg.corner_radius_bottom_left  = 8
	panel_bg.corner_radius_bottom_right = 8

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_bg)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel_root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	# --- Header ---
	var header := Label.new()
	header.text = "⚡  SENSEI Z  —  DRAGON SOUL UPGRADES"
	header.add_theme_color_override("font_color", COLOR_BRIGHT)
	header.add_theme_font_size_override("font_size", 22)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(header)

	var spark_lbl := Label.new()
	spark_lbl.name = "SparkCount"
	spark_lbl.add_theme_font_size_override("font_size", 18)
	spark_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(spark_lbl)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	# --- Upgrade cards ---
	var scroll := ScrollContainer.new()
	scroll.name = "UpgradeScroll"   # Run 41 — findable for selection auto-scroll
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var cards_vbox := VBoxContainer.new()
	cards_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards_vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(cards_vbox)

	_card_nodes.clear()
	for i in range(UPGRADES.size()):
		var card := _make_card(i)
		cards_vbox.add_child(card)
		_card_nodes.append(card)

	# --- Footer ---
	var sep2 := HSeparator.new()
	vbox.add_child(sep2)

	var footer := Label.new()
	InputGlyphs.bind_label(footer, "{menu_nav}  Navigate     {accept}  Purchase     {cancel}  Close")   # Run 158
	footer.add_theme_color_override("font_color", COLOR_GOLD_DIM)
	footer.add_theme_font_size_override("font_size", 14)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(footer)

	_refresh_cards()


func _close_shop() -> void:
	_shop_open = false
	get_tree().paused = false
	if _overlay:
		_overlay.queue_free()
		_overlay = null
	_card_nodes.clear()
	if _player_near and interact_prompt:
		InputGlyphs.update_binding(interact_prompt, "[{interact}]  Train with Sensei Z")   # Run 158
		interact_prompt.visible = true


# ---------------------------------------------------------------------------
# Card helpers
# ---------------------------------------------------------------------------

func _make_card(idx: int) -> Control:
	var upg: Dictionary = UPGRADES[idx]

	var card_sb_normal := StyleBoxFlat.new()
	card_sb_normal.bg_color = Color(0.14, 0.12, 0.18, 0.95)
	card_sb_normal.border_width_left   = 1
	card_sb_normal.border_width_right  = 1
	card_sb_normal.border_width_top    = 1
	card_sb_normal.border_width_bottom = 1
	card_sb_normal.border_color        = COLOR_GOLD_DIM
	card_sb_normal.corner_radius_top_left     = 4
	card_sb_normal.corner_radius_top_right    = 4
	card_sb_normal.corner_radius_bottom_left  = 4
	card_sb_normal.corner_radius_bottom_right = 4
	card_sb_normal.content_margin_left   = 12
	card_sb_normal.content_margin_right  = 12
	card_sb_normal.content_margin_top    = 8
	card_sb_normal.content_margin_bottom = 8

	var panel := PanelContainer.new()
	panel.set_meta("card_idx", idx)
	panel.add_theme_stylebox_override("panel", card_sb_normal)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var hbox := HBoxContainer.new()
	panel.add_child(hbox)

	# Name + desc
	var name_desc := VBoxContainer.new()
	name_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(name_desc)

	var name_lbl := Label.new()
	name_lbl.name = "NameLabel"
	name_lbl.text = upg["name"]
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_desc.add_child(name_lbl)

	var desc_lbl := Label.new()
	desc_lbl.text = upg["desc"]
	desc_lbl.add_theme_font_size_override("font_size", 14)
	desc_lbl.add_theme_color_override("font_color", Color(0.75, 0.72, 0.65, 1.0))
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_desc.add_child(desc_lbl)

	# Right side: current value + cost
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(130, 0)
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_child(right)

	var val_lbl := Label.new()
	val_lbl.name = "ValueLabel"
	val_lbl.add_theme_font_size_override("font_size", 16)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(val_lbl)

	var cost_lbl := Label.new()
	cost_lbl.name = "CostLabel"
	cost_lbl.add_theme_font_size_override("font_size", 14)
	cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right.add_child(cost_lbl)

	return panel


func _refresh_cards() -> void:
	# Update spark count header
	if _overlay:
		var sc: Node = _overlay.find_child("SparkCount", true, false)
		if sc is Label:
			sc.text = "🐉  Dragon Souls: %d" % RunState.dragon_souls
			sc.add_theme_color_override("font_color", COLOR_SPARK)

	for i in range(_card_nodes.size()):
		var card: PanelContainer = _card_nodes[i]
		var upg: Dictionary      = UPGRADES[i]
		var field: String        = upg["field"]
		var current_val          = RunState.get(field)
		var purchases: int       = _get_purchases(upg, current_val)
		var maxed: bool          = purchases >= upg["max"]
		var next_cost: int       = _cost_for(upg, purchases)   # Run 41 — per-rank costs
		var can_afford: bool     = RunState.dragon_souls >= next_cost
		var is_sel: bool         = (i == _sel_idx)

		# Card border: gold if selected, dim if not
		var sb: StyleBoxFlat = card.get_theme_stylebox("panel").duplicate()
		if maxed:
			sb.border_color = COLOR_MAXED
			sb.bg_color = Color(0.10, 0.10, 0.10, 0.90)
		elif is_sel:
			sb.border_color  = COLOR_BRIGHT
			sb.bg_color      = Color(0.20, 0.18, 0.26, 0.98)
			sb.border_width_left   = 2
			sb.border_width_right  = 2
			sb.border_width_top    = 2
			sb.border_width_bottom = 2
		else:
			sb.border_color = COLOR_GOLD_DIM
			sb.bg_color     = Color(0.14, 0.12, 0.18, 0.95)
		card.add_theme_stylebox_override("panel", sb)

		# Name label color
		var name_lbl: Label = card.find_child("NameLabel", true, false)
		if name_lbl:
			if maxed:
				name_lbl.add_theme_color_override("font_color", COLOR_MAXED)
			elif is_sel:
				name_lbl.add_theme_color_override("font_color", COLOR_BRIGHT)
			else:
				name_lbl.add_theme_color_override("font_color", COLOR_GOLD)

		# Value label
		var val_lbl: Label = card.find_child("ValueLabel", true, false)
		if val_lbl:
			val_lbl.text = _fmt_value(upg, current_val, purchases)
			if maxed:
				val_lbl.add_theme_color_override("font_color", COLOR_BOUGHT)
			else:
				val_lbl.add_theme_color_override("font_color", COLOR_GOLD)

		# Cost label
		var cost_lbl: Label = card.find_child("CostLabel", true, false)
		if cost_lbl:
			if maxed:
				cost_lbl.text = "MAXED"
				cost_lbl.add_theme_color_override("font_color", COLOR_MAXED)
			else:
				cost_lbl.text = "Cost: %d 🐉  (%d/%d)" % [next_cost, purchases, upg["max"]]
				if can_afford:
					cost_lbl.add_theme_color_override("font_color", COLOR_SPARK)
				else:
					cost_lbl.add_theme_color_override("font_color", Color(0.60, 0.30, 0.20, 1.0))

	# Run 41 — keep the selected card visible (9 entries can overflow now).
	if _overlay and _sel_idx < _card_nodes.size():
		var scr: ScrollContainer = _overlay.find_child("UpgradeScroll", true, false) as ScrollContainer
		if scr and is_instance_valid(_card_nodes[_sel_idx]):
			scr.ensure_control_visible(_card_nodes[_sel_idx])


func _get_purchases(upg: Dictionary, current_val) -> int:
	if upg["fmt"] in ["int_plus", "rarity_pct", "pct2_per_rank", "chi_regen",
			"coins25", "pct5_minus", "pct15"]:
		return int(current_val)
	# float fields — divide by amount (round to avoid floating-point slop)
	if upg["amount"] > 0.0:
		return int(round(float(current_val) / float(upg["amount"])))
	return 0


func _fmt_value(upg: Dictionary, current_val, purchases: int) -> String:
	var fmt: String = upg["fmt"]
	match fmt:
		"pct":
			return "+%.0f%%" % (float(current_val) * 100.0)
		"pct_minus":
			return "-%.0f%%" % (float(current_val) * 100.0)
		"int_plus":
			return "+%d" % int(current_val)
		"rarity_pct":
			# Run 41 — Dragon's Fortune: ranks → +N% per rarity-upgrade chance.
			return "+%d%%" % int(round(int(current_val) * 5.0))
		"pct2_per_rank":
			# Run 42 — Legend Seeker / Twin Spirits: ranks → +N% room chance.
			return "+%d%%" % int(round(int(current_val) * 2.0))
		"chi_regen":
			# Run 46 — Dragon Chi: ranks → +N Chi per 5 seconds.
			return "+%d Chi/5s" % int(current_val)
		"coins25":
			# Run 46 — Deep Pockets: ranks → +N starting coins.
			return "+%d 💰" % (int(current_val) * 25)
		"pct5_minus":
			# Run 46 — Haggler's Tongue: ranks → -N% shop prices.
			return "-%d%%" % (int(current_val) * 5)
		"pct15":
			# Run 46 — Sibling Bond: ranks → +N% revive speed.
			return "+%d%%" % (int(current_val) * 15)
		_:
			return str(current_val)


# ---------------------------------------------------------------------------
# Purchase logic
# ---------------------------------------------------------------------------

func _try_purchase(idx: int) -> void:
	var upg: Dictionary = UPGRADES[idx]
	var field: String   = upg["field"]
	var current_val     = RunState.get(field)
	var purchases: int  = _get_purchases(upg, current_val)

	if purchases >= upg["max"]:
		return   # already maxed
	var next_cost: int = _cost_for(upg, purchases)   # Run 41 — per-rank costs
	if RunState.dragon_souls < next_cost:
		return   # can't afford

	RunState.dragon_souls -= next_cost
	RunState.set(field, current_val + upg["amount"])

	Log.dbg("[SenseiZ] Purchased '%s' — %s now %.3f  (%d sparks remaining)" % [
		upg["name"], field, RunState.get(field), RunState.dragon_souls
	])

	# Autosave the purchase immediately.
	var sm: Node = get_node_or_null("/root/SaveManager")
	if sm and sm.has_method("save_active_slot"):
		sm.save_active_slot()

	_refresh_cards()
