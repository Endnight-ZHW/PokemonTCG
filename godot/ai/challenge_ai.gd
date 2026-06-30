class_name NativeChallengeAI
extends RefCounted

const DIFFICULTIES := {
	"fast": {"simulations": 64, "seconds": 0.5, "depth": 8},
	"standard": {"simulations": 256, "seconds": 1.5, "depth": 12},
	"hard": {"simulations": 768, "seconds": 4.0, "depth": 16},
}


func decide(
	request: Dictionary,
	cancel_check: Callable,
	inference: Variant = null,
) -> Dictionary:
	var started := Time.get_ticks_usec()
	var catalog := CardCatalog.new()
	var engine := GameEngine.new(catalog)
	var state := GameState.from_dict(request["state"])
	var actor := int(request["actor"])
	var result: Dictionary
	if str(request.get("kind", "action")) == "choice":
		result = _choose_request(
			state,
			ChoiceRequest.from_dict(request["choice"]),
			actor,
			str(request.get("deck_key", "")),
			catalog,
			inference,
			str(request.get("mode", "challenge")),
		)
	else:
		result = _search_action(
			request,
			state,
			actor,
			catalog,
			engine,
			cancel_check,
			inference,
		)
	result["revision"] = int(request["revision"])
	result["request_id"] = str(request.get("request_id", ""))
	result["elapsed_ms"] = (Time.get_ticks_usec() - started) / 1000.0
	return result


func _search_action(
	request: Dictionary,
	state: GameState,
	actor: int,
	catalog: CardCatalog,
	engine: GameEngine,
	cancel_check: Callable,
	inference: Variant,
) -> Dictionary:
	var actions: Array[GameAction] = []
	for row in request.get("actions", []):
		actions.append(GameAction.from_dict(row))
	if actions.is_empty():
		actions = engine.legal_actions(state, actor, false)
	if actions.is_empty():
		return {"success": false, "error": "no_legal_action"}
	var deck_key := _deck_key_for_actor(state, actor, str(request.get("deck_key", "")))
	var mode := str(request.get("mode", "challenge"))
	var difficulty := str(request.get("difficulty", "standard"))
	var preset: Dictionary = DIFFICULTIES.get(difficulty, DIFFICULTIES["standard"])
	var simulation_budget := int(
		256 if mode == "deep" else request.get("simulation_budget", preset["simulations"])
	)
	var seconds := float(8.0 if mode == "deep" else request.get("seconds", preset["seconds"]))
	var max_depth := int(request.get("max_depth", preset["depth"]))
	var deterministic := bool(request.get("deterministic", false))
	var deadline := Time.get_ticks_usec() + int(seconds * 1000000.0)
	var request_seed := int(request.get("seed", 17))
	var priors: Array[float] = []
	var deep_error := ""
	if mode == "deep" and inference != null:
		var neural := _neural_action_priors(state, actor, actions, deck_key, catalog, inference)
		if bool(neural.get("success", false)):
			priors.assign(neural["priors"])
		else:
			deep_error = str(neural.get("error", "inference_failed"))
	elif mode == "deep":
		deep_error = "runtime_unavailable"
	if mode == "deep" and not deep_error.is_empty():
		var standard: Dictionary = DIFFICULTIES["standard"]
		simulation_budget = int(standard["simulations"])
		seconds = float(standard["seconds"])
		max_depth = int(standard["depth"])
		deadline = Time.get_ticks_usec() + int(seconds * 1000000.0)
	if priors.size() != actions.size():
		priors = _heuristic_priors(state, actor, actions, deck_key, catalog)

	var visits: Array[int] = []
	var totals: Array[float] = []
	visits.resize(actions.size())
	totals.resize(actions.size())
	visits.fill(0)
	totals.fill(0.0)
	var completed := 0
	while completed < simulation_budget:
		if cancel_check.call():
			return {"success": false, "cancelled": true, "error": "cancelled"}
		if not deterministic and Time.get_ticks_usec() >= deadline:
			break
		var selected := _select_ucb(visits, totals, priors, completed)
		var simulation := AIObservationBuilder.determinize(
			request["state"],
			actor,
			request_seed + completed * 7919,
			catalog,
		)
		var simulation_rng := PortableRandomSource.new(
			request_seed + completed * 104729
		)
		var value := _simulate(
			simulation,
			actor,
			actions[selected],
			deck_key,
			catalog,
			engine,
			simulation_rng,
			max_depth,
		)
		visits[selected] += 1
		totals[selected] += value
		completed += 1
	if completed == 0 and mode == "deep":
		var fallback_request: Dictionary = request.duplicate(true)
		fallback_request["mode"] = "challenge"
		fallback_request["difficulty"] = "standard"
		fallback_request.erase("simulation_budget")
		fallback_request.erase("seconds")
		fallback_request.erase("max_depth")
		var fallback := _search_action(
			fallback_request,
			state,
			actor,
			catalog,
			engine,
			cancel_check,
			null,
		)
		fallback["deep_fallback"] = true
		fallback["fallback_reason"] = "zero_valid_simulations"
		return fallback
	var best := 0
	for index in range(1, actions.size()):
		var left_average := totals[index] / maxi(1, visits[index])
		var right_average := totals[best] / maxi(1, visits[best])
		if (
			visits[index] > visits[best]
			or (
				visits[index] == visits[best]
				and (
					left_average > right_average
					or (
						is_equal_approx(left_average, right_average)
						and priors[index] > priors[best]
					)
				)
			)
		):
			best = index
	var selected_action := _validated_or_fallback_action(
		state,
		actor,
		actions[best],
		actions,
		deck_key,
		catalog,
		engine,
		request_seed + completed * 15485863,
	)
	return {
		"success": true,
		"kind": "action",
		"action": selected_action.to_dict(),
		"simulations": completed,
		"deep_fallback": not deep_error.is_empty(),
		"fallback_reason": deep_error,
	}


func _simulate(
	state: GameState,
	perspective: int,
	first_action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	rng: PortableRandomSource,
	max_depth: int,
) -> float:
	var step := engine.apply_action(state, first_action, rng)
	if not step.success:
		return -1.0
	if not _resolve_choices(state, perspective, deck_key, catalog, engine, rng):
		return -1.0
	if state.winner >= 0:
		return 1.0 if state.winner == perspective else -1.0
	for _depth in range(max_depth):
		var actor := _current_actor(state)
		var actions := engine.legal_actions(state, actor, false)
		if actions.is_empty():
			break
		var action_deck_key := _deck_key_for_actor(state, actor, deck_key)
		var action := _best_heuristic_action(state, actor, actions, action_deck_key, catalog)
		step = engine.apply_action(state, action, rng)
		if not step.success:
			break
		if not _resolve_choices(state, perspective, deck_key, catalog, engine, rng):
			break
		if state.winner >= 0:
			return 1.0 if state.winner == perspective else -1.0
		if state.active_player_idx == perspective and actor != perspective:
			break
	return _evaluate(state, perspective, catalog)


func _resolve_choices(
	state: GameState,
	perspective: int,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	rng: PortableRandomSource,
) -> bool:
	for _guard in range(32):
		var request := ResolutionStack.from_dict(state.resolution_stack).pending_request
		if request == null:
			return true
		var response := _heuristic_choice(
			state,
			request,
			_deck_key_for_actor(state, request.player, deck_key),
			catalog,
		)
		var step := engine.apply_choice(state, request, response, rng)
		if not step.success:
			return false
	return false


func _choose_request(
	state: GameState,
	request: ChoiceRequest,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
	inference: Variant,
	mode: String,
) -> Dictionary:
	var response: ChoiceResponse
	var deep_error := ""
	if mode == "deep" and inference == null:
		deep_error = "runtime_unavailable"
	elif inference != null and not request.options.is_empty():
		var neural := _neural_choice(state, request, actor, deck_key, catalog, inference)
		if bool(neural.get("success", false)):
			response = neural["response"]
		else:
			deep_error = str(neural.get("error", "choice_inference_failed"))
	if response == null:
		response = _heuristic_choice(
			state,
			request,
			_deck_key_for_actor(state, request.player, deck_key),
			catalog,
		)
	return {
		"success": true,
		"kind": "choice",
		"choice_response": response.to_dict(),
		"simulations": 0,
		"deep_fallback": not deep_error.is_empty(),
		"fallback_reason": deep_error,
	}


func _heuristic_choice(
	state: GameState,
	request: ChoiceRequest,
	deck_key: String,
	catalog: CardCatalog,
) -> ChoiceResponse:
	if request.options.is_empty():
		return ChoiceResponse.new(
			request.request_id,
			[],
			request.can_cancel and request.min_select <= 0,
		)
	var continuation := _pending_choice_continuation(state)
	if request.request_type == "confirm":
		var confirmed := _confirm_choice(state, request, continuation, deck_key, catalog)
		return ChoiceResponse.new(
			request.request_id,
			["confirm:yes" if confirmed else "confirm:no"],
		)
	if _is_arven_choice(request, continuation):
		return ChoiceResponse.new(
			request.request_id,
			_arven_choice_option_ids(state, request, deck_key, catalog),
		)
	var mode := _choice_score_mode(request, continuation)
	var ranked: Array[int] = []
	for index in range(request.options.size()):
		ranked.append(index)
	ranked.sort_custom(func(left: int, right: int) -> bool:
		var left_score := _option_score(
			state, request, request.options[left], deck_key, catalog, mode)
		var right_score := _option_score(
			state, request, request.options[right], deck_key, catalog, mode)
		if is_equal_approx(left_score, right_score):
			return left < right
		return left_score > right_score
	)
	var max_count: int = _choice_max_count(request)
	var min_count: int = max(0, request.min_select)
	if min_count <= 0:
		var positive_ranked: Array[int] = []
		for index in ranked:
			if _option_score(
				state, request, request.options[index], deck_key, catalog, mode
			) <= 0.0:
				continue
			positive_ranked.append(index)
			if not request.allow_duplicates and positive_ranked.size() >= max_count:
				break
		if positive_ranked.is_empty() and request.can_cancel:
			return ChoiceResponse.new(request.request_id, [], true)
		var optional_count: int = max_count if request.allow_duplicates else positive_ranked.size()
		return ChoiceResponse.new(
			request.request_id,
			_ranked_choice_option_ids(request, positive_ranked, optional_count),
		)
	var count: int = max(min_count, max_count)
	return ChoiceResponse.new(
		request.request_id,
		_ranked_choice_option_ids(request, ranked, count),
	)


