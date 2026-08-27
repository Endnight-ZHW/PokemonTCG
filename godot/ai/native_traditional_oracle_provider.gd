class_name NativeTraditionalOracleProvider
extends RefCounted

## Test-only semantic provider for the C++ turn_beam_v2 controller.
##
## This adapter calls the frozen GDScript oracle for differential tests of the
## native traversal. It is excluded from every export preset and is never part
## of the production request path.

var information_set: AIInformationSet
var engine: GameEngine
var strategy: Variant
var catalog: CardCatalog
var perspective := -1
var match_seed := 0
var trusted_leaf_evaluator := Callable()
var trusted_choice_resolver := Callable()
var trusted_action_evaluator := Callable()
var trusted_debug_owner: Variant = null


func configure(
	p_information_set: AIInformationSet,
	p_engine: GameEngine,
	p_strategy: Variant,
	p_catalog: CardCatalog,
	p_perspective: int,
	p_match_seed: int,
	p_trusted_leaf_evaluator: Callable = Callable(),
	p_trusted_choice_resolver: Callable = Callable(),
	p_trusted_action_evaluator: Callable = Callable(),
	p_trusted_debug_owner: Variant = null,
) -> bool:
	information_set = p_information_set
	engine = p_engine
	strategy = p_strategy
	catalog = p_catalog
	perspective = p_perspective
	match_seed = p_match_seed
	trusted_leaf_evaluator = p_trusted_leaf_evaluator
	trusted_choice_resolver = p_trusted_choice_resolver
	trusted_action_evaluator = p_trusted_action_evaluator
	trusted_debug_owner = p_trusted_debug_owner
	return (
		information_set != null
		and information_set.is_valid()
		and engine != null
		and catalog != null
		and perspective in [0, 1]
	)


func dispatch(method: String, payload: Dictionary) -> Variant:
	match method:
		"capabilities":
			return {
				"trusted_leaf": trusted_leaf_evaluator.is_valid(),
				"trusted_action": trusted_action_evaluator.is_valid(),
				"trusted_choice": trusted_choice_resolver.is_valid(),
			}
		"determinize":
			return _determinize(payload)
		"ranked_actions":
			return _ranked_actions(payload)
		"action_score_components":
			return _action_score_components(payload)
		"state_score_milli":
			return _state_score_milli(payload)
		"state_score_adjustments":
			return _state_score_adjustments(payload)
		"resolve_pending":
			return _resolve_pending(payload)
		"select_pending_choice":
			return _select_pending_choice(payload)
		"state_fingerprint":
			var state := _state(payload)
			return (
				AITurnBeamPlanner._state_fingerprint(state)
				if state != null
				else ""
			)
		"branch_seed":
			return AITurnBeamPlanner._branch_seed(
				int(payload.get("base_seed", 1)),
				int(payload.get("depth", 0)),
				str(payload.get("root_signature", "")),
				str(payload.get("sequence_signature", "")),
				int(payload.get("action_index", 0)),
			)
		"sha256_text":
			return str(payload.get("value", "")).sha256_text()
		_:
			return null


func _determinize(payload: Dictionary) -> Dictionary:
	if information_set == null or not information_set.is_valid():
		return {"success": false, "error": "invalid_information_set"}
	var seed := int(payload.get("seed", 1))
	var state := information_set.sample_state(seed)
	if state == null:
		return {"success": false, "error": "determinization_failed"}
	state.set_type_matchups_enabled(false)
	return {
		"success": true,
		"snapshot": state.snapshot(),
		"rng_state": seed,
	}


