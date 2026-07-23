extends RefCounted

# ============================================================
# DreamBiomes.gd — Run 43 (2026-06-10) — Dream World static data
# ============================================================
# Single source of truth for the five star-arm biomes + the Cake
# finale climb. Consumed by DreamRoom.gd / DreamSpawner.gd /
# DreamHub.gd via:  const DB = preload("res://scripts/DreamBiomes.gd")
#
# Enemy entries are CONFIG PRESETS applied to the three proven AI
# archetype scenes (placeholders until art lands):
#   "melee"  → DummyEnemy.tscn   (chase + windup swing)
#   "ranged" → RangedShooter.tscn (kite + projectile)
#   "scout"  → FastScout.tscn    (fast, fragile, in-your-face)
# Fields: name, arch, hp, dmg, speed, scale, tint.
# "dmg" maps to attack_damage (melee/scout) or shot_damage (ranged).
#
# Run 45 layout: 8 rooms — 3 enemy waves, MINI-BOSS (room 4), 3 more
# waves, BIOME BOSS (room 8). Juice auto-drops after rooms 3 and 6
# (just before each big fight). The boss drops the biome's single
# Dragon Soul; the mini-boss drops none.
# Rooms narrow toward the star tip: ROOM_WIDTHS/HEIGHTS lerp from
# wide (room 1) to tight (room 8) along the biome's compass dir.
# ============================================================

# Room footprint interpolation (half-extents of the playable floor).
# Run 87: rooms START BIG (1200x880 full) and stay roomy for the first few
# rooms, then shrink toward the star tip — but the tip room (boss) is still a
# proper arena, not a closet. The shrink is EASED (see room_half_extents) so
# early rooms barely change and the squeeze ramps up near the tip.
const ROOM_HALF_W_START: float = 600.0
const ROOM_HALF_W_END:   float = 340.0
const ROOM_HALF_H_START: float = 440.0
const ROOM_HALF_H_END:   float = 270.0
# Easing exponent: >1 keeps rooms near the START size longer, then shrinks
# faster toward the tip ("start big, plenty of room to decrease").
const ROOM_SHRINK_EASE:  float = 1.5
const ROOMS_PER_BIOME:   int   = 8
const MINIBOSS_ROOM:     int   = 4          # mid-biome gate fight (no spark)
const JUICE_ROOMS:       Array = [3, 6]     # juice auto-drops after these rooms
const CAKE_ROOMS:        int   = 5

# Difficulty scaling: +18% enemy HP and +10% enemy damage per biome
# already cleansed (Tier I..V on the hub gates). Cake climb uses tier 5.
const TIER_HP_SCALE:  float = 0.18
const TIER_DMG_SCALE: float = 0.10

