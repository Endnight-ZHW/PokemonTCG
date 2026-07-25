class_name DeepRootISMCTS
extends RefCounted

## Independent production Deep planner.
##
## Challenge's turn_beam_v2 implementation is deliberately not modified by
## this class.  Deep performs mandatory tactics first, calls ONNX exactly once
## for root priors, then runs a bounded information-set PUCT search with the
## mature position evaluator at leaves.  Any contract failure is returned to
## AICoordinator, which performs the structured Challenge fallback.

const PLANNER_ID := "deep_root_ismcts_v1"
const SCHEMA_VERSION := 1
const SIMULATIONS := 64
const C_PUCT := 1.4
const MAX_DEPTH := 16
const OPPONENT_BRANCH_LIMIT := 6
const NEURAL_PRIOR_WEIGHT := 0.75
const CHALLENGE_PRIOR_WEIGHT := 0.25
const WATCHDOG_USEC := 2000000
const HEURISTIC_TEMPERATURE_MILLI := 80000.0
const MAX_EXHAUSTIVE_CHOICE_OPTIONS := 16
const RULE_DELEGATED_CHOICES := [
	"choose_turn_order",
	"choose_mulligan_draw_count",
	"select_prize",
	"select_retreat_payment",
	"confirm_trigger",
	"confirm",
	"coin_flip",
	"arven",
]

var _challenge_delegate := NativeChallengeAI.new()


func decide(
	request: Dictionary,
	cancel_check: Callable,
	inference: Variant,
) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	if inference == null or not bool(inference.call("is_loaded")):
		return _failure(request, "runtime_unavailable", started_usec)
	if cancel_check.is_valid() and bool(cancel_check.call()):
		return _failure(request, "cancelled", started_usec, true)
	var result: Dictionary
	if str(request.get("kind", "action")) == "choice":
		result = _choose_request(
			request, cancel_check, inference, started_usec)
	else:
		result = _search_action(
			request, cancel_check, inference, started_usec)
	result["revision"] = int(request.get("revision", -1))
	result["request_id"] = str(request.get("request_id", ""))
	result["elapsed_ms"] = maxf(
		0.0, float(Time.get_ticks_usec() - started_usec) / 1000.0)
	return result


