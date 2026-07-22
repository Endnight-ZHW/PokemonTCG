class_name CardSemanticCatalog
extends RefCounted

const BELIEF_SAMPLING_OPS := {
	"draw_and_attach_energy": true,
	"look_top_attach_energy": true,
	"look_top_deck": true,
	"mill_then_damage": true,
	"trekking_shoes": true,
}

## Safe, compact card meanings for planners and deck strategies.
##
## Only explicit public card fields and compiled VM commands are projected.
## Raw effect text, legacy effects, art metadata, weaknesses and resistances are
## deliberately absent. VM arguments are allow-listed by the frozen command
## descriptor and then recursively redacted.

const FORBIDDEN_FIELD_PARTS: Array[String] = [
	"weakness",
	"resistance",
	"type_matchup",
]

var _catalog: CardCatalog
var _cache: Dictionary = {}


func _init(catalog: CardCatalog = null) -> void:
	_catalog = catalog if catalog != null else CardCatalog.shared()


func has_card(card_id: String) -> bool:
	return _catalog.cards.has(card_id)


func semantics_for(card_id: String) -> Dictionary:
	if _cache.has(card_id):
		return _cache[card_id]
	var source := _catalog.get_card(card_id)
	var result: Dictionary
	if source.is_empty():
		result = {
			"card_id": card_id,
			"known": false,
			"semantic_kinds": [],
		}
	else:
		result = _build_card_semantics(card_id, source)
	_deep_make_read_only(result)
	_cache[card_id] = result
	return result


func attack_semantics(card_id: String, attack_index: int) -> Dictionary:
	var attacks: Array = semantics_for(card_id).get("attacks", [])
	if attack_index < 0 or attack_index >= attacks.size():
		return {}
	return attacks[attack_index]


func ability_semantics(card_id: String, ability_name: String) -> Dictionary:
	for ability_value in semantics_for(card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("name", "")) == ability_name:
			return ability
	return {}


func semantic_kinds_for(card_id: String) -> Array[String]:
	var result: Array[String] = []
	result.assign(semantics_for(card_id).get("semantic_kinds", []))
	return result


func _build_card_semantics(card_id: String, source: Dictionary) -> Dictionary:
	var attacks: Array[Dictionary] = []
	var abilities: Array[Dictionary] = []
	var semantic_kinds: Array[String] = []
	var source_attacks: Array = source.get("attacks", [])
	for index in range(source_attacks.size()):
		if not source_attacks[index] is Dictionary:
			continue
		var attack: Dictionary = source_attacks[index]
		var commands := _semantic_commands(attack.get("compiled_effects", []))
		_append_command_kinds(semantic_kinds, commands)
		var base_damage := int(attack.get("damage", 0))
		attacks.append({
			"index": index,
			"name": str(attack.get("name", "")),
			"cost": _string_array(attack.get("cost", [])),
			"converted_energy_cost": int(attack.get(
				"converted_energy_cost", Array(attack.get("cost", [])).size())),
			"base_damage": base_damage,
			"expected_damage": _expected_attack_damage(base_damage, commands),
			"has_random_effect": _commands_have_random_effect(commands),
			"commands": commands,
		})
	for ability_value in source.get("abilities", []):
		if not ability_value is Dictionary:
			continue
		var ability: Dictionary = ability_value
		var commands := _semantic_commands(ability.get("compiled_effects", []))
		_append_command_kinds(semantic_kinds, commands)
		abilities.append({
			"name": str(ability.get("name", "")),
			"ability_type": str(ability.get("ability_type", "")),
			"trigger": str(ability.get("trigger", "")),
			"commands": commands,
		})
	var trainer_commands := _semantic_commands(source.get("compiled_trainer_effects", []))
	_append_command_kinds(semantic_kinds, trainer_commands)
	var energy_semantics := _safe_energy_effects(source.get("energy_effects", []))
	for effect_value in energy_semantics:
		var effect: Dictionary = effect_value
		var kind := str(effect.get("kind", ""))
		if not kind.is_empty() and kind not in semantic_kinds:
			semantic_kinds.append(kind)
	semantic_kinds.sort()
	return {
		"card_id": card_id,
		"known": true,
		"name": str(source.get("name", card_id)),
		"supertype": str(source.get("supertype", "")),
		"subtypes": _string_array(source.get("subtypes", [])),
		"hp": int(source.get("hp", 0)),
		"prize_value": _catalog.prize_value(card_id),
		"retreat_cost": int(source.get("retreat_cost", 0)),
		"energy_types": _string_array(source.get("energy_types", [])),
		"provides_energy": _catalog.provides_energy(card_id),
		"evolves_from": str(source.get("evolves_from", "")),
		"evolves_to": _string_array(source.get("evolves_to", [])),
		"trainer_type": str(source.get("trainer_type", "")),
		"attacks": attacks,
		"abilities": abilities,
		"trainer_commands": trainer_commands,
		"energy_semantics": energy_semantics,
		"semantic_kinds": semantic_kinds,
	}


