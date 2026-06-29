class_name VMModifierManager
extends RefCounted

const MODIFY_DAMAGE := "MODIFY_DAMAGE"
const AFTER_DAMAGE := "AFTER_DAMAGE"
const CAN_RETREAT := "CAN_RETREAT"
const MAX_HP := "MAX_HP"
const POKEMON_KO := "POKEMON_KO"
const ON_ATTACH := "ON_ATTACH"

var _hooks: Dictionary = {}
var _sequence := 0


func _init() -> void:
	for hook in [MODIFY_DAMAGE, AFTER_DAMAGE, CAN_RETREAT, MAX_HP, POKEMON_KO, ON_ATTACH]:
		_hooks[hook] = []


func register_hook(
	hook: String,
	source: String,
	owner_player: int,
	priority: int = 0,
	payload: Dictionary = {},
) -> void:
	if not _hooks.has(hook):
		push_error("Unknown VM modifier hook: %s" % hook)
		return
	_sequence += 1
	_hooks[hook].append({
		"source": source,
		"owner_player": owner_player,
		"priority": priority,
		"sequence": _sequence,
		"payload": payload.duplicate(true),
	})
	_hooks[hook].sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if int(left.get("priority", 0)) == int(right.get("priority", 0)):
			return int(left.get("sequence", 0)) < int(right.get("sequence", 0))
		return int(left.get("priority", 0)) > int(right.get("priority", 0))
	)


func hooks_for(hook: String) -> Array:
	if not _hooks.has(hook):
		return []
	return Array(_hooks[hook]).duplicate(true)


func clear() -> void:
	for hook in _hooks:
		_hooks[hook].clear()
