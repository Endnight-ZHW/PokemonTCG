class_name VMRuntimeEffects
extends RefCounted

static func trainer_effects(card: Dictionary) -> Array:
	return strict_trainer_effects(
		card, "trainer:%s" % str(card.get("id", card.get("card_id", ""))))


static func ability_effects(ability: Dictionary) -> Array:
	return strict_ability_effects(ability)


static func attack_effects(attack: Dictionary) -> Array:
	return strict_attack_effects(attack)


static func strict_trainer_effects(card: Dictionary, source: String) -> Array:
	return strict_runtime_effects(card, "trainer_effects", "compiled_trainer_effects", source)


static func strict_ability_effects(ability: Dictionary) -> Array:
	return strict_runtime_effects(
		ability, "effects", "compiled_effects",
		"ability:%s" % str(ability.get("name", "")))


static func strict_attack_effects(attack: Dictionary) -> Array:
	return strict_runtime_effects(
		attack, "effects", "compiled_effects",
		"attack:%s" % str(attack.get("name", "")))


static func strict_runtime_effects(
	owner: Dictionary,
	legacy_key: String,
	compiled_key: String,
	source: String,
) -> Array:
	var compiled: Array = owner.get(compiled_key, [])
	if not compiled.is_empty():
		return compiled
	var raw: Array = owner.get(legacy_key, [])
	if raw.is_empty():
		return []
	return [missing_compiled_effect(source)]


static func missing_compiled_effect(source: String) -> Dictionary:
	return {
		"op": "__missing_compiled_effect__",
		"args": {"source": source},
		"branches": {},
	}


static func effect_list(effects: Variant) -> Array:
	var result: Array = []
	if effects is Array:
		result = effects
	elif effects is Dictionary:
		result.append(effects)
	return result


static func effect_kind(effect: Dictionary) -> String:
	return VMContract.command_semantic_kind(str(effect.get("op", "")))


static func effect_args(effect: Dictionary) -> Dictionary:
	return Dictionary(effect.get("args", {})).duplicate(true)


static func effect_matches(effect: Dictionary, kind: String) -> bool:
	return effect_kind(effect) == kind


static func availability_effect_kind(effect: Dictionary) -> String:
	var op := str(effect.get("op", ""))
	var semantic_kind := VMContract.command_semantic_kind(op)
	if semantic_kind == "switch":
		if str(availability_effect_params(effect).get("target", "self")) == "opponent":
			return "switch_opponent"
		return "switch_self"
	return semantic_kind


static func availability_effect_params(effect: Dictionary) -> Dictionary:
	var params: Dictionary = {}
	var args: Variant = effect.get("args", {})
	if args is Dictionary:
		for key in Dictionary(args):
			params[key] = Dictionary(args)[key]
	var branches: Variant = effect.get("branches", {})
	if branches is Dictionary:
		for key in Dictionary(branches):
			if not params.has(key):
				params[key] = Dictionary(branches)[key]
	return params


static func replaces_attack_base_damage(effect: Dictionary) -> bool:
	var op := str(effect.get("op", ""))
	return VMContract.command_replaces_base_damage(
		op,
		availability_effect_params(effect),
	)