func _ranked_actions(payload: Dictionary) -> Array[Dictionary]:
	var state := _state(payload)
	var actor := int(payload.get("actor", -1))
	if state == null or actor not in [0, 1]:
		return []
	var actions := _actions_from_wire(payload.get("supplied_actions", []))
	if actions.is_empty():
		var query := engine.query_legal_action_groups(state, actor)
		if query == null or not query.success:
			return []
		actions.assign(query.concrete_actions())
	var selected_strategy: Variant = strategy
	var action_evaluator := trusted_action_evaluator
	if actor != perspective:
		var deck_key := (
			str(state.public_deck_keys[actor])
			if actor < state.public_deck_keys.size()
			else ""
		)
		var registry := AIStrategyRegistry.shared()
		selected_strategy = (
			registry.strategy_for(deck_key)
			if registry != null and registry.is_valid()
			else null
		)
		action_evaluator = Callable()
	var ranked := AIPositionEvaluator.ranked_actions(
		state,
		actor,
		actions,
		selected_strategy,
		CardSemanticCatalog.new(catalog),
		catalog,
		match_seed,
		Callable(),
		action_evaluator,
	)
	var selected := AIPositionEvaluator.diverse_top_actions(
		ranked, int(payload.get("limit", 8)))
	var result: Array[Dictionary] = []
	for row_value in selected:
		var row: Dictionary = row_value
		var action: GameAction = row.get("action")
		if action == null:
			continue
		result.append({
			"action": action.to_dict(),
			"score_milli": int(row.get("score_milli", 0)),
			"signature": str(row.get("signature", "")),
			"bucket": str(row.get("bucket", "")),
			"purpose_bucket": str(row.get("purpose_bucket", "")),
			"index": int(row.get("index", 0)),
		})
	return result


func _action_score_components(payload: Dictionary) -> Array[Dictionary]:
	var state := _state(payload)
	var actor := int(payload.get("actor", -1))
	if state == null or actor not in [0, 1]:
		return []
	var actions := _actions_from_wire(payload.get("supplied_actions", []))
	var action_evaluator := trusted_action_evaluator
	if actor != perspective:
		action_evaluator = Callable()
	var result: Array[Dictionary] = []
	for index in range(actions.size()):
		var action := actions[index]
		var row := {
			"index": index,
			"trusted_valid": false,
			"trusted_value": 0.0,
			"strategy_valid": false,
			"strategy_value": 0.0,
		}
		if action_evaluator.is_valid():
			var trusted_value: Variant = action_evaluator.call(state, actor, action)
			if AIPositionEvaluator._is_finite_number(trusted_value):
				row["trusted_valid"] = true
				row["trusted_value"] = float(trusted_value)
		result.append(row)
	return result


func _state_score_milli(payload: Dictionary) -> int:
	var state := _state(payload)
	if state == null:
		return -AIPositionEvaluator.WIN_SCORE_MILLI
	return AIPositionEvaluator.state_score_milli(
		state,
		int(payload.get("actor", perspective)),
		strategy,
		CardSemanticCatalog.new(catalog),
		catalog,
		match_seed,
		trusted_leaf_evaluator,
	)


func _state_score_adjustments(payload: Dictionary) -> Dictionary:
	var state := _state(payload)
	var actor := int(payload.get("actor", perspective))
	if state == null or actor not in [0, 1]:
		return {"success": false}
	var result := {
		"success": true,
		"trusted_configured": trusted_leaf_evaluator.is_valid(),
		"trusted_valid": false,
		"trusted_value": 0.0,
		"strategy_valid": false,
		"strategy_value": 0.0,
	}
	if trusted_leaf_evaluator.is_valid():
		var trusted_value: Variant = trusted_leaf_evaluator.call(
			state, actor, catalog)
		if AIPositionEvaluator._is_finite_number(trusted_value):
			result["trusted_valid"] = true
			result["trusted_value"] = float(trusted_value)
	var information := AIInformationSet.capture_view_only(
		state, actor, catalog, [], [], match_seed)
	if information.is_valid() and strategy != null:
		var public_view := information.shared_read_only_view()
		var strategy_value: Variant = AIPositionEvaluator._strategy_call(
			strategy,
			"state_score",
			[
				public_view,
				AIPositionEvaluator.semantic_context_for_view(
					public_view, CardSemanticCatalog.new(catalog)),
			],
			0.0,
		)
		if AIPositionEvaluator._is_finite_number(strategy_value):
			result["strategy_valid"] = true
			result["strategy_value"] = float(strategy_value)
	if trusted_debug_owner != null:
		result["trusted_components"] = _trusted_leaf_components(state, actor)
	return result


