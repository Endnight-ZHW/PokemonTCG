class_name EnergyDistributionModel
extends RefCounted

## A local draft. Values are the original public option IDs, never invented actions.
var request: ChoiceView
var card_ids: Array[String] = []
var current_index := -1
var assignments: Dictionary = {}
var _options_by_index: Dictionary = {}
var _target_by_option: Dictionary = {}
var _index_by_option: Dictionary = {}
var _history: Array[Dictionary] = []


func configure(value: ChoiceView, view: Dictionary) -> void:
	request = value
	card_ids.assign(view.get("card_ids", []))
	assignments.clear()
	_history.clear()
	_options_by_index.clear()
	_target_by_option.clear()
	_index_by_option.clear()
	for target_value in view.get("targets", []):
		var target := Dictionary(target_value)
		var key := str(target.get("target_key", ""))
		var indexed := Dictionary(target.get("option_ids_by_energy_index", {}))
		for index in range(card_ids.size()):
			var id := str(indexed.get(index, indexed.get(str(index), target.get("fallback_option_id", ""))))
			if id.is_empty():
				continue
			if not _options_by_index.has(index):
				_options_by_index[index] = {}
			_options_by_index[index][key] = id
			_target_by_option[id] = key
			if indexed.has(index) or indexed.has(str(index)):
				_index_by_option[id] = index
	current_index = _next_unassigned()


func select_energy(index: int) -> bool:
	if index < 0 or index >= card_ids.size() or Dictionary(_options_by_index.get(index, {})).is_empty():
		return false
	current_index = index
	return true


func option_for(index: int, target: String) -> String:
	return str(Dictionary(_options_by_index.get(index, {})).get(target, ""))


func response_ids() -> Array[String]:
	var result: Array[String] = []
	for index in range(card_ids.size()):
		if assignments.has(index):
			result.append(str(assignments[index]))
	return result


func import_ids(ids: Array[String]) -> void:
	assignments.clear()
	_history.clear()
	for position in range(ids.size()):
		var id := ids[position]
		var index := int(_index_by_option.get(id, position))
		if _target_by_option.has(id) and index >= 0 and index < card_ids.size():
			assignments[index] = id
	current_index = _next_unassigned()


func blocked_reason(option_id: String) -> String:
	var index := int(_index_by_option.get(option_id, current_index))
	if index < 0 or index >= card_ids.size() or not _target_by_option.has(option_id):
		return "请先选择要分配或改派的能量"
	var candidate := _candidate(index, option_id)
	if candidate.is_empty():
		return "此共同目标无法接收所有已分配能量"
	return _validate(candidate)


func assign(option_id: String) -> String:
	var reason := blocked_reason(option_id)
	if not reason.is_empty():
		return reason
	var index := int(_index_by_option.get(option_id, current_index))
	var candidate := _candidate(index, option_id)
	if candidate != assignments:
		_checkpoint()
		assignments = candidate
	current_index = _next_unassigned()
	return ""


func remove_current() -> bool:
	if not assignments.has(current_index):
		return false
	_checkpoint()
	assignments.erase(current_index)
	return true


func clear_assignments() -> bool:
	if assignments.is_empty():
		return false
	_checkpoint()
	assignments.clear()
	current_index = _next_unassigned()
	return true


func undo() -> bool:
	if _history.is_empty():
		return false
	var previous: Dictionary = _history.pop_back()
	assignments = previous.assignments
	current_index = int(previous.current_index)
	return true


func can_undo() -> bool:
	return not _history.is_empty()


func is_complete() -> bool:
	return request != null and assignments.size() >= request.min_select and _validate(assignments).is_empty()


func _candidate(index: int, option_id: String) -> Dictionary:
	var result := assignments.duplicate()
	result[index] = option_id
	if bool(request.presentation.get("same_target", false)):
		var target := str(_target_by_option[option_id])
		for assigned_index in result:
			var replacement := option_for(int(assigned_index), target)
			if replacement.is_empty():
				return {}
			result[assigned_index] = replacement
	return result


func _validate(candidate: Dictionary) -> String:
	if candidate.size() > request.max_select:
		return "最多分配 %d 张能量，请先移除一张分配" % request.max_select
	var counts: Dictionary = {}
	var used_ids: Array[String] = []
	var same_target := ""
	for index in candidate:
		var id := str(candidate[index])
		var target := str(_target_by_option.get(id, ""))
		if target.is_empty() or option_for(int(index), target) != id:
			return "该能量或目标已失效，请重新选择"
		if not request.allow_duplicates and id in used_ids:
			return "此效果不能重复选择同一选项"
		used_ids.append(id)
		if bool(request.presentation.get("same_target", false)) and not same_target.is_empty() and target != same_target:
			return "此效果要求所有能量分配到同一目标"
		same_target = target
		counts[target] = int(counts.get(target, 0)) + 1
		var maximum := int(request.presentation.get("max_per_target", 99))
		if int(counts[target]) > maximum:
			return "该目标最多可分配 %d 张能量" % maximum
	return ""


func _next_unassigned() -> int:
	if assignments.size() >= request.max_select:
		return -1
	for index in range(card_ids.size()):
		if not assignments.has(index) and not Dictionary(_options_by_index.get(index, {})).is_empty():
			return index
	return -1


func _checkpoint() -> void:
	_history.append({"assignments": assignments.duplicate(), "current_index": current_index})
