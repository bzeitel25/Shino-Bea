extends Node2D

# ============================================================
# MonsterRig.gd — Run 120 (2026-07-02) — generic strip-based monster rig
# ============================================================
# A REUSABLE, CONFIG-DRIVEN animation rig for Gemini-generated enemy sprites.
# It is a drop-in replacement for the $Body BodyAnimator: it exposes the SAME
# public API every host (DummyEnemy / ChargerEnemy / FastScout / …) already
# calls on its $Body —
#
#     set_anim_state(s: String)   # host state name → a rig animation
#     set_motion_speed(speed)     # host velocity magnitude → walk speed_scale
#     set_config(id: String)      # pick which monster config to drive (rig-only)
#
# …but instead of stick-figure parts it builds a single AnimatedSprite2D at
# runtime from horizontal sprite strips (idle / walk / attack / hit / death).
#
# Unlike OnionRingRig (which is special-purpose: a physically-rolled wheel with
# ghost afterimages), this rig is DATA-driven. Adding the next of the 25 planned
# monsters is a new entry in CONFIGS — no new script. DreamSpawner picks the
# config by the roster's "sprite_rig" field.
#
# ── HOST STATE → ANIMATION MAP ──────────────────────────────────────────────
#   "idle"                       → idle   (loop, gentle fps)
#   "walking"                    → walk   (loop, speed_scale tied to motion)
#   "windup_y"/"windup_x"/"a"    → attack WINDUP sub-clip (the jaws OPENING).
#                                  Timed to land the open-jaw peak right as the
#                                  host's windup ends and damage is dealt.
#   "swing_y"/"swing_x"/"a"      → attack SNAP sub-clip (the jaws CLOSING /
#                                  chomp bite), then a brief hold = "pause after
#                                  each chomp".
#   "hit_recoil"                 → hit    (short flinch, non-loop)
#   "death"                      → death  (crumble, non-loop, holds last frame)
#
# The melee host (DummyEnemy) deals its bite damage exactly at the windup→swing
# transition (ATTACK_WINDUP = 0.28s). We split the 6-frame attack strip into an
# OPENING half (frames driven during windup, ending wide-open) and a CLOSING
# half (driven during swing), so the wide-open chomp lands on the damage frame.
# For a monster whose attack strip is a simple loop, set "attack_open_frames"
# to the strip length to just play the whole thing during windup.
# ============================================================