func _search_action(
	request: Dictionary,
	cancel_check: Callable,
	inference: Variant,
	started_usec: int,
) -> Dictionary:
	var state := GameState.from_dict(request.get("state", {}))
	state.set_type_matchups_enabled(false)
	var actor := int(request.get("actor", -1))
	if actor not in [0, 1]:
		return _failure(request, "invalid_actor", started_usec)
	var catalog := CardCatalog.shared()
	var engine := GameEngine.new(catalog)
	var query := engine.query_legal_action_groups(state, actor)
	if not query.success:
		return _failure(
			request, "legal_query_failed:%s" % query.code, started_usec)
	var authoritative: Array[GameAction] = []
	authoritative.assign(query.concrete_actions())
	var actions := _intersect_supplied_actions(
		authoritative, Array(request.get("actions", [])))
	if actions.is_empty():
		return _failure(request, "no_authoritative_legal_action", started_usec)
	var deck_key := _deck_key(
		state, actor, str(request.get("deck_key", "")))
	var match_seed := int(request.get(
		"match_seed", request.get("seed", 17)))
	var information_set := AIInformationSet.capture(
		state,
		actor,
		catalog,
		actions,
		Array(request.get("public_history", [])),
		match_seed,
	)
	if not information_set.is_valid():
		return _failure(
			request,
			"invalid_information_set:%s" % information_set.validation_error(),
			started_usec,
		)
	var registry := AIStrategyRegistry.shared()
	if registry == null or not registry.is_valid():
		return _failure(request, "invalid_strategy_registry", started_usec)
	var strategy: Variant = registry.strategy_for(deck_key)
	var deadline_usec := started_usec + WATCHDOG_USEC

	# Sound rule tactics have priority over learned policy.
	var preflight_state := information_set.sample_state(
		_derive_seed(match_seed, int(request.get("revision", 0)), actor, 0))
	if preflight_state == null:
		return _failure(request, "determinization_failed", started_usec)
	var mandatory := AIMandatoryTactics.new().resolve(
		information_set,
		preflight_state,
		actor,
		actions,
		engine,
		strategy,
		int(request.get("seed", 17)),
		cancel_check,
		deadline_usec,
		SIMULATIONS,
	)
	if bool(mandatory.get("resolved", false)):
		var forced: GameAction = mandatory.get("action")
		if forced == null or _action_index(actions, forced) < 0:
			return _failure(request, "mandatory_action_illegal", started_usec)
		return _action_result(
			request,
			forced,
			0,
			{},
			0.0,
			0.0,
			str(mandatory.get("reason", "mandatory")),
		)
	if Time.get_ticks_usec() >= deadline_usec:
		return _failure(request, "deep_timeout:mandatory", started_usec)

	# One and only one neural call supplies root priors. Choice inputs remain
	# non-empty because the ONNX graph exports both heads in one invocation.
	var encoded := _encode_action_root(state, actor, deck_key, actions, catalog)
	if encoded.has("error"):
		return _failure(request, str(encoded["error"]), started_usec)
	var inference_result: Variant = inference.call(
		"infer",
		encoded["state_numeric"],
		encoded["state_cards"],
		encoded["candidate_numeric"],
		encoded["candidate_cards"],
		_zero_numeric_candidates(1),
		PackedInt64Array([0]),
	)
	if not inference_result is Dictionary:
		return _failure(request, "inference_result_invalid", started_usec)
	var neural_result: Dictionary = inference_result
	if not bool(neural_result.get("success", false)):
		return _failure(
			request,
			"inference_failed:%s" % neural_result.get("error", "unknown"),
			started_usec,
		)
	if Time.get_ticks_usec() >= deadline_usec:
		return _failure(request, "deep_timeout:inference", started_usec)
	var logits: PackedFloat32Array = neural_result.get(
		"action_logits", PackedFloat32Array())
	if logits.size() != actions.size() or not _finite_values(logits):
		return _failure(request, "action_logits_invalid", started_usec)
	var neural_priors := _softmax_packed(logits, 1.0)
	var heuristic_priors := _heuristic_action_priors(
		state, actor, actions, strategy, catalog, match_seed)
	var priors: Array[float] = []
	for index in range(actions.size()):
		priors.append(
			NEURAL_PRIOR_WEIGHT * neural_priors[index]
			+ CHALLENGE_PRIOR_WEIGHT * heuristic_priors[index]
		)
	priors = _normalize(priors)

	var visits: Array[int] = []
	var totals: Array[float] = []
	visits.resize(actions.size())
	totals.resize(actions.size())
	visits.fill(0)
	totals.fill(0.0)
	for simulation in range(SIMULATIONS):
		if cancel_check.is_valid() and bool(cancel_check.call()):
			return _failure(request, "cancelled", started_usec, true)
		if Time.get_ticks_usec() >= deadline_usec:
			return _failure(request, "deep_timeout:search", started_usec)
		var selected := _puct_index(visits, totals, priors)
		var sampled := information_set.sample_state(_derive_seed(
			match_seed,
			int(request.get("revision", 0)),
			actor,
			simulation + 1,
		))
		if sampled == null:
			return _failure(request, "determinization_failed", started_usec)
		var value := _simulate(
			sampled,
			actor,
			actions[selected],
			deck_key,
			strategy,
			catalog,
			engine,
			match_seed,
			simulation,
			deadline_usec,
			cancel_check,
		)
		if not _finite_number(value):
			return _failure(request, "non_finite_leaf_value", started_usec)
		visits[selected] += 1
		totals[selected] += value

	if Time.get_ticks_usec() >= deadline_usec:
		return _failure(request, "deep_timeout:complete", started_usec)
	var selected_index := _visit_winner(actions, visits, priors)
	if selected_index < 0 or selected_index >= actions.size():
		return _failure(request, "visit_result_illegal", started_usec)
	var visit_rows := {}
	for index in range(actions.size()):
		visit_rows[_action_signature(actions[index])] = visits[index]
	return _action_result(
		request,
		actions[selected_index],
		SIMULATIONS,
		visit_rows,
		float(neural_result.get("value", 0.0)),
		float(neural_result.get("duration_ms", 0.0)),
		"search_complete",
	)