func _trusted_leaf_components(state: GameState, perspective: int) -> Dictionary:
	var result := {}
	for component_actor in [perspective, 1 - perspective]:
		var player := state.get_player(component_actor)
		var opponent := state.get_player(1 - component_actor)
		var deck_key := str(trusted_debug_owner.call(
			"_deck_key_for_actor", state, component_actor, ""))
		var components := {
			"active_prize_threat": float(trusted_debug_owner.call(
				"_active_prize_threat_value", state, component_actor, catalog)),
			"ready_attackers": float(trusted_debug_owner.call(
				"_ready_attackers_value", state, component_actor, deck_key, catalog)),
			"resource_outs": float(trusted_debug_owner.call(
				"_resource_outs_value", state, component_actor, deck_key, catalog)),
			"hand_size_plan": float(trusted_debug_owner.call(
				"_hand_size_attack_plan_value", state, component_actor, deck_key, catalog)),
			"protection": float(trusted_debug_owner.call(
				"_protection_state_value", player.active, catalog)),
			"opponent_status_bonus": float(trusted_debug_owner.call(
				"_status_lock_state_value", opponent.active, state,
				1 - component_actor, catalog)) * 0.45,
			"active_ko_risk": -float(trusted_debug_owner.call(
				"_active_ko_risk_value", state, component_actor, deck_key, catalog)),
			"own_status": -float(trusted_debug_owner.call(
				"_status_lock_state_value", player.active, state,
				component_actor, catalog)),
			"deck_pressure": -float(trusted_debug_owner.call(
				"_deck_pressure_penalty", player)),
			"closeout": 0.0,
		}
		if player.active != null and opponent.active != null:
			if (
				player.prizes.size() <= 2
				and int(trusted_debug_owner.call(
					"_best_available_damage", state, component_actor, catalog))
				>= opponent.active.current_hp(catalog)
			):
				components["closeout"] += (3 - player.prizes.size()) * 42.0
			if (
				opponent.prizes.size() <= 2
				and int(trusted_debug_owner.call(
					"_best_available_damage", state, 1 - component_actor, catalog))
				>= player.active.current_hp(catalog)
			):
				components["closeout"] -= (3 - opponent.prizes.size()) * 42.0
		var total := 0.0
		for value in components.values():
			total += float(value)
		components["total"] = total
		result[str(component_actor)] = components
	result["delta"] = (
		float(Dictionary(result[str(perspective)]).get("total", 0.0))
		- float(Dictionary(result[str(1 - perspective)]).get("total", 0.0))
	)
	return result


func _resolve_pending(payload: Dictionary) -> Dictionary:
	var state := _state(payload)
	var rng := PortableRandomSource.new(int(payload.get("rng_state", 1)))
	if state == null:
		return {"success": false, "error": "invalid_pending_state"}
	for _guard in range(AITurnBeamPlanner.MAX_CHOICE_STEPS):
		var pending_value: Variant = state.resolution_stack.get("pending_request")
		if pending_value == null:
			return {
				"success": true,
				"snapshot": state.snapshot(),
				"rng_state": rng.get_state(),
			}
		if not pending_value is Dictionary:
			return {"success": false, "error": "invalid_pending_request"}
		var pending_player := int(Dictionary(pending_value).get("player", -1))
		var request := engine.query_pending_choice(state, pending_player)
		if request == null:
			return {"success": false, "error": "pending_choice_unavailable"}
		var choice_actor := request.player if request.player in [0, 1] else pending_player
		var response: ChoiceResponse = null
		if trusted_choice_resolver.is_valid():
			var trusted: Variant = trusted_choice_resolver.call(
				state, request, match_seed, Callable(), 0)
			if trusted is ChoiceResponse:
				response = trusted
		if response == null:
			var choice_strategy: Variant = strategy
			if choice_actor != perspective:
				var deck_key := (
					str(state.public_deck_keys[choice_actor])
					if choice_actor < state.public_deck_keys.size()
					else ""
				)
				var registry := AIStrategyRegistry.shared()
				choice_strategy = (
					registry.strategy_for(deck_key)
					if registry != null and registry.is_valid()
					else null
				)
			var semantic_catalog := CardSemanticCatalog.new(catalog)
			var information := AIInformationSet.capture_view_only(
				state, choice_actor, catalog, [], [], match_seed)
			var public_view := (
				information.shared_read_only_view()
				if information.is_valid()
				else {}
			)
			var choice_row: Dictionary = request.to_dict().duplicate(true)
			choice_row.make_read_only()
			var semantic_context := AIPositionEvaluator.semantic_context_for_choice(
				request, semantic_catalog)
			var ranked: Array[Dictionary] = []
			for index in range(request.options.size()):
				var option: Dictionary = request.options[index].duplicate(true)
				option.make_read_only()
				var strategy_value: Variant = AIPositionEvaluator._strategy_call(
					choice_strategy,
					"choice_score",
					[public_view, choice_row, option, semantic_context],
					0.0,
				)
				var score_milli := (
					roundi(float(strategy_value) * AIPositionEvaluator.SCORE_SCALE)
					if strategy_value is float or strategy_value is int
					else 0
				)
				ranked.append({
					"option": request.options[index],
					"score": float(score_milli),
					"score_milli": score_milli,
					"signature": AIPositionEvaluator.stable_variant_signature(
						request.options[index]),
					"index": index,
				})
			ranked.sort_custom(AIPositionEvaluator.action_row_descending)
			response = AIChoiceSelector.response_from_ranked_scores(
				request, ranked, catalog)
		if response == null or not AIChoiceSelector.response_is_shape_legal(
			request, response.option_ids, catalog, response.cancelled):
			return {"success": false, "error": "pending_choice_unresolved"}
		var step := engine.apply_choice_response(state, response, rng)
		if step == null or not step.success:
			return {"success": false, "error": "pending_choice_apply_failed"}
	return {"success": false, "error": "choice_guard_exhausted"}


