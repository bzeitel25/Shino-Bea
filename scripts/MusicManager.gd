extends Node
# MusicManager.gd — autoload. Per-area background music with a shuffled
# "bag" so tracks within an area play in a fresh random order and never
# repeat back-to-back. The AudioStreamPlayer lives on this autoload, so music
# keeps playing seamlessly across room/scene loads within the same area.
#
# Usage:
#   MusicManager.play_biome("beach")   # from DreamRoom._ready()
#   MusicManager.stop()                 # when leaving to a music-less area
#   MusicManager.play_area("menu")      # generic, by folder key (future areas)
#
# Drop more .mp3/.ogg files into the matching folder and they get picked up
# automatically next time that area loads — no code changes needed.

const MUSIC_ROOT: String = "res://Assets/Music/"

# Area key -> folder under Assets/Music/. Biome keys match RunState.current_biome.
const AREA_FOLDERS: Dictionary = {
	# Biomes (keys are RunState.current_biome ids)
	"beach":    "Biomes/Beach_SunSpoil",
	"jungle":   "Biomes/Jungle_Rotwood",
	"swamp":    "Biomes/Swamp_PickleMire",
	"caverns":  "Biomes/Caverns_Emberglass",
	"peaks":    "Biomes/Frostpeak",
	"cake":     "CakeDragon_Climb",
	# Non-biome areas (wired later as tracks land)
	"menu":     "Menu",
	"dojo":     "Dojo",
	"town":     "TownSquare",
	"gauntlet": "Gauntlet_TownDefense",
	"sensei":   "SenseiZ_FinalFight",
}

const FADE_TIME: float = 0.8     # seconds, cross/out fade

var _player: AudioStreamPlayer
var _current_key: String = ""    # which area is currently loaded
var _bag: Array = []             # shuffled queue of track paths, drained as we play
var _all_tracks: Array = []      # every track path for the current area (refills the bag)
var _last_path: String = ""      # last track played (avoid immediate repeat on refill)
var _fade_tween: Tween = null


func _ready() -> void:
	# Keep running while the tree is paused so we can decide, per the player's
	# setting, whether music should pause with the game.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	_player.name = "MusicPlayer"
	# Route through the "Music" bus (created by Settings) so the music-volume
	# slider controls it. Fall back to Master if the bus isn't up yet.
	_player.bus = "Music" if AudioServer.get_bus_index("Music") != -1 else "Master"
	_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_player)
	_player.finished.connect(_on_track_finished)


func _process(_delta: float) -> void:
	# Honor the "pause music with game" setting live. When off, music plays
	# straight through the pause menu; when on, it freezes/resumes with the game.
	if _player == null:
		return
	var want_pause: bool = get_tree().paused and _pause_music_setting()
	if _player.stream_paused != want_pause:
		_player.stream_paused = want_pause


func _pause_music_setting() -> bool:
	var s: Node = get_node_or_null("/root/Settings")
	if s != null and "pause_music_with_game" in s:
		return bool(s.pause_music_with_game)
	return false


# ── Public API ───────────────────────────────────────────────────────────────

func play_biome(biome_id: String) -> void:
	play_area(biome_id)


func play_area(key: String) -> void:
	var folder: String = String(AREA_FOLDERS.get(key, ""))
	if folder == "":
		stop()
		return
	# Already playing this area? Let it keep going (seamless across room loads).
	if key == _current_key and _player.playing:
		return
	_current_key = key
	_all_tracks = _scan_audio(MUSIC_ROOT.path_join(folder))
	_bag.clear()
	_last_path = ""
	if _all_tracks.is_empty():
		stop()
		return
	_refill_bag()
	_kill_fade()
	_player.volume_db = 0.0
	_advance()


func stop() -> void:
	_current_key = ""
	if _player == null:
		return
	if not _player.playing:
		return
	# Quick fade-out then stop.
	_kill_fade()
	_fade_tween = create_tween()
	_fade_tween.tween_property(_player, "volume_db", -40.0, FADE_TIME)
	_fade_tween.tween_callback(_player.stop)
	_fade_tween.tween_callback(func() -> void: _player.volume_db = 0.0)


# ── Internals ────────────────────────────────────────────────────────────────

func _on_track_finished() -> void:
	# A track ended naturally → roll the next one from the bag.
	_advance()


func _advance() -> void:
	if _all_tracks.is_empty():
		return
	if _bag.is_empty():
		_refill_bag()
	var path: String = String(_bag.pop_front())
	_last_path = path
	var stream: AudioStream = load(path)
	if stream == null:
		return
	# We sequence tracks ourselves, so each stream must NOT loop internally —
	# otherwise `finished` never fires and the area never rotates.
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = false
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = false
	_player.stream = stream
	_player.volume_db = 0.0
	_player.play()


func _refill_bag() -> void:
	_bag = _all_tracks.duplicate()
	_bag.shuffle()
	# Avoid the same track playing twice across a bag boundary.
	if _bag.size() > 1 and String(_bag[0]) == _last_path:
		_bag.append(_bag.pop_front())


func _scan_audio(dir_path: String) -> Array:
	# Returns sorted, de-duplicated audio paths. Handles editor (raw .mp3) and
	# exported (.mp3.import remap) layouts by stripping any trailing .import.
	var found: Dictionary = {}
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		push_warning("[MusicManager] No folder: " + dir_path)
		return []
	d.list_dir_begin()
	var f: String = d.get_next()
	while f != "":
		if not d.current_is_dir():
			var nm: String = f
			if nm.to_lower().ends_with(".import"):
				nm = nm.substr(0, nm.length() - 7)
			var low: String = nm.to_lower()
			if low.ends_with(".mp3") or low.ends_with(".ogg") or low.ends_with(".wav"):
				found[dir_path.path_join(nm)] = true
		f = d.get_next()
	d.list_dir_end()
	var out: Array = found.keys()
	out.sort()
	return out


func _kill_fade() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null