const BIOMES: Dictionary = {
	"beach": {
		"display":   "Sun-Spoil Beach",
		"direction": "SE",
		"exit_dir":  Vector2(1, 1),     # rooms advance toward the SE star tip
		"floor":     Color(0.78, 0.68, 0.42),   # sun-bleached sand
		"floor_alt": Color(0.84, 0.74, 0.48),
		"wall":      Color(0.55, 0.45, 0.28),
		"accent":    Color(0.30, 0.70, 0.90),   # tide blue
		"tree":      "palm",
		"river_chance": 0.35,
		"traps": [
			{"type": "root", "visual": "sandpit", "name": "Sand Pit"},
			{"type": "slow", "visual": "brine",   "name": "Brine Pool"},
		],
		"enemies": [
			# Run 120 — Boardwalk Churro Chomper REPLACES the old plain-melee "Corn
			# Dog Crab" (its hand-authored sprite is now THE beach biter). Bites
			# apply a short Burn (sizzling-hot churro) via on_hit_burn; the melee
			# host reads that after each chomp lands.
			{"name": "Boardwalk Churro Chomper", "arch": "melee",  "hp": 65,  "dmg": 8,  "speed": 85.0,  "scale": 1.0,  "tint": Color(1.00, 0.66, 0.30), "sprite_rig": "churro", "on_hit_burn": {"stacks": 1, "duration": 3.0}},
			# Run 122 — Funnel-Cake Fortress (beefy-slow tank) REPLACES the old plain
			# melee "Taffy Slug". Its slam stuns briefly (on_hit_stun).
			{"name": "Funnel-Cake Fortress", "arch": "melee",  "hp": 185, "dmg": 13, "speed": 48.0,  "scale": 1.0,  "tint": Color(0.90, 0.72, 0.40), "sprite_rig": "funnel", "on_hit_stun": {"duration": 0.6}},
			# Run 121 — Popsicle Pelican REPLACES the old plain-ranged "Fried-Clam
			# Sniper" as THE beach ranged/lobber (its hand-authored sprite + two-shot
			# kit: fast snowball, or a lobbed popsicle that plops a frost icy patch).
			{"name": "Popsicle Pelican",  "arch": "pelican", "hp": 40,  "dmg": 10, "speed": 90.0,  "scale": 1.0,  "tint": Color(0.30, 0.62, 0.95), "sprite_rig": "pelican"},
			# Run 122 — Cotton-Candy Wisp (fragile-fast, evasive scout) REPLACES the
			# old plain scout "Soda-Pop Skipper".
			{"name": "Cotton-Candy Wisp", "arch": "scout",  "hp": 30,  "dmg": 5,  "speed": 158.0, "scale": 1.0,  "tint": Color(0.95, 0.70, 0.90), "sprite_rig": "wisp"},
			{"name": "Sea-Salt Jelly",    "arch": "slime",  "sprite_rig": "seasalt", "hp": 80, "dmg": 9,  "speed": 55.0, "scale": 0.80, "tint": Color(0.30, 0.62, 0.95)},
			{"name": "Soda-Static Jelly", "arch": "slime",  "sprite_rig": "sodastatic", "hp": 70, "dmg": 10, "speed": 70.0, "scale": 0.72, "tint": Color(1.00, 0.88, 0.25)},
			# Run 126 — legacy procedural "Boardwalk Beamer" (laser, no sprite rig) REMOVED.
			# Run 119 — Onion-Ring Rollick is now THE beach charger (its hand-authored
			# rig REPLACES the old placeholder "Funnel-Cake Bull" charger).
			{"name": "Onion-Ring Rollick","arch": "charger","hp": 200, "dmg": 16, "speed": 50.0,  "scale": 1.0,  "tint": Color(1.00, 0.66, 0.16), "sprite_rig": "onion"},
		],
		"miniboss": {"name": "Corn Dog Colossus", "arch": "melee", "hp": 420, "dmg": 14, "speed": 70.0, "scale": 1.9, "tint": Color(0.95, 0.50, 0.15), "sprite_rig": "colossus", "secondary": "smash"},
		"boss":     {"name": "Corn Dog Kraken",   "arch": "melee", "hp": 950, "dmg": 18, "speed": 80.0, "scale": 2.6, "tint": Color(0.80, 0.35, 0.10), "sprite_rig": "kraken", "secondary": "smash",
					 "adds": [{"name": "Cotton-Candy Wisp", "arch": "scout", "hp": 30, "dmg": 5, "speed": 158.0, "scale": 1.0, "tint": Color(0.95, 0.70, 0.90), "sprite_rig": "wisp"}]},
	},
	"jungle": {
		"display":   "Rotwood Jungle",
		"direction": "NE",
		"exit_dir":  Vector2(1, -1),
		"floor":     Color(0.18, 0.32, 0.16),   # deep overgrowth
		"floor_alt": Color(0.22, 0.38, 0.19),
		"wall":      Color(0.25, 0.20, 0.12),
		"accent":    Color(0.55, 0.80, 0.30),
		"tree":      "canopy",
		"river_chance": 0.55,
		"traps": [
			{"type": "root", "visual": "vines", "name": "Entangling Vines"},
		],
		"enemies": [
			# Run 122 — Trail-Blaze Squirrel (scout) REPLACES "Banana Peel Slipper".
			{"name": "Trail-Blaze Squirrel", "arch": "scout",  "hp": 32,  "dmg": 6,  "speed": 156.0, "scale": 1.0,  "tint": Color(0.85, 0.55, 0.30), "sprite_rig": "squirrel"},
			# Run 122 — Marshmallow Mauler (tank/melee, knockback) REPLACES "Gummy Worm Brute".
			{"name": "Marshmallow Mauler",   "arch": "melee",  "hp": 175, "dmg": 13, "speed": 50.0,  "scale": 1.0,  "tint": Color(0.98, 0.94, 0.90), "sprite_rig": "mallow", "on_hit_knockback": true},
			# Run 122 — Choco-Frog Flinger (ranged, sticky slow) REPLACES "Trail-Mix Scatterer".
			{"name": "Choco-Frog Flinger",   "arch": "ranged", "hp": 46,  "dmg": 9,  "speed": 92.0,  "scale": 1.0,  "tint": Color(0.45, 0.28, 0.15), "sprite_rig": "chocofrog", "on_hit_slow": {"stacks": 1}, "projectile_sprite": "res://Assets/Sprites/chocofrog_dart.png"},
			# Run 126 — legacy procedural "Choco-Vine Creeper" (melee, no sprite rig) REMOVED.
			# Run 123 — Sour-Gummy Serpent is now a SCOUT (fast runner/attacker), no longer a slime.
			{"name": "Sour-Gummy Serpent",   "arch": "scout",  "hp": 60, "dmg": 10, "speed": 135.0, "scale": 1.0, "tint": Color(0.55, 0.85, 0.35), "sprite_rig": "gummy", "on_hit_poison": {"stacks": 1, "duration": 4.0}},
			# Run 123 — Matcha Jelly restored as the jungle jelly slime (plant element).
			{"name": "Matcha Jelly",         "arch": "slime",  "sprite_rig": "matcha", "hp": 95, "dmg": 10, "speed": 52.0, "scale": 0.84, "tint": Color(0.40, 0.78, 0.35)},
			# Run 122 — Licorice Lasher (laser, stun) ADDED (jungle had no laser).
			{"name": "Licorice Lasher",      "arch": "laser",  "hp": 50,  "dmg": 14, "speed": 60.0,  "scale": 1.0,  "tint": Color(0.20, 0.14, 0.24), "sprite_rig": "licorice", "on_hit_stun": {"duration": 0.6}},
			# Run 126 — legacy procedural "Pop-Rocks Sprinter" (boom scout) + "Coconut Charger" (charger), no sprite rigs, REMOVED.
		],
		"miniboss": {"name": "Gummy Gorilla",       "arch": "melee", "hp": 460,  "dmg": 15, "speed": 75.0, "scale": 1.9, "tint": Color(0.90, 0.25, 0.45), "sprite_rig": "gorilla", "secondary": "smash"},
		"boss":     {"name": "Banana-Split Simian", "arch": "melee", "hp": 1050, "dmg": 19, "speed": 92.0, "scale": 2.5, "tint": Color(0.95, 0.80, 0.30), "sprite_rig": "simian", "secondary": "smash",
					 "adds": [{"name": "Trail-Blaze Squirrel", "arch": "scout", "hp": 32, "dmg": 6, "speed": 156.0, "scale": 1.0, "tint": Color(0.85, 0.55, 0.30), "sprite_rig": "squirrel"}]},
	},
	"swamp": {
		"display":   "Pickle Mire",
		"direction": "SW",
		"exit_dir":  Vector2(-1, 1),
		"floor":     Color(0.25, 0.32, 0.18),   # brackish muck
		"floor_alt": Color(0.30, 0.38, 0.20),
		"wall":      Color(0.20, 0.24, 0.14),
		"accent":    Color(0.65, 0.80, 0.35),
		"tree":      "gnarl",
		"river_chance": 0.60,
		"traps": [
			{"type": "poison", "visual": "poison", "name": "Poison Pool"},
		],
		"enemies": [
			# Run 122 — Rancid-Relish Runt (melee, poison) REPLACES "Pickle Gator".
			{"name": "Rancid-Relish Runt",   "arch": "melee",  "hp": 88,  "dmg": 11, "speed": 82.0,  "scale": 1.0,  "tint": Color(0.55, 0.72, 0.30), "sprite_rig": "relish", "on_hit_poison": {"stacks": 1, "duration": 4.0}},
			# Run 122 — Kombucha Kraken-let (ranged, poison) REPLACES "Funk-Mustard Bubbler".
			{"name": "Kombucha Kraken-let",  "arch": "ranged", "hp": 44,  "dmg": 10, "speed": 84.0,  "scale": 1.0,  "tint": Color(0.70, 0.55, 0.30), "sprite_rig": "kombucha", "on_hit_poison": {"stacks": 1, "duration": 4.0}},
			{"name": "Sour-Venom Jelly",     "arch": "slime",  "sprite_rig": "sourvenom", "hp": 140, "dmg": 10, "speed": 40.0, "scale": 0.92, "tint": Color(0.62, 0.30, 0.75)},
			# Run 122 — Sauerkraut Skulker (scout, poison) REPLACES "Brine Fly".
			{"name": "Sauerkraut Skulker",   "arch": "scout",  "hp": 30,  "dmg": 6,  "speed": 154.0, "scale": 1.0,  "tint": Color(0.80, 0.78, 0.55), "sprite_rig": "kraut", "on_hit_poison": {"stacks": 1, "duration": 3.0}},
			# Run 122 — Expired-Egg Bloater (charger, poison + knockback) ADDED (swamp had no charger).
			{"name": "Expired-Egg Bloater",  "arch": "charger","hp": 200, "dmg": 15, "speed": 52.0,  "scale": 1.0,  "tint": Color(0.85, 0.82, 0.55), "sprite_rig": "eggbomb", "on_hit_poison": {"stacks": 2, "duration": 4.0}, "death_explosion": {"radius": 80.0, "delay": 1.5, "dmg_mult": 1.25, "status": "poison", "status_duration": 3.0, "status_stacks": 2}},
			# Run 126 — legacy procedural "Bog-Light Zapper" (laser, no sprite rig) REMOVED.
		],
		"miniboss": {"name": "Mustard Marauder", "arch": "ranged", "hp": 380,  "dmg": 14, "speed": 95.0, "scale": 1.8, "tint": Color(0.90, 0.75, 0.10), "sprite_rig": "mustard"},
		"boss":     {"name": "Pickled Hydra",    "arch": "melee",  "hp": 1000, "dmg": 18, "speed": 70.0, "scale": 2.6, "tint": Color(0.35, 0.60, 0.20), "sprite_rig": "hydra", "secondary": "smash",
					 "adds": [{"name": "Sauerkraut Skulker", "arch": "scout", "hp": 30, "dmg": 6, "speed": 154.0, "scale": 1.0, "tint": Color(0.80, 0.78, 0.55), "sprite_rig": "kraut", "on_hit_poison": {"stacks": 1, "duration": 3.0}}]},
	},
	"caverns": {
		"display":   "Emberglass Caverns",
		"direction": "NW",
		"exit_dir":  Vector2(-1, -1),
		"floor":     Color(0.28, 0.16, 0.20),   # volcanic rock + crystal sheen
		"floor_alt": Color(0.34, 0.18, 0.26),
		"wall":      Color(0.18, 0.10, 0.14),
		"accent":    Color(0.75, 0.40, 0.95),   # amethyst crystal
		"tree":      "crystal",
		"river_chance": 0.30,                   # lava flow
		"traps": [
			{"type": "burn", "visual": "magma", "name": "Magma Fissure"},
		],
		"enemies": [
			# Run 122 — Nacho-Slag Golem (tank/melee, burn + periodic smash AoE)
			# REPLACES "Magma Marshmallow".
			{"name": "Nacho-Slag Golem",     "arch": "melee",  "hp": 210, "dmg": 14, "speed": 46.0,  "scale": 1.0,  "tint": Color(0.95, 0.72, 0.30), "sprite_rig": "nacho", "on_hit_burn": {"stacks": 1, "duration": 3.0}, "secondary": "smash"},
			# Run 126 — legacy procedural "Rock-Candy Crystaline" (melee, no sprite rig) REMOVED.
			# Run 122 — Cinder-Chili Skitter "Chili Critter" (scout, burn) REPLACES "Spicy-Chip Bat".
			{"name": "Chili Critter",        "arch": "scout",  "hp": 30,  "dmg": 6,  "speed": 158.0, "scale": 1.0,  "tint": Color(0.90, 0.30, 0.15), "sprite_rig": "chili", "on_hit_burn": {"stacks": 1, "duration": 3.0}},
			# Run 122 — Popcorn Popper (ranged, TWO burn jets) REPLACES "Lava-Pop Lobber".
			{"name": "Popcorn Popper",       "arch": "popcorn","hp": 44,  "dmg": 11, "speed": 88.0,  "scale": 1.0,  "tint": Color(1.00, 0.85, 0.45), "sprite_rig": "popcorn", "on_hit_burn": {"stacks": 1, "duration": 3.0}},
			# Run 123 — Fry-Oil Fiend is now a SCOUT (fast runner/attacker), no longer a slime.
			{"name": "Fry-Oil Fiend",        "arch": "scout",  "hp": 58,  "dmg": 11, "speed": 140.0, "scale": 1.0, "tint": Color(0.95, 0.70, 0.25), "sprite_rig": "fryoil", "on_hit_burn": {"stacks": 1, "duration": 3.0}},
			# Run 123 — Hot-Sauce Jelly restored as a caverns jelly slime (fire element).
			{"name": "Hot-Sauce Jelly",      "arch": "slime",  "sprite_rig": "hotsauce", "hp": 85, "dmg": 11, "speed": 58.0, "scale": 0.80, "tint": Color(1.00, 0.45, 0.15), "on_hit_burn": {"stacks": 1, "duration": 3.0}},
			{"name": "Caramel-Crag Jelly",   "arch": "slime",  "sprite_rig": "caramel", "hp": 120, "dmg": 10, "speed": 45.0, "scale": 0.88, "tint": Color(0.62, 0.45, 0.25)},
			# Run 122 — Jawbreaker Juggernaut (charger, stun + burn) ADDED (caverns had no charger).
			{"name": "Jawbreaker Juggernaut","arch": "charger","hp": 210, "dmg": 16, "speed": 50.0,  "scale": 1.0,  "tint": Color(0.85, 0.55, 0.75), "sprite_rig": "jawbreaker", "on_hit_stun": {"duration": 0.55}, "on_hit_burn": {"stacks": 1, "duration": 3.0}},
			# Run 126 — legacy procedural "Ember-Beam Geode" (laser) + "Firecracker Bug" (boom scout), no sprite rigs, REMOVED.
		],
		"miniboss": {"name": "Rock-Candy Golem",    "arch": "melee", "hp": 520,  "dmg": 16, "speed": 60.0, "scale": 2.0, "tint": Color(0.60, 0.35, 0.85), "sprite_rig": "rockcandy", "secondary": "smash"},
		"boss":     {"name": "Spicy Ramen Phoenix", "arch": "melee", "hp": 1100, "dmg": 20, "speed": 100.0, "scale": 2.4, "tint": Color(0.95, 0.35, 0.10), "sprite_rig": "phoenix", "secondary": "smash",
					 "adds": [{"name": "Chili Critter", "arch": "scout", "hp": 30, "dmg": 6, "speed": 158.0, "scale": 1.0, "tint": Color(0.90, 0.30, 0.15), "sprite_rig": "chili", "on_hit_burn": {"stacks": 1, "duration": 3.0}}]},
	},
	"peaks": {
		"display":   "Frostpeak",
		"direction": "N",
		"exit_dir":  Vector2(0, -1),
		"floor":     Color(0.78, 0.84, 0.92),   # snowpack
		"floor_alt": Color(0.84, 0.90, 0.97),
		"wall":      Color(0.45, 0.55, 0.70),
		"accent":    Color(0.40, 0.70, 0.95),   # glacial blue
		"tree":      "pine",
		"river_chance": 0.35,                   # glacial stream (frozen → walkable ice)
		# No point traps: the frozen ice flooring (rivers/lakes/puddles) is
		# Frostpeak's "large" hazard — walkable but slippery (see IceField.gd).
		"traps": [],
		"enemies": [
			# Run 122 — Snow-Cone Sniper (ranged, slow) REPLACES "Slushie Flinger".
			{"name": "Snow-Cone Sniper",         "arch": "ranged", "hp": 44,  "dmg": 10, "speed": 88.0,  "scale": 1.0,  "tint": Color(0.55, 0.80, 0.95), "sprite_rig": "snowcone", "on_hit_slow": {"stacks": 1}},
			# Run 122 — Peppermint Prowler (melee, slow) REPLACES "Frost-Bite Cone".
			{"name": "Peppermint Prowler",       "arch": "melee",  "hp": 80,  "dmg": 11, "speed": 88.0,  "scale": 1.0,  "tint": Color(0.90, 0.40, 0.45), "sprite_rig": "prowler", "on_hit_slow": {"stacks": 1}},
			# Run 122 — Whipped-Cream Wraith (scout, slow) REPLACES "Frosting Penguin".
			{"name": "Whipped-Cream Wraith",     "arch": "scout",  "hp": 30,  "dmg": 6,  "speed": 156.0, "scale": 1.0,  "tint": Color(0.96, 0.96, 0.98), "sprite_rig": "wraith", "on_hit_slow": {"stacks": 1}},
			# Run 122 — Gelato Golem (tank/melee, slow) REPLACES "Ice-Cream Sandwich Guard".
			{"name": "Gelato Golem",             "arch": "melee",  "hp": 195, "dmg": 13, "speed": 46.0,  "scale": 1.0,  "tint": Color(0.75, 0.85, 0.95), "sprite_rig": "gelato", "on_hit_slow": {"stacks": 1}},
			{"name": "Snow-Cone Jelly",          "arch": "slime",  "sprite_rig": "snowjelly", "hp": 90, "dmg": 10, "speed": 55.0, "scale": 0.80, "tint": Color(0.70, 0.90, 1.00)},
			# Run 122 — Frozen-Yogurt Yeti (charger, knockback + slow) REPLACES "Avalanche Yak".
			{"name": "Frozen-Yogurt Yeti",       "arch": "charger","hp": 215, "dmg": 17, "speed": 50.0,  "scale": 1.0,  "tint": Color(0.90, 0.90, 0.98), "sprite_rig": "yeti", "on_hit_slow": {"stacks": 1}},
		],
		"miniboss": {"name": "Sundae Sentinel",         "arch": "melee", "hp": 540,  "dmg": 16, "speed": 65.0, "scale": 2.0, "tint": Color(0.90, 0.85, 0.95), "sprite_rig": "sentinel", "secondary": "smash"},
		"boss":     {"name": "Brain-Freeze Yeti Sundae","arch": "melee", "hp": 1200, "dmg": 21, "speed": 75.0, "scale": 2.7, "tint": Color(0.80, 0.90, 1.00), "sprite_rig": "yetiboss", "secondary": "smash",
					 "adds": [{"name": "Whipped-Cream Wraith", "arch": "scout", "hp": 30, "dmg": 6, "speed": 156.0, "scale": 1.0, "tint": Color(0.96, 0.96, 0.98), "sprite_rig": "wraith", "on_hit_slow": {"stacks": 1}}]},
	},
	# ── Finale climb — Devil's Food Dragon-Cake fortress ─────────────────────
	# Run 126: climb pulls from ALL five biome rosters only (rigged sprites).
	# The cake-unique roster below is DORMANT (still procedural, no rigs yet);
	# random_enemy() skips it. Re-enable per-entry once each gets a sprite_rig.
	"cake": {
		"display":   "Dragon Cake Fortress",
		"direction": "UP",
		"exit_dir":  Vector2(0, -1),    # always climbing — exits face NORTH
		"floor":     Color(0.55, 0.35, 0.30),   # devil's food sponge
		"floor_alt": Color(0.62, 0.40, 0.34),
		"wall":      Color(0.85, 0.65, 0.70),   # frosting piping
		"accent":    Color(0.95, 0.55, 0.65),
		"tree":      "candy",
		"river_chance": 0.30,                   # chocolate river
		"traps": [
			{"type": "slow", "visual": "glaze", "name": "Frosting Glaze"},
		],
		"enemies": [
			{"name": "Fondant Golem",    "arch": "melee",  "hp": 160, "dmg": 14, "speed": 55.0,  "scale": 1.35, "tint": Color(0.95, 0.85, 0.90)},
			{"name": "Sprinkle Swarmer", "arch": "scout",  "hp": 30,  "dmg": 7,  "speed": 165.0, "scale": 0.85, "tint": Color(0.95, 0.50, 0.80)},
			{"name": "Candle Snuffer",   "arch": "ranged", "hp": 48,  "dmg": 12, "speed": 95.0,  "scale": 1.0,  "tint": Color(0.95, 0.75, 0.35)},
			{"name": "Devil's Crumb",    "arch": "melee",  "hp": 90,  "dmg": 12, "speed": 95.0,  "scale": 1.0,  "tint": Color(0.40, 0.22, 0.20)},
			{"name": "Cherry-Bomb Cherub","arch": "scout",  "behavior": "boom", "hp": 26, "dmg": 7, "speed": 160.0, "scale": 0.85, "tint": Color(0.90, 0.20, 0.30)},
			{"name": "Candlelight Lancer","arch": "laser",  "hp": 52,  "dmg": 15, "speed": 68.0,  "scale": 1.0,  "tint": Color(0.95, 0.80, 0.40)},
		],
		"miniboss": {},   # no mid-climb mini-boss — the climb itself escalates
		"boss":     {},   # summit = Shadow Sensei Z (own arena/script)
	},
}

