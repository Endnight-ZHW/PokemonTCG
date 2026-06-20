class_name ChoiceResponse
extends RefCounted

var request_id: String
var option_ids: Array[String]
var cancelled: bool


func _init(
	p_request_id: String = "",
	p_option_ids: Array[String] = [],
	p_cancelled: bool = false,
) -> void:
	request_id = p_request_id
	option_ids = p_option_ids.duplicate()
	cancelled = p_cancelled


func to_dict() -> Dictionary:
	return {
		"request_id": request_id,
		"option_ids": option_ids.duplicate(),
		"cancelled": cancelled,
	}


static func from_dict(data: Dictionary) -> ChoiceResponse:
	var ids: Array[String] = []
	for option_id in data.get("option_ids", []):
		ids.append(str(option_id))
	return ChoiceResponse.new(
		str(data.get("request_id", "")),
		ids,
		bool(data.get("cancelled", false)),
	)
