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
	var deck_key := str(request.get("deck_key", ""))
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
	var seed := int(request.get("seed", 17))
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
			seed + completed * 7919,
			catalog,
		)
		var simulation_rng := PortableRandomSource.new(seed + completed * 104729)
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
	return {
		"success": true,
		"kind": "action",
		"action": actions[best].to_dict(),
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
		var action := _best_heuristic_action(state, actor, actions, deck_key, catalog)
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
		var response := _heuristic_choice(state, request, deck_key, catalog)
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
		response = _heuristic_choice(state, request, deck_key, catalog)
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
		return ChoiceResponse.new(request.request_id, [])
	var ranked: Array[int] = []
	for index in range(request.options.size()):
		ranked.append(index)
	ranked.sort_custom(func(left: int, right: int) -> bool:
		return _option_score(
			state, request, request.options[left], deck_key, catalog
		) > _option_score(
			state, request, request.options[right], deck_key, catalog
		)
	)
	var count: int = mini(
		request.options.size(),
		maxi(request.min_select, request.max_select),
	)
	var selected: Array[String] = []
	if request.allow_duplicates and count > 0:
		for _index in range(count):
			selected.append(str(request.options[ranked[0]]["option_id"]))
	else:
		for index in ranked.slice(0, count):
			selected.append(str(request.options[index]["option_id"]))
	return ChoiceResponse.new(request.request_id, selected)


func _option_score(
	state: GameState,
	request: ChoiceRequest,
	option: Dictionary,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var option_id := str(option.get("option_id", ""))
	if request.request_type == "confirm":
		return 1000.0 if option_id == "confirm:yes" else 0.0
	var ref: Dictionary = option.get("ref", {})
	var value: Dictionary = option.get("value", {})
	var card_id := str(ref.get("card_id", value.get("card_id", "")))
	var score := _card_priority(card_id, deck_key, catalog)
	var slot := str(ref.get("slot", value.get("slot", "")))
	var target_player := int(ref.get("player", request.player))
	var pokemon := state.get_player(target_player).get_pokemon(slot)
	if pokemon:
		var hp := pokemon.current_hp(catalog)
		if target_player != request.player:
			score += 500.0 - hp
		elif "heal" in request.request_type:
			score += pokemon.damage_counters * 30.0
		else:
			score += pokemon.energy_card_ids.size() * 12.0
			if slot == "active":
				score += 20.0
	return score


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


func _action_score(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	var card_id := action.source.card_id if action.source else ""
	var score := _card_priority(card_id, deck_key, catalog)
	match action.action:
		"PLAY_BASIC":
			score += 180.0
			if str(action.params.get("target", "")) == "active":
				score += 200.0
			if AIDeckProfiles.contains(deck_key, "setup", card_id):
				score += 160.0
		"SETUP_DONE":
			score -= 30.0 if player.bench_count() < 2 else 0.0
		"EVOLVE":
			score += 320.0
		"ATTACH_ENERGY":
			score += 220.0
			if str(action.params.get("target_slot", "")) == "active":
				score += 90.0
		"PLAY_TRAINER":
			score += 160.0
		"USE_ABILITY", "USE_STADIUM":
			score += 190.0
		"RETREAT":
			score += 70.0
		"PROMOTE":
			var bench_idx := int(action.params.get("bench_idx", -1))
			if bench_idx >= 0 and bench_idx < player.bench.size():
				var pokemon: PokemonState = player.bench[bench_idx]
				score += _pokemon_strength(pokemon, catalog)
		"DECLARE_ATTACK":
			score += 500.0
			if player.active:
				var attacks: Array = catalog.get_card(player.active.card_id).get("attacks", [])
				var attack_idx := int(action.params.get("attack_idx", -1))
				if attack_idx >= 0 and attack_idx < attacks.size():
					var damage := int(attacks[attack_idx].get("damage", 0))
					score += damage * 3.0
					var opponent := state.get_opponent(actor)
					if opponent.active and damage >= opponent.active.current_hp(catalog):
						score += 900.0
		"END_TURN":
			score -= 120.0
	return score


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
		best_damage = max(best_damage, int(attack.get("damage", 0)))
	return (
		pokemon.current_hp(catalog)
		+ best_damage * 2.0
		+ pokemon.energy_card_ids.size() * 35.0
	)


func _evaluate(state: GameState, perspective: int, catalog: CardCatalog) -> float:
	if state.winner >= 0:
		return 1.0 if state.winner == perspective else -1.0
	var own := state.get_player(perspective)
	var opponent := state.get_player(1 - perspective)
	var score := float(opponent.prizes.size() - own.prizes.size()) * 220.0
	score += (own.hand.size() - opponent.hand.size()) * 4.0
	score += (own.deck.size() - opponent.deck.size()) * 0.5
	for row in own.get_all_pokemon():
		score += _pokemon_strength(row["pokemon"], catalog) if row["pokemon"] else 0.0
	for row in opponent.get_all_pokemon():
		score -= _pokemon_strength(row["pokemon"], catalog) if row["pokemon"] else 0.0
	return clampf(score / 1800.0, -1.0, 1.0)


func _select_ucb(
	visits: Array[int],
	totals: Array[float],
	priors: Array[float],
	total_visits: int,
) -> int:
	for index in range(visits.size()):
		if visits[index] == 0:
			return index
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
	var count: int = mini(
		request.options.size(),
		maxi(request.min_select, request.max_select),
	)
	var selected: Array[String] = []
	if request.allow_duplicates and count > 0:
		for _index in range(count):
			selected.append(str(request.options[ranked[0]]["option_id"]))
	else:
		for index in ranked.slice(0, count):
			selected.append(str(request.options[index]["option_id"]))
	return {
		"success": true,
		"response": ChoiceResponse.new(request.request_id, selected),
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
