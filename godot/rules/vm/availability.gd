class_name VMAvailability
extends RefCounted

const TARGET_DAMAGE_EFFECT_TYPES: Array[String] = [
	"damage",
	"conditional_damage_bonus",
	"damage_per_discard_psychic",
	"damage_per_energy",
	"damage_per_evolved",
	"damage_per_hand_size",
	"damage_per_self_damage",
	"damage_per_self_energy",
	"damage_per_self_energy_type",
	"damage_plus_bench",
	"damage_self_penalty",
	"discard_fighting_energy_damage",
	"discard_hand_conditional_bonus",
	"damage_and_self_heal",
	"mill_and_damage_per_energy",
	"coin_flip_triple",
	"coin_flip_until_tails",
	"attack_damage_formula",
]

var catalog: CardCatalog


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func effects_have_legal_target(
	state: GameState,
	player_idx: int,
	effects: Variant,
	source_slot: String = "active",
	exclude_hand_index: int = -1,
	depth: int = 0,
) -> bool:
	if depth > 8:
		return false
	var effect_list := VMRuntimeEffects.effect_list(effects)
	if effect_list.is_empty():
		return true
	var player := state.get_player(player_idx)
	var opponent := state.get_player(1 - player_idx)
	var saw_checked_effect := false
	for effect_value in effect_list:
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value
		var effect_type := VMRuntimeEffects.availability_effect_kind(effect)
		if effect_type.is_empty():
			continue
		var params := VMRuntimeEffects.availability_effect_params(effect)
		if effect_type in TARGET_DAMAGE_EFFECT_TYPES:
			return opponent.active != null
		if _effect_is_always_usable(effect_type):
			return true
		match effect_type:
			"hand_to_bottom_draw", "houb":
				saw_checked_effect = true
				if _available_hand_count(player, exclude_hand_index) > 0:
					return true
			"zinnia_resolve":
				saw_checked_effect = true
				if _available_hand_count(player, exclude_hand_index) >= 2:
					return true
			"search":
				saw_checked_effect = true
				if _search_has_target(state, player_idx, params, exclude_hand_index):
					return true
			"look_top_deck":
				saw_checked_effect = true
				if _look_top_has_target(state, player_idx, params):
					return true
			"conditional_search_extra", "search_any_and_switch":
				saw_checked_effect = true
				var search_params := params.duplicate(true)
				search_params["from_zone"] = str(search_params.get("from_zone", "deck"))
				search_params["destination"] = str(search_params.get("destination", "hand"))
				if not search_params.has("filter"):
					search_params["filter"] = "grass_pokemon" if effect_type == "conditional_search_extra" else "any"
				if _search_has_target(state, player_idx, search_params, exclude_hand_index):
					return true
			"look_top_attach_energy":
				saw_checked_effect = true
				if _look_top_attach_has_target(state, player_idx, params):
					return true
			"arven":
				saw_checked_effect = true
				# A deck search may legally fail. Availability can use the public
				# deck count, but must not inspect hidden card identities.
				if not player.deck.is_empty():
					return true
			"shuffle_from_discard":
				saw_checked_effect = true
				if _zone_has_matching_cards(player.discard, params):
					return true
			"clara":
				saw_checked_effect = true
				for card_id in player.discard:
					if catalog.is_pokemon(card_id) or catalog.is_basic_energy(card_id):
						return true
			"energy_attach":
				saw_checked_effect = true
				if _energy_attach_has_target(state, player_idx, params, source_slot, exclude_hand_index):
					return true
			"attach_from_discard":
				saw_checked_effect = true
				var attach_params := params.duplicate(true)
				attach_params["from_zone"] = "discard"
				if _energy_attach_has_target(state, player_idx, attach_params, source_slot, exclude_hand_index):
					return true
			"draw_and_attach_energy":
				saw_checked_effect = true
				var draw_attach_params := {
					"from_zone": "hand",
					"filter": str(params.get("energy_type", "Grass")),
					"amount": int(params.get("energy_count", 2)),
					"to": "bench",
				}
				if _energy_attach_has_target(
					state, player_idx, draw_attach_params, source_slot, exclude_hand_index, true
				):
					return true
			"energy_relocate":
				saw_checked_effect = true
				if _energy_relocate_has_target(state, player_idx, params, source_slot):
					return true
			"switch_self":
				saw_checked_effect = true
				if player.active != null and player.bench_count() > 0:
					return true
			"switch_opponent":
				saw_checked_effect = true
				if opponent.active != null and opponent.bench_count() > 0:
					return true
			"heal":
				saw_checked_effect = true
				if _heal_has_target(player, params, source_slot):
					return true
			"heal_all", "potion_heal", "damage_and_self_heal", "conditional_damage_heal":
				saw_checked_effect = true
				if _player_has_damaged_pokemon(player):
					return true
				if effect_type in ["damage_and_self_heal", "conditional_damage_heal"] and opponent.active != null:
					return true
			"energy_discard":
				saw_checked_effect = true
				if _energy_discard_has_target(state, player_idx, params, source_slot):
					return true
			"coin_flip_energy_discard":
				saw_checked_effect = true
				if _player_has_attached_energy(opponent):
					return true
			"any_pokemon_damage", "place_counters_and_self_ko":
				saw_checked_effect = true
				if _player_has_effect_target_pokemon(opponent):
					return true
			"bench_damage":
				saw_checked_effect = true
				if opponent.bench_count() > 0:
					return true
			"status", "conditional_status", "attack_lock_basic", "dazzling_beam":
				saw_checked_effect = true
				if opponent.active != null:
					return true
			"damage_counter_self":
				saw_checked_effect = true
				var source := player.get_pokemon(source_slot)
				if source != null and source.current_hp(catalog) > int(params.get("amount", 0)):
					return true
			"evolve_skip_stage":
				saw_checked_effect = true
				if _rare_candy_has_target(state, player_idx, exclude_hand_index):
					return true
			"ability_discard_revive":
				saw_checked_effect = true
				var revive_id := str(params.get("card_id", ""))
				if (
					not revive_id.is_empty()
					and player.discard.has(revive_id)
					and player.hand.is_empty()
					and player.find_empty_bench_slot() >= 0
				):
					return true
			"conditional":
				saw_checked_effect = true
				if _conditional_has_target(
					state, player_idx, params, source_slot, exclude_hand_index, depth
				):
					return true
			"coin_flip", "coin_flip_triple", "coin_flip_double_ko", "coin_flip_until_tails":
				saw_checked_effect = true
				if _coin_has_target(state, player_idx, params, source_slot, exclude_hand_index, depth):
					return true
			_:
				return true
	return not saw_checked_effect