func _choose_request(
	request: Dictionary,
	cancel_check: Callable,
	inference: Variant,
	started_usec: int,
) -> Dictionary:
	var choice_value: Variant = request.get("choice")
	if not choice_value is Dictionary:
		return _failure(request, "invalid_choice_view", started_usec)
	var choice := ChoiceView.from_dict(choice_value)
	if choice.request_id.is_empty() or choice.options.is_empty():
		return _failure(request, "invalid_choice_view", started_usec)
	if choice.request_type in RULE_DELEGATED_CHOICES:
		var delegated := _challenge_delegate.decide(
			request, cancel_check, null)
		if not bool(delegated.get("success", false)):
			return _failure(
				request,
				"delegated_choice_failed:%s" % delegated.get("error", "unknown"),
				started_usec,
			)
		delegated["deep_fallback"] = false
		delegated["fallback_reason"] = ""
		delegated["planner"] = PLANNER_ID
		delegated["engine_id"] = PLANNER_ID
		delegated["delegated_rule_choice"] = true
		delegated["simulations"] = 0
		return delegated
	if not bool(inference.call("supports_choice_head")):
		return _failure(request, "choice_head_unavailable", started_usec)
	var state := GameState.from_dict(request.get("state", {}))
	state.set_type_matchups_enabled(false)
	var actor := choice.player if choice.player in [0, 1] else int(
		request.get("actor", -1))
	if actor not in [0, 1]:
		return _failure(request, "invalid_choice_actor", started_usec)
	var catalog := CardCatalog.shared()
	var deck_key := _deck_key(
		state, actor, str(request.get("deck_key", "")))
	var observation := AIObservationBuilder.build(state, actor)
	var encoder := AIActionEncoder.new(catalog)
	var encoded_state := encoder.encode_observation(observation, deck_key)
	var choice_numeric := PackedFloat32Array()
	var choice_cards := PackedInt64Array()
	for index in range(choice.options.size()):
		var encoded_choice := encoder.encode_choice(
			observation, choice, choice.options[index], index)
		if encoded_choice.has("error"):
			return _failure(
				request,
				"choice_encoding_failed:%s" % encoded_choice["error"],
				started_usec,
			)
		choice_numeric.append_array(
			PackedFloat32Array(encoded_choice["numeric"]))
		choice_cards.append(int(encoded_choice["card_id"]))
	var inference_result: Variant = inference.call(
		"infer",
		PackedFloat32Array(encoded_state["numeric"]),
		PackedInt64Array(encoded_state["card_ids"]),
		_zero_numeric_candidates(1),
		PackedInt64Array([0]),
		choice_numeric,
		choice_cards,
	)
	if not inference_result is Dictionary:
		return _failure(request, "inference_result_invalid", started_usec)
	var neural_result: Dictionary = inference_result
	if not bool(neural_result.get("success", false)):
		return _failure(
			request,
			"choice_inference_failed:%s" % neural_result.get("error", "unknown"),
			started_usec,
		)
	var logits: PackedFloat32Array = neural_result.get(
		"choice_logits", PackedFloat32Array())
	if logits.size() != choice.options.size() or not _finite_values(logits):
		return _failure(request, "choice_logits_invalid", started_usec)
	var response := _highest_scoring_legal_choice(
		choice, logits, catalog)
	if not AIChoiceSelector.response_is_shape_legal(
		choice, response.option_ids, catalog, response.cancelled):
		return _failure(request, "choice_response_illegal", started_usec)
	if Time.get_ticks_usec() - started_usec >= WATCHDOG_USEC:
		return _failure(request, "deep_timeout:choice", started_usec)
	return {
		"success": true,
		"kind": "choice",
		"choice_response": response.to_dict(),
		"simulations": 0,
		"deep_fallback": false,
		"fallback_reason": "",
		"planner": PLANNER_ID,
		"engine_id": PLANNER_ID,
		"delegated_rule_choice": false,
		"inference_ms": float(neural_result.get("duration_ms", 0.0)),
		"completion_reason": "choice_head",
		"type_matchups": false,
	}


