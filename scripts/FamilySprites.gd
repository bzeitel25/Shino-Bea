extends Node

# ============================================================
# FamilySprites.gd — Run 149 (2026-07-16) — static single-frame DB
# for ALL 10 guardian-family NPCs, re-sliced from the Gemini master
# sheets via grid-line detection + connected components (no more
# naive H/4 cuts: feet intact, no white bar / neighbor-feet bleed).
# Each entry is ONE idle frame per character per tier.
# Strips live in res://Assets/Sprites/Families/ as
#   <family>_<member>_idle_<rotten|unripe|ripe|restored>.png
# All 4 tiers (including Restored/Human) now covered for every family.
#
# Run 167 (2026-08-19) — two additions:
#   * the ten `*_r2` / `*_r4` members Run 149 sliced and never placed
#     in a scene: the townsfolk who now stand around BOTH Seedy City
#     squares (see TownFolk.gd / TownBuild.gd).
#   * the DRAGON FRUIT family — the carnival troupe (Family_Roster
#     §4.11), all four tiers, idle + 6-frame walk. Nova reads the
#     crystal ball, Pitaya barks the show, Jangles clowns, and Tally
#     (the hooded boy) runs the town shop stand between biomes.
# ============================================================

const DIR := "res://Assets/Sprites/Families/"

# member -> desired on-screen height (px) of the RIPE idle frame;
# the same scale is reused for every tier so tier sag/growth reads.
const TARGET_H := {
	# Apple
	"idunn": 64, "cormac": 64, "blossom": 48, "pip": 46,
	# Coconut
	"gnarls": 64, "pina": 62, "kai": 48, "shelly": 46,
	# Banana
	"splitz": 64, "nanette": 36,
	# Broccoli
	"broclee": 64, "roman": 60, "remy": 46,
	# Carrot
	"fletch": 64, "scout": 46,
	# Grape
	"vitti": 64, "welchie": 52, "mani": 46,
	# Watermelon
	"july": 64, "wally": 52, "bobby": 46,
	# Pepper
	"flambeau": 64, "rika": 52, "nino": 46,
	# Potato
	"russel": 64, "tot": 48, "wedge": 46,
	# Onion
	"alliam": 64, "lottie": 48, "pearl": 46,
	# ── Run 167: the never-placed townsfolk (sliced in Run 149) ──
	"banana_r2": 60,     # strutting showman banana
	"banana_r4": 48,     # kid medic with the red-cross satchel
	"broccoli_r4": 62,   # weightlifter mid-press
	"carrot_r2": 62,     # cloaked archer
	"carrot_r4": 50,     # spotter with the spyglass
	"grape_r4": 52,      # armoured squad grape
	"onion_r4": 54,      # basket vendor
	"pepper_r4": 56,     # apron + frying pan cook
	"potato_r4": 52,     # pickaxe miner
	"melon_r4": 54,      # produce-tray vendor
	# ── Run 167: Dragon Fruit carnival troupe ──
	"nova": 62, "pitaya": 66, "jangles": 58, "tally": 52,
}

# member -> family id used by RunState.FAM_COLOR / FamilyLore.
const MEMBER_FAMILY := {
	"idunn": "apple", "cormac": "apple", "blossom": "apple", "pip": "apple",
	"gnarls": "coconut", "pina": "coconut", "kai": "coconut", "shelly": "coconut",
	"splitz": "banana", "nanette": "banana",
	"broclee": "broccoli", "roman": "broccoli", "remy": "broccoli",
	"fletch": "carrot", "scout": "carrot",
	"vitti": "grape", "welchie": "grape", "mani": "grape",
	"july": "watermelon", "wally": "watermelon", "bobby": "watermelon",
	"flambeau": "pepper", "rika": "pepper", "nino": "pepper",
	"russel": "potato", "tot": "potato", "wedge": "potato",
	"alliam": "onion", "lottie": "onion", "pearl": "onion",
	# Run 167 — townsfolk
	"banana_r2": "banana", "banana_r4": "banana",
	"broccoli_r4": "broccoli",
	"carrot_r2": "carrot", "carrot_r4": "carrot",
	"grape_r4": "grape", "onion_r4": "onion", "pepper_r4": "pepper",
	"potato_r4": "potato", "melon_r4": "watermelon",
	# Run 167 — Dragon Fruit carnival troupe
	"nova": "dragonfruit", "pitaya": "dragonfruit",
	"jangles": "dragonfruit", "tally": "dragonfruit",
}

