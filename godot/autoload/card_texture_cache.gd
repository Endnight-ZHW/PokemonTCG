extends Node

signal texture_ready(path: String, texture: Texture2D)

var _textures: Dictionary = {}
var _usage_order: Array[String] = []
var _hits := 0
var _misses := 0
var _pending: Dictionary = {}
var _prefetch_batches: Array[Dictionary] = []


func _ready() -> void:
	set_process(false)
	AppSettings.changed.connect(_apply_limit)
	AppSettings.runtime_quality_changed.connect(_apply_limit)
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


func get_cached_or_request(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _textures.has(path) or ResourceLoader.has_cached(path):
		return get_texture(path)
	if not _pending.has(path):
		var error := ResourceLoader.load_threaded_request(path, "Texture2D")
		if error == OK:
			_pending[path] = true
			set_process(true)
	return null


func _process(_delta: float) -> void:
	for key in _pending.keys():
		var path := str(key)
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_pending.erase(path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var texture := ResourceLoader.load_threaded_get(path) as Texture2D
			if texture != null:
				for batch in _prefetch_batches:
					if path in batch.paths:
						batch.loaded[path] = texture
				_textures[path] = texture
				_touch(path)
				_trim()
				texture_ready.emit(path, texture)
	for i in range(_prefetch_batches.size() - 1, -1, -1):
		var batch: Dictionary = _prefetch_batches[i]
		var handle := batch.handle as MotionHandle
		if handle.is_finished():
			_prefetch_batches.remove_at(i)
			continue
		var waiting := false
		for path in batch.paths:
			if _pending.has(path):
				waiting = true
			elif ResourceLoader.has_cached(path) and not batch.loaded.has(path):
				batch.loaded[path] = ResourceLoader.load(path, "Texture2D")
		if not waiting:
			handle.set_meta("prefetched_textures", batch.loaded.values())
			_prefetch_batches.remove_at(i)
			handle.finish()
	set_process(not _pending.is_empty())


func prefetch(paths: Array[String]) -> MotionHandle:
	var handle := MotionHandle.new()
	var loaded: Dictionary = {}
	var waiting: Array[String] = []
	for path in paths:
		if path.is_empty() or not ResourceLoader.exists(path, "Texture2D"):
			continue
		var texture := get_cached_or_request(path)
		if texture != null:
			loaded[path] = texture
		elif _pending.has(path):
			waiting.append(path)
	if waiting.is_empty():
		handle.set_meta("prefetched_textures", loaded.values())
		handle.finish()
	else:
		_prefetch_batches.append({"handle": handle, "paths": waiting, "loaded": loaded})
		set_process(true)
	return handle


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