func _pending_choice_continuation(state: GameState) -> Dictionary:
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	if stack.frames.is_empty():
		return {}
	var frame: Dictionary = stack.frames[-1]
	if str(frame.get("kind", "")) != "continuation":
		return {}
	return frame


func _choice_max_count(request: ChoiceRequest) -> int:
	var max_count: int = max(0, request.max_select)
	if not request.allow_duplicates:
		max_count = mini(request.options.size(), max_count)
	return max_count


func _choice_score_mode(request: ChoiceRequest, continuation: Dictionary) -> String:
	var operation := str(continuation.get("operation", ""))
	var prompt := request.prompt.to_lower()
	if operation in ["discard_then_draw", "discard_cards", "hand_bottom_draw", "houb", "zinnia"]:
		return "discard"
	if request.request_type in ["select_energy_target", "distribute_energy", "look_top_attach_energy"]:
		return "energy"
	if request.request_type in ["select_heal_target"] or "heal" in prompt or "回复" in request.prompt:
		return "heal"
	if request.request_type in ["select_opponent_bench", "bench_damage_target", "damage_target", "place_counters_self_ko"]:
		return "target"
	if request.request_type == "select_bench" and operation == "switch":
		return "self_switch"
	if (
		"discard" in prompt
		or "bottom" in prompt
		or "丢" in request.prompt
		or "弃" in request.prompt
		or "放回" in request.prompt
		or "牌库底" in request.prompt
	):
		return "discard"
	return "search"


func _is_arven_choice(request: ChoiceRequest, continuation: Dictionary) -> bool:
	return request.request_type == "arven" or str(continuation.get("operation", "")) == "arven"


func _arven_choice_option_ids(
	state: GameState,
	request: ChoiceRequest,
	deck_key: String,
	catalog: CardCatalog,
) -> Array[String]:
	var best_item := -1
	var best_item_score := -INF
	var best_tool := -1
	var best_tool_score := -INF
	for index in range(request.options.size()):
		var option: Dictionary = request.options[index]
		var card_id := _choice_option_card_id(option)
		var score := _card_keep_value(state, request.player, card_id, deck_key, catalog)
		if catalog.is_item(card_id) and score > best_item_score:
			best_item = index
			best_item_score = score
		elif catalog.is_tool(card_id) and score > best_tool_score:
			best_tool = index
			best_tool_score = score
	var selected: Array[String] = []
	if best_item >= 0:
		selected.append(str(request.options[best_item]["option_id"]))
	if best_tool >= 0 and selected.size() < request.max_select:
		selected.append(str(request.options[best_tool]["option_id"]))
	if selected.is_empty() and request.min_select > 0:
		var fallback := 0
		for index in range(1, request.options.size()):
			if _card_keep_value(
				state, request.player, _choice_option_card_id(request.options[index]), deck_key, catalog
			) > _card_keep_value(
				state, request.player, _choice_option_card_id(request.options[fallback]), deck_key, catalog
			):
				fallback = index
		selected.append(str(request.options[fallback]["option_id"]))
	return selected


func _ranked_choice_option_ids(
	request: ChoiceRequest,
	ranked: Array[int],
	count: int,
) -> Array[String]:
	var selected: Array[String] = []
	if count <= 0 or ranked.is_empty():
		return selected
	if not request.allow_duplicates:
		for index in ranked.slice(0, count):
			selected.append(str(request.options[index]["option_id"]))
		return selected
	var max_per_target := int(request.metadata.get("max_per_target", 99))
	if max_per_target >= count:
		for _index in range(count):
			selected.append(str(request.options[ranked[0]]["option_id"]))
		return selected
	var per_target: Dictionary = {}
	for index in ranked:
		if selected.size() >= count:
			break
		var option: Dictionary = request.options[index]
		var target_key := _choice_target_key(option)
		if not target_key.is_empty():
			if int(per_target.get(target_key, 0)) >= max_per_target:
				continue
			per_target[target_key] = int(per_target.get(target_key, 0)) + 1
		selected.append(str(option["option_id"]))
	while selected.size() < count:
		selected.append(str(request.options[ranked[0]]["option_id"]))
	return selected


func _choice_target_key(option: Dictionary) -> String:
	var player := -1
	var ref_variant: Variant = option.get("ref", {})
	if ref_variant is Dictionary:
		player = int(Dictionary(ref_variant).get("player", -1))
	var value_variant: Variant = option.get("value", {})
	if value_variant is Dictionary:
		var value: Dictionary = value_variant
		player = int(value.get("player", player))
		var slot := str(value.get("slot", ""))
		if not slot.is_empty():
			return "%d:%s" % [player, slot]
	if ref_variant is Dictionary:
		var ref_slot := str(Dictionary(ref_variant).get("slot", ""))
		if not ref_slot.is_empty():
			return "%d:%s" % [player, ref_slot]
	var option_parts := str(option.get("option_id", "")).split(":")
	if option_parts.size() >= 3 and option_parts[0] in ["pokemon", "attachment"]:
		return "%s:%s" % [option_parts[1], option_parts[2]]
	return ""


func _option_score(
	state: GameState,
	request: ChoiceRequest,
	option: Dictionary,
	deck_key: String,
	catalog: CardCatalog,
	mode: String = "search",
) -> float:
	var card_id := _choice_option_card_id(option)
	if mode == "discard":
		return _discard_choice_score(state, request.player, card_id, deck_key, catalog)
	var score := _card_keep_value(state, request.player, card_id, deck_key, catalog)
	var slot := _choice_option_slot(option)
	var target_player := _choice_option_player(option, request.player)
	var pokemon := state.get_player(target_player).get_pokemon(slot)
	if pokemon:
		var hp := pokemon.current_hp(catalog)
		if mode == "target" or target_player != request.player:
			score += _target_priority(pokemon, catalog)
		elif mode == "heal":
			score += pokemon.damage_counters * 30.0
		elif mode == "energy":
			score += _energy_choice_target_value(
				state, target_player, slot, card_id, deck_key, catalog)
		elif mode == "self_switch":
			score += _promotion_value_for_state(
				state, target_player, pokemon, deck_key, catalog)
		else:
			score += pokemon.energy_card_ids.size() * 12.0
			if slot == "active":
				score += 20.0
	return score


func _choice_option_card_id(option: Dictionary) -> String:
	var ref_variant: Variant = option.get("ref", {})
	if ref_variant is Dictionary:
		var ref: Dictionary = ref_variant
		var card_id := str(ref.get("card_id", ""))
		if not card_id.is_empty():
			return card_id
	var value_variant: Variant = option.get("value", {})
	if value_variant is Dictionary:
		var value: Dictionary = value_variant
		return str(value.get("card_id", ""))
	return ""


func _choice_option_slot(option: Dictionary) -> String:
	var ref_variant: Variant = option.get("ref", {})
	if ref_variant is Dictionary:
		var ref: Dictionary = ref_variant
		var slot := str(ref.get("slot", ""))
		if not slot.is_empty():
			return slot
	var value_variant: Variant = option.get("value", {})
	if value_variant is Dictionary:
		return str(Dictionary(value_variant).get("slot", ""))
	var option_parts := str(option.get("option_id", "")).split(":")
	if option_parts.size() >= 3 and option_parts[0] in ["pokemon", "attachment"]:
		return str(option_parts[2])
	return ""


func _choice_option_player(option: Dictionary, fallback: int) -> int:
	var ref_variant: Variant = option.get("ref", {})
	if ref_variant is Dictionary:
		var ref: Dictionary = ref_variant
		if ref.has("player"):
			return int(ref["player"])
	var value_variant: Variant = option.get("value", {})
	if value_variant is Dictionary:
		var value: Dictionary = value_variant
		if value.has("player"):
			return int(value["player"])
	var option_parts := str(option.get("option_id", "")).split(":")
	if option_parts.size() >= 2 and option_parts[0] in ["pokemon", "attachment"]:
		return int(option_parts[1])
	return fallback


