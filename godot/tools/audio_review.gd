extends SceneTree

## Captures the actual Godot buses, including variation, ducking and music changes.
func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var baseline := "--baseline" in OS.get_cmdline_user_args()
	var folder := ProjectSettings.globalize_path("res://../build/audio-review")
	DirAccess.make_dir_recursive_absolute(folder)
	var director: Node
	if baseline:
		var script := load(folder.path_join("legacy_audio.gd")) as Script
		if script == null:
			push_error("Capture the pre-change audio_director.gd to build/audio-review/legacy_audio.gd first.")
			quit(1)
			return
		director = script.new()
	else:
		director = AudioDirector.new()
	root.add_child(director)
	var settings := root.get_node("AppSettings")
	settings.muted = false
	settings.master_volume = 0.8
	settings.sfx_volume = 0.8
	settings.music_volume = 0.55
	director.apply_settings()
	var recorder := AudioEffectRecord.new()
	AudioServer.add_bus_effect(0, recorder)
	var effect_index := AudioServer.get_bus_effect_count(0) - 1
	recorder.set_recording_active(true)
	director.play_music("battle")
	if not baseline:
		(director as AudioDirector).update_battle_music(true, false, [6, 6])
	# Same semantic choreography in both recordings; silence replaces formerly absent effects.
	var sequence := [
		[0.2, "click"], [0.5, "shuffle"], [1.5, "card_draw"], [1.68, "card_draw"], [1.86, "card_draw"],
		[2.3, "card_place"], [2.8, "coin_toss"], [3.35, "coin_land"], [4.0, "energy_attach"],
		[5.0, "evolution"], [6.2, "attack_charge_fire"], [6.62, "attack_hit_fire"],
		[7.8, "attack_charge_water"], [8.22, "attack_hit_water"], [9.4, "status_poisoned"],
		[10.2, "heal"], [11.2, "attack_charge_lightning"], [11.62, "attack_heavy_lightning"],
		[12.6, "pokemon_ko"], [13.6, "prize"], [15.5, "victory"],
	]
	var start := Time.get_ticks_msec()
	for row in sequence:
		var wait := float(row[0]) - float(Time.get_ticks_msec() - start) / 1000.0
		if wait > 0:
			await create_timer(wait).timeout
		var cue := str(row[1])
		if baseline:
			if cue.begins_with("attack_charge_"): cue = "attack_charge"
			elif cue.begins_with("attack_heavy_"): cue = "attack_hit_" + cue.trim_prefix("attack_heavy_")
			elif cue.begins_with("status_"): cue = "status"
		if cue == "victory":
			if baseline:
				director.play_music("victory")
				director.play_cue("victory")
			else:
				(director as AudioDirector).play_result("victory")
		else:
			director.play_cue(cue)
		if row[1] == "prize" and not baseline:
			(director as AudioDirector).update_battle_music(true, false, [2, 4])
	await create_timer(3.0).timeout
	recorder.set_recording_active(false)
	var recording := recorder.get_recording()
	var name_value := "before.wav" if baseline else "after.wav"
	var output := folder.path_join(name_value)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output = ProjectSettings.globalize_path(argument.trim_prefix("--output="))
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var error := recording.save_to_wav(output)
	AudioServer.remove_bus_effect(0, effect_index)
	director.queue_free()
	await process_frame
	await create_timer(0.15).timeout
	print("AUDIO_REVIEW_CAPTURE_OK: " + output + " (" + str(recording.get_length()) + " s)")
	quit(0 if error == OK and recording.get_length() > 17.0 else 1)
