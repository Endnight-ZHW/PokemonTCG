class_name PortableRandomSource
extends RefCounted

const UINT32_MAX_PLUS_ONE := 4294967296.0
const FALLBACK_SEED := 0x6D2B79F5

var _state: int


func _init(seed: int = 0) -> void:
	_state = seed & 0xFFFFFFFF
	if _state == 0:
		_state = FALLBACK_SEED


func next_u32() -> int:
	_state ^= (_state << 13) & 0xFFFFFFFF
	_state ^= _state >> 17
	_state ^= (_state << 5) & 0xFFFFFFFF
	_state &= 0xFFFFFFFF
	return _state


func random_float() -> float:
	return float(next_u32()) / UINT32_MAX_PLUS_ONE


func coin() -> bool:
	return (next_u32() & 1) == 0


func choice(values: Array) -> Variant:
	if values.is_empty():
		push_error("cannot choose from an empty sequence")
		return null
	return values[next_u32() % values.size()]


func shuffle(values: Array) -> void:
	for index in range(values.size() - 1, 0, -1):
		var selected := next_u32() % (index + 1)
		var temporary: Variant = values[index]
		values[index] = values[selected]
		values[selected] = temporary


func get_state() -> int:
	return _state


func set_state(value: int) -> void:
	_state = value & 0xFFFFFFFF
	if _state == 0:
		_state = FALLBACK_SEED