# strip name -> [frames, cell_w, cell_h, content_h]
# Run 147: all entries are single-frame static idle sprites.
const DB := {
	# ── Apple ──
	"apple_idunn_idle_rotten": [1, 292, 355, 355],
	"apple_idunn_idle_unripe": [1, 276, 369, 369],
	"apple_idunn_idle_ripe": [1, 270, 365, 365],
	"apple_idunn_idle_restored": [1, 248, 353, 353],
	"apple_cormac_idle_rotten": [1, 282, 368, 368],
	"apple_cormac_idle_unripe": [1, 281, 369, 369],
	"apple_cormac_idle_ripe": [1, 287, 368, 368],
	"apple_cormac_idle_restored": [1, 287, 344, 344],
	"apple_blossom_idle_rotten": [1, 161, 325, 325],
	"apple_blossom_idle_unripe": [1, 162, 325, 325],
	"apple_blossom_idle_ripe": [1, 161, 327, 327],
	"apple_blossom_idle_restored": [1, 182, 302, 302],
	"apple_pip_idle_rotten": [1, 137, 303, 303],
	"apple_pip_idle_unripe": [1, 137, 303, 303],
	"apple_pip_idle_ripe": [1, 137, 307, 307],
	"apple_pip_idle_restored": [1, 145, 272, 272],
	# ── Coconut ──
	"coconut_gnarls_idle_rotten": [1, 301, 362, 362],
	"coconut_gnarls_idle_unripe": [1, 302, 363, 363],
	"coconut_gnarls_idle_ripe": [1, 301, 378, 378],
	"coconut_gnarls_idle_restored": [1, 301, 367, 367],
	"coconut_pina_idle_rotten": [1, 241, 382, 382],
	"coconut_pina_idle_unripe": [1, 248, 382, 382],
	"coconut_pina_idle_ripe": [1, 285, 384, 384],
	"coconut_pina_idle_restored": [1, 263, 387, 387],
	"coconut_kai_idle_rotten": [1, 204, 317, 317],
	"coconut_kai_idle_unripe": [1, 176, 317, 317],
	"coconut_kai_idle_ripe": [1, 223, 317, 317],
	"coconut_kai_idle_restored": [1, 223, 312, 312],
	"coconut_shelly_idle_rotten": [1, 160, 296, 296],
	"coconut_shelly_idle_unripe": [1, 161, 296, 296],
	"coconut_shelly_idle_ripe": [1, 160, 296, 296],
	"coconut_shelly_idle_restored": [1, 184, 291, 291],
	# ── Banana ──
	"banana_splitz_idle_rotten": [1, 236, 388, 388],
	"banana_splitz_idle_unripe": [1, 240, 374, 374],
	"banana_splitz_idle_ripe": [1, 254, 379, 379],
	"banana_splitz_idle_restored": [1, 170, 384, 384],
	"banana_nanette_idle_rotten": [1, 166, 325, 325],
	"banana_nanette_idle_unripe": [1, 173, 325, 325],
	"banana_nanette_idle_ripe": [1, 263, 325, 325],
	"banana_nanette_idle_restored": [1, 237, 299, 299],
	# ── Broccoli ──
	"broccoli_broclee_idle_rotten": [1, 320, 370, 370],
	"broccoli_broclee_idle_unripe": [1, 320, 370, 370],
	"broccoli_broclee_idle_ripe": [1, 319, 369, 369],
	"broccoli_broclee_idle_restored": [1, 317, 369, 369],
	"broccoli_roman_idle_rotten": [1, 321, 387, 387],
	"broccoli_roman_idle_unripe": [1, 320, 380, 380],
	"broccoli_roman_idle_ripe": [1, 320, 375, 375],
	"broccoli_roman_idle_restored": [1, 319, 374, 374],
	"broccoli_remy_idle_rotten": [1, 285, 329, 329],
	"broccoli_remy_idle_unripe": [1, 286, 329, 329],
	"broccoli_remy_idle_ripe": [1, 319, 329, 329],
	"broccoli_remy_idle_restored": [1, 318, 328, 328],
	# ── Carrot ──
	"carrot_fletch_idle_rotten": [1, 222, 380, 380],
	"carrot_fletch_idle_unripe": [1, 219, 365, 365],
	"carrot_fletch_idle_ripe": [1, 268, 380, 380],
	"carrot_fletch_idle_restored": [1, 268, 364, 364],
	"carrot_scout_idle_rotten": [1, 176, 303, 303],
	"carrot_scout_idle_unripe": [1, 207, 310, 310],
	"carrot_scout_idle_ripe": [1, 206, 310, 310],
	"carrot_scout_idle_restored": [1, 214, 299, 299],
	# ── Grape ──
	"grape_vitti_idle_rotten": [1, 291, 370, 370],
	"grape_vitti_idle_unripe": [1, 291, 369, 369],
	"grape_vitti_idle_ripe": [1, 290, 363, 363],
	"grape_vitti_idle_restored": [1, 250, 467, 467],
	"grape_welchie_idle_rotten": [1, 290, 383, 383],
	"grape_welchie_idle_unripe": [1, 291, 384, 384],
	"grape_welchie_idle_ripe": [1, 235, 381, 381],
	"grape_welchie_idle_restored": [1, 239, 536, 536],
	"grape_mani_idle_rotten": [1, 166, 323, 323],
	"grape_mani_idle_unripe": [1, 210, 323, 323],
	"grape_mani_idle_ripe": [1, 276, 323, 323],
	"grape_mani_idle_restored": [1, 209, 357, 357],
	# ── Watermelon ──
	"watermelon_july_idle_rotten": [1, 242, 369, 369],
	"watermelon_july_idle_unripe": [1, 240, 368, 368],
	"watermelon_july_idle_ripe": [1, 261, 358, 358],
	"watermelon_july_idle_restored": [1, 250, 353, 353],
	"watermelon_wally_idle_rotten": [1, 240, 372, 372],
	"watermelon_wally_idle_unripe": [1, 252, 371, 371],
	"watermelon_wally_idle_ripe": [1, 270, 370, 370],
	"watermelon_wally_idle_restored": [1, 248, 370, 370],
	"watermelon_bobby_idle_rotten": [1, 186, 324, 324],
	"watermelon_bobby_idle_unripe": [1, 185, 324, 324],
	"watermelon_bobby_idle_ripe": [1, 256, 329, 329],
	"watermelon_bobby_idle_restored": [1, 215, 309, 309],
	# ── Pepper ──
	"pepper_flambeau_idle_rotten": [1, 256, 374, 374],
	"pepper_flambeau_idle_unripe": [1, 256, 374, 374],
	"pepper_flambeau_idle_ripe": [1, 165, 374, 374],
	"pepper_flambeau_idle_restored": [1, 187, 344, 344],
	"pepper_rika_idle_rotten": [1, 248, 383, 383],
	"pepper_rika_idle_unripe": [1, 248, 381, 381],
	"pepper_rika_idle_ripe": [1, 253, 382, 382],
	"pepper_rika_idle_restored": [1, 251, 364, 364],
	"pepper_nino_idle_rotten": [1, 249, 324, 324],
	"pepper_nino_idle_unripe": [1, 248, 323, 323],
	"pepper_nino_idle_ripe": [1, 126, 323, 323],
	"pepper_nino_idle_restored": [1, 131, 296, 296],
	# ── Potato ──
	"potato_russel_idle_rotten": [1, 214, 349, 349],
	"potato_russel_idle_unripe": [1, 254, 349, 349],
	"potato_russel_idle_ripe": [1, 271, 354, 354],
	"potato_russel_idle_restored": [1, 269, 354, 354],
	"potato_tot_idle_rotten": [1, 186, 356, 356],
	"potato_tot_idle_unripe": [1, 186, 354, 354],
	"potato_tot_idle_ripe": [1, 196, 380, 380],
	"potato_tot_idle_restored": [1, 200, 347, 347],
	"potato_wedge_idle_rotten": [1, 212, 312, 312],
	"potato_wedge_idle_unripe": [1, 230, 310, 310],
	"potato_wedge_idle_ripe": [1, 209, 324, 324],
	"potato_wedge_idle_restored": [1, 194, 293, 293],
	# ── Onion ──
	"onion_alliam_idle_rotten": [1, 215, 361, 361],
	"onion_alliam_idle_unripe": [1, 216, 361, 361],
	"onion_alliam_idle_ripe": [1, 215, 365, 365],
	"onion_alliam_idle_restored": [1, 214, 336, 336],
	"onion_lottie_idle_rotten": [1, 219, 365, 365],
	"onion_lottie_idle_unripe": [1, 218, 366, 366],
	"onion_lottie_idle_ripe": [1, 218, 368, 368],
	"onion_lottie_idle_restored": [1, 218, 334, 334],
	"onion_pearl_idle_rotten": [1, 230, 336, 336],
	"onion_pearl_idle_unripe": [1, 176, 335, 335],
	"onion_pearl_idle_ripe": [1, 174, 334, 334],
	"onion_pearl_idle_restored": [1, 165, 309, 309],
	# ── Run 167: townsfolk (sliced Run 149, first placed Run 167) ──
	"banana_banana_r2_idle_rotten": [1, 233, 385, 385],
	"banana_banana_r2_idle_unripe": [1, 232, 384, 384],
	"banana_banana_r2_idle_ripe": [1, 216, 398, 398],
	"banana_banana_r2_idle_restored": [1, 184, 394, 394],
	"banana_banana_r4_idle_rotten": [1, 160, 301, 301],
	"banana_banana_r4_idle_unripe": [1, 159, 301, 301],
	"banana_banana_r4_idle_ripe": [1, 239, 300, 300],
	"banana_banana_r4_idle_restored": [1, 233, 286, 286],
	"broccoli_broccoli_r4_idle_rotten": [1, 274, 302, 302],
	"broccoli_broccoli_r4_idle_unripe": [1, 273, 301, 301],
	"broccoli_broccoli_r4_idle_ripe": [1, 320, 310, 310],
	"broccoli_broccoli_r4_idle_restored": [1, 319, 308, 308],
	"carrot_carrot_r2_idle_rotten": [1, 280, 392, 392],
	"carrot_carrot_r2_idle_unripe": [1, 280, 370, 370],
	"carrot_carrot_r2_idle_ripe": [1, 279, 391, 391],
	"carrot_carrot_r2_idle_restored": [1, 265, 369, 369],
	"carrot_carrot_r4_idle_rotten": [1, 177, 298, 298],
	"carrot_carrot_r4_idle_unripe": [1, 209, 303, 303],
	"carrot_carrot_r4_idle_ripe": [1, 208, 302, 302],
	"carrot_carrot_r4_idle_restored": [1, 213, 291, 291],
	"grape_grape_r4_idle_rotten": [1, 208, 311, 311],
	"grape_grape_r4_idle_unripe": [1, 209, 311, 311],
	"grape_grape_r4_idle_ripe": [1, 208, 310, 310],
	"grape_grape_r4_idle_restored": [1, 180, 326, 326],
	"onion_onion_r4_idle_rotten": [1, 137, 296, 296],
	"onion_onion_r4_idle_unripe": [1, 157, 296, 296],
	"onion_onion_r4_idle_ripe": [1, 166, 295, 295],
	"onion_onion_r4_idle_restored": [1, 143, 264, 264],
	"pepper_pepper_r4_idle_rotten": [1, 252, 315, 315],
	"pepper_pepper_r4_idle_unripe": [1, 246, 315, 315],
	"pepper_pepper_r4_idle_ripe": [1, 260, 316, 316],
	"pepper_pepper_r4_idle_restored": [1, 262, 285, 285],
	"potato_potato_r4_idle_rotten": [1, 133, 280, 280],
	"potato_potato_r4_idle_unripe": [1, 143, 280, 280],
	"potato_potato_r4_idle_ripe": [1, 194, 276, 276],
	"potato_potato_r4_idle_restored": [1, 178, 269, 269],
	"watermelon_melon_r4_idle_rotten": [1, 177, 300, 300],
	"watermelon_melon_r4_idle_unripe": [1, 176, 298, 298],
	"watermelon_melon_r4_idle_ripe": [1, 137, 302, 302],
	"watermelon_melon_r4_idle_restored": [1, 143, 284, 284],
	# ── Run 167: Dragon Fruit carnival troupe (idle + 6-frame walk) ──
"dragonfruit_nova_idle_rotten": [1, 170, 373, 373],
	"dragonfruit_nova_walk_rotten": [6, 165, 377, 377],
	"dragonfruit_pitaya_idle_rotten": [1, 329, 414, 414],
	"dragonfruit_pitaya_walk_rotten": [6, 170, 416, 416],
	"dragonfruit_jangles_idle_rotten": [1, 212, 342, 342],
	"dragonfruit_jangles_walk_rotten": [6, 139, 343, 343],
	"dragonfruit_tally_idle_rotten": [1, 144, 323, 323],
	"dragonfruit_tally_walk_rotten": [6, 142, 325, 325],
	"dragonfruit_nova_idle_unripe": [1, 169, 372, 372],
	"dragonfruit_nova_walk_unripe": [6, 165, 376, 376],
	"dragonfruit_pitaya_idle_unripe": [1, 273, 414, 414],
	"dragonfruit_pitaya_walk_unripe": [6, 169, 416, 416],
	"dragonfruit_jangles_idle_unripe": [1, 211, 342, 342],
	"dragonfruit_jangles_walk_unripe": [6, 139, 351, 351],
	"dragonfruit_tally_idle_unripe": [1, 144, 323, 323],
	"dragonfruit_tally_walk_unripe": [6, 142, 325, 325],
	"dragonfruit_nova_idle_ripe": [1, 168, 372, 372],
	"dragonfruit_nova_walk_ripe": [6, 164, 376, 376],
	"dragonfruit_pitaya_idle_ripe": [1, 273, 390, 390],
	"dragonfruit_pitaya_walk_ripe": [6, 170, 402, 402],
	"dragonfruit_jangles_idle_ripe": [1, 223, 352, 352],
	"dragonfruit_jangles_walk_ripe": [6, 151, 351, 351],
	"dragonfruit_tally_idle_ripe": [1, 142, 323, 323],
	"dragonfruit_tally_walk_ripe": [6, 142, 318, 318],
	"dragonfruit_nova_idle_restored": [1, 179, 371, 371],
	"dragonfruit_nova_walk_restored": [6, 173, 367, 367],
	"dragonfruit_pitaya_idle_restored": [1, 313, 390, 390],
	"dragonfruit_pitaya_walk_restored": [6, 250, 397, 397],
	"dragonfruit_jangles_idle_restored": [1, 255, 342, 342],
	"dragonfruit_jangles_walk_restored": [6, 179, 342, 342],
	"dragonfruit_tally_idle_restored": [1, 166, 303, 303],
	"dragonfruit_tally_walk_restored": [6, 154, 301, 301],
}


static func strip_name(member: String, anim: String, tier: int) -> String:
	var tiers := ["rotten", "unripe", "ripe", "restored"]
	var fam: String = (MEMBER_FAMILY as Dictionary).get(member, "")
	if fam == "":
		return ""
	return "%s_%s_%s_%s" % [fam, member, anim, tiers[clampi(tier, 0, 3)]]


static func has_strip(member: String, anim: String, tier: int) -> bool:
	return (DB as Dictionary).has(strip_name(member, anim, tier))
