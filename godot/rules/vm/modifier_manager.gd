class_name VMModifierManager
extends RefCounted

const MODIFY_DAMAGE := "MODIFY_DAMAGE"
const AFTER_DAMAGE := "AFTER_DAMAGE"
const CAN_RETREAT := "CAN_RETREAT"
const MAX_HP := "MAX_HP"
const POKEMON_KO := "POKEMON_KO"
const ON_ATTACH := "ON_ATTACH"
const CAN_ATTACK := "CAN_ATTACK"
const PREVENT_EFFECTS := "PREVENT_EFFECTS"

const _LAYER_ORDER := {
	"base_replacement": 0,
	"base": 0,
	"attacker_adjust": 10,
	"weakness": 20,
	"resistance": 30,
	"defender_adjust": 40,
	"add": 10,
	"set": 20,
	"permission": 10,
	"gate": 20,
	"prevent": 50,
	"clamp": 60,
}

var _hooks: Dictionary = {}
var _descriptors: Dictionary = {}
var _sequence := 0
var _errors: Array[String] = []


func _init() -> void:
	for hook in [
		MODIFY_DAMAGE, AFTER_DAMAGE, CAN_RETREAT, MAX_HP, POKEMON_KO, ON_ATTACH,
		CAN_ATTACK, PREVENT_EFFECTS,
	]:
		_hooks[hook] = []
		_descriptors[hook] = []


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


func register_descriptor(value: Variant) -> bool:
	var error := VMModifierDescriptorRegistry.shared().validation_error(value)
	if not error.is_empty():
		_errors.append(error)
		return false
	var descriptor := Dictionary(value).duplicate(true)
	_sequence += 1
	descriptor["_sequence"] = _sequence
	var hook := str(descriptor["hook"])
	var stacking := str(descriptor.get("stacking", "stack"))
	var operation: Dictionary = descriptor.get("operation", {})
	var operation_kind := str(operation.get("kind", ""))
	var source_ref: Dictionary = descriptor.get("source_ref", {})
	if stacking in ["replace_same_source", "unique"]:
		var kept: Array = []
		for existing_value in _descriptors[hook]:
			var existing: Dictionary = existing_value
			var same_operation := str(Dictionary(
				existing.get("operation", {})).get("kind", "")) == operation_kind
			var same_source := Dictionary(existing.get("source_ref", {})) == source_ref
			if same_operation and (stacking == "unique" or same_source):
				continue
			kept.append(existing)
		_descriptors[hook] = kept
	elif stacking == "maximum":
		for index in range(_descriptors[hook].size() - 1, -1, -1):
			var existing: Dictionary = _descriptors[hook][index]
			if str(Dictionary(existing.get("operation", {})).get("kind", "")) != operation_kind:
				continue
			var existing_amount: int = abs(int(Dictionary(
				existing.get("operation", {})).get("amount", 0)))
			var candidate_amount: int = abs(int(operation.get("amount", 0)))
			if existing_amount >= candidate_amount:
				return true
			_descriptors[hook].remove_at(index)
	_descriptors[hook].append(descriptor)
	_descriptors[hook].sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_layer := int(_LAYER_ORDER.get(str(left.get("layer", "")), 999))
		var right_layer := int(_LAYER_ORDER.get(str(right.get("layer", "")), 999))
		if left_layer != right_layer:
			return left_layer < right_layer
		if int(left.get("priority", 0)) != int(right.get("priority", 0)):
			return int(left.get("priority", 0)) > int(right.get("priority", 0))
		return int(left.get("_sequence", 0)) < int(right.get("_sequence", 0))
	)
	return true


