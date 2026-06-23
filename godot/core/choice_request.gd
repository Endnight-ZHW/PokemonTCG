class_name ChoiceRequest
extends RefCounted

var request_id: String
var request_type: String
var player: int
var prompt: String
var options: Array[Dictionary]
var min_select: int
var max_select: int
var allow_duplicates: bool
var can_cancel: bool
var metadata: Dictionary


func _init(
	p_request_id: String = "",
	p_request_type: String = "",
	p_player: int = 0,
	p_prompt: String = "",
	p_options: Array[Dictionary] = [],
	p_min_select: int = 1,
	p_max_select: int = 1,
	p_allow_duplicates: bool = false,
	p_can_cancel: bool = false,
	p_metadata: Dictionary = {},
) -> void:
	request_id = p_request_id
	request_type = p_request_type
	player = p_player
	prompt = p_prompt
	options = p_options.duplicate(true)
	min_select = p_min_select
	max_select = p_max_select
	allow_duplicates = p_allow_duplicates
	can_cancel = p_can_cancel
	metadata = p_metadata.duplicate(true)


func to_dict() -> Dictionary:
	return {
		"request_id": request_id,
		"request_type": request_type,
		"player": player,
		"prompt": prompt,
		"options": options.duplicate(true),
		"min_select": min_select,
		"max_select": max_select,
		"allow_duplicates": allow_duplicates,
		"can_cancel": can_cancel,
		"metadata": metadata.duplicate(true),
	}


static func from_dict(data: Dictionary) -> ChoiceRequest:
	var raw_options: Array[Dictionary] = []
	for option in data.get("options", []):
		raw_options.append(Dictionary(option))
	return ChoiceRequest.new(
		str(data.get("request_id", "")),
		str(data.get("request_type", "")),
		int(data.get("player", 0)),
		str(data.get("prompt", "")),
		raw_options,
		int(data.get("min_select", 1)),
		int(data.get("max_select", 1)),
		bool(data.get("allow_duplicates", false)),
		bool(data.get("can_cancel", false)),
		Dictionary(data.get("metadata", {})),
	)
