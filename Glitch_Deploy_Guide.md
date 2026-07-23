# Glitch.fun Deployment Guide — Shino & Bea

## Before You Export (One-Time Setup)

1. **Generate a Title Token** on glitch.fun:
   - Go to your game's **Integration** tab
   - Scroll to **Step 1: Generate Your Title Token**
   - Click **"+ New Token"** — copy the token immediately (it won't show again)
   - Open `scripts/GlitchAegis.gd` and paste it into the `TITLE_TOKEN` constant

2. Your **Title ID** is already wired: `908ab2e9-3577-4d28-a298-0219d42ce07f`
3. Your **Developer Test Install ID** (for local testing): `ab1b6960-7537-4aeb-b9dc-8cdbd5e253c9`

---

## Godot Export Settings

1. **Renderer**: Must be **Compatibility** (top-right of editor — already set in this project).

2. **Project → Export → Add… → Web**:
   - **Export Path**: Create a new folder (e.g. `webexport/`), name the file `index.html`
   - **Thread Support**: **Off** (Single-threaded) — required for Glitch iframe compatibility
   - **VRAM Texture Compression**: Enable **For Desktop** and **For Mobile**
   - **Focus Canvas On Start**: **Disabled**
   - **Progressive Web App**: **Enabled**
   - **Ensure Cross Origin Isolation Headers**: **Enabled**

3. Click **"Export Project…"** (not Export PCK/ZIP)

---

## Packaging the ZIP

After export, your folder should contain:
- `index.html`
- `index.js`
- `index.wasm`
- `index.pck`
- (plus icons, manifest, service worker, etc.)

### Critical rules:
- **ZIP the files, NOT the folder** — `index.html` must be at the ZIP root, no sub-folder
- **All lowercase filenames** — Glitch CDN is Linux-based (`Index.html` ≠ `index.html`)
- **Relative paths only** — use `./assets/img.png`, not `/assets/img.png`

### Windows:
Select all files in the export folder → right-click → "Compress to ZIP file"

### Command line:
```bash
cd webexport
# Windows PowerShell:
Compress-Archive -Path * -DestinationPath ..\shino-and-bea-deploy.zip
```

---

## Uploading

1. Go to your game's **Deploy Game** tab on glitch.fun
2. Click **"I have my Godot ZIP, let's upload!"**
3. Upload the ZIP
4. If asked for deployment type, select **wasm** (not iframe) — Godot exports are WASM builds
5. Wait for deployment — the status table at the bottom will update

---

## How the Handshake Works

1. Glitch loads your game in an iframe with `?install_id=<UUID>` in the URL
2. `GlitchAegis.gd` reads that `install_id` via `JavaScriptBridge`
3. Every 60 seconds, it POSTs to the Glitch API with the install_id + your Title Token
4. Glitch credits you **$0.10/hour** of active playtime

If the player is idle (no input detected by the Glitch wrapper), the heartbeat is flagged as `is_idle` and no payout is generated.

---

## Testing Locally

To test the handshake without deploying:
- Open your exported `index.html` via a local web server (not file://)
- Append `?install_id=ab1b6960-7537-4aeb-b9dc-8cdbd5e253c9` to the URL
- Check the browser console for `GlitchAegis:` log messages

---

## Notes

- The `GlitchAegis` autoload is **completely inert** on desktop/editor builds
- If no `install_id` is found (local play), it prints a notice and does nothing
- If the token hasn't been configured yet, it skips heartbeats with a warning
- The MCP debug autoloads (MCPScreenshot, MCPInputService, MCPGameInspector) will be harmless in the web build but you may want to remove them for a production deploy to reduce file size
