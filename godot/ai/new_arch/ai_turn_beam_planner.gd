class_name AITurnBeamPlanner
extends RefCounted

## Bounded beam search over the rest of the current turn.
##
## GameState is strictly internal. Deck strategies receive only deeply
## read-only information-set dictionaries, public action/choice dictionaries,
## and CardSemanticCatalog projections.

const DEFAULT_BEAM_WIDTH := 6
const DEFAULT_MAX_DEPTH := 6
const DEFAULT_NODE_BUDGET := 192
const DEFAULT_TIME_BUDGET_MS := 850
const DEFAULT_MAX_ACTIONS_PER_NODE := 6
const WIN_SCORE := 1000000.0


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
		return _failure("invalid_information_set", 0, "invalid_input")
	if actor not in [0, 1] or actor != information_set.perspective_player():
		return _failure("actor_must_match_perspective", 0, "invalid_input")
	if engine == null or root_actions.is_empty():
		return _failure("no_legal_actions", 0, "invalid_input")
	var beam_width := clampi(int(config.get("beam_width", DEFAULT_BEAM_WIDTH)), 1, 6)
	var max_depth := clampi(int(config.get("max_depth", DEFAULT_MAX_DEPTH)), 1, 6)
	var node_budget := clampi(int(config.get("node_budget", DEFAULT_NODE_BUDGET)), 1, 192)
	var time_budget_ms := clampi(
		int(config.get("time_budget_ms", DEFAULT_TIME_BUDGET_MS)), 1, 850)
	var max_actions_per_node := clampi(
		int(config.get("max_actions_per_node", DEFAULT_MAX_ACTIONS_PER_NODE)), 1, 6)
	var seed := int(config.get("seed", 1))
	var match_seed := information_set.match_seed()
	var local_deadline_usec := Time.get_ticks_usec() + time_budget_ms * 1000
	var configured_deadline_usec := int(config.get("soft_deadline_usec", 0))
	var deadline_usec := (
		mini(local_deadline_usec, configured_deadline_usec)
		if configured_deadline_usec > 0
		else local_deadline_usec
	)
	var root_state := information_set.sample_state(seed)
	if root_state == null:
		return _failure("determinization_failed", 0, "invalid_input")
	root_state.set_type_matchups_enabled(false)
	var semantic_catalog := CardSemanticCatalog.new(engine.catalog)
	var nodes_expanded := 0
	var depth_reached := 0
	var frontier: Array[Dictionary] = []
	# Partial positions and turn-complete/horizon leaves are not comparable: only
	# the latter have paid the opponent-reply penalty.  Track them separately so
	# an attractive one-step development cannot displace a fully evaluated turn.
	var best_complete: Dictionary = {}
	var best_partial: Dictionary = {}
	var seen: Dictionary = {}
	var root_fingerprint := _state_fingerprint(root_state)
	var stop_reason := "depth_limit"
	var ranked_roots := _rank_actions(
		root_state,
		actor,
		root_actions,
		strategy,
		semantic_catalog,
		engine.catalog,
		match_seed,
		deadline_usec,
		cancel_check,
		trusted_action_evaluator,
	)
	var root_candidates := _diverse_top_actions(ranked_roots, max_actions_per_node)
	for root_index in range(root_candidates.size()):
		if _is_cancelled(cancel_check):
			stop_reason = "cancelled"
			break
		if Time.get_ticks_usec() >= deadline_usec:
			stop_reason = "deadline"
			break
		if nodes_expanded >= node_budget:
			stop_reason = "node_budget"
			break
		var action: GameAction = root_candidates[root_index]["action"]
		var child := root_state.clone_state()
		child.set_type_matchups_enabled(false)
		var rng := PortableRandomSource.new(seed + nodes_expanded * 104729 + root_index)
		nodes_expanded += 1
		var step := engine.apply_action(child, action, rng)
		if not step.success:
			continue
		var cache_trace := {
			"had_choice": false,
			"unpredictable": _step_has_unpredictable_event(step),
		}
		if not _resolve_choices(
			child,
			actor,
			engine,
			strategy,
			semantic_catalog,
			rng,
			cancel_check,
			deadline_usec,
			match_seed,
			cache_trace,
			trusted_choice_resolver,
		):
			continue
		var sequence: Array[GameAction] = [action]
		var cache_preconditions: Array[Dictionary] = [information_set.cache_precondition()]
		var cache_open := _action_allows_cache_continuation(action, step, cache_trace)
		var ended := _turn_has_ended(child, actor, action)
		var fingerprint := _state_fingerprint(child)
		# Optional trainer/ability choices may legally cancel and roll the state
		# back. Never emit such a root action: choosing it again would create an
		# unbounded legal-but-non-progress loop in the live match.
		if not ended and fingerprint == root_fingerprint:
			continue
		var evaluation := _score_with_opponent_reply(
			child,
			actor,
			strategy,
			semantic_catalog,
			engine,
			match_seed,
			sequence.size(),
			ended or max_depth == 1,
			seed + nodes_expanded * 49999,
			node_budget - nodes_expanded,
			deadline_usec,
			cancel_check,
			trusted_leaf_evaluator,
		)
		nodes_expanded += int(evaluation.get("nodes_expanded", 0))
		var score := float(evaluation.get("score", -INF))
		if not str(evaluation.get("stop_reason", "")).is_empty():
			stop_reason = str(evaluation["stop_reason"])
		var node := _node(
			child, sequence, score, ended, cache_preconditions, cache_open)
		if not seen.has(fingerprint) or score > float(seen[fingerprint]):
			seen[fingerprint] = score
			if not ended and max_depth > 1:
				frontier.append(node)
		if ended:
			best_complete = _better_node(best_complete, node)
		else:
			best_partial = _better_node(best_partial, node)
	depth_reached = 1 if not best_complete.is_empty() or not best_partial.is_empty() else 0
	frontier = _top_nodes(frontier, beam_width)
	for depth in range(2, max_depth + 1):
		if frontier.is_empty():
			if stop_reason == "depth_limit":
				stop_reason = "frontier_exhausted"
			break
		if stop_reason in ["cancelled", "deadline", "node_budget"]:
			break
		var next_frontier: Array[Dictionary] = []
		for parent in frontier:
			if bool(parent.get("ended", false)):
				continue
			if _is_cancelled(cancel_check):
				stop_reason = "cancelled"
				break
			if Time.get_ticks_usec() >= deadline_usec:
				stop_reason = "deadline"
				break
			if nodes_expanded >= node_budget:
				stop_reason = "node_budget"
				break
			var parent_state: GameState = parent["state"]
			var parent_fingerprint := _state_fingerprint(parent_state)
			if _decision_actor(parent_state) != actor:
				continue
			var query := engine.query_legal_action_groups(parent_state, actor)
			if not query.success:
				continue
			var legal_actions := query.concrete_actions()
			var ranked := _rank_actions(
				parent_state,
				actor,
				legal_actions,
				strategy,
				semantic_catalog,
				engine.catalog,
				match_seed,
				deadline_usec,
				cancel_check,
				trusted_action_evaluator,
			)
			var candidates := _diverse_top_actions(ranked, max_actions_per_node)
			if depth == max_depth:
				candidates = _terminal_candidates(candidates)
			for action_index in range(candidates.size()):
				if _is_cancelled(cancel_check):
					stop_reason = "cancelled"
					break
				if Time.get_ticks_usec() >= deadline_usec:
					stop_reason = "deadline"
					break
				if nodes_expanded >= node_budget:
					stop_reason = "node_budget"
					break
				var action: GameAction = candidates[action_index]["action"]
				var child := parent_state.clone_state()
				child.set_type_matchups_enabled(false)
				var branch_seed := (
					seed + nodes_expanded * 15485863 + depth * 32452843 + action_index)
				var rng := PortableRandomSource.new(branch_seed)
				nodes_expanded += 1
				var step := engine.apply_action(child, action, rng)
				if not step.success:
					continue
				var cache_trace := {
					"had_choice": false,
					"unpredictable": _step_has_unpredictable_event(step),
				}
				if not _resolve_choices(
					child,
					actor,
					engine,
					strategy,
					semantic_catalog,
					rng,
					cancel_check,
					deadline_usec,
					match_seed,
					cache_trace,
					trusted_choice_resolver,
				):
					continue
				var sequence: Array[GameAction] = []
				sequence.assign(parent.get("sequence", []))
				sequence.append(action)
				var cache_preconditions: Array[Dictionary] = []
				cache_preconditions.assign(parent.get("cache_preconditions", []))
				var parent_cache_open := bool(parent.get("cache_open", false))
				if parent_cache_open:
					var pre_information := AIInformationSet.capture(
						parent_state, actor, engine.catalog, [], [], match_seed)
					if pre_information.is_valid():
						cache_preconditions.append(pre_information.cache_precondition())
				var cache_open := (
					parent_cache_open
					and _action_allows_cache_continuation(action, step, cache_trace)
				)
				var ended := _turn_has_ended(child, actor, action)
				var fingerprint := _state_fingerprint(child)
				if not ended and fingerprint == parent_fingerprint:
					continue
				var evaluation := _score_with_opponent_reply(
					child,
					actor,
					strategy,
					semantic_catalog,
					engine,
					match_seed,
					sequence.size(),
					ended or depth == max_depth,
					branch_seed + 67867967,
					node_budget - nodes_expanded,
					deadline_usec,
					cancel_check,
					trusted_leaf_evaluator,
				)
				nodes_expanded += int(evaluation.get("nodes_expanded", 0))
				var score := float(evaluation.get("score", -INF))
				if not str(evaluation.get("stop_reason", "")).is_empty():
					stop_reason = str(evaluation["stop_reason"])
				var node := _node(
					child, sequence, score, ended, cache_preconditions, cache_open)
				depth_reached = maxi(depth_reached, depth)
				if seen.has(fingerprint) and float(seen[fingerprint]) >= score:
					continue
				seen[fingerprint] = score
				if ended:
					best_complete = _better_node(best_complete, node)
				else:
					best_partial = _better_node(best_partial, node)
				if not ended and depth < max_depth:
					next_frontier.append(node)
			if stop_reason in ["cancelled", "deadline", "node_budget"]:
				break
		frontier = _top_nodes(next_frontier, beam_width)
	var best := _preferred_final_node(best_complete, best_partial)
	if best.is_empty():
		return _failure("no_simulatable_action", nodes_expanded, stop_reason)
	var sequence: Array[GameAction] = []
	sequence.assign(best.get("sequence", []))
	return {
		"success": true,
		"action": sequence[0],
		"sequence": sequence,
		"cache_preconditions": Array(best.get("cache_preconditions", [])).duplicate(true),
		"score": float(best.get("score", 0.0)),
		"nodes_expanded": nodes_expanded,
		"depth_reached": depth_reached,
		"stop_reason": stop_reason,
		"error": "",
	}