func effects_cost_is_payable(
	state: GameState,
	player_idx: int,
	effects: Variant,
	exclude_hand_index: int,
) -> bool:
	for effect_value in VMRuntimeEffects.effect_list(effects):
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value
		var effect_type := VMRuntimeEffects.availability_effect_kind(effect)
		if effect_type == "discard":
			if not _cost_is_payable(state, player_idx, effect, exclude_hand_index):
				return false
		elif effect_type == "conditional":
			var cost: Variant = VMRuntimeEffects.availability_effect_params(effect).get("cost")
			if cost != null and not _cost_is_payable(state, player_idx, cost, exclude_hand_index):
				return false
	return true


func stadium_is_activatable(state: GameState) -> bool:
	if state.stadium_card_id.is_empty():
		return false
	var card := catalog.get_card(state.stadium_card_id)
	var effects := VMRuntimeEffects.strict_trainer_effects(
		card, "trainer:%s" % state.stadium_card_id)
	for effect_value in effects:
		if not (effect_value is Dictionary):
			continue
		if str(VMRuntimeEffects.availability_effect_params(effect_value).get("stadium_type", "")) == "activatable":
			return true
	return false


func _effect_is_always_usable(effect_type: String) -> bool:
	return effect_type in [
		"draw",
		"shuffle_draw",
		"discard_draw",
		"discard_then_draw",
		"draw_until",
		"draw_until_more",
		"judge",
		"trekking_shoes",
		"return_to_hand",
		"self_attack_lock",
		"prevent_all",
		"prevent_damage",
		"prevent_effects",
		"piercing_marker",
		"tool",
		"tool_exp_share",
		"aura_damage_reduction",
		"aura_damage_boost",
		"conditional_hp_boost",
		"conditional_zero_retreat",
		"reactive_thorns",
		"apply_outgoing_damage_reduction",
	]


