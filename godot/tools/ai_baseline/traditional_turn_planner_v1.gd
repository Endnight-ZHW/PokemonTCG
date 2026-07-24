class_name TraditionalTurnPlannerV1
extends RefCounted

## Stable integration facade for the replacement traditional AI.
##
## `request` is intentionally metadata-only. No state/snapshot/observation key
## is ever read; every simulated position originates at AIInformationSet.


static func plan_action(
	request: Dictionary,
	information_set: AIInformationSet,
	actions: Array[GameAction],
	strategy: Variant,
	catalog: CardCatalog,
	engine: GameEngine,
	cancel_check: Callable = Callable(),
	trusted_leaf_evaluator: Callable = Callable(),
	trusted_choice_resolver: Callable = Callable(),
	trusted_action_evaluator: Callable = Callable(),
) -> Dictionary:
	var planning_started_usec := Time.get_ticks_usec()
	if information_set == null or not information_set.is_valid():
		return _failure(
			information_set.validation_error() if information_set != null else "null_information_set")
	if actions.is_empty():
		return _failure("no_legal_actions")
	var config := _planner_config_from_request(request)
	var safe_catalog := catalog if catalog != null else CardCatalog.shared()
	var safe_engine := engine if engine != null else GameEngine.new(safe_catalog)
	var seed := int(config.get("seed", 1))
	var actor := information_set.perspective_player()
	var total_node_budget := maxi(1, int(config.get("node_budget", 192)))
	var total_time_budget_ms := clampi(int(config.get("time_budget_ms", 850)), 1, 850)
	var configured_soft_deadline := int(config.get("soft_deadline_usec", 0))
	var soft_deadline_usec := (
		configured_soft_deadline
		if configured_soft_deadline > 0
		else planning_started_usec + total_time_budget_ms * 1000
	)
	soft_deadline_usec = mini(
		soft_deadline_usec, planning_started_usec + total_time_budget_ms * 1000)
	var configured_hard_deadline := int(config.get("hard_deadline_usec", 0))
	var hard_deadline_usec := (
		configured_hard_deadline
		if configured_hard_deadline > 0
		else soft_deadline_usec + 250000
	)
	hard_deadline_usec = mini(hard_deadline_usec, planning_started_usec + 1100000)
	var nodes_used := clampi(int(config.get("initial_nodes_used", 0)), 0, total_node_budget)
	var tactical_state := information_set.sample_state(seed)
	if tactical_state == null:
		return _failure("determinization_failed")
	var legal_actions := _validated_legal_actions(
		tactical_state, actor, actions, safe_engine, information_set)
	if legal_actions.is_empty():
		return _failure("no_authoritative_legal_action")
	var root_precondition := information_set.cache_precondition()
	if not bool(config.get("skip_mandatory", false)) and nodes_used < total_node_budget:
		var tactics := AIMandatoryTactics.new()
		var forced := tactics.resolve(
			information_set,
			tactical_state,
			actor,
			legal_actions,
			safe_engine,
			strategy,
			seed,
			cancel_check,
			soft_deadline_usec,
			total_node_budget - nodes_used,
			trusted_choice_resolver,
			trusted_action_evaluator,
		)
		nodes_used += mini(
			total_node_budget - nodes_used,
			maxi(0, int(forced.get("nodes_expanded", 0))),
		)
		if bool(forced.get("resolved", false)):
			var forced_action: GameAction = forced["action"]
			return _success_result(
				forced_action,
				[forced_action],
				0.0,
				nodes_used,
				str(forced.get("reason", "mandatory")),
				str(forced.get("reason", "mandatory")),
				[_plan_step(forced_action, root_precondition)],
			)
	var planner := AITurnBeamPlannerV1.new()
	var configured_samples := int(config.get("belief_samples", 0))
	var requested_samples := (
		clampi(configured_samples, 1, 3)
		if configured_samples > 0
		else recommended_belief_samples(
			legal_actions, CardSemanticCatalog.new(safe_catalog))
	)
	var belief_samples := mini(requested_samples, total_node_budget - nodes_used)
	var attempted_samples := 0
	var aggregate: Dictionary = {}
	var last_planned: Dictionary = {}
	var fallback_reason := "beam_fallback"
	for sample_index in range(belief_samples):
		if cancel_check.is_valid() and bool(cancel_check.call()):
			fallback_reason = "cancelled"
			break
		var now_usec := Time.get_ticks_usec()
		if now_usec >= hard_deadline_usec or now_usec >= soft_deadline_usec:
			fallback_reason = "deadline"
			break
		var remaining_time_ms := maxi(0, int((soft_deadline_usec - now_usec) / 1000))
		var remaining_nodes := total_node_budget - nodes_used
		if remaining_time_ms <= 0 or remaining_nodes <= 0:
			fallback_reason = "deadline" if remaining_time_ms <= 0 else "node_budget"
			break
		var remaining_samples := belief_samples - sample_index
		var sample_config := config.duplicate(true)
		sample_config["seed"] = seed + sample_index * 1000003
		sample_config["node_budget"] = maxi(
			1, floori(float(remaining_nodes) / float(remaining_samples)))
		sample_config["time_budget_ms"] = maxi(
			1, floori(float(remaining_time_ms) / float(remaining_samples)))
		sample_config["soft_deadline_usec"] = mini(
			soft_deadline_usec,
			now_usec + int(sample_config["time_budget_ms"]) * 1000,
		)
		sample_config["hard_deadline_usec"] = hard_deadline_usec
		var planned := planner.plan(
			information_set,
			actor,
			legal_actions,
			safe_engine,
			strategy,
			sample_config,
			cancel_check,
			trusted_leaf_evaluator,
			trusted_choice_resolver,
			trusted_action_evaluator,
		)
		last_planned = planned
		attempted_samples += 1
		var expanded := mini(
			remaining_nodes, maxi(0, int(planned.get("nodes_expanded", 0))))
		nodes_used += expanded
		if not bool(planned.get("success", false)):
			continue
		var planned_action: GameAction = planned.get("action")
		if planned_action == null:
			continue
		var signature := str(action_intent(planned_action).get("signature", ""))
		var row: Dictionary = aggregate.get(signature, {
			"count": 0,
			"score_total": 0.0,
			"representative_score": -INF,
			"planned": {},
		})
		row["count"] = int(row["count"]) + 1
		row["score_total"] = float(row["score_total"]) + float(
			planned.get("score", 0.0))
		if float(planned.get("score", -INF)) > float(row["representative_score"]):
			row["representative_score"] = float(planned.get("score", -INF))
			row["planned"] = planned
		aggregate[signature] = row
	if not aggregate.is_empty():
		var selected_row: Dictionary = {}
		for row_value in aggregate.values():
			var row: Dictionary = row_value
			if selected_row.is_empty() or _belief_row_is_better(row, selected_row):
				selected_row = row
		var selected_plan: Dictionary = selected_row["planned"]
		var sequence: Array[GameAction] = []
		sequence.assign(selected_plan.get("sequence", []))
		var plan_steps := _plan_steps_from_preconditions(
			sequence, Array(selected_plan.get("cache_preconditions", [])))
		var result := _success_result(
			selected_plan["action"],
			sequence,
			float(selected_row["score_total"]) / float(maxi(1, int(selected_row["count"]))),
			nodes_used,
			str(selected_plan.get("stop_reason", "complete")),
			"",
			plan_steps,
		)
		result["belief_samples"] = attempted_samples
		result["belief_consensus"] = int(selected_row["count"])
		result["search_depth_applicable"] = true
		result["search_depth_requested"] = int(config.get("max_depth", 6))
		result["search_depth_reached"] = int(selected_plan.get("depth_reached", 0))
		result["search_depth_stop_reason"] = str(
			selected_plan.get("stop_reason", "complete"))
		return result
	# The fallback comes from a fresh engine query intersected with the supplied
	# roots, so even direct/internal callers cannot turn an invalid row into an
	# emitted action when the budget expires before a simulation completes.
	var fallback := AIMandatoryTactics.survival_backup_action(
		tactical_state,
		actor,
		legal_actions,
		information_set,
		strategy,
		safe_catalog,
		trusted_action_evaluator,
	)
	if fallback == null:
		fallback = legal_actions[0]
	var result := _success_result(
		fallback,
		[fallback],
		-INF,
		nodes_used,
		fallback_reason,
		"",
		[_plan_step(fallback, root_precondition)],
	)
	result["belief_samples"] = attempted_samples
	result["belief_consensus"] = 0
	result["error"] = str(last_planned.get("error", "planner_failed"))
	result["search_depth_applicable"] = true
	result["search_depth_requested"] = int(config.get("max_depth", 6))
	result["search_depth_reached"] = int(last_planned.get("depth_reached", 0))
	result["search_depth_stop_reason"] = str(
		last_planned.get("stop_reason", fallback_reason))
	return result


