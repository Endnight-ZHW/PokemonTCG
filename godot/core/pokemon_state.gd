class_name PokemonState
extends RefCounted

var card_id: String
var damage_counters := 0
var energy_card_ids: Array[String] = []
var attached_tool_id := ""
var status_conditions: Array[String] = []
var evolution_stack_ids: Array[String] = []
var can_evolve_this_turn := true
var placed_this_turn := true
var used_abilities: Array[String] = []
var healed_this_turn := false
var modifiers: Array[Dictionary] = []
var paralyzed_since_turn := 0


func _init(p_card_id: String = "") -> void:
	card_id = p_card_id


func current_hp(catalog: CardCatalog) -> int:
	return VMPokemonStatHooks.current_hp(self, catalog)


func is_knocked_out(catalog: CardCatalog) -> bool:
	return current_hp(catalog) <= 0


func available_energy(catalog: CardCatalog) -> Array[String]:
	return EnergyView.units_for_cards(energy_card_ids, catalog)


func has_enough_energy(cost: Array, catalog: CardCatalog) -> bool:
	return EnergyView.can_pay_cost(energy_card_ids, cost, catalog)


func register_modifier(descriptor: Dictionary) -> String:
	var error := VMModifierDescriptorRegistry.shared().validation_error(descriptor)
	if not error.is_empty():
		return error
	var candidate := descriptor.duplicate(true)
	var stacking := str(candidate.get("stacking", "stack"))
	var operation: Dictionary = candidate.get("operation", {})
	var operation_kind := str(operation.get("kind", ""))
	var source_ref: Dictionary = candidate.get("source_ref", {})
	if stacking in ["replace_same_source", "unique"]:
		var kept: Array[Dictionary] = []
		for existing_value in modifiers:
			var existing: Dictionary = existing_value
			var same_operation := str(Dictionary(
				existing.get("operation", {})).get("kind", "")) == operation_kind
			var same_source := Dictionary(existing.get("source_ref", {})) == source_ref
			if stacking == "unique" and same_operation:
				continue
			if stacking == "replace_same_source" and same_operation and same_source:
				continue
			kept.append(existing)
		modifiers = kept
	elif stacking == "maximum":
		for index in range(modifiers.size()):
			var existing: Dictionary = modifiers[index]
			if str(Dictionary(existing.get("operation", {})).get("kind", "")) != operation_kind:
				continue
			var existing_amount := int(Dictionary(existing.get("operation", {})).get("amount", 0))
			var candidate_amount := int(operation.get("amount", 0))
			if abs(existing_amount) >= abs(candidate_amount):
				return ""
			modifiers.remove_at(index)
			break
	modifiers.append(candidate)
	return ""


func modifier_descriptors(hook: String = "") -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in modifiers:
		var descriptor: Dictionary = value
		if not VMModifierDescriptorRegistry.shared().validation_error(descriptor).is_empty():
			continue
		if not hook.is_empty() and str(descriptor.get("hook", "")) != hook:
			continue
		result.append(descriptor.duplicate(true))
	return result


func has_modifier_operation(operation_kind: String, string_value: String = "") -> bool:
	for descriptor in modifier_descriptors():
		var operation: Dictionary = descriptor.get("operation", {})
		if str(operation.get("kind", "")) != operation_kind:
			continue
		if string_value.is_empty():
			return true
		if str(operation.get("attack_name", operation.get("reason", ""))) in [
			string_value, "__all__",
		]:
			return true
	return false


func modifier_operation_max(operation_kind: String, key: String = "amount") -> int:
	var result := 0
	for descriptor in modifier_descriptors():
		var operation: Dictionary = descriptor.get("operation", {})
		if str(operation.get("kind", "")) == operation_kind:
			result = maxi(result, int(operation.get(key, 0)))
	return result


func modifier_operation_sum(operation_kind: String, key: String = "amount") -> int:
	var result := 0
	for descriptor in modifier_descriptors():
		var operation: Dictionary = descriptor.get("operation", {})
		if str(operation.get("kind", "")) == operation_kind:
			result += int(operation.get(key, 0))
	return result


func remove_modifiers_with_duration(durations: Array[String]) -> void:
	var kept: Array[Dictionary] = []
	for descriptor in modifiers:
		if str(descriptor.get("duration", "")) not in durations:
			kept.append(descriptor)
	modifiers = kept


func consume_modifier_operation(operation_kind: String, string_value: String = "") -> bool:
	for index in range(modifiers.size()):
		var descriptor: Dictionary = modifiers[index]
		if not VMModifierDescriptorRegistry.shared().validation_error(descriptor).is_empty():
			continue
		var operation: Dictionary = descriptor.get("operation", {})
		if str(operation.get("kind", "")) != operation_kind:
			continue
		if (
			not string_value.is_empty()
			and str(operation.get("attack_name", operation.get("reason", ""))) not in [
				string_value, "__all__",
			]
		):
			continue
		modifiers.remove_at(index)
		return true
	return false