func _available_hand_count(player: PlayerState, exclude_hand_index: int) -> int:
	if exclude_hand_index < 0:
		return player.hand.size()
	return max(0, player.hand.size() - 1)


func _zone_cards(
	state: GameState,
	player_idx: int,
	zone: String,
	exclude_hand_index: int = -1,
) -> Array[String]:
	var player := state.get_player(player_idx)
	var result: Array[String] = []
	match zone:
		"discard":
			result.assign(player.discard)
		"hand":
			for index in range(player.hand.size()):
				if index != exclude_hand_index:
					result.append(player.hand[index])
		_:
			result.assign(player.deck)
	return result


func _search_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	exclude_hand_index: int,
) -> bool:
	var player := state.get_player(player_idx)
	var destination := str(params.get("destination", "hand"))
	if destination == "bench" and player.find_empty_bench_slot() < 0:
		return false
	if destination == "bench_energy" and _energy_effect_target_slots(state, player_idx, params, "active").is_empty():
		return false
	var from_zone := str(params.get("from_zone", "deck"))
	if from_zone == "deck":
		return int(params.get("count", 1)) > 0 and not player.deck.is_empty()
	var pool := _zone_cards(state, player_idx, from_zone, exclude_hand_index)
	return _zone_has_matching_cards(pool, params)


func _look_top_has_target(state: GameState, player_idx: int, params: Dictionary) -> bool:
	var player := state.get_player(player_idx)
	if str(params.get("destination", "hand")) == "bench_energy":
		if _energy_effect_target_slots(state, player_idx, params, "active").is_empty():
			return false
	return int(params.get("count", 1)) > 0 and not player.deck.is_empty()


func _look_top_attach_has_target(state: GameState, player_idx: int, params: Dictionary) -> bool:
	var player := state.get_player(player_idx)
	if not player.has_any_pokemon_in_play():
		return false
	return int(params.get("count", 5)) > 0 and not player.deck.is_empty()


func _zone_has_matching_cards(card_ids: Array, params: Dictionary) -> bool:
	var filter_type := str(params.get("filter", "any"))
	var filter_name := str(params.get("filter_name", ""))
	for card_id_value in card_ids:
		if _card_matches_filter(str(card_id_value), filter_type, filter_name):
			return true
	return false


func _card_matches_filter(card_id: String, filter_type: String, filter_name: String = "") -> bool:
	if not filter_name.is_empty() and catalog.card_name(card_id) != filter_name:
		return false
	var normalized := filter_type.to_lower()
	match normalized:
		"", "any":
			return true
		"basic_pokemon":
			return catalog.is_basic_pokemon(card_id)
		"pokemon":
			return catalog.is_pokemon(card_id)
		"basic", "basic_energy", "basic_energy_card":
			return catalog.is_basic_energy(card_id)
		"energy", "energy_card":
			return catalog.is_energy(card_id)
		"supporter":
			return catalog.is_supporter(card_id)
		"item":
			return catalog.is_item(card_id)
		"item_or_tool":
			return catalog.is_item(card_id) or catalog.is_tool(card_id)
		"pokemon_and_energy":
			return catalog.is_pokemon(card_id) or catalog.is_basic_energy(card_id)
		"grass_pokemon":
			return catalog.is_pokemon(card_id) and "Grass" in catalog.get_card(card_id).get("energy_types", [])
		"water_pokemon_and_energy":
			return (
				(catalog.is_pokemon(card_id) and "Water" in catalog.get_card(card_id).get("energy_types", []))
				or _energy_matches(card_id, "water")
			)
	if normalized.ends_with("_energy"):
		return _energy_matches(card_id, normalized)
	return true


func _energy_matches(card_id: String, filter_type: String) -> bool:
	if not catalog.is_energy(card_id):
		return false
	var normalized := filter_type.to_lower()
	if normalized in ["", "any", "energy"]:
		return true
	if normalized in ["basic", "basic_energy"]:
		return catalog.is_basic_energy(card_id)
	if normalized.ends_with("_energy"):
		normalized = normalized.trim_suffix("_energy")
	if normalized == "basic":
		return catalog.is_basic_energy(card_id)
	for provided in catalog.provides_energy(card_id):
		if str(provided).to_lower() == normalized:
			return true
	return false


