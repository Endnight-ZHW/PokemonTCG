extends SceneTree

var failures: Array[String] = []
var audio: AudioDirector


func _initialize() -> void:
	call_deferred("_run")


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)


func _run() -> void:
	audio = AudioDirector.new()
	root.add_child(audio)
	await process_frame
	check(audio.cues.size() == 87, "Incomplete cue catalog")
	check(audio.sfx.players.size() == 16 and audio.ui.players.size() == 4, "Voice pools exceed their budgets")
	for cue: AudioCueDefinition in audio.catalog.cues:
		check(cue.variants.size() >= 3, "Missing variants: " + str(cue.id))
		var hashes := {}
		for stream in cue.variants:
			check(stream != null and stream.get_length() > 0.03, "Missing or empty sample: " + str(cue.id))
			if stream is AudioStreamWAV:
				var data := (stream as AudioStreamWAV).data
				hashes[hash(data)] = true
		check(hashes.size() == cue.variants.size(), "Identical variants: " + str(cue.id))
	for element in BattleFeedbackCue.ELEMENTS:
		for kind in ["attack_charge_", "attack_hit_", "attack_heavy_"]:
			check(audio.cues.has(StringName(kind + str(element).to_lower())), "Missing attribute " + kind + str(element))
	check(audio.music.tracks.size() == 7, "Missing music")
	for track: MusicTrackDefinition in audio.catalog.tracks:
		check(track.stream != null and track.loop_offset >= 0.0 and track.loop_offset < track.stream.get_length() - 5.0, "Invalid music loop: " + str(track.id))
	_check_randomization_and_identity()
	_check_priority_and_scopes()
	_check_battle_mix()
	await _check_music()
	await _check_ui_and_settings()
	audio.queue_free()
	await process_frame
	await create_timer(0.15).timeout
	if failures.is_empty():
		print("AUDIO_SYSTEM_CONTRACT_OK")
	else:
		for message in failures:
			push_error(message)
	quit(0 if failures.is_empty() else 1)


func _check_randomization_and_identity() -> void:
	var definition := (audio.cues[&"card_draw"] as AudioCueDefinition).duplicate() as AudioCueDefinition
	definition.cooldown_ms = 0
	var previous := -1
	seed(314159)
	var expected := randi()
	seed(314159)
	for index in range(60):
		check(audio.sfx.play(AudioCueRequest.make(&"card_draw"), definition), "Variation dropped")
		var current := int(audio.sfx.last_variants[definition.id])
		check(current != previous, "Consecutive sample repetition")
		previous = current
	check(randi() == expected, "Audio consumed global randomness")
	audio.stop_sfx()
	var request := AudioCueRequest.make(&"card_draw", &"battle", "draw:1", "departure", 0)
	check(audio.play(request), "First semantic event was suppressed")
	check(not audio.play(request), "Duplicate semantic event replayed")
	request = AudioCueRequest.make(&"card_draw", &"battle", "draw:1", "departure", 1)
	request.variant = 1
	check(audio.play(request), "Second card collapsed into first card")
	var heavy := AudioCueRequest.make(&"attack_hit")
	heavy.element = "Fire"
	heavy.heavy = true
	check(heavy.resolved_cue() == &"attack_heavy_fire", "Heavy attribute request resolves incorrectly")
	audio.stop_sfx()


func _check_priority_and_scopes() -> void:
	var ordinary := (audio.cues[&"card_draw"] as AudioCueDefinition).duplicate() as AudioCueDefinition
	var critical := (audio.cues[&"pokemon_ko"] as AudioCueDefinition).duplicate() as AudioCueDefinition
	ordinary.cooldown_ms = 0
	ordinary.max_instances = 16
	critical.cooldown_ms = 0
	critical.max_instances = 16
	for index in range(16):
		audio.sfx.play(AudioCueRequest.make(&"pokemon_ko"), critical)
	check(not audio.sfx.play(AudioCueRequest.make(&"card_draw"), ordinary), "Ordinary sound stole critical voice")
	check(audio.sfx.play(AudioCueRequest.make(&"pokemon_ko"), critical), "Critical sound could not reclaim oldest voice")
	check(audio.sfx.slots[0].order == audio.sfx.serial, "Reclaimed wrong priority victim")
	audio.stop_sfx()
	audio.play(AudioCueRequest.make(&"card_draw", &"battle"))
	audio.play(AudioCueRequest.make(&"coin_toss", &"coin:test"))
	audio.cancel_scope(&"coin:test")
	check(audio.sfx.players[0].playing and not audio.sfx.players[1].playing, "Scoped cancellation affected unrelated audio")
	audio.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	for player in audio.sfx.players:
		check(not player.playing and player.stream == null, "Background retained short sound")
	check(not audio.play(AudioCueRequest.make(&"card_draw")), "Background accepted cue")
	audio.notification(Node.NOTIFICATION_APPLICATION_RESUMED)


