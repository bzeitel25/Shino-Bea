# art_clean — Run 175 cleanup tools

Paths resolve relative to this folder (`<project>/ShinoAndBea_Godot/tools/art_clean/`).
Originals are read from `<project>/_backup_pre_run175_art/` when present.

* `clean2.py`  — `pick_hue(img)` / `defringe(img, hue)`: removes a key-colour halo ring outside
  the dark outline; `shadow_fix(img, hue)`: key-tinted baked drop shadow -> neutral translucent.
* `holes.py`   — enclosed key-colour holes (house art) using the bg colour left in transparent px.
* `reslice.py` — `key_master()`: border-flood + key-dominance key, edge despill, Gemini ✦ removal.
* `reslice2.py MASTER.png strip_a.png strip_b.png ...` — re-cut ALL strips of one monster from its
  master: exact template match per frame, nearest-pose ownership (no neighbour leaks), symmetric
  padding so registration is unchanged. Writes `rs_<strip>.png` next to the cwd for review.
  If the ground_ref (walk) strip grows, add `"ground_h": <old height>` to its MonsterRig config.
* `fixbands.py '{"Tilesets/..png":{"c":[[x0,x1]],"r":[[y0,y1]]}}'` — inpaint sheet grid lines.

Always review a contact sheet before copying results over the game art.
