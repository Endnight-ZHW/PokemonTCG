extends Node

signal changed

const SETTINGS_PATH := "user://settings.cfg"
const DEFAULT_MASTER_VOLUME := 0.8
const DEFAULT_MUSIC_VOLUME := 0.55
const DEFAULT_SFX_VOLUME := 0.8
const DEFAULT_MUTED := false
const DEFAULT_REDUCED_MOTION := false
const DEFAULT_CARD_CACHE_SIZE := 24
const DEFAULT_RELAY_URL := "ws://127.0.0.1:8766"
const DEFAULT_ANIMATION_MODE := "cinematic"
const DEFAULT_QUALITY_PROFILE := "auto"

var master_volume := DEFAULT_MASTER_VOLUME
var music_volume := DEFAULT_MUSIC_VOLUME
var sfx_volume := DEFAULT_SFX_VOLUME
var muted := DEFAULT_MUTED
var reduced_motion := DEFAULT_REDUCED_MOTION
var card_cache_size := DEFAULT_CARD_CACHE_SIZE
var relay_url := DEFAULT_RELAY_URL
var animation_mode := DEFAULT_ANIMATION_MODE
var quality_profile := DEFAULT_QUALITY_PROFILE


func _ready() -> void:
	load_settings()


func load_settings(path: String = SETTINGS_PATH) -> bool:
	reset_defaults(false)
	var config := ConfigFile.new()
	var error := config.load(path)
	if error == ERR_FILE_NOT_FOUND:
		changed.emit()
		return true
	if error != OK:
		push_warning("Unable to load settings from %s: %s" % [path, error_string(error)])
		changed.emit()
		return false
	master_volume = clampf(
		float(config.get_value("audio", "master_volume", DEFAULT_MASTER_VOLUME)),
		0.0,
		1.0,
	)
	music_volume = clampf(
		float(config.get_value("audio", "music_volume", DEFAULT_MUSIC_VOLUME)),
		0.0,
		1.0,
	)
	sfx_volume = clampf(
		float(config.get_value("audio", "sfx_volume", DEFAULT_SFX_VOLUME)),
		0.0,
		1.0,
	)
	muted = bool(config.get_value("audio", "muted", DEFAULT_MUTED))
	var legacy_reduced_motion := bool(
		config.get_value("accessibility", "reduced_motion", DEFAULT_REDUCED_MOTION)
	)
	animation_mode = str(config.get_value(
		"accessibility",
		"animation_mode",
		"reduced" if legacy_reduced_motion else DEFAULT_ANIMATION_MODE,
	))
	if animation_mode not in ["cinematic", "standard", "fast", "reduced"]:
		animation_mode = DEFAULT_ANIMATION_MODE
	reduced_motion = animation_mode == "reduced"
	quality_profile = str(config.get_value(
		"performance",
		"quality_profile",
		DEFAULT_QUALITY_PROFILE,
	))
	if quality_profile not in ["auto", "high", "medium", "low"]:
		quality_profile = DEFAULT_QUALITY_PROFILE
	card_cache_size = clampi(
		int(config.get_value(
			"performance",
			"card_cache_size",
			DEFAULT_CARD_CACHE_SIZE,
		)),
		8,
		64,
	)
	relay_url = str(
		config.get_value("network", "relay_url", DEFAULT_RELAY_URL)
	).strip_edges()
	if relay_url.is_empty():
		relay_url = DEFAULT_RELAY_URL
	changed.emit()
	return true


func save_settings(path: String = SETTINGS_PATH) -> bool:
	var config := ConfigFile.new()
	config.set_value("audio", "master_volume", master_volume)
	config.set_value("audio", "music_volume", music_volume)
	config.set_value("audio", "sfx_volume", sfx_volume)
	config.set_value("audio", "muted", muted)
	config.set_value("accessibility", "reduced_motion", reduced_motion)
	config.set_value("accessibility", "animation_mode", animation_mode)
	config.set_value("performance", "card_cache_size", card_cache_size)
	config.set_value("performance", "quality_profile", quality_profile)
	config.set_value("network", "relay_url", relay_url)
	var error := config.save(path)
	if error != OK:
		push_warning("Unable to save settings to %s: %s" % [path, error_string(error)])
		return false
	return true


func update(
	new_master_volume: float,
	new_muted: bool,
	new_reduced_motion: bool,
	new_card_cache_size: int,
	new_animation_mode: String = "",
	new_quality_profile: String = "",
	new_music_volume: float = -1.0,
	new_sfx_volume: float = -1.0,
) -> void:
	master_volume = clampf(new_master_volume, 0.0, 1.0)
	if new_music_volume >= 0.0:
		music_volume = clampf(new_music_volume, 0.0, 1.0)
	if new_sfx_volume >= 0.0:
		sfx_volume = clampf(new_sfx_volume, 0.0, 1.0)
	muted = new_muted
	if not new_animation_mode.is_empty():
		animation_mode = (
			new_animation_mode
			if new_animation_mode in ["cinematic", "standard", "fast", "reduced"]
			else DEFAULT_ANIMATION_MODE
		)
	else:
		animation_mode = "reduced" if new_reduced_motion else animation_mode
	if not new_quality_profile.is_empty():
		quality_profile = (
			new_quality_profile
			if new_quality_profile in ["auto", "high", "medium", "low"]
			else DEFAULT_QUALITY_PROFILE
		)
	reduced_motion = animation_mode == "reduced"
	card_cache_size = clampi(new_card_cache_size, 8, 64)
	changed.emit()


func set_relay_url(value: String) -> void:
	var normalized := value.strip_edges()
	if normalized.is_empty():
		return
	relay_url = normalized
	save_settings()
	changed.emit()


func reset_defaults(emit_signal: bool = true) -> void:
	master_volume = DEFAULT_MASTER_VOLUME
	music_volume = DEFAULT_MUSIC_VOLUME
	sfx_volume = DEFAULT_SFX_VOLUME
	muted = DEFAULT_MUTED
	reduced_motion = DEFAULT_REDUCED_MOTION
	card_cache_size = DEFAULT_CARD_CACHE_SIZE
	relay_url = DEFAULT_RELAY_URL
	animation_mode = DEFAULT_ANIMATION_MODE
	quality_profile = DEFAULT_QUALITY_PROFILE
	if emit_signal:
		changed.emit()


func volume_db() -> float:
	if muted or master_volume <= 0.0001:
		return -80.0
	return linear_to_db(master_volume)


func resolved_quality_profile() -> String:
	if quality_profile != "auto":
		return quality_profile
	if OS.get_name() in ["Android", "iOS"]:
		# Stability first: mobile auto mode uses the bounded 30 FPS profile.
		# Users can explicitly select Medium/High after validating their device.
		return "low"
	return "high"


func target_fps() -> int:
	return 30 if resolved_quality_profile() == "low" else 60
