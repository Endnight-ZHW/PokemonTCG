class_name AudioDirector
extends Node

var ui_player: AudioStreamPlayer
var sfx_player: AudioStreamPlayer
var music_player: AudioStreamPlayer
var _cues: Dictionary = {}
var _music_streams: Dictionary = {}
var _current_music := ""
var _initialized := false


func _ready() -> void:
	_initialize_runtime()


func _exit_tree() -> void:
	for player in [ui_player, sfx_player, music_player]:
		if player:
			player.stop()
			player.stream = null
	_cues.clear()
	_music_streams.clear()


func _initialize_runtime() -> void:
	if _initialized:
		return
	_initialized = true
	_ensure_buses()
	ui_player = _player("UI")
	sfx_player = _player("SFX")
	music_player = _player("Music")
	music_player.finished.connect(_on_music_finished)
	_build_cues()
	_build_music()
	apply_settings()


func play_ui(cue: String = "click") -> void:
	_initialize_runtime()
	_play(ui_player, _cues.get(cue))


func play_cue(cue: String) -> void:
	_initialize_runtime()
	_play(sfx_player, _cues.get(cue))


func play_music(track: String) -> void:
	_initialize_runtime()
	if not is_inside_tree() or music_player == null or not music_player.is_inside_tree():
		_current_music = track
		return
	if _current_music == track and music_player.playing:
		return
	_current_music = track
	var stream: AudioStreamWAV = _music_streams.get(track)
	if stream == null:
		music_player.stop()
		return
	music_player.stream = stream
	music_player.play()


func stop_music() -> void:
	_initialize_runtime()
	_current_music = ""
	if music_player and music_player.is_inside_tree():
		music_player.stop()


func apply_settings() -> void:
	_initialize_runtime()
	_set_bus_volume("Master", AppSettings.master_volume, AppSettings.muted)
	_set_bus_volume("Music", AppSettings.music_volume, AppSettings.muted)
	_set_bus_volume("SFX", AppSettings.sfx_volume, AppSettings.muted)
	_set_bus_volume("UI", AppSettings.sfx_volume, AppSettings.muted)


func _ensure_buses() -> void:
	for bus_name in ["Music", "SFX", "UI"]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			var index := AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, bus_name)
			AudioServer.set_bus_send(index, "Master")


func _player(bus_name: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.bus = bus_name
	add_child(player)
	return player


func _build_cues() -> void:
	_cues = {
		"click": _tone([760.0, 1040.0], 0.06, 0.12),
		"success": _tone([660.0, 880.0, 1160.0], 0.18, 0.14),
		"card_draw": _sweep(360.0, 960.0, 0.12, 0.12),
		"card_place": _tone([190.0, 260.0], 0.12, 0.16),
		"card_move": _sweep(520.0, 760.0, 0.14, 0.09),
		"card_discard": _sweep(780.0, 220.0, 0.18, 0.13),
		"energy_attach": _tone([580.0, 920.0, 1280.0], 0.2, 0.14),
		"evolution": _sweep(260.0, 1540.0, 0.48, 0.17),
		"attack_charge": _sweep(140.0, 840.0, 0.32, 0.16),
		"attack_hit": _tone([95.0, 140.0, 220.0], 0.2, 0.2),
		"heal": _tone([520.0, 760.0, 1040.0], 0.28, 0.12),
		"status": _tone([330.0, 470.0], 0.18, 0.11),
		"pokemon_ko": _sweep(620.0, 70.0, 0.42, 0.18),
		"prize": _tone([700.0, 980.0, 1320.0], 0.26, 0.13),
		"coin": _tone([1280.0, 1640.0], 0.14, 0.1),
		"turn_change": _tone([440.0, 620.0, 820.0], 0.3, 0.11),
		"victory": _tone([520.0, 680.0, 860.0, 1100.0], 0.52, 0.16),
	}


func _build_music() -> void:
	_music_streams = {
		"title": _ambient_loop([110.0, 164.81, 220.0], 4.0, 0.025),
		"battle": _ambient_loop([98.0, 146.83, 196.0, 293.66], 3.2, 0.032),
		"victory": _ambient_loop([130.81, 196.0, 261.63, 329.63], 3.6, 0.03),
	}


func _play(player: AudioStreamPlayer, stream: Variant) -> void:
	if (
		player == null
		or stream == null
		or not player.is_inside_tree()
	):
		return
	player.stream = stream
	player.play()


func _set_bus_volume(bus_name: String, linear: float, muted: bool) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	AudioServer.set_bus_mute(index, muted)
	AudioServer.set_bus_volume_db(
		index,
		-80.0 if linear <= 0.0001 else linear_to_db(clampf(linear, 0.0, 1.0)),
	)


func _tone(
	frequencies: Array,
	duration: float,
	volume: float,
) -> AudioStreamWAV:
	var sample_rate := 22050
	var sample_count := int(sample_rate * duration)
	var bytes := PackedByteArray()
	bytes.resize(sample_count * 2)
	for index in range(sample_count):
		var progress := float(index) / float(maxi(1, sample_count - 1))
		var envelope := sin(PI * progress) * (1.0 - progress * 0.25)
		var wave := 0.0
		for frequency in frequencies:
			wave += sin(TAU * float(frequency) * float(index) / float(sample_rate))
		wave /= maxf(1.0, float(frequencies.size()))
		bytes.encode_s16(
			index * 2,
			int(clampf(wave * envelope * volume, -1.0, 1.0) * 32767.0),
		)
	return _wav(bytes, sample_rate, false)


func _sweep(
	start_frequency: float,
	end_frequency: float,
	duration: float,
	volume: float,
) -> AudioStreamWAV:
	var sample_rate := 22050
	var sample_count := int(sample_rate * duration)
	var bytes := PackedByteArray()
	bytes.resize(sample_count * 2)
	var phase := 0.0
	for index in range(sample_count):
		var progress := float(index) / float(maxi(1, sample_count - 1))
		var frequency := lerpf(start_frequency, end_frequency, progress)
		phase += TAU * frequency / float(sample_rate)
		var envelope := sin(PI * progress)
		var wave := sin(phase) * envelope * volume
		bytes.encode_s16(index * 2, int(clampf(wave, -1.0, 1.0) * 32767.0))
	return _wav(bytes, sample_rate, false)


func _ambient_loop(
	frequencies: Array,
	duration: float,
	volume: float,
) -> AudioStreamWAV:
	# Native AudioStreamWAV loop points can crash Android AudioTrack on some
	# devices/emulators. Replay completed one-shot streams from the player.
	return _tone(frequencies, duration, volume)


func _on_music_finished() -> void:
	if (
		_current_music.is_empty()
		or music_player == null
		or not music_player.is_inside_tree()
		or music_player.stream == null
	):
		return
	music_player.play()


func _wav(
	bytes: PackedByteArray,
	sample_rate: int,
	looped: bool,
) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = bytes
	if looped:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = int(bytes.size() / 2)
	return stream