func descriptors_for(hook: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _descriptors.has(hook):
		return result
	for value in _descriptors[hook]:
		var descriptor := Dictionary(value).duplicate(true)
		descriptor.erase("_sequence")
		result.append(descriptor)
	return result


func errors() -> Array[String]:
	return _errors.duplicate()


func resolve_controller_choices(
	state: GameState,
	stack: ResolutionStack,
	hook: String,
	decision_id: String,
) -> Dictionary:
	if decision_id.is_empty():
		return VMResult.fail(
			"Modifier冲突缺少唯一决策标识。", "invalid_modifier_conflict_scope")
	if not _descriptors.has(hook):
		return VMResult.fail("未知Modifier hook。", "invalid_modifier_hook")
	if not _errors.is_empty():
		return VMResult.fail(
			"Modifier描述符无效：%s" % "; ".join(_errors),
			"invalid_modifier_descriptor",
		)
	var descriptors := descriptors_for(hook)
	var conflict_groups := _controller_choice_groups(descriptors, hook, decision_id)
	if conflict_groups.is_empty():
		return {"success": true, "descriptors": descriptors, "pending_choice": null}
	var resolutions: Dictionary = stack.context.get(
		"modifier_conflict_resolutions", {}).duplicate(true)
	var selected_indices: Dictionary = {}
	var conflicting_indices: Dictionary = {}
	for group_value in conflict_groups:
		var group: Dictionary = group_value
		for descriptor_index in group.get("descriptor_indices", []):
			conflicting_indices[int(descriptor_index)] = true
		var conflict_id := str(group.get("conflict_id", ""))
		var selected_option_id := str(resolutions.get(conflict_id, ""))
		if selected_option_id.is_empty():
			var request_result := _request_controller_choice(state, stack, group)
			if not bool(request_result.get("success", false)):
				return request_result
			return {
				"success": true,
				"descriptors": [],
				"pending_choice": request_result.get("pending_choice"),
			}
		var option_ids: Array = group.get("option_ids", [])
		var selected_local_index := option_ids.find(selected_option_id)
		if selected_local_index < 0:
			return VMResult.fail(
				"Modifier冲突选择与候选不一致。", "stale_modifier_conflict")
		var descriptor_indices: Array = group.get("descriptor_indices", [])
		selected_indices[int(descriptor_indices[selected_local_index])] = true
	var resolved: Array[Dictionary] = []
	for descriptor_index in range(descriptors.size()):
		if (
			conflicting_indices.has(descriptor_index)
			and not selected_indices.has(descriptor_index)
		):
			continue
		resolved.append(descriptors[descriptor_index].duplicate(true))
	return {"success": true, "descriptors": resolved, "pending_choice": null}


func _controller_choice_groups(
	descriptors: Array[Dictionary],
	hook: String,
	decision_id: String,
) -> Array[Dictionary]:
	var grouped: Dictionary = {}
	for descriptor_index in range(descriptors.size()):
		var descriptor: Dictionary = descriptors[descriptor_index]
		if str(descriptor.get("conflict_policy", "")) != "controller_choice":
			continue
		var group_key := "%s|%s|%d" % [
			hook,
			str(descriptor.get("layer", "")),
			int(descriptor.get("controller", -1)),
		]
		if not grouped.has(group_key):
			grouped[group_key] = []
		grouped[group_key].append(descriptor_index)
	var group_keys := grouped.keys()
	group_keys.sort()
	var result: Array[Dictionary] = []
	for group_key_value in group_keys:
		var group_key := str(group_key_value)
		var descriptor_indices: Array = grouped[group_key]
		if descriptor_indices.size() < 2:
			continue
		var first: Dictionary = descriptors[int(descriptor_indices[0])]
		var conflict_id := "%s|%s" % [decision_id, group_key]
		var option_ids: Array[String] = []
		for local_index in range(descriptor_indices.size()):
			option_ids.append("modifier:%s:%d" % [conflict_id, local_index])
		result.append({
			"conflict_id": conflict_id,
			"decision_id": decision_id,
			"hook": hook,
			"layer": str(first.get("layer", "")),
			"controller": int(first.get("controller", -1)),
			"descriptor_indices": descriptor_indices.duplicate(),
			"descriptors": _descriptors_at(descriptors, descriptor_indices),
			"option_ids": option_ids,
		})
	return result


func _request_controller_choice(
	state: GameState,
	stack: ResolutionStack,
	group: Dictionary,
) -> Dictionary:
	if stack.pending_request != null:
		return VMResult.fail(
			"已有规则选择等待响应。", "choice_already_pending")
	var descriptors: Array = group.get("descriptors", [])
	var option_ids: Array = group.get("option_ids", [])
	var options: Array[Dictionary] = []
	var candidates: Array[Dictionary] = []
	for index in range(descriptors.size()):
		var descriptor: Dictionary = descriptors[index]
		var source_ref: Dictionary = descriptor.get("source_ref", {})
		var option_id := str(option_ids[index])
		var source_card_id := str(source_ref.get("card_id", ""))
		options.append({
			"option_id": option_id,
			"label": source_card_id if not source_card_id.is_empty() else "Modifier %d" % (index + 1),
			"ref": source_ref.duplicate(true),
			"value": {"descriptor": descriptor.duplicate(true)},
		})
		candidates.append({
			"option_id": option_id,
			"descriptor": descriptor.duplicate(true),
		})
	stack.push_continuation("modifier_controller_choice", {
		"conflict_id": str(group.get("conflict_id", "")),
		"decision_id": str(group.get("decision_id", "")),
		"hook": str(group.get("hook", "")),
		"layer": str(group.get("layer", "")),
		"controller": int(group.get("controller", -1)),
		"candidates": candidates,
	})
	var stack_error := stack.validation_result()
	if not stack_error.is_empty():
		return stack_error
	var controller := int(group.get("controller", -1))
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, controller, "select_modifier_conflict"),
		"select_modifier_conflict",
		controller,
		"请选择要应用的替换效果。",
		options,
		1,
		1,
		false,
		false,
		{
			"revision": state.revision,
			"domain": "modifier",
			"purpose": "modifier_conflict",
			"source_player": controller,
			"hook": str(group.get("hook", "")),
		},
	)
	return {"success": true, "pending_choice": stack.pending_request}