# ── Per-monster configs ─────────────────────────────────────────────────────
# Fields:
#   strips:        {anim: {"path": res-path, "frames": int}}   (idle/walk/attack/hit/death)
#   scale:         float — downscale factor applied to native frames (rule: <= 1)
#   facing_sign:   +1 if the SOURCE art faces RIGHT, -1 if it faces LEFT.
#                  flip_h is derived so the monster faces its travel/target dir.
#   fps:           {anim: float} per-animation base frame rate.
#   loop:          {anim: bool}  which animations loop.
#   attack_open_frames: how many leading attack frames are the "opening"
#                  (played during windup); the rest are the "closing/snap".
#   ground_ref:    which strip's frame height anchors the vertical placement
#                  (feet-plant); defaults to "walk".
const CONFIGS: Dictionary = {
	# ── Boardwalk Churro Chomper — beach MELEE (churro w/ croc jaw) ──────────
	# Native frames 424x335. scale 0.17 → ~57px tall, hero-ish for a biter.
	"churro": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/churro_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/churro_walk.png",   "frames": 5},
			"attack": {"path": "res://Assets/Sprites/churro_attack.png", "frames": 6},
			"hit":    {"path": "res://Assets/Sprites/churro_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/churro_death.png",  "frames": 2},
		},
		"scale": 0.17,
		"facing_sign": 1.0,     # churro art faces RIGHT
		"fps": {
			"idle":   5.0,
			"walk":   9.0,      # base; scaled by motion speed at runtime
			"attack": 20.0,     # fast snap
			"hit":    10.0,
			"death":  7.0,
		},
		"loop": {
			"idle": true, "walk": true, "attack": false, "hit": false, "death": false,
		},
		# 6-frame chomp: [0,1] closed, [2,3] jaws WIDE (bite), [4,5] closing.
		# Opening half = frames 0..3 (played during windup, ending wide-open at
		# the exact damage moment). Closing half = frames 4..5 (played on swing).
		"attack_open_frames": 4,
		"ground_ref": "walk",
	},

	# ── Popsicle Pelican — beach RANGED (replaces the ranged/lobber shooter) ──
	# Native frames 620x371. scale 0.17 → ~63px tall, hero-ish plinker bird.
	# 4-frame attack strip: [0] beak agape (WINDUP), [1] POPSICLE spit (lobbed
	# arc attack pose), [2] SNOWBALL spit (fast straight attack, mid-lunge),
	# [3] recover. The host (PelicanShooter) drives windup then picks the fire
	# pose per attack type via the "fire_snowball"/"fire_popsicle" states below.
	"pelican": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/pelican_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/pelican_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/pelican_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/pelican_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/pelican_death.png",  "frames": 2},
		},
		"scale": 0.17,
		"facing_sign": 1.0,     # pelican art faces RIGHT (beak points right)
		"fps": {
			"idle":   5.0,
			"walk":   9.0,
			"attack": 16.0,
			"hit":    9.0,
			"death":  6.0,
		},
		"loop": {
			"idle": true, "walk": true, "attack": false, "hit": false, "death": false,
		},
		# Frame 0 = beak agape; held through the host's shot windup.
		"attack_open_frames": 1,
		# Which single attack frame each fire variant snaps to (held briefly as the
		# projectile leaves the beak; the host then returns to idle/walk = recover).
		"attack_fire_frames": {"popsicle": 1, "snowball": 2},
		"ground_ref": "idle",
	},

	# ══════════════════════════════════════════════════════════════════════════
	# Run 122 — 21 junk-food monsters (frames/scales/facing from slice_report_all).
	# Scale tiers: scouts ~48px, standard ~60px, chargers ~70px, tanks ~85px.
	# ══════════════════════════════════════════════════════════════════════════

	# ── BEACH ────────────────────────────────────────────────────────────────
	# Cotton-Candy Wisp — scout (fragile-fast). cellH 324, faces LEFT.
	"wisp": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/wisp_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/wisp_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/wisp_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/wisp_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/wisp_death.png",  "frames": 2},
		},
		"scale": 0.148, "facing_sign": -1.0,
		"fps": {"idle": 6.0, "walk": 11.0, "attack": 18.0, "hit": 10.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 3, "ground_ref": "walk",
	},
	# Funnel-Cake Fortress — tank (beefy-slow). cellH 354, faces FRONT.
	"funnel": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/funnel_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/funnel_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/funnel_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/funnel_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/funnel_death.png",  "frames": 2},
		},
		"scale": 0.240, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 7.0, "attack": 12.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 1, "ground_ref": "walk",
	},

	# ── JUNGLE ───────────────────────────────────────────────────────────────
	# Sour-Gummy Serpent — slime-leaper. cellH 373, faces RIGHT.
	"gummy": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/gummy_idle.png",   "frames": 7},
			"walk":   {"path": "res://Assets/Sprites/gummy_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/gummy_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/gummy_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/gummy_death.png",  "frames": 3},
		},
		"scale": 0.161, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 16.0, "hit": 10.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
	},
	# Choco-Frog Flinger — ranged (dart). Faces RIGHT.
	# Run 150 reslice from Chocolate_Frog_Darter.png master — grid-aware cut,
	# green-key→alpha. Attack cell 4 (smoke+dart VFX) skipped → 5 body frames.
	# Death row had 4 distinct poses (old slice only grabbed 3).
	"chocofrog": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/chocofrog_idle.png",   "frames": 6},
			"walk":   {"path": "res://Assets/Sprites/chocofrog_walk.png",   "frames": 6},
			"attack": {"path": "res://Assets/Sprites/chocofrog_attack.png", "frames": 5},
			"hit":    {"path": "res://Assets/Sprites/chocofrog_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/chocofrog_death.png",  "frames": 4},
		},
		"scale": 0.168, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 14.0, "hit": 9.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		# 5-frame attack: [0] ready stance, [1] raising blowgun, [2] blowgun
		# at mouth AIMING (held through windup — the dodge-readable telegraph),
		# [3] blow/spit (puff of smoke moment), [4] recovery/lower.
		# open_frames=3 → frames 0-2 during windup, frame 2 held as aim pose;
		# frames 3-4 during swing (the blow + recover).
		"attack_open_frames": 3, "ground_ref": "walk",
	},
	# Trail-Blaze Squirrel — scout. cellH 311, faces RIGHT.
	"squirrel": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/squirrel_idle.png",   "frames": 5},
			"walk":   {"path": "res://Assets/Sprites/squirrel_walk.png",   "frames": 5},
			"attack": {"path": "res://Assets/Sprites/squirrel_attack.png", "frames": 5},
			"hit":    {"path": "res://Assets/Sprites/squirrel_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/squirrel_death.png",  "frames": 3},
		},
		"scale": 0.154, "facing_sign": 1.0,
		"fps": {"idle": 6.0, "walk": 12.0, "attack": 18.0, "hit": 10.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
	},
	# Marshmallow Mauler — tank. cellH 345, faces RIGHT.
	"mallow": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/mallow_idle.png",   "frames": 5},
			"walk":   {"path": "res://Assets/Sprites/mallow_walk.png",   "frames": 5},
			"attack": {"path": "res://Assets/Sprites/mallow_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/mallow_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/mallow_death.png",  "frames": 2},
		},
		"scale": 0.246, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 7.0, "attack": 13.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
	},
	# Licorice Lasher — laser. cellH 346, faces UP.
	"licorice": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/licorice_idle.png",   "frames": 6},
			"walk":   {"path": "res://Assets/Sprites/licorice_walk.png",   "frames": 5},
			"attack": {"path": "res://Assets/Sprites/licorice_attack.png", "frames": 6},
			"hit":    {"path": "res://Assets/Sprites/licorice_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/licorice_death.png",  "frames": 2},
		},
		"scale": 0.173, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 14.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 3, "ground_ref": "walk",
	},

	# ── SWAMP ────────────────────────────────────────────────────────────────
	# Rancid-Relish Runt — melee. cellH 321, faces FRONT/RIGHT.
	"relish": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/relish_idle.png",   "frames": 5},
			"walk":   {"path": "res://Assets/Sprites/relish_walk.png",   "frames": 5},
			"attack": {"path": "res://Assets/Sprites/relish_attack.png", "frames": 5},
			"hit":    {"path": "res://Assets/Sprites/relish_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/relish_death.png",  "frames": 2},
		},
		"scale": 0.187, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 15.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
	},
	# Kombucha Kraken-let — ranged (bubble spit). cellH 309, faces FRONT.
	"kombucha": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/kombucha_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/kombucha_walk.png",   "frames": 5},
			"attack": {"path": "res://Assets/Sprites/kombucha_attack.png", "frames": 6},
			"hit":    {"path": "res://Assets/Sprites/kombucha_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/kombucha_death.png",  "frames": 2},
		},
		"scale": 0.194, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 15.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		# Frames 1-4 charge; the ranged host holds the late frames for the spit.
		"attack_open_frames": 4, "ground_ref": "walk",
	},
	# Expired-Egg Bloater — charger (self-detonating bruiser). cellH 337, faces FRONT/RIGHT.
	"eggbomb": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/eggbomb_idle.png",   "frames": 5},
			"walk":   {"path": "res://Assets/Sprites/eggbomb_walk.png",   "frames": 5},
			"attack": {"path": "res://Assets/Sprites/eggbomb_attack.png", "frames": 6},
			"hit":    {"path": "res://Assets/Sprites/eggbomb_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/eggbomb_death.png",  "frames": 3},
		},
		"scale": 0.208, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 8.0, "attack": 12.0, "hit": 9.0, "death": 8.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 5, "ground_ref": "walk",
	},
	# Sauerkraut Skulker — scout. cellH 323, faces FRONT.
	"kraut": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/kraut_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/kraut_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/kraut_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/kraut_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/kraut_death.png",  "frames": 4},
		},
		"scale": 0.149, "facing_sign": 1.0,
		"fps": {"idle": 6.0, "walk": 11.0, "attack": 16.0, "hit": 10.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 1, "ground_ref": "walk",
	},

	# ── CAVERNS ──────────────────────────────────────────────────────────────
	# Popcorn Popper — ranged w/ TWO spit poses (short jet vs big jet). cellH 365, faces FRONT/RIGHT.
	"popcorn": {
		"strips": {
			# Run 138 — idle resliced 8→4: the old slicer split each pose's floating
			# kernels into their own clipped frames; now 4 full kettle poses.
			"idle":   {"path": "res://Assets/Sprites/popcorn_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/popcorn_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/popcorn_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/popcorn_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/popcorn_death.png",  "frames": 4},
		},
		"scale": 0.164, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 15.0, "hit": 9.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		# Frame 0 = windup; two fire poses (short jet = frame 2, big jet = frame 3)
		# selected by the pelican-style host via fire_snowball/fire_popsicle states.
		"attack_open_frames": 1,
		"attack_fire_frames": {"snowball": 2, "popsicle": 3},
		"ground_ref": "walk",
	},
	# Fry-Oil Fiend — slime-leaper (oil splash). cellH 286, faces FRONT.
	"fryoil": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/fryoil_idle.png",   "frames": 5},
			"walk":   {"path": "res://Assets/Sprites/fryoil_walk.png",   "frames": 5},
			"attack": {"path": "res://Assets/Sprites/fryoil_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/fryoil_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/fryoil_death.png",  "frames": 3},
		},
		"scale": 0.210, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 15.0, "hit": 9.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 1, "ground_ref": "walk",
	},
	# Jawbreaker Juggernaut — charger. cellH 339, faces FRONT.
	"jawbreaker": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/jawbreaker_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/jawbreaker_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/jawbreaker_attack.png", "frames": 6},
			"hit":    {"path": "res://Assets/Sprites/jawbreaker_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/jawbreaker_death.png",  "frames": 3},
		},
		"scale": 0.206, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 13.0, "hit": 9.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 5, "ground_ref": "walk",
	},
	# Cinder-Chili Skitter ("Chili Critter") — scout (flame-breath cone). cellH 303, faces RIGHT.
	"chili": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/chili_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/chili_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/chili_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/chili_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/chili_death.png",  "frames": 2},
		},
		"scale": 0.158, "facing_sign": 1.0,
		"fps": {"idle": 6.0, "walk": 11.0, "attack": 15.0, "hit": 10.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 1, "ground_ref": "walk",
	},
	# Nacho-Slag Golem — tank w/ SECONDARY smash shockwave (nacho_smash extra strip).
	# cellH 177, idle/attack face SOUTH, walk faces RIGHT.
	"nacho": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/nacho_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/nacho_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/nacho_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/nacho_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/nacho_death.png",  "frames": 4},
		},
		"scale": 0.480, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 7.0, "attack": 13.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
		# Run 122 — periodic telegraphed AoE slam: "Raise Arm and Smash Down
		# Shockwave" (4 frames: 2 raise windup -> small impact -> big burst).
		# Driven via set_anim_state("smash_windup") / ("smash_hit").
		"extra_strips": {
			"smash": {"path": "res://Assets/Sprites/nacho_smash.png", "frames": 4},
		},
		"smash_open_frames": 2, "smash_fps": 11.0,
	},

	# ── FROSTPEAK ────────────────────────────────────────────────────────────
	# Snow-Cone Sniper — ranged. cellH 357, faces RIGHT.
	"snowcone": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/snowcone_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/snowcone_walk.png",   "frames": 5},
			"attack": {"path": "res://Assets/Sprites/snowcone_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/snowcone_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/snowcone_death.png",  "frames": 2},
		},
		"scale": 0.168, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 15.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
	},
	# Peppermint Prowler — melee. cellH 332, faces RIGHT.
	"prowler": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/prowler_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/prowler_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/prowler_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/prowler_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/prowler_death.png",  "frames": 2},
		},
		"scale": 0.181, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 10.0, "attack": 16.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
	},
	# Whipped-Cream Wraith — scout. cellH 347, faces RIGHT.
	"wraith": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/wraith_idle.png",   "frames": 5},
			"walk":   {"path": "res://Assets/Sprites/wraith_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/wraith_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/wraith_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/wraith_death.png",  "frames": 3},
		},
		"scale": 0.138, "facing_sign": 1.0,
		"fps": {"idle": 6.0, "walk": 11.0, "attack": 16.0, "hit": 10.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
	},
	# Frozen-Yogurt Yeti — charger. cellH 341, faces FRONT.
	"yeti": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/yeti_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/yeti_walk.png",   "frames": 8},
			"attack": {"path": "res://Assets/Sprites/yeti_attack.png", "frames": 6},
			"hit":    {"path": "res://Assets/Sprites/yeti_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/yeti_death.png",  "frames": 2},
		},
		"scale": 0.205, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 10.0, "attack": 13.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 4, "ground_ref": "walk",
	},
	# Gelato Golem — tank. cellH 359, faces FRONT.
	"gelato": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/gelato_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/gelato_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/gelato_attack.png", "frames": 5},
			"hit":    {"path": "res://Assets/Sprites/gelato_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/gelato_death.png",  "frames": 4},
		},
		"scale": 0.237, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 7.0, "attack": 12.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 1, "ground_ref": "walk",
	},

	# ══════════════════════════════════════════════════════════════════════════
	# Run 124 — ELEMENTAL JELLY SLIMES (host = SlimeEnemy, arch "slime").
	# Six hand-drawn strips each: idle/walk/hit/death + two extra attack strips
	# leap (6f) and element (5f). Run 135: strips re-sliced blob-by-blob from
	# the master sheets (one slime per frame guaranteed; the leap panel always
	# had 6 drawings, so leap grew a frame and leap_land plays the last 2).
	# The leaping host drives:
	#   WINDUP → "leap_windup" (squash), LEAP → "leap_air" (stretch/airborne),
	#   LAND   → "leap_land" (splat) ; point-blank breath → "element_windup" /
	#   "element_hit". All jellies face RIGHT. Cells are uniform per jelly so
	#   every strip feet-aligns automatically (ground_ref irrelevant, kept "idle").
	# Scales target a ~72px body at node-scale 1.0 (DreamBiomes shrinks further).
	# ══════════════════════════════════════════════════════════════════════════
	"seasalt": {   # Beach · water
		"strips": {
			"idle":  {"path": "res://Assets/Sprites/seasalt_idle.png",  "frames": 4},
			"walk":  {"path": "res://Assets/Sprites/seasalt_walk.png",  "frames": 4},
			"hit":   {"path": "res://Assets/Sprites/seasalt_hit.png",   "frames": 2},
			"death": {"path": "res://Assets/Sprites/seasalt_death.png", "frames": 3},
		},
		"scale": 0.316, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "hit": 10.0, "death": 7.0, "leap": 14.0, "element": 7.0},
		"loop": {"idle": true, "walk": true, "hit": false, "death": false, "leap": false, "element": false},
		"ground_ref": "idle",
		"extra_strips": {
			"leap":    {"path": "res://Assets/Sprites/seasalt_leap.png",    "frames": 6},
			"element": {"path": "res://Assets/Sprites/seasalt_element.png", "frames": 5},
		},
		"leap_windup_frames": 1, "leap_land_frames": 2, "element_open_frames": 2,
	},
	"sodastatic": {   # Beach · electric
		"strips": {
			"idle":  {"path": "res://Assets/Sprites/sodastatic_idle.png",  "frames": 4},
			"walk":  {"path": "res://Assets/Sprites/sodastatic_walk.png",  "frames": 4},
			"hit":   {"path": "res://Assets/Sprites/sodastatic_hit.png",   "frames": 2},
			"death": {"path": "res://Assets/Sprites/sodastatic_death.png", "frames": 3},
		},
		"scale": 0.316, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "hit": 10.0, "death": 7.0, "leap": 14.0, "element": 7.0},
		"loop": {"idle": true, "walk": true, "hit": false, "death": false, "leap": false, "element": false},
		"ground_ref": "idle",
		"extra_strips": {
			"leap":    {"path": "res://Assets/Sprites/sodastatic_leap.png",    "frames": 6},
			"element": {"path": "res://Assets/Sprites/sodastatic_element.png", "frames": 5},
		},
		"leap_windup_frames": 1, "leap_land_frames": 2, "element_open_frames": 2,
	},
	"matcha": {   # Jungle · plant
		"strips": {
			"idle":  {"path": "res://Assets/Sprites/matcha_idle.png",  "frames": 4},
			"walk":  {"path": "res://Assets/Sprites/matcha_walk.png",  "frames": 4},
			"hit":   {"path": "res://Assets/Sprites/matcha_hit.png",   "frames": 2},
			"death": {"path": "res://Assets/Sprites/matcha_death.png", "frames": 3},
		},
		"scale": 0.232, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "hit": 10.0, "death": 7.0, "leap": 14.0, "element": 7.0},
		"loop": {"idle": true, "walk": true, "hit": false, "death": false, "leap": false, "element": false},
		"ground_ref": "idle",
		"extra_strips": {
			"leap":    {"path": "res://Assets/Sprites/matcha_leap.png",    "frames": 6},
			"element": {"path": "res://Assets/Sprites/matcha_element.png", "frames": 5},
		},
		"leap_windup_frames": 1, "leap_land_frames": 2, "element_open_frames": 2,
	},
	"sourvenom": {   # Swamp · poison
		"strips": {
			"idle":  {"path": "res://Assets/Sprites/sourvenom_idle.png",  "frames": 4},
			"walk":  {"path": "res://Assets/Sprites/sourvenom_walk.png",  "frames": 4},
			"hit":   {"path": "res://Assets/Sprites/sourvenom_hit.png",   "frames": 2},
			"death": {"path": "res://Assets/Sprites/sourvenom_death.png", "frames": 3},
		},
		"scale": 0.275, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "hit": 10.0, "death": 7.0, "leap": 13.0, "element": 7.0},
		"loop": {"idle": true, "walk": true, "hit": false, "death": false, "leap": false, "element": false},
		"ground_ref": "idle",
		"extra_strips": {
			"leap":    {"path": "res://Assets/Sprites/sourvenom_leap.png",    "frames": 6},
			"element": {"path": "res://Assets/Sprites/sourvenom_element.png", "frames": 5},
		},
		"leap_windup_frames": 1, "leap_land_frames": 2, "element_open_frames": 2,
	},
	"caramel": {   # Caverns · earth
		"strips": {
			"idle":  {"path": "res://Assets/Sprites/caramel_idle.png",  "frames": 4},
			"walk":  {"path": "res://Assets/Sprites/caramel_walk.png",  "frames": 4},
			"hit":   {"path": "res://Assets/Sprites/caramel_hit.png",   "frames": 2},
			"death": {"path": "res://Assets/Sprites/caramel_death.png", "frames": 3},
		},
		"scale": 0.314, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 8.0, "hit": 10.0, "death": 7.0, "leap": 12.0, "element": 7.0},
		"loop": {"idle": true, "walk": true, "hit": false, "death": false, "leap": false, "element": false},
		"ground_ref": "idle",
		"extra_strips": {
			"leap":    {"path": "res://Assets/Sprites/caramel_leap.png",    "frames": 6},
			"element": {"path": "res://Assets/Sprites/caramel_element.png", "frames": 5},
		},
		"leap_windup_frames": 1, "leap_land_frames": 2, "element_open_frames": 2,
	},
	"hotsauce": {   # Caverns · fire
		"strips": {
			"idle":  {"path": "res://Assets/Sprites/hotsauce_idle.png",  "frames": 4},
			"walk":  {"path": "res://Assets/Sprites/hotsauce_walk.png",  "frames": 4},
			"hit":   {"path": "res://Assets/Sprites/hotsauce_hit.png",   "frames": 2},
			"death": {"path": "res://Assets/Sprites/hotsauce_death.png", "frames": 3},
		},
		"scale": 0.240, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "hit": 10.0, "death": 7.0, "leap": 14.0, "element": 7.0},
		"loop": {"idle": true, "walk": true, "hit": false, "death": false, "leap": false, "element": false},
		"ground_ref": "idle",
		"extra_strips": {
			"leap":    {"path": "res://Assets/Sprites/hotsauce_leap.png",    "frames": 6},
			"element": {"path": "res://Assets/Sprites/hotsauce_element.png", "frames": 5},
		},
		"leap_windup_frames": 1, "leap_land_frames": 2, "element_open_frames": 2,
	},
	# NOTE: key is "snowjelly" (NOT "snowcone" — that config is the Snow-Cone
	# SNIPER bird, a different enemy). Strips are snowjelly_*.png.
	"snowjelly": {   # Frostpeak · ice
		"strips": {
			"idle":  {"path": "res://Assets/Sprites/snowjelly_idle.png",  "frames": 4},
			"walk":  {"path": "res://Assets/Sprites/snowjelly_walk.png",  "frames": 4},
			"hit":   {"path": "res://Assets/Sprites/snowjelly_hit.png",   "frames": 2},
			"death": {"path": "res://Assets/Sprites/snowjelly_death.png", "frames": 3},
		},
		"scale": 0.263, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "hit": 10.0, "death": 7.0, "leap": 13.0, "element": 7.0},
		"loop": {"idle": true, "walk": true, "hit": false, "death": false, "leap": false, "element": false},
		"ground_ref": "idle",
		"extra_strips": {
			"leap":    {"path": "res://Assets/Sprites/snowjelly_leap.png",    "frames": 6},
			"element": {"path": "res://Assets/Sprites/snowjelly_element.png", "frames": 5},
		},
		"leap_windup_frames": 1, "leap_land_frames": 2, "element_open_frames": 2,
	},

	# ══════════════════════════════════════════════════════════════════════════
	# Run 125 — BIOME BOSSES & MINIBOSSES (10, one miniboss + one boss per biome).
	# Host = DummyEnemy (arch "melee") except mustard (arch "ranged"). All source
	# art faces FRONT → facing_sign 1.0. Every melee monster drives a secondary
	# "smash" AoE via extra_strips (nacho precedent). BASE body height target:
	# minibosses ≈66px, big bosses ≈68px; the DreamBiomes roster node-scale
	# (1.8-2.0 mini / 2.4-2.7 boss) multiplies on top → ≈120-135px minis,
	# ≈165-185px bosses on screen. scale = target_px / cell_h (3 dp).
	# ══════════════════════════════════════════════════════════════════════════

	# ── BEACH ────────────────────────────────────────────────────────────────
	# Corn Dog Colossus — miniboss (corndog luchador). cell_h 374.
	# scale 0.176 = 66/374 → base ≈66px; ×1.9 node = ≈125px on screen.
	"colossus": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/colossus_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/colossus_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/colossus_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/colossus_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/colossus_death.png",  "frames": 3},
		},
		"scale": 0.176, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 7.0, "attack": 12.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
		# Batter Quake spin → ground splat (4f: 2 raise → impact → burst).
		"extra_strips": {
			"smash": {"path": "res://Assets/Sprites/colossus_smash.png", "frames": 4},
		},
		"smash_open_frames": 2, "smash_fps": 11.0,
	},
	# Corn Dog Kraken — BOSS (fried octopus). cell_h 296.
	# scale 0.230 = 68/296 → base ≈68px; ×2.6 node = ≈177px on screen.
	"kraken": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/kraken_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/kraken_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/kraken_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/kraken_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/kraken_death.png",  "frames": 3},
		},
		"scale": 0.230, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 7.0, "attack": 12.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
		# Oil geyser eruption (3f: raise → impact → big burst).
		"extra_strips": {
			"smash": {"path": "res://Assets/Sprites/kraken_smash.png", "frames": 3},
		},
		"smash_open_frames": 2, "smash_fps": 10.0,
	},

	# ── JUNGLE ───────────────────────────────────────────────────────────────
	# Gummy Gorilla — miniboss (psychedelic gummy). cell_h 390.
	# scale 0.169 = 66/390 → base ≈66px; ×1.9 node = ≈125px on screen.
	"gorilla": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/gorilla_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/gorilla_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/gorilla_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/gorilla_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/gorilla_death.png",  "frames": 2},
		},
		"scale": 0.169, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 8.0, "attack": 13.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
		"ground_h": 390,   # Run 175: walk strip re-cut 390→426 (heads no longer clipped); keep old grounding
		# Sour-Sugar Thump ground slam + pink splash (4f).
		"extra_strips": {
			"smash": {"path": "res://Assets/Sprites/gorilla_smash.png", "frames": 4},
		},
		"smash_open_frames": 2, "smash_fps": 11.0,
	},
	# Banana-Split Simian — BOSS (simian king, huge cell). cell_h 758.
	# scale 0.090 = 68/758 → base ≈68px; ×2.5 node = ≈170px on screen.
	"simian": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/simian_idle.png",   "frames": 3},
			"walk":   {"path": "res://Assets/Sprites/simian_walk.png",   "frames": 3},
			"attack": {"path": "res://Assets/Sprites/simian_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/simian_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/simian_death.png",  "frames": 2},
		},
		"scale": 0.090, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 14.0, "hit": 9.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
		# Roar + banana-swipe crescent (3f).
		"extra_strips": {
			"smash": {"path": "res://Assets/Sprites/simian_smash.png", "frames": 3},
		},
		"smash_open_frames": 2, "smash_fps": 11.0,
	},

	# ── SWAMP ────────────────────────────────────────────────────────────────
	# Mustard Marauder — RANGED miniboss (mustard cannon). cell_h 383.
	# scale 0.172 = 66/383 → base ≈66px; ×1.8 node = ≈119px on screen.
	# NOTE: ranged host never drives smash states, so mustard_smash.png is left
	# UNWIRED on disk (no extra_strips). glob projectile (mustard_glob.png) is
	# also unwired here — the ranged host spawns its own shot.
	"mustard": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/mustard_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/mustard_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/mustard_attack.png", "frames": 3},
			"hit":    {"path": "res://Assets/Sprites/mustard_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/mustard_death.png",  "frames": 2},
		},
		"scale": 0.172, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 14.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
	},
	# Pickled Hydra — BOSS (pickle-barrel hydra; walk==idle barrel). cell_h 408.
	# scale 0.167 = 68/408 → base ≈68px; ×2.6 node = ≈177px on screen.
	# hydra_spit (4f) + hydra_cloud (4f) extras deliberately NOT wired.
	"hydra": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/hydra_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/hydra_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/hydra_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/hydra_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/hydra_death.png",  "frames": 4},
		},
		"scale": 0.167, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 7.0, "attack": 12.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
		# Spit / fog belch (3f: raise → impact → burst).
		"extra_strips": {
			"smash": {"path": "res://Assets/Sprites/hydra_smash.png", "frames": 3},
		},
		"smash_open_frames": 2, "smash_fps": 10.0,
	},

	# ── CAVERNS ──────────────────────────────────────────────────────────────
	# Rock-Candy Golem — miniboss (amethyst crystal golem). cell_h 375.
	# scale 0.176 = 66/375 → base ≈66px; ×2.0 node = ≈132px on screen.
	"rockcandy": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/rockcandy_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/rockcandy_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/rockcandy_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/rockcandy_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/rockcandy_death.png",  "frames": 2},
		},
		"scale": 0.176, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 7.0, "attack": 12.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
		# Core Flare glowing ring (4f: 2 raise → impact → big burst).
		"extra_strips": {
			"smash": {"path": "res://Assets/Sprites/rockcandy_smash.png", "frames": 4},
		},
		"smash_open_frames": 2, "smash_fps": 11.0,
	},
	# Spicy Ramen Phoenix — BOSS (ramen firebird, wide cell). cell_h 392.
	# scale 0.173 = 68/392 → base ≈68px; ×2.4 node = ≈163px on screen.
	"phoenix": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/phoenix_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/phoenix_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/phoenix_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/phoenix_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/phoenix_death.png",  "frames": 2},
		},
		"scale": 0.173, "facing_sign": 1.0,
		"fps": {"idle": 5.0, "walk": 9.0, "attack": 14.0, "hit": 9.0, "death": 7.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
		# Broth-spit / rain (3f: raise → impact → burst).
		"extra_strips": {
			"smash": {"path": "res://Assets/Sprites/phoenix_smash.png", "frames": 3},
		},
		"smash_open_frames": 2, "smash_fps": 11.0,
	},

	# ── FROSTPEAK ────────────────────────────────────────────────────────────
	# Sundae Sentinel — miniboss (wafer-spear knight, TALL cell). cell_h 492.
	# scale 0.134 = 66/492 → base ≈66px; ×2.0 node = ≈132px on screen.
	"sentinel": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/sentinel_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/sentinel_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/sentinel_attack.png", "frames": 4},
			"hit":    {"path": "res://Assets/Sprites/sentinel_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/sentinel_death.png",  "frames": 4},
		},
		"scale": 0.134, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 7.0, "attack": 12.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
		# Frost Stomp (3f: raise → stomp dust → ice burst).
		"extra_strips": {
			"smash": {"path": "res://Assets/Sprites/sentinel_smash.png", "frames": 3},
		},
		"smash_open_frames": 2, "smash_fps": 10.0,
	},
	# Brain-Freeze Yeti Sundae — BOSS (soft-serve yeti; distinct from small
	# "yeti" charger). cell_h 392.
	# scale 0.173 = 68/392 → base ≈68px; ×2.7 node = ≈184px on screen.
	"yetiboss": {
		"strips": {
			"idle":   {"path": "res://Assets/Sprites/yetiboss_idle.png",   "frames": 4},
			"walk":   {"path": "res://Assets/Sprites/yetiboss_walk.png",   "frames": 4},
			"attack": {"path": "res://Assets/Sprites/yetiboss_attack.png", "frames": 3},
			"hit":    {"path": "res://Assets/Sprites/yetiboss_hit.png",    "frames": 2},
			"death":  {"path": "res://Assets/Sprites/yetiboss_death.png",  "frames": 3},
		},
		"scale": 0.173, "facing_sign": 1.0,
		"fps": {"idle": 4.0, "walk": 7.0, "attack": 13.0, "hit": 9.0, "death": 6.0},
		"loop": {"idle": true, "walk": true, "attack": false, "hit": false, "death": false},
		"attack_open_frames": 2, "ground_ref": "walk",
		# Roar buildup → frost-aura bubble (4f: 2 raise → impact → burst).
		"extra_strips": {
			"smash": {"path": "res://Assets/Sprites/yetiboss_smash.png", "frames": 4},
		},
		"smash_open_frames": 2, "smash_fps": 11.0,
	},
}