func _simulate(
	state: GameState,
	perspective: int,
	first_action: GameAction,
	deck_key: String,
	strategy: Variant,
	catalog: CardCatalog,
	engine: GameEngine,
	match_seed: int,
	simulation: int,
	deadline_usec: int,
	cancel_check: Callable,
) -> float:
	var rng := PortableRandomSource.new(_derive_seed(
		match_seed, state.revision, perspective, simulation + 1000))
	var applied := engine.apply_search_action_ephemeral(
		state, first_action, rng)
	var current: GameState = applied.get("state")
	var step: StepResult = applied.get("step")
	if current == null or step == null or not step.success:
		return -1.0
	if not _resolve_simulated_choices(
		current, engine, rng, catalog, deadline_usec):
		return -1.0
	if current.is_terminal():
		return _terminal_value(current, perspective)
	var opponent_started := current.active_player_idx != perspective
	var opponent_actions := 0
	for depth in range(1, MAX_DEPTH):
		if Time.get_ticks_usec() >= deadline_usec:
			break
		if cancel_check.is_valid() and bool(cancel_check.call()):
			break
		var actor: int = (
			current.pending_promotion_player
			if current.pending_promotion_player >= 0
			else current.active_player_idx
		)
		var query := engine.query_legal_action_groups(current, actor)
		if not query.success:
			break
		var actions: Array[GameAction] = []
		actions.assign(query.concrete_actions())
		if actions.is_empty():
			break
		var selected: GameAction
		if actor == perspective:
			selected = _highest_heuristic_action(
				current, actor, actions, strategy, catalog, match_seed)
		else:
			opponent_started = true
			selected = _opponent_action(
				current,
				perspective,
				actions,
				strategy,
				catalog,
				engine,
				match_seed,
				rng,
				deadline_usec,
			)
			opponent_actions += 1
		applied = engine.apply_search_action_ephemeral(current, selected, rng)
		current = applied.get("state")
		step = applied.get("step")
		if current == null or step == null or not step.success:
			break
		if not _resolve_simulated_choices(
			current, engine, rng, catalog, deadline_usec):
			break
		if current.is_terminal():
			return _terminal_value(current, perspective)
		if (
			opponent_started
			and opponent_actions > 0
			and current.active_player_idx == perspective
		):
			break
	return _leaf_value(
		current, perspective, strategy, catalog, match_seed)


