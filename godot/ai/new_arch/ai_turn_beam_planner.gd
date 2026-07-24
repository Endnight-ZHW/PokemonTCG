class_name AITurnBeamPlanner
extends RefCounted

## Device-independent fixed-work search for the rest of the current turn.
##
## Search quality is determined only by these structural limits. Wall-clock
## time is telemetry and never participates in candidate selection.

const ENGINE_ID := "turn_beam_v2"
const DEFAULT_ROOT_ACTIONS := 8
const DEFAULT_PER_ROOT_BEAM_WIDTH := 2
const DEFAULT_MAX_DEPTH := 8
const DEFAULT_MAX_ACTIONS_PER_NODE := 8
const DEFAULT_REPLY_DEPTH := 3
const DEFAULT_REPLY_BEAM_WIDTH := 4
const DEFAULT_REPLY_ACTIONS_PER_NODE := 4
const MAX_CHOICE_STEPS := 32


func plan(
	information_set: AIInformationSet,
	actor: int,
	root_actions: Array[GameAction],
	engine: GameEngine,
	strategy: Variant = null,
	config: Dictionary = {},
	cancel_check: Callable = Callable(),
	trusted_leaf_evaluator: Callable = Callable(),
	trusted_choice_resolver: Callable = Callable(),
	trusted_action_evaluator: Callable = Callable(),
) -> Dictionary:
	if information_set == null or not information_set.is_valid():
		return _failure("invalid_information_set", 0, "error")
	if actor not in [0, 1] or actor != information_set.perspective_player():
		return _failure("actor_must_match_perspective", 0, "error")
	if engine == null or root_actions.is_empty():
		return _failure("no_legal_actions", 0, "error")
	var root_limit := clampi(
		int(config.get("root_actions", DEFAULT_ROOT_ACTIONS)),
		1,
		DEFAULT_ROOT_ACTIONS,
	)
	var per_root_width := clampi(
		int(config.get("per_root_beam_width", DEFAULT_PER_ROOT_BEAM_WIDTH)),
		1,
		DEFAULT_PER_ROOT_BEAM_WIDTH,
	)
	var max_depth := clampi(
		int(config.get("max_depth", DEFAULT_MAX_DEPTH)), 1, DEFAULT_MAX_DEPTH)
	var actions_per_node := clampi(
		int(config.get("max_actions_per_node", DEFAULT_MAX_ACTIONS_PER_NODE)),
		1,
		DEFAULT_MAX_ACTIONS_PER_NODE,
	)
	var reply_depth := clampi(
		int(config.get("reply_depth", DEFAULT_REPLY_DEPTH)), 1, DEFAULT_REPLY_DEPTH)
	var reply_width := clampi(
		int(config.get("reply_beam_width", DEFAULT_REPLY_BEAM_WIDTH)),
		1,
		DEFAULT_REPLY_BEAM_WIDTH,
	)
	var reply_actions := clampi(
		int(config.get(
			"reply_actions_per_node", DEFAULT_REPLY_ACTIONS_PER_NODE)),
		1,
		DEFAULT_REPLY_ACTIONS_PER_NODE,
	)
	var seed := int(config.get("seed", 1))
	var match_seed := information_set.match_seed()
	var root_state := information_set.sample_state(seed)
	if root_state == null:
		return _failure("determinization_failed", 0, "error")
	root_state.set_type_matchups_enabled(false)
	var semantic_catalog := CardSemanticCatalog.new(engine.catalog)
	var ranked_roots := AIPositionEvaluator.ranked_actions(
		root_state,
		actor,
		root_actions,
		strategy,
		semantic_catalog,
		engine.catalog,
		match_seed,
		cancel_check,
		trusted_action_evaluator,
	)
	var fixed_root_values: Variant = config.get("fixed_root_signatures", [])
	if fixed_root_values is Array and not Array(fixed_root_values).is_empty():
		var fixed_root_signatures: Dictionary = {}
		for signature_value in Array(fixed_root_values):
			fixed_root_signatures[str(signature_value)] = true
		var filtered_roots: Array[Dictionary] = []
		for row_value in ranked_roots:
			var row: Dictionary = row_value
			if fixed_root_signatures.has(str(row.get("signature", ""))):
				filtered_roots.append(row)
		ranked_roots = filtered_roots
		root_limit = mini(root_limit, fixed_root_signatures.size())
	var root_candidates := AIPositionEvaluator.diverse_top_actions(
		ranked_roots, root_limit)
	if root_candidates.is_empty():
		return _failure("no_ranked_root_action", 0, "error")
	var trajectory := {
		"hash": "turn_beam_v2:trajectory:v1".sha256_text(),
		"events": 0,
	}
	var root_candidate_signatures: Array[String] = []
	for row_value in root_candidates:
		var row: Dictionary = row_value
		root_candidate_signatures.append(str(row.get("signature", "")))
	_trace_event(trajectory, "seed=%d|roots=%s" % [
		seed, ",".join(root_candidate_signatures)])

	var nodes_expanded := 0
	var completed_depth := 0
	var max_path_depth := 0
	var layers_completed := 0
	var frontier: Array[Dictionary] = []
	var best_complete_by_root: Dictionary = {}
	var best_partial_by_root: Dictionary = {}
	var seen: Dictionary = {}
	var root_order: Array[String] = []
	var root_fingerprint := _state_fingerprint(root_state)
	var root_precondition := information_set.cache_precondition()

	for root_index in range(root_candidates.size()):
		if _is_cancelled(cancel_check):
			return _failure("cancelled", nodes_expanded, "cancelled")
		var row: Dictionary = root_candidates[root_index]
		var action: GameAction = row.get("action")
		if action == null:
			continue
		var root_signature := str(row.get(
			"signature", AIPositionEvaluator.action_signature(action)))
		if root_signature not in root_order:
			root_order.append(root_signature)
		var branch_seed := _branch_seed(
			seed, 1, root_signature, root_signature, root_index)
		var expanded := _apply_planned_action(
			root_state,
			actor,
			action,
			engine,
			strategy,
			semantic_catalog,
			match_seed,
			branch_seed,
			cancel_check,
			trusted_choice_resolver,
		)
		nodes_expanded += 1
		if not bool(expanded.get("success", false)):
			_trace_event(trajectory, "root=%d|%s|failed" % [
				root_index, root_signature])
			if bool(expanded.get("cancelled", false)):
				return _failure("cancelled", nodes_expanded, "cancelled")
			continue
		var child: GameState = expanded["state"]
		var child_fingerprint := _state_fingerprint(child)
		var ended := _turn_has_ended(child, actor, action)
		if not ended and child_fingerprint == root_fingerprint:
			continue
		var score_milli := AIPositionEvaluator.state_score_milli(
			child,
			actor,
			strategy,
			semantic_catalog,
			engine.catalog,
			match_seed,
			trusted_leaf_evaluator,
		)
		_trace_event(trajectory, "root=%d|%s|state=%s|ended=%s|score=%d" % [
			root_index,
			root_signature,
			child_fingerprint,
			str(ended),
			score_milli,
		])
		var sequence: Array[GameAction] = [action]
		var cache_open := _action_allows_cache_continuation(
			action, expanded.get("step"), expanded.get("trace", {}))
		var node := _node(
			child,
			sequence,
			score_milli,
			ended,
			[root_precondition],
			cache_open,
			root_signature,
			action,
		)
		_record_node(
			node,
			best_complete_by_root,
			best_partial_by_root,
			seen,
			child_fingerprint,
		)
		if not ended and max_depth > 1:
			frontier.append(node)
		max_path_depth = maxi(max_path_depth, 1)
	completed_depth = 1
	layers_completed = 1
	frontier = _top_nodes_per_root(frontier, per_root_width, root_order)

	var completion_reason := "depth_complete" if max_depth == 1 else ""
	for depth in range(2, max_depth + 1):
		if frontier.is_empty():
			completion_reason = "frontier_exhausted"
			break
		var next_frontier: Array[Dictionary] = []
		for parent_value in frontier:
			if _is_cancelled(cancel_check):
				return _failure("cancelled", nodes_expanded, "cancelled")
			var parent: Dictionary = parent_value
			var parent_state: GameState = parent.get("state")
			if parent_state == null or _decision_actor(parent_state) != actor:
				continue
			var query := engine.query_legal_action_groups(parent_state, actor)
			if not query.success:
				continue
			var ranked := AIPositionEvaluator.ranked_actions(
				parent_state,
				actor,
				query.concrete_actions(),
				strategy,
				semantic_catalog,
				engine.catalog,
				match_seed,
				cancel_check,
				trusted_action_evaluator,
			)
			var candidates := AIPositionEvaluator.diverse_top_actions(
				ranked, actions_per_node)
			var parent_fingerprint := _state_fingerprint(parent_state)
			var parent_sequence: Array[GameAction] = []
			parent_sequence.assign(parent.get("sequence", []))
			var parent_sequence_signature := AIPositionEvaluator.sequence_signature(
				parent_sequence)
			for action_index in range(candidates.size()):
				if _is_cancelled(cancel_check):
					return _failure("cancelled", nodes_expanded, "cancelled")
				var action: GameAction = candidates[action_index].get("action")
				if action == null:
					continue
				var root_signature := str(parent.get("root_signature", ""))
				var branch_seed := _branch_seed(
					seed,
					depth,
					root_signature,
					parent_sequence_signature,
					action_index,
				)
				var expanded := _apply_planned_action(
					parent_state,
					actor,
					action,
					engine,
					strategy,
					semantic_catalog,
					match_seed,
					branch_seed,
					cancel_check,
					trusted_choice_resolver,
				)
				nodes_expanded += 1
				if not bool(expanded.get("success", false)):
					_trace_event(
						trajectory,
						"depth=%d|root=%s|parent=%s|action=%s|failed" % [
							depth,
							root_signature,
							parent_sequence_signature,
							AIPositionEvaluator.action_signature(action),
						],
					)
					if bool(expanded.get("cancelled", false)):
						return _failure("cancelled", nodes_expanded, "cancelled")
					continue
				var child: GameState = expanded["state"]
				var child_fingerprint := _state_fingerprint(child)
				var ended := _turn_has_ended(child, actor, action)
				if not ended and child_fingerprint == parent_fingerprint:
					continue
				var sequence: Array[GameAction] = []
				sequence.assign(parent_sequence)
				sequence.append(action)
				var cache_preconditions: Array[Dictionary] = []
				cache_preconditions.assign(parent.get("cache_preconditions", []))
				var parent_cache_open := bool(parent.get("cache_open", false))
				if parent_cache_open:
					var pre_information := AIInformationSet.capture(
						parent_state, actor, engine.catalog, [], [], match_seed)
					if pre_information.is_valid():
						cache_preconditions.append(
							pre_information.cache_precondition())
				var cache_open := (
					parent_cache_open
					and _action_allows_cache_continuation(
						action, expanded.get("step"), expanded.get("trace", {}))
				)
				var score_milli := AIPositionEvaluator.state_score_milli(
					child,
					actor,
					strategy,
					semantic_catalog,
					engine.catalog,
					match_seed,
					trusted_leaf_evaluator,
				)
				_trace_event(
					trajectory,
					"depth=%d|root=%s|parent=%s|action=%s|state=%s|ended=%s|score=%d" % [
						depth,
						root_signature,
						parent_sequence_signature,
						AIPositionEvaluator.action_signature(action),
						child_fingerprint,
						str(ended),
						score_milli,
					],
				)
				var node := _node(
					child,
					sequence,
					score_milli,
					ended,
					cache_preconditions,
					cache_open,
					root_signature,
					parent.get("root_action"),
				)
				var accepted := _record_node(
					node,
					best_complete_by_root,
					best_partial_by_root,
					seen,
					child_fingerprint,
				)
				if accepted and not ended and depth < max_depth:
					next_frontier.append(node)
				max_path_depth = maxi(max_path_depth, depth)
		completed_depth = depth
		layers_completed += 1
		frontier = _top_nodes_per_root(
			next_frontier, per_root_width, root_order)
		if depth == max_depth:
			completion_reason = "depth_complete"
		elif frontier.is_empty():
			completion_reason = "frontier_exhausted"
			break
	if completion_reason.is_empty():
		completion_reason = (
			"depth_complete"
			if completed_depth >= max_depth
			else "frontier_exhausted"
		)

	var root_plans: Array[Dictionary] = []
	var reply_completed_depth := reply_depth
	var reply_depth_applicable := false
	var reply_completion_reasons: Dictionary = {}
	for root_signature in root_order:
		var selected_node := _preferred_final_node(
			Dictionary(best_complete_by_root.get(root_signature, {})),
			Dictionary(best_partial_by_root.get(root_signature, {})),
		)
		if selected_node.is_empty():
			continue
		if _is_cancelled(cancel_check):
			return _failure("cancelled", nodes_expanded, "cancelled")
		var reply_result := _score_opponent_response(
			selected_node.get("state"),
			actor,
			strategy,
			semantic_catalog,
			engine,
			match_seed,
			reply_depth,
			reply_width,
			reply_actions,
			_branch_seed(seed, 97, root_signature, root_signature, 0),
			cancel_check,
			trusted_leaf_evaluator,
			trusted_choice_resolver,
			trajectory,
		)
		nodes_expanded += int(reply_result.get("nodes_expanded", 0))
		if bool(reply_result.get("cancelled", false)):
			return _failure("cancelled", nodes_expanded, "cancelled")
		selected_node["score_milli"] = int(reply_result.get(
			"score_milli", selected_node.get("score_milli", 0)))
		if bool(reply_result.get("reply_depth_applicable", false)):
			reply_depth_applicable = true
			reply_completed_depth = mini(
				reply_completed_depth,
				int(reply_result.get("reply_completed_depth", 0)),
			)
			var reply_reason := str(reply_result.get(
				"reply_completion_reason", "frontier_exhausted"))
			reply_completion_reasons[reply_reason] = true
		var sequence: Array[GameAction] = []
		sequence.assign(selected_node.get("sequence", []))
		root_plans.append({
			"root_signature": root_signature,
			"action": selected_node.get("root_action"),
			"sequence": sequence,
			"cache_preconditions": Array(
				selected_node.get("cache_preconditions", [])).duplicate(true),
			"score_milli": int(selected_node.get("score_milli", 0)),
			"score": float(selected_node.get("score_milli", 0))
				/ float(AIPositionEvaluator.SCORE_SCALE),
			"opponent_strategy_id": str(reply_result.get(
				"opponent_strategy_id", "")),
		})
	if root_plans.is_empty():
		return _failure("no_simulatable_action", nodes_expanded, "error")
	if not reply_depth_applicable:
		reply_completed_depth = 0
	root_plans.sort_custom(_root_plan_descending)
	var best: Dictionary = root_plans[0]
	var sequence: Array[GameAction] = []
	sequence.assign(best.get("sequence", []))
	return {
		"success": true,
		"engine_id": ENGINE_ID,
		"action": best.get("action"),
		"sequence": sequence,
		"cache_preconditions": Array(best.get(
			"cache_preconditions", [])).duplicate(true),
		"score_milli": int(best.get("score_milli", 0)),
		"score": float(best.get("score_milli", 0))
			/ float(AIPositionEvaluator.SCORE_SCALE),
		"root_plans": root_plans,
		"root_signatures_attempted": root_order.duplicate(),
		"nodes_expanded": nodes_expanded,
		"trajectory_hash": str(trajectory.get("hash", "")),
		"trajectory_events": int(trajectory.get("events", 0)),
		"requested_depth": max_depth,
		"completed_depth": completed_depth,
		"max_path_depth": max_path_depth,
		"reply_completed_depth": reply_completed_depth,
		"reply_depth_applicable": reply_depth_applicable,
		"reply_completion_reasons": reply_completion_reasons.keys(),
		"layers_completed": layers_completed,
		"completion_reason": completion_reason,
		# Compatibility aliases for consumers migrating from schema v5.
		"depth_reached": max_path_depth,
		"stop_reason": completion_reason,
		"error": "",
	}