const BIOME_ORDER: Array = ["beach", "jungle", "swamp", "caverns", "peaks"]

# Hub gate placement (plaza is ~1420x800; gates at the end of the dirt paths).
const HUB_GATE_POS: Dictionary = {
	"peaks":   Vector2(0, -390),      # N  — flush with north wall
	"jungle":  Vector2(580, -200),    # NE — at end of dirt path
	"beach":   Vector2(580, 280),     # SE — at end of dirt path (nudged south)
	"swamp":   Vector2(-580, 280),    # SW — at end of dirt path (nudged south)
	"caverns": Vector2(-580, -200),   # NW — at end of dirt path
}

const ARCH_SCENES: Dictionary = {
	"melee":   "res://scenes/DummyEnemy.tscn",
	"ranged":  "res://scenes/RangedShooter.tscn",
	"scout":   "res://scenes/FastScout.tscn",
	# Run 57 — new attack archetypes.
	"slime":   "res://scenes/SlimeEnemy.tscn",    # squish + leap, landing AoE
	"laser":   "res://scenes/LaserEnemy.tscn",    # 2s ground line → instant zap
	"charger": "res://scenes/ChargerEnemy.tscn",  # aim, lock lane, rush
	# Run 121 — Popsicle Pelican: beach ranged bird with two shots (fast snowball
	# + lobbed popsicle that leaves a frost-slowing icy patch).
	"pelican": "res://scenes/PelicanShooter.tscn",
	# Run 122 — Popcorn Popper: caverns ranged with two burn jets (short/big).
	"popcorn": "res://scenes/PopcornPopper.tscn",
}