func _select_pending_choice(payload: Dictionary) -> Dictionary:
	var state := _state(payload)
	if state == null:
		return {"success": false, "error": "invalid_pending_state"}
	var pending_value: Variant = state.resolution_stack.get("pending_request")
	if not pending_value is Dictionary:
		return {"success": false, "error": "invalid_pending_request"}
	var pending_player := int(Dictionary(pending_value).get("player", -1))
	var request := engine.query_pending_choice(state, pending_player)
	if request == null:
		return {"success": false, "error": "pending_choice_unavailable"}
	var choice_actor := request.player if request.player in [0, 1] else pending_player
	var response: ChoiceResponse = null
	if trusted_choice_resolver.is_valid():
		var trusted: Variant = trusted_choice_resolver.call(
			state, request, match_seed, Callable(), 0)
		if trusted is ChoiceResponse:
			response = trusted
	if response == null:
		var choice_strategy: Variant = strategy
		if choice_actor != perspective:
			var deck_key := (
				str(state.public_deck_keys[choice_actor])
				if choice_actor < state.public_deck_keys.size()
				else ""
			)
			var registry := AIStrategyRegistry.shared()
			choice_strategy = (
				registry.strategy_for(deck_key)
				if registry != null and registry.is_valid()
				else null
			)
		var semantic_catalog := CardSemanticCatalog.new(catalog)
		var information := AIInformationSet.capture_view_only(
			state, choice_actor, catalog, [], [], match_seed)
		var public_view := (
			information.shared_read_only_view()
			if information.is_valid()
			else {}
		)
		var choice_row: Dictionary = request.to_dict().duplicate(true)
		choice_row.make_read_only()
		var semantic_context := AIPositionEvaluator.semantic_context_for_choice(
			request, semantic_catalog)
		var ranked: Array[Dictionary] = []
		for index in range(request.options.size()):
			var option: Dictionary = request.options[index].duplicate(true)
			option.make_read_only()
			var strategy_value: Variant = AIPositionEvaluator._strategy_call(
				choice_strategy,
				"choice_score",
				[public_view, choice_row, option, semantic_context],
				0.0,
			)
			var score_milli := (
				roundi(float(strategy_value) * AIPositionEvaluator.SCORE_SCALE)
				if strategy_value is float or strategy_value is int
				else 0
			)
			ranked.append({
				"option": request.options[index],
				"score": float(score_milli),
				"score_milli": score_milli,
				"signature": AIPositionEvaluator.stable_variant_signature(
					request.options[index]),
				"index": index,
			})
		ranked.sort_custom(AIPositionEvaluator.action_row_descending)
		response = AIChoiceSelector.response_from_ranked_scores(
			request, ranked, catalog)
	if response == null or not AIChoiceSelector.response_is_shape_legal(
		request, response.option_ids, catalog, response.cancelled):
		return {"success": false, "error": "pending_choice_unresolved"}
	return {
		"success": true,
		"error": "",
		"response": response.to_dict(),
	}


func _state(payload: Dictionary) -> GameState:
	var value: Variant = payload.get("snapshot")
	return GameState.from_snapshot(value) if value is Dictionary else null


static func _actions_from_wire(value: Variant) -> Array[GameAction]:
	var result: Array[GameAction] = []
	if not value is Array:
		return result
	for row_value in Array(value):
		if row_value is Dictionary:
			result.append(GameAction.from_dict(Dictionary(row_value)))
	return result