static func _apply_planned_action(
	parent_state: GameState,
	actor: int,
	action: GameAction,
	engine: GameEngine,
	strategy: Variant,
	semantic_catalog: CardSemanticCatalog,
	match_seed: int,
	seed: int,
	cancel_check: Callable,
	trusted_choice_resolver: Callable,
) -> Dictionary:
	if _is_cancelled(cancel_check):
		return {"success": false, "cancelled": true}
	var child := parent_state.clone_state()
	child.set_type_matchups_enabled(false)
	var rng := PortableRandomSource.new(seed)
	var step := engine.apply_action(child, action, rng)
	if not step.success:
		return {"success": false, "cancelled": false}
	var trace := {
		"had_choice": false,
		"unpredictable": _step_has_unpredictable_event(step),
	}
	var choices_ok := _resolve_choices(
		child,
		actor,
		engine,
		strategy,
		semantic_catalog,
		rng,
		cancel_check,
		match_seed,
		trace,
		trusted_choice_resolver,
	)
	return {
		"success": choices_ok,
		"cancelled": not choices_ok and _is_cancelled(cancel_check),
		"state": child,
		"step": step,
		"trace": trace,
	}


static func _score_opponent_response(
	state: GameState,
	actor: int,
	root_strategy: Variant,
	semantic_catalog: CardSemanticCatalog,
	engine: GameEngine,
	match_seed: int,
	max_depth: int,
	beam_width: int,
	actions_per_node: int,
	seed: int,
	cancel_check: Callable,
	trusted_leaf_evaluator: Callable,
	trusted_choice_resolver: Callable,
	trajectory: Dictionary,
) -> Dictionary:
	var base_score := AIPositionEvaluator.state_score_milli(
		state,
		actor,
		root_strategy,
		semantic_catalog,
		engine.catalog,
		match_seed,
		trusted_leaf_evaluator,
	)
	if state == null or state.is_terminal():
		return {
			"score_milli": base_score,
			"nodes_expanded": 0,
			"reply_depth_applicable": false,
			"reply_completed_depth": 0,
			"reply_completion_reason": "frontier_exhausted",
		}
	var nodes_expanded := 0
	var opponent := 1 - actor
	var reply_root := state.clone_state()
	reply_root.set_type_matchups_enabled(false)
	if _decision_actor(reply_root) == actor:
		var yield_action := _find_turn_yield_action(reply_root, actor, engine)
		if yield_action == null:
			return {
				"score_milli": base_score,
				"nodes_expanded": nodes_expanded,
				"reply_depth_applicable": false,
				"reply_completed_depth": 0,
				"reply_completion_reason": "frontier_exhausted",
			}
		var yielded := _apply_planned_action(
			reply_root,
			actor,
			yield_action,
			engine,
			root_strategy,
			semantic_catalog,
			match_seed,
			_branch_seed(seed, 0, "yield", "yield", 0),
			cancel_check,
			trusted_choice_resolver,
		)
		nodes_expanded += 1
		if not bool(yielded.get("success", false)):
			_trace_event(trajectory, "reply_yield|failed")
			return {
				"score_milli": base_score,
				"nodes_expanded": nodes_expanded,
				"cancelled": bool(yielded.get("cancelled", false)),
				"reply_depth_applicable": false,
				"reply_completed_depth": 0,
				"reply_completion_reason": "frontier_exhausted",
			}
		reply_root = yielded["state"]
		_trace_event(trajectory, "reply_yield|state=%s" % _state_fingerprint(
			reply_root))
	if reply_root.is_terminal() or _decision_actor(reply_root) != opponent:
		return {
			"score_milli": AIPositionEvaluator.state_score_milli(
				reply_root,
				actor,
				root_strategy,
				semantic_catalog,
				engine.catalog,
				match_seed,
				trusted_leaf_evaluator,
			),
			"nodes_expanded": nodes_expanded,
			"reply_depth_applicable": false,
			"reply_completed_depth": 0,
			"reply_completion_reason": "frontier_exhausted",
		}
	var opponent_strategy: Variant = null
	var deck_key := (
		str(reply_root.public_deck_keys[opponent])
		if opponent < reply_root.public_deck_keys.size()
		else ""
	)
	var registry := AIStrategyRegistry.shared()
	if registry != null and registry.is_valid():
		opponent_strategy = registry.strategy_for(deck_key)
	var opponent_strategy_id := (
		str(opponent_strategy.strategy_id())
		if opponent_strategy != null
		else ""
	)
	var frontier: Array[Dictionary] = [{
		"state": reply_root,
		"score_milli": base_score,
		"sequence_signature": "",
	}]
	var worst_complete: Dictionary = {}
	var completed_depth := 0
	var completion_reason := "depth_complete"
	for depth in range(1, max_depth + 1):
		if frontier.is_empty():
			completion_reason = "frontier_exhausted"
			break
		var next_frontier: Array[Dictionary] = []
		for parent_value in frontier:
			if _is_cancelled(cancel_check):
				return {
					"score_milli": base_score,
					"nodes_expanded": nodes_expanded,
					"cancelled": true,
					"reply_depth_applicable": true,
					"reply_completed_depth": completed_depth,
					"reply_completion_reason": "cancelled",
				}
			var parent: Dictionary = parent_value
			var parent_state: GameState = parent.get("state")
			if parent_state == null or _decision_actor(parent_state) != opponent:
				worst_complete = _worse_node(worst_complete, parent)
				continue
			var query := engine.query_legal_action_groups(parent_state, opponent)
			if not query.success:
				worst_complete = _worse_node(worst_complete, parent)
				continue
			var ranked := AIPositionEvaluator.ranked_actions(
				parent_state,
				opponent,
				query.concrete_actions(),
				opponent_strategy,
				semantic_catalog,
				engine.catalog,
				match_seed,
				cancel_check,
			)
			var candidates := AIPositionEvaluator.diverse_top_actions(
				ranked, actions_per_node)
			for action_index in range(candidates.size()):
				var action: GameAction = candidates[action_index].get("action")
				if action == null:
					continue
				var signature := "%s|%s" % [
					str(parent.get("sequence_signature", "")),
					AIPositionEvaluator.action_signature(action),
				]
				var expanded := _apply_planned_action(
					parent_state,
					opponent,
					action,
					engine,
					opponent_strategy,
					semantic_catalog,
					match_seed,
					_branch_seed(seed, depth, deck_key, signature, action_index),
					cancel_check,
					trusted_choice_resolver,
				)
				nodes_expanded += 1
				if not bool(expanded.get("success", false)):
					_trace_event(
						trajectory,
						"reply_depth=%d|deck=%s|action=%s|failed" % [
							depth,
							deck_key,
							AIPositionEvaluator.action_signature(action),
						],
					)
					if bool(expanded.get("cancelled", false)):
						return {
							"score_milli": base_score,
							"nodes_expanded": nodes_expanded,
							"cancelled": true,
							"reply_depth_applicable": true,
							"reply_completed_depth": completed_depth,
							"reply_completion_reason": "cancelled",
						}
					continue
				var child: GameState = expanded["state"]
				var child_score := AIPositionEvaluator.state_score_milli(
					child,
					actor,
					root_strategy,
					semantic_catalog,
					engine.catalog,
					match_seed,
					trusted_leaf_evaluator,
				)
				var node := {
					"state": child,
					"score_milli": child_score,
					"sequence_signature": signature,
				}
				_trace_event(
					trajectory,
					"reply_depth=%d|deck=%s|action=%s|state=%s|ended=%s|score=%d" % [
						depth,
						deck_key,
						AIPositionEvaluator.action_signature(action),
						_state_fingerprint(child),
						str(_turn_has_ended(child, opponent, action)),
						child_score,
					],
				)
				if _turn_has_ended(child, opponent, action):
					worst_complete = _worse_node(worst_complete, node)
				elif depth < max_depth:
					next_frontier.append(node)
				else:
					# Horizon positions are compared only if no complete opponent
					# turn survived the deterministic candidate set.
					next_frontier.append(node)
		completed_depth = depth
		frontier = _bottom_nodes(next_frontier, beam_width)
		if depth < max_depth and frontier.is_empty():
			completion_reason = "frontier_exhausted"
			break
	var worst := (
		worst_complete
		if not worst_complete.is_empty()
		else (_bottom_nodes(frontier, 1)[0] if not frontier.is_empty() else {})
	)
	return {
		"score_milli": int(worst.get("score_milli", base_score)),
		"nodes_expanded": nodes_expanded,
		"opponent_strategy_id": opponent_strategy_id,
		"reply_depth_applicable": true,
		"reply_completed_depth": completed_depth,
		"reply_completion_reason": completion_reason,
	}


