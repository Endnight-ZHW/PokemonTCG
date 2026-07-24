class_name TraditionalTurnPlanner
extends RefCounted

## Stable integration facade for the fixed-work traditional AI v2.
##
## Request metadata can select a seed and a 1/3 belief count, but cannot change
## the production search depth, branch width or introduce a wall-clock limit.

const ENGINE_ID := "turn_beam_v2"
const SEARCH_DEPTH := 8
const MANDATORY_TACTIC_NODE_GUARD := 4096


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
	reuse_sample_zero: bool = true,
) -> Dictionary:
	if information_set == null or not information_set.is_valid():
		return _failure(
			information_set.validation_error()
			if information_set != null
			else "null_information_set"
		)
	if actions.is_empty():
		return _failure("no_legal_actions")
	var config := _planner_config_from_request(request)
	var requested_depth := int(config.get("max_depth", SEARCH_DEPTH))
	var safe_catalog := catalog if catalog != null else CardCatalog.shared()
	var safe_engine := engine if engine != null else GameEngine.new(safe_catalog)
	var seed := int(config.get("seed", 1))
	var actor := information_set.perspective_player()
	var tactical_state := information_set.sample_state(seed)
	if tactical_state == null:
		return _failure("determinization_failed")
	tactical_state.set_type_matchups_enabled(false)
	var legal_actions := _validated_legal_actions(
		tactical_state, actor, actions, safe_engine, information_set)
	if legal_actions.is_empty():
		return _failure("no_authoritative_legal_action")
	var root_precondition := information_set.cache_precondition()
	var nodes_used := 0
	if not bool(config.get("skip_mandatory", false)):
		var forced := AIMandatoryTactics.new().resolve(
			information_set,
			tactical_state,
			actor,
			legal_actions,
			safe_engine,
			strategy,
			seed,
			cancel_check,
			0,
			MANDATORY_TACTIC_NODE_GUARD,
			trusted_choice_resolver,
			trusted_action_evaluator,
		)
		nodes_used += maxi(0, int(forced.get("nodes_expanded", 0)))
		if bool(forced.get("resolved", false)):
			var forced_action: GameAction = forced.get("action")
			var result := _success_result(
				forced_action,
				[forced_action],
				0,
				nodes_used,
				"forced_tactic",
				str(forced.get("reason", "mandatory")),
				[_plan_step(forced_action, root_precondition)],
			)
			result["search_depth_applicable"] = false
			result["completion_reason"] = "forced_tactic"
			result["trajectory_hash"] = (
				"forced_tactic|%s" % AIPositionEvaluator.action_signature(
					forced_action)).sha256_text()
			return result
	if _is_cancelled(cancel_check):
		return _cancelled(nodes_used)

	var configured_samples := int(config.get("belief_samples", 0))
	var belief_samples := (
		clampi(configured_samples, 1, 3)
		if configured_samples > 0
		else recommended_belief_samples(
			legal_actions,
			CardSemanticCatalog.new(safe_catalog),
			information_set,
		)
	)
	# Select the bounded root set once, then evaluate every retained root on
	# every identical belief seed.  Re-ranking roots independently inside each
	# determinization would give some actions more samples than others.
	var semantic_catalog := CardSemanticCatalog.new(safe_catalog)
	var ranked_roots := AIPositionEvaluator.ranked_actions(
		tactical_state,
		actor,
		legal_actions,
		strategy,
		semantic_catalog,
		safe_catalog,
		information_set.match_seed(),
		cancel_check,
		trusted_action_evaluator,
	)
	var fixed_roots := AIPositionEvaluator.diverse_top_actions(
		ranked_roots, int(config.get(
			"root_actions", AITurnBeamPlanner.DEFAULT_ROOT_ACTIONS)))
	var fixed_root_signatures: Array[String] = []
	for root_value in fixed_roots:
		var root: Dictionary = root_value
		var signature := str(root.get("signature", ""))
		if not signature.is_empty():
			fixed_root_signatures.append(signature)
	if fixed_root_signatures.is_empty():
		return _failure("no_ranked_root_action")
	config["fixed_root_signatures"] = fixed_root_signatures
	var planner := AITurnBeamPlanner.new()
	var aggregate: Dictionary = {}
	var attempted_samples := 0
	var completed_depth := requested_depth
	var max_path_depth := 0
	var reply_completed_depth := int(config.get(
		"reply_depth", AITurnBeamPlanner.DEFAULT_REPLY_DEPTH))
	var reply_depth_applicable := false
	var reply_completion_reasons: Dictionary = {}
	var layers_completed := requested_depth
	var completion_reasons: Dictionary = {}
	var belief_seeds: Array[int] = []
	var trajectory_hash := "traditional_turn_planner:v2:trajectory:v1".sha256_text()
	for sample_index in range(belief_samples):
		if _is_cancelled(cancel_check):
			return _cancelled(nodes_used)
		var sample_config := config.duplicate(true)
		sample_config["seed"] = seed + sample_index * 1000003
		belief_seeds.append(int(sample_config["seed"]))
		var precomputed_sample_zero := {}
		if reuse_sample_zero and sample_index == 0:
			precomputed_sample_zero = {
				"seed": seed,
				"actor": actor,
				"state_revision": tactical_state.revision,
				"catalog_source_id": int(safe_catalog.get_instance_id()),
				"information_binding":
					AITurnBeamPlanner._information_binding(root_precondition),
				"match_seed": information_set.match_seed(),
				"root_actions_binding":
					AITurnBeamPlanner._root_actions_binding(legal_actions),
				"strategy_binding":
					AITurnBeamPlanner._variant_binding(strategy),
				"trusted_action_evaluator_binding":
					AITurnBeamPlanner._variant_binding(
						trusted_action_evaluator),
				"ranked_roots_binding":
					AITurnBeamPlanner._ranked_roots_binding(ranked_roots),
				"root_state": tactical_state,
				"ranked_roots": ranked_roots,
			}
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
			precomputed_sample_zero,
		)
		nodes_used += maxi(0, int(planned.get("nodes_expanded", 0)))
		trajectory_hash = ("%s|sample=%d|seed=%d|trace=%s|nodes=%d|reason=%s" % [
			trajectory_hash,
			sample_index,
			int(sample_config["seed"]),
			str(planned.get("trajectory_hash", "")),
			int(planned.get("nodes_expanded", 0)),
			str(planned.get("completion_reason", "")),
		]).sha256_text()
		if bool(planned.get("cancelled", false)) or _is_cancelled(cancel_check):
			return _cancelled(nodes_used)
		if not bool(planned.get("success", false)):
			return _fallback_result(
				tactical_state,
				actor,
				legal_actions,
				information_set,
				strategy,
				safe_catalog,
				trusted_action_evaluator,
				nodes_used,
				str(planned.get("error", "planner_failed")),
				root_precondition,
			)
		attempted_samples += 1
		completed_depth = mini(
			completed_depth, int(planned.get("completed_depth", 0)))
		max_path_depth = maxi(
			max_path_depth, int(planned.get("max_path_depth", 0)))
		if bool(planned.get("reply_depth_applicable", false)):
			reply_depth_applicable = true
			reply_completed_depth = mini(
				reply_completed_depth,
				int(planned.get("reply_completed_depth", 0)),
			)
			for reply_reason_value in planned.get(
				"reply_completion_reasons", []):
				reply_completion_reasons[str(reply_reason_value)] = true
		layers_completed = mini(
			layers_completed, int(planned.get("layers_completed", 0)))
		var reason := str(planned.get("completion_reason", "error"))
		completion_reasons[reason] = true
		for root_value in planned.get("root_plans", []):
			if not root_value is Dictionary:
				continue
			var root: Dictionary = root_value
			var root_action: GameAction = root.get("action")
			if root_action == null:
				continue
			var signature := str(root.get(
				"root_signature", action_intent(root_action).get("signature", "")))
			var score_milli := int(root.get("score_milli", 0))
			var row: Dictionary = aggregate.get(signature, {
				"count": 0,
				"score_total_milli": 0,
				"worst_score_milli": AIPositionEvaluator.WIN_SCORE_MILLI,
				"representative": {},
				"signature": signature,
			})
			row["count"] = int(row["count"]) + 1
			row["score_total_milli"] = int(row["score_total_milli"]) + score_milli
			row["worst_score_milli"] = mini(
				int(row["worst_score_milli"]), score_milli)
			if Dictionary(row.get("representative", {})).is_empty():
				row["representative"] = root
			aggregate[signature] = row
	if attempted_samples != belief_samples:
		return _failure("incomplete_belief_search")
	var eligible: Array[Dictionary] = []
	for row_value in aggregate.values():
		var row: Dictionary = row_value
		if int(row.get("count", 0)) == belief_samples:
			eligible.append(row)
	if eligible.is_empty():
		return _fallback_result(
			tactical_state,
			actor,
			legal_actions,
			information_set,
			strategy,
			safe_catalog,
			trusted_action_evaluator,
			nodes_used,
			"no_root_compared_across_all_beliefs",
			root_precondition,
		)
	eligible.sort_custom(_belief_row_descending)
	var selected_row: Dictionary = eligible[0]
	var selected_plan: Dictionary = selected_row.get("representative", {})
	var selected_action: GameAction = selected_plan.get("action")
	var sequence: Array[GameAction] = []
	sequence.assign(selected_plan.get("sequence", []))
	var plan_steps := _plan_steps_from_preconditions(
		sequence, Array(selected_plan.get("cache_preconditions", [])))
	var score_milli := roundi(
		float(selected_row.get("score_total_milli", 0))
		/ float(maxi(1, belief_samples))
	)
	var completion_reason := (
		"depth_complete"
		if completion_reasons.size() == 1 and completion_reasons.has("depth_complete")
		else "frontier_exhausted"
	)
	if not reply_depth_applicable:
		reply_completed_depth = 0
	var reply_completion_reason := "not_applicable"
	if reply_depth_applicable:
		reply_completion_reason = (
			"depth_complete"
			if (
				reply_completion_reasons.size() == 1
				and reply_completion_reasons.has("depth_complete")
			)
			else "frontier_exhausted"
		)
	var result := _success_result(
		selected_action,
		sequence,
		score_milli,
		nodes_used,
		completion_reason,
		"",
		plan_steps,
	)
	result["belief_samples"] = belief_samples
	result["belief_consensus"] = belief_samples
	var root_sample_counts: Dictionary = {}
	for signature_value in fixed_root_signatures:
		var row: Dictionary = aggregate.get(signature_value, {})
		root_sample_counts[signature_value] = int(row.get("count", 0))
	result["root_signatures_attempted"] = fixed_root_signatures.duplicate()
	result["root_sample_counts"] = root_sample_counts
	result["belief_seed_hash"] = AIPositionEvaluator.stable_variant_signature(
		belief_seeds).sha256_text()
	result["trajectory_hash"] = trajectory_hash
	result["opponent_strategy_id"] = str(selected_plan.get(
		"opponent_strategy_id", ""))
	result["search_depth_applicable"] = true
	result["requested_depth"] = requested_depth
	result["completed_depth"] = completed_depth
	result["max_path_depth"] = max_path_depth
	result["reply_completed_depth"] = reply_completed_depth
	result["reply_depth_applicable"] = reply_depth_applicable
	result["reply_requested_depth"] = int(config.get(
		"reply_depth", AITurnBeamPlanner.DEFAULT_REPLY_DEPTH))
	result["reply_completion_reason"] = reply_completion_reason
	result["layers_completed"] = layers_completed
	result["completion_reason"] = completion_reason
	result["search_depth_requested"] = requested_depth
	result["search_depth_reached"] = max_path_depth
	result["search_depth_completed"] = completed_depth
	result["search_depth_stop_reason"] = completion_reason
	return result