func prevents_damage() -> bool:
	return has_modifier_operation("prevent_damage")


func prevents_effects() -> bool:
	return has_modifier_operation("prevent_effects")


func attack_is_locked(attack_name: String = "") -> bool:
	return has_modifier_operation("attack_lock", attack_name)


func has_attack_gate(reason: String) -> bool:
	return has_modifier_operation("attack_gate_coin", reason)


func expire_modifiers_at_turn(turn_number: int) -> void:
	var kept: Array[Dictionary] = []
	for descriptor in modifiers:
		var condition: Dictionary = descriptor.get("condition", {})
		if (
			str(descriptor.get("duration", "")) in [
				"until_end_of_turn", "until_end_of_opponents_next_turn", "until_next_attack",
			]
			and int(condition.get("expires_after_turn", 2147483647)) <= turn_number
		):
			continue
		kept.append(descriptor)
	modifiers = kept


func clear_attack_effect_modifiers() -> void:
	var kept: Array[Dictionary] = []
	for descriptor in modifiers:
		var operation_kind := str(Dictionary(
			descriptor.get("operation", {})).get("kind", ""))
		if (
			str(descriptor.get("duration", "")) not in ["persistent", "until_leave_play"]
			and operation_kind in [
			"prevent_damage", "prevent_effects", "damage_delta", "attack_lock",
			"attack_gate_coin",
			]
		):
			continue
		kept.append(descriptor)
	modifiers = kept


func clear_special_conditions_and_attack_effects() -> void:
	# Evolving or moving an Active Pokemon to the Bench removes Special
	# Conditions and effects of attacks on that Pokemon. Card attachments,
	# damage, the evolution stack and persistent card modifiers remain.
	status_conditions.clear()
	paralyzed_since_turn = 0
	clear_attack_effect_modifiers()
	remove_modifiers_with_duration(["until_switch_or_evolve"])


func to_dict() -> Dictionary:
	var payload := {
		"card_id": card_id,
		"damage_counters": damage_counters,
		"energy_card_ids": energy_card_ids.duplicate(),
		"attached_tool_id": attached_tool_id,
		"status_conditions": status_conditions.duplicate(),
		"evolution_stack_ids": evolution_stack_ids.duplicate(),
		"can_evolve_this_turn": can_evolve_this_turn,
		"placed_this_turn": placed_this_turn,
		"used_abilities": used_abilities.duplicate(),
		"healed_this_turn": healed_this_turn,
		"paralyzed_since_turn": paralyzed_since_turn,
	}
	if not modifiers.is_empty():
		payload["modifiers"] = modifiers.duplicate(true)
	return payload


func clone_state() -> PokemonState:
	var result := PokemonState.new(card_id)
	result.damage_counters = damage_counters
	result.energy_card_ids.assign(energy_card_ids)
	result.attached_tool_id = attached_tool_id
	result.status_conditions.assign(status_conditions)
	result.evolution_stack_ids.assign(evolution_stack_ids)
	result.can_evolve_this_turn = can_evolve_this_turn
	result.placed_this_turn = placed_this_turn
	result.used_abilities.assign(used_abilities)
	result.healed_this_turn = healed_this_turn
	result.modifiers.assign(modifiers.duplicate(true))
	result.paralyzed_since_turn = paralyzed_since_turn
	return result


static func from_dict(data: Dictionary) -> PokemonState:
	var result := PokemonState.new(str(data.get("card_id", "")))
	result.damage_counters = int(data.get("damage_counters", 0))
	result.energy_card_ids.assign(data.get("energy_card_ids", []))
	result.attached_tool_id = str(data.get("attached_tool_id", ""))
	result.status_conditions.assign(data.get("status_conditions", []))
	result.evolution_stack_ids.assign(data.get("evolution_stack_ids", []))
	result.can_evolve_this_turn = bool(data.get("can_evolve_this_turn", true))
	result.placed_this_turn = bool(data.get("placed_this_turn", true))
	result.used_abilities.assign(data.get("used_abilities", []))
	result.healed_this_turn = bool(data.get("healed_this_turn", false))
	for modifier in data.get("modifiers", []):
		if modifier is Dictionary:
			result.modifiers.append(Dictionary(modifier).duplicate(true))
	result.paralyzed_since_turn = int(data.get("paralyzed_since_turn", 0))
	return result


static func modifier_wire_validation_error(value: Variant) -> String:
	return VMModifierDescriptorRegistry.shared().wire_validation_error(value)