static func continue_controller_choice(
	_state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	_events: Array[Dictionary],
) -> Dictionary:
	if selected.size() != 1:
		return VMResult.fail(
			"Modifier冲突必须选择一个候选。", "invalid_modifier_conflict_choice")
	var conflict_id := str(data.get("conflict_id", ""))
	var selected_option_id := str(selected[0].get("option_id", ""))
	var selected_descriptor: Variant = Dictionary(selected[0].get("value", {})).get("descriptor")
	if conflict_id.is_empty() or selected_option_id.is_empty():
		return VMResult.fail(
			"Modifier冲突续体缺少标识。", "invalid_modifier_conflict_choice")
	if (
		not selected_descriptor is Dictionary
		or not VMModifierDescriptorRegistry.shared().validation_error(selected_descriptor).is_empty()
	):
		return VMResult.fail(
			"Modifier冲突候选描述符无效。", "invalid_modifier_descriptor")
	var matched := false
	for candidate_value in data.get("candidates", []):
		if not candidate_value is Dictionary:
			return VMResult.fail(
				"Modifier冲突续体候选无效。", "invalid_modifier_conflict_choice")
		var candidate: Dictionary = candidate_value
		if str(candidate.get("option_id", "")) != selected_option_id:
			continue
		matched = (
			candidate.get("descriptor") is Dictionary
			and Dictionary(candidate["descriptor"]) == Dictionary(selected_descriptor)
		)
		break
	if not matched:
		return VMResult.fail(
			"Modifier冲突选择已过期。", "stale_modifier_conflict")
	var resolutions: Dictionary = stack.context.get(
		"modifier_conflict_resolutions", {}).duplicate(true)
	resolutions[conflict_id] = selected_option_id
	stack.context["modifier_conflict_resolutions"] = resolutions
	return VMResult.ok("已选择替换效果。")


static func _descriptors_at(
	descriptors: Array[Dictionary],
	indices: Array,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index_value in indices:
		result.append(descriptors[int(index_value)].duplicate(true))
	return result


static func descriptor(
	hook: String,
	layer: String,
	priority: int,
	controller: int,
	source_ref: Dictionary,
	scope: String,
	duration: String,
	stacking: String,
	condition: Dictionary,
	operation: Dictionary,
	conflict_policy: String = "commutative",
) -> Dictionary:
	return {
		"hook": hook,
		"layer": layer,
		"priority": priority,
		"controller": controller,
		"source_ref": source_ref.duplicate(true),
		"scope": scope,
		"duration": duration,
		"stacking": stacking,
		"conflict_policy": conflict_policy,
		"condition": condition.duplicate(true),
		"operation": operation.duplicate(true),
	}


static func source_pokemon_ref(
	player_idx: int,
	slot: String,
	card_id: String,
) -> Dictionary:
	return EntityRef.new("pokemon", player_idx, "", slot, -1, "", card_id).to_dict()


static func source_attachment_ref(
	player_idx: int,
	slot: String,
	attachment_type: String,
	index: int,
	card_id: String,
) -> Dictionary:
	return EntityRef.new(
		"attachment", player_idx, "", slot, index, attachment_type, card_id).to_dict()


func hooks_for(hook: String) -> Array:
	if not _hooks.has(hook):
		return []
	return Array(_hooks[hook]).duplicate(true)


func clear() -> void:
	for hook in _hooks:
		_hooks[hook].clear()
	for hook in _descriptors:
		_descriptors[hook].clear()
	_errors.clear()