static func _resolve_choices(
	state: GameState,
	actor: int,
	engine: GameEngine,
	strategy: Variant,
	semantic_catalog: CardSemanticCatalog,
	rng: PortableRandomSource,
	cancel_check: Callable,
	match_seed: int,
	trace: Dictionary = {},
	trusted_choice_resolver: Callable = Callable(),
) -> bool:
	for _guard in range(MAX_CHOICE_STEPS):
		if _is_cancelled(cancel_check):
			return false
		var request := engine.query_pending_choice(state, 0)
		if request == null:
			request = engine.query_pending_choice(state, 1)
		if request == null:
			return true
		var choice_actor := request.player if request.player in [0, 1] else actor
		trace["had_choice"] = true
		var response: ChoiceResponse = null
		if trusted_choice_resolver.is_valid():
			var trusted_response: Variant = trusted_choice_resolver.call(
				state, request, match_seed, cancel_check, 0)
			if trusted_response is ChoiceResponse:
				response = trusted_response
		if response == null:
			var choice_strategy: Variant = strategy if choice_actor == actor else null
			response = _choice_response(
				state,
				choice_actor,
				request,
				choice_strategy,
				semantic_catalog,
				engine.catalog,
				match_seed,
				cancel_check,
			)
		if response == null or not AIChoiceSelector.response_is_shape_legal(
			request, response.option_ids, engine.catalog, response.cancelled):
			return false
		var step := engine.apply_choice_response(state, response, rng)
		if not step.success:
			return false
		if _step_has_unpredictable_event(step):
			trace["unpredictable"] = true
	return false