func _opponent_action(
	state: GameState,
	perspective: int,
	actions: Array[GameAction],
	strategy: Variant,
	catalog: CardCatalog,
	engine: GameEngine,
	match_seed: int,
	rng: PortableRandomSource,
	deadline_usec: int,
) -> GameAction:
	var scored: Array[Dictionary] = []
	var semantic := CardSemanticCatalog.new(catalog)
	for index in range(actions.size()):
		scored.append({
			"index": index,
			"score": AIPositionEvaluator.action_score_milli(
				state,
				state.active_player_idx,
				actions[index],
				strategy,
				semantic,
				catalog,
				match_seed,
			),
		})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["score"]) > int(b["score"]))
	var best := actions[int(scored[0]["index"])]
	var worst := INF
	for row in scored.slice(0, mini(OPPONENT_BRANCH_LIMIT, scored.size())):
		if Time.get_ticks_usec() >= deadline_usec:
			break
		var candidate: GameAction = actions[int(row["index"])]
		var applied := engine.apply_search_action_ephemeral(
			state, candidate, rng)
		var child: GameState = applied.get("state")
		var step: StepResult = applied.get("step")
		if child == null or step == null or not step.success:
			continue
		if not _resolve_simulated_choices(
			child, engine, rng, catalog, deadline_usec):
			continue
		var value := _leaf_value(
			child, perspective, strategy, catalog, match_seed)
		if value < worst:
			worst = value
			best = candidate
	return best


func _resolve_simulated_choices(
	state: GameState,
	engine: GameEngine,
	rng: PortableRandomSource,
	catalog: CardCatalog,
	deadline_usec: int,
) -> bool:
	for _guard in range(32):
		if Time.get_ticks_usec() >= deadline_usec:
			return false
		var request := engine.query_pending_choice(state, 0)
		if request == null:
			request = engine.query_pending_choice(state, 1)
		if request == null:
			return true
		var ranked: Array[Dictionary] = []
		for index in range(request.options.size()):
			ranked.append({
				"index": index,
				"score": float(request.options.size() - index),
			})
		var response := AIChoiceSelector.response_from_ranked_scores(
			request, ranked, catalog)
		if not AIChoiceSelector.response_is_shape_legal(
			request, response.option_ids, catalog, response.cancelled):
			return false
		var step := engine.apply_choice_response(state, response, rng)
		if not step.success:
			return false
	return false


func _encode_action_root(
	state: GameState,
	actor: int,
	deck_key: String,
	actions: Array[GameAction],
	catalog: CardCatalog,
) -> Dictionary:
	var observation := AIObservationBuilder.build(state, actor)
	var encoder := AIActionEncoder.new(catalog)
	var encoded_state := encoder.encode_observation(observation, deck_key)
	var candidate_numeric := PackedFloat32Array()
	var candidate_cards := PackedInt64Array()
	for action in actions:
		var encoded_action := encoder.encode_action(
			observation, action, deck_key)
		if encoded_action.has("error"):
			return {
				"error": "action_encoding_failed:%s" % encoded_action["error"],
			}
		candidate_numeric.append_array(
			PackedFloat32Array(encoded_action["numeric"]))
		candidate_cards.append(int(encoded_action["card_id"]))
	return {
		"state_numeric": PackedFloat32Array(encoded_state["numeric"]),
		"state_cards": PackedInt64Array(encoded_state["card_ids"]),
		"candidate_numeric": candidate_numeric,
		"candidate_cards": candidate_cards,
	}


func _heuristic_action_priors(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	strategy: Variant,
	catalog: CardCatalog,
	match_seed: int,
) -> Array[float]:
	var semantic := CardSemanticCatalog.new(catalog)
	var scores := PackedFloat32Array()
	for action in actions:
		scores.append(float(AIPositionEvaluator.action_score_milli(
			state,
			actor,
			action,
			strategy,
			semantic,
			catalog,
			match_seed,
		)))
	return _softmax_packed(scores, HEURISTIC_TEMPERATURE_MILLI)


func _highest_heuristic_action(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	strategy: Variant,
	catalog: CardCatalog,
	match_seed: int,
) -> GameAction:
	var priors := _heuristic_action_priors(
		state, actor, actions, strategy, catalog, match_seed)
	var index := 0
	for candidate in range(1, priors.size()):
		if priors[candidate] > priors[index]:
			index = candidate
	return actions[index]


