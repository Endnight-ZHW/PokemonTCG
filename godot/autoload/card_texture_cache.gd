extends Node

var _textures: Dictionary = {}
var _usage_order: Array[String] = []
var _hits := 0
var _misses := 0


func _ready() -> void:
	AppSettings.changed.connect(_apply_limit)
	_apply_limit()


func get_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _textures.has(path):
		_hits += 1
		_touch(path)
		return _textures[path] as Texture2D
	_misses += 1
	var texture := ResourceLoader.load(path, "Texture2D") as Texture2D
	if texture == null:
		return null
	_textures[path] = texture
	_usage_order.append(path)
	_trim()
	return texture


func clear() -> void:
	_textures.clear()
	_usage_order.clear()


func stats() -> Dictionary:
	return {
		"entries": _textures.size(),
		"limit": AppSettings.card_cache_size,
		"hits": _hits,
		"misses": _misses,
	}


func reset_stats() -> void:
	_hits = 0
	_misses = 0


func _apply_limit() -> void:
	_trim()


func _touch(path: String) -> void:
	_usage_order.erase(path)
	_usage_order.append(path)


func _trim() -> void:
	var limit := maxi(8, AppSettings.card_cache_size)
	if OS.get_name() in ["Android", "iOS"]:
		var quality := AppSettings.resolved_quality_profile()
		limit = mini(limit, 12 if quality == "low" else 18)
	while _usage_order.size() > limit:
		var oldest: String = _usage_order.pop_front()
		_textures.erase(oldest)
