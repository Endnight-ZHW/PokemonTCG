class_name NetTransport
extends RefCounted


func poll() -> Array[Dictionary]:
	return []


func send(_message: Dictionary) -> bool:
	return false


func close() -> void:
	pass


func connected_state() -> bool:
	return false


func get_room_id() -> String:
	return ""
