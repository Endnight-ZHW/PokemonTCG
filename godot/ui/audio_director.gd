class_name AudioDirector
extends Node

signal cue_played(request: AudioCueRequest, definition: AudioCueDefinition, variant: int)

const SFX_VOICES := 16
const UI_VOICES := 4
const CATALOG_PATH := "res://assets/audio/library.tres"
var catalog: AudioCatalog
var cues: Dictionary = {}
var sfx: AudioVoicePool
var ui: AudioVoicePool
var music: GameMusicDirector
var ui_player: AudioStreamPlayer
var sfx_player: AudioStreamPlayer
var music_player: AudioStreamPlayer:
	get:
		return music.players[music.active] if music != null and not music.players.is_empty() else null
var _initialized := false
var _suspended := false
var _seen: Dictionary = {}
var _missing: Dictionary = {}
var _pending_ui := ""
var _ui_scheduled := false


func _ready() -> void:
	_initialize_runtime()
	if get_parent() is Control:
		var binder := AudioUIBinder.new()
		add_child(binder)
		binder.configure(get_parent() as Control, self)
	var settings := get_tree().root.get_node_or_null("AppSettings")
	if settings != null and not settings.changed.is_connected(apply_settings):
		settings.changed.connect(apply_settings)


func _initialize_runtime() -> void:
	if _initialized:
		return
	_initialized = true
	GameAudioMixer.ensure_buses()
	catalog = load(CATALOG_PATH) as AudioCatalog
	if catalog != null:
		cues = catalog.cue_map()
	sfx = AudioVoicePool.new()
	add_child(sfx)
	sfx.configure("SFX", SFX_VOICES)
	ui = AudioVoicePool.new()
	add_child(ui)
	ui.configure("UI", UI_VOICES)
	sfx.started.connect(cue_played.emit)
	ui.started.connect(cue_played.emit)
	sfx_player = sfx.players[0]
	ui_player = ui.players[0]
	music = GameMusicDirector.new()
	add_child(music)
	music.configure(catalog.track_map() if catalog != null else {})
	apply_settings()


func play(request: AudioCueRequest) -> bool:
	_initialize_runtime()
	if request == null or _suspended or not is_inside_tree():
		return false
	var identity := request.identity()
	if not identity.is_empty() and _seen.has(identity):
		return false
	var id := request.resolved_cue()
	var definition := cues.get(id) as AudioCueDefinition
	if definition == null:
		if not _missing.has(id):
			_missing[id] = true
			push_warning("Missing audio cue: " + str(id))
		return false
	# Mark even suppressed events as consumed, so retries cannot sound later.
	if not identity.is_empty():
		_seen[identity] = request.scope_id
		if _seen.size() > 512:
			_seen.erase(_seen.keys()[0])
	return (ui if definition.bus == "UI" else sfx).play(request, definition)


func play_ui(cue: String = "click") -> void:
	# Coalesce generic click signals and the semantic control signal in one frame.
	var weights := {"click": 0, "select": 1, "toggle": 1, "modal_open": 1, "modal_close": 1, "back": 2, "confirm": 2, "success": 3, "connect": 3, "disconnect": 6, "error": 5}
	if _pending_ui.is_empty() or int(weights.get(cue, 2)) >= int(weights.get(_pending_ui, 2)):
		_pending_ui = cue
	if not _ui_scheduled:
		_ui_scheduled = true
		call_deferred("_flush_ui")


func _flush_ui() -> void:
	_ui_scheduled = false
	var cue := _pending_ui
	_pending_ui = ""
	if not cue.is_empty():
		play(AudioCueRequest.make(StringName(cue), &"ui"))


func play_cue(cue: String) -> void:
	play(AudioCueRequest.make(StringName(cue)))


func play_home(cue: String) -> void:
	play(AudioCueRequest.make(StringName(cue), &"home"))


func cancel_scope(scope_id: StringName) -> void:
	if not _initialized:
		return
	sfx.cancel_scope(scope_id)
	ui.cancel_scope(scope_id)
	for key in _seen.keys():
		if _seen[key] == scope_id:
			_seen.erase(key)


func stop_sfx() -> void:
	if sfx != null:
		sfx.cancel_scope(&"")
	_seen.clear()


func stop_all_short_sounds() -> void:
	_pending_ui = ""
	stop_sfx()
	if ui != null:
		ui.cancel_scope(&"")


func play_music(track: String) -> void:
	_initialize_runtime()
	if not is_inside_tree():
		return
	if track == "battle":
		music.begin_match()
	else:
		if track in ["title", "preparation", ""]:
			music.leave_match()
		music.play(StringName(track))


func update_battle_music(setup_complete: bool, terminal: bool, prize_counts: Array[int]) -> void:
	_initialize_runtime()
	music.update_battle(setup_complete, terminal, prize_counts)


func play_result(result: String) -> void:
	_initialize_runtime()
	if music.result_played:
		return
	music.result_played = true
	music.leave_match()
	cancel_scope(&"battle")
	music.play(&"victory" if result == "victory" else &"reflection")
	play(AudioCueRequest.make(StringName(result), &"result", "result", "arrival"))


func apply_settings() -> void:
	_initialize_runtime()
	var tree := Engine.get_main_loop() as SceneTree
	GameAudioMixer.apply_settings(tree.root.get_node_or_null("AppSettings") if tree != null else null)


func _process(delta: float) -> void:
	if music != null and not _suspended:
		music.update_duck(minf(sfx.duck_db(), ui.duck_db()), delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_suspended = true
		stop_all_short_sounds()
		if music != null:
			music.set_suspended(true)
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_suspended = false
		if music != null:
			music.set_suspended(false)


func _exit_tree() -> void:
	stop_all_short_sounds()
	if music != null:
		music.play(&"")
