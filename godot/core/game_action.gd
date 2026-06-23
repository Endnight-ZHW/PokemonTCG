class_name GameAction
extends RefCounted

var action: String
var params: Dictionary
var terminal: bool
var actor: int
var source: EntityRef
var target: EntityRef
var action_id: String


func _init(
	p_action: String = "",
	p_params: Dictionary = {},
	p_terminal: bool = false,
	p_actor: int = -1,
	p_source: EntityRef = null,
	p_target: EntityRef = null,
	p_action_id: String = "",
) -> void:
	action = p_action
	params = p_params.duplicate(true)
	terminal = p_terminal
	actor = p_actor
	source = p_source
	target = p_target
	action_id = p_action_id


func to_dict() -> Dictionary:
	return {
		"action": action,
		"params": params.duplicate(true),
		"terminal": terminal,
		"actor": actor,
		"source": source.to_dict() if source else null,
		"target": target.to_dict() if target else null,
		"action_id": action_id,
	}


static func from_dict(data: Dictionary) -> GameAction:
	return GameAction.new(
		str(data.get("action", "")),
		Dictionary(data.get("params", {})),
		bool(data.get("terminal", false)),
		int(data.get("actor", -1)),
		EntityRef.from_dict(data["source"]) if data.get("source") is Dictionary else null,
		EntityRef.from_dict(data["target"]) if data.get("target") is Dictionary else null,
		str(data.get("action_id", "")),
	)