func _energy_attach_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
	exclude_hand_index: int,
	include_deck: bool = false,
) -> bool:
	var player := state.get_player(player_idx)
	var from_zone := str(params.get("from_zone", "deck"))
	var filter_type := str(params.get("filter", params.get("energy_type", "any")))
	var has_target := not _energy_effect_target_slots(
		state, player_idx, params, source_slot).is_empty()
	if not has_target:
		return false
	if from_zone == "deck":
		return not player.deck.is_empty()
	var source_cards: Array[String] = []
	match from_zone:
		"discard":
			source_cards.assign(player.discard)
		"hand":
			source_cards = _zone_cards(state, player_idx, "hand", exclude_hand_index)
			if include_deck and not player.deck.is_empty():
				# Draw-and-attach effects can become live from an unknown draw.
				return true
		_:
			source_cards.assign(player.deck)
	var has_energy := false
	for card_id in source_cards:
		if _energy_matches(card_id, filter_type):
			has_energy = true
			break
	if not has_energy:
		return false
	return true


func _energy_effect_target_slots(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
) -> Array[String]:
	var player := state.get_player(player_idx)
	var target_spec := str(params.get("to", params.get("target", "self")))
	var target_type := str(params.get("target_pokemon_type", ""))
	if str(params.get("destination", "")) == "bench_energy":
		target_spec = "bench"
		if target_type.is_empty():
			target_type = "Lightning"
	var slots: Array[String] = []
	match target_spec:
		"self":
			var pokemon := player.get_pokemon(source_slot)
			if pokemon != null and _pokemon_matches_target_type(pokemon, target_type):
				slots.append(source_slot)
		"bench":
			for index in range(player.bench.size()):
				var bench_pokemon: PokemonState = player.bench[index]
				if bench_pokemon != null and _pokemon_matches_target_type(bench_pokemon, target_type):
					slots.append("bench_%d" % index)
		"self_basic":
			for row in player.get_all_pokemon():
				var own_pokemon: PokemonState = row["pokemon"]
				if (
					own_pokemon != null
					and catalog.is_basic_pokemon(own_pokemon.card_id)
					and _pokemon_matches_target_type(own_pokemon, target_type)
				):
					slots.append(str(row["slot"]))
		"any", "self_or_bench":
			for row in player.get_all_pokemon():
				var any_pokemon: PokemonState = row["pokemon"]
				if any_pokemon != null and _pokemon_matches_target_type(any_pokemon, target_type):
					slots.append(str(row["slot"]))
		_:
			var explicit_pokemon := player.get_pokemon(target_spec)
			if explicit_pokemon != null and _pokemon_matches_target_type(explicit_pokemon, target_type):
				slots.append(target_spec)
	return slots


func _pokemon_matches_target_type(pokemon: PokemonState, target_type: String) -> bool:
	if target_type.is_empty():
		return true
	var normalized := target_type.to_lower()
	for card_type in catalog.get_card(pokemon.card_id).get("energy_types", []):
		if str(card_type).to_lower() == normalized:
			return true
	return false


func _energy_relocate_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
) -> bool:
	var player := state.get_player(player_idx)
	var energy_type := str(params.get("energy_type", params.get("filter", "any")))
	var candidates: Array[Dictionary] = []
	if bool(params.get("from_self", false)):
		candidates.append({"slot": source_slot, "pokemon": player.get_pokemon(source_slot)})
	else:
		candidates = player.get_all_pokemon()
	var target_slots: Array[String] = []
	for row in player.get_all_pokemon():
		if row["pokemon"] != null:
			target_slots.append(str(row["slot"]))
	if target_slots.size() < 2:
		return false
	for row in candidates:
		var pokemon: PokemonState = row["pokemon"]
		var slot := str(row["slot"])
		if pokemon == null:
			continue
		var has_matching_energy := false
		for energy_id in pokemon.energy_card_ids:
			if _energy_matches(energy_id, energy_type):
				has_matching_energy = true
				break
		if not has_matching_energy:
			continue
		for target_slot in target_slots:
			if target_slot != slot:
				return true
	return false


func _heal_has_target(player: PlayerState, params: Dictionary, source_slot: String) -> bool:
	var target := str(params.get("target", "self"))
	if target == "all":
		return _player_has_damaged_pokemon(player)
	var pokemon := player.get_pokemon(source_slot if target == "self" else target)
	return pokemon != null and pokemon.damage_counters > 0


