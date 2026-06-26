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
			if AIDeckProfiles.contains(deck_key, "setup", card_id):
				score += 160.0
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
			score += 190.0
			score += _development_action_value(state, actor, action, deck_key, catalog) * 0.75
		"RETREAT":
			score += 70.0
			var bench_idx := int(action.params.get("bench_idx", -1))
			if bench_idx >= 0 and bench_idx < player.bench.size():
				var target: PokemonState = player.bench[bench_idx]
				if target != null and player.active != null:
					score += (
						_best_pokemon_damage(target, catalog)
						- _best_pokemon_damage(player.active, catalog)
					) * 1.3
		"PROMOTE":
			var promote_idx := int(action.params.get("bench_idx", -1))
			if promote_idx >= 0 and promote_idx < player.bench.size():
				var pokemon: PokemonState = player.bench[promote_idx]
				score += _pokemon_strength(pokemon, catalog)
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
			"energy_attach", "draw_and_attach_energy", "attach_from_discard":
				value += 145.0
				if _has_energy_target_with_missing_cost(state, actor, catalog):
					value += 85.0
			"energy_relocate":
				value += 75.0
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
			"status", "conditional_status", "dazzling_beam", "attack_lock_basic", "self_attack_lock":
				value += 45.0
			"damage", "any_pokemon_damage", "damage_counter_self", "place_counters_and_self_ko":
				value += int(params.get("amount", params.get("damage", 0))) * 1.2
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
	for effect in _flatten_effects(effects):
		if str(effect.get("effect_type", "")) in [
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
			"mill_and_damage_per_energy",
		]:
			full_damage = true
			break
	var damage := 0 if full_damage else int(attack.get("damage", 0))
	for effect in _flatten_effects(effects):
		damage = max(damage, _effect_damage_estimate(state, actor, effect, catalog))
	return _modified_attack_damage(state, actor, damage, catalog)


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
		"damage_per_hand_size":
			return player.hand.size() * int(params.get("per", 0))
		"damage_per_discard_psychic":
			var psychic_count := 0
			for card_id in player.discard:
				if catalog.is_pokemon(card_id) and "Psychic" in catalog.get_card(card_id).get("energy_types", []):
					psychic_count += 1
			return int(params.get("base", 0)) + psychic_count * int(params.get("per_card", 0))
		"damage_per_evolved":
			var evolved := 0
			for row in player.get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				if pokemon and not pokemon.evolution_stack_ids.is_empty():
					evolved += 1
			return evolved * int(params.get("per_evolved", 0))
		"conditional_damage_heal":
			return int(params.get("base", 0)) + (int(params.get("bonus", 0)) if player.healed_this_turn else 0)
		"damage_self_penalty":
			return max(0, int(params.get("base", 0)) - (active.damage_counters if active else 0) * int(params.get("per_counter", 0)))
		"coin_flip_triple":
			return int(float(params.get("damage_per_head", 10)) * 1.5)
		"coin_flip_until_tails":
			return int(params.get("per_head", 20))
	return 0


func _modified_attack_damage(
	state: GameState,
	actor: int,
	base_damage: int,
	catalog: CardCatalog,
) -> int:
	var attacker := state.get_player(actor).active
	var defender := state.get_player(1 - actor).active
	if attacker == null or defender == null or base_damage <= 0:
		return max(0, base_damage)
	var damage := base_damage
	for ability_value in catalog.get_card(defender.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		for effect_value in ability.get("effects", []):
			var effect: Dictionary = effect_value
			if str(effect.get("effect_type", "")) == "aura_damage_reduction":
				damage -= int(effect.get("params", {}).get("reduction", 20))
	for energy_id in attacker.energy_card_ids:
		if energy_id == "svi-dtur":
			damage -= 20
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
	if state.apply_type_matchups:
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
		best = max(best, damage)
	return best


func _pokemon_card_strength(card_id: String, energy_count: int, catalog: CardCatalog) -> float:
	var card := catalog.get_card(card_id)
	var best_damage := 0
	for attack in card.get("attacks", []):
		best_damage = max(best_damage, int(attack.get("damage", 0)))
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
		if pokemon and _best_missing_energy(pokemon, catalog) > 0:
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
		best_damage = max(best_damage, int(attack.get("damage", 0)))
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
