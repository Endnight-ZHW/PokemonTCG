class_name VMPokemonStatHooks
extends RefCounted

const TOOL_HP_BOOST := 50


static func current_hp(pokemon: PokemonState, catalog: CardCatalog) -> int:
	if pokemon == null:
		return 0
	var max_hp := int(catalog.get_card(pokemon.card_id).get("hp", 0))
	var manager := VMModifierManager.new()
	_register_max_hp_hooks(manager, pokemon, catalog)
	for descriptor in manager.descriptors_for(VMModifierManager.MAX_HP):
		max_hp = _apply_descriptor(pokemon, catalog, max_hp, descriptor)
	for hook_value in manager.hooks_for(VMModifierManager.MAX_HP):
		var hook: Dictionary = hook_value
		max_hp = _apply_max_hp_hook(pokemon, catalog, max_hp, hook)
	return max(0, max_hp - pokemon.damage_counters * 10)


static func _register_max_hp_hooks(
	manager: VMModifierManager,
	pokemon: PokemonState,
	catalog: CardCatalog,
) -> void:
	if not pokemon.attached_tool_id.is_empty():
		for effect_value in VMRuntimeEffects.strict_trainer_effects(
			catalog.get_card(pokemon.attached_tool_id),
			"trainer:%s" % pokemon.attached_tool_id,
		):
			var effect: Dictionary = effect_value
			var params := VMRuntimeEffects.effect_args(effect)
			if (
				not VMRuntimeEffects.effect_matches(effect, "tool")
				or str(params.get("effect", "")) != "hp_boost_basic"
			):
				continue
			var tool_amount := int(params.get("amount", TOOL_HP_BOOST))
			if _has_equivalent_hp_descriptor(
				pokemon,
				pokemon.card_id,
				tool_amount,
				{"target_basic": true},
			):
				continue
			manager.register_hook(
				VMModifierManager.MAX_HP,
				pokemon.attached_tool_id,
				-1,
				0,
				{
					"kind": "hp_boost_basic",
					"amount": tool_amount,
				},
			)
	for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		for effect_value in VMRuntimeEffects.strict_ability_effects(ability):
			var effect: Dictionary = effect_value
			if not VMRuntimeEffects.effect_matches(effect, "conditional_hp_boost"):
				continue
			var args := VMRuntimeEffects.effect_args(effect)
			var ability_condition := {
				"energy_type": str(args.get("energy_type", "")),
				"threshold": int(args.get("threshold", 0)),
			}
			if _has_equivalent_hp_descriptor(
				pokemon,
				pokemon.card_id,
				int(args.get("amount", 0)),
				ability_condition,
			):
				continue
			manager.register_hook(
				VMModifierManager.MAX_HP,
				"conditional_hp_boost",
				-1,
				0,
				{
					"kind": "conditional_hp_boost",
					"params": args,
				},
			)
	for modifier_value in pokemon.modifiers:
		var modifier: Dictionary = modifier_value
		if VMModifierDescriptorRegistry.shared().validation_error(modifier).is_empty():
			if str(modifier.get("hook", "")) == VMModifierManager.MAX_HP:
				manager.register_descriptor(modifier)
			continue
		if str(modifier.get("modifier_kind", modifier.get("effect_type", ""))) != "conditional_hp_boost":
			continue
		manager.register_hook(
			VMModifierManager.MAX_HP,
			str(modifier.get("source", "conditional_hp_boost")),
			-1,
			0,
			{
				"kind": "conditional_hp_boost",
				"params": Dictionary(modifier.get("params", {})).duplicate(true),
			},
		)


static func _apply_max_hp_hook(
	pokemon: PokemonState,
	catalog: CardCatalog,
	max_hp: int,
	hook: Dictionary,
) -> int:
	var payload: Dictionary = hook.get("payload", {})
	match str(payload.get("kind", "")):
		"hp_boost_basic":
			if catalog.is_basic_pokemon(pokemon.card_id):
				return max_hp + int(payload.get("amount", TOOL_HP_BOOST))
		"conditional_hp_boost":
			var params: Dictionary = payload.get("params", {})
			if _has_energy_threshold(
				pokemon,
				catalog,
				str(params.get("energy_type", "")),
				int(params.get("threshold", 0)),
			):
				return max_hp + int(params.get("amount", 0))
	return max_hp


static func _apply_descriptor(
	pokemon: PokemonState,
	catalog: CardCatalog,
	max_hp: int,
	descriptor: Dictionary,
) -> int:
	var condition: Dictionary = descriptor.get("condition", {})
	if bool(condition.get("target_basic", false)) and not catalog.is_basic_pokemon(pokemon.card_id):
		return max_hp
	if condition.has("energy_type") and not _has_energy_threshold(
		pokemon,
		catalog,
		str(condition.get("energy_type", "")),
		int(condition.get("threshold", 0)),
	):
		return max_hp
	var operation: Dictionary = descriptor.get("operation", {})
	if str(operation.get("kind", "")) == "hp_delta":
		return max_hp + int(operation.get("amount", 0))
	return max_hp


static func _has_energy_threshold(
	pokemon: PokemonState,
	catalog: CardCatalog,
	required_type: String,
	threshold: int,
) -> bool:
	var required := required_type.to_lower()
	if threshold <= 0:
		return true
	var matching := 0
	for provided in EnergyView.units_for_cards(pokemon.energy_card_ids, catalog):
		if str(provided).to_lower() in [required, "rainbow"]:
			matching += 1
	return matching >= threshold


static func _has_equivalent_hp_descriptor(
	pokemon: PokemonState,
	source_card_id: String,
	amount: int,
	condition: Dictionary,
) -> bool:
	for descriptor in pokemon.modifier_descriptors(VMModifierManager.MAX_HP):
		var operation: Dictionary = descriptor.get("operation", {})
		var source_ref: Dictionary = descriptor.get("source_ref", {})
		if (
			str(operation.get("kind", "")) == "hp_delta"
			and int(operation.get("amount", 0)) == amount
			and str(source_ref.get("card_id", "")) == source_card_id
			and Dictionary(descriptor.get("condition", {})) == condition
		):
			return true
	return false
