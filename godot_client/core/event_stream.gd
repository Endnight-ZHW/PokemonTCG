class_name GameEventStream
extends RefCounted

var capacity: int
var _events: Array[Dictionary] = []


func _init(p_capacity: int = 256) -> void:
	capacity = max(1, p_capacity)


func push(event_type: String, data: Dictionary = {}) -> void:
	if _events.size() >= capacity:
		_events.pop_front()
	_events.append({"event_type": event_type, "data": data.duplicate(true)})


func drain() -> Array[Dictionary]:
	var result: Array[Dictionary] = _events.duplicate(true)
	_events.clear()
	return result


func size() -> int:
	return _events.size()