static func _node(
	state: GameState,
	sequence: Array[GameAction],
	score: float,
	ended: bool,
	cache_preconditions: Array[Dictionary],
	cache_open: bool,
) -> Dictionary:
	return {
		"state": state,
		"sequence": sequence,
		"score": score,
		"ended": ended,
		"cache_preconditions": cache_preconditions,
		"cache_open": cache_open,
	}


static func _better_node(current: Dictionary, candidate: Dictionary) -> Dictionary:
	if current.is_empty() or float(candidate.get("score", -INF)) > float(
		current.get("score", -INF)):
		return candidate
	return current


static func _preferred_final_node(
	best_complete: Dictionary,
	best_partial: Dictionary,
) -> Dictionary:
	# A partial is a deadline fallback only when no action reached a common
	# comparison horizon. In ordinary MAIN states an attack or END_TURN always
	# supplies at least one complete leaf.
	return best_complete if not best_complete.is_empty() else best_partial


static func _top_nodes(nodes: Array[Dictionary], count: int) -> Array[Dictionary]:
	nodes.sort_custom(_score_descending)
	if nodes.size() > count:
		nodes.resize(count)
	return nodes


static func _score_descending(left: Dictionary, right: Dictionary) -> bool:
	return float(left.get("score", -INF)) > float(right.get("score", -INF))


