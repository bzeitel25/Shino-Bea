# Shino & Bea — Godot Prototype

Early playable prototype for the Shino & Bea project.
Built autonomously by Claude while Bruno travels — see `../Godot_Build_Log.md` for the build roadmap and session log.

## Running the prototype

1. **Install Godot 4.x** (4.2 or later recommended) — https://godotengine.org/download
2. Open Godot, click **Import**, and select this folder's `project.godot` file.
3. Click **Play** (▶) to run the prototype.

## Current state (Phase 1 — Scaffold)

What works right now:
- Top-down arena with boundary walls
- Shino (placeholder orange rectangle) moves with WASD or left stick
- Diagonal movement is normalized (no diagonal speed boost)
- Camera smoothly follows the player
- Collision with arena walls

What's coming next (per `../Godot_Build_Log.md` Phase 2):
- Y / X / A attack inputs with combo state machine
- 4-hit punch combo (Jab → Cross → Hook → Spinning Uppercut)
- 3-hit kick combo (Sweep → Sweep → Push)
- Ki Blast ranged attack
- Cross-button combo cancel (Y cancels X and vice versa)
- Placeholder dummy enemy with HP + hit reaction

## Controls (current + planned)

| Key | Action |
|---|---|
| WASD or Left Stick | Move |
| J or Y button | Y attack (punch combo) — Phase 2 |
| K or X button | X attack (kick combo) — Phase 2 |
| L or A button | A attack (ki blast) — Phase 2 |
| Space or B button | Dash — Phase 3 |

## Folder structure

```
ShinoAndBea_Godot/
├── project.godot          # Godot 4.x project config + input bindings + physics layers
├── icon.svg               # Placeholder icon
├── scenes/
│   ├── World.tscn         # Main test arena (entry scene)
│   └── Player.tscn        # Shino character — CharacterBody2D + placeholder sprite
├── scripts/
│   ├── World.gd           # World controller (Phase 1: just logs controls)
│   ├── Player.gd          # Movement + facing + state machine stubs
│   └── CameraFollow.gd    # Smooth follow camera
├── assets/
│   ├── sprites/           # (empty — placeholder rectangles for now)
│   ├── audio/             # (empty)
│   └── ui/                # (empty)
└── README.md              # This file
```

## Art style note

Currently using **colored rectangles** as placeholders.
Target visual style is SNES/GBA pixel art (think Stardew Valley / CrossCode).
Will be swapped in once art assets are ready — see `../Townsfolk_Directory.md` and `../Shino_and_Bea_GDD.md` §11 Art Direction for spec.

## Physics layer setup (for reference when extending)

| Layer | Use |
|---|---|
| 1 | World (walls, terrain) |
| 2 | Player body |
| 3 | Enemy body |
| 4 | Player hitbox (offensive — what damages enemies) |
| 5 | Enemy hitbox (offensive — what damages player) |

Hurtboxes are Area2D on layer 0 (no own layer) with mask matching the relevant offensive layer.