static func _choice_response(
	state: GameState,
	actor: int,
	request: ChoiceView,
	strategy: Variant,
	semantic_catalog: CardSemanticCatalog,
	catalog: CardCatalog,
	match_seed: int,
	cancel_check: Callable,
) -> ChoiceResponse:
	var information := AIInformationSet.capture(
		state, actor, catalog, [], [], match_seed)
	var public_view := (
		information.read_only_view() if information.is_valid() else {})
	var choice_row: Dictionary = request.to_dict().duplicate(true)
	choice_row.make_read_only()
	var semantic_context := AIPositionEvaluator.semantic_context_for_choice(
		request, semantic_catalog)
	var ranked: Array[Dictionary] = []
	for index in range(request.options.size()):
		if _is_cancelled(cancel_check):
			return null
		var option: Dictionary = request.options[index].duplicate(true)
		option.make_read_only()
		var strategy_value: Variant = AIPositionEvaluator._strategy_call(
			strategy,
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
	return AIChoiceSelector.response_from_ranked_scores(request, ranked, catalog)


static func _node(
	state: GameState,
	sequence: Array[GameAction],
	score_milli: int,
	ended: bool,
	cache_preconditions: Array[Dictionary],
	cache_open: bool,
	root_signature: String,
	root_action: GameAction,
) -> Dictionary:
	return {
		"state": state,
		"sequence": sequence,
		"depth": sequence.size(),
		"score_milli": score_milli,
		"ended": ended,
		"cache_preconditions": cache_preconditions,
		"cache_open": cache_open,
		"root_signature": root_signature,
		"root_action": root_action,
	}


static func _record_node(
	node: Dictionary,
	best_complete_by_root: Dictionary,
	best_partial_by_root: Dictionary,
	seen: Dictionary,
	state_fingerprint: String,
) -> bool:
	var root_signature := str(node.get("root_signature", ""))
	var seen_key := "%s|%s" % [root_signature, state_fingerprint]
	var previous: Dictionary = seen.get(seen_key, {})
	if not previous.is_empty() and not _node_is_better(node, previous):
		return false
	seen[seen_key] = node
	if bool(node.get("ended", false)):
		best_complete_by_root[root_signature] = _better_node(
			Dictionary(best_complete_by_root.get(root_signature, {})), node)
	else:
		best_partial_by_root[root_signature] = _better_partial_node(
			Dictionary(best_partial_by_root.get(root_signature, {})), node)
	return true


static func _better_node(current: Dictionary, candidate: Dictionary) -> Dictionary:
	return candidate if current.is_empty() or _node_is_better(candidate, current) else current


static func _better_partial_node(
	current: Dictionary,
	candidate: Dictionary,
) -> Dictionary:
	if current.is_empty():
		return candidate
	var current_depth := int(current.get("depth", 0))
	var candidate_depth := int(candidate.get("depth", 0))
	if candidate_depth != current_depth:
		return candidate if candidate_depth > current_depth else current
	return _better_node(current, candidate)


static func _worse_node(current: Dictionary, candidate: Dictionary) -> Dictionary:
	if current.is_empty():
		return candidate
	var candidate_score := int(candidate.get(
		"score_milli", AIPositionEvaluator.WIN_SCORE_MILLI))
	var current_score := int(current.get(
		"score_milli", AIPositionEvaluator.WIN_SCORE_MILLI))
	if candidate_score != current_score:
		return candidate if candidate_score < current_score else current
	var candidate_signature := str(candidate.get("sequence_signature", ""))
	var current_signature := str(current.get("sequence_signature", ""))
	return candidate if candidate_signature < current_signature else current


static func _node_is_better(left: Dictionary, right: Dictionary) -> bool:
	var left_score := int(left.get(
		"score_milli", -AIPositionEvaluator.WIN_SCORE_MILLI))
	var right_score := int(right.get(
		"score_milli", -AIPositionEvaluator.WIN_SCORE_MILLI))
	if left_score != right_score:
		return left_score > right_score
	return AIPositionEvaluator.sequence_signature(
		left.get("sequence", [])) < AIPositionEvaluator.sequence_signature(
			right.get("sequence", []))


static func _preferred_final_node(
	best_complete: Dictionary,
	best_partial: Dictionary,
) -> Dictionary:
	return best_complete if not best_complete.is_empty() else best_partial


static func _top_nodes_per_root(
	nodes: Array[Dictionary],
	per_root_count: int,
	root_order: Array[String],
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for root_signature in root_order:
		var group: Array[Dictionary] = []
		for node_value in nodes:
			var node: Dictionary = node_value
			if str(node.get("root_signature", "")) == root_signature:
				group.append(node)
		group.sort_custom(_node_descending)
		if group.size() > per_root_count:
			group.resize(per_root_count)
		result.append_array(group)
	return result


static func _bottom_nodes(
	nodes: Array[Dictionary],
	count: int,
) -> Array[Dictionary]:
	nodes.sort_custom(_node_ascending)
	if nodes.size() > count:
		nodes.resize(count)
	return nodes


static func _node_descending(left: Dictionary, right: Dictionary) -> bool:
	return _node_is_better(left, right)


static func _node_ascending(left: Dictionary, right: Dictionary) -> bool:
	var left_score := int(left.get(
		"score_milli", AIPositionEvaluator.WIN_SCORE_MILLI))
	var right_score := int(right.get(
		"score_milli", AIPositionEvaluator.WIN_SCORE_MILLI))
	if left_score != right_score:
		return left_score < right_score
	return str(left.get("sequence_signature", "")) < str(
		right.get("sequence_signature", ""))


static func _root_plan_descending(left: Dictionary, right: Dictionary) -> bool:
	var left_score := int(left.get(
		"score_milli", -AIPositionEvaluator.WIN_SCORE_MILLI))
	var right_score := int(right.get(
		"score_milli", -AIPositionEvaluator.WIN_SCORE_MILLI))
	if left_score != right_score:
		return left_score > right_score
	return str(left.get("root_signature", "")) < str(
		right.get("root_signature", ""))


static func _turn_has_ended(
	state: GameState,
	actor: int,
	action: GameAction,
) -> bool:
	return (
		state.is_terminal()
		or action.kind in ["DECLARE_ATTACK", "END_TURN", "SETUP_DONE"]
		or _decision_actor(state) != actor
	)


static func _find_turn_yield_action(
	state: GameState,
	actor: int,
	engine: GameEngine,
) -> GameAction:
	var query := engine.query_legal_action_groups(state, actor)
	if not query.success:
		return null
	var setup_done: GameAction = null
	for action in query.concrete_actions():
		if action.kind == "END_TURN":
			return action
		if action.kind == "SETUP_DONE":
			setup_done = action
	return setup_done


static func _decision_actor(state: GameState) -> int:
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		return (
			state.setup_actor_idx
			if state.setup_actor_idx in [0, 1]
			else state.active_player_idx
		)
	return state.active_player_idx


static func _state_fingerprint(state: GameState) -> String:
	var payload := state.to_dict()
	payload.erase("action_log")
	payload.erase("processed_action_ids")
	payload.erase("revision")
	payload.erase("choice_sequence")
	payload["resolution_stack"] = {}
	return AIPositionEvaluator.stable_variant_signature(payload).sha256_text()


static func _branch_seed(
	base_seed: int,
	depth: int,
	root_signature: String,
	sequence_signature: String,
	action_index: int,
) -> int:
	var mixed := (
		base_seed
		^ root_signature.hash()
		^ sequence_signature.hash()
		^ (depth * 32452843)
		^ ((action_index + 1) * 49979687)
	)
	return absi(mixed) + 1


static func _action_allows_cache_continuation(
	action: GameAction,
	step: StepResult,
	trace: Dictionary,
) -> bool:
	if action == null or step == null or not step.success:
		return false
	if bool(trace.get("unpredictable", false)):
		return false
	return action.kind not in ["DECLARE_ATTACK", "END_TURN", "SETUP_DONE"]


static func _step_has_unpredictable_event(step: StepResult) -> bool:
	if step == null:
		return true
	for event_value in step.events:
		if not event_value is Dictionary:
			continue
		var event_type := str(Dictionary(event_value).get("event_type", ""))
		if (
			event_type == "coin_flip"
			or event_type.contains("shuffle")
			or event_type.contains("draw")
			or event_type.contains("random")
		):
			return true
	return false


static func _is_cancelled(cancel_check: Callable) -> bool:
	return cancel_check.is_valid() and bool(cancel_check.call())


static func _trace_event(trajectory: Dictionary, event: String) -> void:
	if trajectory == null:
		return
	trajectory["hash"] = ("%s\n%s" % [
		str(trajectory.get("hash", "")),
		event,
	]).sha256_text()
	trajectory["events"] = int(trajectory.get("events", 0)) + 1


static func _failure(
	error: String,
	nodes_expanded: int,
	completion_reason: String,
) -> Dictionary:
	return {
		"success": false,
		"engine_id": ENGINE_ID,
		"action": null,
		"sequence": [],
		"cache_preconditions": [],
		"score_milli": -AIPositionEvaluator.WIN_SCORE_MILLI,
		"score": -INF,
		"root_plans": [],
		"nodes_expanded": nodes_expanded,
		"trajectory_hash": "",
		"requested_depth": DEFAULT_MAX_DEPTH,
		"completed_depth": 0,
		"max_path_depth": 0,
		"reply_completed_depth": 0,
		"reply_depth_applicable": false,
		"layers_completed": 0,
		"completion_reason": completion_reason,
		"depth_reached": 0,
		"stop_reason": completion_reason,
		"cancelled": completion_reason == "cancelled",
		"error": error,
	}


# Compatibility helpers retained for the existing tactical contract tests.
static func _diverse_top_actions(
	ranked: Array[Dictionary],
	count: int,
) -> Array[Dictionary]:
	var normalized: Array[Dictionary] = []
	for index in range(ranked.size()):
		var row: Dictionary = ranked[index].duplicate(true)
		var action: GameAction = row.get("action")
		if not row.has("score_milli"):
			row["score_milli"] = roundi(
				float(row.get("score", 0.0)) * AIPositionEvaluator.SCORE_SCALE)
		row["signature"] = AIPositionEvaluator.action_signature(action)
		row["bucket"] = AIPositionEvaluator.semantic_bucket(action)
		row["purpose_bucket"] = AIPositionEvaluator.action_purpose_bucket(action)
		row["index"] = index
		normalized.append(row)
	normalized.sort_custom(AIPositionEvaluator.action_row_descending)
	return AIPositionEvaluator.diverse_top_actions(normalized, count)


static func _terminal_candidates(candidates: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row_value in candidates:
		var row: Dictionary = row_value
		var action: GameAction = row.get("action")
		if action != null and action.terminal:
			result.append(row)
	return result


static func _board_score(player: PlayerState, catalog: CardCatalog) -> float:
	return AIPositionEvaluator.board_score(player, catalog)


static func _public_attack_profile(
	pokemon: PokemonState,
	catalog: CardCatalog,
) -> Dictionary:
	return AIPositionEvaluator.public_attack_profile(pokemon, catalog)