# Reference walk speed (px/s) that maps to the walk animation's base fps
# (speed_scale = motion_speed / WALK_REF_SPEED, clamped). Keeps the shuffle in
# step with actual ground travel like OnionRingRig's rolling idea.
const WALK_REF_SPEED: float = 80.0
const WALK_SPEED_SCALE_MIN: float = 0.35
const WALK_SPEED_SCALE_MAX: float = 2.2

var _cfg_id: String = "churro"
var _cfg: Dictionary = {}
var _anim: AnimatedSprite2D = null
var _state: String = "idle"
var _motion_speed: float = 0.0
var _facing_sign: float = 1.0
var _base_pos: Vector2 = Vector2.ZERO
var _built: bool = false
var _open_frames: int = 0
var _attack_total: int = 0
var _attack_phase: String = ""    # "open" | "snap" | "smash_open" | "smash_snap" | ""
# Run 122 — optional secondary "smash" strip (nacho's telegraphed AoE slam).
var _smash_total: int = 0
var _smash_open: int = 0
var _has_smash: bool = false
# Run 124 — jelly-slime leap + close-range element clips (SlimeEnemy host).
var _has_leap: bool = false
var _leap_total: int = 0
var _leap_open: int = 0
var _leap_land: int = 1   # Run 135 — trailing land frames (splash → settle)
var _has_element: bool = false
var _elem_total: int = 0
var _elem_open: int = 0
# Generic sub-clip playback (leap/element): play frames [_clip_lo .. _clip_hi]
# then hold on _clip_hi. _clip_name is the active strip while "clip" phase runs.
var _clip_name: String = ""
var _clip_lo: int = 0
var _clip_hi: int = 0