func _leaf_value(
	state: GameState,
	perspective: int,
	strategy: Variant,
	catalog: CardCatalog,
	match_seed: int,
) -> float:
	if state == null:
		return -1.0
	if state.is_terminal():
		return _terminal_value(state, perspective)
	var score := AIPositionEvaluator.state_score_milli(
		state,
		perspective,
		strategy,
		CardSemanticCatalog.new(catalog),
		catalog,
		match_seed,
	)
	return clampf(float(score) / 1000000.0, -1.0, 1.0)


func _terminal_value(state: GameState, perspective: int) -> float:
	if state.result_status == GameState.RESULT_DRAW:
		return 0.0
	return 1.0 if state.winner == perspective else -1.0


func _puct_index(
	visits: Array[int],
	totals: Array[float],
	priors: Array[float],
) -> int:
	var total_visits := 0
	for count in visits:
		total_visits += count
	var best := 0
	var best_score := -INF
	for index in range(visits.size()):
		var q := totals[index] / visits[index] if visits[index] > 0 else 0.0
		var score := q + C_PUCT * priors[index] * sqrt(
			float(total_visits + 1)) / float(visits[index] + 1)
		if score > best_score:
			best = index
			best_score = score
	return best


func _visit_winner(
	actions: Array[GameAction],
	visits: Array[int],
	priors: Array[float],
) -> int:
	var best := -1
	for index in range(actions.size()):
		if best < 0:
			best = index
			continue
		var candidate_key := [
			visits[index],
			priors[index],
			_action_signature(actions[index]),
		]
		var best_key := [
			visits[best],
			priors[best],
			_action_signature(actions[best]),
		]
		if (
			int(candidate_key[0]) > int(best_key[0])
			or (
				int(candidate_key[0]) == int(best_key[0])
				and float(candidate_key[1]) > float(best_key[1])
			)
			or (
				int(candidate_key[0]) == int(best_key[0])
				and is_equal_approx(
					float(candidate_key[1]), float(best_key[1]))
				and str(candidate_key[2]) < str(best_key[2])
			)
		):
			best = index
	return best


func _highest_scoring_legal_choice(
	request: ChoiceView,
	logits: PackedFloat32Array,
	catalog: CardCatalog,
) -> ChoiceResponse:
	if request.allow_duplicates or request.options.size() > MAX_EXHAUSTIVE_CHOICE_OPTIONS:
		var ranked: Array[Dictionary] = []
		for index in range(logits.size()):
			ranked.append({"index": index, "score": logits[index]})
		ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["score"]) > float(b["score"]))
		return AIChoiceSelector.response_from_ranked_scores(
			request, ranked, catalog)
	var best_ids: Array[String] = []
	var best_score := 0.0 if request.min_select == 0 else -INF
	var subset_count := 1 << request.options.size()
	for mask in range(subset_count):
		var count := 0
		var score := 0.0
		var ids: Array[String] = []
		for index in range(request.options.size()):
			if (mask & (1 << index)) == 0:
				continue
			count += 1
			score += float(logits[index])
			ids.append(str(request.options[index].get("option_id", "")))
		if count < request.min_select or count > request.max_select:
			continue
		if not AIChoiceSelector.response_is_shape_legal(
			request, ids, catalog, false):
			continue
		if score > best_score:
			best_score = score
			best_ids = ids
	var cancelled := (
		best_ids.is_empty() and request.min_select == 0 and request.can_cancel)
	return ChoiceResponse.new(request.request_id, best_ids, cancelled)


func _intersect_supplied_actions(
	authoritative: Array[GameAction],
	supplied_rows: Array,
) -> Array[GameAction]:
	if supplied_rows.is_empty():
		return authoritative
	var supplied: Dictionary = {}
	for row in supplied_rows:
		if row is Dictionary:
			supplied[_action_signature(GameAction.from_dict(row))] = true
	var result: Array[GameAction] = []
	for action in authoritative:
		if supplied.has(_action_signature(action)):
			result.append(action)
	return result


