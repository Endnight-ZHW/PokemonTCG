class_name GameAudioMixer
extends RefCounted


static func ensure_buses() -> void:
	for bus_name in ["Music", "SFX", "UI"]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			var index := AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, bus_name)
			AudioServer.set_bus_send(index, "Master")
	for index in range(AudioServer.get_bus_effect_count(0)):
		if AudioServer.get_bus_effect(0, index) is AudioEffectLimiter:
			return
	var limiter := AudioEffectLimiter.new()
	limiter.ceiling_db = -1.0
	AudioServer.add_bus_effect(0, limiter)


static func apply_settings(settings: Node) -> void:
	if settings == null:
		return
	for pair in [["Master", "master_volume"], ["Music", "music_volume"], ["SFX", "sfx_volume"], ["UI", "sfx_volume"]]:
		var index := AudioServer.get_bus_index(pair[0])
		var value := clampf(float(settings.get(pair[1])), 0.0, 1.0)
		AudioServer.set_bus_mute(index, bool(settings.get("muted")) or value <= 0.0001)
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(value, 0.0001)))