static func recommended_belief_samples(
	actions: Array[GameAction],
	semantic_catalog: CardSemanticCatalog,
	information_set: AIInformationSet = null,
) -> int:
	if semantic_catalog == null:
		return 3
	if information_set != null and information_set.is_valid():
		for player_idx in [0, 1]:
			var counts := information_set.hidden_zone_counts(player_idx)
			if (
				int(counts.get("hand", 0)) > 0
				or int(counts.get("deck", 0)) > 0
				or int(counts.get("prizes", 0)) > 0
			):
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
				if CardSemanticCatalog.commands_require_belief_sampling(
					semantic_catalog.semantics_for(card_id).get(
						"trainer_commands", [])):
					return 3
			"USE_ABILITY":
				var ability_name := str(action.payload.get("ability_name", ""))
				if not ability_name.is_empty():
					if CardSemanticCatalog.commands_require_belief_sampling(
						semantic_catalog.ability_semantics(
							card_id, ability_name).get("commands", [])):
						return 3
				else:
					for ability_value in semantic_catalog.semantics_for(
						card_id).get("abilities", []):
						if (
							ability_value is Dictionary
							and CardSemanticCatalog.commands_require_belief_sampling(
								Dictionary(ability_value).get("commands", []))
						):
							return 3
	return 1


