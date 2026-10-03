extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")
	create_timer(20.0).timeout.connect(func() -> void:
		push_error("Audio contract timed out")
		quit(1)
	)


func _run() -> void:
	var audio := AudioDirector.new()
	root.add_child(audio)
	await process_frame
	_check(audio._sfx_voices.size() == 8, "SFX pool is not bounded to eight voices")
	audio.play_cue("card_draw")
	audio.play_cue("attack_hit_fire")
	_check(audio._sfx_voices[0].playing and audio._sfx_voices[1].playing, "A hit interrupted the card sound")
	for i in range(6): audio.play_cue("card_place")
	audio.play_cue("card_move")
	_check(audio._sfx_voices[1].stream == audio._cues.attack_hit_fire, "Low-priority sound stole a hit")
	_check(audio._sfx_voices[0].stream == audio._cues.card_move, "Full pool failed to reclaim its oldest ordinary voice")
	audio.stop_sfx()
	for i in range(8): audio.play_cue("attack_hit_fire")
	var serial := audio._sfx_serial
	audio.play_cue("card_draw")
	_check(audio._sfx_serial == serial, "Full critical pool admitted a lower priority voice")
	audio.play_cue("pokemon_ko")
	_check(audio._sfx_voices[0].stream == audio._cues.pokemon_ko, "KO could not reclaim the oldest critical voice")
	var table := preload("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	root.add_child(table)
	table.audio_cancel_requested.connect(audio.stop_sfx)
	table.cancel_presentations("audio_resync")
	for voice in audio._sfx_voices:
		_check(not voice.playing and voice.stream == null, "Resync left an orphan sound")
	for element in BattleFeedbackCue.ELEMENTS:
		_check(audio._cues.has("attack_hit_" + str(element).to_lower()), "Missing attribute sound: " + str(element))
	_check(audio._cues.attack_hit_fire.data != audio._cues.attack_hit_water.data, "Attributes share identical impact audio")
	var a := audio._textured_cue(140, 48, 0.24, 0.7, 0.2)
	var b := audio._textured_cue(140, 48, 0.24, 0.7, 0.2)
	_check(a.data == b.data, "Synthesis is not reproducible")
	audio.play_cue("evolution")
	audio.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	for voice in audio._sfx_voices: _check(not voice.playing, "App pause left a sound playing")
	table.queue_free()
	audio.queue_free()
	await process_frame
	# The audio mixer releases stopped playbacks on its next mixing buffer.
	await create_timer(0.15).timeout
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("BATTLE_AUDIO_CONTRACT_OK")
	quit(0 if failures.is_empty() else 1)


func _check(ok: bool, message: String) -> void:
	if not ok: failures.append(message)