func _ready() -> void:
	_build()


# Rig-only: allow the spawner to pick the monster before _ready (see below) or
# after. Safe to call either side of _build().
func set_config(id: String) -> void:
	if not CONFIGS.has(id):
		push_warning("[MonsterRig] Unknown config '%s' — keeping '%s'." % [id, _cfg_id])
		return
	_cfg_id = id
	if _built:
		# Rebuild against the new config.
		if _anim and is_instance_valid(_anim):
			_anim.queue_free()
			_anim = null
		_built = false
		_build()


func _build() -> void:
	if _built:
		return
	_cfg = CONFIGS.get(_cfg_id, {})
	if _cfg.is_empty():
		push_warning("[MonsterRig] No config '%s'." % _cfg_id)
		return
	var strips: Dictionary = _cfg["strips"]
	# Bail gracefully if the PNGs aren't imported yet (host keeps its stick figure).
	for key in strips.keys():
		if not ResourceLoader.exists(strips[key]["path"]):
			push_warning("[MonsterRig] %s not imported yet — open the Godot editor once to import the strips." % strips[key]["path"])
			return

	var fps: Dictionary = _cfg.get("fps", {})
	var loops: Dictionary = _cfg.get("loop", {})
	var sf := SpriteFrames.new()
	sf.remove_animation("default")
	# Merge the base strips + any optional extra_strips (Run 122 — e.g. nacho's
	# "smash" secondary AoE strip) into one build loop.
	var all_strips: Dictionary = strips.duplicate()
	var extra: Dictionary = _cfg.get("extra_strips", {})
	for ek in extra.keys():
		if not ResourceLoader.exists(extra[ek]["path"]):
			push_warning("[MonsterRig] extra strip %s not imported yet." % extra[ek]["path"])
		else:
			all_strips[ek] = extra[ek]
	for key in all_strips.keys():
		var info: Dictionary = all_strips[key]
		var tex: Texture2D = load(info["path"])
		if tex == null:
			return
		var count: int = int(info["frames"])
		var fw: int = int(tex.get_width() / count)
		var fh: int = tex.get_height()
		sf.add_animation(key)
		sf.set_animation_loop(key, bool(loops.get(key, false)))
		var spd: float = float(fps.get(key, 8.0))
		if key == "smash":
			spd = float(_cfg.get("smash_fps", 11.0))
		sf.set_animation_speed(key, spd)
		for i in range(count):
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(i * fw, 0, fw, fh)
			sf.add_frame(key, at)

	_attack_total = int(strips["attack"]["frames"]) if strips.has("attack") else 0
	_open_frames = clampi(int(_cfg.get("attack_open_frames", _attack_total)), 1, max(1, _attack_total))
	# Run 122 — secondary smash strip bookkeeping (nacho). Only enabled if the
	# strip actually imported (present in the built SpriteFrames).
	_has_smash = extra.has("smash") and sf.has_animation("smash")
	if _has_smash:
		_smash_total = int(extra["smash"]["frames"])
		_smash_open = clampi(int(_cfg.get("smash_open_frames", _smash_total)), 1, max(1, _smash_total))
	# Run 124 — jelly leap/element sub-clip bookkeeping (only if the strips imported).
	_has_leap = extra.has("leap") and sf.has_animation("leap")
	if _has_leap:
		_leap_total = int(extra["leap"]["frames"])
		_leap_open = clampi(int(_cfg.get("leap_windup_frames", 1)), 1, max(1, _leap_total))
		_leap_land = clampi(int(_cfg.get("leap_land_frames", 1)), 1, max(1, _leap_total))
	_has_element = extra.has("element") and sf.has_animation("element")
	if _has_element:
		_elem_total = int(extra["element"]["frames"])
		_elem_open = clampi(int(_cfg.get("element_open_frames", 2)), 1, max(1, _elem_total))

	var scl: float = float(_cfg.get("scale", 0.2))
	_anim = AnimatedSprite2D.new()
	_anim.name = "MonsterSprite"
	_anim.sprite_frames = sf
	_anim.animation = "idle"
	_anim.centered = true
	_anim.texture_filter = Settings.HD_SPRITE_FILTER
	_anim.scale = Vector2(scl, scl)
	# Frames are bottom-anchored (feet at frame bottom). Nudge up so the monster
	# grounds near the enemy origin instead of centering the art on it.
	var ref_key: String = String(_cfg.get("ground_ref", "walk"))
	if not strips.has(ref_key):
		ref_key = strips.keys()[0]
	var ref_h: float = float(load(strips[ref_key]["path"]).get_height())
	# Run 175 — strips re-cut from their masters with SYMMETRIC transparent
	# padding (so cut-off wings/heads fit) keep their old registration: every
	# frame's content box stays centred where it was. "ground_h" pins the
	# placement to the pre-padding cell height when the ground_ref strip grew.
	if _cfg.has("ground_h"):
		ref_h = float(_cfg["ground_h"])
	_anim.position = Vector2(0, -(ref_h * scl) * 0.5 + 2.0)
	_base_pos = _anim.position
	_facing_sign = float(_cfg.get("facing_sign", 1.0))
	add_child(_anim)
	_anim.frame_changed.connect(_on_frame_changed)
	_anim.play("idle")

	# Hide the placeholder stick-figure parts that ship in the scene; the
	# AnimatedSprite2D is the body now. (The host's "Sprite" flash overlay is a
	# sibling ColorRect on the enemy, not our child — untouched.)
	for child in get_children():
		if child is CanvasItem and child != _anim:
			(child as CanvasItem).visible = false

	_built = true