func _energy_discard_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
) -> bool:
	var from_target := str(params.get("from", "self"))
	var owner := state.get_player(player_idx if from_target == "self" else 1 - player_idx)
	var pokemon := owner.get_pokemon(source_slot) if from_target == "self" else owner.active
	if pokemon == null:
		return false
	var energy_type := str(params.get("filter", params.get("energy_type", "any")))
	for energy_id in pokemon.energy_card_ids:
		if _energy_matches(energy_id, energy_type):
			return true
	return false


func _rare_candy_has_target(
	state: GameState,
	player_idx: int,
	exclude_hand_index: int,
) -> bool:
	if state.is_player_first_turn(player_idx):
		return false
	var player := state.get_player(player_idx)
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null or not catalog.is_basic_pokemon(pokemon.card_id):
			continue
		if pokemon.placed_this_turn or not pokemon.can_evolve_this_turn:
			continue
		var basic_name := catalog.card_name(pokemon.card_id)
		for hand_index in range(player.hand.size()):
			if hand_index == exclude_hand_index:
				continue
			var stage2_id := str(player.hand[hand_index])
			if catalog.is_stage2(stage2_id) and _stage2_can_evolve_from_basic(stage2_id, basic_name):
				return true
	return false


func _stage2_can_evolve_from_basic(stage2_id: String, basic_name: String) -> bool:
	var stage1_name := str(catalog.get_card(stage2_id).get("evolves_from", ""))
	if stage1_name.is_empty():
		return false
	for candidate_id_value in catalog.cards:
		var candidate_id := str(candidate_id_value)
		if catalog.card_name(candidate_id) != stage1_name:
			continue
		if str(catalog.get_card(candidate_id).get("evolves_from", "")).to_lower() == basic_name.to_lower():
			return true
	return false


func _conditional_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
	exclude_hand_index: int,
	depth: int,
) -> bool:
	var player := state.get_player(player_idx)
	if str(params.get("condition", "")) == "ko_by_attack_last_turn" and not player.was_ko_by_attack:
		return false
	var cost: Variant = params.get("cost")
	if cost != null and not _cost_is_payable(state, player_idx, cost, exclude_hand_index):
		return false
	var on_pay: Variant = params.get("on_pay", [])
	return effects_have_legal_target(
		state, player_idx, on_pay, source_slot, exclude_hand_index, depth + 1
	)


func _coin_has_target(
	state: GameState,
	player_idx: int,
	params: Dictionary,
	source_slot: String,
	exclude_hand_index: int,
	depth: int,
) -> bool:
	var branch_found := false
	for key in ["on_heads", "on_tails", "on_success", "on_fail"]:
		var branch: Variant = params.get(key, [])
		if VMRuntimeEffects.effect_list(branch).is_empty():
			continue
		branch_found = true
		if effects_have_legal_target(
			state, player_idx, branch, source_slot, exclude_hand_index, depth + 1
		):
			return true
	return not branch_found


func _cost_is_payable(
	state: GameState,
	player_idx: int,
	cost: Variant,
	exclude_hand_index: int,
) -> bool:
	var player := state.get_player(player_idx)
	for cost_value in VMRuntimeEffects.effect_list(cost):
		if not (cost_value is Dictionary):
			continue
		var cost_effect: Dictionary = cost_value
		if VMRuntimeEffects.availability_effect_kind(cost_effect) != "discard":
			continue
		var params := VMRuntimeEffects.availability_effect_params(cost_effect)
		var from_zone := str(params.get("from", params.get("from_zone", "hand")))
		var amount := int(params.get("amount", 1))
		if from_zone == "hand" and _available_hand_count(player, exclude_hand_index) < amount:
			return false
		if from_zone == "discard" and player.discard.size() < amount:
			return false
	return true


func _player_has_damaged_pokemon(player: PlayerState) -> bool:
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon != null and pokemon.damage_counters > 0:
			return true
	return false


func _player_has_attached_energy(player: PlayerState) -> bool:
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon != null and not pokemon.energy_card_ids.is_empty():
			return true
	return false


func _player_has_effect_target_pokemon(player: PlayerState) -> bool:
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon != null:
			return true
	return false
