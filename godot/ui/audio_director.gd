class_name AudioDirector
extends Node

var ui_player: AudioStreamPlayer
var sfx_player: AudioStreamPlayer
var music_player: AudioStreamPlayer
var _cues: Dictionary = {}
var _music_streams: Dictionary = {}
var _current_music := ""
var _initialized := false
const SFX_VOICES := 8
var _sfx_voices: Array[AudioStreamPlayer] = []
var _sfx_orders: Array[int] = []
var _sfx_priorities: Array[int] = []
var _sfx_serial := 0


func _ready() -> void:
	_initialize_runtime()


func _exit_tree() -> void:
	stop_sfx()
	for player in [ui_player, sfx_player, music_player]:
		if player:
			player.stop()
			player.stream = null
	_cues.clear()
	_music_streams.clear()
	_sfx_voices.clear()
	_sfx_orders.clear()
	_sfx_priorities.clear()


func _initialize_runtime() -> void:
	if _initialized:
		return
	_initialized = true
	_ensure_buses()
	ui_player = _player("UI")
	sfx_player = _player("SFX")
	_sfx_voices.append(sfx_player)
	for index in range(SFX_VOICES):
		if index > 0: _sfx_voices.append(_player("SFX"))
		_sfx_orders.append(0)
		_sfx_priorities.append(0)
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
	var stream: AudioStreamWAV = _cues.get(cue)
	if stream == null: return
	var priority := 3 if cue.begins_with("attack_hit") or cue in ["evolution", "pokemon_ko", "victory", "coin_land"] else 1
	var chosen := -1
	for index in range(_sfx_voices.size()):
		if not _sfx_voices[index].playing:
			chosen = index
			break
		if chosen < 0 or _sfx_priorities[index] < _sfx_priorities[chosen] or (_sfx_priorities[index] == _sfx_priorities[chosen] and _sfx_orders[index] < _sfx_orders[chosen]):
			chosen = index
	if chosen < 0 or (_sfx_voices[chosen].playing and _sfx_priorities[chosen] > priority): return
	_sfx_serial += 1
	_sfx_orders[chosen] = _sfx_serial
	_sfx_priorities[chosen] = priority
	_play(_sfx_voices[chosen], stream)


func stop_sfx() -> void:
	for voice in _sfx_voices:
		if is_instance_valid(voice):
			voice.stop()
			voice.stream = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		stop_sfx()


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
	# Resolve at runtime, including SceneTree contract scripts parsed before autoloads.
	var loop := Engine.get_main_loop() as SceneTree
	var settings := loop.root.get_node_or_null("AppSettings") if loop != null else null
	if settings == null: return
	_set_bus_volume("Master", float(settings.get("master_volume")), bool(settings.get("muted")))
	_set_bus_volume("Music", float(settings.get("music_volume")), bool(settings.get("muted")))
	_set_bus_volume("SFX", float(settings.get("sfx_volume")), bool(settings.get("muted")))
	_set_bus_volume("UI", float(settings.get("sfx_volume")), bool(settings.get("muted")))


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
		"card_reveal": _tone([520.0, 760.0, 1120.0], 0.22, 0.11),
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
		"coin_toss": _sweep(920.0, 1760.0, 0.18, 0.09),
		"coin_land": _tone([240.0, 480.0, 960.0], 0.12, 0.12),
		"shuffle": _sweep(420.0, 880.0, 0.28, 0.08),
		"turn_change": _tone([440.0, 620.0, 820.0], 0.3, 0.11),
		"victory": _tone([520.0, 680.0, 860.0, 1100.0], 0.52, 0.16),
	}
	# Deterministic synthesis is cached once; no samples or randomness enter rules.
	var paper_sounds := {
		"card_draw": [680.0, 1080.0, 0.12, 0.80], "card_move": [340.0, 780.0, 0.14, 0.68],
		"card_discard": [900.0, 180.0, 0.18, 0.82], "shuffle": [460.0, 300.0, 0.28, 0.90],
	}
	for name_value: String in paper_sounds:
		var values: Array = paper_sounds[name_value]
		_cues[name_value] = _textured_cue(values[0], values[1], values[2], values[3], 0.18)
	_cues.card_place = _textured_cue(210.0, 65.0, 0.13, 0.48, 0.25)
	_cues.attack_charge = _textured_cue(110.0, 680.0, 0.22, 0.24, 0.20, true)
	_cues.attack_hit = _textured_cue(160.0, 48.0, 0.24, 0.62, 0.32)
	_cues.energy_attach = _textured_cue(780.0, 1380.0, 0.24, 0.12, 0.17)
	_cues.evolution = _textured_cue(480.0, 1480.0, 0.38, 0.20, 0.22)
	_cues.pokemon_ko = _textured_cue(330.0, 44.0, 0.42, 0.44, 0.27)
	_cues.coin_land = _textured_cue(1850.0, 1420.0, 0.16, 0.28, 0.16)
	var attributes := {
		"grass": [650.0, 180.0, 0.82], "fire": [140.0, 48.0, 0.78],
		"water": [460.0, 90.0, 0.68], "lightning": [2100.0, 130.0, 0.56],
		"psychic": [580.0, 220.0, 0.18], "fighting": [100.0, 38.0, 0.48],
		"darkness": [190.0, 54.0, 0.30], "metal": [1700.0, 580.0, 0.26],
		"dragon": [380.0, 72.0, 0.44], "colorless": [320.0, 65.0, 0.84],
	}
	for element: String in attributes:
		var values: Array = attributes[element]
		_cues["attack_hit_" + element] = _textured_cue(values[0], values[1], 0.26, values[2], 0.28)


func _textured_cue(start_hz: float, end_hz: float, seconds: float, noise_mix: float, volume: float, rising: bool = false) -> AudioStreamWAV:
	var rate := 22050
	var samples := int(seconds * rate)
	var bytes := PackedByteArray()
	bytes.resize(samples * 2)
	var phase := 0.0
	var filtered := 0.0
	var seed_value := 73101
	for index in range(samples):
		var t := float(index) / maxi(1, samples - 1)
		seed_value = (seed_value * 1103515245 + 12345) & 0x7fffffff
		var noise := float(seed_value) / 1073741824.0 - 1.0
		filtered = lerpf(filtered, noise, 0.34)
		phase += TAU * lerpf(start_hz, end_hz, t) / rate
		var body := sin(phase) * 0.68 + sin(phase * 2.73) * 0.20 + sin(phase * 0.5) * 0.12
		var envelope := smoothstep(0.0, 0.025, t) * exp(-t * 5.0) * (1.0 - smoothstep(0.8, 1.0, t))
		if rising: envelope = sin(t * PI * 0.85) * (1.0 - smoothstep(0.82, 1.0, t))
		var transient := noise * exp(-t * 45.0) * 0.18
		var wave := (lerpf(body, filtered * 2.0, noise_mix) + transient) * envelope * volume
		bytes.encode_s16(index * 2, int(clampf(wave, -1.0, 1.0) * 32767.0))
	return _wav(bytes, rate, false)


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
		stream.loop_end = int(float(bytes.size()) / 2.0)
	return stream