func _check_battle_mix() -> void:
	audio.stop_sfx()
	for element in BattleFeedbackCue.ELEMENTS:
		var charge := audio.cues[StringName("attack_charge_" + str(element).to_lower())] as AudioCueDefinition
		for stream in charge.variants:
			check(stream.get_length() <= 0.25, "Charge tail extends beyond the normal windup: " + str(element))
	var windup := AudioCueRequest.make(&"attack_charge_fire", &"battle", "a", "windup")
	windup.variant = 0
	check(audio.play(windup), "Missing battle windup")
	var other := AudioCueRequest.make(&"attack_charge_water", &"audition", "b", "windup")
	other.variant = 0
	check(audio.play(other), "Missing independent windup")
	var hit := AudioCueRequest.make(&"attack_hit_fire", &"battle", "hit:a", "impact")
	check(audio.play(hit), "First target was suppressed")
	check(audio.sfx.slots[0].get("category") == "impact", "Impact did not replace its windup")
	check(audio.sfx.slots[1].get("category") == "charge" and audio.sfx.players[1].playing, "Impact stopped another scope's windup")
	var second := AudioCueRequest.make(&"attack_hit_fire", &"battle", "hit:b", "impact")
	check(audio.play(second), "Distinct simultaneous target was lost to cooldown")
	check(is_equal_approx(float(audio.sfx.slots[2].get("stack_db", 0.0)), -2.0), "Simultaneous targets lack gain compensation")
	check(not audio.play(second), "Repeated impact event played twice")
	var audition := AudioCueRequest.make(&"attack_hit_water", &"audition", "hit:c", "impact")
	audition.variant = 1
	check(audio.play(audition), "Independent audition impact failed")
	check(is_zero_approx(float(audio.sfx.slots[1].get("stack_db", -1))), "Stack attenuation leaked between scopes")
	check(is_equal_approx(audio.sfx.players[1].pitch_scale, 1.0), "Fixed audition changed pitch")
	audio.cancel_scope(&"battle")
	check(audio.sfx.players[1].playing and not audio.sfx.players[0].playing and not audio.sfx.players[2].playing, "Battle cancellation affected independent scope")
	audio.stop_sfx()


func _check_music() -> void:
	check("未白镇" in (audio.music.tracks[&"title"] as MusicTrackDefinition).title, "Homepage lost its Littleroot selection")
	audio.play_music("title")
	await create_timer(0.2).timeout
	var same := audio.music.active
	var tween := audio.music.transition
	audio.play_music("title")
	check(audio.music.active == same and audio.music.transition == tween, "Same-state music restarted")
	audio.play_music("preparation")
	audio.play_music("title")
	audio.play_music("preparation")
	await create_timer(1.1).timeout
	var count := 0
	for player in audio.music.players:
		if player.playing: count += 1
	check(count == 1 and audio.music.current == &"preparation", "Interrupted crossfade stranded a music player")
	audio.play_music("battle")
	audio.update_battle_music(false, false, [0, 0])
	check(audio.music.current == &"preparation", "Setup triggered battle/climax")
	audio.update_battle_music(true, false, [6, 6])
	check(audio.music.current == &"battle_kanto", "First match did not select first battle track")
	audio.update_battle_music(true, true, [0, 2])
	check(audio.music.current == &"battle_kanto", "Terminal snapshot triggered climax")
	audio.update_battle_music(true, false, [2, 6])
	check(audio.music.current == &"climax", "Public prize threshold failed")
	audio.update_battle_music(true, false, [4, 6])
	check(audio.music.current == &"climax", "Climax did not latch")
	audio.play_result("defeat")
	var serial := audio.sfx.serial
	audio.play_result("defeat")
	check(audio.music.current == &"reflection" and audio.sfx.serial == serial, "Result played twice or used victory music on defeat")
	audio.play_music("battle")
	audio.update_battle_music(true, false, [6, 6])
	check(audio.music.current == &"battle_johto" and not audio.music.climax, "Rematch did not rotate/reset music")
	audio.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	check(audio.music.suspended and audio.music.players[audio.music.active].stream_paused, "Background did not pause music")
	audio.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	check(not audio.music.suspended and not audio.music.players[audio.music.active].stream_paused, "Foreground did not resume music")
	for track: MusicTrackDefinition in audio.catalog.tracks:
		audio.music.play(track.id)
		var player := audio.music.players[audio.music.active]
		player.seek(track.stream.get_length() - 0.08)
		await create_timer(0.28).timeout
		check(player.playing and player.get_stream_playback().get_loop_count() > 0, "Native Ogg loop did not wrap: " + str(track.id))
		check(player.get_playback_position() >= track.loop_offset and player.get_playback_position() < track.loop_offset + 1.0, "Loop replayed intro or wrong section: " + str(track.id))
	audio.play_music("")
	audio.stop_sfx()


func _check_ui_and_settings() -> void:
	var serial := audio.ui.serial
	audio.play_ui("click")
	audio.play_ui("confirm")
	await process_frame
	check(audio.ui.serial == serial + 1, "UI activation produced duplicate cues")
	check(audio.ui.slots[0].get("cue") == &"confirm", "UI generic click masked semantic cue")
	var settings := root.get_node("AppSettings")
	var saved := bool(settings.muted)
	settings.muted = true
	settings.changed.emit()
	check(AudioServer.is_bus_mute(0), "Mute setting did not apply")
	settings.muted = saved
	settings.changed.emit()
	check(AudioServer.get_bus_effect_count(0) == 1, "Duplicate master limiter")
