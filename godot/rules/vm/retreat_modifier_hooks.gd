class_name VMRetreatModifierHooks
extends RefCounted


static func effective_retreat_cost(
	state: GameState,
	catalog: CardCatalog,
	player: PlayerState,
) -> int:
	if player.active == null:
		return 0
	var base_cost := int(catalog.get_card(player.active.card_id).get("retreat_cost", 0))
	var manager := VMModifierManager.new()
	_register_can_retreat_hooks(manager, state, catalog, player)
	var cost := base_cost
	for descriptor in manager.descriptors_for(VMModifierManager.CAN_RETREAT):
		cost = _apply_descriptor(catalog, player, cost, descriptor)
	for hook_value in manager.hooks_for(VMModifierManager.CAN_RETREAT):
		var hook: Dictionary = hook_value
		cost = _apply_can_retreat_hook(state, catalog, player, cost, hook)
	return max(0, cost)


static func _register_can_retreat_hooks(
	manager: VMModifierManager,
	state: GameState,
	catalog: CardCatalog,
	player: PlayerState,
) -> void:
	var active := player.active
	if active == null:
		return
	var owner_player := _player_index(state, player)
	for ability_value in catalog.get_card(active.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		for effect_value in VMRuntimeEffects.strict_ability_effects(ability):
			var effect: Dictionary = effect_value
			if not VMRuntimeEffects.effect_matches(effect, "conditional_zero_retreat"):
				continue
			manager.register_hook(
				VMModifierManager.CAN_RETREAT,
				"conditional_zero_retreat",
				owner_player,
				0,
				{
					"kind": "conditional_zero_retreat",
					"params": VMRuntimeEffects.effect_args(effect),
				},
			)
	for modifier_value in active.modifiers:
		var modifier: Dictionary = modifier_value
		if VMModifierDescriptorRegistry.shared().validation_error(modifier).is_empty():
			if str(modifier.get("hook", "")) == VMModifierManager.CAN_RETREAT:
				manager.register_descriptor(modifier)
			continue
		if str(modifier.get("modifier_kind", modifier.get("effect_type", ""))) != "conditional_zero_retreat":
			continue
		manager.register_hook(
			VMModifierManager.CAN_RETREAT,
			str(modifier.get("source", "conditional_zero_retreat")),
			owner_player,
			0,
			{
				"kind": "conditional_zero_retreat",
				"params": Dictionary(modifier.get("params", {})).duplicate(true),
			},
		)
	if state.stadium_card_id.is_empty() or not catalog.is_basic_pokemon(active.card_id):
		return
	for effect_value in VMRuntimeEffects.strict_trainer_effects(
		catalog.get_card(state.stadium_card_id),
		"trainer:%s" % state.stadium_card_id,
	):
		var effect: Dictionary = effect_value
		var params := VMRuntimeEffects.effect_args(effect)
		if (
			not VMRuntimeEffects.effect_matches(effect, "stadium")
			or str(params.get("effect", "")) != "reduce_retreat_cost_basics"
		):
			continue
		manager.register_hook(
			VMModifierManager.CAN_RETREAT,
			state.stadium_card_id,
			owner_player,
			0,
			{
				"kind": "stadium_reduce_retreat_cost_basics",
				"amount": int(params.get("amount", 1)),
			},
		)


static func _apply_can_retreat_hook(
	_state: GameState,
	catalog: CardCatalog,
	player: PlayerState,
	cost: int,
	hook: Dictionary,
) -> int:
	var active := player.active
	if active == null:
		return cost
	var payload: Dictionary = hook.get("payload", {})
	match str(payload.get("kind", "")):
		"conditional_zero_retreat":
			var params: Dictionary = payload.get("params", {})
			if _has_required_energy(active, catalog, str(params.get("energy_type", ""))):
				return 0
		"stadium_reduce_retreat_cost_basics":
			return max(0, cost - int(payload.get("amount", 1)))
	return cost


static func _apply_descriptor(
	catalog: CardCatalog,
	player: PlayerState,
	cost: int,
	descriptor: Dictionary,
) -> int:
	var active := player.active
	if active == null:
		return cost
	var condition: Dictionary = descriptor.get("condition", {})
	var required_energy := str(condition.get("energy_type", ""))
	if not required_energy.is_empty() and not _has_required_energy(active, catalog, required_energy):
		return cost
	var operation: Dictionary = descriptor.get("operation", {})
	match str(operation.get("kind", "")):
		"retreat_delta":
			return cost + int(operation.get("amount", 0))
		"retreat_set":
			return int(operation.get("value", cost))
	return cost


static func _has_required_energy(
	pokemon: PokemonState,
	catalog: CardCatalog,
	required_type: String,
) -> bool:
	var required := required_type.to_lower()
	if required.is_empty():
		return true
	for provided in EnergyView.units_for_cards(pokemon.energy_card_ids, catalog):
		if str(provided).to_lower() in [required, "rainbow"]:
			return true
	return false


static func _player_index(state: GameState, player: PlayerState) -> int:
	for index in range(state.players.size()):
		if state.players[index] == player:
			return index
	return -1