static func _belief_row_is_better(left: Dictionary, right: Dictionary) -> bool:
	var left_count := int(left.get("count", 0))
	var right_count := int(right.get("count", 0))
	if left_count != right_count:
		return left_count > right_count
	var left_average := float(left.get("score_total", 0.0)) / float(maxi(1, left_count))
	var right_average := float(right.get("score_total", 0.0)) / float(maxi(1, right_count))
	return left_average > right_average


static func recommended_belief_samples(
	actions: Array[GameAction],
	semantic_catalog: CardSemanticCatalog,
) -> int:
	## Deterministic roots benefit from one coherent 192-node turn search. Split
	## the budget into three seeded beliefs only when an action can actually
	## expose an unresolved random VM branch.
	if semantic_catalog == null:
		return 3
	for action in actions:
		if action == null:
			continue
		var card_id := action.source.card_id if action.source != null else ""
		if card_id.is_empty():
			card_id = str(action.payload.get("card_id", ""))
		if card_id.is_empty():
			continue
		match action.kind:
			"DECLARE_ATTACK":
				var attack_index := int(action.payload.get(
					"attack_index", action.payload.get("attack_idx", -1)))
				if bool(semantic_catalog.attack_semantics(
					card_id, attack_index).get("has_random_effect", false)):
					return 3
			"PLAY_TRAINER", "USE_STADIUM":
				if _semantic_commands_have_random_effect(
					semantic_catalog.semantics_for(card_id).get("trainer_commands", [])):
					return 3
			"USE_ABILITY":
				var ability_name := str(action.payload.get("ability_name", ""))
				if not ability_name.is_empty():
					if _semantic_commands_have_random_effect(
						semantic_catalog.ability_semantics(
							card_id, ability_name).get("commands", [])):
						return 3
				else:
					for ability_value in semantic_catalog.semantics_for(
						card_id).get("abilities", []):
						if (
							ability_value is Dictionary
							and _semantic_commands_have_random_effect(
								Dictionary(ability_value).get("commands", []))
						):
							return 3
	return 1