static func _semantic_commands(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not value is Array:
		return result
	for command_value in value:
		if not command_value is Dictionary:
			continue
		var projected := _semantic_command(command_value)
		if not projected.is_empty():
			result.append(projected)
	return result


static func _semantic_command(command: Dictionary) -> Dictionary:
	var op := str(command.get("op", ""))
	if op.is_empty() or _field_is_forbidden(op):
		return {}
	var descriptor := VMContract.command_descriptor(op)
	var semantic_kind := VMContract.command_semantic_kind(op)
	if descriptor.is_empty() or semantic_kind.is_empty() or _field_is_forbidden(semantic_kind):
		return {}
	var raw_args := Dictionary(command.get("args", {}))
	var args: Dictionary = {}
	var args_schema := Dictionary(descriptor.get("args_schema", {}))
	var allowed_args := Dictionary(args_schema.get("properties", {}))
	for key_value in allowed_args:
		var key := str(key_value)
		if not raw_args.has(key) or _field_is_forbidden(key):
			continue
		args[key] = _safe_value(raw_args[key], 0)
	var branches: Dictionary = {}
	var raw_branches := Dictionary(command.get("branches", {}))
	var branch_schema := Dictionary(descriptor.get("branch_schema", {}))
	for key_value in branch_schema.get("allowed_keys", []):
		var key := str(key_value)
		if raw_branches.has(key) and not _field_is_forbidden(key):
			branches[key] = _safe_branch_value(raw_branches[key], 0)
	return {
		"op": op,
		"semantic_kind": semantic_kind,
		"attack_timing": VMContract.command_attack_timing(op),
		"preflight": VMContract.command_preflight_evaluator(op),
		"may_suspend": bool(descriptor.get("may_suspend", false)),
		"replaces_base_damage": VMContract.command_replaces_base_damage(op, raw_args),
		"args": args,
		"branches": branches,
	}


static func _safe_branch_value(value: Variant, depth: int) -> Variant:
	if depth >= 12:
		return null
	if value is Dictionary and Dictionary(value).has("op"):
		return _semantic_command(Dictionary(value))
	if value is Array:
		var result: Array = []
		for nested in value:
			var projected: Variant = _safe_branch_value(nested, depth + 1)
			if projected != null:
				result.append(projected)
		return result
	return _safe_value(value, depth + 1)


static func _safe_value(value: Variant, depth: int) -> Variant:
	if depth >= 12:
		return null
	if value is Dictionary:
		var result: Dictionary = {}
		var dictionary: Dictionary = value
		for key_value in dictionary:
			var key := str(key_value)
			if _field_is_forbidden(key):
				continue
			result[key] = _safe_value(dictionary[key_value], depth + 1)
		return result
	if value is Array:
		var result: Array = []
		for nested in value:
			result.append(_safe_value(nested, depth + 1))
		return result
	if value is String or value is StringName:
		return null if _field_is_forbidden(str(value)) else value
	if value is bool or value is int or value is float:
		return value
	return null


static func _safe_energy_effects(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not value is Array:
		return result
	for effect_value in value:
		if not effect_value is Dictionary:
			continue
		var effect: Dictionary = effect_value
		var projected: Dictionary = {}
		for key in [
			"kind", "types", "downgrade_if_other_special", "hook", "priority",
			"scope", "effect",
		]:
			if effect.has(key) and not _field_is_forbidden(key):
				projected[key] = _safe_value(effect[key], 0)
		if not projected.is_empty():
			result.append(projected)
	return result


static func _append_command_kinds(target: Array[String], commands: Array[Dictionary]) -> void:
	for command in commands:
		var kind := str(command.get("semantic_kind", ""))
		if not kind.is_empty() and kind not in target:
			target.append(kind)


static func _commands_have_random_effect(commands: Array) -> bool:
	return commands_require_belief_sampling(commands)


static func commands_require_belief_sampling(commands_value: Variant) -> bool:
	if not commands_value is Array:
		return false
	for command in commands_value:
		if not command is Dictionary:
			continue
		var op := str(command.get("op", ""))
		if (
			op.begins_with("flip_coin")
			or op == "flip_until_tails"
			or BELIEF_SAMPLING_OPS.has(op)
		):
			return true
		for branch_value in Dictionary(command.get("branches", {})).values():
			if commands_require_belief_sampling(branch_value):
				return true
	return false


static func _expected_attack_damage(
	base_damage: int,
	commands: Array,
) -> float:
	var expected := float(base_damage)
	for command in commands:
		if not command is Dictionary:
			continue
		var op := str(command.get("op", ""))
		var args := Dictionary(command.get("args", {}))
		match op:
			"flip_coin_repeat_damage":
				expected = (
					float(args.get("flips", 0))
					* 0.5
					* float(args.get("damage_per_head", 0))
				)
			"flip_until_tails":
				# A fair geometric sequence has one expected head before tails.
				expected = float(args.get("per_head", 0))
	return expected


static func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if value is Array:
		for item in value:
			result.append(str(item))
	return result


static func _field_is_forbidden(field: String) -> bool:
	var normalized := field.to_lower().replace("-", "_").replace(" ", "_")
	for part in FORBIDDEN_FIELD_PARTS:
		if part in normalized:
			return true
	return false


static func contains_forbidden_field(value: Variant) -> bool:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for key_value in dictionary:
			if _field_is_forbidden(str(key_value)):
				return true
			if contains_forbidden_field(dictionary[key_value]):
				return true
	elif value is Array:
		for nested in value:
			if contains_forbidden_field(nested):
				return true
	elif value is String or value is StringName:
		return _field_is_forbidden(str(value))
	return false


static func _deep_make_read_only(value: Variant) -> void:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for nested_value in dictionary.values():
			_deep_make_read_only(nested_value)
		dictionary.make_read_only()
	elif value is Array:
		var array: Array = value
		for nested_value in array:
			_deep_make_read_only(nested_value)
		array.make_read_only()