# ---------------------------------------------------------------------------
# Public API (mirrors BodyAnimator so the host doesn't care which rig it got)
# ---------------------------------------------------------------------------
func set_motion_speed(speed: float) -> void:
	_motion_speed = speed
	# Tie the walk shuffle cadence to actual ground speed while walking.
	if _built and _anim and _state == "walking":
		var sc: float = clampf(speed / WALK_REF_SPEED, WALK_SPEED_SCALE_MIN, WALK_SPEED_SCALE_MAX)
		_anim.speed_scale = sc


func set_anim_state(s: String) -> void:
	if not _built or _anim == null:
		return
	_update_facing()
	if s == _state:
		return
	_state = s

	# Reset speed_scale for non-walk states.
	if s != "walking":
		_anim.speed_scale = 1.0
	# Clear the attack frame-watcher unless we're entering an attack sub-state
	# (attack windup/swing, nacho smash, OR a jelly leap/element clip).
	if not (s.begins_with("windup") or s.begins_with("swing") or s.begins_with("smash") \
			or s.begins_with("leap") or s.begins_with("element")):
		_attack_phase = ""
		_clip_name = ""

	match s:
		"idle":
			_play("idle")
		"walking":
			_play("walk")
			var sc: float = clampf(_motion_speed / WALK_REF_SPEED, WALK_SPEED_SCALE_MIN, WALK_SPEED_SCALE_MAX)
			_anim.speed_scale = sc
		"windup_y", "windup_x", "windup_a":
			# Jaws OPENING — play the opening sub-clip of the attack strip so the
			# wide-open frame lands as the host's windup ends (damage moment).
			_play_attack_open()
		"swing_y", "swing_x", "swing_a":
			# The BITE / closing snap, then hold (brief pause after each chomp).
			_play_attack_snap()
		"fire_popsicle":
			# Popsicle lob — hold the standing-spit pose as the arc launches.
			_play_attack_fire("popsicle")
		"fire_snowball":
			# Snowball — hold the mid-lunge spit pose as the fast shot launches.
			_play_attack_fire("snowball")
		"smash_windup":
			# Nacho secondary — arm-raise windup (telegraph phase), hold at the top.
			_play_smash_open()
		"smash_hit":
			# Nacho secondary — smash down + shockwave burst, hold on the last frame.
			_play_smash_snap()
		"leap_windup":
			# Jelly squashes down low (anticipation) and HOLDS until launch.
			_play_clip("leap", 0, maxi(0, _leap_open - 1))
		"leap_air":
			# Spring tall → airborne teardrop → apex; hold near the apex mid-flight.
			_play_clip("leap", _leap_open, maxi(_leap_open, _leap_total - _leap_land - 1))
		"leap_land":
			# Touchdown: splash burst → settle pancake (Run 135 — the rebuilt
			# 6-frame strips carry both land drawings), held through recovery.
			_play_clip("leap", maxi(0, _leap_total - _leap_land), _leap_total - 1)
		"element_windup":
			# Swell / inhale before the close-range burst; hold agape.
			_play_clip("element", 0, maxi(0, _elem_open - 1))
		"element_hit":
			# Elemental burst → follow-through → settle; hold the settle frame.
			_play_clip("element", _elem_open, _elem_total - 1)
		"hit_recoil":
			_play("hit")
		"death":
			_play("death")
		_:
			pass