static func _semantic_commands_have_random_effect(commands_value: Variant) -> bool:
	return CardSemanticCatalog.commands_require_belief_sampling(commands_value)


static func _validated_legal_actions(
	state: GameState,
	actor: int,
	supplied: Array[GameAction],
	engine: GameEngine,
	information_set: AIInformationSet,
) -> Array[GameAction]:
	var result: Array[GameAction] = []
	var query := engine.query_legal_action_groups(state, actor)
	if not query.success:
		return result
	var authoritative: Array[GameAction] = []
	authoritative.assign(query.concrete_actions())
	var used: Dictionary = {}
	for supplied_action in supplied:
		var intent := action_intent(supplied_action)
		var matched := find_matching_action(intent, authoritative, information_set)
		if matched == null:
			continue
		var signature := str(action_intent(matched).get("signature", ""))
		if used.has(signature):
			continue
		used[signature] = true
		result.append(matched)
	return result


static func _plan_step(action: GameAction, precondition: Dictionary) -> Dictionary:
	var result := action_intent(action)
	for key in ["expected_public_fingerprint", "expected_actor", "expected_phase"]:
		if precondition.has(key):
			result[key] = precondition[key]
	return result


static func _plan_steps_from_preconditions(
	sequence: Array[GameAction],
	preconditions: Array,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(mini(sequence.size(), preconditions.size())):
		if preconditions[index] is Dictionary:
			result.append(_plan_step(sequence[index], preconditions[index]))
	return result


static func action_intent(action: GameAction, _state: Variant = null) -> Dictionary:
	if action == null:
		return {}
	var result := {
		"kind": action.kind,
		"intent": _semantic_intent(action.kind),
		"actor": action.actor,
		"source": _stable_ref(action.source),
		"target": _stable_ref(action.target),
		"payload": action.payload.duplicate(true),
	}
	result["signature"] = _intent_signature(result)
	return result


static func find_matching_action(
	intent: Dictionary,
	actions: Array[GameAction],
	information_set: AIInformationSet = null,
) -> GameAction:
	if intent.is_empty():
		return null
	if (
		information_set != null
		and information_set.is_valid()
		and intent.has("actor")
		and int(intent["actor"]) != information_set.perspective_player()
	):
		return null
	var expected_signature := str(intent.get("signature", ""))
	if not expected_signature.is_empty():
		for action in actions:
			if str(action_intent(action).get("signature", "")) == expected_signature:
				return action
	for action in actions:
		var candidate := action_intent(action)
		if _intent_fields_match(intent, candidate):
			return action
	return null


static func _planner_config_from_request(request: Dictionary) -> Dictionary:
	## Security boundary: only these scalar metadata keys are inspected.
	var result: Dictionary = {
		"beam_width": 6,
		"max_actions_per_node": 6,
		"max_depth": 6,
		"node_budget": 192,
		"time_budget_ms": 850,
		# Zero means infer 1 or 3 from the legal root semantics.
		"belief_samples": 0,
		"soft_deadline_usec": 0,
		"hard_deadline_usec": 0,
		"initial_nodes_used": 0,
		"skip_mandatory": false,
		"seed": 1,
	}
	if request.get("seed") is int or request.get("seed") is float:
		result["seed"] = int(request["seed"])
	if request.get("node_budget") is int or request.get("node_budget") is float:
		result["node_budget"] = clampi(int(request["node_budget"]), 1, 192)
	if request.get("max_depth") is int or request.get("max_depth") is float:
		result["max_depth"] = clampi(int(request["max_depth"]), 1, 6)
	elif request.get("turn_depth") is int or request.get("turn_depth") is float:
		result["max_depth"] = clampi(int(request["turn_depth"]), 1, 6)
	if request.get("time_budget_ms") is int or request.get("time_budget_ms") is float:
		result["time_budget_ms"] = clampi(int(request["time_budget_ms"]), 1, 850)
	elif request.get("seconds") is int or request.get("seconds") is float:
		result["time_budget_ms"] = clampi(
			int(float(request["seconds"]) * 1000.0), 1, 850)
	if request.get("belief_samples") is int or request.get("belief_samples") is float:
		result["belief_samples"] = clampi(int(request["belief_samples"]), 1, 3)
	for key in ["soft_deadline_usec", "hard_deadline_usec", "initial_nodes_used"]:
		if request.get(key) is int or request.get(key) is float:
			result[key] = int(request[key])
	if request.get("skip_mandatory") is bool:
		result["skip_mandatory"] = bool(request["skip_mandatory"])
	# Mode is allowed metadata, but does not grant a wider state boundary.
	if request.get("mode") is String:
		result["mode"] = str(request["mode"])
	return result


static func _success_result(
	action: GameAction,
	sequence: Array[GameAction],
	score: float,
	nodes_expanded: int,
	stop_reason: String,
	forced_tactic: String,
	plan_steps: Array = [],
) -> Dictionary:
	var plan: Array[Dictionary] = []
	if not plan_steps.is_empty():
		for step_value in plan_steps:
			if step_value is Dictionary:
				plan.append(Dictionary(step_value).duplicate(true))
	else:
		for planned_action in sequence:
			plan.append(action_intent(planned_action))
	return {
		"success": action != null,
		"action": action,
		"action_dict": action.to_dict() if action != null else {},
		"turn_plan": plan,
		"nodes_expanded": nodes_expanded,
		"stop_reason": stop_reason,
		"score": score,
		"forced_tactic": forced_tactic,
		"error": "",
	}


static func _failure(error: String) -> Dictionary:
	return {
		"success": false,
		"action": null,
		"action_dict": {},
		"turn_plan": [],
		"nodes_expanded": 0,
		"stop_reason": "invalid_input",
		"score": -INF,
		"forced_tactic": "",
		"error": error,
	}


static func _stable_ref(ref: EntityRef) -> Dictionary:
	if ref == null:
		return {}
	var result := {
		"kind": ref.kind,
		"player": ref.player,
	}
	if not ref.zone.is_empty():
		result["zone"] = ref.zone
	if not ref.slot.is_empty():
		result["slot"] = ref.slot
	if not ref.attachment_type.is_empty():
		result["attachment_type"] = ref.attachment_type
	if not ref.card_id.is_empty():
		result["card_id"] = ref.card_id
	# Physical indices are intentionally omitted so an intent survives hand and
	# attachment reindexing at the next state revision.
	return result


static func _intent_signature(intent: Dictionary) -> String:
	var stable := {
		"kind": str(intent.get("kind", "")),
		"actor": int(intent.get("actor", -1)),
		"source": Dictionary(intent.get("source", {})),
		"target": Dictionary(intent.get("target", {})),
		"payload": Dictionary(intent.get("payload", {})),
	}
	var wire := _stable_variant_signature(stable)
	return "intent:%08x%08x" % [wire.hash(), wire.reverse().hash()]


static func _stable_variant_signature(value: Variant) -> String:
	if value is Dictionary:
		var dictionary: Dictionary = value
		var keys: Array[String] = []
		for key_value in dictionary:
			keys.append(str(key_value))
		keys.sort()
		var parts: Array[String] = []
		for key in keys:
			parts.append("%s:%s" % [
				JSON.stringify(key), _stable_variant_signature(dictionary[key]),
			])
		return "{%s}" % ",".join(parts)
	if value is Array:
		var parts: Array[String] = []
		for nested in value:
			parts.append(_stable_variant_signature(nested))
		return "[%s]" % ",".join(parts)
	return JSON.stringify(value)


static func _intent_fields_match(expected: Dictionary, candidate: Dictionary) -> bool:
	if str(expected.get("kind", "")) != str(candidate.get("kind", "")):
		return false
	if expected.has("actor") and int(expected["actor"]) != int(candidate.get("actor", -1)):
		return false
	for field in ["source", "target", "payload"]:
		if expected.has(field) and _stable_variant_signature(expected[field]) != _stable_variant_signature(
			candidate.get(field, {})):
			return false
	return true


static func _semantic_intent(kind: String) -> String:
	match kind:
		"PLAY_BASIC":
			return "develop_board"
		"EVOLVE":
			return "evolve"
		"ATTACH_ENERGY":
			return "attach_energy"
		"PLAY_TRAINER":
			return "play_trainer"
		"USE_ABILITY":
			return "use_ability"
		"USE_STADIUM":
			return "use_stadium"
		"RETREAT":
			return "retreat"
		"DECLARE_ATTACK":
			return "attack"
		"PROMOTE":
			return "promote"
		"SETUP_DONE":
			return "finish_setup"
		"END_TURN":
			return "end_turn"
		_:
			return "action"
