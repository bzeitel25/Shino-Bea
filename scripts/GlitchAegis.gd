extends Node
## Glitch.fun Aegis handshake — sends a heartbeat every 60 s so the platform
## can credit playtime and trigger developer payouts ($0.10/hr active play).
##
## Entirely inert on non-web builds.  On web, reads the `install_id` query
## parameter that Glitch injects into the iframe URL, then POSTs it back to
## the Aegis API once per minute.
##
## SETUP:
##   1. Go to https://glitch.fun  →  your game  →  Integration  →  "New Token"
##   2. Paste the token string into TITLE_TOKEN below.
##   3. Add this script as an Autoload named "GlitchAegis".
##   4. Export as Web (Compatibility renderer, Thread Support OFF).

# ── CONFIG ──────────────────────────────────────────────────────────────────
const TITLE_ID     : String = "908ab2e9-3577-4d28-a298-0219d42ce07f"
const API_URL      : String = "https://api.glitch.fun/api/titles/" + TITLE_ID + "/installs"
const HEARTBEAT_SEC: float  = 60.0

## PASTE YOUR TITLE TOKEN HERE  (Integration page → "New Token")
const TITLE_TOKEN  : String = "85aec55a-3510-43f5-98b1-9c93114a1409.uWqfOxp8ccQKhCa7AzAx6eSCjeJ2LhCa"

# ── RUNTIME STATE ───────────────────────────────────────────────────────────
var _install_id : String = ""
var _http       : HTTPRequest
var _timer      : Timer

# ── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	if not OS.has_feature("web"):
		# Desktop / editor — nothing to do.
		return

	# --- grab install_id from the browser URL ---
	# Desktop App may pass: install_id, user_install_id, title_id, game_id, session_id
	# Web iframe passes: install_id
	# We check install_id first, then user_install_id as fallback (Desktop App compat).
	_install_id = JavaScriptBridge.eval("""
		(function() {
			var p = new URLSearchParams(window.location.search);
			return p.get('install_id') || p.get('user_install_id') || '';
		})()
	""", true)           # true = return as String

	if _install_id == "" or _install_id == "null":
		# Also check the parent iframe's URL (cross-origin safe)
		_install_id = JavaScriptBridge.eval("""
			(function() {
				try {
					var p = new URLSearchParams(window.parent.location.search);
					return p.get('install_id') || p.get('user_install_id') || '';
				} catch(e) { return ''; }
			})()
		""", true)

	if _install_id == "" or _install_id == "null":
		print("GlitchAegis: No install_id found — payouts disabled (local testing?).")
		return

	print("GlitchAegis: install_id = ", _install_id)

	# --- build child nodes ---
	_http = HTTPRequest.new()
	_http.name = "GlitchRequest"
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)

	_timer = Timer.new()
	_timer.name = "HeartbeatTimer"
	_timer.wait_time = HEARTBEAT_SEC
	_timer.autostart = true
	_timer.timeout.connect(_send_heartbeat)
	add_child(_timer)

	# First heartbeat immediately
	_send_heartbeat()

# ── HEARTBEAT ───────────────────────────────────────────────────────────────

func _send_heartbeat() -> void:
	if _install_id == "":
		return
	if TITLE_TOKEN == "YOUR_TITLE_TOKEN":
		print("GlitchAegis: Title token not configured — skipping heartbeat.")
		return

	var headers : PackedStringArray = PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + TITLE_TOKEN
	])
	var body := JSON.stringify({
		"user_install_id": _install_id,
		"platform": "web"
	})

	var err := _http.request(API_URL, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		print("GlitchAegis: HTTP request error: ", err)

func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	match response_code:
		200:
			print("GlitchAegis: Heartbeat OK — payout recorded.")
		403:
			print("GlitchAegis: 403 — session expired or invalid license.")
			# Optionally pause the game or show a purchase-required screen
		401:
			print("GlitchAegis: 401 — Title Token invalid or revoked.")
		422:
			print("GlitchAegis: 422 — missing user_install_id.")
		_:
			print("GlitchAegis: Unexpected response: ", response_code)
