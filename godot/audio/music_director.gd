class_name GameMusicDirector
extends Node

const CROSSFADE_SECONDS := 1.0
var players: Array[AudioStreamPlayer] = []
var gains := [0.0, 0.0]
var track_gains := [1.0, 1.0]
var tracks: Dictionary = {}
var current: StringName
var active := 0
var transition: Tween
var duck := 0.0
var suspended := false
var match_active := false
var climax := false
var battle_index := -1
var result_played := false
var missing_tracks: Dictionary = {}


func configure(definitions: Dictionary) -> void:
	tracks = definitions
	for index in range(2):
		var player := AudioStreamPlayer.new()
		player.bus = "Music"
		add_child(player)
		players.append(player)


func play(track_id: StringName) -> void:
	if current == track_id:
		return
	var definition := tracks.get(track_id) as MusicTrackDefinition
	if not track_id.is_empty() and (definition == null or definition.stream == null):
		if not missing_tracks.has(track_id):
			missing_tracks[track_id] = true
			push_warning("Missing music track: " + str(track_id))
		return
	current = track_id
	if transition != null:
		transition.kill()
	if track_id.is_empty():
		for player in players:
			player.stop()
		gains = [0.0, 0.0]
		return
	# Keep the louder half of an interrupted transition; never create a third voice.
	var outgoing := 0 if float(gains[0]) >= float(gains[1]) else 1
	active = 1 - outgoing
	players[active].stop()
	var stream := definition.stream.duplicate() as AudioStreamOggVorbis
	stream.loop = true
	stream.loop_offset = definition.loop_offset
	players[active].stream = stream
	track_gains[active] = db_to_linear(definition.gain_db)
	_set_gain(0.0, active)
	players[active].play()
	players[active].stream_paused = suspended
	transition = create_tween().set_parallel(true)
	transition.tween_method(_set_gain.bind(outgoing), float(gains[outgoing]), 0.0, CROSSFADE_SECONDS)
	transition.tween_method(_set_gain.bind(active), 0.0, 1.0, CROSSFADE_SECONDS)
	transition.chain().tween_callback(_stop_inactive.bind(outgoing))
	if suspended:
		transition.pause()


func _set_gain(value: float, index: int) -> void:
	gains[index] = value
	players[index].volume_db = linear_to_db(maxf(0.0001, value * float(track_gains[index]))) + duck


func _stop_inactive(index: int) -> void:
	players[index].stop()
	players[index].stream = null


func update_duck(target: float, delta: float) -> void:
	duck = move_toward(duck, target, delta * (80.0 if target < duck else 12.0))
	for index in range(players.size()):
		_set_gain(float(gains[index]), index)


func set_suspended(value: bool) -> void:
	suspended = value
	for player in players:
		player.stream_paused = value
	if transition != null and transition.is_valid():
		if value:
			transition.pause()
		else:
			transition.play()


func begin_match() -> void:
	match_active = true
	climax = false
	result_played = false
	battle_index = (battle_index + 1) % 2
	play(&"preparation")


func update_battle(setup_complete: bool, terminal: bool, prize_counts: Array[int]) -> void:
	if not match_active or terminal or result_played:
		return
	if not setup_complete:
		play(&"preparation")
		return
	for count in prize_counts:
		if count in [1, 2]:
			climax = true
	play(&"climax" if climax else &"battle_kanto" if battle_index == 0 else &"battle_johto")


func leave_match() -> void:
	match_active = false
	climax = false
