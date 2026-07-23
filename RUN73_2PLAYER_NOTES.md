# Run 73 — Local 2-Player Co-op

## What this adds
Pressing **START** on the title now goes to a new **PlayerSetup** screen *before* the
save-file select:

1. **Mode phase** — pick `1 PLAYER` or `2 PLAYERS`.
   - 1P → unchanged classic hot-swap build → SaveFileSelect.
   - 2P → controller-assignment phase.
2. **Assign phase** — Shino is framed on the left, Bea on the right, with two
   little drawn controller icons (P1 top, P2 bottom) in the center. Each player
   slides their own icon left/right onto the ninja they want. The game can only
   start once **each ninja has exactly one controller** (icons on different
   ninjas). Then any player presses **A / Enter** to begin.

In 2P, **both ninjas are human-controlled at once**, each reading only its own
device. The classic AI partner / auto-defend logic is fully bypassed.

## Controls / devices
- Device convention: `-1` = keyboard, `>=0` = joypad id.
- Auto-assignment of the two player slots (in `InputRouter.resolve_player_devices`):
  - **2+ pads** → P1 = pad 0, P2 = pad 1
  - **1 pad** → P1 = keyboard, P2 = pad 0
  - **0 pads** → both keyboard (degenerate — they share WASD; use controllers for real 2P)
- On the assign screen: P1 moves with its stick/d-pad **or A/D**, P2 with its
  stick/d-pad **or the ← / → arrow keys** (so it's testable on a keyboard).

## Character swap in 2P
Q is still the swap, but co-op requires **both players to press swap within the
window** (`SWAP_DBL_TAP_WINDOW`, 1.2s). The first press raises the "🙋 TAG IN?"
prompt on that player's ninja; when the partner also presses, the two players
**trade characters** (the device→ninja assignment is exchanged — both stay
human-controlled). 1P keeps the old double-tap-Q behavior.

## Camera
`CameraFollow.gd` now frames **both** ninjas in 2P: it centers on their midpoint
and eases the zoom so both stay on-screen with a margin. It never zooms in
tighter than the scene's authored zoom and never further out than a floor
(`TWOP_MIN_ZOOM = 0.55`), so a ninja should never leave the screen. 1P camera is
unchanged.

## Files touched
- **NEW** `scripts/InputRouter.gd` (+ autoload in `project.godot`) — per-device
  input state (pressed/just_pressed/just_released + move/aim vectors).
- **NEW** `scripts/PlayerSetup.gd` + `scenes/PlayerSetup.tscn` — the mode +
  assignment screen.
- `scripts/RunState.gd` — `two_player`, `shino_device`, `bea_device`,
  `setup_two_player()`, `swap_two_player_devices()`. (Intentionally NOT reset in
  `reset_run()` since that also fires mid-run; `MainMenu` clears it at the title.)
- `scripts/MainMenu.gd` — START → PlayerSetup; force single-player at the title.
- `scripts/CameraFollow.gd` — 2P zoom-to-fit.
- `scripts/Player.gd` / `scripts/BeaAI.gd` — per-device input wrappers
  (`_act_p/_act_jp/_act_jr/_move_axis/_aim_vec`), 2P control init, and the 2P
  swap handler. In 1P every wrapper falls through to the global `Input`
  singleton, so single-player behavior is byte-identical.

## Not yet done / future polish
- Portraits on the assign screen are the existing in-game sprites
  (`shino_walk_s` frame 0, `bea_static`); swap in nicer portrait art when ready.
- The controller icons are drawn placeholders — feed real art anytime.
- HUD shows both ninjas' bars as before; both ult-ready indicators can light at
  once in 2P (correct, since both are active players).
- Keyboard-only 2P shares one keyboard (no true input separation) — expected.

## Needs a real playtest
This was static-reviewed only (no Godot in the sandbox). Worth checking on a
build: device auto-assignment with your actual pads, the both-press swap window
feel, and the camera framing as the two of you spread across a room.