func _process(_delta: float) -> void:
	if not _built or _anim == null:
		return
	_update_facing()


# ---------------------------------------------------------------------------
# Attack sub-clips (split the strip into OPEN then SNAP so the chomp syncs)
# ---------------------------------------------------------------------------
func _play_attack_open() -> void:
	# Play frames [0 .. _open_frames-1] once and HOLD wide-open. The frame_changed
	# watcher pins us at the last opening frame so the jaws stay agape until the
	# host's windup ends (and damage is dealt), regardless of windup duration.
	_attack_phase = "open"
	_anim.play("attack")
	_anim.frame = 0     # set AFTER play so it's the true starting frame


func _play_attack_snap() -> void:
	# Jump to the first CLOSING frame and play through to the last, then HOLD on
	# the last frame (the brief settle = "pause after each chomp"). The watcher
	# stops playback once we reach the final frame.
	_attack_phase = "snap"
	_anim.play("attack")
	_anim.frame = clampi(_open_frames, 0, max(0, _attack_total - 1))


# Snap to a single attack frame (the projectile-launch pose) and HOLD it. The
# host returns to idle/walk shortly after, which plays the recover. Used by the
# Pelican's two fire poses (popsicle lob vs snowball straight).
func _play_attack_fire(variant: String) -> void:
	var fire_map: Dictionary = _cfg.get("attack_fire_frames", {})
	var fr: int = int(fire_map.get(variant, max(0, _attack_total - 1)))
	fr = clampi(fr, 0, max(0, _attack_total - 1))
	_attack_phase = ""   # no open/snap watcher — this is a single held pose
	if _anim.sprite_frames and _anim.sprite_frames.has_animation("attack"):
		_anim.play("attack")
		_anim.frame = fr
		_anim.pause()


