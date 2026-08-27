class_name ChoiceFlowController
extends RefCounted

var selected_ids: Array[String] = []


func replace(values: Array[String]) -> void:
	selected_ids.assign(values)


func clear() -> void:
	selected_ids.clear()


func response(request: ChoiceView, cancelled: bool = false) -> ChoiceResponse:
	if request == null:
		return null
	return ChoiceResponse.new(request.request_id, selected_ids.duplicate(), cancelled)