static func _rank_actions(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	strategy: Variant,
	semantic_catalog: CardSemanticCatalog,
	catalog: CardCatalog,
	match_seed: int,
	deadline_usec: int,
	cancel_check: Callable,
	trusted_action_evaluator: Callable = Callable(),
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var information: AIInformationSet = AIInformationSet.capture(
		state, actor, catalog, actions, [], match_seed)
	var public_view: Dictionary = information.read_only_view() if information.is_valid() else {}
	for index in range(actions.size()):
		if _is_cancelled(cancel_check) or _deadline_reached(deadline_usec):
			break
		var action: GameAction = actions[index]
		var action_row: Dictionary = _read_only_copy(action.to_dict())
		var semantic_context: Dictionary = _semantic_context_for_action(action, semantic_catalog)
		var strategy_score: Variant = _strategy_call(
			strategy,
			"action_score",
			[public_view, action_row, semantic_context],
			NAN,
		)
		var score := _default_action_priority(
			state, actor, action, semantic_catalog)
		if trusted_action_evaluator.is_valid():
			var trusted_score: Variant = trusted_action_evaluator.call(
				state, actor, action)
			if (
				(trusted_score is float or trusted_score is int)
				and is_finite(float(trusted_score))
			):
				score = float(trusted_score)
		if strategy_score is float or strategy_score is int:
			score += float(strategy_score)
		result.append({"action": action, "score": score, "index": index})
	result.sort_custom(_rank_descending)
	return result


static func _rank_descending(left: Dictionary, right: Dictionary) -> bool:
	var left_score := float(left.get("score", -INF))
	var right_score := float(right.get("score", -INF))
	if left_score == right_score:
		return int(left.get("index", 0)) < int(right.get("index", 0))
	return left_score > right_score


static func _diverse_top_actions(ranked: Array[Dictionary], count: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var limit := mini(maxi(0, count), ranked.size())
	if limit <= 0:
		return result
	var represented_kinds: Dictionary = {}
	var used_indices: Dictionary = {}
	for index in range(ranked.size()):
		var row: Dictionary = ranked[index]
		var action: GameAction = row.get("action")
		if action == null or represented_kinds.has(action.kind):
			continue
		result.append(row)
		represented_kinds[action.kind] = true
		used_indices[index] = true
		if result.size() >= limit:
			break
	for index in range(ranked.size()):
		if result.size() >= limit:
			break
		if used_indices.has(index):
			continue
		result.append(ranked[index])
		used_indices[index] = true
	# The planner must be able to compare at least one genuinely completed turn.
	# If six higher-priority development kinds filled the cap, reserve the final
	# slot for the best attack/END/other authoritative terminal action.
	var has_terminal := false
	for row_value in result:
		var selected_action: GameAction = Dictionary(row_value).get("action")
		if selected_action != null and selected_action.terminal:
			has_terminal = true
			break
	if not has_terminal:
		for index in range(ranked.size()):
			var terminal_action: GameAction = Dictionary(ranked[index]).get("action")
			if terminal_action == null or not terminal_action.terminal:
				continue
			if result.size() >= limit:
				result[result.size() - 1] = ranked[index]
			else:
				result.append(ranked[index])
			break
	return result


static func _terminal_candidates(candidates: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row_value in candidates:
		var row: Dictionary = row_value
		var action: GameAction = row.get("action")
		if action != null and action.terminal:
			result.append(row)
	return result


static func _score_state(
	state: GameState,
	actor: int,
	strategy: Variant,
	semantic_catalog: CardSemanticCatalog,
	catalog: CardCatalog,
	match_seed: int,
	depth: int,
	deadline_usec: int,
	cancel_check: Callable,
	trusted_leaf_evaluator: Callable = Callable(),
) -> float:
	var base_score: float = _default_state_score(
		state, actor, catalog)
	if _is_cancelled(cancel_check) or _deadline_reached(deadline_usec):
		return base_score - float(depth) * 0.001
	if not state.is_terminal() and trusted_leaf_evaluator.is_valid():
		var trusted_value: Variant = trusted_leaf_evaluator.call(state, actor, catalog)
		if (
			(trusted_value is float or trusted_value is int)
			and is_finite(float(trusted_value))
		):
			# The callback is an additive strategic delta, not a second full board
			# evaluation. Bound it so prize/attack readiness in the canonical score
			# cannot be drowned out by one deck-specific engine feature.
			base_score += clampf(float(trusted_value), -600.0, 600.0) * 0.35
	var information: AIInformationSet = AIInformationSet.capture(
		state, actor, catalog, [], [], match_seed)
	if information.is_valid():
		var public_view: Dictionary = information.read_only_view()
		var semantic_context: Dictionary = _semantic_context_for_view(
			public_view, semantic_catalog)
		var strategy_score: Variant = _strategy_call(
			strategy, "state_score", [public_view, semantic_context], NAN)
		if strategy_score is float or strategy_score is int:
			base_score += float(strategy_score)
	return base_score - float(depth) * 0.001


static func _score_with_opponent_reply(
	state: GameState,
	actor: int,
	strategy: Variant,
	semantic_catalog: CardSemanticCatalog,
	engine: GameEngine,
	match_seed: int,
	depth: int,
	include_reply: bool,
	seed: int,
	remaining_nodes: int,
	deadline_usec: int,
	cancel_check: Callable,
	trusted_leaf_evaluator: Callable = Callable(),
) -> Dictionary:
	var base_score := _score_state(
		state,
		actor,
		strategy,
		semantic_catalog,
		engine.catalog,
		match_seed,
		depth,
		deadline_usec,
		cancel_check,
		trusted_leaf_evaluator,
	)
	if not include_reply or state.is_terminal():
		return {"score": base_score, "nodes_expanded": 0, "stop_reason": ""}
	var used := 0
	var opponent := 1 - actor
	var reply_root := state.clone_state()
	reply_root.set_type_matchups_enabled(false)
	if _decision_actor(reply_root) == actor:
		if _is_cancelled(cancel_check):
			return {"score": base_score, "nodes_expanded": used, "stop_reason": "cancelled"}
		if Time.get_ticks_usec() >= deadline_usec:
			return {"score": base_score, "nodes_expanded": used, "stop_reason": "deadline"}
		if used >= remaining_nodes:
			return {"score": base_score, "nodes_expanded": used, "stop_reason": "node_budget"}
		var yield_action := _find_turn_yield_action(reply_root, actor, engine)
		if yield_action == null:
			return {"score": base_score, "nodes_expanded": used, "stop_reason": ""}
		var yield_rng := PortableRandomSource.new(seed + 7919)
		used += 1
		var yielded := engine.apply_action(reply_root, yield_action, yield_rng)
		if not yielded.success or not _resolve_choices(
			reply_root,
			actor,
			engine,
			strategy,
			semantic_catalog,
			yield_rng,
			cancel_check,
			deadline_usec,
			match_seed,
		):
			return {"score": base_score, "nodes_expanded": used, "stop_reason": ""}
	if reply_root.is_terminal():
		return {
			"score": _score_state(
				reply_root,
				actor,
				strategy,
				semantic_catalog,
				engine.catalog,
				match_seed,
				depth,
				deadline_usec,
				cancel_check,
				trusted_leaf_evaluator,
			),
			"nodes_expanded": used,
			"stop_reason": "",
		}
	if _decision_actor(reply_root) != opponent:
		return {"score": base_score, "nodes_expanded": used, "stop_reason": ""}
	var query := engine.query_legal_action_groups(reply_root, opponent)
	if not query.success:
		return {"score": base_score, "nodes_expanded": used, "stop_reason": ""}
	var replies := _rank_actions(
		reply_root,
		opponent,
		query.concrete_actions(),
		null,
		semantic_catalog,
		engine.catalog,
		match_seed,
		deadline_usec,
		cancel_check,
	)
	var worst_score := INF
	var evaluated := 0
	var local_stop := ""
	for reply_index in range(mini(3, replies.size())):
		if _is_cancelled(cancel_check):
			local_stop = "cancelled"
			break
		if Time.get_ticks_usec() >= deadline_usec:
			local_stop = "deadline"
			break
		if used >= remaining_nodes:
			local_stop = "node_budget"
			break
		var reply_action: GameAction = replies[reply_index]["action"]
		var response_state := reply_root.clone_state()
		response_state.set_type_matchups_enabled(false)
		var reply_rng := PortableRandomSource.new(seed + 104729 * (reply_index + 1))
		used += 1
		var applied := engine.apply_action(response_state, reply_action, reply_rng)
		if not applied.success:
			continue
		if not _resolve_choices(
			response_state,
			opponent,
			engine,
			null,
			semantic_catalog,
			reply_rng,
			cancel_check,
			deadline_usec,
			match_seed,
		):
			continue
		var response_score := _score_state(
			response_state,
			actor,
			strategy,
			semantic_catalog,
			engine.catalog,
			match_seed,
			depth + 1,
			deadline_usec,
			cancel_check,
			trusted_leaf_evaluator,
		)
		worst_score = minf(worst_score, response_score)
		evaluated += 1
	return {
		"score": worst_score if evaluated > 0 else base_score,
		"nodes_expanded": used,
		"stop_reason": local_stop,
	}


static func _find_turn_yield_action(
	state: GameState,
	actor: int,
	engine: GameEngine,
) -> GameAction:
	var query := engine.query_legal_action_groups(state, actor)
	if not query.success:
		return null
	var setup_done: GameAction
	for action in query.concrete_actions():
		if action.kind == "END_TURN":
			return action
		if action.kind == "SETUP_DONE":
			setup_done = action
	return setup_done


static func _resolve_choices(
	state: GameState,
	actor: int,
	engine: GameEngine,
	strategy: Variant,
	semantic_catalog: CardSemanticCatalog,
	rng: PortableRandomSource,
	cancel_check: Callable,
	deadline_usec: int,
	match_seed: int,
	trace: Dictionary = {},
	trusted_choice_resolver: Callable = Callable(),
) -> bool:
	for _guard in range(32):
		if _is_cancelled(cancel_check) or _deadline_reached(deadline_usec):
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
				state, request, match_seed, cancel_check, deadline_usec)
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
				deadline_usec,
				cancel_check,
			)
		if not AIChoiceSelector.response_is_shape_legal(
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
	deadline_usec: int,
	cancel_check: Callable,
) -> ChoiceResponse:
	var information: AIInformationSet = AIInformationSet.capture(
		state, actor, catalog, [], [], match_seed)
	var public_view: Dictionary = information.read_only_view() if information.is_valid() else {}
	var choice_row: Dictionary = _read_only_copy(request.to_dict())
	var semantic_context: Dictionary = _semantic_context_for_choice(
		request, semantic_catalog)
	var ranked: Array[Dictionary] = []
	var scored: Dictionary = {}
	for index in range(request.options.size()):
		if _is_cancelled(cancel_check) or _deadline_reached(deadline_usec):
			break
		var option: Dictionary = request.options[index]
		var option_row: Dictionary = _read_only_copy(option)
		var score_value: Variant = _strategy_call(
			strategy,
			"choice_score",
			[public_view, choice_row, option_row, semantic_context],
			0.0,
		)
		var score := float(score_value) if score_value is float or score_value is int else 0.0
		ranked.append({"option": option, "score": score, "index": index})
		scored[index] = true
	for index in range(request.options.size()):
		if not scored.has(index):
			ranked.append({
				"option": request.options[index], "score": 0.0, "index": index,
			})
	ranked.sort_custom(_rank_descending)
	return AIChoiceSelector.response_from_ranked_scores(request, ranked, catalog)


static func _default_action_priority(
	state: GameState,
	actor: int,
	action: GameAction,
	semantic_catalog: CardSemanticCatalog,
) -> float:
	match action.kind:
		"DECLARE_ATTACK":
			var card_id := action.source.card_id if action.source != null else ""
			var attack_index := int(action.payload.get("attack_index", -1))
			var attack := semantic_catalog.attack_semantics(card_id, attack_index)
			return 500.0 + float(attack.get("expected_damage", 0.0))
		"USE_ABILITY":
			return 420.0
		"PLAY_TRAINER":
			return 360.0
		"EVOLVE":
			return 320.0
		"ATTACH_ENERGY":
			return 280.0
		"PLAY_BASIC":
			return 220.0
		"USE_STADIUM":
			return 180.0
		"RETREAT", "PROMOTE":
			return 140.0
		"SETUP_DONE":
			return 40.0
		"END_TURN":
			return -100.0
		_:
			return 0.0


static func _default_state_score(state: GameState, actor: int, catalog: CardCatalog) -> float:
	if state.is_terminal():
		if state.result_status == GameState.RESULT_DRAW:
			return 0.0
		return WIN_SCORE if state.winner == actor else -WIN_SCORE
	var own := state.get_player(actor)
	var opponent := state.get_player(1 - actor)
	var score := float(opponent.prizes.size() - own.prizes.size()) * 150.0
	score += float(own.hand.size() - opponent.hand.size()) * 2.0
	score += float(own.deck.size() - opponent.deck.size()) * 0.05
	score += _board_score(own, catalog) - _board_score(opponent, catalog)
	return score


static func _board_score(player: PlayerState, catalog: CardCatalog) -> float:
	var score := 0.0
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var remaining_hp := pokemon.current_hp(catalog)
		var is_active := str(row["slot"]) == "active"
		var slot_weight := 1.2 if is_active else 1.0
		var attack_profile := _public_attack_profile(pokemon, catalog)
		score += float(remaining_hp) * 0.35 * slot_weight
		# Reward only energy units that advance a printed attack cost. Wrong-type
		# and excess units remain public resources, but are inefficiently stranded.
		score += float(attack_profile["useful_units"]) * 8.0
		score -= float(attack_profile["stranded_units"]) * 5.0
		var missing := int(attack_profile["minimum_missing"])
		var preparation_factor := 0.0
		if missing == 0:
			preparation_factor = 1.0
		elif missing == 1:
			preparation_factor = 0.55
		elif missing == 2:
			preparation_factor = 0.20
		score += preparation_factor * (26.0 if is_active else 14.0)
		if is_active:
			score += (
				45.0
				* float(attack_profile["ready_ratio"])
				* float(attack_profile["gate_probability"])
			)
		score += float(catalog.prize_value(pokemon.card_id)) * 2.0
	return score


static func _public_attack_profile(
	pokemon: PokemonState,
	catalog: CardCatalog,
) -> Dictionary:
	var result := {
		"available_units": 0,
		"useful_units": 0,
		"stranded_units": 0,
		"eligible_attacks": 0,
		"ready_attacks": 0,
		"ready_ratio": 0.0,
		"minimum_missing": 99,
		"gate_probability": 1.0,
	}
	if pokemon == null or catalog == null:
		return result
	var available: Array[String] = []
	available.assign(pokemon.available_energy(catalog))
	result["available_units"] = available.size()
	var attacks: Array = catalog.get_card(pokemon.card_id).get("attacks", [])
	var useful_units := 0
	var eligible_attacks := 0
	var ready_attacks := 0
	var minimum_missing := 99
	for attack_value in attacks:
		if not attack_value is Dictionary:
			continue
		var attack: Dictionary = attack_value
		var cost: Array = attack.get("cost", [])
		var missing := _missing_energy_units_from_available(available, cost)
		useful_units = maxi(useful_units, maxi(0, cost.size() - missing))
		var attack_name := str(attack.get("name", ""))
		if pokemon.attack_is_locked(attack_name):
			continue
		eligible_attacks += 1
		minimum_missing = mini(minimum_missing, missing)
		if missing == 0:
			ready_attacks += 1
	result["useful_units"] = useful_units
	result["stranded_units"] = maxi(0, available.size() - useful_units)
	result["eligible_attacks"] = eligible_attacks
	result["ready_attacks"] = ready_attacks
	result["minimum_missing"] = minimum_missing
	result["ready_ratio"] = (
		float(ready_attacks) / float(eligible_attacks)
		if eligible_attacks > 0
		else 0.0
	)
	var gate_probability := 1.0
	if (
		"ASLEEP" in pokemon.status_conditions
		or "PARALYZED" in pokemon.status_conditions
	):
		gate_probability = 0.0
	else:
		if "CONFUSED" in pokemon.status_conditions:
			gate_probability *= 0.5
		if pokemon.has_attack_gate("dazzled"):
			gate_probability *= 0.5
	result["gate_probability"] = gate_probability
	return result


static func _missing_energy_units_from_available(
	available_input: Array[String],
	cost: Array,
) -> int:
	var available: Array[String] = []
	available.assign(available_input)
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
	return missing + maxi(0, colorless - available.size())


static func _turn_has_ended(state: GameState, actor: int, action: GameAction) -> bool:
	return (
		state.is_terminal()
		or action.kind in ["DECLARE_ATTACK", "END_TURN", "SETUP_DONE"]
		or _decision_actor(state) != actor
	)


static func _action_allows_cache_continuation(
	action: GameAction,
	step: StepResult,
	trace: Dictionary,
) -> bool:
	if action == null or step == null or not step.success:
		return false
	if bool(trace.get("unpredictable", false)):
		return false
	# Every later intent carries the exact public fingerprint expected immediately
	# before it. Deterministic choice outcomes can therefore reuse the plan, while
	# draws, shuffles and coin flips automatically invalidate it when the live
	# public branch differs from the sampled branch.
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


static func _decision_actor(state: GameState) -> int:
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		return state.setup_actor_idx if state.setup_actor_idx in [0, 1] else state.active_player_idx
	return state.active_player_idx


static func _state_fingerprint(state: GameState) -> String:
	var payload := state.to_dict()
	payload.erase("action_log")
	payload.erase("processed_action_ids")
	payload.erase("revision")
	payload.erase("choice_sequence")
	payload["resolution_stack"] = {}
	return "%08x" % JSON.stringify(payload).hash()


static func _semantic_context_for_action(
	action: GameAction,
	semantic_catalog: CardSemanticCatalog,
) -> Dictionary:
	var ids: Array[String] = []
	for ref_value in [action.source, action.target]:
		var ref: EntityRef = ref_value
		if ref != null and not ref.card_id.is_empty() and ref.card_id not in ids:
			ids.append(ref.card_id)
	return _semantic_context(ids, semantic_catalog)


static func _semantic_context_for_choice(
	request: ChoiceView,
	semantic_catalog: CardSemanticCatalog,
) -> Dictionary:
	var ids: Array[String] = []
	for option_value in request.options:
		if not option_value is Dictionary:
			continue
		var ref_value: Variant = Dictionary(option_value).get("ref")
		if not ref_value is Dictionary:
			continue
		var card_id := str(Dictionary(ref_value).get("card_id", ""))
		if not card_id.is_empty() and card_id not in ids:
			ids.append(card_id)
	return _semantic_context(ids, semantic_catalog)


static func _semantic_context_for_view(
	view: Dictionary,
	semantic_catalog: CardSemanticCatalog,
) -> Dictionary:
	var ids: Array[String] = []
	var stadium_id := str(view.get("stadium_card_id", ""))
	if not stadium_id.is_empty():
		ids.append(stadium_id)
	for player_value in view.get("players", []):
		if not player_value is Dictionary:
			continue
		var player: Dictionary = player_value
		for zone in ["hand", "discard"]:
			for card_id_value in player.get(zone, []):
				var card_id := str(card_id_value)
				if not card_id.begins_with("__ai_hidden_") and card_id not in ids:
					ids.append(card_id)
		_append_visible_pokemon_ids(ids, player.get("active"))
		for pokemon_value in player.get("bench", []):
			_append_visible_pokemon_ids(ids, pokemon_value)
	return _semantic_context(ids, semantic_catalog)


static func _append_visible_pokemon_ids(ids: Array[String], value: Variant) -> void:
	if not value is Dictionary:
		return
	var pokemon: Dictionary = value
	for field in ["card_id", "attached_tool_id"]:
		var card_id := str(pokemon.get(field, ""))
		if not card_id.is_empty() and card_id not in ids:
			ids.append(card_id)
	for field in ["evolution_stack_ids", "energy_card_ids"]:
		for card_id_value in pokemon.get(field, []):
			var card_id := str(card_id_value)
			if not card_id.is_empty() and card_id not in ids:
				ids.append(card_id)


static func _semantic_context(
	card_ids: Array[String],
	semantic_catalog: CardSemanticCatalog,
) -> Dictionary:
	var cards: Dictionary = {}
	for card_id in card_ids:
		cards[card_id] = semantic_catalog.semantics_for(card_id)
	var result := {"cards": cards}
	_deep_make_read_only(result)
	return result


static func _strategy_call(
	strategy: Variant,
	method: String,
	args: Array,
	fallback: Variant,
) -> Variant:
	if strategy is Dictionary:
		var callable_value: Variant = Dictionary(strategy).get(method)
		if callable_value is Callable and Callable(callable_value).is_valid():
			return Callable(callable_value).callv(args)
	elif typeof(strategy) == TYPE_OBJECT and strategy != null and strategy.has_method(method):
		return strategy.callv(method, args)
	return fallback


static func _read_only_copy(value: Variant) -> Variant:
	var result: Variant = value.duplicate(true) if value is Dictionary or value is Array else value
	_deep_make_read_only(result)
	return result


static func _deep_make_read_only(value: Variant) -> void:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for nested_value in dictionary.values():
			_deep_make_read_only(nested_value)
		dictionary.make_read_only()
	elif value is Array:
		var array: Array = value
		for nested_value in array:
			_deep_make_read_only(nested_value)
		array.make_read_only()


static func _is_cancelled(cancel_check: Callable) -> bool:
	return cancel_check.is_valid() and bool(cancel_check.call())


static func _deadline_reached(deadline_usec: int) -> bool:
	return deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec


static func _failure(error: String, nodes_expanded: int, stop_reason: String) -> Dictionary:
	return {
		"success": false,
		"action": null,
		"sequence": [],
		"cache_preconditions": [],
		"score": -INF,
		"nodes_expanded": nodes_expanded,
		"depth_reached": 0,
		"stop_reason": stop_reason,
		"error": error,
	}