static func action_intent(
	action: GameAction,
	_state: Variant = null,
) -> Dictionary:
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
		if _intent_fields_match(intent, action_intent(action)):
			return action
	return null


static func _planner_config_from_request(request: Dictionary) -> Dictionary:
	var result := {
		"root_actions": AITurnBeamPlanner.DEFAULT_ROOT_ACTIONS,
		"per_root_beam_width": AITurnBeamPlanner.DEFAULT_PER_ROOT_BEAM_WIDTH,
		"max_actions_per_node": AITurnBeamPlanner.DEFAULT_MAX_ACTIONS_PER_NODE,
		"max_depth": SEARCH_DEPTH,
		"reply_depth": AITurnBeamPlanner.DEFAULT_REPLY_DEPTH,
		"reply_beam_width": AITurnBeamPlanner.DEFAULT_REPLY_BEAM_WIDTH,
		"reply_actions_per_node": AITurnBeamPlanner.DEFAULT_REPLY_ACTIONS_PER_NODE,
		"belief_samples": 0,
		"skip_mandatory": false,
		"seed": 1,
	}
	if request.get("seed") is int or request.get("seed") is float:
		result["seed"] = int(request["seed"])
	if request.get("belief_samples") is int or request.get("belief_samples") is float:
		result["belief_samples"] = clampi(int(request["belief_samples"]), 1, 3)
	if request.get("skip_mandatory") is bool:
		result["skip_mandatory"] = bool(request["skip_mandatory"])
	# A private legality-smoke profile keeps the broad regression suite quick.
	# The release client never sends this flag and cannot alter the production
	# depth/width profile.
	if bool(request.get("internal_evaluation_smoke", false)):
		result["root_actions"] = 2
		result["per_root_beam_width"] = 1
		result["max_actions_per_node"] = 2
		result["max_depth"] = 1
		result["reply_depth"] = 1
		result["reply_beam_width"] = 2
		result["reply_actions_per_node"] = 2
		if int(result.get("belief_samples", 0)) <= 0:
			result["belief_samples"] = 1
	return result


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
		var matched := find_matching_action(
			action_intent(supplied_action), authoritative, information_set)
		if matched == null:
			continue
		var signature := str(action_intent(matched).get("signature", ""))
		if used.has(signature):
			continue
		used[signature] = true
		result.append(matched)
	return result


