extends Node

signal changed

const SETTINGS_PATH := "user://settings.cfg"
const DEFAULT_MASTER_VOLUME := 0.8
const DEFAULT_MUTED := false
const DEFAULT_REDUCED_MOTION := false
const DEFAULT_CARD_CACHE_SIZE := 24
const DEFAULT_RELAY_URL := "ws://127.0.0.1:8766"

var master_volume := DEFAULT_MASTER_VOLUME
var muted := DEFAULT_MUTED
var reduced_motion := DEFAULT_REDUCED_MOTION
var card_cache_size := DEFAULT_CARD_CACHE_SIZE
var relay_url := DEFAULT_RELAY_URL


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
	muted = bool(config.get_value("audio", "muted", DEFAULT_MUTED))
	reduced_motion = bool(
		config.get_value("accessibility", "reduced_motion", DEFAULT_REDUCED_MOTION)
	)
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
	config.set_value("audio", "muted", muted)
	config.set_value("accessibility", "reduced_motion", reduced_motion)
	config.set_value("performance", "card_cache_size", card_cache_size)
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
) -> void:
	master_volume = clampf(new_master_volume, 0.0, 1.0)
	muted = new_muted
	reduced_motion = new_reduced_motion
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
	muted = DEFAULT_MUTED
	reduced_motion = DEFAULT_REDUCED_MOTION
	card_cache_size = DEFAULT_CARD_CACHE_SIZE
	relay_url = DEFAULT_RELAY_URL
	if emit_signal:
		changed.emit()


func volume_db() -> float:
	if muted or master_volume <= 0.0001:
		return -80.0
	return linear_to_db(master_volume)
