class_name HeroBase
extends CharacterBody2D
# ============================================================
# HeroBase.gd — Batch 1 of the architecture refactor (2026-07-23)
# ============================================================
# Shared base for the two playable heroes:
#   Player.gd (Shino)  and  BeaAI.gd (Bea)
# Both extend this class BY PATH (extends "res://scripts/HeroBase.gd")
# so no global-class-cache scan is required for a correct first load.
#
# Extraction plan: shared functions/vars migrate here batch-by-batch per
# Hero_Diff_Map.md §7 (project root docs folder). Rules:
#   - A function moves here ONLY when its behavior is verified identical
#     (or made identical) in both heroes, and every var/const it touches
#     either moves with it or already lives here.
#   - Hero-specific values become vars set by the child in _init/_ready
#     (e.g. hero_id, sprite scale) — never hardcoded here.
#   - Public API names, signal names, group memberships must NOT change
#     (Wiring_Map.md contracts).
# ============================================================

# --- Hero identity (set by each child before/at _ready) -------------
# "shino" or "bea" — the key used across RunState per-hero gating
# (shino_has/bea_has, get_*_for(hero_id), etc.).
var hero_id: String = ""