# Run 122 — nacho secondary smash (arm-raise windup → smash-down shockwave).
# Mirrors the attack open/snap split but drives the separate "smash" strip.
func _play_smash_open() -> void:
	if not _has_smash:
		return
	_attack_phase = "smash_open"
	_anim.play("smash")
	_anim.frame = 0


func _play_smash_snap() -> void:
	if not _has_smash:
		return
	_attack_phase = "smash_snap"
	_anim.play("smash")
	_anim.frame = clampi(_smash_open, 0, max(0, _smash_total - 1))


# Run 124 — generic sub-clip player for the jelly leap/element strips. Plays
# from frame `lo`, then the frame_changed watcher pins playback at `hi` and
# pauses (so each phase — squash / airborne / splat / breath — holds its pose
# for as long as the host stays in that state, independent of clip fps).
func _play_clip(anim: String, lo: int, hi: int) -> void:
	if _anim == null or _anim.sprite_frames == null or not _anim.sprite_frames.has_animation(anim):
		return
	var last: int = _anim.sprite_frames.get_frame_count(anim) - 1
	_clip_name = anim
	_clip_lo = clampi(lo, 0, max(0, last))
	_clip_hi = clampi(hi, _clip_lo, max(0, last))
	_attack_phase = "clip"
	_anim.play(anim)
	_anim.frame = _clip_lo
	if _clip_hi <= _clip_lo:
		_anim.pause()