func _action_index(
	actions: Array[GameAction],
	selected: GameAction,
) -> int:
	var signature := _action_signature(selected)
	for index in range(actions.size()):
		if _action_signature(actions[index]) == signature:
			return index
	return -1


func _action_signature(action: GameAction) -> String:
	return AIPositionEvaluator.stable_variant_signature(action.to_dict())


func _deck_key(
	state: GameState,
	actor: int,
	requested: String,
) -> String:
	if requested in AIActionEncoder.DECK_KEYS:
		return requested
	if (
		state != null
		and actor in [0, 1]
		and state.public_deck_keys.size() == 2
		and str(state.public_deck_keys[actor]) in AIActionEncoder.DECK_KEYS
	):
		return str(state.public_deck_keys[actor])
	return "fire"


func _derive_seed(
	match_seed: int,
	revision: int,
	actor: int,
	ordinal: int,
) -> int:
	return AIDecisionSeed.derive(
		match_seed,
		revision,
		actor,
		"deep_root_ismcts_v1",
		"simulation:%d" % ordinal,
	)


func _softmax_packed(
	values: PackedFloat32Array,
	temperature: float,
) -> Array[float]:
	if values.is_empty():
		return []
	var maximum := -INF
	for value in values:
		maximum = maxf(maximum, float(value))
	var result: Array[float] = []
	var total := 0.0
	for value in values:
		var weight := exp(clampf(
			(float(value) - maximum) / maxf(0.000001, temperature),
			-60.0,
			60.0,
		))
		result.append(weight)
		total += weight
	if total <= 0.0:
		result.fill(1.0 / float(result.size()))
		return result
	for index in range(result.size()):
		result[index] /= total
	return result


func _normalize(values: Array[float]) -> Array[float]:
	var total := 0.0
	for value in values:
		total += maxf(0.0, value)
	if total <= 0.0:
		values.fill(1.0 / float(values.size()))
		return values
	for index in range(values.size()):
		values[index] = maxf(0.0, values[index]) / total
	return values


func _finite_values(values: PackedFloat32Array) -> bool:
	for value in values:
		if not _finite_number(value):
			return false
	return true


func _finite_number(value: Variant) -> bool:
	if not value is float and not value is int:
		return false
	var number := float(value)
	return not is_nan(number) and not is_inf(number)


func _zero_numeric_candidates(count: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(maxi(1, count) * AIActionEncoder.ACTION_NUMERIC_SIZE)
	result.fill(0.0)
	return result


func _action_result(
	request: Dictionary,
	action: GameAction,
	simulations: int,
	visits: Dictionary,
	diagnostic_value: float,
	inference_ms: float,
	completion_reason: String,
) -> Dictionary:
	return {
		"success": true,
		"kind": "action",
		"action": action.to_dict(),
		"engine_id": PLANNER_ID,
		"planner": PLANNER_ID,
		"planner_schema_version": SCHEMA_VERSION,
		"simulations": simulations,
		"visits": visits,
		"diagnostic_value": diagnostic_value,
		"inference_ms": inference_ms,
		"root_inference_calls": 1 if completion_reason == "search_complete" else 0,
		"deep_fallback": false,
		"fallback_reason": "",
		"completion_reason": completion_reason,
		"type_matchups": false,
		"seed": int(request.get("seed", 17)),
	}


func _failure(
	request: Dictionary,
	reason: String,
	started_usec: int,
	cancelled: bool = false,
) -> Dictionary:
	return {
		"success": false,
		"kind": str(request.get("kind", "action")),
		"error": reason,
		"deep_failure_reason": reason,
		"cancelled": cancelled,
		"planner": PLANNER_ID,
		"engine_id": PLANNER_ID,
		"simulations": 0,
		"elapsed_ms": maxf(
			0.0, float(Time.get_ticks_usec() - started_usec) / 1000.0),
	}