func _card_keep_value(
	state: GameState,
	actor: int,
	card_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	if card_id.is_empty():
		return 0.0
	var player := state.get_player(actor)
	var value := _card_priority(card_id, deck_key, catalog)
	if catalog.is_pokemon(card_id):
		value += int(catalog.get_card(card_id).get("hp", 0)) * 0.25
	if catalog.is_energy(card_id) and _has_energy_target_with_missing_cost(state, actor, catalog):
		value += 50.0
	if catalog.is_trainer(card_id):
		value += 18.0
	var duplicate_count := 0
	for hand_card_id in player.hand:
		if hand_card_id == card_id:
			duplicate_count += 1
	if duplicate_count >= 2:
		value -= min(90.0, float(duplicate_count - 1) * 35.0)
	return value


func _discard_choice_score(
	state: GameState,
	actor: int,
	card_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	var keep_value := _card_keep_value(state, actor, card_id, deck_key, catalog)
	var score := -keep_value
	var duplicate_count := 0
	for hand_card_id in player.hand:
		if hand_card_id == card_id:
			duplicate_count += 1
	if duplicate_count > 1:
		score += min(120.0, float(duplicate_count - 1) * 55.0)
	if catalog.is_energy(card_id) and player.energy_attached_this_turn:
		score += 35.0
	if catalog.is_trainer(card_id) and player.supporter_played_this_turn and catalog.is_supporter(card_id):
		score += 30.0
	return score


func _energy_choice_target_value(
	state: GameState,
	actor: int,
	slot: String,
	energy_card_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var pokemon := state.get_player(actor).get_pokemon(slot)
	if pokemon == null:
		return -INF
	var before := _best_missing_energy(pokemon, catalog)
	var after := (
		_best_missing_energy_with_extra(pokemon, energy_card_id, catalog)
		if not energy_card_id.is_empty() and catalog.is_energy(energy_card_id)
		else before
	)
	var progress: int = max(0, before - after)
	var value := progress * 85.0
	if before > 0 and after == 0:
		value += 155.0 + _best_pokemon_damage(pokemon, catalog) * 0.25
	elif before > 1 and after == 1:
		value += 65.0
	if AIDeckProfiles.contains(deck_key, "core", pokemon.card_id):
		value += 65.0
	if slot == "active":
		value += 28.0
	return value


func _target_priority(pokemon: PokemonState, catalog: CardCatalog) -> float:
	if pokemon == null:
		return -INF
	var max_hp := int(catalog.get_card(pokemon.card_id).get("hp", 0))
	return (
		catalog.prize_value(pokemon.card_id) * 160.0
		+ max(0, max_hp - pokemon.current_hp(catalog)) * 2.0
		+ pokemon.energy_card_ids.size() * 26.0
		+ _best_pokemon_damage(pokemon, catalog) * 0.35
		- pokemon.current_hp(catalog) * 0.45
	)


func _confirm_choice(
	state: GameState,
	request: ChoiceRequest,
	continuation: Dictionary,
	deck_key: String,
	catalog: CardCatalog,
) -> bool:
	var data: Dictionary = Dictionary(continuation.get("data", {}))
	var operation := str(continuation.get("operation", data.get("kind", "")))
	if operation == "trekking_shoes":
		var top_card_id := str(data.get("card_id", ""))
		if top_card_id.is_empty() and not state.get_player(request.player).deck.is_empty():
			top_card_id = state.get_player(request.player).deck[-1]
		return _should_keep_top_deck_card(state, request.player, top_card_id, deck_key, catalog)
	if operation == "confirm_switch":
		var chooser := int(data.get("chooser", request.player))
		var target_player := int(data.get("target_player", request.player))
		if target_player == chooser:
			return _switch_self_has_good_target(state, chooser, deck_key, catalog)
		return _switch_opponent_has_good_target(state, chooser, target_player, catalog)
	if "牌库顶" in request.prompt:
		var top_id := state.get_player(request.player).deck[-1] if not state.get_player(request.player).deck.is_empty() else ""
		return _should_keep_top_deck_card(state, request.player, top_id, deck_key, catalog)
	var prompt_l := request.prompt.to_lower()
	if "switch" in prompt_l or "替换" in request.prompt or "交换" in request.prompt:
		return _switch_self_has_good_target(state, request.player, deck_key, catalog)
	if "heal" in prompt_l or "回复" in request.prompt:
		for row in state.get_player(request.player).get_all_pokemon():
			var pokemon: PokemonState = row["pokemon"]
			if pokemon and pokemon.damage_counters > 0:
				return true
		return false
	return true


func _should_keep_top_deck_card(
	state: GameState,
	actor: int,
	card_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> bool:
	if card_id.is_empty():
		return false
	if (
		AIDeckProfiles.contains(deck_key, "core", card_id)
		or AIDeckProfiles.contains(deck_key, "evolution", card_id)
		or AIDeckProfiles.contains(deck_key, "engine", card_id)
	):
		return true
	if catalog.is_energy(card_id) and _has_energy_target_with_missing_cost(state, actor, catalog):
		return true
	return _card_keep_value(state, actor, card_id, deck_key, catalog) >= 55.0


func _heuristic_priors(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
) -> Array[float]:
	var scores: Array[float] = []
	var maximum := -INF
	for action in actions:
		var score := _action_score(state, actor, action, deck_key, catalog)
		scores.append(score)
		maximum = max(maximum, score)
	var priors: Array[float] = []
	var total := 0.0
	for score in scores:
		var value := exp(clampf((score - maximum) / 80.0, -30.0, 30.0))
		priors.append(value)
		total += value
	for index in range(priors.size()):
		priors[index] /= max(0.000001, total)
	return priors


func _best_heuristic_action(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
) -> GameAction:
	var best := actions[0]
	var best_score := -INF
	for action in actions:
		var score := _action_score(state, actor, action, deck_key, catalog)
		if score > best_score:
			best = action
			best_score = score
	return best


func _validated_or_fallback_action(
	state: GameState,
	actor: int,
	preferred: GameAction,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
) -> GameAction:
	var ko_attack := _best_immediate_ko_attack(state, actor, actions, deck_key, catalog, engine, seed)
	if ko_attack != null and _should_override_with_ko(preferred, ko_attack, state, actor, catalog):
		return ko_attack

	if preferred.action == "DECLARE_ATTACK":
		if (
			_attack_draw_pressure_is_unsafe(state, actor, preferred, catalog)
			or _attack_feeds_dangerous_retaliation(state, actor, preferred, catalog)
		):
			var safe_development := _best_productive_nonterminal_action(
				state, actor, actions, deck_key, catalog, engine, seed + 11, preferred)
			if safe_development != null:
				return safe_development
			var end_turn := _find_action(actions, "END_TURN")
			if end_turn != null and _action_executes_successfully(
				state, actor, end_turn, deck_key, catalog, engine, seed + 13):
				return end_turn
		var pre_attack := _best_pre_attack_development_action(
			state, actor, preferred, actions, deck_key, catalog, engine, seed + 17)
		if pre_attack != null:
			return pre_attack

	if _should_avoid_repeating_ability(state, actor, preferred, catalog):
		var follow_up_attack := _best_productive_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 14)
		if follow_up_attack != null:
			return follow_up_attack
		var follow_up_development := _best_productive_nonterminal_action(
			state, actor, actions, deck_key, catalog, engine, seed + 15, preferred)
		if follow_up_development != null:
			return follow_up_development
		var follow_up_end_turn := _find_action(actions, "END_TURN")
		if follow_up_end_turn != null:
			return follow_up_end_turn

	if preferred.action == "RETREAT":
		var retreat_idx := int(preferred.params.get("bench_idx", -1))
		if not _retreat_has_good_target(state, actor, retreat_idx, deck_key, catalog):
			var safe_development := _best_productive_nonterminal_action(
				state, actor, actions, deck_key, catalog, engine, seed + 18, preferred)
			if safe_development != null:
				return safe_development
			var safe_end_turn := _find_action(actions, "END_TURN")
			if safe_end_turn != null and _action_executes_successfully(
				state, actor, safe_end_turn, deck_key, catalog, engine, seed + 20):
				return safe_end_turn

	if preferred.action in ["RETREAT", "END_TURN"]:
		var development := _best_productive_nonterminal_action(
			state, actor, actions, deck_key, catalog, engine, seed + 19, preferred)
		if development != null:
			return development

	if preferred.action == "PLAY_TRAINER" and _is_major_hand_refresh_action(state, actor, preferred, catalog):
		var before_refresh := _best_productive_nonterminal_action(
			state, actor, actions, deck_key, catalog, engine, seed + 23, preferred)
		if before_refresh != null:
			return before_refresh

	if preferred.action == "END_TURN":
		var productive_attack := _best_productive_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 29)
		if productive_attack != null:
			return productive_attack

	if _action_executes_successfully(state, actor, preferred, deck_key, catalog, engine, seed + 31):
		return preferred
	for action in actions:
		if _action_executes_successfully(state, actor, action, deck_key, catalog, engine, seed + 37):
			return action
	var fallback_end := _find_action(actions, "END_TURN")
	return fallback_end if fallback_end != null else actions[0]


func _best_immediate_ko_attack(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
) -> GameAction:
	var opponent := state.get_player(1 - actor)
	if opponent.active == null:
		return null
	var best: GameAction = null
	var best_value := -INF
	for action in actions:
		if action.action != "DECLARE_ATTACK":
			continue
		var damage := _estimated_attack_damage(state, actor, int(action.params.get("attack_idx", -1)), catalog)
		if damage < opponent.active.current_hp(catalog):
			continue
		var value := damage + catalog.prize_value(opponent.active.card_id) * 140.0
		if value > best_value and _action_executes_successfully(
			state, actor, action, deck_key, catalog, engine, seed + int(value)):
			best = action
			best_value = value
	return best


func _should_override_with_ko(
	preferred: GameAction,
	ko_attack: GameAction,
	state: GameState,
	actor: int,
	catalog: CardCatalog,
) -> bool:
	if preferred == null:
		return true
	if preferred.action != "DECLARE_ATTACK":
		return true
	var preferred_damage := _estimated_attack_damage(
		state, actor, int(preferred.params.get("attack_idx", -1)), catalog)
	var ko_damage := _estimated_attack_damage(
		state, actor, int(ko_attack.params.get("attack_idx", -1)), catalog)
	return ko_damage > preferred_damage


func _best_pre_attack_development_action(
	state: GameState,
	actor: int,
	attack_action: GameAction,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
) -> GameAction:
	if attack_action.action != "DECLARE_ATTACK":
		return null
	var opponent := state.get_player(1 - actor)
	var damage := _estimated_attack_damage(
		state, actor, int(attack_action.params.get("attack_idx", -1)), catalog)
	if opponent.active != null and damage >= opponent.active.current_hp(catalog):
		return null
	var active_missing := _best_missing_energy(state.get_player(actor).active, catalog)
	var is_weak := damage < 80 or (opponent.active != null and damage < opponent.active.current_hp(catalog) * 0.45)
	if not is_weak and active_missing <= 0:
		return null
	return _best_productive_nonterminal_action(
		state, actor, actions, deck_key, catalog, engine, seed, attack_action)


func _best_productive_nonterminal_action(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	excluded: GameAction = null,
) -> GameAction:
	var productive_types := {
		"ATTACH_ENERGY": true,
		"EVOLVE": true,
		"USE_ABILITY": true,
		"PLAY_TRAINER": true,
		"PLAY_BASIC": true,
		"USE_STADIUM": true,
	}
	var base_score := _evaluate_raw(state, actor, catalog)
	var best: GameAction = null
	var best_value := -INF
	for action_index in range(actions.size()):
		var action := actions[action_index]
		if action == excluded or not productive_types.has(action.action):
			continue
		if _should_avoid_repeating_ability(state, actor, action, catalog):
			continue
		var development_value := _development_action_value(state, actor, action, deck_key, catalog)
		if development_value <= 0.0:
			continue
		var sim_score := _simulated_action_score(
			state, actor, action, deck_key, catalog, engine, seed + action_index * 7919)
		if sim_score <= -INF / 2.0:
			continue
		var delta := sim_score - base_score
		var value := development_value + delta * 0.45 + _action_score(
			state, actor, action, deck_key, catalog) * 0.04
		if action.action == "PLAY_BASIC" and state.get_player(actor).bench_count() < 2:
			value += 45.0
		if value < 105.0 and delta < 12.0:
			continue
		if value > best_value:
			best = action
			best_value = value
	return best


func _best_productive_attack(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
) -> GameAction:
	var best: GameAction = null
	var best_value := -INF
	for action in actions:
		if action.action != "DECLARE_ATTACK":
			continue
		if (
			_attack_draw_pressure_is_unsafe(state, actor, action, catalog)
			or _attack_feeds_dangerous_retaliation(state, actor, action, catalog)
		):
			continue
		var attack_idx := int(action.params.get("attack_idx", -1))
		var damage := _estimated_attack_damage(state, actor, attack_idx, catalog)
		var effects := _attack_effects(state, actor, attack_idx, catalog)
		var value := damage * 1.2 + _effects_tactical_value(
			state, actor, effects, "active", catalog)
		if value <= 0.0:
			continue
		if value > best_value and _action_executes_successfully(
			state, actor, action, deck_key, catalog, engine, seed + attack_idx):
			best = action
			best_value = value
	return best


func _simulated_action_score(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
) -> float:
	var simulation := GameState.from_dict(state.snapshot())
	var rng := PortableRandomSource.new(seed)
	var step := engine.apply_action(simulation, action, rng)
	if not step.success:
		return -INF
	if not _resolve_choices(simulation, actor, deck_key, catalog, engine, rng):
		return -INF
	return _evaluate_raw(simulation, actor, catalog)


func _action_executes_successfully(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
) -> bool:
	return _simulated_action_score(state, actor, action, deck_key, catalog, engine, seed) > -INF / 2.0


func _action_score(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	var card_id := _action_card_id(state, actor, action)
	var score := _card_priority(card_id, deck_key, catalog)
	match action.action:
		"PLAY_BASIC":
			score += 180.0
			if str(action.params.get("target", "")) == "active":
				score += 200.0
				if (
					AIDeckProfiles.contains(deck_key, "bench", card_id)
					and not AIDeckProfiles.contains(deck_key, "setup", card_id)
					and _has_alternative_setup_active_in_hand(state, actor, card_id, deck_key, catalog)
				):
					score -= 260.0
			if AIDeckProfiles.contains(deck_key, "setup", card_id):
				score += 160.0
			elif (
				str(action.params.get("target", "")) != "active"
				and AIDeckProfiles.contains(deck_key, "bench", card_id)
			):
				score += 70.0
			score += _development_action_value(state, actor, action, deck_key, catalog) * 0.5
		"SETUP_DONE":
			score -= 30.0 if player.bench_count() < 2 else 0.0
		"EVOLVE":
			score += 320.0
			score += _development_action_value(state, actor, action, deck_key, catalog) * 0.7
		"ATTACH_ENERGY":
			score += 220.0
			if str(action.params.get("target_slot", "")) == "active":
				score += 90.0
			score += _development_action_value(state, actor, action, deck_key, catalog) * 0.8
		"PLAY_TRAINER":
			score += 160.0
			score += _development_action_value(state, actor, action, deck_key, catalog) * 0.75
		"USE_ABILITY", "USE_STADIUM":
			var development_value := _development_action_value(state, actor, action, deck_key, catalog)
			if development_value > 0.0:
				score += 190.0 + development_value * 0.75
			else:
				score -= 220.0
			if _should_avoid_repeating_ability(state, actor, action, catalog):
				score -= 650.0
		"RETREAT":
			score += 70.0
			var bench_idx := int(action.params.get("bench_idx", -1))
			if bench_idx >= 0 and bench_idx < player.bench.size():
				var target: PokemonState = player.bench[bench_idx]
				if target != null and player.active != null:
					if _retreat_has_good_target(state, actor, bench_idx, deck_key, catalog):
						score += 180.0
					else:
						score -= 420.0
					score += (
						_best_pokemon_damage(target, catalog)
						- _best_pokemon_damage(player.active, catalog)
					) * 1.3
		"PROMOTE":
			var promote_idx := int(action.params.get("bench_idx", -1))
			if promote_idx >= 0 and promote_idx < player.bench.size():
				var pokemon: PokemonState = player.bench[promote_idx]
				score += _promotion_value_for_state(state, actor, pokemon, deck_key, catalog)
		"DECLARE_ATTACK":
			score += 360.0
			if player.active:
				var attacks: Array = catalog.get_card(player.active.card_id).get("attacks", [])
				var attack_idx := int(action.params.get("attack_idx", -1))
				if attack_idx >= 0 and attack_idx < attacks.size():
					var damage := _estimated_attack_damage(state, actor, attack_idx, catalog)
					var effects: Array = attacks[attack_idx].get("effects", [])
					score += damage * 3.4
					score += _effects_tactical_value(state, actor, effects, "active", catalog)
					var opponent := state.get_opponent(actor)
					if opponent.active and damage >= opponent.active.current_hp(catalog):
						score += 900.0
					elif damage <= 30 and _effects_tactical_value(
						state, actor, effects, "active", catalog) <= 0.0:
						score -= 260.0
					if _attack_draw_pressure_is_unsafe(state, actor, action, catalog):
						score -= 450.0
					if _attack_feeds_dangerous_retaliation(state, actor, action, catalog):
						score -= 420.0
		"END_TURN":
			score -= 220.0
	return score


func _action_card_id(state: GameState, actor: int, action: GameAction) -> String:
	if action.source != null and not action.source.card_id.is_empty():
		return action.source.card_id
	var hand_idx: Variant = action.params.get("hand_idx")
	if hand_idx is int or hand_idx is float:
		var player := state.get_player(actor)
		var index := int(hand_idx)
		if index >= 0 and index < player.hand.size():
			return str(player.hand[index])
	if action.action in ["DECLARE_ATTACK", "USE_ABILITY"] and state.get_player(actor).active != null:
		return state.get_player(actor).active.card_id
	return ""


func _development_action_value(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	var card_id := _action_card_id(state, actor, action)
	match action.action:
		"ATTACH_ENERGY":
			var target_slot := str(action.params.get("target_slot", ""))
			var target := player.get_pokemon(target_slot)
			if target == null or card_id.is_empty():
				return 0.0
			var before := _best_missing_energy(target, catalog)
			var after := _best_missing_energy_with_extra(target, card_id, catalog)
			var progress: int = max(0, before - after)
			var attach_value: float = progress * 95.0
			if before > 0 and after == 0:
				attach_value += 175.0 + _best_pokemon_damage(target, catalog) * 0.25
			elif before > 1 and after == 1:
				attach_value += 70.0
			if AIDeckProfiles.contains(deck_key, "core", target.card_id):
				attach_value += 85.0
			if target_slot == "active":
				attach_value += 45.0
			if _energy_matches_profile(card_id, deck_key, catalog):
				attach_value += 45.0
			if before == 0 and progress == 0:
				attach_value -= 45.0
			return attach_value
		"EVOLVE":
			var evolve_slot := str(action.params.get("slot", ""))
			var evolve_target := player.get_pokemon(evolve_slot)
			if evolve_target == null or card_id.is_empty():
				return 0.0
			var evolved_strength := _pokemon_card_strength(card_id, evolve_target.energy_card_ids.size(), catalog)
			var current_strength := _pokemon_strength(evolve_target, catalog)
			var evolve_value: float = 145.0 + max(0.0, evolved_strength - current_strength) * 0.75
			if AIDeckProfiles.contains(deck_key, "core", card_id):
				evolve_value += 95.0
			if AIDeckProfiles.contains(deck_key, "evolution", card_id):
				evolve_value += 70.0
			return evolve_value
		"PLAY_BASIC":
			if card_id.is_empty() or player.bench_count() >= PlayerState.MAX_BENCH_SIZE:
				return 0.0
			var basic_value: float = 90.0 + _card_priority(card_id, deck_key, catalog) * 0.7
			if player.bench_count() < 2:
				basic_value += 70.0
			if AIDeckProfiles.contains(deck_key, "setup", card_id):
				basic_value += 80.0
			if (
				str(action.params.get("target", "")) != "active"
				and AIDeckProfiles.contains(deck_key, "bench", card_id)
			):
				basic_value += 70.0
			return basic_value
		"PLAY_TRAINER":
			if card_id.is_empty():
				return 0.0
			var effects: Array = catalog.get_card(card_id).get("trainer_effects", [])
			var trainer_value := _effects_tactical_value(state, actor, effects, "active", catalog)
			if AIDeckProfiles.contains(deck_key, "trainer", card_id):
				trainer_value += 45.0
			return trainer_value
		"USE_ABILITY":
			var slot := str(action.params.get("slot", "active"))
			var pokemon := player.get_pokemon(slot)
			if pokemon == null:
				return 0.0
			var ability_name := str(action.params.get("ability_name", ""))
			for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
				var ability: Dictionary = ability_value
				if str(ability.get("name", "")) == ability_name:
					return 65.0 + _effects_tactical_value(
						state, actor, ability.get("effects", []), slot, catalog)
			return 0.0
		"USE_STADIUM":
			if state.stadium_card_id.is_empty():
				return 0.0
			return _effects_tactical_value(
				state,
				actor,
				catalog.get_card(state.stadium_card_id).get("trainer_effects", []),
				"active",
				catalog,
			)
	return 0.0


func _effects_tactical_value(
	state: GameState,
	actor: int,
	effects: Array,
	source_slot: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	var opponent := state.get_player(1 - actor)
	var value := 0.0
	for effect in _flatten_effects(effects):
		var effect_type := str(effect.get("effect_type", ""))
		var params: Dictionary = effect.get("params", {})
		match effect_type:
			"draw", "draw_until", "draw_until_more":
				var amount := int(params.get("amount", params.get("target", 2)))
				if player.deck.size() <= amount:
					value -= 260.0
				else:
					value += min(amount, 7) * 34.0
					if player.hand.size() <= 3:
						value += 55.0
			"discard_draw", "shuffle_draw", "judge", "hand_to_bottom_draw", "discard_then_draw":
				var draw_count := int(params.get("draw", params.get("amount", 4)))
				if player.deck.size() <= draw_count:
					value -= 220.0
				else:
					value += 95.0 + min(draw_count, 7) * 24.0
					if player.hand.size() <= 4:
						value += 65.0
			"search", "conditional_search_extra", "search_any_and_switch", "arven", "clara", "houb":
				value += 125.0
				if player.bench_count() < 2:
					value += 35.0
			"energy_attach", "draw_and_attach_energy", "attach_from_discard", "look_top_attach_energy":
				value += 145.0
				if _has_energy_target_with_missing_cost(state, actor, catalog):
					value += 85.0
			"energy_relocate":
				value += _energy_relocate_value(state, actor, params, catalog)
			"heal", "heal_all", "potion_heal", "conditional_damage_heal", "damage_and_self_heal":
				value += _healing_value(state, actor)
			"switch_self":
				value += 65.0 if player.bench_count() > 0 else -80.0
			"switch_opponent":
				value += 75.0 if opponent.bench_count() > 0 else -80.0
			"energy_discard", "coin_flip_energy_discard":
				value += 90.0 if opponent.active and not opponent.active.energy_card_ids.is_empty() else -35.0
			"discard", "discard_hand_conditional_bonus":
				value += 55.0
			"prevent_damage", "prevent_all", "prevent_effects":
				value += 80.0
			"status", "conditional_status", "dazzling_beam", "attack_lock_basic", "apply_outgoing_damage_reduction", "self_attack_lock":
				value += 45.0
			"damage", "any_pokemon_damage", "place_counters_and_self_ko", "bench_damage", "damage_and_self_heal":
				value += int(params.get("amount", params.get("damage", 0))) * 1.2
			"damage_counter_self":
				value -= int(params.get("amount", params.get("damage", 20))) * 0.8
			"attack_damage_formula", "conditional_damage_bonus", "discard_fighting_energy_damage", "discard_hand_conditional_bonus":
				value += _effect_damage_estimate(state, actor, effect, catalog) * 1.1
	return value


func _flatten_effects(effects: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for effect_value in effects:
		if not effect_value is Dictionary:
			continue
		var effect: Dictionary = effect_value
		result.append(effect)
		var params: Dictionary = effect.get("params", {})
		for key in ["on_heads", "on_tails", "on_success", "on_fail", "on_pay", "cost"]:
			var branch: Variant = params.get(key, [])
			if branch is Dictionary:
				result.append_array(_flatten_effects([branch]))
			elif branch is Array:
				result.append_array(_flatten_effects(branch))
	return result


func _is_major_hand_refresh_action(
	state: GameState,
	actor: int,
	action: GameAction,
	catalog: CardCatalog,
) -> bool:
	if action.action != "PLAY_TRAINER":
		return false
	var card_id := _action_card_id(state, actor, action)
	for effect in _flatten_effects(catalog.get_card(card_id).get("trainer_effects", [])):
		if str(effect.get("effect_type", "")) in [
			"discard_draw", "shuffle_draw", "judge", "hand_to_bottom_draw", "discard_then_draw"
		]:
			return true
	return false


func _attack_effects(
	state: GameState,
	actor: int,
	attack_idx: int,
	catalog: CardCatalog,
) -> Array:
	var active := state.get_player(actor).active
	if active == null:
		return []
	var attacks: Array = catalog.get_card(active.card_id).get("attacks", [])
	if attack_idx < 0 or attack_idx >= attacks.size():
		return []
	return attacks[attack_idx].get("effects", [])


func _estimated_attack_damage(
	state: GameState,
	actor: int,
	attack_idx: int,
	catalog: CardCatalog,
) -> int:
	var player := state.get_player(actor)
	if player.active == null:
		return 0
	var attacks: Array = catalog.get_card(player.active.card_id).get("attacks", [])
	if attack_idx < 0 or attack_idx >= attacks.size():
		return 0
	var attack: Dictionary = attacks[attack_idx]
	var effects: Array = attack.get("effects", [])
	var full_damage := false
	var ignore_defender_effects := false
	var piercing := false
	var flattened := _flatten_effects(effects)
	for effect in flattened:
		var effect_type := str(effect.get("effect_type", ""))
		if effect_type in [
			"attack_damage_formula",
			"damage_per_self_damage",
			"damage_per_self_energy",
			"damage_per_self_energy_type",
			"damage_plus_bench",
			"damage_per_hand_size",
			"damage_per_energy",
			"damage_per_evolved",
			"damage_self_penalty",
			"damage_per_discard_psychic",
			"conditional_damage_heal",
			"discard_fighting_energy_damage",
			"discard_hand_conditional_bonus",
			"damage_and_self_heal",
			"any_pokemon_damage",
			"mill_and_damage_per_energy",
		]:
			full_damage = true
		if effect_type == "attack_damage_formula":
			var formula_params: Dictionary = effect.get("params", {})
			ignore_defender_effects = (
				ignore_defender_effects
				or bool(formula_params.get("ignore_defender_effects", false))
			)
			piercing = piercing or bool(formula_params.get("piercing", false))
	var damage := 0 if full_damage else int(attack.get("damage", 0))
	for effect in flattened:
		var effect_type := str(effect.get("effect_type", ""))
		if effect_type == "coin_flip":
			var params: Dictionary = effect.get("params", {})
			if _branch_has_effect_type(params.get("on_tails", []), "attack_fail"):
				damage = int(round(
					(float(damage) + float(_branch_damage_estimate(
						state, actor, params.get("on_heads", []), catalog))) * 0.5
				))
				continue
		var estimate := _effect_damage_estimate(state, actor, effect, catalog)
		if effect_type == "conditional_damage_bonus":
			damage += estimate
		else:
			damage = max(damage, estimate)
	return _modified_attack_damage(
		state, actor, damage, catalog, ignore_defender_effects, piercing)


func _effect_damage_estimate(
	state: GameState,
	actor: int,
	effect: Dictionary,
	catalog: CardCatalog,
) -> int:
	var player := state.get_player(actor)
	var opponent := state.get_player(1 - actor)
	var active := player.active
	var params: Dictionary = effect.get("params", {})
	match str(effect.get("effect_type", "")):
		"damage":
			return int(params.get("amount", 0))
		"conditional_damage_bonus":
			return int(params.get("bonus", params.get("amount", 0))) if _conditional_damage_bonus_applies(
				state, actor, params, catalog) else 0
		"damage_per_self_damage":
			return int(params.get("base", 0)) + (active.damage_counters if active else 0) * int(params.get("per_counter", 0))
		"damage_per_self_energy", "damage_per_self_energy_type":
			var filter := str(params.get("energy_filter", params.get("energy_type", ""))).to_lower()
			var count := 0
			if active:
				for energy_id in active.energy_card_ids:
					if filter.is_empty() or filter == "any":
						count += 1
					else:
						for provided in catalog.provides_energy(energy_id):
							if provided.to_lower() == filter:
								count += 1
								break
			return int(params.get("base", 0)) + count * int(params.get("per_energy", 0))
		"damage_per_energy":
			var count := 0
			match str(params.get("count_from", "self")):
				"opponent_active":
					count = opponent.active.energy_card_ids.size() if opponent.active else 0
				"all_opponent":
					for row in opponent.get_all_pokemon():
						var pokemon: PokemonState = row["pokemon"]
						if pokemon:
							count += pokemon.energy_card_ids.size()
				_:
					count = active.energy_card_ids.size() if active else 0
			return int(params.get("base", 0)) + count * int(params.get("per_energy", 0))
		"damage_plus_bench":
			return int(params.get("base", 0)) + player.bench_count() * int(params.get("per_bench", 0))
		"attack_damage_formula":
			var total := int(params.get("base", 0))
			total += player.bench_count() * int(params.get("per_own_bench", 0))
			var per_self_energy_type := str(params.get("per_self_energy_type", ""))
			if active and not per_self_energy_type.is_empty():
				var energy_count := 0
				for energy_id in active.energy_card_ids:
					if _energy_card_matches_type(energy_id, per_self_energy_type, catalog):
						energy_count += 1
				total += energy_count * int(params.get("per_energy", 0))
			if active:
				total += active.damage_counters * int(params.get("per_self_damage_counter", 0))
			var condition_bonus: Dictionary = params.get("condition_bonus", {})
			var condition := str(condition_bonus.get("condition", ""))
			var applies := false
			match condition:
				"ko_by_attack_last_turn":
					applies = player.was_ko_by_attack
				"own_bench_damaged":
					for bench_pokemon in player.bench:
						if bench_pokemon and bench_pokemon.damage_counters > 0:
							applies = true
							break
				"opponent_active_evolved":
					applies = opponent.active != null and not catalog.is_basic_pokemon(opponent.active.card_id)
				"opponent_active_damaged":
					applies = opponent.active != null and opponent.active.damage_counters > 0
				"own_hand_empty":
					applies = player.hand.is_empty()
			if applies:
				total += int(condition_bonus.get("bonus", 0))
			return total
		"damage_per_hand_size":
			return player.hand.size() * int(params.get("per", 0))
		"discard_hand_conditional_bonus":
			var hand_base := int(params.get("base_damage", params.get("base", 0)))
			var threshold := int(params.get("threshold", 5))
			return hand_base + (int(params.get("bonus", 0)) if player.hand.size() >= threshold else 0)
		"damage_per_discard_psychic":
			var psychic_count := 0
			for card_id in player.discard:
				if catalog.is_pokemon(card_id) and "Psychic" in catalog.get_card(card_id).get("energy_types", []):
					psychic_count += 1
			return int(params.get("base", 0)) + psychic_count * int(params.get("per_card", 0))
		"discard_fighting_energy_damage":
			var fighting_count := 0
			if active:
				for energy_id in active.energy_card_ids:
					if "Fighting" in catalog.provides_energy(energy_id):
						fighting_count += 1
			return int(params.get("base", 10)) + fighting_count * int(params.get("per_energy", 60))
		"damage_per_evolved":
			var evolved := 0
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				if pokemon and not pokemon.evolution_stack_ids.is_empty():
					evolved += 1
			return evolved * int(params.get("per_evolved", 0))
		"conditional_damage_heal":
			return int(params.get("base", 0)) + (int(params.get("bonus", 0)) if player.healed_this_turn else 0)
		"damage_and_self_heal":
			return int(params.get("damage", params.get("amount", 0)))
		"any_pokemon_damage", "bench_damage", "place_counters_and_self_ko":
			return int(params.get("amount", params.get("damage", 0)))
		"mill_and_damage_per_energy":
			var energy_seen := 0
			for card_id in player.deck.slice(max(0, player.deck.size() - int(params.get("mill_count", 5)))):
				if catalog.is_energy(card_id):
					energy_seen += 1
			return energy_seen * int(params.get("damage_per", 0))
		"damage_self_penalty":
			return max(0, int(params.get("base", 0)) - (active.damage_counters if active else 0) * int(params.get("per_counter", 0)))
		"coin_flip_triple":
			return int(float(params.get("damage_per_head", 10)) * 1.5)
		"coin_flip_until_tails":
			return int(params.get("per_head", 20))
		"coin_flip_double_ko":
			return int((opponent.active.current_hp(catalog) if opponent.active else 0) * 0.25)
		"coin_flip":
			return int((
				_branch_damage_estimate(state, actor, params.get("on_heads", []), catalog)
				+ _branch_damage_estimate(state, actor, params.get("on_tails", []), catalog)
			) * 0.5)
	return 0


func _conditional_damage_bonus_applies(
	state: GameState,
	actor: int,
	params: Dictionary,
	_catalog: CardCatalog,
) -> bool:
	var player := state.get_player(actor)
	var opponent := state.get_player(1 - actor)
	match str(params.get("condition", "")):
		"opponent_active_damaged":
			return opponent.active != null and opponent.active.damage_counters > 0
		"field_energy_ge_5":
			var count := 0
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				if pokemon:
					count += pokemon.energy_card_ids.size()
			return count >= 5
		"opponent_active_evolved":
			return opponent.active != null and not _catalog.is_basic_pokemon(opponent.active.card_id)
		"ko_by_attack_last_turn":
			return player.was_ko_by_attack
		_:
			return opponent.active != null and opponent.active.damage_counters > 0


func _branch_damage_estimate(
	state: GameState,
	actor: int,
	branch: Variant,
	catalog: CardCatalog,
) -> int:
	var effects: Array = []
	if branch is Dictionary:
		effects = [branch]
	elif branch is Array:
		effects = branch
	var best := 0
	for effect in _flatten_effects(effects):
		best = max(best, _effect_damage_estimate(state, actor, effect, catalog))
	return best


func _branch_has_effect_type(branch: Variant, effect_type: String) -> bool:
	var effects: Array = []
	if branch is Dictionary:
		effects = [branch]
	elif branch is Array:
		effects = branch
	for effect in _flatten_effects(effects):
		if str(effect.get("effect_type", "")) == effect_type:
			return true
	return false


func _energy_card_matches_type(
	card_id: String,
	energy_type: String,
	catalog: CardCatalog,
) -> bool:
	var normalized := energy_type.to_lower()
	if normalized in ["", "any", "energy"]:
		return catalog.is_energy(card_id)
	if normalized in ["basic", "basic_energy"]:
		return catalog.is_basic_energy(card_id)
	if not catalog.is_energy(card_id):
		return false
	for provided in catalog.provides_energy(card_id):
		var provided_type := str(provided).to_lower()
		if provided_type == normalized or provided_type == "rainbow":
			return true
	return false


func _modified_attack_damage(
	state: GameState,
	actor: int,
	base_damage: int,
	catalog: CardCatalog,
	ignore_defender_effects: bool = false,
	piercing: bool = false,
) -> int:
	var attacker := state.get_player(actor).active
	var defender := state.get_player(1 - actor).active
	if attacker == null or defender == null or base_damage <= 0:
		return max(0, base_damage)
	var damage := base_damage
	if not ignore_defender_effects:
		for ability_value in catalog.get_card(defender.card_id).get("abilities", []):
			var ability: Dictionary = ability_value
			for effect_value in ability.get("effects", []):
				var effect: Dictionary = effect_value
				if str(effect.get("effect_type", "")) == "aura_damage_reduction":
					var params: Dictionary = effect.get("params", {})
					if (
						bool(params.get("requires_attached_energy", false))
						and defender.energy_card_ids.is_empty()
					):
						continue
					damage -= int(params.get("reduction", 20))
	for row in state.get_player(actor).get_all_pokemon():
		var aura_source: PokemonState = row["pokemon"]
		if aura_source == null:
			continue
		for ability_value in catalog.get_card(aura_source.card_id).get("abilities", []):
			var ability: Dictionary = ability_value
			for effect_value in ability.get("effects", []):
				var effect: Dictionary = effect_value
				if str(effect.get("effect_type", "")) != "aura_damage_boost":
					continue
				var params: Dictionary = effect.get("params", {})
				var attacker_subtype := str(params.get("attacker_subtype", ""))
				var defender_type := str(params.get("defender_type", ""))
				if (
					not attacker_subtype.is_empty()
					and attacker_subtype not in catalog.get_card(attacker.card_id).get("subtypes", [])
				):
					continue
				if (
					not defender_type.is_empty()
					and defender_type not in catalog.get_card(defender.card_id).get("energy_types", [])
				):
					continue
				damage += int(params.get("amount", 0))
	for energy_id in attacker.energy_card_ids:
		if energy_id == "svi-dtur":
			damage -= 20
	if attacker.outgoing_damage_reduction_next_turn > 0:
		damage -= attacker.outgoing_damage_reduction_next_turn
	if not attacker.attached_tool_id.is_empty():
		for effect_value in catalog.get_card(attacker.attached_tool_id).get("trainer_effects", []):
			var effect: Dictionary = effect_value
			if str(effect.get("effect_type", "")) != "tool":
				continue
			var modifier := str(effect.get("params", {}).get("effect", ""))
			if modifier == "damage_boost_10":
				damage += 10
			elif (
				modifier == "damage_boost_when_behind"
				and state.get_player(actor).prizes.size() > state.get_player(1 - actor).prizes.size()
			):
				damage += 30
	if not ignore_defender_effects and not defender.attached_tool_id.is_empty():
		for effect_value in catalog.get_card(defender.attached_tool_id).get("trainer_effects", []):
			var effect: Dictionary = effect_value
			if str(effect.get("effect_type", "")) != "tool":
				continue
			var modifier := str(effect.get("params", {}).get("effect", ""))
			if modifier == "damage_reduction_stage1" and catalog.is_stage1(defender.card_id):
				damage -= int(effect.get("params", {}).get("amount", 30))
	if state.apply_type_matchups and not piercing:
		var attacking_type := "Colorless"
		var attacking_card := catalog.get_card(attacker.card_id)
		if not attacking_card.get("energy_types", []).is_empty():
			attacking_type = str(attacking_card.get("energy_types", [])[0])
		var defending_card := catalog.get_card(defender.card_id)
		for weakness_value in defending_card.get("weaknesses", []):
			var weakness: Dictionary = weakness_value
			if str(weakness.get("energy_type", "")) == attacking_type:
				if str(weakness.get("value", "")) in ["x2", "×2"]:
					damage *= 2
				break
		for resistance_value in defending_card.get("resistances", []):
			var resistance: Dictionary = resistance_value
			if str(resistance.get("energy_type", "")) == attacking_type:
				damage -= abs(int(str(resistance.get("value", "0")).replace("-", "")))
				break
	return max(0, damage)


func _attack_draw_pressure_is_unsafe(
	state: GameState,
	actor: int,
	action: GameAction,
	catalog: CardCatalog,
) -> bool:
	if action.action != "DECLARE_ATTACK":
		return false
	var draw_amount := 0
	for effect in _flatten_effects(_attack_effects(
		state, actor, int(action.params.get("attack_idx", -1)), catalog)):
		if str(effect.get("effect_type", "")) in ["draw", "draw_until", "draw_until_more"]:
			draw_amount += int(effect.get("params", {}).get("amount", 2))
	return draw_amount > 0 and state.get_player(actor).deck.size() <= draw_amount


func _attack_feeds_dangerous_retaliation(
	state: GameState,
	actor: int,
	action: GameAction,
	catalog: CardCatalog,
) -> bool:
	if action.action != "DECLARE_ATTACK":
		return false
	var player := state.get_player(actor)
	var opponent := state.get_player(1 - actor)
	if player.active == null or opponent.active == null:
		return false
	var damage := _estimated_attack_damage(
		state, actor, int(action.params.get("attack_idx", -1)), catalog)
	if damage <= 0 or damage >= opponent.active.current_hp(catalog):
		return false
	var has_retaliation_scaler := false
	for attack in catalog.get_card(opponent.active.card_id).get("attacks", []):
		for effect in _flatten_effects(attack.get("effects", [])):
			if str(effect.get("effect_type", "")) == "damage_per_self_damage":
				has_retaliation_scaler = true
				break
	if not has_retaliation_scaler:
		return false
	var before := _best_potential_retaliation_damage(state, 1 - actor, catalog)
	var simulated := GameState.from_dict(state.snapshot())
	var simulated_opponent := simulated.get_player(1 - actor).active
	if simulated_opponent == null:
		return false
	simulated_opponent.damage_counters += max(1, damage / 10)
	var after := _best_potential_retaliation_damage(simulated, 1 - actor, catalog)
	if after >= player.active.current_hp(catalog):
		return true
	return damage < 100 and after > before + 30 and after >= 90


func _best_potential_retaliation_damage(
	state: GameState,
	actor: int,
	catalog: CardCatalog,
) -> int:
	var player := state.get_player(actor)
	if player.active == null:
		return 0
	var best := 0
	var attacks: Array = catalog.get_card(player.active.card_id).get("attacks", [])
	for attack_idx in range(attacks.size()):
		var attack: Dictionary = attacks[attack_idx]
		var missing := _missing_energy_count(player.active, attack.get("cost", []), catalog)
		if missing <= 1:
			best = max(best, _estimated_attack_damage(state, actor, attack_idx, catalog))
	return best


func _switch_self_has_good_target(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> bool:
	var player := state.get_player(actor)
	if player.active == null or player.bench_count() <= 0:
		return false
	for index in range(player.bench.size()):
		if player.bench[index] and _retreat_has_good_target(state, actor, index, deck_key, catalog):
			return true
	return false


func _switch_opponent_has_good_target(
	state: GameState,
	actor: int,
	target_player: int,
	catalog: CardCatalog,
) -> bool:
	var opponent := state.get_player(target_player)
	if opponent.active == null or opponent.bench_count() <= 0:
		return false
	var active_priority := _target_priority(opponent.active, catalog)
	var best_bench_priority := -INF
	for pokemon in opponent.bench:
		if pokemon:
			best_bench_priority = max(best_bench_priority, _target_priority(pokemon, catalog))
	if best_bench_priority <= active_priority + 20.0:
		return false
	var own_active := state.get_player(actor).active
	if own_active != null:
		var current_ko := _best_available_damage(state, actor, catalog) >= opponent.active.current_hp(catalog)
		if current_ko:
			return false
	return true


func _retreat_has_good_target(
	state: GameState,
	actor: int,
	bench_idx: int,
	deck_key: String,
	catalog: CardCatalog,
) -> bool:
	var player := state.get_player(actor)
	if player.active == null or bench_idx < 0 or bench_idx >= player.bench.size():
		return false
	var target: PokemonState = player.bench[bench_idx]
	if target == null:
		return false
	var opponent := state.get_player(1 - actor)
	var target_ready_damage := _best_ready_pokemon_damage(state, actor, target, catalog)
	if opponent.active != null and target_ready_damage >= opponent.active.current_hp(catalog):
		return true
	var opponent_damage := _best_available_damage(state, 1 - actor, catalog)
	var active_survives := opponent_damage < player.active.current_hp(catalog)
	var target_falls := opponent_damage >= target.current_hp(catalog)
	if active_survives and target_falls:
		return false
	var target_is_core := AIDeckProfiles.contains(deck_key, "core", target.card_id)
	var target_is_engine := (
		AIDeckProfiles.contains(deck_key, "engine", target.card_id)
		or AIDeckProfiles.contains(deck_key, "bench", target.card_id)
	)
	var active_max_hp := int(catalog.get_card(player.active.card_id).get("hp", 0))
	var active_safe: bool = (
		player.active.status_conditions.is_empty()
		and player.active.current_hp(catalog) > max(50, active_max_hp * 0.45)
	)
	if active_safe and not target_is_core and target_is_engine and target_ready_damage < 70:
		return false
	var active_value := _promotion_value_for_state(
		state, actor, player.active, deck_key, catalog)
	var target_value := _promotion_value_for_state(state, actor, target, deck_key, catalog)
	if (
		not player.active.status_conditions.is_empty()
		or player.active.current_hp(catalog) <= max(40, active_max_hp * 0.35)
	):
		return target_value > active_value - 20.0
	return target_value > active_value + 25.0


func _promotion_value_for_state(
	state: GameState,
	actor: int,
	pokemon: PokemonState,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	if pokemon == null:
		return -INF
	var value := _pokemon_strength(pokemon, catalog)
	var missing := _best_missing_energy(pokemon, catalog)
	var ready_damage := _best_ready_pokemon_damage(state, actor, pokemon, catalog)
	var opponent := state.get_player(1 - actor)
	if missing == 0:
		value += 140.0 + ready_damage * 0.85
		if opponent.active != null and ready_damage >= opponent.active.current_hp(catalog):
			value += 240.0 + catalog.prize_value(opponent.active.card_id) * 110.0
	elif missing == 1:
		value += 55.0 + _best_pokemon_damage(pokemon, catalog) * 0.20
	else:
		value -= min(120.0, missing * 35.0)
	value += pokemon.energy_card_ids.size() * 18.0
	if _best_available_damage_against_candidate(state, actor, pokemon, catalog) >= pokemon.current_hp(catalog):
		value -= 85.0
		var can_trade := opponent.active != null and ready_damage >= opponent.active.current_hp(catalog)
		if not can_trade:
			value -= 90.0
			if AIDeckProfiles.contains(deck_key, "core", pokemon.card_id):
				value -= 55.0
			if AIDeckProfiles.contains(deck_key, "engine", pokemon.card_id):
				value -= 30.0
	if (
		missing > 0
		and AIDeckProfiles.contains(deck_key, "bench", pokemon.card_id)
		and not AIDeckProfiles.contains(deck_key, "setup", pokemon.card_id)
	):
		value -= 70.0 + min(80.0, missing * 24.0)
	return value


func _best_ready_pokemon_damage(
	state: GameState,
	actor: int,
	pokemon: PokemonState,
	catalog: CardCatalog,
) -> int:
	if pokemon == null:
		return 0
	var player := state.get_player(actor)
	var original_active := player.active
	var best := 0
	player.active = pokemon
	for attack_idx in range(catalog.get_card(pokemon.card_id).get("attacks", []).size()):
		var attack: Dictionary = catalog.get_card(pokemon.card_id).get("attacks", [])[attack_idx]
		if _missing_energy_count(pokemon, attack.get("cost", []), catalog) <= 0:
			best = max(best, _estimated_attack_damage(state, actor, attack_idx, catalog))
	player.active = original_active
	return best


func _best_available_damage(
	state: GameState,
	actor: int,
	catalog: CardCatalog,
) -> int:
	var player := state.get_player(actor)
	if player.active == null:
		return 0
	var best := 0
	var attacks: Array = catalog.get_card(player.active.card_id).get("attacks", [])
	for attack_idx in range(attacks.size()):
		var attack: Dictionary = attacks[attack_idx]
		if _missing_energy_count(player.active, attack.get("cost", []), catalog) <= 0:
			best = max(best, _estimated_attack_damage(state, actor, attack_idx, catalog))
	return best


func _best_available_damage_against_candidate(
	state: GameState,
	actor: int,
	candidate: PokemonState,
	catalog: CardCatalog,
) -> int:
	var player := state.get_player(actor)
	var original_active := player.active
	player.active = candidate
	var damage := _best_available_damage(state, 1 - actor, catalog)
	player.active = original_active
	return damage


func _has_alternative_setup_active_in_hand(
	state: GameState,
	actor: int,
	card_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> bool:
	var player := state.get_player(actor)
	for hand_card_id in player.hand:
		if (
			hand_card_id != card_id
			and catalog.is_basic_pokemon(hand_card_id)
			and AIDeckProfiles.contains(deck_key, "setup", hand_card_id)
		):
			return true
	return false


func _best_missing_energy(pokemon: PokemonState, catalog: CardCatalog) -> int:
	if pokemon == null:
		return 99
	var attacks: Array = catalog.get_card(pokemon.card_id).get("attacks", [])
	if attacks.is_empty():
		return 99
	var best := 99
	for attack in attacks:
		best = min(best, _missing_energy_count(pokemon, attack.get("cost", []), catalog))
	return best


func _best_missing_energy_with_extra(
	pokemon: PokemonState,
	energy_card_id: String,
	catalog: CardCatalog,
) -> int:
	if pokemon == null:
		return 99
	var attacks: Array = catalog.get_card(pokemon.card_id).get("attacks", [])
	if attacks.is_empty():
		return 99
	var best := 99
	for attack in attacks:
		best = min(best, _missing_energy_count_with_extra(
			pokemon, attack.get("cost", []), energy_card_id, catalog))
	return best


func _missing_energy_count(pokemon: PokemonState, cost: Array, catalog: CardCatalog) -> int:
	if pokemon == null:
		return 99
	return _missing_energy_count_from_available(pokemon.available_energy(catalog), cost)


func _missing_energy_count_with_extra(
	pokemon: PokemonState,
	cost: Array,
	energy_card_id: String,
	catalog: CardCatalog,
) -> int:
	if pokemon == null:
		return 99
	var available := pokemon.available_energy(catalog)
	available.append_array(catalog.provides_energy(energy_card_id))
	return _missing_energy_count_from_available(available, cost)


func _missing_energy_count_from_available(available_input: Array[String], cost: Array) -> int:
	var available := available_input.duplicate()
	var missing := 0
	var colorless := 0
	for required_value in cost:
		var required := str(required_value)
		if required == "Colorless":
			colorless += 1
			continue
		var index := available.find(required)
		if index < 0:
			index = available.find("Rainbow")
		if index >= 0:
			available.remove_at(index)
		else:
			missing += 1
	return missing + max(0, colorless - available.size())


func _best_pokemon_damage(pokemon: PokemonState, catalog: CardCatalog) -> int:
	if pokemon == null:
		return 0
	var best := 0
	for attack in catalog.get_card(pokemon.card_id).get("attacks", []):
		var damage := int(attack.get("damage", 0))
		for effect in _flatten_effects(attack.get("effects", [])):
			var params: Dictionary = effect.get("params", {})
			match str(effect.get("effect_type", "")):
				"damage_per_self_damage":
					damage = max(damage, int(params.get("base", 0)) + pokemon.damage_counters * int(params.get("per_counter", 0)))
				"damage_per_self_energy", "damage_per_self_energy_type":
					damage = max(damage, int(params.get("base", 0)) + pokemon.energy_card_ids.size() * int(params.get("per_energy", 0)))
				"damage_plus_bench":
					damage = max(damage, int(params.get("base", 0)) + int(params.get("per_bench", 0)) * 3)
				"attack_damage_formula":
					var formula_damage := int(params.get("base", 0))
					formula_damage += int(params.get("per_own_bench", 0)) * 3
					if not str(params.get("per_self_energy_type", "")).is_empty():
						formula_damage += pokemon.energy_card_ids.size() * int(params.get("per_energy", 0))
					var condition_bonus: Dictionary = params.get("condition_bonus", {})
					formula_damage += int(condition_bonus.get("bonus", 0))
					damage = max(damage, formula_damage)
		best = max(best, damage)
	return best


func _pokemon_card_strength(card_id: String, energy_count: int, catalog: CardCatalog) -> float:
	var card := catalog.get_card(card_id)
	var best_damage := 0
	for attack in card.get("attacks", []):
		var damage := int(attack.get("damage", 0))
		for effect_value in _flatten_effects(attack.get("effects", [])):
			var effect: Dictionary = effect_value
			var params: Dictionary = effect.get("params", {})
			match str(effect.get("effect_type", "")):
				"damage_plus_bench":
					damage = max(damage, int(params.get("base", 0)) + int(params.get("per_bench", 0)) * 3)
				"damage_per_self_energy", "damage_per_self_energy_type":
					damage = max(damage, int(params.get("base", 0)) + energy_count * int(params.get("per_energy", 0)))
				"attack_damage_formula":
					var formula_damage := int(params.get("base", 0))
					formula_damage += int(params.get("per_own_bench", 0)) * 3
					if not str(params.get("per_self_energy_type", "")).is_empty():
						formula_damage += energy_count * int(params.get("per_energy", 0))
					formula_damage += int(Dictionary(params.get("condition_bonus", {})).get("bonus", 0))
					damage = max(damage, formula_damage)
		best_damage = max(best_damage, damage)
	return int(card.get("hp", 0)) + best_damage * 2.0 + energy_count * 35.0


func _energy_matches_profile(card_id: String, deck_key: String, catalog: CardCatalog) -> bool:
	var provided := catalog.provides_energy(card_id)
	for energy_type in AIDeckProfiles.get_profile(deck_key).get("energy", []):
		if energy_type in provided or "Rainbow" in provided:
			return true
	return false


func _has_energy_target_with_missing_cost(
	state: GameState,
	actor: int,
	catalog: CardCatalog,
) -> bool:
	for row in state.get_player(actor).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var best_missing := _best_missing_energy(pokemon, catalog)
		if best_missing > 0 and best_missing < 99:
			return true
		var attacks: Array = catalog.get_card(pokemon.card_id).get("attacks", [])
		for attack in attacks:
			var missing := _missing_energy_count(pokemon, attack.get("cost", []), catalog)
			if missing > 0 and missing <= 2:
				return true
	return false


func _energy_relocate_value(
	state: GameState,
	actor: int,
	params: Dictionary,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	if player.active == null or player.bench_count() <= 0:
		return -120.0
	var energy_type := str(params.get("energy_type", params.get("filter", "any")))
	var best := -120.0
	for source_row in player.get_all_pokemon():
		var source: PokemonState = source_row["pokemon"]
		var source_slot := str(source_row["slot"])
		if source == null:
			continue
		for energy_id in source.energy_card_ids:
			if not _energy_card_matches_type(energy_id, energy_type, catalog):
				continue
			for target_row in player.get_all_pokemon():
				var target: PokemonState = target_row["pokemon"]
				var target_slot := str(target_row["slot"])
				if target == null or target_slot == source_slot:
					continue
				var before := _best_missing_energy(target, catalog)
				var after := _best_missing_energy_with_extra(target, energy_id, catalog)
				if after >= before:
					continue
				var value := float(before - after) * 85.0
				if target_slot == "active":
					value += 90.0
				if after == 0:
					value += 130.0 + _best_pokemon_damage(target, catalog) * 0.20
				if source_slot == "active" and target_slot != "active":
					value -= 80.0
				best = max(best, value)
	return best


func _should_avoid_repeating_ability(
	state: GameState,
	actor: int,
	action: GameAction,
	catalog: CardCatalog,
) -> bool:
	if action.action != "USE_ABILITY" or state.action_log.is_empty():
		return false
	var ability_name := str(action.params.get("ability_name", ""))
	if ability_name.is_empty():
		return false
	if not _ability_is_repeatable(state, actor, action, ability_name, catalog):
		return false
	return ability_name in str(state.action_log[-1])


func _ability_is_repeatable(
	state: GameState,
	actor: int,
	action: GameAction,
	ability_name: String,
	catalog: CardCatalog,
) -> bool:
	var slot := str(action.params.get("slot", "active"))
	var pokemon := state.get_player(actor).get_pokemon(slot)
	if pokemon == null:
		return false
	for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if (
			str(ability.get("name", "")) == ability_name
			and str(ability.get("trigger", "")) == "repeatable"
		):
			return true
	return false


func _healing_value(state: GameState, actor: int) -> float:
	var value := 0.0
	for row in state.get_player(actor).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon:
			value += min(120.0, pokemon.damage_counters * 22.0)
	return value


func _find_action(actions: Array[GameAction], action_name: String) -> GameAction:
	for action in actions:
		if action.action == action_name:
			return action
	return null


func _card_priority(card_id: String, deck_key: String, catalog: CardCatalog) -> float:
	if card_id.is_empty():
		return 0.0
	var score := 0.0
	if AIDeckProfiles.contains(deck_key, "core", card_id):
		score += 180.0
	if AIDeckProfiles.contains(deck_key, "engine", card_id):
		score += 100.0
	if AIDeckProfiles.contains(deck_key, "evolution", card_id):
		score += 120.0
	if AIDeckProfiles.contains(deck_key, "trainer", card_id):
		score += 60.0
	var provided := catalog.provides_energy(card_id)
	for energy_type in AIDeckProfiles.get_profile(deck_key).get("energy", []):
		if energy_type in provided or "Rainbow" in provided:
			score += 50.0
	return score


func _pokemon_strength(pokemon: PokemonState, catalog: CardCatalog) -> float:
	if pokemon == null:
		return -1000.0
	var card := catalog.get_card(pokemon.card_id)
	var best_damage := 0
	for attack in card.get("attacks", []):
		var damage := int(attack.get("damage", 0))
		for effect_value in _flatten_effects(attack.get("effects", [])):
			var effect: Dictionary = effect_value
			var params: Dictionary = effect.get("params", {})
			match str(effect.get("effect_type", "")):
				"damage_plus_bench":
					damage = max(damage, int(params.get("base", 0)) + int(params.get("per_bench", 0)) * 3)
				"damage_per_self_energy", "damage_per_self_energy_type":
					damage = max(damage, int(params.get("base", 0)) + pokemon.energy_card_ids.size() * int(params.get("per_energy", 0)))
				"attack_damage_formula":
					var formula_damage := int(params.get("base", 0))
					formula_damage += int(params.get("per_own_bench", 0)) * 3
					if not str(params.get("per_self_energy_type", "")).is_empty():
						formula_damage += pokemon.energy_card_ids.size() * int(params.get("per_energy", 0))
					formula_damage += int(Dictionary(params.get("condition_bonus", {})).get("bonus", 0))
					damage = max(damage, formula_damage)
		best_damage = max(best_damage, damage)
	return (
		pokemon.current_hp(catalog)
		+ best_damage * 2.0
		+ pokemon.energy_card_ids.size() * 35.0
	)


func _evaluate(state: GameState, perspective: int, catalog: CardCatalog) -> float:
	return clampf(_evaluate_raw(state, perspective, catalog) / 1800.0, -1.0, 1.0)


func _evaluate_raw(state: GameState, perspective: int, catalog: CardCatalog) -> float:
	if state.winner >= 0:
		return 1800.0 if state.winner == perspective else -1800.0
	var own := state.get_player(perspective)
	var opponent := state.get_player(1 - perspective)
	var score := float(opponent.prizes.size() - own.prizes.size()) * 220.0
	score += (own.hand.size() - opponent.hand.size()) * 4.0
	score += (own.deck.size() - opponent.deck.size()) * 0.5
	for row in own.get_all_pokemon():
		score += _pokemon_strength(row["pokemon"], catalog) if row["pokemon"] else 0.0
	for row in opponent.get_all_pokemon():
		score -= _pokemon_strength(row["pokemon"], catalog) if row["pokemon"] else 0.0
	return score


func _select_ucb(
	visits: Array[int],
	totals: Array[float],
	priors: Array[float],
	total_visits: int,
) -> int:
	var best_unvisited := -1
	var best_unvisited_prior := -INF
	for index in range(visits.size()):
		if visits[index] == 0:
			var prior := priors[index] if index < priors.size() else 0.0
			if best_unvisited < 0 or prior > best_unvisited_prior:
				best_unvisited = index
				best_unvisited_prior = prior
	if best_unvisited >= 0:
		return best_unvisited
	var best := 0
	var best_score := -INF
	for index in range(visits.size()):
		var average := totals[index] / visits[index]
		var exploration := (
			1.4 * priors[index] * sqrt(float(total_visits + 1)) / (visits[index] + 1)
		)
		if average + exploration > best_score:
			best_score = average + exploration
			best = index
	return best


func _current_actor(state: GameState) -> int:
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		return 0 if not state.setup_ready[0] else 1
	return state.active_player_idx


func _deck_key_for_actor(state: GameState, actor: int, fallback: String) -> String:
	if actor >= 0 and actor < state.public_deck_keys.size():
		var deck_key := str(state.public_deck_keys[actor])
		if not deck_key.is_empty():
			return deck_key
	return fallback


func _neural_action_priors(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	inference: Variant,
) -> Dictionary:
	var observation := AIObservationBuilder.build(state, actor)
	var encoder := AIActionEncoder.new(catalog)
	var encoded_state := encoder.encode_observation(observation, deck_key)
	var action_numeric: Array[float] = []
	var action_cards: Array[int] = []
	for action in actions:
		var encoded := encoder.encode_action(observation, action, deck_key)
		action_numeric.append_array(encoded["numeric"])
		action_cards.append(int(encoded["card_id"]))
	var outputs: Dictionary = inference.call(
		"infer",
		PackedFloat32Array(encoded_state["numeric"]),
		PackedInt64Array(encoded_state["card_ids"]),
		PackedFloat32Array(action_numeric),
		PackedInt64Array(action_cards),
			PackedFloat32Array(_zero_numeric()),
		PackedInt64Array([0]),
	)
	if not bool(outputs.get("success", false)):
		return outputs
	var logits: Array = outputs.get("action_logits", [])
	if logits.size() != actions.size():
		return {"success": false, "error": "action_output_size"}
	return {"success": true, "priors": _softmax(logits)}


func _neural_choice(
	state: GameState,
	request: ChoiceRequest,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
	inference: Variant,
) -> Dictionary:
	var observation := AIObservationBuilder.build(state, actor)
	var encoder := AIActionEncoder.new(catalog)
	var encoded_state := encoder.encode_observation(observation, deck_key)
	var choice_numeric: Array[float] = []
	var choice_cards: Array[int] = []
	for index in range(request.options.size()):
		var encoded := encoder.encode_choice(
			observation, request, request.options[index], index)
		choice_numeric.append_array(encoded["numeric"])
		choice_cards.append(int(encoded["card_id"]))
	var outputs: Dictionary = inference.call(
		"infer",
		PackedFloat32Array(encoded_state["numeric"]),
		PackedInt64Array(encoded_state["card_ids"]),
			PackedFloat32Array(_zero_numeric()),
		PackedInt64Array([0]),
		PackedFloat32Array(choice_numeric),
		PackedInt64Array(choice_cards),
	)
	if not bool(outputs.get("success", false)):
		return outputs
	var logits: Array = outputs.get("choice_logits", [])
	if logits.size() != request.options.size():
		return {"success": false, "error": "choice_output_size"}
	var ranked: Array[int] = []
	for index in range(logits.size()):
		ranked.append(index)
	ranked.sort_custom(func(left: int, right: int) -> bool:
		return float(logits[left]) > float(logits[right])
	)
	var count: int = maxi(request.min_select, request.max_select)
	if not request.allow_duplicates:
		count = mini(request.options.size(), count)
	return {
		"success": true,
		"response": ChoiceResponse.new(
			request.request_id,
			_ranked_choice_option_ids(request, ranked, count),
		),
	}


func _softmax(logits: Array) -> Array[float]:
	var maximum := -INF
	for value in logits:
		maximum = max(maximum, float(value))
	var result: Array[float] = []
	var total := 0.0
	for value in logits:
		var probability := exp(clampf(float(value) - maximum, -60.0, 60.0))
		result.append(probability)
		total += probability
	for index in range(result.size()):
		result[index] /= max(total, 0.000001)
	return result


func _zero_numeric() -> Array[float]:
	var values: Array[float] = []
	values.resize(AIActionEncoder.ACTION_NUMERIC_SIZE)
	values.fill(0.0)
	return values