# Host-driven facing (e.g. a ranged enemy aiming at the player while standing
# still, where velocity.x ~ 0 so _update_facing wouldn't flip us). Safe no-op
# until built.
func face_towards(x: float) -> void:
	if not _built or _anim == null:
		return
	if absf(x) > 0.001:
		_anim.flip_h = (x < 0.0) if _facing_sign > 0.0 else (x >= 0.0)


func _on_frame_changed() -> void:
	# Clamp attack/smash playback to the active sub-clip (open vs snap) and hold at
	# the clip's end so neither phase runs past its frames.
	if _anim == null:
		return
	if _anim.animation == "attack":
		if _attack_phase == "open":
			if _anim.frame >= _open_frames - 1:
				_anim.frame = _open_frames - 1
				_anim.pause()
		elif _attack_phase == "snap":
			if _anim.frame >= _attack_total - 1:
				_anim.frame = _attack_total - 1
				_anim.pause()
	elif _anim.animation == "smash":
		if _attack_phase == "smash_open":
			if _anim.frame >= _smash_open - 1:
				_anim.frame = _smash_open - 1
				_anim.pause()
		elif _attack_phase == "smash_snap":
			if _anim.frame >= _smash_total - 1:
				_anim.frame = _smash_total - 1
				_anim.pause()
	elif _attack_phase == "clip" and _clip_name != "" and _anim.animation == _clip_name:
		# Jelly leap/element sub-clip: hold at _clip_hi.
		if _anim.frame >= _clip_hi:
			_anim.frame = _clip_hi
			_anim.pause()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _play(anim_name: String) -> void:
	if _anim.sprite_frames and _anim.sprite_frames.has_animation(anim_name):
		_anim.play(anim_name)


func _update_facing() -> void:
	var host := get_parent()
	if host and host is CharacterBody2D:
		var vx: float = (host as CharacterBody2D).velocity.x
		if absf(vx) > 4.0:
			# Face travel direction. Source faces facing_sign; flip when opposite.
			_anim.flip_h = (vx < 0.0) if _facing_sign > 0.0 else (vx >= 0.0)