static func get_biome(id: String) -> Dictionary:
	return BIOMES.get(id, {})


# Playable half-extents for a given room index (1-indexed), narrowing
# linearly toward the star tip. Cake climb narrows over CAKE_ROOMS.
static func room_half_extents(room: int, biome_id: String) -> Vector2:
	var total: int = CAKE_ROOMS if biome_id == "cake" else ROOMS_PER_BIOME
	var t: float = clamp(float(room - 1) / float(max(1, total - 1)), 0.0, 1.0)
	t = pow(t, ROOM_SHRINK_EASE)   # stay big early, shrink harder toward the tip
	return Vector2(
		lerp(ROOM_HALF_W_START, ROOM_HALF_W_END, t),
		lerp(ROOM_HALF_H_START, ROOM_HALF_H_END, t)
	)


# Wave size for a room (1-indexed): ramps 4 → 8 across the biome.
static func wave_size(room: int) -> int:
	return 4 + int(floor(float(room - 1) * 0.5))


# Difficulty multipliers from biomes already cleansed (tier 0..5).
static func tier_hp_mult(tier: int) -> float:
	return 1.0 + TIER_HP_SCALE * float(tier)

static func tier_dmg_mult(tier: int) -> float:
	return 1.0 + TIER_DMG_SCALE * float(tier)


# Random enemy config for a biome. For "cake", pulls from ALL five biome
# rosters (any rigged monster can spawn on the climb). Run 126: the
# cake-unique roster is dormant until those enemies get sprite rigs —
# no procedurally-drawn enemies in the finale.
static func random_enemy(biome_id: String) -> Dictionary:
	if biome_id == "cake":
		var src: String = BIOME_ORDER[randi() % BIOME_ORDER.size()]
		var roster: Array = BIOMES[src]["enemies"]
		return (roster[randi() % roster.size()] as Dictionary).duplicate()
	var b: Dictionary = get_biome(biome_id)
	if b.is_empty():
		return {}
	var own: Array = b["enemies"]
	return (own[randi() % own.size()] as Dictionary).duplicate()