static func _fallback_result(
	state: GameState,
	actor: int,
	legal_actions: Array[GameAction],
	information_set: AIInformationSet,
	strategy: Variant,
	catalog: CardCatalog,
	trusted_action_evaluator: Callable,
	nodes_used: int,
	error: String,
	root_precondition: Dictionary,
) -> Dictionary:
	var fallback := AIMandatoryTactics.survival_backup_action(
		state,
		actor,
		legal_actions,
		information_set,
		strategy,
		catalog,
		trusted_action_evaluator,
	)
	if fallback == null and not legal_actions.is_empty():
		var ranked := AIPositionEvaluator.ranked_actions(
			state,
			actor,
			legal_actions,
			strategy,
			CardSemanticCatalog.new(catalog),
			catalog,
			information_set.match_seed(),
			Callable(),
			trusted_action_evaluator,
		)
		if not ranked.is_empty():
			fallback = ranked[0].get("action")
	var result := _success_result(
		fallback,
		[fallback],
		-AIPositionEvaluator.WIN_SCORE_MILLI,
		nodes_used,
		"error",
		"survival_backup",
		[_plan_step(fallback, root_precondition)],
	)
	result["error"] = error
	# The production runtime may still return a legal tactical fallback, but an
	# evaluation must retain the failed search as applicable evidence so the
	# fixed-depth gate fails closed.
	result["search_depth_applicable"] = true
	result["search_depth_requested"] = SEARCH_DEPTH
	result["search_depth_reached"] = 0
	result["search_depth_completed"] = 0
	result["search_depth_stop_reason"] = "error"
	result["completion_reason"] = "error"
	result["trajectory_hash"] = (
		"fallback|%s|%s" % [
			error,
			AIPositionEvaluator.action_signature(fallback),
		]).sha256_text()
	return result


static func _plan_step(
	action: GameAction,
	precondition: Dictionary,
) -> Dictionary:
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


static func _success_result(
	action: GameAction,
	sequence: Array[GameAction],
	score_milli: int,
	nodes_expanded: int,
	completion_reason: String,
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
		"engine_id": ENGINE_ID,
		"action": action,
		"action_dict": action.to_dict() if action != null else {},
		"turn_plan": plan,
		"nodes_expanded": nodes_expanded,
		"trajectory_hash": "",
		"score_milli": score_milli,
		"score": float(score_milli) / float(AIPositionEvaluator.SCORE_SCALE),
		"forced_tactic": forced_tactic,
		"requested_depth": SEARCH_DEPTH,
		"completed_depth": 0,
		"max_path_depth": 0,
		"reply_completed_depth": 0,
		"layers_completed": 0,
		"completion_reason": completion_reason,
		"stop_reason": completion_reason,
		"error": "",
	}


static func _failure(error: String) -> Dictionary:
	return {
		"success": false,
		"engine_id": ENGINE_ID,
		"action": null,
		"action_dict": {},
		"turn_plan": [],
		"nodes_expanded": 0,
		"trajectory_hash": "",
		"score_milli": -AIPositionEvaluator.WIN_SCORE_MILLI,
		"score": -INF,
		"forced_tactic": "",
		"requested_depth": SEARCH_DEPTH,
		"completed_depth": 0,
		"max_path_depth": 0,
		"reply_completed_depth": 0,
		"layers_completed": 0,
		"completion_reason": "error",
		"stop_reason": "error",
		"error": error,
	}


static func _cancelled(nodes_expanded: int) -> Dictionary:
	var result := _failure("cancelled")
	result["nodes_expanded"] = nodes_expanded
	result["cancelled"] = true
	result["completion_reason"] = "cancelled"
	result["stop_reason"] = "cancelled"
	return result


static func _belief_row_descending(
	left: Dictionary,
	right: Dictionary,
) -> bool:
	var left_count := maxi(1, int(left.get("count", 0)))
	var right_count := maxi(1, int(right.get("count", 0)))
	var left_total := int(left.get("score_total_milli", 0))
	var right_total := int(right.get("score_total_milli", 0))
	var left_scaled := left_total * right_count
	var right_scaled := right_total * left_count
	if left_scaled != right_scaled:
		return left_scaled > right_scaled
	var left_worst := int(left.get(
		"worst_score_milli", -AIPositionEvaluator.WIN_SCORE_MILLI))
	var right_worst := int(right.get(
		"worst_score_milli", -AIPositionEvaluator.WIN_SCORE_MILLI))
	if left_worst != right_worst:
		return left_worst > right_worst
	return str(left.get("signature", "")) < str(right.get("signature", ""))


static func _stable_ref(ref: EntityRef) -> Dictionary:
	if ref == null:
		return {}
	var result := {"kind": ref.kind, "player": ref.player}
	if not ref.zone.is_empty():
		result["zone"] = ref.zone
	if not ref.slot.is_empty():
		result["slot"] = ref.slot
	if not ref.attachment_type.is_empty():
		result["attachment_type"] = ref.attachment_type
	if not ref.card_id.is_empty():
		result["card_id"] = ref.card_id
	return result


static func _intent_signature(intent: Dictionary) -> String:
	var stable := {
		"kind": str(intent.get("kind", "")),
		"actor": int(intent.get("actor", -1)),
		"source": Dictionary(intent.get("source", {})),
		"target": Dictionary(intent.get("target", {})),
		"payload": Dictionary(intent.get("payload", {})),
	}
	var wire := AIPositionEvaluator.stable_variant_signature(stable)
	return "intent:%s" % wire.sha256_text()


static func _intent_fields_match(
	expected: Dictionary,
	candidate: Dictionary,
) -> bool:
	if str(expected.get("kind", "")) != str(candidate.get("kind", "")):
		return false
	if expected.has("actor") and int(expected["actor"]) != int(
		candidate.get("actor", -1)):
		return false
	for field in ["source", "target", "payload"]:
		if (
			expected.has(field)
			and AIPositionEvaluator.stable_variant_signature(expected[field])
			!= AIPositionEvaluator.stable_variant_signature(
				candidate.get(field, {}))
		):
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


static func _is_cancelled(cancel_check: Callable) -> bool:
	return cancel_check.is_valid() and bool(cancel_check.call())
