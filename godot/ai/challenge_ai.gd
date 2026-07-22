class_name NativeChallengeAI
extends RefCounted

const STRONGEST_DIFFICULTY := "strongest"
const HEURISTIC_VARIANT_SEMANTIC_V2 := "semantic_v2"
const DEFAULT_HEURISTIC_VARIANT := HEURISTIC_VARIANT_SEMANTIC_V2
## Compatibility names retained for callers on the Actions 4 boundary.  In the
## traditional planner a "simulation" is one expanded beam node.
const DEEP_DEFAULT_SIMULATIONS := 192
const DEEP_FALLBACK_SIMULATIONS := 192
const DEEP_DEFAULT_SECONDS := 0.85
const DEEP_DEFAULT_DEPTH := 6
const GAMEPLAY_DEFAULT_SIMULATIONS := 192
const GAMEPLAY_DEFAULT_SECONDS := 0.85
const GAMEPLAY_DEFAULT_DEPTH := 6
const GAMEPLAY_LOW_SIMULATIONS := 1
const GAMEPLAY_LOW_SECONDS := 0.12
const GAMEPLAY_LOW_DEPTH := 1
const TRADITIONAL_HARD_DEADLINE_MSEC := 1100
const TURN_REPLAN_FULL_LIMIT := 1
const TURN_REPLAN_LOCAL_LIMIT := 5
const TURN_REPLAN_LOCAL_NODES := 24
const TURN_REPLAN_LOCAL_DEPTH := 2
const TURN_REPLAN_LOCAL_SOFT_MSEC := 45
const TURN_REPLAN_LOCAL_HARD_MSEC := 60
const TURN_REPLAN_EXHAUSTED_SOFT_MSEC := 50
const TURN_REPLAN_LEDGER_LIMIT := 16
## The turn planner reasons over at most six atomic actions.  A repeatable
## ability may otherwise be selected again after every local replan and bounce
## resources forever, so carry the same bound across the authoritative turn.
const MAX_REPEATABLE_ABILITY_USES_PER_TURN := 6
const CACHE_GUARDED_ABILITY_EFFECT_TYPES := {
	"damage_counter_self": true,
	"place_counters_and_self_ko": true,
}
const DIFFICULTIES := {
	"strongest": {"simulations": 192, "seconds": 0.85, "depth": 6},
	# Compatibility aliases for older saves/tests that still send a difficulty.
	"fast": {"simulations": 192, "seconds": 0.85, "depth": 6},
	"standard": {"simulations": 192, "seconds": 0.85, "depth": 6},
	"hard": {"simulations": 192, "seconds": 0.85, "depth": 6},
}
const DIAGNOSTIC_LABELS := [
	"missed_immediate_ko",
	"ended_with_productive_attack",
	"ended_with_productive_development",
	"weak_attack_before_development",
	"retreat_without_good_target",
	"trainer_first_choice_cancelled",
	"unsafe_draw_pressure_attack",
	"unsafe_retaliation_attack",
]
const DYNAMIC_BUDGET_DEFAULTS := {
	"enabled": false,
	"min_simulations": 128,
	"ambiguous_min_simulations": 512,
	"check_interval": 32,
	"stable_checks": 3,
	"ambiguous_stable_checks": 5,
	"min_mean_gap": 0.10,
	"ambiguous_mean_gap": 0.14,
	"min_best_visits": 32,
	"min_best_visit_share": 0.35,
	"clear_prior_gap": 0.25,
	"max_root_actions_for_clear": 10,
	"single_action_simulations": 0,
}
const GAMEPLAY_DYNAMIC_BUDGET := {
	"enabled": true,
	"min_simulations": 32,
	"ambiguous_min_simulations": 64,
	"check_interval": 16,
	"stable_checks": 2,
	"ambiguous_stable_checks": 3,
	"min_mean_gap": 0.10,
	"ambiguous_mean_gap": 0.14,
	"min_best_visits": 8,
	"min_best_visit_share": 0.30,
	"clear_prior_gap": 0.25,
	"max_root_actions_for_clear": 10,
	"single_action_simulations": 0,
}
const SCORE_WEIGHTS := {
	"prize_race": 42.0,
	"ready_attacker": 58.0,
	"backup_attacker": 34.0,
	"active_ko_risk": 170.0,
	"active_damage_pressure": 62.0,
	"resource_out": 32.0,
	"status_lock": 118.0,
	"protection": 126.0,
	"deck_danger": 135.0,
	"hand_size_plan": 92.0,
	"discard_fuel": 76.0,
	"evolution_line_plan": 86.0,
	"thin_deck_draw": 96.0,
	"lone_active_backup": 300.0,
	"last_useful_energy": 230.0,
}
const EFFECT_VALUE_WEIGHTS := {
	"draw_card": 27.0,
	"search_base": 84.0,
	"energy_accel_base": 112.0,
	"switch_base": 72.0,
	"disruption_base": 65.0,
	"protection_base": 76.0,
	"status_base": 58.0,
}
const SEMANTIC_CHOICE_LOOKAHEAD_MAX_OPTIONS := 8
const MODIFY_DAMAGE_HOOK := "MODIFY_DAMAGE"
const CHOICE_VIEW_FIELDS := [
	"schema_version",
	"request_id",
	"base_revision",
	"player",
	"request_type",
	"prompt",
	"options",
	"min_select",
	"max_select",
	"allow_duplicates",
	"can_cancel",
	"presentation",
]

var _catalog_cache: CardCatalog = null
var _engine_cache: GameEngine = null
var _native_math: Variant = null
var _native_math_checked := false
var _disable_native_math := false
var _pre_evolution_ids_cache: Dictionary = {}
var _core_evolution_line_cache: Dictionary = {}
var _traditional_semantic_catalog: Variant = null
var _traditional_strategy_registry: Variant = null
## Cache semantic intents, never GameAction instances or mutable GameState.
## Entries are keyed by match/actor/turn/deck and revalidated against the
## authoritative legal action list on every atomic decision.
var _turn_plan_cache: Dictionary = {}
## A cache invalidation must not grant another full search in the same turn.
## Each entry is scoped by an explicit match instance and advances only when a
## cache miss actually needs a new plan.  Repeating the same revision reuses the
## reservation, which makes coordinator timeout/cancellation retries idempotent.
var _turn_replan_ledger: Dictionary = {}


static func strongest_preset() -> Dictionary:
	return Dictionary(DIFFICULTIES[STRONGEST_DIFFICULTY]).duplicate(true)


static func gameplay_dynamic_budget() -> Dictionary:
	return GAMEPLAY_DYNAMIC_BUDGET.duplicate(true)


static func gameplay_action_budget(
	state: GameState,
	actions: Array[GameAction],
) -> Dictionary:
	var params := {
		"simulation_budget": GAMEPLAY_DEFAULT_SIMULATIONS,
		"seconds": GAMEPLAY_DEFAULT_SECONDS,
		"max_depth": GAMEPLAY_DEFAULT_DEPTH,
		"dynamic_budget": gameplay_dynamic_budget(),
	}
	if state == null:
		return params
	if (
		actions.size() > 1
		and (
			state.phase == "SETUP"
			or state.phase == "ATTACK"
			or not state.pending_promotions.is_empty()
		)
	):
		params["simulation_budget"] = GAMEPLAY_LOW_SIMULATIONS
		params["seconds"] = GAMEPLAY_LOW_SECONDS
		params["max_depth"] = GAMEPLAY_LOW_DEPTH
	return params


static func diagnostic_labels() -> Array:
	return DIAGNOSTIC_LABELS.duplicate()


static func heuristic_variants() -> Array[String]:
	return [HEURISTIC_VARIANT_SEMANTIC_V2]


func _semantic_v2_enabled() -> bool:
	return true


func _cached_catalog() -> CardCatalog:
	if _catalog_cache == null:
		_catalog_cache = CardCatalog.shared()
	return _catalog_cache


func _cached_engine(catalog: CardCatalog) -> GameEngine:
	if _engine_cache == null or _engine_cache.catalog != catalog:
		_engine_cache = GameEngine.new(catalog)
	return _engine_cache


func _cached_native_math() -> Variant:
	if _disable_native_math:
		return null
	if not _native_math_checked:
		_native_math_checked = true
		if ClassDB.class_exists("ChallengeAIMath"):
			_native_math = ClassDB.instantiate("ChallengeAIMath")
	return _native_math


func _new_decision_profile() -> Dictionary:
	return {
		"enabled": true,
		"segments_ms": {},
		"counts": {},
	}


func _profile_enabled(profile: Dictionary) -> bool:
	return bool(profile.get("enabled", false))


func _profile_add_ms(profile: Dictionary, key: String, elapsed_ms: float) -> void:
	if not _profile_enabled(profile):
		return
	var segments: Dictionary = profile["segments_ms"]
	segments[key] = float(segments.get(key, 0.0)) + elapsed_ms


func _profile_add_elapsed(profile: Dictionary, key: String, started_usec: int) -> void:
	if not _profile_enabled(profile):
		return
	_profile_add_ms(profile, key, float(Time.get_ticks_usec() - started_usec) / 1000.0)


func _profile_start(profile: Dictionary) -> int:
	return Time.get_ticks_usec() if _profile_enabled(profile) else 0


func _profile_count(profile: Dictionary, key: String, value: int = 1) -> void:
	if not _profile_enabled(profile):
		return
	var counts: Dictionary = profile["counts"]
	counts[key] = int(counts.get(key, 0)) + value


func _public_decision_profile(profile: Dictionary) -> Dictionary:
	if not _profile_enabled(profile):
		return {}
	var segments := {}
	for key in Dictionary(profile.get("segments_ms", {})).keys():
		segments[str(key)] = round(float(profile["segments_ms"][key]) * 1000.0) / 1000.0
	return {
		"segments_ms": segments,
		"counts": Dictionary(profile.get("counts", {})).duplicate(true),
	}


func decide(
	request: Dictionary,
	cancel_check: Callable,
	inference: Variant = null,
) -> Dictionary:
	var started := Time.get_ticks_usec()
	var profile := _new_decision_profile() if bool(request.get("profile", false)) else {}
	var previous_disable_native_math := _disable_native_math
	_disable_native_math = bool(request.get("disable_native_math", false))
	var context_started := _profile_start(profile)
	var disable_cache := bool(request.get("disable_cache", false))
	var catalog := CardCatalog.new(true) if disable_cache else _cached_catalog()
	var engine := GameEngine.new(catalog) if disable_cache else _cached_engine(catalog)
	var state := GameState.from_dict(request["state"])
	# Challenge and its disabled-Deep fallback are a fixed no-matchup ruleset.
	# Canonicalize again at the worker boundary so an internal/test caller cannot
	# accidentally re-enable global Weakness or Resistance calculations.
	state.set_type_matchups_enabled(false)
	var actor := int(request["actor"])
	_profile_add_elapsed(profile, "request_context_ms", context_started)
	var result: Dictionary
	if str(request.get("kind", "action")) == "choice":
		var choice_started := _profile_start(profile)
		var decoded := _decode_choice_view(request.get("choice"))
		if not bool(decoded.get("ok", false)):
			result = {
				"success": false,
				"kind": "choice",
				"error": str(decoded.get("error", "invalid_choice_view")),
				"simulations": 0,
			}
		else:
			result = _choose_request(
				state,
				decoded["view"],
				actor,
				str(request.get("deck_key", "")),
				catalog,
				engine,
				int(request.get("seed", 17)),
				int(request.get("match_seed", request.get("seed", 0))),
				inference,
				str(request.get("mode", "challenge")),
				cancel_check,
				started,
			)
		_profile_add_elapsed(profile, "choice_ms", choice_started)
	else:
		result = _search_action(
			request,
			state,
			actor,
			catalog,
			engine,
			cancel_check,
			inference,
			profile,
			started,
		)
	result["revision"] = int(request["revision"])
	result["request_id"] = str(request.get("request_id", ""))
	result["elapsed_ms"] = (Time.get_ticks_usec() - started) / 1000.0
	result["heuristic_variant"] = HEURISTIC_VARIANT_SEMANTIC_V2
	if _profile_enabled(profile):
		result["profile"] = _public_decision_profile(profile)
	_disable_native_math = previous_disable_native_math
	return result


func _search_action(
	request: Dictionary,
	state: GameState,
	actor: int,
	catalog: CardCatalog,
	engine: GameEngine,
	cancel_check: Callable,
	_inference: Variant,
	profile: Dictionary = {},
	decision_started_usec: int = 0,
) -> Dictionary:
	var decode_started := _profile_start(profile)
	state.set_type_matchups_enabled(false)
	var query := engine.query_legal_action_groups(state, actor)
	if not query.success:
		return {"success": false, "error": "legal_query_failed:%s" % query.code}
	var authoritative: Array[GameAction] = []
	authoritative.assign(query.concrete_actions())
	var supplied: Array[GameAction] = []
	for row in request.get("actions", []):
		if row is Dictionary:
			supplied.append(GameAction.from_dict(row))
	var actions := (
		authoritative
		if supplied.is_empty()
		else _authoritative_action_intersection(supplied, authoritative)
	)
	_profile_add_elapsed(profile, "decode_actions_ms", decode_started)
	if actions.is_empty():
		return {"success": false, "error": "no_authoritative_legal_action"}
	if cancel_check.is_valid() and bool(cancel_check.call()):
		return {"success": false, "cancelled": true, "error": "cancelled"}
	var deck_key := _deck_key_for_actor(
		state, actor, str(request.get("deck_key", "")))
	actions = _filter_exhausted_repeatable_abilities(
		state, actor, actions, catalog)
	if actions.is_empty():
		return {"success": false, "error": "no_bounded_legal_action"}
	_profile_count(profile, "root_action_count", actions.size())

	var information_set := AIInformationSet.capture(
		state,
		actor,
		catalog,
		actions,
		Array(request.get("public_history", [])),
		int(request.get("match_seed", request.get("seed", 0))),
	)
	if not information_set.is_valid():
		return {
			"success": false,
			"error": "invalid_information_set:%s" % information_set.validation_error(),
		}
	var strategy_registry: Variant = _traditional_strategy_registry_instance()
	if strategy_registry == null or not strategy_registry.is_valid():
		return {"success": false, "error": "invalid_strategy_registry"}
	var strategy: Variant = strategy_registry.strategy_for(deck_key)
	var effective_started_usec := (
		decision_started_usec if decision_started_usec > 0 else Time.get_ticks_usec())
	var cache_key := _turn_plan_cache_key(request, information_set, deck_key)
	var preview_tier := _preview_turn_replan_tier(
		cache_key, state.revision, deck_key)
	var planner_request := _bounded_traditional_planner_request(
		request, effective_started_usec, preview_tier)
	# A zero-node request is the public deterministic tactical mode used by
	# golden fixtures and emergency callers. It does not run the retired UCB
	# search; it applies the proven rule-tactics scorer to a fair sampled state.
	if request.has("simulation_budget") and int(request["simulation_budget"]) <= 0:
		var tactical_state := information_set.sample_state(int(request.get("seed", 17)))
		if tactical_state == null:
			return {"success": false, "error": "tactical_determinization_failed"}
		var tactical_action := _zero_budget_tactical_action(
			tactical_state,
			actor,
			actions,
			deck_key,
			catalog,
			engine,
			int(request.get("seed", 17)),
			profile,
		)
		return _traditional_action_result(
			request,
			tactical_action,
			strategy,
			information_set,
			0,
			"forced_tactics",
			false,
			{
				"score": _action_score(
					tactical_state, actor, tactical_action, deck_key, catalog),
				"forced_tactic": "deterministic_rule_tactics",
				"turn_plan": [TraditionalTurnPlanner.action_intent(tactical_action)],
				"turn_budget_tier": "tactical",
				"turn_replan_ordinal": 0,
			},
		)
	# Mandatory tactics always run before a cache lookup. A stale but still legal
	# development intent must never hide a newly available immediate match win.
	var trusted_choice_resolver := Callable(
		self, "_traditional_simulated_choice_response").bind(
			actor, deck_key, strategy, catalog)
	var trusted_action_evaluator := Callable(
		self, "_traditional_action_candidate_score").bind(deck_key, catalog)
	var preflight_state := information_set.sample_state(int(planner_request["seed"]))
	var preflight := {"resolved": false, "nodes_expanded": 0, "reason": "invalid_input"}
	if preflight_state != null:
		preflight = AIMandatoryTactics.new().resolve(
			information_set,
			preflight_state,
			actor,
			actions,
			engine,
			strategy,
			int(planner_request["seed"]),
			cancel_check,
			int(planner_request["soft_deadline_usec"]),
			int(planner_request["node_budget"]),
			trusted_choice_resolver,
			trusted_action_evaluator,
		)
	var preflight_nodes := mini(
		int(planner_request["node_budget"]),
		maxi(0, int(preflight.get("nodes_expanded", 0))),
	)
	if bool(preflight.get("resolved", false)):
		var forced_action: GameAction = preflight.get("action")
		return _traditional_action_result(
			request,
			forced_action,
			strategy,
			information_set,
			preflight_nodes,
			str(preflight.get("reason", "mandatory")),
			false,
			{
				"forced_tactic": str(preflight.get("reason", "mandatory")),
				"turn_plan": [_intent_with_precondition(
					forced_action, information_set.cache_precondition())],
				"turn_budget_tier": "mandatory",
				"turn_replan_ordinal": 0,
			},
		)
	if cancel_check.is_valid() and bool(cancel_check.call()):
		return {"success": false, "cancelled": true, "error": "cancelled"}
	var cached_action := _take_cached_turn_action(
		cache_key, state.revision, actions, information_set)
	if cached_action != null:
		_profile_count(profile, "turn_plan_cache_hits")
		var validated_cached := cached_action
		# Turn-ending, board-position and irreversible self-cost actions need the
		# comparatively expensive tactical pass.  A cached self-damage/self-KO
		# ability can become losing after an intervening choice or public effect
		# even when its structural cache precondition still matches.
		if (
			preflight_state != null
			and _cached_action_needs_tactical_guard(
				preflight_state, actor, cached_action, catalog)
		):
			validated_cached = _validated_or_fallback_action(
				preflight_state,
				actor,
				cached_action,
				actions,
				deck_key,
				catalog,
				engine,
				int(planner_request["seed"]) + 700001,
				profile,
			)
		var cached_signature := str(TraditionalTurnPlanner.action_intent(
			cached_action).get("signature", ""))
		var validated_signature := str(TraditionalTurnPlanner.action_intent(
			validated_cached).get("signature", ""))
		if validated_cached != null and validated_signature != cached_signature:
			# Consuming one cached intent before validation is harmless only while
			# the plan remains tactically sound.  Once the guard changes the action,
			# every remaining intent was derived from a branch we no longer follow.
			_turn_plan_cache.erase(cache_key)
			return _traditional_action_result(
				request,
				validated_cached,
				strategy,
				information_set,
				preflight_nodes,
				"plan_cache_guard",
				true,
				{
					"forced_tactic": "post_plan_tactical_guard",
					"turn_plan": [_intent_with_precondition(
						validated_cached, information_set.cache_precondition())],
					"turn_budget_tier": "cache",
					"turn_replan_ordinal": 0,
				},
			)
		return _traditional_action_result(
			request,
			cached_action,
			strategy,
			information_set,
			preflight_nodes,
			"plan_cache",
			true,
			{
				"turn_budget_tier": "cache",
				"turn_replan_ordinal": 0,
			},
		)
	if not cache_key.is_empty():
		_profile_count(profile, "turn_plan_cache_misses")

	var reserved_tier := _reserve_turn_replan_tier(
		cache_key,
		state.revision,
		str(request.get("request_id", "")),
		deck_key,
	)
	planner_request = _bounded_traditional_planner_request(
		request, effective_started_usec, reserved_tier)
	if str(reserved_tier.get("tier", "full")) == "exhausted":
		var exhausted_state := (
			preflight_state
			if preflight_state != null
			else information_set.sample_state(int(planner_request["seed"]))
		)
		if exhausted_state == null:
			return {"success": false, "error": "exhausted_determinization_failed"}
		var exhausted_action := _exhausted_turn_action(
			exhausted_state,
			actor,
			actions,
			deck_key,
			catalog,
			engine,
			int(planner_request["seed"]) + 900001,
			profile,
		)
		_turn_plan_cache.erase(cache_key)
		return _traditional_action_result(
			request,
			exhausted_action,
			strategy,
			information_set,
			preflight_nodes,
			"turn_budget_exhausted",
			false,
			{
				"forced_tactic": "turn_budget_terminal",
				"turn_plan": [_intent_with_precondition(
					exhausted_action, information_set.cache_precondition())],
				"turn_budget_tier": "exhausted",
				"turn_replan_ordinal": int(reserved_tier.get("ordinal", 0)),
			},
		)
	planner_request["initial_nodes_used"] = mini(
		int(planner_request["node_budget"]), preflight_nodes)
	planner_request["skip_mandatory"] = true
	var plan_started := _profile_start(profile)
	var planned := TraditionalTurnPlanner.plan_action(
		planner_request,
		information_set,
		actions,
		strategy,
		catalog,
		engine,
		cancel_check,
		Callable(self, "_traditional_leaf_score"),
		trusted_choice_resolver,
		trusted_action_evaluator,
	)
	planned["turn_budget_tier"] = str(reserved_tier.get("tier", "full"))
	planned["turn_replan_ordinal"] = int(reserved_tier.get("ordinal", 1))
	_profile_add_elapsed(profile, "turn_planner_ms", plan_started)
	if cancel_check.is_valid() and bool(cancel_check.call()):
		return {"success": false, "cancelled": true, "error": "cancelled"}
	if not bool(planned.get("success", false)):
		return {
			"success": false,
			"error": str(planned.get("error", "turn_planner_failed")),
			"simulations": int(planned.get("nodes_expanded", 0)),
		}
	var selected: GameAction = planned.get("action")
	if selected == null:
		return {"success": false, "error": "turn_planner_returned_no_action"}
	var validated_selected: GameAction = selected
	if preflight_state != null:
		validated_selected = _validated_or_fallback_action(
			preflight_state,
			actor,
			selected,
			actions,
			deck_key,
			catalog,
			engine,
			int(planner_request["seed"]) + 700001,
			profile,
		)
	if (
		validated_selected != null
		and str(TraditionalTurnPlanner.action_intent(
			validated_selected).get("signature", ""))
		!= str(TraditionalTurnPlanner.action_intent(selected).get("signature", ""))
	):
		selected = validated_selected
		planned["action"] = selected
		planned["action_dict"] = selected.to_dict()
		planned["turn_plan"] = [_intent_with_precondition(
			selected, information_set.cache_precondition())]
		planned["forced_tactic"] = "post_plan_tactical_guard"
	_store_turn_plan(cache_key, state.revision, planned.get("turn_plan", []), selected)
	var nodes_expanded := int(planned.get("nodes_expanded", 0))
	_profile_count(profile, "planner_nodes", nodes_expanded)
	return _traditional_action_result(
		request,
		selected,
		strategy,
		information_set,
		nodes_expanded,
		str(planned.get("stop_reason", "complete")),
		false,
		planned,
	)


func _traditional_strategy_registry_instance() -> Variant:
	if _traditional_strategy_registry == null:
		_traditional_strategy_registry = AIStrategyRegistry.shared()
	return _traditional_strategy_registry


func _zero_budget_tactical_action(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	profile: Dictionary,
) -> GameAction:
	var best := actions[0]
	var best_score := _action_score(state, actor, best, deck_key, catalog, profile)
	for index in range(1, actions.size()):
		var candidate := actions[index]
		var candidate_score := _action_score(
			state, actor, candidate, deck_key, catalog, profile)
		if candidate_score > best_score:
			best = candidate
			best_score = candidate_score
	return _validated_or_fallback_action(
		state,
		actor,
		best,
		actions,
		deck_key,
		catalog,
		engine,
		seed,
		profile,
	)


func _exhausted_turn_action(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	profile: Dictionary,
) -> GameAction:
	## Once the deterministic replan allowance is spent, do not emit another
	## development action that would create a fresh decision.  Mandatory phases
	## are handled before this point; MAIN always supplies attack and/or end turn.
	var terminal_actions: Array[GameAction] = []
	for action in actions:
		if action.terminal or action.kind in ["DECLARE_ATTACK", "END_TURN", "SETUP_DONE"]:
			terminal_actions.append(action)
	if terminal_actions.is_empty():
		# Defensive compatibility for a future mandatory phase. Returning an
		# authoritative action remains safer than manufacturing an illegal terminal.
		terminal_actions.append(actions[0])
	return _zero_budget_tactical_action(
		state, actor, terminal_actions, deck_key, catalog, engine, seed, profile)


func _traditional_semantics_instance(catalog: CardCatalog) -> CardSemanticCatalog:
	if _traditional_semantic_catalog == null:
		_traditional_semantic_catalog = CardSemanticCatalog.new(catalog)
	return _traditional_semantic_catalog


func _traditional_leaf_score(
	state: GameState,
	actor: int,
	catalog: CardCatalog,
) -> float:
	# This callback is internal to the trusted planner. Deck strategy hooks never
	# receive GameState. Refuse any future caller that failed to canonicalize the
	# Challenge/Deep no-matchup rules before evaluating a leaf.
	if state == null or catalog == null or state.apply_type_matchups:
		return NAN
	return _strategic_evaluation_delta(state, actor, catalog)


func _traditional_action_candidate_score(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	# Root/turn candidate ordering is a trusted rules-layer concern. Deck hooks
	# still receive only AIInformationSet views; this bridge merely makes beam
	# ordering agree with the post-plan tactical guard.
	if state == null or action == null or catalog == null or state.apply_type_matchups:
		return NAN
	return _action_score(state, actor, action, deck_key, catalog)


func _traditional_simulated_choice_response(
	state: GameState,
	request: ChoiceView,
	match_seed: int,
	cancel_check: Callable,
	deadline_usec: int,
	root_actor: int,
	root_deck_key: String,
	root_strategy: Variant,
	catalog: CardCatalog,
) -> ChoiceResponse:
	## Trusted bridge used by mandatory tactics and the beam. Raw GameState stays
	## inside NativeChallengeAI: deck hooks receive only the deeply read-only
	## AIInformationSet view created by _traditional_choice_response.
	if state == null or request == null or catalog == null:
		return null
	state.set_type_matchups_enabled(false)
	var choice_actor := request.player if request.player in [0, 1] else root_actor
	var information_set := AIInformationSet.capture(
		state, choice_actor, catalog, [], [], match_seed)
	if not information_set.is_valid():
		return null
	var deck_key := _deck_key_for_actor(
		state,
		choice_actor,
		root_deck_key if choice_actor == root_actor else "",
	)
	var strategy: Variant = root_strategy if choice_actor == root_actor else null
	if strategy == null:
		var registry: Variant = _traditional_strategy_registry_instance()
		if registry == null or not registry.is_valid():
			return null
		strategy = registry.strategy_for(deck_key)
	return _traditional_choice_response(
		state,
		information_set,
		request,
		deck_key,
		strategy,
		catalog,
		cancel_check,
		deadline_usec,
		deadline_usec,
	)


func _bounded_traditional_planner_request(
	request: Dictionary,
	decision_started_usec: int = 0,
	tier: Dictionary = {},
) -> Dictionary:
	var requested_nodes := int(request.get(
		"node_budget", request.get("simulation_budget", GAMEPLAY_DEFAULT_SIMULATIONS)))
	if requested_nodes <= 0:
		requested_nodes = GAMEPLAY_DEFAULT_SIMULATIONS
	var requested_seconds := float(request.get("seconds", GAMEPLAY_DEFAULT_SECONDS))
	var requested_time_ms := int(request.get(
		"time_budget_ms", round(maxf(0.025, requested_seconds) * 1000.0)))
	var time_budget_ms := clampi(requested_time_ms, 25, 850)
	var node_budget := clampi(requested_nodes, 1, 192)
	var max_depth := clampi(int(request.get(
		"max_depth", GAMEPLAY_DEFAULT_DEPTH)), 1, 6)
	var tier_name := str(tier.get("tier", "full"))
	var hard_budget_msec := TRADITIONAL_HARD_DEADLINE_MSEC
	if tier_name == "local":
		node_budget = mini(node_budget, TURN_REPLAN_LOCAL_NODES)
		max_depth = mini(max_depth, TURN_REPLAN_LOCAL_DEPTH)
		time_budget_ms = mini(time_budget_ms, TURN_REPLAN_LOCAL_SOFT_MSEC)
		hard_budget_msec = TURN_REPLAN_LOCAL_HARD_MSEC
	elif tier_name == "exhausted":
		node_budget = 1
		max_depth = 1
		time_budget_ms = TURN_REPLAN_EXHAUSTED_SOFT_MSEC
		hard_budget_msec = TURN_REPLAN_EXHAUSTED_SOFT_MSEC
	var started_usec := (
		decision_started_usec if decision_started_usec > 0 else Time.get_ticks_usec())
	var soft_deadline_usec := started_usec + time_budget_ms * 1000
	var hard_deadline_usec := mini(
		started_usec + hard_budget_msec * 1000,
		soft_deadline_usec + 250000,
	)
	var result := {
		"beam_width": 6,
		"node_budget": node_budget,
		"max_actions_per_node": 6,
		"max_depth": max_depth,
		"time_budget_ms": time_budget_ms,
		"soft_deadline_usec": soft_deadline_usec,
		"hard_deadline_usec": hard_deadline_usec,
		"seed": int(request.get("seed", 17)),
		"mode": str(request.get("mode", "challenge")),
	}
	if tier_name == "local":
		result["belief_samples"] = 1
	if request.get("belief_samples") is int or request.get("belief_samples") is float:
		result["belief_samples"] = (
			1 if tier_name == "local" else clampi(int(request["belief_samples"]), 1, 3))
	return result


func _turn_plan_cache_key(
	request: Dictionary,
	information_set: AIInformationSet,
	deck_key: String,
) -> String:
	# Callers without a stable match instance remain correct, but deliberately do not
	# reuse plans across requests or test cases.
	if str(request.get("match_instance_id", "")).is_empty():
		return ""
	var view := information_set.read_only_view()
	return "%s|%d|%d|%s" % [
		str(request.get("match_instance_id", "")),
		information_set.perspective_player(),
		int(view.get("turn_number", 0)),
		deck_key,
	]


func _preview_turn_replan_tier(
	cache_key: String,
	revision: int,
	deck_key: String = "",
) -> Dictionary:
	if cache_key.is_empty() or not _turn_replan_ledger.has(cache_key):
		return {"tier": "full", "ordinal": 1}
	var entry: Dictionary = _turn_replan_ledger[cache_key]
	if revision == int(entry.get("last_revision", -1)):
		return {
			"tier": str(entry.get("last_tier", "full")),
			"ordinal": int(entry.get("last_ordinal", 1)),
		}
	return _next_turn_replan_tier(entry, deck_key)


func _reserve_turn_replan_tier(
	cache_key: String,
	revision: int,
	request_id: String,
	deck_key: String = "",
) -> Dictionary:
	if cache_key.is_empty():
		return {"tier": "full", "ordinal": 1}
	var entry: Dictionary = _turn_replan_ledger.get(cache_key, {
		"full_replans": 0,
		"local_replans": 0,
		"last_revision": -1,
		"last_tier": "",
		"last_ordinal": 0,
		"pending_request_id": "",
		"deck_key": deck_key,
	})
	if revision == int(entry.get("last_revision", -1)):
		return {
			"tier": str(entry.get("last_tier", "full")),
			"ordinal": int(entry.get("last_ordinal", 1)),
		}
	if not deck_key.is_empty():
		entry["deck_key"] = deck_key
	var reserved := _next_turn_replan_tier(entry, deck_key)
	match str(reserved["tier"]):
		"full":
			entry["full_replans"] = int(entry.get("full_replans", 0)) + 1
		"local":
			entry["local_replans"] = int(entry.get("local_replans", 0)) + 1
	entry["last_revision"] = revision
	entry["last_tier"] = reserved["tier"]
	entry["last_ordinal"] = reserved["ordinal"]
	entry["pending_request_id"] = request_id
	_turn_replan_ledger[cache_key] = entry
	while _turn_replan_ledger.size() > TURN_REPLAN_LEDGER_LIMIT:
		_turn_replan_ledger.erase(_turn_replan_ledger.keys()[0])
	return reserved


func _next_turn_replan_tier(
	entry: Dictionary,
	deck_key: String = "",
) -> Dictionary:
	var full_replans := int(entry.get("full_replans", 0))
	var local_replans := int(entry.get("local_replans", 0))
	var ordinal := full_replans + local_replans + 1
	if full_replans < TURN_REPLAN_FULL_LIMIT:
		return {"tier": "full", "ordinal": ordinal}
	if local_replans < TURN_REPLAN_LOCAL_LIMIT:
		return {"tier": "local", "ordinal": ordinal}
	return {"tier": "exhausted", "ordinal": ordinal}


func _authoritative_action_intersection(
	supplied: Array[GameAction],
	authoritative: Array[GameAction],
) -> Array[GameAction]:
	var result: Array[GameAction] = []
	var used: Dictionary = {}
	for supplied_action in supplied:
		var matched := TraditionalTurnPlanner.find_matching_action(
			TraditionalTurnPlanner.action_intent(supplied_action), authoritative)
		if matched == null:
			continue
		var signature := str(
			TraditionalTurnPlanner.action_intent(matched).get("signature", ""))
		if used.has(signature):
			continue
		used[signature] = true
		result.append(matched)
	return result


func _filter_exhausted_repeatable_abilities(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	catalog: CardCatalog,
) -> Array[GameAction]:
	## This guard is derived exclusively from the public authoritative log, not
	## mutable AI memory.  Identical snapshots therefore remain reproducible and
	## evaluator workers can be safely reused across matches.
	var result: Array[GameAction] = []
	var terminal_fallbacks: Array[GameAction] = []
	for action in actions:
		if action.terminal:
			terminal_fallbacks.append(action)
		if action.kind != "USE_ABILITY":
			result.append(action)
			continue
		var ability_name := str(action.payload.get("ability_name", ""))
		if (
			ability_name.is_empty()
			or not _ability_is_repeatable(
				state, actor, action, ability_name, catalog)
			or _repeatable_ability_uses_this_turn(
				state, action, ability_name, catalog)
			< MAX_REPEATABLE_ABILITY_USES_PER_TURN
		):
			result.append(action)
	if not result.is_empty():
		return result
	# MAIN normally always exposes END_TURN.  Retain any terminal authority action
	# as a defensive legal escape hatch if a future rules phase changes that set.
	return terminal_fallbacks if not terminal_fallbacks.is_empty() else actions


func _cached_action_needs_tactical_guard(
	state: GameState,
	actor: int,
	action: GameAction,
	catalog: CardCatalog,
) -> bool:
	if action == null:
		return false
	if action.kind in ["DECLARE_ATTACK", "RETREAT", "END_TURN"]:
		return true
	if action.kind != "USE_ABILITY":
		return false
	var slot := str(action.payload.get("slot", "active"))
	var source := state.get_player(actor).get_pokemon(slot)
	if source == null:
		# An unresolvable cached ability is stale; fail closed through validation.
		return true
	var ability_name := str(action.payload.get("ability_name", ""))
	for ability_value in catalog.get_card(source.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("name", "")) != ability_name:
			continue
		for effect in _flatten_effects(ability.get("effects", [])):
			if CACHE_GUARDED_ABILITY_EFFECT_TYPES.has(str(
				effect.get("effect_type", ""))):
				return true
		return false
	# Unknown ability metadata must not let an irreversible cached action bypass
	# the authoritative tactical validation path.
	return true


func _repeatable_ability_uses_this_turn(
	state: GameState,
	action: GameAction,
	ability_name: String,
	catalog: CardCatalog,
) -> int:
	var source_card_id := action.source.card_id if action.source != null else ""
	if source_card_id.is_empty() and action.source != null:
		var source_pokemon := state.get_player(action.actor).get_pokemon(action.source.slot)
		if source_pokemon != null:
			source_card_id = source_pokemon.card_id
	var card_name := catalog.card_name(source_card_id)
	var exact_log_entry := "%s使用特性%s。" % [card_name, ability_name]
	var generic_suffix := "使用特性%s。" % ability_name
	var count := 0
	for index in range(state.action_log.size() - 1, -1, -1):
		var entry := str(state.action_log[index])
		if entry.begins_with("—— "):
			break
		if (
			(not card_name.is_empty() and entry == exact_log_entry)
			or (card_name.is_empty() and entry.ends_with(generic_suffix))
		):
			count += 1
	return count


func _intent_with_precondition(
	action: GameAction,
	precondition: Dictionary,
) -> Dictionary:
	var result := TraditionalTurnPlanner.action_intent(action)
	for key in ["expected_public_fingerprint", "expected_actor", "expected_phase"]:
		if precondition.has(key):
			result[key] = precondition[key]
	return result


func _take_cached_turn_action(
	cache_key: String,
	revision: int,
	actions: Array[GameAction],
	information_set: AIInformationSet,
) -> GameAction:
	if cache_key.is_empty() or not _turn_plan_cache.has(cache_key):
		return null
	var entry: Dictionary = _turn_plan_cache[cache_key]
	if revision <= int(entry.get("last_revision", -1)):
		_turn_plan_cache.erase(cache_key)
		return null
	var intents: Array = Array(entry.get("intents", [])).duplicate(true)
	if intents.is_empty():
		_turn_plan_cache.erase(cache_key)
		return null
	var next_intent: Dictionary = intents[0]
	var actual_precondition := information_set.cache_precondition()
	if (
		str(next_intent.get("expected_public_fingerprint", "")).is_empty()
		or str(next_intent.get("expected_public_fingerprint", ""))
		!= str(actual_precondition.get("expected_public_fingerprint", ""))
		or int(next_intent.get("expected_actor", -1))
		!= int(actual_precondition.get("expected_actor", -1))
		or str(next_intent.get("expected_phase", ""))
		!= str(actual_precondition.get("expected_phase", ""))
	):
		_turn_plan_cache.erase(cache_key)
		return null
	var matched := TraditionalTurnPlanner.find_matching_action(
		next_intent, actions, information_set)
	if matched == null:
		_turn_plan_cache.erase(cache_key)
		return null
	intents.pop_front()
	if intents.is_empty():
		_turn_plan_cache.erase(cache_key)
	else:
		entry["intents"] = intents
		entry["last_revision"] = revision
		_turn_plan_cache[cache_key] = entry
	return matched


func _store_turn_plan(
	cache_key: String,
	revision: int,
	plan_value: Variant,
	selected: GameAction,
) -> void:
	if cache_key.is_empty() or not plan_value is Array or selected == null:
		return
	var intents: Array = Array(plan_value).duplicate(true)
	var selected_signature := str(
		TraditionalTurnPlanner.action_intent(selected).get("signature", ""))
	for index in range(intents.size()):
		if str(Dictionary(intents[index]).get("signature", "")) == selected_signature:
			intents.remove_at(index)
			break
	if intents.is_empty() or selected.terminal:
		_turn_plan_cache.erase(cache_key)
		return
	_turn_plan_cache[cache_key] = {
		"intents": intents,
		"last_revision": revision,
	}
	while _turn_plan_cache.size() > 8:
		_turn_plan_cache.erase(_turn_plan_cache.keys()[0])


func _traditional_action_result(
	request: Dictionary,
	action: GameAction,
	strategy: Variant,
	information_set: AIInformationSet,
	nodes_expanded: int,
	stop_reason: String,
	cache_hit: bool,
	planner_result: Dictionary,
) -> Dictionary:
	var mode := str(request.get("mode", "challenge"))
	var dynamic_config := _dynamic_budget_config(request.get("dynamic_budget", {}))
	var goal: Dictionary = {}
	var strategy_id := "generic_balanced_v1"
	var strategy_version := 0
	var strategy_hash := ""
	var reported_stop_reason := (
		"single_action" if stop_reason == "only_legal_action" else stop_reason)
	if strategy != null:
		if strategy.has_method("turn_goals"):
			goal = strategy.turn_goals(information_set.read_only_view())
		if strategy.has_method("strategy_id"):
			strategy_id = str(strategy.strategy_id())
		if strategy.has_method("version"):
			strategy_version = int(strategy.version())
		if strategy.has_method("content_hash"):
			strategy_hash = str(strategy.content_hash())
	return {
		"success": true,
		"kind": "action",
		"action": action.to_dict(),
		# Compatibility aliases: one simulation now means one expanded beam node.
		"simulations": nodes_expanded,
		"nodes_expanded": nodes_expanded,
		"budget_requested": mini(192, maxi(1, int(request.get(
			"simulation_budget", GAMEPLAY_DEFAULT_SIMULATIONS)))),
		"budget_stop_reason": reported_stop_reason,
		"dynamic_budget_enabled": bool(dynamic_config.get("enabled", false)),
		"deep_fallback": mode == "deep",
		"fallback_reason": "runtime_unavailable" if mode == "deep" else "",
		"planner": "turn_beam_v1",
		"planner_score": float(planner_result.get("score", 0.0)),
		"belief_samples": int(planner_result.get("belief_samples", 0)),
		"belief_consensus": int(planner_result.get("belief_consensus", 0)),
		"forced_tactic": str(planner_result.get("forced_tactic", "")),
		"turn_plan_size": Array(planner_result.get("turn_plan", [])).size(),
		"turn_plan_cache_hit": cache_hit,
		"turn_budget_tier": str(planner_result.get("turn_budget_tier", "untracked")),
		"turn_replan_ordinal": int(planner_result.get("turn_replan_ordinal", 0)),
		"strategy_id": strategy_id,
		"strategy_version": strategy_version,
		"strategy_hash": strategy_hash,
		"turn_goal": goal,
		"type_matchups": false,
	}


func _resolve_choices(
	state: GameState,
	perspective: int,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	rng: PortableRandomSource,
) -> bool:
	for _guard in range(32):
		var request := engine.query_pending_choice(state, 0)
		if request == null:
			request = engine.query_pending_choice(state, 1)
		if request == null:
			return true
		var response := _heuristic_choice(
			state,
			request,
			_deck_key_for_actor(state, request.player, deck_key),
			catalog,
		)
		var step := engine.apply_choice_response(state, response, rng)
		if not step.success:
			return false
	return false


func _choose_request(
	state: GameState,
	request: ChoiceView,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
	_engine: GameEngine,
	seed: int,
	match_seed: int,
	_inference: Variant,
	mode: String,
	cancel_check: Callable,
	decision_started_usec: int,
) -> Dictionary:
	state.set_type_matchups_enabled(false)
	if cancel_check.is_valid() and bool(cancel_check.call()):
		return {"success": false, "kind": "choice", "cancelled": true, "error": "cancelled"}
	var started_usec := (
		decision_started_usec if decision_started_usec > 0 else Time.get_ticks_usec())
	var soft_deadline_usec := started_usec + 850000
	var hard_deadline_usec := started_usec + TRADITIONAL_HARD_DEADLINE_MSEC * 1000
	var choice_actor := request.player if request.player in [0, 1] else actor
	var information_set := AIInformationSet.capture(
		state,
		choice_actor,
		catalog,
		[],
		[],
		match_seed,
	)
	if not information_set.is_valid():
		return {
			"success": false,
			"kind": "choice",
			"error": "invalid_information_set:%s" % information_set.validation_error(),
			"simulations": 0,
		}
	var sampled_state := information_set.sample_state(seed)
	if sampled_state == null:
		return {
			"success": false,
			"kind": "choice",
			"error": "choice_determinization_failed",
			"simulations": 0,
		}
	var resolved_deck_key := _deck_key_for_actor(sampled_state, choice_actor, deck_key)
	var registry: Variant = _traditional_strategy_registry_instance()
	var strategy: Variant = registry.strategy_for(resolved_deck_key)
	var response := _traditional_choice_response(
		sampled_state,
		information_set,
		request,
		resolved_deck_key,
		strategy,
		catalog,
		cancel_check,
		soft_deadline_usec,
		hard_deadline_usec,
	)
	if cancel_check.is_valid() and bool(cancel_check.call()):
		return {"success": false, "kind": "choice", "cancelled": true, "error": "cancelled"}
	if not AIChoiceSelector.response_is_shape_legal(
		request, response.option_ids, catalog, response.cancelled):
		return {
			"success": false,
			"kind": "choice",
			"error": "choice_response_constraints_unsatisfied",
			"simulations": 0,
		}
	return {
		"success": true,
		"kind": "choice",
		"choice_response": response.to_dict(),
		"simulations": 0,
		"deep_fallback": mode == "deep",
		"fallback_reason": "runtime_unavailable" if mode == "deep" else "",
		"strategy_id": str(strategy.strategy_id()),
		"strategy_version": int(strategy.version()),
		"strategy_hash": str(strategy.content_hash()),
		"planner": "turn_beam_v1",
		"type_matchups": false,
	}


func _traditional_choice_response(
	state: GameState,
	information_set: AIInformationSet,
	request: ChoiceView,
	deck_key: String,
	strategy: Variant,
	catalog: CardCatalog,
	cancel_check: Callable = Callable(),
	soft_deadline_usec: int = 0,
	hard_deadline_usec: int = 0,
) -> ChoiceResponse:
	# These choices have a rule-shaped dominant policy and should not be diluted
	# by deck tuning. They still operate on the sampled information-set state.
	if request.request_type in [
		"choose_turn_order",
		"choose_mulligan_draw_count",
		"select_prize",
		"select_retreat_payment",
		"confirm_trigger",
		"confirm",
		"arven",
	] or _is_arven_choice(request, _choice_presentation(request)):
		return _heuristic_choice(
			state,
			request,
			deck_key,
			catalog,
			null,
			17,
			false,
			cancel_check,
			soft_deadline_usec,
			hard_deadline_usec,
		)
	if request.options.is_empty():
		return ChoiceResponse.new(
			request.request_id, [], request.can_cancel and request.min_select <= 0)
	var public_view := information_set.read_only_view()
	var choice_row: Dictionary = _traditional_read_only_copy(request.to_dict())
	var semantics := _traditional_semantics_instance(catalog)
	var score_mode := _choice_score_mode(request, _choice_presentation(request))
	var joint_discard := _sequential_discard_choice_response(
		state,
		information_set,
		request,
		deck_key,
		strategy,
		catalog,
		score_mode,
		cancel_check,
		hard_deadline_usec,
	)
	if joint_discard != null:
		return joint_discard
	var ordered_distribution := _ordered_energy_distribution_response(
		state,
		request,
		deck_key,
		catalog,
		cancel_check,
		soft_deadline_usec,
		hard_deadline_usec,
	)
	if ordered_distribution != null:
		return ordered_distribution
	var repeated_energy_target := (
		score_mode == "energy"
		and request.allow_duplicates
		and bool(_choice_presentation(request).get("same_target", false))
	)
	var energy_prefix_plans: Dictionary = {}
	var ranked: Array[Dictionary] = []
	var scored: Dictionary = {}
	for index in range(request.options.size()):
		if _choice_work_should_stop(
			cancel_check, soft_deadline_usec, hard_deadline_usec):
			break
		var option: Dictionary = request.options[index]
		var card_id := _choice_option_card_id(option, catalog)
		var semantic_context: Dictionary = {"cards": {}}
		if not card_id.is_empty():
			semantic_context["cards"][card_id] = semantics.semantics_for(card_id)
		_traditional_deep_make_read_only(semantic_context)
		var base_score := _option_score(
			state, request, option, deck_key, catalog, score_mode)
		if repeated_energy_target:
			var prefix_plan := _energy_target_prefix_plan(
				state, request, option, deck_key, catalog,
				_choice_max_count(request))
			energy_prefix_plans[index] = prefix_plan
			if int(prefix_plan.get("count", 0)) <= 0:
				base_score = -10000.0
			else:
				# Rank the target by the value of its complete Energy prefix.  This
				# distinguishes a three-Energy attack route from a target whose first
				# attachment is useful but whose remaining attachments are wasteful.
				base_score += clampf(
					float(prefix_plan.get("gain", 0.0)) * 0.35, 0.0, 180.0)
		var strategy_score := 0.0
		if strategy != null and strategy.has_method("choice_score"):
			strategy_score = float(strategy.choice_score(
				public_view,
				choice_row,
				_traditional_read_only_copy(option),
				semantic_context,
			))
		ranked.append({
			"index": index,
			"score": base_score + strategy_score,
		})
		scored[index] = true
	for index in range(request.options.size()):
		if not scored.has(index):
			ranked.append({"index": index, "score": 0.0})
	ranked.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if is_equal_approx(float(left["score"]), float(right["score"])):
			return int(left["index"]) < int(right["index"])
		return float(left["score"]) > float(right["score"])
	)
	var ranked_indices: Array[int] = []
	for row in ranked:
		ranked_indices.append(int(row["index"]))
	var max_count := _choice_max_count(request)
	var min_count := maxi(0, request.min_select)
	if min_count <= 0:
		var positive_indices: Array[int] = []
		for row in ranked:
			if float(row["score"]) <= 0.0:
				continue
			positive_indices.append(int(row["index"]))
			if not request.allow_duplicates and positive_indices.size() >= max_count:
				break
		if positive_indices.is_empty() and request.can_cancel:
			return ChoiceResponse.new(request.request_id, [], true)
		var optional_count := max_count if request.allow_duplicates else positive_indices.size()
		if score_mode == "energy" and not positive_indices.is_empty():
			var selected_optional_plan: Dictionary = energy_prefix_plans.get(
				positive_indices[0], {})
			optional_count = mini(optional_count, int(selected_optional_plan.get(
				"count",
				_useful_energy_target_selection_count(
					state, request, request.options[positive_indices[0]],
					deck_key, catalog, max_count),
			)))
			if optional_count <= 0 and request.can_cancel:
				return ChoiceResponse.new(request.request_id, [], true)
		return ChoiceResponse.new(
			request.request_id,
			_ranked_choice_option_ids(
				request, positive_indices, optional_count, catalog),
		)
	var count := maxi(min_count, max_count)
	if score_mode == "energy" and not ranked_indices.is_empty():
		var selected_required_plan: Dictionary = energy_prefix_plans.get(
			ranked_indices[0], {})
		count = maxi(min_count, mini(count, int(selected_required_plan.get(
			"count",
			_useful_energy_target_selection_count(
				state, request, request.options[ranked_indices[0]],
				deck_key, catalog, max_count),
		))))
	return ChoiceResponse.new(
		request.request_id,
		_ranked_choice_option_ids(request, ranked_indices, count, catalog),
	)


func _sequential_discard_choice_response(
	state: GameState,
	information_set: AIInformationSet,
	request: ChoiceView,
	deck_key: String,
	strategy: Variant,
	catalog: CardCatalog,
	score_mode: String,
	cancel_check: Callable = Callable(),
	hard_deadline_usec: int = 0,
) -> ChoiceResponse:
	# Multi-card costs must value the final hand, not each card against the same
	# untouched hand.  Otherwise two copies can each look disposable because the
	# other copy appears to remain, and both are discarded together.
	var maximum := _choice_max_count(request)
	if (
		score_mode != "discard"
		or maximum <= 1
		or request.allow_duplicates
		or state == null
	):
		return null
	var virtual_state := GameState.from_dict(state.snapshot())
	virtual_state.set_type_matchups_enabled(false)
	var selected_indices: Array[int] = []
	var selected_ids: Array[String] = []
	var semantics := _traditional_semantics_instance(catalog)
	var choice_row: Dictionary = _traditional_read_only_copy(request.to_dict())
	for selection_index in range(maximum):
		if (
			(cancel_check.is_valid() and bool(cancel_check.call()))
			or (hard_deadline_usec > 0 and Time.get_ticks_usec() >= hard_deadline_usec)
		):
			return null
		var virtual_info := AIInformationSet.capture(
			virtual_state,
			request.player,
			catalog,
			[],
			[],
			information_set.match_seed(),
		)
		if not virtual_info.is_valid():
			return null
		var public_view := virtual_info.read_only_view()
		var best_index := -1
		var best_score := -INF
		var best_tiebreak := ""
		for option_index in range(request.options.size()):
			if option_index in selected_indices:
				continue
			var option: Dictionary = request.options[option_index]
			var card_id := _choice_option_card_id(option, catalog)
			var semantic_context: Dictionary = {"cards": {}}
			if not card_id.is_empty():
				semantic_context["cards"][card_id] = semantics.semantics_for(card_id)
			_traditional_deep_make_read_only(semantic_context)
			var score := _option_score(
				virtual_state, request, option, deck_key, catalog, score_mode)
			if strategy != null and strategy.has_method("choice_score"):
				score += float(strategy.choice_score(
					public_view,
					choice_row,
					_traditional_read_only_copy(option),
					semantic_context,
				))
			var tiebreak := "%s|%s" % [
				card_id, str(option.get("option_id", ""))]
			if (
				best_index < 0
				or score > best_score + 0.001
				or (is_equal_approx(score, best_score) and tiebreak < best_tiebreak)
			):
				best_index = option_index
				best_score = score
				best_tiebreak = tiebreak
		if best_index < 0:
			return null
		if selection_index >= request.min_select and best_score <= 0.0:
			break
		var selected_option: Dictionary = request.options[best_index]
		var selected_option_id := str(selected_option.get("option_id", ""))
		if selected_option_id.is_empty():
			return null
		selected_indices.append(best_index)
		selected_ids.append(selected_option_id)
		if _choice_option_is_hand_card(selected_option):
			var selected_card_id := _choice_option_card_id(selected_option, catalog)
			var hand := virtual_state.get_player(request.player).hand
			var hand_index := hand.find(selected_card_id)
			if hand_index >= 0:
				hand.remove_at(hand_index)
	if selected_ids.size() < request.min_select:
		return null
	if not AIChoiceSelector.response_is_shape_legal(
		request, selected_ids, catalog, false):
		return null
	return ChoiceResponse.new(request.request_id, selected_ids)


func _useful_energy_target_selection_count(
	state: GameState,
	request: ChoiceView,
	option: Dictionary,
	deck_key: String,
	catalog: CardCatalog,
	max_count: int,
) -> int:
	return int(_energy_target_prefix_plan(
		state, request, option, deck_key, catalog, max_count).get(
			"count", max_count))


func _energy_target_prefix_plan(
	state: GameState,
	request: ChoiceView,
	option: Dictionary,
	deck_key: String,
	catalog: CardCatalog,
	max_count: int,
) -> Dictionary:
	var presentation := _choice_presentation(request)
	if (
		not request.allow_duplicates
		or not bool(presentation.get("same_target", false))
	):
		# Independent targets may each have a useful deficit; their normal ranked
		# selection must not be capped by the first target's missing Energy.
		return {"count": max_count, "gain": 0.0}
	var target_player := _choice_option_player(option, request.player)
	var pokemon := state.get_player(target_player).get_pokemon(
		_choice_option_slot(option))
	if pokemon == null or max_count <= 0:
		return {"count": max_count, "gain": 0.0}
	var energy_ids: Array[String] = []
	for card_id_value in presentation.get("card_ids", []):
		var listed_id := str(card_id_value)
		if catalog.is_energy(listed_id):
			energy_ids.append(listed_id)
	var fallback_energy_id := _choice_energy_card_id(presentation, catalog)
	if energy_ids.is_empty() and not fallback_energy_id.is_empty():
		energy_ids.append(fallback_energy_id)
	if energy_ids.is_empty():
		return {"count": max_count, "gain": 0.0}

	# Evaluate every complete prefix.  A temporarily flat second attachment can
	# be the bridge to a valuable third attachment (for example Deoxys), so a
	# greedy first-zero-marginal break is incorrect.
	var baseline := _energy_attack_plan_utility(
		state, target_player, pokemon, deck_key, catalog)
	var best_utility := baseline
	var best_count := 0
	var appended := 0
	for prefix_index in range(max_count):
		var energy_card_id := str(energy_ids[mini(
			prefix_index, energy_ids.size() - 1)])
		if energy_card_id.is_empty() or not catalog.is_energy(energy_card_id):
			break
		pokemon.energy_card_ids.append(energy_card_id)
		appended += 1
		var prefix_count := prefix_index + 1
		var utility := _energy_attack_plan_utility(
			state, target_player, pokemon, deck_key, catalog
		) - float(prefix_count) * 25.0
		# Strict comparison intentionally keeps the smaller prefix on ties.
		if utility > best_utility + 0.001:
			best_utility = utility
			best_count = prefix_count
	for _index in range(appended):
		pokemon.energy_card_ids.remove_at(pokemon.energy_card_ids.size() - 1)
	return {
		"count": best_count,
		"gain": maxf(0.0, best_utility - baseline),
	}


func _ordered_energy_distribution_response(
	state: GameState,
	request: ChoiceView,
	deck_key: String,
	catalog: CardCatalog,
	cancel_check: Callable = Callable(),
	soft_deadline_usec: int = 0,
	hard_deadline_usec: int = 0,
) -> ChoiceResponse:
	var presentation := _choice_presentation(request)
	if (
		request.request_type != "distribute_energy"
		or not request.allow_duplicates
		or bool(presentation.get("same_target", false))
	):
		return null
	var maximum := _choice_max_count(request)
	if maximum < 2 or maximum > 3:
		return null
	var raw_card_ids: Variant = presentation.get("card_ids", [])
	if not raw_card_ids is Array or Array(raw_card_ids).size() < maximum:
		return null
	# ChoiceResponse.option_ids[k] targets presentation.card_ids[k].  Keep the
	# public order exactly; filtering or sorting these ids silently retargets a
	# different Energy in the authoritative continuation.
	var energy_ids: Array[String] = []
	for index in range(maximum):
		var energy_id := str(Array(raw_card_ids)[index])
		if not catalog.is_energy(energy_id):
			return null
		energy_ids.append(energy_id)

	var player := state.get_player(request.player)
	var targets: Array[Dictionary] = []
	var seen_slots: Dictionary = {}
	var seen_option_ids: Dictionary = {}
	for option_index in range(request.options.size()):
		var option: Dictionary = request.options[option_index]
		var option_id := str(option.get("option_id", ""))
		var slot := _choice_option_slot(option)
		if (
			option_id.is_empty()
			or slot.is_empty()
			or _choice_option_player(option, request.player) != request.player
			or seen_slots.has(slot)
			or seen_option_ids.has(option_id)
		):
			continue
		var pokemon := player.get_pokemon(slot)
		if pokemon == null:
			continue
		var public_card_id := _choice_option_card_id(option, catalog)
		if not public_card_id.is_empty() and public_card_id != pokemon.card_id:
			continue
		seen_slots[slot] = true
		seen_option_ids[option_id] = true
		targets.append({
			"option_index": option_index,
			"option_id": option_id,
			"slot": slot,
		})
	if targets.is_empty():
		return null

	var purpose := str(presentation.get("purpose", ""))
	var is_relocation := purpose.begins_with("relocate_energy")
	var minimum := maxi(0, request.min_select)
	if is_relocation and minimum != maximum:
		# The relocation continuation requires one target for every public
		# attachment ref.  A malformed partial request is left to the normal
		# fail-closed choice path instead of guessing at the private stack.
		return null
	var original_energy := _capture_public_field_energy(player)
	var best_ids: Array[String] = []
	var best_score := -INF
	var found_best := false
	var invalid_relocation := false
	for count in range(minimum, maximum + 1):
		var assignments: Array = [[]]
		for _position in range(count):
			var expanded: Array = []
			for prefix_value in assignments:
				var prefix: Array = prefix_value
				for target_index in range(targets.size()):
					var next_prefix := prefix.duplicate()
					next_prefix.append(target_index)
					expanded.append(next_prefix)
			assignments = expanded
		for assignment_value in assignments:
			if _choice_work_should_stop(
				cancel_check, soft_deadline_usec, hard_deadline_usec):
				break
			var assignment: Array = assignment_value
			var option_ids: Array[String] = []
			for target_index_value in assignment:
				option_ids.append(str(targets[int(target_index_value)]["option_id"]))
			if not AIChoiceSelector.response_is_shape_legal(
				request, option_ids, catalog, false):
				continue
			_restore_public_field_energy(player, original_energy)
			if is_relocation and not _remove_public_relocation_energy(
				state, request, energy_ids, maximum):
				invalid_relocation = true
				break
			for position in range(assignment.size()):
				var target: Dictionary = targets[int(assignment[position])]
				var target_pokemon := player.get_pokemon(str(target["slot"]))
				if target_pokemon != null:
					target_pokemon.energy_card_ids.append(energy_ids[position])
			var score := _public_energy_distribution_board_utility(
				state, request.player, deck_key, catalog)
			_restore_public_field_energy(player, original_energy)
			# Assignments are generated by count and option index.  Strict score
			# comparison therefore gives deterministic smaller-prefix/lexicographic
			# tie breaking without consulting hidden state or random data.
			if not found_best or score > best_score + 0.001:
				found_best = true
				best_score = score
				best_ids = option_ids
		if invalid_relocation or _choice_work_should_stop(
			cancel_check, soft_deadline_usec, hard_deadline_usec):
			break
	_restore_public_field_energy(player, original_energy)
	if invalid_relocation or not found_best:
		return null
	return ChoiceResponse.new(
		request.request_id,
		best_ids,
		best_ids.is_empty() and request.can_cancel,
	)


func _capture_public_field_energy(player: PlayerState) -> Dictionary:
	var result: Dictionary = {}
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon != null:
			result[str(row["slot"])] = pokemon.energy_card_ids.duplicate()
	return result


func _restore_public_field_energy(player: PlayerState, values: Dictionary) -> void:
	for slot_value in values:
		var pokemon := player.get_pokemon(str(slot_value))
		if pokemon != null:
			pokemon.energy_card_ids.assign(values[slot_value])


func _remove_public_relocation_energy(
	state: GameState,
	request: ChoiceView,
	energy_ids: Array[String],
	count: int,
) -> bool:
	var presentation := _choice_presentation(request)
	var source_player := int(presentation.get("source_player", request.player))
	var source_slot := str(presentation.get("source_slot", ""))
	if source_player != request.player or source_slot.is_empty():
		return false
	var source := state.get_player(source_player).get_pokemon(source_slot)
	var refs_value: Variant = presentation.get("attachment_refs", [])
	if source == null or not refs_value is Array or Array(refs_value).size() < count:
		return false
	var indices: Array[int] = []
	var seen_indices: Dictionary = {}
	for position in range(count):
		var ref_value: Variant = Array(refs_value)[position]
		if not ref_value is Dictionary:
			return false
		var ref: Dictionary = ref_value
		var index := int(ref.get("index", -1))
		if (
			str(ref.get("kind", "")) != "attachment"
			or int(ref.get("player", -1)) != source_player
			or str(ref.get("slot", "")) != source_slot
			or str(ref.get("attachment_type", "")) != "energy"
			or index < 0
			or index >= source.energy_card_ids.size()
			or seen_indices.has(index)
			or str(ref.get("card_id", "")) != energy_ids[position]
			or str(source.energy_card_ids[index]) != energy_ids[position]
		):
			return false
		seen_indices[index] = true
		indices.append(index)
	indices.sort()
	indices.reverse()
	for index in indices:
		source.energy_card_ids.remove_at(index)
	return true


func _public_energy_distribution_board_utility(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var score := 0.0
	var opponent := state.get_player(1 - actor)
	var opponent_hp := (
		opponent.active.current_hp(catalog) if opponent.active != null else 0)
	var high_impact_floor := AIDeckProfiles.high_impact_damage_floor(deck_key)
	for row in state.get_player(actor).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var best := -INF
		for attack_value in catalog.get_card(pokemon.card_id).get("attacks", []):
			var attack: Dictionary = attack_value
			var missing := _missing_energy_count(
				pokemon, attack.get("cost", []), catalog)
			# Printed damage and Energy costs are public semantic data.  Deliberately
			# avoid the full damage estimator here: some attacks inspect hidden deck
			# contents, and type-matchup metadata is outside Challenge AI's ruleset.
			var damage := int(attack.get("damage", 0))
			var value := float(damage) - float(missing) * 55.0
			if missing == 0 and damage > 0:
				value += 80.0
				if damage >= high_impact_floor:
					value += 70.0
				if opponent_hp > 0 and damage >= opponent_hp:
					value += 200.0 + float(catalog.prize_value(
						opponent.active.card_id)) * 100.0
			elif missing == 1 and damage >= high_impact_floor:
				value += 25.0
			best = maxf(best, value)
		if best > -INF:
			score += best * (1.0 if str(row["slot"]) == "active" else 0.9)
	return score


func _energy_attack_plan_utility(
	state: GameState,
	actor: int,
	pokemon: PokemonState,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var opponent := state.get_player(1 - actor)
	var opponent_hp := (
		opponent.active.current_hp(catalog) if opponent.active != null else 0)
	var opponent_prizes := (
		catalog.prize_value(opponent.active.card_id)
		if opponent.active != null else 0)
	var best := _energy_attack_plan_for_card(
		state, actor, pokemon, pokemon.card_id, opponent_hp,
		opponent_prizes, catalog)
	for descendant_id in _energy_plan_evolution_descendants(
		state, actor, pokemon.card_id, deck_key, catalog):
		best = maxf(best, _energy_attack_plan_for_card(
			state, actor, pokemon, descendant_id, opponent_hp,
			opponent_prizes, catalog) * 0.75)
	return best


func _energy_attack_plan_for_card(
	state: GameState,
	actor: int,
	source: PokemonState,
	card_id: String,
	opponent_hp: int,
	opponent_prizes: int,
	catalog: CardCatalog,
) -> float:
	var attacks: Array = catalog.get_card(card_id).get("attacks", [])
	if attacks.is_empty():
		return -99.0
	var probe := source
	if card_id != source.card_id:
		probe = source.clone_state()
		probe.evolution_stack_ids.append(source.card_id)
		probe.card_id = card_id
	var best := -INF
	for attack_index in range(attacks.size()):
		var attack: Dictionary = attacks[attack_index]
		var missing := _missing_energy_count(
			probe, attack.get("cost", []), catalog)
		var damage := (
			_estimated_pokemon_attack_damage(
				state, actor, probe, attack_index, catalog)
			if probe == source
			else _estimated_evolution_attack_damage(
				state, actor, source, probe, attack_index, catalog)
		)
		var value := float(damage) - float(missing) * 50.0
		if missing == 0 and damage > 0:
			value += 80.0
			if opponent_hp > 0 and damage >= opponent_hp:
				value += 220.0 + float(opponent_prizes) * 100.0
		best = maxf(best, value)
	return best


func _estimated_evolution_attack_damage(
	state: GameState,
	actor: int,
	source: PokemonState,
	probe: PokemonState,
	attack_index: int,
	catalog: CardCatalog,
) -> int:
	var player := state.get_player(actor)
	if player.active == source:
		player.active = probe
		var active_damage := _estimated_pokemon_attack_damage(
			state, actor, probe, attack_index, catalog)
		player.active = source
		return active_damage
	var bench_index := player.bench.find(source)
	if bench_index >= 0:
		player.bench[bench_index] = probe
		var bench_damage := _estimated_pokemon_attack_damage(
			state, actor, probe, attack_index, catalog)
		player.bench[bench_index] = source
		return bench_damage
	return _best_pokemon_damage(probe, catalog)


func _energy_plan_evolution_descendants(
	state: GameState,
	actor: int,
	source_card_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> Array[String]:
	var result: Array[String] = []
	if deck_key.is_empty() or source_card_id.is_empty():
		return result
	var deck_cards := catalog.expand_deck(deck_key)
	var frontier: Array[String] = [source_card_id]
	var seen := {source_card_id: true}
	for _depth in range(2):
		var next_frontier: Array[String] = []
		for parent_id in frontier:
			var parent_name := catalog.card_name(parent_id)
			for candidate_id_value in deck_cards:
				var candidate_id := str(candidate_id_value)
				if seen.has(candidate_id) or not catalog.is_pokemon(candidate_id):
					continue
				if str(catalog.get_card(candidate_id).get(
					"evolves_from", "")) != parent_name:
					continue
				seen[candidate_id] = true
				if _deck_evolution_copy_publicly_available(
					state, actor, candidate_id, deck_cards):
					next_frontier.append(candidate_id)
					var probe := PokemonState.new(candidate_id)
					if (
						AIDeckProfiles.contains(deck_key, "core", candidate_id)
						or catalog.prize_value(candidate_id) >= 2
						or _best_pokemon_damage(probe, catalog)
							>= AIDeckProfiles.high_impact_damage_floor(deck_key)
					):
						result.append(candidate_id)
		frontier = next_frontier
		if frontier.is_empty():
			break
	return result


func _deck_evolution_copy_publicly_available(
	state: GameState,
	actor: int,
	card_id: String,
	deck_cards: Array[String],
) -> bool:
	var deck_copies := deck_cards.count(card_id)
	if deck_copies <= 0:
		return false
	# Deliberately use only the fixed public deck list and the actor's public
	# discard.  The real deck/prize ordering must never influence a choice.
	return state.get_player(actor).discard.count(card_id) < deck_copies


static func _traditional_read_only_copy(value: Variant) -> Variant:
	var result: Variant = (
		value.duplicate(true) if value is Dictionary or value is Array else value)
	_traditional_deep_make_read_only(result)
	return result


static func _traditional_deep_make_read_only(value: Variant) -> void:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for nested in dictionary.values():
			_traditional_deep_make_read_only(nested)
		dictionary.make_read_only()
	elif value is Array:
		var array: Array = value
		for nested in array:
			_traditional_deep_make_read_only(nested)
		array.make_read_only()


func _heuristic_choice(
	state: GameState,
	request: ChoiceView,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine = null,
	seed: int = 17,
	enable_lookahead: bool = false,
	cancel_check: Callable = Callable(),
	soft_deadline_usec: int = 0,
	hard_deadline_usec: int = 0,
) -> ChoiceResponse:
	if request.options.is_empty():
		return ChoiceResponse.new(
			request.request_id,
			[],
			request.can_cancel and request.min_select <= 0,
		)
	if request.request_type == "choose_turn_order":
		return ChoiceResponse.new(request.request_id, ["turn:first"])
	if request.request_type == "choose_mulligan_draw_count":
		var largest_draw := -1
		for option in request.options:
			var option_id := str(option.get("option_id", ""))
			if option_id.begins_with("draw:"):
				largest_draw = maxi(largest_draw, int(option_id.trim_prefix("draw:")))
		return ChoiceResponse.new(request.request_id, ["draw:%d" % maxi(0, largest_draw)])
	if request.request_type == "select_prize":
		var lowest_prize := 999
		for option in request.options:
			var option_id := str(option.get("option_id", ""))
			if option_id.begins_with("prize:"):
				lowest_prize = mini(lowest_prize, int(option_id.trim_prefix("prize:")))
		return ChoiceResponse.new(request.request_id, [
			"prize:%d" % (0 if lowest_prize == 999 else lowest_prize)
		])
	if request.request_type == "select_retreat_payment":
		return retreat_payment_response(state, request, catalog)
	if request.request_type == "confirm_trigger":
		return ChoiceResponse.new(request.request_id, [str(
			request.options[0].get("option_id", ""))])
	var presentation := _choice_presentation(request)
	if request.request_type == "confirm":
		var confirmed := _confirm_choice(state, request, presentation, deck_key, catalog)
		return ChoiceResponse.new(
			request.request_id,
			["confirm:yes" if confirmed else "confirm:no"],
		)
	if _is_arven_choice(request, presentation):
		return ChoiceResponse.new(
			request.request_id,
			_arven_choice_option_ids(state, request, deck_key, catalog),
		)
	var mode := _choice_score_mode(request, presentation)
	if enable_lookahead and _semantic_v2_enabled() and engine != null:
		var lookahead := _semantic_lookahead_choice(
			state, request, deck_key, catalog, engine, seed, mode)
		if lookahead != null:
			return lookahead
	var ranked_rows: Array[Dictionary] = []
	var scored: Dictionary = {}
	for index in range(request.options.size()):
		if _choice_work_should_stop(
			cancel_check, soft_deadline_usec, hard_deadline_usec):
			break
		ranked_rows.append({
			"index": index,
			"score": _option_score(
				state, request, request.options[index], deck_key, catalog, mode),
		})
		scored[index] = true
	for index in range(request.options.size()):
		if not scored.has(index):
			ranked_rows.append({"index": index, "score": 0.0})
	ranked_rows.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if is_equal_approx(float(left["score"]), float(right["score"])):
			return int(left["index"]) < int(right["index"])
		return float(left["score"]) > float(right["score"])
	)
	var ranked: Array[int] = []
	var scores_by_index: Dictionary = {}
	for row in ranked_rows:
		ranked.append(int(row["index"]))
		scores_by_index[int(row["index"])] = float(row["score"])
	var max_count: int = _choice_max_count(request)
	var min_count: int = max(0, request.min_select)
	if min_count <= 0:
		var positive_ranked: Array[int] = []
		for index in ranked:
			if float(scores_by_index.get(index, 0.0)) <= 0.0:
				continue
			positive_ranked.append(index)
			if not request.allow_duplicates and positive_ranked.size() >= max_count:
				break
		if positive_ranked.is_empty() and request.can_cancel:
			return ChoiceResponse.new(request.request_id, [], true)
		var optional_count: int = max_count if request.allow_duplicates else positive_ranked.size()
		return ChoiceResponse.new(
			request.request_id,
			_ranked_choice_option_ids(
				request, positive_ranked, optional_count, catalog),
		)
	var count: int = max(min_count, max_count)
	return ChoiceResponse.new(
		request.request_id,
		_ranked_choice_option_ids(request, ranked, count, catalog),
	)


static func retreat_payment_response(
	state: GameState,
	request: ChoiceView,
	catalog: CardCatalog,
) -> ChoiceResponse:
	var required_units := maxi(0, int(request.presentation.get("required_units", 0)))
	if required_units <= 0:
		return ChoiceResponse.new(request.request_id, [])
	if state == null or request.player not in [0, 1]:
		return ChoiceResponse.new(request.request_id, [], request.can_cancel)
	var player: PlayerState = state.get_player(request.player)
	var active: PokemonState = player.active if player != null else null
	if active == null:
		return ChoiceResponse.new(request.request_id, [], request.can_cancel)
	var candidates: Array[Dictionary] = []
	for option_order in range(request.options.size()):
		var option: Dictionary = request.options[option_order]
		var ref_value: Variant = option.get("ref")
		if not ref_value is Dictionary:
			continue
		var ref: Dictionary = ref_value
		var attachment_index := int(ref.get("index", -1))
		if (
			str(ref.get("kind", "")) != "attachment"
			or str(ref.get("attachment_type", "")) != "energy"
			or int(ref.get("player", -1)) != request.player
			or str(ref.get("slot", "")) != "active"
			or attachment_index < 0
			or attachment_index >= active.energy_card_ids.size()
			or str(ref.get("card_id", "")) != active.energy_card_ids[attachment_index]
		):
			continue
		var units := EnergyView.units_provided_by_card(
			active.energy_card_ids, attachment_index, catalog)
		if units <= 0:
			continue
		candidates.append({
			"option_id": str(option.get("option_id", "")),
			"units": units,
			"index": attachment_index,
			"order": option_order,
		})
	# Prefer fewer discarded cards. Stable attachment index ordering keeps the
	# choice reproducible when multiple payments provide the same units.
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if int(left["units"]) != int(right["units"]):
			return int(left["units"]) > int(right["units"])
		if int(left["index"]) != int(right["index"]):
			return int(left["index"]) < int(right["index"])
		return int(left["order"]) < int(right["order"])
	)
	var selected: Array[Dictionary] = []
	var paid_units := 0
	for candidate in candidates:
		selected.append(candidate)
		paid_units += int(candidate["units"])
		if paid_units >= required_units:
			break
	if paid_units < required_units:
		return ChoiceResponse.new(request.request_id, [], request.can_cancel)
	# Defensive inclusion-minimal pass: no selected card may be removable while
	# the remaining cards still cover the retreat cost.
	for index in range(selected.size() - 1, -1, -1):
		var units := int(selected[index]["units"])
		if paid_units - units >= required_units:
			paid_units -= units
			selected.remove_at(index)
	var option_ids: Array[String] = []
	for candidate in selected:
		option_ids.append(str(candidate["option_id"]))
	return ChoiceResponse.new(request.request_id, option_ids)


func _semantic_lookahead_choice(
	state: GameState,
	request: ChoiceView,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	mode: String,
) -> ChoiceResponse:
	if request.options.size() > SEMANTIC_CHOICE_LOOKAHEAD_MAX_OPTIONS:
		return null
	if not _choice_request_matches_pending(state, request):
		return null
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
	var count: int = max(min_count, max_count)
	if not request.allow_duplicates:
		count = mini(count, request.options.size())
	if count <= 0:
		return ChoiceResponse.new(request.request_id, [], request.can_cancel)

	var baseline := _evaluate_raw(state, request.player, catalog)
	var best_response: ChoiceResponse = null
	var best_score := -INF
	var best_option_score := -INF
	var candidate_count: int = mini(ranked.size(), SEMANTIC_CHOICE_LOOKAHEAD_MAX_OPTIONS)
	for candidate_offset in range(candidate_count):
		var anchor := ranked[candidate_offset]
		var candidate_ranked: Array[int] = [anchor]
		for index in ranked:
			if index != anchor:
				candidate_ranked.append(index)
		var option_ids := _ranked_choice_option_ids(
			request, candidate_ranked, count, catalog)
		if option_ids.is_empty() and min_count > 0:
			continue
		var response := ChoiceResponse.new(request.request_id, option_ids, false)
		var simulation := state.clone_state()
		var rng := PortableRandomSource.new(seed + candidate_offset * 7919 + anchor * 101)
		var step := engine.apply_choice_response(simulation, response, rng)
		if not step.success:
			continue
		if not _resolve_choices(simulation, request.player, deck_key, catalog, engine, rng):
			continue
		var score := _evaluate_raw(simulation, request.player, catalog)
		var option_score := _option_score(state, request, request.options[anchor], deck_key, catalog, mode)
		score += option_score * _semantic_choice_option_weight(mode)
		if score > best_score:
			best_score = score
			best_option_score = option_score
			best_response = response
	if best_response == null:
		return null
	if (
		min_count <= 0
		and request.can_cancel
		and best_score <= baseline + 2.0
		and best_option_score <= 0.0
	):
		return ChoiceResponse.new(request.request_id, [], true)
	return best_response


func _semantic_choice_option_weight(mode: String) -> float:
	match mode:
		"search":
			return 0.28
		"discard":
			return 0.18
		"energy", "energy_source":
			return 0.12
		"target", "self_switch", "heal":
			return 0.10
	return 0.08


func _choice_request_matches_pending(state: GameState, request: ChoiceView) -> bool:
	if request == null or request.player not in [0, 1]:
		return false
	return request.base_revision == state.revision


func _choice_presentation(
	request: ChoiceView = null,
) -> Dictionary:
	return request.presentation.duplicate(true) if request != null else {}


func _choice_max_count(request: ChoiceView) -> int:
	var max_count: int = max(0, request.max_select)
	if not request.allow_duplicates:
		max_count = mini(request.options.size(), max_count)
	return max_count


func _choice_score_mode(request: ChoiceView, presentation: Dictionary) -> String:
	var purpose := str(presentation.get("purpose", ""))
	if request.request_type == "select_attachment":
		if purpose == "discard_energy":
			return (
				"energy_source"
				if int(presentation.get("source_player", request.player)) == request.player
				else "target"
			)
		return (
			"energy"
			if purpose.begins_with("relocate_energy")
			else "discard"
		)
	if purpose in ["discard_then_draw", "discard_cards", "hand_bottom_draw", "houb", "zinnia"]:
		return "discard"
	if request.request_type == "select_energy_source" or purpose == "energy_relocate_source":
		return "energy_source"
	if request.request_type in ["select_energy_target", "distribute_energy", "look_top_attach_energy"]:
		return "energy"
	if request.request_type == "select_heal_target" or purpose == "heal":
		return "heal"
	if request.request_type in ["select_opponent_bench", "bench_damage_target", "damage_target", "place_counters_self_ko"]:
		return "target"
	if request.request_type == "select_bench" and purpose == "switch":
		return "self_switch"
	if purpose in ["discard", "discard_cost", "bottom_deck"]:
		return "discard"
	return "search"


func _is_arven_choice(request: ChoiceView, presentation: Dictionary) -> bool:
	return request.request_type == "arven" or str(presentation.get("purpose", "")) == "arven"


func _arven_choice_option_ids(
	state: GameState,
	request: ChoiceView,
	deck_key: String,
	catalog: CardCatalog,
) -> Array[String]:
	var opening_switch := _psychic_arven_opening_switch_option(
		state, request, deck_key, catalog)
	var best_item := -1
	var best_item_score := -INF
	var best_tool := -1
	var best_tool_score := -INF
	for index in range(request.options.size()):
		var option: Dictionary = request.options[index]
		var card_id := _choice_option_card_id(option, catalog)
		var score := _card_keep_value(state, request.player, card_id, deck_key, catalog)
		if catalog.is_item(card_id) and score > best_item_score:
			best_item = index
			best_item_score = score
		elif catalog.is_tool(card_id) and score > best_tool_score:
			best_tool = index
			best_tool_score = score
	if opening_switch >= 0:
		# Arven is resolved by this trusted category-aware selector rather than the
		# deck hook.  Preserve the only public, executable Cresselia opening route
		# here so generic keep-value cannot replace Switch with Ultra Ball.
		best_item = opening_switch
	var selected: Array[String] = []
	if best_item >= 0:
		selected.append(str(request.options[best_item]["option_id"]))
	if best_tool >= 0 and selected.size() < request.max_select:
		selected.append(str(request.options[best_tool]["option_id"]))
	if selected.is_empty() and request.min_select > 0:
		var fallback := 0
		for index in range(1, request.options.size()):
			if _card_keep_value(
				state, request.player, _choice_option_card_id(request.options[index], catalog), deck_key, catalog
			) > _card_keep_value(
				state, request.player, _choice_option_card_id(request.options[fallback], catalog), deck_key, catalog
			):
				fallback = index
		selected.append(str(request.options[fallback]["option_id"]))
	return selected


func _psychic_arven_opening_switch_option(
	state: GameState,
	request: ChoiceView,
	deck_key: String,
	catalog: CardCatalog,
) -> int:
	if (
		deck_key != "psychic"
		or state == null
		or request.player not in [0, 1]
		or state.phase != "MAIN"
		or state.active_player_idx != request.player
		or state.first_player_idx == request.player
		or not state.is_player_first_turn(request.player)
	):
		return -1
	var player := state.get_player(request.player)
	if player.active == null or player.active.card_id == "sv1-113":
		return -1
	# An in-hand Switch or a legal direct retreat already completes the route;
	# spending the once-per-turn Supporter on another copy is not dominant.
	if "sv1-150" in player.hand:
		return -1
	var cresselia_bench_index := -1
	for bench_index in range(player.bench.size()):
		if (
			player.bench[bench_index] != null
			and player.bench[bench_index].card_id == "sv1-113"
		):
			cresselia_bench_index = bench_index
			break
	if cresselia_bench_index < 0:
		return -1
	var cresselia: PokemonState = player.bench[cresselia_bench_index]
	var can_pay_attack := (
		"sv1-ener-5" in cresselia.energy_card_ids
		or (
			not player.energy_attached_this_turn
			and "sv1-ener-5" in player.hand
		)
	)
	if not can_pay_attack:
		return -1
	if RulesValidator.new(catalog).can_start_retreat(
		state, request.player, cresselia_bench_index).is_empty():
		return -1
	for index in range(request.options.size()):
		if _choice_option_card_id(request.options[index], catalog) == "sv1-150":
			return index
	return -1


func _ranked_choice_option_ids(
	request: ChoiceView,
	ranked: Array[int],
	count: int,
	catalog: CardCatalog = null,
) -> Array[String]:
	return AIChoiceSelector.select_ranked_option_ids(
		request, ranked, count, catalog)


func _choice_work_should_stop(
	cancel_check: Callable,
	soft_deadline_usec: int,
	hard_deadline_usec: int,
) -> bool:
	return (
		(cancel_check.is_valid() and bool(cancel_check.call()))
		or (soft_deadline_usec > 0 and Time.get_ticks_usec() >= soft_deadline_usec)
		or (hard_deadline_usec > 0 and Time.get_ticks_usec() >= hard_deadline_usec)
	)


func _option_score(
	state: GameState,
	request: ChoiceView,
	option: Dictionary,
	deck_key: String,
	catalog: CardCatalog,
	mode: String = "search",
) -> float:
	var card_id := _choice_option_card_id(option, catalog)
	if mode == "discard":
		return _discard_choice_score(
			state, request.player, card_id, deck_key, catalog,
			_choice_option_is_hand_card(option))
	var presentation := _choice_presentation(request)
	if mode == "energy_source":
		return _energy_source_choice_value(
			state,
			_choice_option_player(option, request.player),
			_choice_option_slot(option),
			presentation,
			deck_key,
			catalog,
		)
	# Card-retention value is meaningful for search/discard choices, but it is
	# not a board-target value.  Starting Energy/heal/switch/attack targets with
	# it used to count a core Pokemon's search priority and HP a second time,
	# overwhelming the marginal effect of the choice itself.
	var score := (
		_card_keep_value(state, request.player, card_id, deck_key, catalog)
		if mode == "search"
		else 0.0
	)
	var slot := _choice_option_slot(option)
	var target_player := _choice_option_player(option, request.player)
	var pokemon := state.get_player(target_player).get_pokemon(slot)
	if pokemon:
		var hp := pokemon.current_hp(catalog)
		if mode == "target" or target_player != request.player:
			score += _target_choice_value(
				state, request, target_player, pokemon, slot, presentation, catalog)
		elif mode == "heal":
			score += pokemon.damage_counters * 30.0
		elif mode == "energy":
			score += _energy_choice_target_value(
				state,
				target_player,
				slot,
				_choice_energy_card_id(presentation, catalog),
				deck_key,
				catalog,
			)
		elif mode == "self_switch":
			score += _promotion_value_for_state(
				state, target_player, pokemon, deck_key, catalog)
		else:
			score += _effective_energy_unit_count(pokemon, catalog) * 12.0
			if slot == "active":
				score += 20.0
	return score


func _choice_option_card_id(option: Dictionary, catalog: CardCatalog) -> String:
	var ref_variant: Variant = option.get("ref", {})
	if ref_variant is Dictionary:
		var ref: Dictionary = ref_variant
		var card_id := str(ref.get("card_id", ""))
		if not card_id.is_empty():
			return card_id
	var option_parts := str(option.get("option_id", "")).split(":")
	if option_parts.size() >= 2:
		var candidate := str(option_parts[-1])
		if not catalog.get_card(candidate).is_empty():
			return candidate
	return ""


func _choice_option_slot(option: Dictionary) -> String:
	var ref_variant: Variant = option.get("ref", {})
	if ref_variant is Dictionary:
		var ref: Dictionary = ref_variant
		var slot := str(ref.get("slot", ""))
		if not slot.is_empty():
			return slot
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
	var option_parts := str(option.get("option_id", "")).split(":")
	if option_parts.size() >= 2 and option_parts[0] in ["pokemon", "attachment"]:
		return int(option_parts[1])
	return fallback


func _choice_option_is_hand_card(option: Dictionary) -> bool:
	var ref_variant: Variant = option.get("ref", {})
	if ref_variant is Dictionary:
		var ref: Dictionary = ref_variant
		if ref.has("zone"):
			return str(ref.get("zone", "")) == "hand"
		if str(ref.get("kind", "")) == "attachment":
			return false
	# Older ChoiceView producers omitted zone for hand-card choices.
	return true


func _choice_energy_card_id(presentation: Dictionary, catalog: CardCatalog) -> String:
	for value in presentation.get("card_ids", []):
		var card_id := str(value)
		if catalog.is_energy(card_id):
			return card_id
	var card_id := str(presentation.get("card_id", ""))
	if catalog.is_energy(card_id):
		return card_id
	return ""


func _card_keep_value(
	state: GameState,
	actor: int,
	card_id: String,
	deck_key: String,
	catalog: CardCatalog,
	removing_one: bool = false,
) -> float:
	if card_id.is_empty():
		return 0.0
	var player := state.get_player(actor)
	var value := _card_priority(card_id, deck_key, catalog)
	if catalog.is_pokemon(card_id):
		value += int(catalog.get_card(card_id).get("hp", 0)) * 0.25
		# With no benched Pokemon, a legal Basic is immediate survival material:
		# losing the lone Active would otherwise end the game before a stranded
		# evolution card can matter.  Keep this in the trusted generic scorer so
		# every deck strategy and simulated search choice agrees on the priority.
		if (
			catalog.is_basic_pokemon(card_id)
			and player.active != null
			and player.bench_count() == 0
		):
			value += _lone_active_backup_search_bonus(state, actor, catalog)
		if _semantic_v2_enabled():
			value += _core_evolution_line_card_bonus(
				state, actor, card_id, deck_key, catalog, removing_one)
	if catalog.is_energy(card_id):
		if _has_energy_target_with_missing_cost(state, actor, catalog):
			value += 50.0
		# Multi-card costs are evaluated against a virtually shrinking hand.  Once
		# only one Energy that can advance a public attack remains, discarding it
		# would often turn a playable attacker into a dead board (notably Ultra
		# Ball with two Special Energy in the Colorless deck).
		if (
			removing_one
			and _energy_card_improves_attack_readiness(
				state, actor, card_id, catalog)
			and _helpful_hand_energy_count(state, actor, catalog) <= 1
		):
			value += float(SCORE_WEIGHTS["last_useful_energy"])
	if catalog.is_trainer(card_id):
		value += 18.0
		if _semantic_v2_enabled():
			value += _bench_setup_search_card_bonus(state, actor, card_id, deck_key, catalog)
	var duplicate_count := 0
	for hand_card_id in player.hand:
		if hand_card_id == card_id:
			duplicate_count += 1
	var remaining_duplicates := maxi(
		0, duplicate_count - (1 if removing_one else 0))
	if (
		remaining_duplicates >= 1
		and catalog.is_pokemon(card_id)
		and (
			AIDeckProfiles.contains(deck_key, "core", card_id)
			or AIDeckProfiles.contains(deck_key, "evolution", card_id)
		)
	):
		value -= min(120.0, float(remaining_duplicates) * 45.0)
	elif removing_one and remaining_duplicates >= 1:
		# A hand-discard decision values the marginal copy.  Once another copy
		# remains public in hand, a secondary engine/basic must not retain the
		# full one-of search premium (notably Psychic discard-damage fuel).
		value -= min(90.0, float(remaining_duplicates) * 60.0)
	elif remaining_duplicates >= 2:
		value -= min(90.0, float(remaining_duplicates - 1) * 35.0)
	return value


func _lone_active_backup_search_bonus(
	state: GameState,
	actor: int,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	if player.active == null or player.bench_count() > 0:
		return 0.0
	var opponent := state.get_player(1 - actor)
	if opponent.active == null:
		return 80.0
	var active_hp := player.active.current_hp(catalog)
	var ready_damage := _best_available_damage(state, 1 - actor, catalog)
	var next_attack_damage := _best_pokemon_damage(opponent.active, catalog)
	var next_attack_missing := _best_missing_energy(opponent.active, catalog)
	if (
		ready_damage >= active_hp
		or (next_attack_missing <= 1 and next_attack_damage >= active_hp)
	):
		return float(SCORE_WEIGHTS["lone_active_backup"])
	return 80.0


func _core_evolution_line_card_bonus(
	state: GameState,
	actor: int,
	card_id: String,
	deck_key: String,
	catalog: CardCatalog,
	removing_one: bool = false,
) -> float:
	if deck_key.is_empty() or not catalog.is_pokemon(card_id):
		return 0.0
	var player := state.get_player(actor)
	var best := 0.0
	for core_value in AIDeckProfiles.get_profile(deck_key).get("core", []):
		var core_id := str(core_value)
		if core_id.is_empty() or not catalog.is_pokemon(core_id):
			continue
		var parts := _core_evolution_line_parts(core_id, deck_key, catalog)
		var stage1_ids: Array[String] = []
		stage1_ids.assign(parts.get("stage1", []))
		var basic_ids: Array[String] = []
		basic_ids.assign(parts.get("basic", []))
		if stage1_ids.is_empty() and basic_ids.is_empty():
			continue
		var has_core := _player_has_any_pokemon_id_in_play(player, [core_id])
		var has_stage1 := _player_has_any_pokemon_id_in_play(player, stage1_ids)
		var has_basic := _player_has_any_pokemon_id_in_play(player, basic_ids)
		var has_rare_candy := "sv1-152" in player.hand
		var stage1_count := _player_pokemon_id_count_in_play(player, stage1_ids)
		var basic_count := _player_pokemon_id_count_in_play(player, basic_ids)
		var core_receivers := (
			stage1_count + (basic_count if has_rare_candy else 0)
			if catalog.is_stage2(core_id)
			else basic_count
		)
		var core_supply := maxi(
			0,
			player.hand.count(core_id) - (
				1 if removing_one and card_id == core_id else 0),
		)
		var bonus := 0.0
		if card_id == core_id:
			# For an ordinary keep/search score the card currently being valued is
			# still part of ``core_supply``; equality means it is the copy needed by
			# the only receiver.  During an actual hand removal it has already been
			# subtracted, so equality means the remaining copies cover every receiver.
			var core_is_surplus := (
				core_supply >= core_receivers
				if removing_one
				else core_supply > core_receivers
			)
			if core_is_surplus:
				bonus = -180.0
			elif catalog.is_stage2(core_id):
				if has_stage1:
					bonus = 170.0
				elif has_basic and has_rare_candy:
					bonus = 70.0
				elif has_basic:
					bonus = -35.0
				elif not has_core:
					bonus = -145.0
				else:
					bonus = -180.0
			elif catalog.is_stage1(core_id):
				if has_basic:
					bonus = 130.0
				elif not has_core:
					bonus = -55.0
				else:
					bonus = -120.0
		elif card_id in stage1_ids:
			var stage1_supply := maxi(
				0,
				player.hand.count(card_id) - (1 if removing_one else 0),
			)
			var stage1_is_surplus := (
				stage1_supply >= basic_count
				if removing_one
				else stage1_supply > basic_count
			)
			if stage1_is_surplus:
				bonus = -120.0
			elif has_basic:
				bonus = 145.0
			elif not has_stage1 and not has_core:
				bonus = 25.0
		elif card_id in basic_ids:
			var basic_supply_after_removal := maxi(
				0,
				player.hand.count(card_id) - (1 if removing_one else 0),
			)
			if (
				removing_one
				and basic_supply_after_removal >= 1
				and not has_basic
				and not has_stage1
				and not has_core
			):
				bonus = -80.0
			elif not has_basic and not has_stage1 and not has_core:
				bonus = 155.0
			elif has_basic and not has_stage1 and not has_core:
				bonus = 55.0
		if catalog.is_stage2(core_id):
			bonus *= 1.15
		if catalog.prize_value(core_id) >= 2:
			bonus *= 1.1
		bonus *= _core_line_focus_multiplier(state, actor, core_id, deck_key, catalog)
		if absf(bonus) > absf(best):
			best = bonus
	return best


func _discard_choice_score(
	state: GameState,
	actor: int,
	card_id: String,
	deck_key: String,
	catalog: CardCatalog,
	removing_from_hand: bool = true,
) -> float:
	var player := state.get_player(actor)
	var keep_value := _card_keep_value(
		state, actor, card_id, deck_key, catalog, removing_from_hand)
	var score := -keep_value
	if removing_from_hand:
		var duplicate_count := 0
		for hand_card_id in player.hand:
			if hand_card_id == card_id:
				duplicate_count += 1
		if duplicate_count > 1:
			score += min(120.0, float(duplicate_count - 1) * 55.0)
		if catalog.is_energy(card_id) and player.energy_attached_this_turn:
			score += 35.0
		if (
			catalog.is_trainer(card_id)
			and player.supporter_played_this_turn
			and catalog.is_supporter(card_id)
		):
			score += 30.0
	if _semantic_v2_enabled() and _discard_fuels_damage_plan(state, actor, card_id, catalog):
		score += float(SCORE_WEIGHTS["discard_fuel"])
	return score


func _core_evolution_line_parts(
	core_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> Dictionary:
	var cache_key := "%s|%s" % [deck_key, core_id]
	if _core_evolution_line_cache.has(cache_key):
		return Dictionary(_core_evolution_line_cache[cache_key]).duplicate(true)
	var stage1_ids: Array[String] = []
	var basic_ids: Array[String] = []
	if catalog.is_stage2(core_id):
		stage1_ids = _pre_evolution_ids(core_id, deck_key, catalog)
		for stage1_id in stage1_ids:
			for basic_id in _pre_evolution_ids(stage1_id, deck_key, catalog):
				if basic_id not in basic_ids:
					basic_ids.append(basic_id)
	elif catalog.is_stage1(core_id):
		basic_ids = _pre_evolution_ids(core_id, deck_key, catalog)
	var result := {
		"stage1": stage1_ids,
		"basic": basic_ids,
	}
	_core_evolution_line_cache[cache_key] = result.duplicate(true)
	return result


func _pre_evolution_ids(
	card_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> Array[String]:
	var cache_key := "%s|%s" % [deck_key, card_id]
	if _pre_evolution_ids_cache.has(cache_key):
		var cached_result: Array[String] = []
		cached_result.assign(_pre_evolution_ids_cache[cache_key])
		return cached_result
	var previous_name := str(catalog.get_card(card_id).get("evolves_from", ""))
	var result: Array[String] = []
	if previous_name.is_empty() or deck_key.is_empty():
		_pre_evolution_ids_cache[cache_key] = result.duplicate()
		return result
	for candidate_id in catalog.expand_deck(deck_key):
		if candidate_id in result:
			continue
		if catalog.is_pokemon(candidate_id) and catalog.card_name(candidate_id) == previous_name:
			result.append(candidate_id)
	_pre_evolution_ids_cache[cache_key] = result.duplicate()
	return result


func _player_has_any_pokemon_id_in_play(player: PlayerState, card_ids: Array[String]) -> bool:
	if card_ids.is_empty():
		return false
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon != null and pokemon.card_id in card_ids:
			return true
	return false


func _player_pokemon_id_count_in_play(
	player: PlayerState,
	card_ids: Array[String],
) -> int:
	var result := 0
	if card_ids.is_empty():
		return result
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon != null and pokemon.card_id in card_ids:
			result += 1
	return result


func _player_has_any_pokemon_id_available(
	player: PlayerState,
	card_ids: Array[String],
) -> bool:
	if card_ids.is_empty():
		return false
	if _player_has_any_pokemon_id_in_play(player, card_ids):
		return true
	return _zone_has_any_card_id(player.hand, card_ids) or _zone_has_any_card_id(player.deck, card_ids)


func _core_line_focus_multiplier(
	state: GameState,
	actor: int,
	core_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var primary_core_id := _primary_core_line_card_id(deck_key, catalog)
	if primary_core_id.is_empty() or core_id == primary_core_id:
		return 1.0
	var player := state.get_player(actor)
	if _player_has_any_pokemon_id_in_play(player, [primary_core_id]):
		return 0.72
	var primary_parts := _core_evolution_line_parts(primary_core_id, deck_key, catalog)
	var primary_ids: Array[String] = [primary_core_id]
	var primary_stage1_ids: Array[String] = []
	primary_stage1_ids.assign(primary_parts.get("stage1", []))
	var primary_basic_ids: Array[String] = []
	primary_basic_ids.assign(primary_parts.get("basic", []))
	primary_ids.append_array(primary_stage1_ids)
	primary_ids.append_array(primary_basic_ids)
	if _player_has_any_pokemon_id_available(player, primary_ids):
		return 0.42
	return 0.65


func _primary_core_line_card_id(deck_key: String, catalog: CardCatalog) -> String:
	for core_value in AIDeckProfiles.get_profile(deck_key).get("core", []):
		var core_id := str(core_value)
		if core_id.is_empty() or not catalog.is_pokemon(core_id):
			continue
		var parts := _core_evolution_line_parts(core_id, deck_key, catalog)
		var stage1_ids: Array = parts.get("stage1", [])
		var basic_ids: Array = parts.get("basic", [])
		if not stage1_ids.is_empty() or not basic_ids.is_empty():
			return core_id
	return ""


func _primary_core_line_ids(deck_key: String, catalog: CardCatalog) -> Array[String]:
	var primary_core_id := _primary_core_line_card_id(deck_key, catalog)
	var result: Array[String] = []
	if primary_core_id.is_empty() or not catalog.is_pokemon(primary_core_id):
		return result
	result.append(primary_core_id)
	var primary_parts := _core_evolution_line_parts(primary_core_id, deck_key, catalog)
	var stage1_ids: Array[String] = []
	stage1_ids.assign(primary_parts.get("stage1", []))
	var basic_ids: Array[String] = []
	basic_ids.assign(primary_parts.get("basic", []))
	result.append_array(stage1_ids)
	result.append_array(basic_ids)
	return result


func _card_is_secondary_core(card_id: String, deck_key: String, catalog: CardCatalog) -> bool:
	var primary_core_id := _primary_core_line_card_id(deck_key, catalog)
	if primary_core_id.is_empty() or card_id == primary_core_id:
		return false
	var core_values: Array = AIDeckProfiles.get_profile(deck_key).get("core", [])
	return core_values.find(card_id) >= 0


func _bench_setup_search_card_bonus(
	state: GameState,
	actor: int,
	card_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	if player.bench_count() >= 3:
		return 0.0
	var finds_basic_to_bench := false
	for effect in _flatten_effects(catalog.get_card(card_id).get("trainer_effects", [])):
		if str(effect.get("effect_type", "")) != "search":
			continue
		var params: Dictionary = effect.get("params", {})
		if (
			str(params.get("destination", "")) == "bench"
			and str(params.get("filter", "")) == "basic_pokemon"
		):
			finds_basic_to_bench = true
			break
	if not finds_basic_to_bench:
		return 0.0
	var basic_outs := 0
	for deck_card_id in player.deck:
		if catalog.is_basic_pokemon(deck_card_id):
			basic_outs += 1
	if basic_outs <= 0:
		return 0.0
	var value: float = 55.0 + min(80.0, basic_outs * 10.0)
	if player.bench_count() == 0:
		value += 150.0
	elif player.bench_count() == 1:
		value += 75.0
	if player.active != null:
		var opponent_damage := _best_available_damage(state, 1 - actor, catalog)
		if opponent_damage >= player.active.current_hp(catalog):
			value += 95.0
	if _has_core_basic_out_in_deck(player, deck_key, catalog):
		value += 55.0
	return value


func _has_core_basic_out_in_deck(
	player: PlayerState,
	deck_key: String,
	catalog: CardCatalog,
) -> bool:
	if deck_key.is_empty():
		return false
	for deck_card_id in player.deck:
		if not catalog.is_basic_pokemon(deck_card_id):
			continue
		if (
			AIDeckProfiles.contains(deck_key, "setup", deck_card_id)
			or AIDeckProfiles.contains(deck_key, "bench", deck_card_id)
			or AIDeckProfiles.contains(deck_key, "core", deck_card_id)
		):
			return true
	return false


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
	var power_before := _high_impact_missing_energy(state, actor, pokemon, "", catalog)
	var power_after := (
		_high_impact_missing_energy(state, actor, pokemon, energy_card_id, catalog)
		if not energy_card_id.is_empty() and catalog.is_energy(energy_card_id)
		else power_before
	)
	var power_progress: int = max(0, power_before - power_after)
	var damage_ceiling := _best_pokemon_damage_for_state(
		state, actor, pokemon, catalog)
	var ready_damage_after := _best_ready_pokemon_damage_with_extra(
		state, actor, pokemon, energy_card_id, catalog)
	var high_impact_floor := AIDeckProfiles.high_impact_damage_floor(deck_key)
	var value := progress * 85.0
	if before > 0 and after == 0:
		value += (
			55.0
			if ready_damage_after <= 0 and power_after > 0
			else 155.0 + damage_ceiling * 0.25
		)
	elif before > 1 and after == 1:
		value += 65.0
	if damage_ceiling >= high_impact_floor and power_progress > 0:
		value += power_progress * 105.0
		if power_after == 0:
			value += 165.0 + damage_ceiling * 0.25
		elif power_after == 1:
			value += 115.0
	if AIDeckProfiles.contains(deck_key, "core", pokemon.card_id):
		value += 65.0
	value += _energy_plan_target_bonus(state, actor, slot, energy_card_id, deck_key, catalog)
	if before == 0 and progress == 0 and power_progress == 0:
		value -= 60.0
	if slot == "active":
		value += 28.0
	return value


func _energy_source_choice_value(
	state: GameState,
	actor: int,
	slot: String,
	presentation: Dictionary,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var pokemon := state.get_player(actor).get_pokemon(slot)
	if pokemon == null:
		return -INF
	var energy_type := str(presentation.get("energy_type", "any"))
	var energy_index := _matching_energy_index_for_type(pokemon, energy_type, catalog)
	if energy_index < 0:
		return -INF
	var energy_id := str(pokemon.energy_card_ids[energy_index])
	var before_missing := _best_missing_energy(pokemon, catalog)
	var before_high_impact := _high_impact_missing_energy(
		state, actor, pokemon, "", catalog)
	var before_ready_damage := _best_ready_pokemon_damage(state, actor, pokemon, catalog)
	var damage_ceiling := _best_pokemon_damage_for_state(
		state, actor, pokemon, catalog)
	pokemon.energy_card_ids.remove_at(energy_index)
	var after_missing := _best_missing_energy(pokemon, catalog)
	var after_high_impact := _high_impact_missing_energy(
		state, actor, pokemon, "", catalog)
	var after_ready_damage := _best_ready_pokemon_damage(
		state, actor, pokemon, catalog)
	pokemon.energy_card_ids.insert(energy_index, energy_id)

	var cost := 0.0
	if before_missing == 0 and after_missing > 0:
		cost += 220.0 + max(before_ready_damage, damage_ceiling) * 0.45
	elif after_missing > before_missing:
		cost += float(after_missing - before_missing) * 95.0
	var high_impact_floor := AIDeckProfiles.high_impact_damage_floor(deck_key)
	if (
		damage_ceiling >= high_impact_floor
		and before_high_impact == 0
		and after_high_impact > 0
	):
		cost += 190.0 + damage_ceiling * 0.35
	elif after_high_impact > before_high_impact:
		cost += float(after_high_impact - before_high_impact) * 70.0
	# Some attacks (notably Lucario's Continuous Aura Sphere) remain legally
	# usable after moving an Energy but lose a full damage tier.  Missing-cost
	# checks alone therefore cannot identify the attachment as valuable.
	cost += float(maxi(0, before_ready_damage - after_ready_damage)) * 0.55
	if slot == "active":
		cost += 80.0
		if before_ready_damage > 0:
			cost += 60.0 + before_ready_damage * 0.35
		var max_hp := int(catalog.get_card(pokemon.card_id).get("hp", 0))
		if pokemon.current_hp(catalog) <= max(40, max_hp * 0.35):
			cost -= 60.0
	if AIDeckProfiles.contains(deck_key, "core", pokemon.card_id):
		cost += 65.0
	if (
		AIDeckProfiles.contains(deck_key, "engine", pokemon.card_id)
		and not AIDeckProfiles.contains(deck_key, "core", pokemon.card_id)
	):
		cost -= 35.0
	if (
		_effective_energy_unit_count(pokemon, catalog) >= 3
		and after_missing == 0
		and after_ready_damage >= before_ready_damage
	):
		cost -= 100.0
	elif before_missing >= 2 and before_high_impact >= 2:
		cost -= 45.0
	return -cost


func _matching_energy_index_for_type(
	pokemon: PokemonState,
	energy_type: String,
	catalog: CardCatalog,
) -> int:
	for index in range(pokemon.energy_card_ids.size()):
		if _energy_card_matches_type(
			str(pokemon.energy_card_ids[index]),
			energy_type,
			catalog,
			pokemon.energy_card_ids,
			index,
		):
			return index
	return -1


func _energy_plan_target_bonus(
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
	var card := catalog.get_card(pokemon.card_id)
	var bonus := 0.0
	if AIDeckProfiles.contains(deck_key, "core", pokemon.card_id):
		bonus += 95.0
	if (
		AIDeckProfiles.contains(deck_key, "evolution", pokemon.card_id)
		or not pokemon.evolution_stack_ids.is_empty()
	):
		bonus += 45.0
	if (
		AIDeckProfiles.contains(deck_key, "engine", pokemon.card_id)
		and not AIDeckProfiles.contains(deck_key, "core", pokemon.card_id)
	):
		bonus += 22.0
		if not pokemon.energy_card_ids.is_empty():
			bonus -= 55.0 * pokemon.energy_card_ids.size()
		if (
			_best_pokemon_damage_for_state(state, actor, pokemon, catalog)
			< AIDeckProfiles.high_impact_damage_floor(deck_key)
		):
			bonus -= 25.0
	if slot != "active" and AIDeckProfiles.contains(deck_key, "bench", pokemon.card_id):
		bonus += 34.0
	if "ex" in card.get("subtypes", []):
		bonus += 45.0
	var damage_ceiling := _best_pokemon_damage_for_state(
		state, actor, pokemon, catalog)
	bonus += min(120.0, damage_ceiling * 0.35)
	var missing := _best_missing_energy(pokemon, catalog)
	var high_impact_missing := _high_impact_missing_energy(
		state, actor, pokemon, "", catalog)
	var high_impact_after := (
		_high_impact_missing_energy(
			state, actor, pokemon, energy_card_id, catalog)
		if not energy_card_id.is_empty() and catalog.is_energy(energy_card_id)
		else high_impact_missing
	)
	var high_impact_progress: int = max(0, high_impact_missing - high_impact_after)
	var high_impact_floor := AIDeckProfiles.high_impact_damage_floor(deck_key)
	if damage_ceiling >= high_impact_floor and high_impact_progress > 0:
		bonus += high_impact_progress * 110.0
		if high_impact_after == 0:
			bonus += 170.0 + damage_ceiling * 0.25
		elif high_impact_after == 1:
			bonus += 125.0
		if slot != "active" and AIDeckProfiles.contains(deck_key, "core", pokemon.card_id):
			bonus += 75.0
	if missing == 0:
		bonus += 35.0
	elif missing == 1:
		bonus += 25.0
	elif missing <= 3 and damage_ceiling >= high_impact_floor:
		bonus += 30.0
	var max_hp := int(card.get("hp", 0))
	if (
		slot == "active"
		and pokemon.current_hp(catalog) <= max(40, max_hp * 0.35)
		and missing > 0
	):
		bonus -= 65.0
	if not energy_card_id.is_empty() and _energy_matches_profile(energy_card_id, deck_key, catalog):
		bonus += 18.0
	if (
		deck_key == "water"
		and pokemon.card_id == "sv2-grex"
		and _effective_energy_type_count(pokemon, "Water", catalog) >= 2
		and missing == 0
		and high_impact_progress == 0
	):
		# Both Greninja attacks are fully supplied at two Water Energy.  A third
		# attachment has no printed payoff and routinely starved the next attacker.
		bonus -= 480.0
	if (
		deck_key == "water"
		and pokemon.card_id == "sv2-keldeo"
		and state.get_player(actor).bench_count() >= 3
	):
		var keldeo_attacks: Array = card.get("attacks", [])
		if keldeo_attacks.size() > 1:
			var queue_cost: Array = Dictionary(keldeo_attacks[1]).get("cost", [])
			var queue_before := _missing_energy_count(pokemon, queue_cost, catalog)
			var queue_after := _missing_energy_count_with_extra(
				pokemon, queue_cost, energy_card_id, catalog)
			if queue_before == 1 and queue_after == 0:
				# The generic best-attack deficit is already zero once Kick Away is
				# usable.  Score Queue Power's exact W+C route instead (70/90/110
				# damage at three/four/five public Bench Pokemon).
				bonus += 190.0
	if (
		deck_key == "water"
		and slot == "active"
		and pokemon.card_id == "sv2-tatsu"
		and state.get_player(actor).bench_count() > 0
	):
		var tatsugiri_attacks: Array = card.get("attacks", [])
		if not tatsugiri_attacks.is_empty():
			var prepare_cost: Array = Dictionary(tatsugiri_attacks[0]).get("cost", [])
			var prepare_before := _missing_energy_count(
				pokemon, prepare_cost, catalog)
			var prepare_after := _missing_energy_count_with_extra(
				pokemon, prepare_cost, energy_card_id, catalog)
			if (
				prepare_before == 1
				and prepare_after == 0
				and _has_public_tatsugiri_acceleration_target(
					state, actor, catalog)
			):
				bonus += 280.0
	return bonus


func _has_public_tatsugiri_acceleration_target(
	state: GameState,
	actor: int,
	catalog: CardCatalog,
) -> bool:
	var player := state.get_player(actor)
	for pokemon_value in player.bench:
		var pokemon: PokemonState = pokemon_value
		if (
			pokemon != null
			and catalog.is_basic_pokemon(pokemon.card_id)
			and _best_missing_energy(pokemon, catalog) > 0
		):
			return true
	return false


func _has_better_bench_energy_plan(
	state: GameState,
	actor: int,
	energy_card_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> bool:
	var player := state.get_player(actor)
	if player.active == null:
		return false
	var high_impact_floor := AIDeckProfiles.high_impact_damage_floor(deck_key)
	if (
		AIDeckProfiles.contains(deck_key, "core", player.active.card_id)
		and player.active.current_hp(catalog) > max(50, int(catalog.get_card(player.active.card_id).get("hp", 0)) * 0.35)
		and _best_pokemon_damage_for_state(
			state, actor, player.active, catalog) >= high_impact_floor
	):
		return false
	var active_before := _best_missing_energy(player.active, catalog)
	var active_after := _best_missing_energy_with_extra(player.active, energy_card_id, catalog)
	var active_damage := _best_pokemon_damage_for_state(
		state, actor, player.active, catalog)
	var active_power_before := _high_impact_missing_energy(
		state, actor, player.active, "", catalog)
	var active_power_after := _high_impact_missing_energy(
		state, actor, player.active, energy_card_id, catalog)
	var active_progresses := (
		active_after < active_before
		or (
			active_damage >= high_impact_floor
			and active_power_after < active_power_before
		)
	)
	for index in range(player.bench.size()):
		var pokemon: PokemonState = player.bench[index]
		if pokemon == null:
			continue
		var before := _best_missing_energy(pokemon, catalog)
		var after := _best_missing_energy_with_extra(pokemon, energy_card_id, catalog)
		var bench_damage := _best_pokemon_damage_for_state(
			state, actor, pokemon, catalog)
		var bench_power_before := _high_impact_missing_energy(
			state, actor, pokemon, "", catalog)
		var bench_power_after := _high_impact_missing_energy(
			state, actor, pokemon, energy_card_id, catalog)
		var progresses_bench := (
			after < before
			or (
				bench_damage >= high_impact_floor
				and bench_power_after < bench_power_before
			)
		)
		if (
			progresses_bench
			and AIDeckProfiles.contains(deck_key, "core", pokemon.card_id)
			and (not active_progresses or active_damage < bench_damage)
		):
			return true
		if (
			progresses_bench
			and before > 0
			and after == 0
			and bench_damage >= max(high_impact_floor, active_damage + 40)
		):
			return true
	return false


func _target_priority(pokemon: PokemonState, catalog: CardCatalog) -> float:
	if pokemon == null:
		return -INF
	var max_hp := int(catalog.get_card(pokemon.card_id).get("hp", 0))
	return (
		catalog.prize_value(pokemon.card_id) * 160.0
		+ max(0, max_hp - pokemon.current_hp(catalog)) * 2.0
		+ _effective_energy_unit_count(pokemon, catalog) * 26.0
		+ _best_pokemon_damage(pokemon, catalog) * 0.35
		- pokemon.current_hp(catalog) * 0.45
	)


func _target_choice_value(
	state: GameState,
	request: ChoiceView,
	target_player: int,
	pokemon: PokemonState,
	slot: String,
	presentation: Dictionary,
	catalog: CardCatalog,
) -> float:
	if pokemon == null:
		return -INF
	var amount := maxi(0, int(presentation.get("amount", 0)))
	var value := _target_priority(pokemon, catalog)
	if (
		request.request_type == "select_opponent_bench"
		or str(presentation.get("purpose", "")) == "switch_opponent"
	):
		value += _switch_opponent_attack_route_bonus(
			state, request.player, target_player, pokemon, slot, catalog)
	if amount <= 0:
		return value
	var current_hp := pokemon.current_hp(catalog)
	# An advertised damage amount is public rules information.  A direct Prize
	# must dominate a merely high-value full-HP target (for example Greninja's
	# 40-damage Shuriken choosing a 40-HP Bench target over a healthy ex).
	value += float(mini(amount, current_hp)) * 2.5
	if amount >= current_hp:
		value += 900.0 + float(catalog.prize_value(pokemon.card_id)) * 420.0
		value -= float(maxi(0, amount - current_hp)) * 0.4
	if (
		str(presentation.get("purpose", "")) == "place_counters_self_ko"
		and str(presentation.get("source_card_id", "")) == "sv2-starm"
		and int(presentation.get("source_player", request.player)) == request.player
	):
		value += _starmie_torrent_target_bonus(
			state, request.player,
			str(presentation.get("source_slot", "")),
			target_player, slot, pokemon, amount, catalog)
	return value


func _switch_opponent_attack_route_bonus(
	state: GameState,
	actor: int,
	target_player: int,
	target: PokemonState,
	target_slot: String,
	catalog: CardCatalog,
) -> float:
	if target_player != 1 - actor or not target_slot.replace(":", "_").begins_with("bench_"):
		return 0.0
	var opponent := state.get_player(target_player)
	var bench_index := opponent.bench.find(target)
	if bench_index < 0 or opponent.active == null:
		return 0.0
	var original_active := opponent.active
	opponent.active = target
	opponent.bench[bench_index] = original_active
	var attacker := state.get_player(actor).active
	var damage := _best_ready_pokemon_damage(
		state, actor, attacker, catalog) if attacker != null else 0
	opponent.bench[bench_index] = target
	opponent.active = original_active
	if damage <= 0:
		return 0.0
	var hp := target.current_hp(catalog)
	if damage >= hp:
		return (
			1100.0
			+ float(catalog.prize_value(target.card_id)) * 430.0
			- float(maxi(0, damage - hp)) * 0.25
		)
	return float(mini(damage, hp)) * 1.4


func _starmie_torrent_target_bonus(
	state: GameState,
	actor: int,
	source_slot: String,
	target_player: int,
	target_slot: String,
	target: PokemonState,
	amount: int,
	catalog: CardCatalog,
) -> float:
	# The combo is same-turn only when Starmie is on the Bench and a ready Active
	# Greninja remains in play after Starmie discards itself.
	if target_player != 1 - actor or target_slot != "active":
		return 0.0
	var attacker: PokemonState = null
	var player := state.get_player(actor)
	if player.active != null and player.active.card_id == "sv2-grex":
		attacker = player.active
	elif source_slot == "active":
		for bench_pokemon in player.bench:
			if bench_pokemon != null and bench_pokemon.card_id == "sv2-grex":
				attacker = bench_pokemon
				break
	if attacker == null:
		return 0.0
	var attacks: Array = catalog.get_card(attacker.card_id).get("attacks", [])
	if attacks.size() <= 1 or _missing_energy_count(
		attacker, Dictionary(attacks[1]).get("cost", []), catalog) > 0:
		return 0.0
	var before_damage := _estimated_pokemon_attack_damage(
		state, actor, attacker, 1, catalog)
	var before_hp := target.current_hp(catalog)
	var added_counters := int(amount / 10)
	if added_counters <= 0:
		return 0.0
	target.damage_counters += added_counters
	var after_damage := _estimated_pokemon_attack_damage(
		state, actor, attacker, 1, catalog)
	var after_hp := target.current_hp(catalog)
	target.damage_counters -= added_counters
	var bonus := float(maxi(0, after_damage - before_damage)) * 3.0
	if before_damage < before_hp and after_damage >= after_hp:
		bonus += 1050.0 + float(catalog.prize_value(target.card_id)) * 360.0
	return bonus


func _confirm_choice(
	state: GameState,
	request: ChoiceView,
	presentation: Dictionary,
	deck_key: String,
	catalog: CardCatalog,
) -> bool:
	var purpose := str(presentation.get("purpose", ""))
	if purpose == "trekking_shoes" or not str(
		presentation.get("top_card_id", "")).is_empty():
		var top_card_id := str(presentation.get(
			"top_card_id", presentation.get("card_id", "")))
		if top_card_id.is_empty() and not state.get_player(request.player).deck.is_empty():
			top_card_id = state.get_player(request.player).deck[-1]
		return _should_keep_top_deck_card(state, request.player, top_card_id, deck_key, catalog)
	if purpose == "confirm_switch":
		var chooser := int(presentation.get("source_player", request.player))
		var target_player := int(presentation.get("target_player", request.player))
		if target_player == chooser:
			return _switch_self_has_good_target(state, chooser, deck_key, catalog)
		return _switch_opponent_has_good_target(state, chooser, target_player, catalog)
	if purpose == "switch":
		return _switch_self_has_good_target(state, request.player, deck_key, catalog)
	if purpose == "heal":
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


func _validated_or_fallback_action(
	state: GameState,
	actor: int,
	preferred: GameAction,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	profile: Dictionary = {},
) -> GameAction:
	if (
		preferred != null
		and preferred.action == "DECLARE_ATTACK"
		and _action_immediately_loses_match(
			state, actor, preferred, deck_key, catalog, engine, seed + 3)
	):
		# A losing attack does not imply that every attack is losing.  Prefer a
		# deterministic safe attack before giving up tempo to development or END.
		# This matters for attackers such as Thundurus whose high-damage attack can
		# self-KO while their cheaper attack remains a safe prize-neutral line.
		var safe_alternative_attack := _best_productive_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 4, profile)
		if safe_alternative_attack != null:
			return safe_alternative_attack
		var escape := _best_immediate_loss_escape_action(
			state,
			actor,
			actions,
			deck_key,
			catalog,
			engine,
			seed + 5,
			preferred,
			profile,
		)
		if escape != null:
			return escape
	if (
		preferred != null
		and preferred.action == "ATTACH_ENERGY"
		and _switching_energy_regresses_current_attack(
			state, actor, preferred, deck_key, catalog, engine, seed + 7)
	):
		var retained_attack := _best_productive_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 9, profile)
		if retained_attack != null:
			return retained_attack
		var retained_development := _best_productive_nonterminal_action(
			state,
			actor,
			actions,
			deck_key,
			catalog,
			engine,
			seed + 10,
			preferred,
			profile,
		)
		if retained_development != null:
			return retained_development
	var ko_attack := _best_immediate_ko_attack(
		state, actor, actions, deck_key, catalog, engine, seed, profile)
	if ko_attack != null and _should_override_with_ko(preferred, ko_attack, state, actor, catalog):
		return ko_attack

	if preferred.action == "DECLARE_ATTACK":
		if (
			_attack_draw_pressure_is_unsafe(state, actor, preferred, catalog)
			or _attack_feeds_dangerous_retaliation(state, actor, preferred, catalog)
			or _attack_squanders_only_fire_energy(
				state, actor, preferred, deck_key, catalog)
		):
			var safe_attack := _best_productive_attack(
				state, actor, actions, deck_key, catalog, engine, seed + 11, profile)
			if safe_attack != null:
				return safe_attack
			var safe_development := _best_productive_nonterminal_action(
				state, actor, actions, deck_key, catalog, engine, seed + 12, preferred, profile)
			if safe_development != null:
				return safe_development
			var end_turn := _find_action(actions, "END_TURN")
			if end_turn != null and _action_executes_successfully(
				state, actor, end_turn, deck_key, catalog, engine, seed + 13, profile):
				return end_turn
		var pre_attack := _best_pre_attack_development_action(
			state, actor, preferred, actions, deck_key, catalog, engine, seed + 17, profile)
		if pre_attack != null:
			return pre_attack

	if _should_avoid_repeating_ability(state, actor, preferred, catalog):
		var follow_up_attack := _best_productive_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 14, profile)
		if follow_up_attack != null:
			return follow_up_attack
		var follow_up_development := _best_productive_nonterminal_action(
			state, actor, actions, deck_key, catalog, engine, seed + 15, preferred, profile)
		if follow_up_development != null:
			return follow_up_development
		var follow_up_end_turn := _find_action(actions, "END_TURN")
		if follow_up_end_turn != null:
			return follow_up_end_turn

	if preferred.action == "RETREAT":
		var retreat_idx := int(preferred.params.get("bench_idx", -1))
		if not _retreat_has_good_target(state, actor, retreat_idx, deck_key, catalog):
			var retained_attack := _best_productive_attack(
				state, actor, actions, deck_key, catalog, engine, seed + 18, profile)
			if retained_attack != null:
				return retained_attack
			var safe_development := _best_productive_nonterminal_action(
				state, actor, actions, deck_key, catalog, engine, seed + 19, preferred, profile)
			if safe_development != null:
				return safe_development
			var safe_end_turn := _find_action(actions, "END_TURN")
			if safe_end_turn != null and _action_executes_successfully(
				state, actor, safe_end_turn, deck_key, catalog, engine, seed + 20, profile):
				return safe_end_turn

	if preferred.action in ["RETREAT", "END_TURN"]:
		var development := _best_productive_nonterminal_action(
			state, actor, actions, deck_key, catalog, engine, seed + 19, preferred, profile)
		if development != null:
			return development

	if preferred.action == "PLAY_TRAINER" and _is_major_hand_refresh_action(state, actor, preferred, catalog):
		var before_refresh := _best_productive_nonterminal_action(
			state, actor, actions, deck_key, catalog, engine, seed + 23, preferred, profile)
		if before_refresh != null:
			return before_refresh

	if (
		preferred.action == "PLAY_TRAINER"
		and _action_first_choice_cancelled(
			state, actor, preferred, deck_key, catalog, engine, seed + 24)
	):
		var cancelled_attack := _best_productive_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 25, profile)
		if cancelled_attack != null:
			return cancelled_attack
		var cancelled_damage := _best_damaging_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 26, profile)
		if cancelled_damage != null:
			return cancelled_damage
		var cancelled_development := _best_productive_nonterminal_action(
			state, actor, actions, deck_key, catalog, engine, seed + 27, preferred, profile)
		if cancelled_development != null:
			return cancelled_development
		var cancelled_end := _find_action(actions, "END_TURN")
		if cancelled_end != null and _action_executes_successfully(
			state, actor, cancelled_end, deck_key, catalog, engine, seed + 28, profile):
			return cancelled_end

	if (
		preferred.action in ["PLAY_TRAINER", "USE_ABILITY", "USE_STADIUM"]
		and _development_action_value(state, actor, preferred, deck_key, catalog) <= 0.0
	):
		var active_attack := _best_productive_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 25, profile)
		if active_attack != null:
			return active_attack
		var active_damage := _best_damaging_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 26, profile)
		if active_damage != null:
			return active_damage
		var active_development := _best_productive_nonterminal_action(
			state, actor, actions, deck_key, catalog, engine, seed + 27, preferred, profile)
		if active_development != null:
			return active_development
		var active_end := _find_action(actions, "END_TURN")
		if active_end != null and _action_executes_successfully(
			state, actor, active_end, deck_key, catalog, engine, seed + 28, profile):
			return active_end

	if preferred.action == "END_TURN":
		# Do not use the estimate-only fast candidate here: END_TURN is often a
		# deliberate escape from a deterministic self-KO/reactive-thorns loss.
		# The trusted helper below executes the action and applies the same
		# immediate-loss guard used at the final boundary.
		var productive_attack := _best_productive_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 29, profile)
		if productive_attack != null:
			return productive_attack
		var damaging_attack := _best_damaging_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 31, profile)
		if damaging_attack != null:
			return damaging_attack

	if _action_executes_successfully(state, actor, preferred, deck_key, catalog, engine, seed + 33, profile):
		return preferred
	for action in actions:
		if _action_executes_successfully(state, actor, action, deck_key, catalog, engine, seed + 39, profile):
			return action
	var fallback_end := _find_action(actions, "END_TURN")
	return fallback_end if fallback_end != null else actions[0]


func diagnose_decision(
	state: GameState,
	actor: int,
	selected: GameAction,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	_requested_variant: String = "",
) -> Dictionary:
	var result := {}
	for label in DIAGNOSTIC_LABELS:
		result[label] = 0
	if selected == null or actions.is_empty():
		return result

	var ko_attack := _best_immediate_ko_attack(
		state, actor, actions, deck_key, catalog, engine, seed + 101)
	# Any authoritative Basic placed onto an empty Bench is the intentional
	# survival tactic. Do not compare against whichever one the current scorer
	# ranks highest: diagnostics must remain correct after strategy/hand changes.
	var safe_pre_knockout_development := (
		AIMandatoryTactics.is_survival_backup_action(state, actor, selected)
	)
	if (
		ko_attack != null
		and not safe_pre_knockout_development
		and selected.kind == "EVOLVE"
		and selected.target != null
		and selected.target.slot.begins_with("bench_")
	):
		var diagnostic_information := AIInformationSet.capture(
			state, actor, catalog, actions, [], seed)
		if diagnostic_information.is_valid():
			var selected_candidates: Array[GameAction] = [selected]
			var safe_row := AIMandatoryTactics.safe_pre_knockout_development_action(
				diagnostic_information,
				state,
				actor,
				selected_candidates,
				ko_attack,
				engine,
				null,
				seed + 103,
				Callable(),
				0,
				2,
			)
			safe_pre_knockout_development = safe_row.get("action") != null
	if (
		ko_attack != null
		and not _diagnostic_same_action(selected, ko_attack)
		and not _selected_attack_takes_active_ko(
			state, actor, selected, deck_key, catalog, engine, seed + 102)
		and not safe_pre_knockout_development
	):
		result["missed_immediate_ko"] = 1

	if selected.action == "END_TURN":
		var productive_attack := _best_productive_attack(
			state, actor, actions, deck_key, catalog, engine, seed + 103)
		if productive_attack != null:
			result["ended_with_productive_attack"] = 1
		var productive_development := _best_productive_nonterminal_action(
			state, actor, actions, deck_key, catalog, engine, seed + 107, selected)
		if productive_development != null:
			result["ended_with_productive_development"] = 1

	if selected.action == "DECLARE_ATTACK":
		var pre_attack := _best_pre_attack_development_action(
			state, actor, selected, actions, deck_key, catalog, engine, seed + 109)
		if pre_attack != null:
			result["weak_attack_before_development"] = 1
		if _attack_draw_pressure_is_unsafe(state, actor, selected, catalog):
			result["unsafe_draw_pressure_attack"] = 1
		if _attack_feeds_dangerous_retaliation(state, actor, selected, catalog):
			result["unsafe_retaliation_attack"] = 1

	if selected.action == "RETREAT":
		var retreat_idx := int(selected.params.get("bench_idx", -1))
		if not _retreat_has_good_target(state, actor, retreat_idx, deck_key, catalog):
			result["retreat_without_good_target"] = 1

	if (
		selected.action == "PLAY_TRAINER"
		and _action_first_choice_cancelled(
			state, actor, selected, deck_key, catalog, engine, seed + 113)
	):
		result["trainer_first_choice_cancelled"] = 1

	return result


func _diagnostic_same_action(left: GameAction, right: GameAction) -> bool:
	if left == null and right == null:
		return true
	if left == null or right == null:
		return false
	return (
		left.action == right.action
		and left.actor == right.actor
		and left.params == right.params
		and (
			(left.source == null and right.source == null)
			or (
				left.source != null
				and right.source != null
				and left.source.to_dict() == right.source.to_dict()
			)
		)
		and (
			(left.target == null and right.target == null)
			or (
				left.target != null
				and right.target != null
				and left.target.to_dict() == right.target.to_dict()
			)
		)
	)


func _selected_attack_takes_active_ko(
	state: GameState,
	actor: int,
	selected: GameAction,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
) -> bool:
	if selected == null or selected.action != "DECLARE_ATTACK":
		return false
	var source_card_id := selected.source.card_id if selected.source != null else ""
	if source_card_id.is_empty() and state.get_player(actor).active != null:
		source_card_id = state.get_player(actor).active.card_id
	var attack_index := int(selected.params.get(
		"attack_idx", selected.params.get("attack_index", -1)))
	if bool(CardSemanticCatalog.new(catalog).attack_semantics(
		source_card_id, attack_index).get("has_random_effect", false)):
		return false
	return _deterministic_attack_takes_prize(
		state, actor, selected, deck_key, catalog, engine, seed)


func _deterministic_attack_takes_prize(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
) -> bool:
	if state == null or action == null or action.action != "DECLARE_ATTACK":
		return false
	var opponent := state.get_player(1 - actor)
	if opponent.active == null:
		return false
	var prizes_before := state.get_player(actor).prizes.size()
	var simulation := state.clone_state()
	simulation.set_type_matchups_enabled(false)
	var simulated_action := GameAction.from_dict(action.to_dict())
	simulated_action.actor = actor
	var rng := PortableRandomSource.new(seed)
	var step := engine.apply_action(simulation, simulated_action, rng)
	if not step.success:
		return false
	if not _resolve_choices(simulation, actor, deck_key, catalog, engine, rng):
		return false
	return (
		simulation.get_player(actor).prizes.size() < prizes_before
		or (simulation.is_terminal() and simulation.winner == actor)
	)


func _best_immediate_ko_attack(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	profile: Dictionary = {},
) -> GameAction:
	var opponent := state.get_player(1 - actor)
	if opponent.active == null:
		return null
	var best: GameAction = null
	var best_value := -INF
	var semantic_catalog := CardSemanticCatalog.new(catalog)
	for action in actions:
		if action.action != "DECLARE_ATTACK":
			continue
		var source_card_id := (
			action.source.card_id
			if action.source != null
			else ""
		)
		if (
			source_card_id.is_empty()
			and state.get_player(actor).active != null
		):
			source_card_id = state.get_player(actor).active.card_id
		var attack_index := int(action.params.get(
			"attack_idx", action.params.get("attack_index", -1)))
		# Diagnostics must not inspect the authoritative hidden deck top and call
		# a favourable reveal a provable missed KO.  Stochastic attacks are
		# evaluated by the seeded belief planner, not this certainty label.
		if bool(semantic_catalog.attack_semantics(
			source_card_id, attack_index).get("has_random_effect", false)):
			continue
		var damage := _estimated_attack_damage(
			state, actor, attack_index, catalog)
		if damage < opponent.active.current_hp(catalog):
			continue
		if _action_immediately_loses_match(
			state,
			actor,
			action,
			deck_key,
			catalog,
			engine,
			seed + attack_index * 3571,
		):
			continue
		var value := _immediate_ko_attack_value(
			state, actor, action, catalog)
		if value > best_value and _deterministic_attack_takes_prize(
			state,
			actor,
			action,
			deck_key,
			catalog,
			engine,
			seed + int(action.params.get("attack_idx", 0)) * 7919,
		):
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
	var opponent := state.get_player(1 - actor)
	if opponent.active != null and preferred_damage < opponent.active.current_hp(catalog):
		return true
	return _immediate_ko_attack_value(
		state, actor, ko_attack, catalog
	) > _immediate_ko_attack_value(state, actor, preferred, catalog) + 0.001


func _immediate_ko_attack_value(
	state: GameState,
	actor: int,
	action: GameAction,
	catalog: CardCatalog,
) -> float:
	if action == null or action.action != "DECLARE_ATTACK":
		return -INF
	var opponent := state.get_player(1 - actor)
	if opponent.active == null:
		return -INF
	var damage := _estimated_attack_damage(
		state, actor, int(action.params.get("attack_idx", -1)), catalog)
	var target_hp := opponent.active.current_hp(catalog)
	if damage < target_hp:
		return -INF
	# Every candidate here takes the same public Active Prize.  Prefer the line
	# that preserves Energy/HP and minimizes overkill instead of blindly taking
	# the attack with the largest printed number.
	return (
		float(catalog.prize_value(opponent.active.card_id)) * 1000.0
		- _attack_self_resource_cost(state, actor, action, catalog)
		- float(maxi(0, damage - target_hp)) * 0.75
	)


func _attack_self_resource_cost(
	state: GameState,
	actor: int,
	action: GameAction,
	catalog: CardCatalog,
) -> float:
	if action == null or action.action != "DECLARE_ATTACK":
		return 0.0
	var source_slot := str(action.params.get("source_slot", "active"))
	var effects := _attack_effects(
		state, actor, int(action.params.get("attack_idx", -1)), catalog)
	return (
		_expected_self_energy_discard_cost(
			state, actor, effects, source_slot, catalog)
		+ _expected_self_damage_cost(
			state, actor, effects, source_slot, catalog)
	)


func _best_pre_attack_development_action(
	state: GameState,
	actor: int,
	attack_action: GameAction,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	profile: Dictionary = {},
) -> GameAction:
	if attack_action.action != "DECLARE_ATTACK":
		return null
	var opponent := state.get_player(1 - actor)
	var damage := _estimated_attack_damage(
		state, actor, int(attack_action.params.get("attack_idx", -1)), catalog)
	if opponent.active != null and damage >= opponent.active.current_hp(catalog):
		return null
	var monotonic_development := _best_monotonic_pre_attack_development_action(
		state,
		actor,
		attack_action,
		actions,
		deck_key,
		catalog,
		engine,
		seed + 500009,
		profile,
	)
	if monotonic_development != null:
		return monotonic_development
	var active_missing := _best_missing_energy(state.get_player(actor).active, catalog)
	var is_weak := damage < 80 or (opponent.active != null and damage < opponent.active.current_hp(catalog) * 0.45)
	if not is_weak and active_missing <= 0:
		return null
	return _best_productive_nonterminal_action(
		state, actor, actions, deck_key, catalog, engine, seed, attack_action, profile)


func _best_monotonic_pre_attack_development_action(
	state: GameState,
	actor: int,
	attack_action: GameAction,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	profile: Dictionary = {},
) -> GameAction:
	var player := state.get_player(actor)
	var best: GameAction = null
	var best_value := -INF
	for action_index in range(actions.size()):
		var action := actions[action_index]
		if action == null or action == attack_action:
			continue
		var card_id := _action_card_id(state, actor, action)
		if action.action == "PLAY_BASIC":
			if (
				action.target == null
				or not action.target.slot.begins_with("bench_")
				or player.bench_count() >= PlayerState.MAX_BENCH_SIZE - 1
				or not (
					AIDeckProfiles.contains(deck_key, "setup", card_id)
					or AIDeckProfiles.contains(deck_key, "bench", card_id)
					or AIDeckProfiles.contains(deck_key, "core", card_id)
				)
			):
				continue
		elif action.action == "EVOLVE":
			if (
				action.target == null
				or not action.target.slot.begins_with("bench_")
				or AIMandatoryTactics._card_has_on_enter_play_effect(card_id, catalog)
			):
				continue
		else:
			continue
		var simulation := state.clone_state()
		simulation.set_type_matchups_enabled(false)
		var rng := PortableRandomSource.new(seed + action_index * 7919)
		var step := engine.apply_action(simulation, action, rng)
		if (
			not step.success
			or simulation.is_terminal()
			or AIMandatoryTactics._step_has_hidden_or_random_event(step)
			or engine.query_pending_choice(simulation, 0) != null
			or engine.query_pending_choice(simulation, 1) != null
		):
			continue
		var followup_query := engine.query_legal_action_groups(simulation, actor)
		if not followup_query.success:
			continue
		var attack_still_legal := false
		for followup_action in followup_query.concrete_actions():
			if _diagnostic_same_action(followup_action, attack_action):
				attack_still_legal = true
				break
		if not attack_still_legal:
			continue
		var value := (
			_development_action_value(state, actor, action, deck_key, catalog)
			+ _action_score(state, actor, action, deck_key, catalog, profile) * 0.08
		)
		if action.action == "EVOLVE":
			value += 35.0
		if value > best_value:
			best = action
			best_value = value
	return best


func _best_productive_nonterminal_action(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	excluded: GameAction = null,
	profile: Dictionary = {},
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
		if (
			action.action == "PLAY_TRAINER"
			and _action_first_choice_cancelled(
				state, actor, action, deck_key, catalog, engine, seed + action_index * 3917)
		):
			continue
		var sim_score := _simulated_action_score(
			state, actor, action, deck_key, catalog, engine, seed + action_index * 7919, profile)
		if sim_score <= -INF / 2.0:
			continue
		var delta := sim_score - base_score
		var value := development_value + delta * 0.45 + _action_score(
			state, actor, action, deck_key, catalog, profile) * 0.04
		if action.action == "PLAY_BASIC" and state.get_player(actor).bench_count() < 2:
			value += 45.0
		if action.action == "EVOLVE":
			value += 35.0
		elif action.action == "ATTACH_ENERGY":
			value += 30.0
		var semantic_pre_attack_development := (
			_semantic_v2_enabled()
			and excluded != null
			and excluded.action == "DECLARE_ATTACK"
			and development_value >= 55.0
			and delta >= -20.0
		)
		if value < 80.0 and delta < 8.0 and not semantic_pre_attack_development:
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
	profile: Dictionary = {},
) -> GameAction:
	var best: GameAction = null
	var best_value := -INF
	for action in actions:
		if action.action != "DECLARE_ATTACK":
			continue
		if (
			_attack_draw_pressure_is_unsafe(state, actor, action, catalog)
			or _attack_feeds_dangerous_retaliation(state, actor, action, catalog)
			or _attack_squanders_only_fire_energy(
				state, actor, action, deck_key, catalog)
			or _action_immediately_loses_match(
				state, actor, action, deck_key, catalog, engine, seed + 104729)
		):
			continue
		var attack_idx := int(action.params.get("attack_idx", -1))
		var damage := _estimated_attack_damage(state, actor, attack_idx, catalog)
		var effects := _attack_effects(state, actor, attack_idx, catalog)
		var value := damage * 1.2 + _effects_tactical_value(
			state, actor, effects, "active", catalog, deck_key)
		if value <= 0.0:
			continue
		if value > best_value and _action_executes_successfully(
			state, actor, action, deck_key, catalog, engine, seed + attack_idx, profile):
			best = action
			best_value = value
	return best


func _best_productive_attack_candidate(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
) -> GameAction:
	var best: GameAction = null
	var best_value := -INF
	for action in actions:
		if action.action != "DECLARE_ATTACK":
			continue
		if (
			_attack_draw_pressure_is_unsafe(state, actor, action, catalog)
			or _attack_feeds_dangerous_retaliation(state, actor, action, catalog)
			or _attack_squanders_only_fire_energy(
				state, actor, action, deck_key, catalog)
		):
			continue
		var attack_idx := int(action.params.get("attack_idx", -1))
		var damage := _estimated_attack_damage(state, actor, attack_idx, catalog)
		var effects := _attack_effects(state, actor, attack_idx, catalog)
		var value := damage * 1.2 + _effects_tactical_value(
			state, actor, effects, "active", catalog, deck_key)
		if value <= 0.0:
			continue
		if value > best_value:
			best = action
			best_value = value
	return best


func _best_damaging_attack(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	profile: Dictionary = {},
) -> GameAction:
	var base_score := _evaluate_raw(state, actor, catalog)
	var best: GameAction = null
	var best_value := -INF
	for action in actions:
		if action.action != "DECLARE_ATTACK":
			continue
		if (
			_attack_draw_pressure_is_unsafe(state, actor, action, catalog)
			or _attack_feeds_dangerous_retaliation(state, actor, action, catalog)
			or _attack_squanders_only_fire_energy(
				state, actor, action, deck_key, catalog)
			or _action_immediately_loses_match(
				state, actor, action, deck_key, catalog, engine, seed + 130363)
		):
			continue
		var attack_idx := int(action.params.get("attack_idx", -1))
		var damage := _estimated_attack_damage(state, actor, attack_idx, catalog)
		var effect_value := _effects_tactical_value(
			state, actor, _attack_effects(state, actor, attack_idx, catalog), "active", catalog, deck_key)
		if damage <= 0 and effect_value <= 0.0:
			continue
		var sim_score := _simulated_action_score(
			state, actor, action, deck_key, catalog, engine, seed + attack_idx * 9973, profile)
		if sim_score <= -INF / 2.0:
			continue
		var value := (sim_score - base_score) + damage * 0.55 + effect_value * 0.35
		if value > best_value:
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
	profile: Dictionary = {},
) -> float:
	var score_started := _profile_start(profile)
	_profile_count(profile, "simulated_action_score_calls")
	var simulation := state.clone_state()
	var rng := PortableRandomSource.new(seed)
	var step := engine.apply_action(simulation, action, rng)
	if not step.success:
		_profile_add_elapsed(profile, "simulated_action_score_ms", score_started)
		return -INF
	if not _resolve_choices(simulation, actor, deck_key, catalog, engine, rng):
		_profile_add_elapsed(profile, "simulated_action_score_ms", score_started)
		return -INF
	var result := _evaluate_raw(simulation, actor, catalog)
	_profile_add_elapsed(profile, "simulated_action_score_ms", score_started)
	return result


func _action_executes_successfully(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	profile: Dictionary = {},
) -> bool:
	return _simulated_action_score(
		state, actor, action, deck_key, catalog, engine, seed, profile) > -INF / 2.0


func _action_first_choice_cancelled(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
) -> bool:
	var simulation := state.clone_state()
	var rng := PortableRandomSource.new(seed)
	var step := engine.apply_action(simulation, action, rng)
	if not step.success:
		return false
	var request := step.pending_choice
	if request == null or request.player != actor:
		return false
	var response := _heuristic_choice(simulation, request, deck_key, catalog)
	return response.cancelled


func _action_score(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
	profile: Dictionary = {},
) -> float:
	var score_started := _profile_start(profile)
	_profile_count(profile, "action_score_calls")
	var player := state.get_player(actor)
	var card_id := _action_card_id(state, actor, action)
	var score := _card_priority(card_id, deck_key, catalog)
	match action.action:
		"PLAY_BASIC":
			score += 180.0
			if str(action.params.get("target", "")) == "active":
				score += 200.0
				if deck_key == "water":
					if card_id == "sv2-tatsu" and actor != state.first_player_idx:
						# One attachment turns Prepare into two more Energy while
						# preserving Froakie and Staryu as Bench development.
						score += 240.0
					elif (
						card_id == "sv2-staryu"
						and "sv2-tatsu" in player.hand
						and actor != state.first_player_idx
					):
						score -= 180.0
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
				score += 40.0
			score += _development_action_value(state, actor, action, deck_key, catalog) * 0.8
		"PLAY_TRAINER":
			score += 160.0
			var trainer_development := _development_action_value(
				state, actor, action, deck_key, catalog)
			if trainer_development > 0.0:
				score += trainer_development * 0.75
			else:
				score -= 360.0
				if _semantic_v2_enabled():
					score += max(-260.0, trainer_development * 0.35)
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
					score += _effects_tactical_value(state, actor, effects, "active", catalog, deck_key)
					var opponent := state.get_opponent(actor)
					if opponent.active and damage >= opponent.active.current_hp(catalog):
						score += 900.0
					elif damage <= 30 and _effects_tactical_value(
						state, actor, effects, "active", catalog, deck_key) <= 0.0:
						score -= 260.0
					if _attack_draw_pressure_is_unsafe(state, actor, action, catalog):
						score -= 450.0
					if _attack_feeds_dangerous_retaliation(state, actor, action, catalog):
						score -= 420.0
		"END_TURN":
			score -= 220.0
	_profile_add_elapsed(profile, "action_score_ms", score_started)
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
			var damage_ceiling := _best_pokemon_damage_for_state(
				state, actor, target, catalog)
			var ready_damage_after := _best_ready_pokemon_damage_with_extra(
				state, actor, target, card_id, catalog)
			var power_before := _high_impact_missing_energy(
				state, actor, target, "", catalog)
			var power_after := _high_impact_missing_energy(
				state, actor, target, card_id, catalog)
			var power_progress: int = max(0, power_before - power_after)
			var attach_value: float = progress * 95.0
			if before > 0 and after == 0:
				attach_value += (
					65.0
					if ready_damage_after <= 0 and power_after > 0
					else 175.0 + damage_ceiling * 0.25
				)
			elif before > 1 and after == 1:
				attach_value += 70.0
			var high_impact_floor := AIDeckProfiles.high_impact_damage_floor(deck_key)
			if damage_ceiling >= high_impact_floor and power_progress > 0:
				attach_value += power_progress * 120.0
				if power_after == 0:
					attach_value += 190.0 + damage_ceiling * 0.25
				elif power_after == 1:
					attach_value += 135.0
			if AIDeckProfiles.contains(deck_key, "core", target.card_id):
				attach_value += 85.0
			attach_value += _energy_plan_target_bonus(
				state, actor, target_slot, card_id, deck_key, catalog)
			if target_slot == "active":
				attach_value += 35.0
				if before > 0:
					attach_value += 55.0
				if _has_better_bench_energy_plan(state, actor, card_id, deck_key, catalog):
					attach_value -= 135.0
			elif before > 0 and after == 0:
				attach_value += 35.0
			if _energy_matches_profile(card_id, deck_key, catalog):
				attach_value += 45.0
			if before == 0 and progress == 0 and power_progress == 0:
				attach_value -= 85.0
				if not AIDeckProfiles.contains(deck_key, "core", target.card_id):
					attach_value -= 45.0
			if target_slot == "active":
				var opponent_ready_damage := _best_deterministic_available_damage(
					state, 1 - actor, catalog)
				if opponent_ready_damage >= target.current_hp(catalog):
					var units_before := _effective_energy_unit_count(target, catalog)
					var energy_probe := target.clone_state()
					energy_probe.energy_card_ids.append(card_id)
					var units_after := _effective_energy_unit_count(
						energy_probe, catalog)
					var retreat_cost := int(catalog.get_card(
						target.card_id).get("retreat_cost", 0))
					var unlocks_attack := before > 0 and after == 0
					var unlocks_retreat := (
						units_before < retreat_cost and units_after >= retreat_cost)
					if not unlocks_attack and not unlocks_retreat:
						attach_value -= 520.0
			return attach_value
		"EVOLVE":
			var evolve_slot := str(action.params.get("slot", ""))
			var evolve_target := player.get_pokemon(evolve_slot)
			if evolve_target == null or card_id.is_empty():
				return 0.0
			var evolved_strength := _pokemon_card_strength(
				card_id, _effective_energy_unit_count(evolve_target, catalog), catalog)
			var current_strength := _pokemon_strength(evolve_target, catalog)
			var evolve_value: float = 145.0 + max(0.0, evolved_strength - current_strength) * 0.75
			if AIDeckProfiles.contains(deck_key, "core", card_id):
				evolve_value += 95.0
			if AIDeckProfiles.contains(deck_key, "evolution", card_id):
				evolve_value += 70.0
			if _semantic_v2_enabled():
				evolve_value -= _active_side_core_evolve_blocking_penalty(
					state, actor, evolve_slot, evolve_target, card_id, deck_key, catalog)
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
			var trainer_value := _effects_tactical_value(
				state, actor, effects, "active", catalog, deck_key)
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
					var tactical_value := 65.0 + _effects_tactical_value(
						state, actor, ability.get("effects", []), slot, catalog, deck_key)
					if pokemon.card_id == "sv2-starm":
						tactical_value += _starmie_torrent_followup_value(
							state, actor, slot, catalog)
					return tactical_value
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
				deck_key,
			)
	return 0.0


func _starmie_torrent_followup_value(
	state: GameState,
	actor: int,
	source_slot: String,
	catalog: CardCatalog,
) -> float:
	var opponent := state.get_player(1 - actor)
	if opponent.active == null:
		return 0.0
	return _starmie_torrent_target_bonus(
		state,
		actor,
		source_slot,
		1 - actor,
		"active",
		opponent.active,
		20,
		catalog,
	)


func _active_side_core_evolve_blocking_penalty(
	state: GameState,
	actor: int,
	evolve_slot: String,
	evolve_target: PokemonState,
	evolved_card_id: String,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	if evolve_slot != "active" or evolve_target == null:
		return 0.0
	if not _card_is_secondary_core(evolved_card_id, deck_key, catalog):
		return 0.0
	var evolved_probe := evolve_target.clone_state()
	evolved_probe.evolution_stack_ids.append(evolve_target.card_id)
	evolved_probe.card_id = evolved_card_id
	var evolved_ready_damage := _best_ready_pokemon_damage(
		state, actor, evolved_probe, catalog)
	if evolved_ready_damage >= AIDeckProfiles.high_impact_damage_floor(deck_key):
		return 0.0
	var before_retreat := int(catalog.get_card(evolve_target.card_id).get("retreat_cost", 0))
	var after_retreat := int(catalog.get_card(evolved_card_id).get("retreat_cost", 0))
	var attached_energy := _effective_energy_unit_count(evolve_target, catalog)
	var penalty := 0.0
	if after_retreat > before_retreat:
		penalty += 115.0 + float(after_retreat - before_retreat) * 55.0
	if after_retreat > attached_energy:
		penalty += 90.0
	var player := state.get_player(actor)
	var primary_ids := _primary_core_line_ids(deck_key, catalog)
	if _player_has_any_pokemon_id_available(player, primary_ids):
		penalty += 115.0
	for bench_pokemon in player.bench:
		if bench_pokemon == null:
			continue
		var bench_ready_damage := _best_ready_pokemon_damage(
			state, actor, bench_pokemon, catalog)
		var bench_missing := _best_missing_energy(bench_pokemon, catalog)
		if (
			bench_ready_damage >= max(80, evolved_ready_damage + 40)
			or (
				bench_pokemon.card_id in primary_ids
				and (_effective_energy_unit_count(bench_pokemon, catalog) >= 1 or bench_missing <= 1)
			)
		):
			penalty += 115.0
			break
	if after_retreat >= 2 and evolved_ready_damage <= 40:
		penalty += 70.0
	return min(430.0, penalty)


func _expected_self_energy_discard_cost(
	state: GameState,
	actor: int,
	effects: Array,
	source_slot: String,
	catalog: CardCatalog,
	probability: float = 1.0,
) -> float:
	var total := 0.0
	for effect_value in effects:
		if not effect_value is Dictionary:
			continue
		var effect: Dictionary = effect_value
		var params: Dictionary = effect.get("params", {})
		if (
			str(effect.get("effect_type", "")) == "energy_discard"
			and str(params.get("from", "opponent")) == "self"
		):
			total += probability * _self_energy_discard_cost(
				state, actor, source_slot, int(params.get("amount", 1)), catalog)
		elif str(effect.get("effect_type", "")) == "discard_fighting_energy_damage":
			total += probability * _self_fighting_energy_discard_cost(
				state, actor, source_slot, catalog)
		for branch_key in [
			"on_heads", "on_tails", "on_success", "on_fail", "on_pay", "cost",
		]:
			var branch_value: Variant = params.get(branch_key, [])
			var branch_effects: Array = []
			if branch_value is Dictionary:
				branch_effects = [branch_value]
			elif branch_value is Array:
				branch_effects = branch_value
			if branch_effects.is_empty():
				continue
			var branch_probability := probability
			if branch_key in ["on_heads", "on_tails", "on_success", "on_fail"]:
				branch_probability *= 0.5
			total += _expected_self_energy_discard_cost(
				state, actor, branch_effects, source_slot, catalog, branch_probability)
	return total


func _self_energy_discard_cost(
	state: GameState,
	actor: int,
	source_slot: String,
	requested_amount: int,
	catalog: CardCatalog,
) -> float:
	var source := state.get_player(actor).get_pokemon(source_slot)
	if source == null or source.energy_card_ids.is_empty():
		return 0.0
	var discard_count := mini(
		source.energy_card_ids.size(), maxi(0, requested_amount))
	if discard_count <= 0:
		return 0.0
	var original_energy: Array[String] = source.energy_card_ids.duplicate()
	var before_missing := _best_missing_energy(source, catalog)
	var before_ready_damage := _best_ready_pokemon_damage(
		state, actor, source, catalog)
	var kept_energy: Array[String] = []
	kept_energy.assign(original_energy.slice(
		0, original_energy.size() - discard_count))
	source.energy_card_ids.assign(kept_energy)
	var after_missing := _best_missing_energy(source, catalog)
	var after_ready_damage := _best_ready_pokemon_damage(
		state, actor, source, catalog)
	source.energy_card_ids.assign(original_energy)
	var cost := float(discard_count) * 65.0
	if discard_count >= original_energy.size():
		cost += 60.0
	cost += float(maxi(0, after_missing - before_missing)) * 55.0
	cost += float(maxi(0, before_ready_damage - after_ready_damage)) * 0.45
	return cost


func _self_fighting_energy_discard_cost(
	state: GameState,
	actor: int,
	source_slot: String,
	catalog: CardCatalog,
) -> float:
	var source := state.get_player(actor).get_pokemon(source_slot)
	if source == null or source.energy_card_ids.is_empty():
		return 0.0
	var original_energy: Array[String] = source.energy_card_ids.duplicate()
	var kept_energy: Array[String] = []
	var removed := 0
	for index in range(original_energy.size()):
		var units := EnergyView.units_for_card_at(
			original_energy, index, catalog)
		if "Fighting" in units or "Rainbow" in units:
			removed += 1
		else:
			kept_energy.append(original_energy[index])
	if removed <= 0:
		return 0.0
	var before_missing := _best_missing_energy(source, catalog)
	var before_ready_damage := _best_ready_pokemon_damage(
		state, actor, source, catalog)
	source.energy_card_ids.assign(kept_energy)
	var after_missing := _best_missing_energy(source, catalog)
	var after_ready_damage := _best_ready_pokemon_damage(
		state, actor, source, catalog)
	source.energy_card_ids.assign(original_energy)
	var cost := float(removed) * 65.0
	# The per-card cost, readiness loss, and future-damage loss below already
	# price an all-Energy discard.  A second blanket empty-board surcharge made
	# ordinary two- and three-Energy Lucario attacks look unproductive.
	cost += float(maxi(0, after_missing - before_missing)) * 55.0
	cost += float(maxi(0, before_ready_damage - after_ready_damage)) * 0.45
	return cost


func _expected_self_damage_cost(
	state: GameState,
	actor: int,
	effects: Array,
	source_slot: String,
	catalog: CardCatalog,
	probability: float = 1.0,
) -> float:
	var source := state.get_player(actor).get_pokemon(source_slot)
	var total := 0.0
	for effect_value in effects:
		if not effect_value is Dictionary:
			continue
		var effect: Dictionary = effect_value
		var params: Dictionary = effect.get("params", {})
		if str(effect.get("effect_type", "")) == "damage_counter_self":
			var amount := maxi(0, int(params.get("amount", params.get("damage", 0))))
			total += probability * float(amount) * 1.8
			if source != null and amount >= source.current_hp(catalog):
				total += probability * 1000.0
		for branch_key in ["on_heads", "on_tails", "on_success", "on_fail"]:
			var branch_value: Variant = params.get(branch_key, [])
			var branch_effects: Array = []
			if branch_value is Dictionary:
				branch_effects = [branch_value]
			elif branch_value is Array:
				branch_effects = branch_value
			if not branch_effects.is_empty():
				total += _expected_self_damage_cost(
					state, actor, branch_effects, source_slot, catalog,
					probability * 0.5)
	return total


func _effects_tactical_value(
	state: GameState,
	actor: int,
	effects: Array,
	source_slot: String,
	catalog: CardCatalog,
	deck_key: String = "",
) -> float:
	if _semantic_v2_enabled():
		return _semantic_effects_tactical_value(
			state, actor, effects, source_slot, catalog, deck_key)
	var player := state.get_player(actor)
	var opponent := state.get_player(1 - actor)
	var profile_key := deck_key
	if profile_key.is_empty():
		profile_key = _deck_key_for_actor(state, actor, "")
	var value := -_expected_self_energy_discard_cost(
		state, actor, effects, source_slot, catalog)
	for effect in _flatten_effects(effects):
		var effect_type := str(effect.get("effect_type", ""))
		var params: Dictionary = effect.get("params", {})
		match effect_type:
			"draw", "draw_until", "draw_until_more":
				var amount := int(params.get("amount", params.get("target", 2)))
				if player.deck.size() <= amount:
					value -= 260.0
				else:
					var draw_value: float = min(amount, 7) * 34.0
					if player.hand.size() >= 8:
						draw_value -= min(amount, 7) * 22.0
					elif player.hand.size() >= 6:
						draw_value -= min(amount, 7) * 10.0
					value += draw_value
					if player.hand.size() <= 3:
						value += 55.0
			"discard_draw", "shuffle_draw", "judge", "hand_to_bottom_draw", "discard_then_draw":
				var draw_count := int(params.get("draw", params.get("amount", 4)))
				if player.deck.size() <= draw_count:
					value -= 220.0
				else:
					var refresh_value: float = 95.0 + min(draw_count, 7) * 24.0
					if player.hand.size() >= 8:
						refresh_value -= 85.0
					elif player.hand.size() >= 6:
						refresh_value -= 35.0
					value += refresh_value
					if player.hand.size() <= 4:
						value += 65.0
			"search", "conditional_search_extra", "search_any_and_switch", "arven":
				value += 125.0
				if player.bench_count() < 2:
					value += 35.0
			"houb":
				value += _semantic_houb_value(
					state, actor, int(params.get("target_hand_size", 5)), profile_key, catalog)
			"look_top_deck":
				value += _semantic_look_top_deck_value(
					state, actor, params, profile_key, catalog)
			"clara":
				value += _clara_recovery_value(state, actor, profile_key, catalog)
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
				if str(params.get("from", "opponent")) != "self":
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


func _semantic_effects_tactical_value(
	state: GameState,
	actor: int,
	effects: Array,
	source_slot: String,
	catalog: CardCatalog,
	deck_key: String = "",
) -> float:
	var profile_key := deck_key
	if profile_key.is_empty():
		profile_key = _deck_key_for_actor(state, actor, "")
	var value := -_expected_self_energy_discard_cost(
		state, actor, effects, source_slot, catalog)
	for effect in _flatten_effects(effects):
		var effect_type := str(effect.get("effect_type", ""))
		var params: Dictionary = effect.get("params", {})
		match effect_type:
			"draw", "draw_until", "draw_until_more":
				value += _semantic_draw_value(
					state, actor, int(params.get("amount", params.get("target", 2))), false, profile_key, catalog)
			"discard_draw", "shuffle_draw", "judge", "hand_to_bottom_draw", "discard_then_draw":
				value += _semantic_draw_value(
					state, actor, int(params.get("draw", params.get("amount", 4))), true, profile_key, catalog)
			"search", "conditional_search_extra", "search_any_and_switch", "arven":
				value += _semantic_search_value(state, actor, params, profile_key, catalog)
			"houb":
				value += _semantic_houb_value(
					state, actor, int(params.get("target_hand_size", 5)), profile_key, catalog)
			"look_top_deck":
				value += _semantic_look_top_deck_value(
					state, actor, params, profile_key, catalog)
			"clara":
				value += _clara_recovery_value(state, actor, profile_key, catalog)
			"energy_attach", "draw_and_attach_energy", "attach_from_discard", "look_top_attach_energy":
				value += _semantic_energy_accel_value(state, actor, profile_key, catalog)
			"energy_relocate":
				value += _energy_relocate_value(state, actor, params, catalog)
			"heal", "heal_all", "potion_heal", "conditional_damage_heal", "damage_and_self_heal":
				value += _semantic_healing_value(state, actor, catalog)
			"switch_self":
				value += _semantic_switch_self_value(state, actor, profile_key, catalog)
			"switch_opponent":
				value += _semantic_switch_opponent_value(state, actor, catalog)
			"energy_discard", "coin_flip_energy_discard":
				if str(params.get("from", "opponent")) != "self":
					value += _semantic_energy_disruption_value(state, actor, catalog)
			"discard", "discard_hand_conditional_bonus":
				value += _semantic_hand_disruption_value(state, actor)
			"prevent_damage", "prevent_all", "prevent_effects":
				value += _semantic_protection_effect_value(state, actor, profile_key, catalog)
			"status", "conditional_status", "dazzling_beam", "attack_lock_basic", "apply_outgoing_damage_reduction", "self_attack_lock":
				value += _semantic_status_effect_value(state, actor, effect_type, params, catalog)
			"damage", "any_pokemon_damage", "place_counters_and_self_ko", "bench_damage", "damage_and_self_heal":
				value += _semantic_damage_effect_value(
					state, actor, effect, source_slot, catalog)
			"damage_counter_self":
				value -= int(params.get("amount", params.get("damage", 20))) * 1.0
			"attack_damage_formula", "conditional_damage_bonus", "discard_fighting_energy_damage", "discard_hand_conditional_bonus":
				value += _semantic_damage_effect_value(
					state, actor, effect, source_slot, catalog)
			"shuffle_from_discard", "ability_discard_revive":
				value += 60.0 + _resource_outs_value(state, actor, profile_key, catalog) * 0.35
			"tool", "tool_exp_share":
				value += 52.0 + _active_ko_risk_value(state, actor, profile_key, catalog) * 0.12
			"evolve_skip_stage":
				value += 145.0 + _resource_outs_value(state, actor, profile_key, catalog) * 0.35
			"return_to_hand":
				value += _semantic_return_to_hand_value(state, actor, source_slot, profile_key, catalog)
	return value


func _semantic_draw_value(
	state: GameState,
	actor: int,
	amount: int,
	refresh: bool,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	if amount <= 0:
		return 0.0
	if player.deck.size() <= amount:
		return -300.0 - (amount - player.deck.size()) * 45.0
	var draw_count: int = min(amount, 7)
	var projected_deck: int = player.deck.size() - draw_count
	var value := draw_count * float(EFFECT_VALUE_WEIGHTS["draw_card"])
	if refresh:
		value += 54.0
	var hand_plan := _hand_size_attack_plan_value(state, actor, deck_key, catalog)
	if player.hand.size() <= 3:
		value += 86.0
	elif player.hand.size() <= 5:
		value += 34.0
	elif player.hand.size() >= 8:
		if refresh:
			value -= 115.0 + draw_count * 24.0
		else:
			value -= 45.0 + draw_count * 8.0
		if hand_plan > 0.0 and not refresh:
			value += min(85.0, hand_plan * 0.38)
		elif hand_plan > 0.0:
			value += min(70.0, hand_plan * 0.30)
	elif player.hand.size() >= 6:
		value -= 25.0
		if hand_plan > 0.0:
			value += min(45.0, hand_plan * 0.22)
	if hand_plan > 0.0 and (player.hand.size() < 8 or not refresh):
		var projected_hand := player.hand.size() + draw_count
		if projected_hand >= 5:
			value += min(70.0, hand_plan * 0.25)
		elif projected_hand >= 4:
			value += min(35.0, hand_plan * 0.16)
	value += min(75.0, _deck_outs_quality(state, actor, catalog) * 0.18)
	if projected_deck <= 2:
		value -= float(SCORE_WEIGHTS["thin_deck_draw"]) + 165.0 + (3 - projected_deck) * 70.0
	elif projected_deck <= 5:
		value -= 58.0 + (6 - projected_deck) * 20.0 + max(0, draw_count - 2) * 54.0
	elif projected_deck <= 8:
		value -= 58.0 + (9 - projected_deck) * 18.0 + max(0, draw_count - 3) * 34.0
	elif projected_deck <= 12 and refresh:
		value -= 58.0 + (13 - projected_deck) * 12.0
	if refresh and player.deck.size() <= 15:
		value -= 46.0 + (16 - player.deck.size()) * 8.0
	if hand_plan > 0.0 and not refresh and draw_count <= 2 and projected_deck >= 3:
		value += min(105.0, hand_plan * 0.9)
	return value


func _semantic_houb_value(
	state: GameState,
	actor: int,
	target_hand_size: int,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	# Playing the Supporter and bottoming one additional card happen before the
	# draw-to-five effect.  When five cards already remain, Houb is pure resource
	# loss rather than a search card.
	var hand_after_cost := maxi(0, player.hand.size() - 2)
	var draw_count := maxi(0, target_hand_size - hand_after_cost)
	if draw_count <= 0:
		return -175.0 - float(maxi(0, hand_after_cost - target_hand_size)) * 28.0
	if player.deck.size() <= draw_count:
		return -280.0
	var value := float(draw_count) * float(EFFECT_VALUE_WEIGHTS["draw_card"])
	if player.hand.size() <= 3:
		value += 115.0
	elif player.hand.size() <= 5:
		value += 45.0
	value += min(55.0, _deck_outs_quality(state, actor, catalog) * 0.14)
	# Approximate the cheapest public card that must be put on the bottom.  The
	# subsequent Choice scorer still selects the exact card.
	var cheapest_keep := INF
	for card_id in player.hand:
		var effects: Array = catalog.get_card(card_id).get("trainer_effects", [])
		var is_houb := false
		for effect in _flatten_effects(effects):
			if str(effect.get("effect_type", "")) == "houb":
				is_houb = true
				break
		if is_houb:
			continue
		cheapest_keep = minf(
			cheapest_keep,
			_card_keep_value(state, actor, card_id, deck_key, catalog),
		)
	if cheapest_keep < INF:
		value -= maxf(0.0, cheapest_keep) * 0.22
	return value


func _semantic_look_top_deck_value(
	state: GameState,
	actor: int,
	params: Dictionary,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	var top_count := mini(
		maxi(0, int(params.get("count", 0))), player.deck.size())
	if top_count <= 0:
		return -160.0
	var unseen_pool := _public_unseen_deck_pool(
		state, actor, deck_key, catalog)
	if unseen_pool.is_empty():
		return -90.0
	var filter_type := str(params.get("filter", "any"))
	var hit_count := catalog.filter_cards(unseen_pool, filter_type).size()
	var expected_hits := (
		float(hit_count) * float(top_count) / float(unseen_pool.size()))
	var value := expected_hits * 52.0
	if expected_hits >= 3.0:
		value += 55.0
	elif expected_hits < 1.0:
		value -= 85.0
	if _has_energy_target_with_missing_cost(state, actor, catalog):
		value += minf(65.0, expected_hits * 12.0)
	if player.bench_count() < 2:
		value += minf(55.0, expected_hits * 10.0)
	if player.deck.size() <= 3:
		value -= 210.0
	return value


func _public_unseen_deck_pool(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> Array[String]:
	# Use the fixed public release list minus zones the actor may legally see.
	# Do not inspect the determinized deck/prize identities: exchanging a card
	# between those hidden zones must leave the estimate unchanged.
	var pool := catalog.expand_deck(deck_key)
	var player := state.get_player(actor)
	var public_cards: Array[String] = []
	public_cards.append_array(player.hand)
	public_cards.append_array(player.discard)
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		public_cards.append(pokemon.card_id)
		public_cards.append_array(pokemon.evolution_stack_ids)
		public_cards.append_array(pokemon.energy_card_ids)
		if not pokemon.attached_tool_id.is_empty():
			public_cards.append(pokemon.attached_tool_id)
	for card_id in public_cards:
		var index := pool.find(card_id)
		if index >= 0:
			pool.remove_at(index)
	return pool


func _semantic_search_value(
	state: GameState,
	actor: int,
	params: Dictionary,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	if player.deck.is_empty():
		return -90.0
	var filter_type := str(params.get("filter", params.get("filter_type", params.get("card_filter", "any"))))
	var candidates: Array[String] = catalog.filter_cards(player.deck, filter_type)
	if candidates.is_empty():
		candidates.assign(player.deck)
	var best := -INF
	for card_id in candidates:
		best = max(best, _card_keep_value(state, actor, card_id, deck_key, catalog))
	var value: float = float(EFFECT_VALUE_WEIGHTS["search_base"]) + max(0.0, best) * 0.42
	if player.bench_count() < 2:
		value += 45.0
	if _has_energy_target_with_missing_cost(state, actor, catalog):
		for card_id in candidates:
			if catalog.is_energy(card_id):
				value += 56.0
				break
	for card_id in candidates:
		if catalog.is_pokemon(card_id) and AIDeckProfiles.contains(deck_key, "evolution", card_id):
			value += 48.0
			break
	return value


func _semantic_energy_accel_value(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var best := -70.0
	for row in state.get_player(actor).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var missing := _best_missing_energy(pokemon, catalog)
		if missing >= 99:
			continue
		var damage := _best_pokemon_damage(pokemon, catalog)
		var candidate := float(EFFECT_VALUE_WEIGHTS["energy_accel_base"])
		if missing == 0:
			candidate -= 65.0
		elif missing == 1:
			candidate += 150.0 + damage * 0.22
		else:
			candidate += min(95.0, damage * 0.16)
		if str(row["slot"]) == "active":
			candidate += 32.0
		if AIDeckProfiles.contains(deck_key, "core", pokemon.card_id):
			candidate += 70.0
		best = max(best, candidate)
	return best


func _semantic_healing_value(state: GameState, actor: int, catalog: CardCatalog) -> float:
	var value := 0.0
	var opponent_damage := _best_available_damage(state, 1 - actor, catalog)
	for row in state.get_player(actor).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null or pokemon.damage_counters <= 0:
			continue
		var heal_target_value: float = min(150.0, pokemon.damage_counters * 24.0)
		if opponent_damage >= pokemon.current_hp(catalog):
			heal_target_value += 70.0
		value += heal_target_value
	return value


func _semantic_switch_self_value(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	if player.active == null or player.bench_count() <= 0:
		return -100.0
	var active_value := _promotion_value_for_state(state, actor, player.active, deck_key, catalog)
	var best_delta := -INF
	for index in range(player.bench.size()):
		var pokemon: PokemonState = player.bench[index]
		if pokemon == null:
			continue
		var delta := _promotion_value_for_state(state, actor, pokemon, deck_key, catalog) - active_value
		if _retreat_has_good_target(state, actor, index, deck_key, catalog):
			delta += float(EFFECT_VALUE_WEIGHTS["switch_base"])
		best_delta = max(best_delta, delta)
	return best_delta if best_delta > -INF / 2.0 else -100.0


func _semantic_switch_opponent_value(state: GameState, actor: int, catalog: CardCatalog) -> float:
	var opponent := state.get_player(1 - actor)
	if opponent.active == null or opponent.bench_count() <= 0:
		return -100.0
	var active_priority := _target_priority(opponent.active, catalog)
	var best_bench_priority := -INF
	for pokemon in opponent.bench:
		if pokemon:
			best_bench_priority = max(best_bench_priority, _target_priority(pokemon, catalog))
	if best_bench_priority <= -INF / 2.0:
		return -100.0
	var value := best_bench_priority - active_priority + float(EFFECT_VALUE_WEIGHTS["switch_base"])
	if _best_available_damage(state, actor, catalog) >= opponent.active.current_hp(catalog):
		value -= 120.0
	return value


func _semantic_energy_disruption_value(state: GameState, actor: int, catalog: CardCatalog) -> float:
	var opponent := state.get_player(1 - actor)
	if opponent.active == null or opponent.active.energy_card_ids.is_empty():
		return -45.0
	var before := _best_available_damage(state, 1 - actor, catalog)
	var value := (
		float(EFFECT_VALUE_WEIGHTS["disruption_base"])
		+ _effective_energy_unit_count(opponent.active, catalog) * 32.0
	)
	if state.get_player(actor).active != null and before >= state.get_player(actor).active.current_hp(catalog):
		value += 78.0
	return value


func _semantic_hand_disruption_value(state: GameState, actor: int) -> float:
	var opponent := state.get_player(1 - actor)
	var player := state.get_player(actor)
	var value: float = float(EFFECT_VALUE_WEIGHTS["disruption_base"]) + min(90.0, opponent.hand.size() * 14.0)
	if player.prizes.size() > opponent.prizes.size():
		value += 38.0
	if opponent.hand.size() <= 1:
		value -= 55.0
	return value


func _semantic_protection_effect_value(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	return (
		float(EFFECT_VALUE_WEIGHTS["protection_base"])
		+ _active_ko_risk_value(state, actor, deck_key, catalog) * 0.45
	)


func _semantic_status_effect_value(
	state: GameState,
	actor: int,
	effect_type: String,
	params: Dictionary,
	catalog: CardCatalog,
) -> float:
	var opponent := state.get_player(1 - actor)
	if opponent.active == null:
		return -30.0
	var value := float(EFFECT_VALUE_WEIGHTS["status_base"])
	var status := str(params.get("status", "")).to_upper()
	if status == "PARALYZED" or effect_type in ["attack_lock_basic", "dazzling_beam", "self_attack_lock"]:
		value += 72.0
	elif status == "ASLEEP":
		value += 34.0
	if state.get_player(actor).active != null:
		var opponent_damage := _best_available_damage(state, 1 - actor, catalog)
		if opponent_damage >= state.get_player(actor).active.current_hp(catalog):
			value += 86.0
	if not opponent.active.status_conditions.is_empty() or opponent.active.attack_is_locked():
		value -= 35.0
	return value


func _semantic_damage_effect_value(
	state: GameState,
	actor: int,
	effect: Dictionary,
	source_slot: String,
	catalog: CardCatalog,
) -> float:
	var opponent := state.get_player(1 - actor)
	var damage := _effect_damage_estimate(state, actor, effect, catalog)
	var value := damage * 1.15
	var effect_type := str(effect.get("effect_type", ""))
	if opponent.active != null and damage >= opponent.active.current_hp(catalog):
		value += 190.0 + catalog.prize_value(opponent.active.card_id) * 120.0
	elif effect_type in ["bench_damage", "any_pokemon_damage"]:
		value += _semantic_best_bench_damage_value(state, actor, damage, catalog)
	if effect_type == "place_counters_and_self_ko":
		value -= _self_ko_source_cost(state, actor, source_slot, catalog)
	return value


func _self_ko_source_cost(
	state: GameState,
	actor: int,
	source_slot: String,
	catalog: CardCatalog,
) -> float:
	var source := state.get_player(actor).get_pokemon(source_slot)
	if source == null:
		return 320.0
	var cost := 120.0 + catalog.prize_value(source.card_id) * 80.0
	# The command discards the source and every attached/evolution card.  Price
	# those public resources on the actual source slot, rather than accidentally
	# charging whichever Pokemon currently occupies the Active Spot.
	cost += _effective_energy_unit_count(source, catalog) * 45.0
	cost += source.evolution_stack_ids.size() * 30.0
	if not source.attached_tool_id.is_empty():
		cost += 35.0
	return cost


func _semantic_best_bench_damage_value(
	state: GameState,
	actor: int,
	damage: int,
	catalog: CardCatalog,
) -> float:
	var best := 0.0
	for pokemon in state.get_player(1 - actor).bench:
		if pokemon == null:
			continue
		var target_value := _target_priority(pokemon, catalog) * 0.25
		if damage >= pokemon.current_hp(catalog):
			target_value += 150.0 + catalog.prize_value(pokemon.card_id) * 95.0
		best = max(best, target_value)
	return best


func _semantic_return_to_hand_value(
	state: GameState,
	actor: int,
	source_slot: String,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var pokemon := state.get_player(actor).get_pokemon(source_slot)
	if pokemon == null:
		return 0.0
	var risk := _active_ko_risk_value(state, actor, deck_key, catalog)
	var value := risk * 0.35
	if AIDeckProfiles.contains(deck_key, "core", pokemon.card_id):
		value += 35.0
	return value


func _hand_size_attack_plan_value(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	var best := 0.0
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var card := catalog.get_card(pokemon.card_id)
		for attack in card.get("attacks", []):
			var missing := _missing_energy_count(pokemon, attack.get("cost", []), catalog)
			var readiness := 0.0
			if missing == 0:
				readiness = 1.0
			elif missing == 1:
				readiness = 0.62
			elif missing == 2:
				readiness = 0.32
			if readiness <= 0.0:
				continue
			for effect_value in _flatten_effects(attack.get("effects", [])):
				var effect: Dictionary = effect_value
				var params: Dictionary = effect.get("params", {})
				match str(effect.get("effect_type", "")):
					"damage_per_hand_size":
						var per_card: int = int(params.get("per", 0))
						var projected_damage: int = player.hand.size() * per_card
						best = max(best, min(190.0, projected_damage * 0.72 * readiness))
					"discard_hand_conditional_bonus":
						var threshold: int = int(params.get("threshold", 5))
						var base_damage: int = int(params.get("base_damage", params.get("base", 0)))
						var bonus_damage: int = int(params.get("bonus", 0))
						var gap: int = max(0, threshold - player.hand.size())
						var threshold_damage: int = base_damage + bonus_damage - gap * 34
						best = max(best, min(210.0, threshold_damage * 0.52 * readiness))
	if best <= 0.0:
		return 0.0
	if deck_key == "colorless":
		best += float(SCORE_WEIGHTS["hand_size_plan"]) * 0.35
	return best


func _discard_fuels_damage_plan(
	state: GameState,
	actor: int,
	card_id: String,
	catalog: CardCatalog,
) -> bool:
	if not catalog.is_pokemon(card_id):
		return false
	var discarded_card := catalog.get_card(card_id)
	if not ("Psychic" in discarded_card.get("energy_types", [])):
		return false
	var player := state.get_player(actor)
	var attacker_ids: Array[String] = []
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon != null:
			attacker_ids.append(pokemon.card_id)
	for zone_card_id in player.hand + player.deck + player.discard:
		if catalog.is_pokemon(zone_card_id):
			attacker_ids.append(zone_card_id)
	for attacker_id in attacker_ids:
		var attacker := catalog.get_card(attacker_id)
		for attack in attacker.get("attacks", []):
			for effect_value in _flatten_effects(attack.get("effects", [])):
				var effect: Dictionary = effect_value
				if str(effect.get("effect_type", "")) == "damage_per_discard_psychic":
					return true
	return false


func _deck_outs_quality(state: GameState, actor: int, catalog: CardCatalog) -> float:
	var deck_key := _deck_key_for_actor(state, actor, "")
	var quality := 0.0
	for card_id in state.get_player(actor).deck:
		quality += max(0.0, _card_keep_value(state, actor, card_id, deck_key, catalog))
	return quality / max(1, state.get_player(actor).deck.size())


func _clara_recovery_value(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	var positive_targets := 0
	var best_target := -INF
	for card_id in player.discard:
		if not catalog.is_pokemon(card_id) and not catalog.is_basic_energy(card_id):
			continue
		var target_value := _card_keep_value(state, actor, card_id, deck_key, catalog)
		if catalog.is_basic_energy(card_id) and not _has_energy_target_with_missing_cost(
			state, actor, catalog):
			target_value -= 70.0
		best_target = max(best_target, target_value)
		if target_value > 0.0:
			positive_targets += 1
	if positive_targets == 0:
		return -180.0
	return 70.0 + min(positive_targets, 4) * 35.0 + max(0.0, best_target) * 0.35


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
	var ignore_weakness := false
	var ignore_resistance := false
	var ignore_defender_damage_effects := false
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
			"coin_flip_triple",
			"coin_flip_until_tails",
			"coin_flip_double_ko",
		]:
			full_damage = true
		var effect_params: Dictionary = effect.get("params", {})
		# Runtime damage packets use three independent flags. Accept the old
		# compiler-boundary spellings here only so historical card data cannot
		# make the AI evaluate a different attack from the rules engine.
		var legacy_piercing := bool(effect_params.get("piercing", false))
		ignore_weakness = (
			ignore_weakness
			or bool(effect_params.get("ignore_weakness", false))
			or legacy_piercing
		)
		ignore_resistance = (
			ignore_resistance
			or bool(effect_params.get("ignore_resistance", false))
			or legacy_piercing
		)
		ignore_defender_damage_effects = (
			ignore_defender_damage_effects
			or bool(effect_params.get("ignore_defender_damage_effects", false))
			or bool(effect_params.get("ignore_defender_effects", false))
			or bool(effect_params.get("ignore_effects", false))
		)
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
		state,
		actor,
		damage,
		catalog,
		ignore_weakness,
		ignore_resistance,
		ignore_defender_damage_effects,
	)


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
				for provided in EnergyView.units_for_cards(active.energy_card_ids, catalog):
					if (
						filter.is_empty()
						or filter == "any"
						or provided.to_lower() in [filter, "rainbow"]
					):
						count += 1
			return int(params.get("base", 0)) + count * int(params.get("per_energy", 0))
		"damage_per_energy":
			var count := 0
			match str(params.get("count_from", "self")):
				"opponent_active":
					count = _effective_energy_unit_count(opponent.active, catalog)
				"all_opponent":
					for row in opponent.get_all_pokemon():
						var pokemon: PokemonState = row["pokemon"]
						if pokemon:
							count += _effective_energy_unit_count(pokemon, catalog)
				_:
					count = _effective_energy_unit_count(active, catalog)
			return int(params.get("base", 0)) + count * int(params.get("per_energy", 0))
		"damage_plus_bench":
			return int(params.get("base", 0)) + player.bench_count() * int(params.get("per_bench", 0))
		"attack_damage_formula":
			var total := int(params.get("base", 0))
			total += player.bench_count() * int(params.get("per_own_bench", 0))
			var per_self_energy_type := str(params.get("per_self_energy_type", ""))
			if active and not per_self_energy_type.is_empty():
				var energy_count := _effective_energy_type_count(
					active, per_self_energy_type, catalog)
				total += energy_count * int(params.get("per_energy", 0))
			if active:
				total += active.damage_counters * int(params.get("per_self_damage_counter", 0))
			var condition_bonus: Dictionary = params.get("condition_bonus", {})
			var condition := str(condition_bonus.get("condition", ""))
			var applies := false
			match condition:
				"ko_by_attack_last_turn", "ko_by_attack_damage_last_turn":
					applies = state.had_attack_knockout_last_turn(actor)
				"ko_last_opponent_turn":
					applies = state.had_knockout_last_turn(actor)
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
				for index in range(active.energy_card_ids.size()):
					var units := EnergyView.units_for_card_at(
						active.energy_card_ids, index, catalog)
					if "Fighting" in units or "Rainbow" in units:
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
			return int(params.get("base", 0)) + (
				int(params.get("bonus", 0))
				if active != null and active.healed_this_turn
				else 0
			)
		"damage_and_self_heal":
			return int(params.get("damage", params.get("amount", 0)))
		"any_pokemon_damage", "bench_damage":
			return int(params.get("amount", params.get("damage", 0)))
		"place_counters_and_self_ko":
			return int(params.get(
				"amount", params.get("damage", int(params.get("counters", 0)) * 10)))
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
					count += _effective_energy_unit_count(pokemon, _catalog)
			return count >= 5
		"opponent_active_evolved":
			return opponent.active != null and not _catalog.is_basic_pokemon(opponent.active.card_id)
		"ko_by_attack_last_turn", "ko_by_attack_damage_last_turn":
			return state.had_attack_knockout_last_turn(actor)
		"ko_last_opponent_turn":
			return state.had_knockout_last_turn(actor)
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


func _effective_energy_unit_count(
	pokemon: PokemonState,
	catalog: CardCatalog,
) -> int:
	return (
		0
		if pokemon == null
		else EnergyView.units_for_cards(pokemon.energy_card_ids, catalog).size()
	)


func _effective_energy_type_count(
	pokemon: PokemonState,
	energy_type: String,
	catalog: CardCatalog,
) -> int:
	if pokemon == null:
		return 0
	var normalized := energy_type.to_lower()
	if normalized in ["", "any", "energy"]:
		return _effective_energy_unit_count(pokemon, catalog)
	var result := 0
	for provided in EnergyView.units_for_cards(pokemon.energy_card_ids, catalog):
		if provided.to_lower() in [normalized, "rainbow"]:
			result += 1
	return result


func _energy_card_matches_type(
	card_id: String,
	energy_type: String,
	catalog: CardCatalog,
	attached_card_ids: Array[String] = [],
	card_index: int = -1,
) -> bool:
	var normalized := energy_type.to_lower()
	if normalized in ["", "any", "energy"]:
		return catalog.is_energy(card_id)
	if normalized in ["basic", "basic_energy"]:
		return catalog.is_basic_energy(card_id)
	if not catalog.is_energy(card_id):
		return false
	var provided_types: Array[String] = []
	if card_index >= 0 and card_index < attached_card_ids.size():
		provided_types = EnergyView.units_for_card_at(attached_card_ids, card_index, catalog)
	else:
		provided_types.assign(catalog.provides_energy(card_id))
	for provided in provided_types:
		var provided_type := str(provided).to_lower()
		if provided_type == normalized or provided_type == "rainbow":
			return true
	return false


func _modified_attack_damage(
	state: GameState,
	actor: int,
	base_damage: int,
	catalog: CardCatalog,
	ignore_weakness: bool = false,
	ignore_resistance: bool = false,
	ignore_defender_damage_effects: bool = false,
) -> int:
	var attacker := state.get_player(actor).active
	var defender := state.get_player(1 - actor).active
	if attacker == null or defender == null or base_damage <= 0:
		return max(0, base_damage)
	var damage := base_damage
	# Attacker-side modifiers are applied before type matchups.
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
		damage += _energy_damage_delta(catalog.get_card(energy_id), "attached_attacker")
	damage += attacker.modifier_operation_sum("damage_delta")
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
	if damage <= 0:
		return 0

	# Weakness and Resistance are independent. Bench packets set both flags in
	# the engine, while attacks such as Zacian's may ignore Weakness only.
	if state.apply_type_matchups:
		var attacking_type := "Colorless"
		var attacking_card := catalog.get_card(attacker.card_id)
		if not attacking_card.get("energy_types", []).is_empty():
			attacking_type = str(attacking_card.get("energy_types", [])[0])
		var defending_card := catalog.get_card(defender.card_id)
		if not ignore_weakness:
			for weakness_value in defending_card.get("weaknesses", []):
				var weakness: Dictionary = weakness_value
				if str(weakness.get("energy_type", "")) == attacking_type:
					if str(weakness.get("value", "")) in ["x2", "×2"]:
						damage *= 2
					break
		if not ignore_resistance:
			for resistance_value in defending_card.get("resistances", []):
				var resistance: Dictionary = resistance_value
				if str(resistance.get("energy_type", "")) == attacking_type:
					damage -= abs(int(str(resistance.get("value", "0")).replace("-", "")))
					break
	if damage <= 0:
		return 0

	# Defender-side modifiers and final prevention are last in the pipeline.
	if not ignore_defender_damage_effects:
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
	if (
		not ignore_defender_damage_effects
		and not defender.attached_tool_id.is_empty()
	):
		for effect_value in catalog.get_card(defender.attached_tool_id).get("trainer_effects", []):
			var effect: Dictionary = effect_value
			if str(effect.get("effect_type", "")) != "tool":
				continue
			var modifier := str(effect.get("params", {}).get("effect", ""))
			if modifier == "damage_reduction_stage1" and catalog.is_stage1(defender.card_id):
				damage -= int(effect.get("params", {}).get("amount", 30))
	if (
		not ignore_defender_damage_effects
		and (defender.prevents_damage() or defender.prevents_effects())
	):
		return 0
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


func _attack_squanders_only_fire_energy(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
) -> bool:
	if (
		deck_key != "fire"
		or action == null
		or action.action != "DECLARE_ATTACK"
		or state.get_player(actor).active == null
	):
		return false
	var player := state.get_player(actor)
	var active := player.active
	# Chimchar's Spark is the release deck's only 30-damage attack that burns
	# its sole attached Energy.  With no backup and no replacement Energy in the
	# visible hand, passing preserves both the evolution route and next turn's
	# attack; a non-KO Spark irreversibly loses that resource for negligible gain.
	if (
		active.card_id != "svi-chim"
		or player.bench_count() != 0
		or _effective_energy_unit_count(active, catalog) != 1
		or _helpful_hand_energy_count(state, actor, catalog) > 0
	):
		return false
	var attack_index := int(action.params.get(
		"attack_idx", action.params.get("attack_index", -1)))
	var has_self_discard := false
	for effect_value in _flatten_effects(
		_attack_effects(state, actor, attack_index, catalog)):
		var effect: Dictionary = effect_value
		if (
			str(effect.get("effect_type", "")) == "energy_discard"
			and str(Dictionary(effect.get("params", {})).get("from", "self"))
			in ["", "self"]
		):
			has_self_discard = true
			break
	if not has_self_discard:
		return false
	var opponent := state.get_player(1 - actor)
	return (
		opponent.active != null
		and _estimated_attack_damage(state, actor, attack_index, catalog)
		< opponent.active.current_hp(catalog)
	)


func _switching_energy_regresses_current_attack(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
) -> bool:
	if (
		state == null
		or action == null
		or action.action != "ATTACH_ENERGY"
		or action.target == null
		or not action.target.slot.begins_with("bench_")
	):
		return false
	var energy_card_id := _action_card_id(state, actor, action)
	var forces_switch := false
	for effect_value in catalog.get_card(energy_card_id).get("energy_effects", []):
		var effect: Dictionary = effect_value
		var nested_effect: Dictionary = Dictionary(effect.get("effect", {}))
		if (
			str(effect.get("hook", "")) == "ON_ATTACH"
			and str(nested_effect.get("op", "")) == "switch_with_active"
		):
			forces_switch = true
			break
	if not forces_switch:
		return false
	var before_damage := _best_deterministic_available_damage(
		state, actor, catalog)
	if before_damage < 80:
		return false
	var player := state.get_player(actor)
	var opponent_damage := _best_deterministic_available_damage(
		state, 1 - actor, catalog)
	var switch_avoids_public_knockout := (
		player.active != null
		and opponent_damage >= player.active.current_hp(catalog)
	)
	if switch_avoids_public_knockout:
		return false
	var simulation := state.clone_state()
	simulation.set_type_matchups_enabled(false)
	var rng := PortableRandomSource.new(seed)
	var step := engine.apply_action(simulation, action, rng)
	if not step.success:
		return false
	if not _resolve_choices(simulation, actor, deck_key, catalog, engine, rng):
		return false
	var after_damage := _best_deterministic_available_damage(
		simulation, actor, catalog)
	return after_damage + 40 <= before_damage


func _best_deterministic_available_damage(
	state: GameState,
	actor: int,
	catalog: CardCatalog,
) -> int:
	var player := state.get_player(actor)
	if player.active == null or not player.active.status_conditions.is_empty():
		return 0
	var best := 0
	var attacks: Array = catalog.get_card(player.active.card_id).get("attacks", [])
	var semantic_catalog := CardSemanticCatalog.new(catalog)
	for attack_index in range(attacks.size()):
		var attack: Dictionary = attacks[attack_index]
		if (
			_missing_energy_count(player.active, attack.get("cost", []), catalog) <= 0
			and not bool(semantic_catalog.attack_semantics(
				player.active.card_id, attack_index).get("has_random_effect", false))
		):
			best = maxi(
				best,
				_estimated_attack_damage(state, actor, attack_index, catalog),
			)
	return best


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
	var simulated := state.clone_state()
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
	var missing := _best_missing_energy(pokemon, catalog)
	var ready_damage := _best_ready_pokemon_damage(state, actor, pokemon, catalog)
	# Promotion is an immediate board decision.  Printed maximum damage made a
	# zero-Energy high-HP evolution outrank a one-prize attacker that could act
	# now, so start from actual ready damage and keep future potential in the
	# missing-Energy branches below.
	var value := (
		float(pokemon.current_hp(catalog))
		+ float(ready_damage) * 2.0
		+ float(_effective_energy_unit_count(pokemon, catalog)) * 35.0
	)


	var opponent := state.get_player(1 - actor)
	var can_take_prize := opponent.active != null and ready_damage >= opponent.active.current_hp(catalog)
	if missing == 0:
		value += 140.0 + ready_damage * 0.85
		if can_take_prize:
			value += 420.0 + catalog.prize_value(opponent.active.card_id) * 180.0
	elif missing == 1:
		value += 55.0 + _best_pokemon_damage(pokemon, catalog) * 0.20
	else:
		value -= min(120.0, missing * 35.0)
	value += _effective_energy_unit_count(pokemon, catalog) * 18.0
	var opponent_damage := _best_available_damage_against_candidate(state, actor, pokemon, catalog)
	var survives := opponent_damage <= 0 or opponent_damage < pokemon.current_hp(catalog)
	if survives:
		value += 90.0 + ready_damage * 0.35 + pokemon.current_hp(catalog) * 0.18
	else:
		var asset_value := (
			_card_priority(pokemon.card_id, deck_key, catalog)
			+ _effective_energy_unit_count(pokemon, catalog) * 45.0
			+ pokemon.evolution_stack_ids.size() * 45.0
			+ catalog.prize_value(pokemon.card_id) * 120.0
		)
		value -= min(260.0, asset_value * 0.35)
	if opponent_damage >= pokemon.current_hp(catalog):
		value -= 85.0
		var can_trade := can_take_prize
		if not can_trade:
			value -= 90.0
			if AIDeckProfiles.contains(deck_key, "core", pokemon.card_id):
				value -= 85.0
			if AIDeckProfiles.contains(deck_key, "engine", pokemon.card_id):
				value -= 45.0
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
	var bench_index := player.bench.find(pokemon)
	var best := 0
	if bench_index >= 0:
		player.bench[bench_index] = original_active
	player.active = pokemon
	for attack_idx in range(catalog.get_card(pokemon.card_id).get("attacks", []).size()):
		var attack: Dictionary = catalog.get_card(pokemon.card_id).get("attacks", [])[attack_idx]
		if _missing_energy_count(pokemon, attack.get("cost", []), catalog) <= 0:
			best = max(best, _estimated_attack_damage(state, actor, attack_idx, catalog))
	player.active = original_active
	if bench_index >= 0:
		player.bench[bench_index] = pokemon
	return best


func _action_immediately_loses_match(
	state: GameState,
	actor: int,
	action: GameAction,
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
) -> bool:
	if state == null or action == null or actor not in [0, 1]:
		return false
	# A single determinization must not turn a hidden/coin-dependent attack into
	# a hard veto.  The guard is reserved for publicly deterministic outcomes
	# such as reactive thorns, self-KO and final-Prize resolution.
	if action.action == "DECLARE_ATTACK":
		var source_card_id := (
			action.source.card_id if action.source != null else "")
		if source_card_id.is_empty() and state.get_player(actor).active != null:
			source_card_id = state.get_player(actor).active.card_id
		var attack_index := int(action.params.get(
			"attack_idx", action.params.get("attack_index", -1)))
		if bool(CardSemanticCatalog.new(catalog).attack_semantics(
			source_card_id, attack_index).get("has_random_effect", false)):
			return false
	var simulation := state.clone_state()
	simulation.set_type_matchups_enabled(false)
	var rng := PortableRandomSource.new(seed)
	var step := engine.apply_action(simulation, action, rng)
	if not step.success:
		return false
	if not _resolve_choices(simulation, actor, deck_key, catalog, engine, rng):
		return false
	return simulation.is_terminal() and simulation.winner == 1 - actor


func _best_immediate_loss_escape_action(
	state: GameState,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	seed: int,
	excluded: GameAction,
	profile: Dictionary = {},
) -> GameAction:
	var best: GameAction = null
	var best_value := -INF
	for action_index in range(actions.size()):
		var action := actions[action_index]
		if (
			action == null
			or action == excluded
			or action.action in ["DECLARE_ATTACK", "END_TURN"]
		):
			continue
		var sim_score := _simulated_action_score(
			state,
			actor,
			action,
			deck_key,
			catalog,
			engine,
			seed + action_index * 7919,
			profile,
		)
		if sim_score <= -INF / 2.0:
			continue
		var value := sim_score + _development_action_value(
			state, actor, action, deck_key, catalog)
		if action.action == "EVOLVE":
			value += 80.0
		elif action.action == "RETREAT":
			value += 60.0
		elif action.action == "PLAY_BASIC":
			value += 40.0
		if value > best_value:
			best = action
			best_value = value
	if best != null:
		return best
	var end_turn := _find_action(actions, "END_TURN")
	if (
		end_turn != null
		and _action_executes_successfully(
			state, actor, end_turn, deck_key, catalog, engine, seed + 100003, profile)
	):
		return end_turn
	return null


func _best_ready_pokemon_damage_with_extra(
	state: GameState,
	actor: int,
	pokemon: PokemonState,
	energy_card_id: String,
	catalog: CardCatalog,
) -> int:
	if pokemon == null:
		return 0
	var appended := not energy_card_id.is_empty() and catalog.is_energy(energy_card_id)
	if appended:
		pokemon.energy_card_ids.append(energy_card_id)
	var result := _best_ready_pokemon_damage(
		state, actor, pokemon, catalog)
	if appended:
		pokemon.energy_card_ids.remove_at(pokemon.energy_card_ids.size() - 1)
	return result


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
	var bench_index := player.bench.find(candidate)
	if bench_index >= 0:
		player.bench[bench_index] = original_active
	player.active = candidate
	var damage := _best_available_damage(state, 1 - actor, catalog)
	player.active = original_active
	if bench_index >= 0:
		player.bench[bench_index] = candidate
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


func _high_impact_missing_energy(
	state: GameState,
	actor: int,
	pokemon: PokemonState,
	energy_card_id: String,
	catalog: CardCatalog,
) -> int:
	return int(_high_impact_attack_plan(
		state, actor, pokemon, energy_card_id, catalog).get("missing", 99))


func _high_impact_attack_plan(
	state: GameState,
	actor: int,
	pokemon: PokemonState,
	energy_card_id: String,
	catalog: CardCatalog,
) -> Dictionary:
	if pokemon == null:
		return {"attack_index": -1, "damage": 0, "missing": 99}
	var attacks: Array = catalog.get_card(pokemon.card_id).get("attacks", [])
	if attacks.is_empty():
		return {"attack_index": -1, "damage": 0, "missing": 99}
	var appended_energy := false
	if not energy_card_id.is_empty() and catalog.is_energy(energy_card_id):
		pokemon.energy_card_ids.append(energy_card_id)
		appended_energy = true
	var best_impact := -INF
	var best_damage := 0
	var best_missing := 99
	var best_attack_index := -1
	for attack_index in range(attacks.size()):
		var attack: Dictionary = attacks[attack_index]
		var missing := _missing_energy_count(
			pokemon, attack.get("cost", []), catalog)
		var damage := _pokemon_attack_damage_ceiling(
			state, actor, pokemon, attack_index, catalog)
		# Missing Energy is an opportunity cost.  Selecting solely by printed
		# damage made Torterra chase its four-Energy 160 attack while its dynamic
		# two-Energy attack was already worth 150-250 on the public board.  Damage
		# and missing cost must come from this same attack route; combining the
		# cheap setup attack's cost with another attack's ceiling over-valued
		# Cresselia and Deoxys attachments.
		var impact := float(damage) - float(missing) * 50.0
		if (
			impact > best_impact
			or (
				is_equal_approx(impact, best_impact)
				and (missing < best_missing or (
					missing == best_missing and damage > best_damage))
			)
		):
			best_impact = impact
			best_damage = damage
			best_missing = missing
			best_attack_index = attack_index
	if appended_energy:
		pokemon.energy_card_ids.remove_at(pokemon.energy_card_ids.size() - 1)
	return {
		"attack_index": best_attack_index,
		"damage": best_damage,
		"missing": best_missing,
		"impact": best_impact,
	}


func _pokemon_attack_damage_ceiling(
	state: GameState,
	actor: int,
	pokemon: PokemonState,
	attack_index: int,
	catalog: CardCatalog,
) -> int:
	var attacks: Array = catalog.get_card(pokemon.card_id).get("attacks", [])
	if attack_index < 0 or attack_index >= attacks.size():
		return 0
	var attack: Dictionary = attacks[attack_index]
	var potential := int(attack.get("damage", 0))
	# Conditional printed bonuses describe the attack's reachable route.  They
	# are included here for preparation scoring even when the public condition
	# is not met yet; actual attack selection still uses the rules-accurate
	# estimator below.
	for effect in _flatten_effects(attack.get("effects", [])):
		if str(effect.get("effect_type", "")) == "conditional_damage_bonus":
			var params: Dictionary = effect.get("params", {})
			potential += int(params.get("bonus", params.get("amount", 0)))
	return maxi(
		potential,
		_estimated_pokemon_attack_damage(
			state, actor, pokemon, attack_index, catalog),
	)


func _best_pokemon_damage_for_state(
	state: GameState,
	actor: int,
	pokemon: PokemonState,
	catalog: CardCatalog,
) -> int:
	if pokemon == null:
		return 0
	var attacks: Array = catalog.get_card(pokemon.card_id).get("attacks", [])
	var best := 0
	for attack_index in range(attacks.size()):
		best = maxi(best, _pokemon_attack_damage_ceiling(
			state, actor, pokemon, attack_index, catalog))
	return best


func _estimated_pokemon_attack_damage(
	state: GameState,
	actor: int,
	pokemon: PokemonState,
	attack_index: int,
	catalog: CardCatalog,
) -> int:
	if state == null or actor not in [0, 1] or pokemon == null:
		return 0
	var player := state.get_player(actor)
	var original_active := player.active
	var bench_index := player.bench.find(pokemon)
	if bench_index >= 0:
		player.bench[bench_index] = original_active
	player.active = pokemon
	var damage := _estimated_attack_damage(
		state, actor, attack_index, catalog)
	player.active = original_active
	if bench_index >= 0:
		player.bench[bench_index] = pokemon
	return damage


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
	var cards := pokemon.energy_card_ids.duplicate()
	cards.append(energy_card_id)
	var available := EnergyView.units_for_cards(cards, catalog)
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
					var energy_type := str(params.get(
						"energy_filter", params.get("energy_type", "any")))
					damage = max(
						damage,
						int(params.get("base", 0))
						+ _effective_energy_type_count(pokemon, energy_type, catalog)
						* int(params.get("per_energy", 0)),
					)
				"damage_plus_bench":
					damage = max(damage, int(params.get("base", 0)) + int(params.get("per_bench", 0)) * 3)
				"discard_fighting_energy_damage":
					damage = max(
						damage,
						int(params.get("base", 0))
						+ _effective_energy_type_count(
							pokemon, "Fighting", catalog)
						* int(params.get("per_energy", 0)),
					)
				"damage_self_penalty":
					# The printed value is the undamaged maximum, not a floor.
					damage = max(0, int(params.get("base", 0)) - pokemon.damage_counters * int(params.get("per_counter", 0)))
				"conditional_damage_bonus":
					damage += int(params.get("bonus", params.get("amount", 0)))
				"attack_damage_formula":
					var formula_damage := int(params.get("base", 0))
					formula_damage += int(params.get("per_own_bench", 0)) * 3
					if not str(params.get("per_self_energy_type", "")).is_empty():
						formula_damage += _effective_energy_type_count(
							pokemon,
							str(params.get("per_self_energy_type", "any")),
							catalog,
						) * int(params.get("per_energy", 0))
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
				"damage_self_penalty":
					damage = max(damage, int(params.get("base", 0)))
				"conditional_damage_bonus":
					damage += int(params.get("bonus", params.get("amount", 0)))
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


func _energy_card_improves_attack_readiness(
	state: GameState,
	actor: int,
	card_id: String,
	catalog: CardCatalog,
) -> bool:
	if state == null or not catalog.is_energy(card_id):
		return false
	for row in state.get_player(actor).get_all_pokemon():
		var pokemon: PokemonState = row.get("pokemon")
		if pokemon == null:
			continue
		for attack_value in catalog.get_card(pokemon.card_id).get("attacks", []):
			var attack: Dictionary = attack_value
			var cost: Array = attack.get("cost", [])
			var before := _missing_energy_count(pokemon, cost, catalog)
			if before <= 0:
				continue
			if _missing_energy_count_with_extra(
				pokemon, cost, card_id, catalog) < before:
				return true
	return false


func _helpful_hand_energy_count(
	state: GameState,
	actor: int,
	catalog: CardCatalog,
) -> int:
	var result := 0
	for card_id_value in state.get_player(actor).hand:
		var card_id := str(card_id_value)
		if _energy_card_improves_attack_readiness(
			state, actor, card_id, catalog):
			result += 1
	return result


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
		for energy_index in range(source.energy_card_ids.size()):
			var energy_id := str(source.energy_card_ids[energy_index])
			if not _energy_card_matches_type(
				energy_id, energy_type, catalog, source.energy_card_ids, energy_index):
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
	var start_index: int = max(0, state.action_log.size() - 6)
	for index in range(start_index, state.action_log.size()):
		if ability_name in str(state.action_log[index]):
			return true
	return false


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
	var features := _pokemon_strength_feature_row(pokemon, catalog)
	var native_math: Variant = _cached_native_math()
	if native_math != null:
		return float(native_math.call(
			"pokemon_strength",
			float(features[0]),
			float(features[1]),
			float(features[2]),
		))
	return _pokemon_strength_from_features(features)


func _pokemon_strength_from_features(features: PackedFloat64Array) -> float:
	return float(features[0]) + float(features[1]) * 2.0 + float(features[2]) * 35.0


func _pokemon_strength_gdscript(pokemon: PokemonState, catalog: CardCatalog) -> float:
	if pokemon == null:
		return -1000.0
	return _pokemon_strength_from_features(_pokemon_strength_feature_row(pokemon, catalog))


func _pokemon_strength_feature_row(pokemon: PokemonState, catalog: CardCatalog) -> PackedFloat64Array:
	var result := PackedFloat64Array()
	result.resize(3)
	if pokemon == null:
		result[0] = -1000.0
		result[1] = 0.0
		result[2] = 0.0
		return result
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
					var energy_type := str(params.get(
						"energy_filter", params.get("energy_type", "any")))
					damage = max(
						damage,
						int(params.get("base", 0))
						+ _effective_energy_type_count(pokemon, energy_type, catalog)
						* int(params.get("per_energy", 0)),
					)
				"damage_self_penalty":
					damage = max(0, int(params.get("base", 0)) - pokemon.damage_counters * int(params.get("per_counter", 0)))
				"conditional_damage_bonus":
					damage += int(params.get("bonus", params.get("amount", 0)))
				"attack_damage_formula":
					var formula_damage := int(params.get("base", 0))
					formula_damage += int(params.get("per_own_bench", 0)) * 3
					if not str(params.get("per_self_energy_type", "")).is_empty():
						formula_damage += _effective_energy_type_count(
							pokemon,
							str(params.get("per_self_energy_type", "any")),
							catalog,
						) * int(params.get("per_energy", 0))
					formula_damage += int(Dictionary(params.get("condition_bonus", {})).get("bonus", 0))
					damage = max(damage, formula_damage)
		best_damage = max(best_damage, damage)
	result[0] = float(pokemon.current_hp(catalog))
	result[1] = float(best_damage)
	result[2] = float(_effective_energy_unit_count(pokemon, catalog))
	return result


func _pokemon_strength_features(player: PlayerState, catalog: CardCatalog) -> PackedFloat64Array:
	var result := PackedFloat64Array()
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		result.append_array(_pokemon_strength_feature_row(pokemon, catalog))
	return result


func _strategic_evaluation_delta(
	state: GameState,
	perspective: int,
	catalog: CardCatalog,
) -> float:
	return (
		_player_strategic_score(state, perspective, catalog)
		- _player_strategic_score(state, 1 - perspective, catalog)
	)


func _player_strategic_score(state: GameState, actor: int, catalog: CardCatalog) -> float:
	var player := state.get_player(actor)
	var opponent := state.get_player(1 - actor)
	var deck_key := _deck_key_for_actor(state, actor, "")
	var score := 0.0
	score += _active_prize_threat_value(state, actor, catalog)
	score += _ready_attackers_value(state, actor, deck_key, catalog)
	score += _resource_outs_value(state, actor, deck_key, catalog)
	score += _hand_size_attack_plan_value(state, actor, deck_key, catalog)
	score += _protection_state_value(player.active, catalog)
	score += _status_lock_state_value(opponent.active, state, 1 - actor, catalog) * 0.45
	score -= _active_ko_risk_value(state, actor, deck_key, catalog)
	score -= _status_lock_state_value(player.active, state, actor, catalog)
	score -= _deck_pressure_penalty(player)
	if player.active != null and opponent.active != null:
		var own_prizes := player.prizes.size()
		var opponent_prizes := opponent.prizes.size()
		if own_prizes <= 2 and _best_available_damage(state, actor, catalog) >= opponent.active.current_hp(catalog):
			score += (3 - own_prizes) * float(SCORE_WEIGHTS["prize_race"])
		if opponent_prizes <= 2 and _best_available_damage(state, 1 - actor, catalog) >= player.active.current_hp(catalog):
			score -= (3 - opponent_prizes) * float(SCORE_WEIGHTS["prize_race"])
	return score


func _active_prize_threat_value(state: GameState, actor: int, catalog: CardCatalog) -> float:
	var opponent := state.get_player(1 - actor)
	if opponent.active == null:
		return 0.0
	var ready_damage := _best_available_damage(state, actor, catalog)
	if ready_damage <= 0:
		return 0.0
	var value: float = min(90.0, ready_damage * 0.28)
	if ready_damage >= opponent.active.current_hp(catalog):
		value += 170.0 + catalog.prize_value(opponent.active.card_id) * 115.0
	return value


func _ready_attackers_value(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var value := 0.0
	for row in state.get_player(actor).get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var slot_multiplier := 1.0 if str(row.get("slot", "")) == "active" else 0.45
		var missing := _best_missing_energy(pokemon, catalog)
		var damage := _best_pokemon_damage(pokemon, catalog)
		if missing == 0 and damage > 0:
			value += (
				float(SCORE_WEIGHTS["ready_attacker"]) + min(70.0, damage * 0.22)
			) * slot_multiplier
		elif missing == 1 and damage >= AIDeckProfiles.high_impact_damage_floor(deck_key):
			value += (
				float(SCORE_WEIGHTS["backup_attacker"]) + min(45.0, damage * 0.12)
			) * slot_multiplier
	return value


func _active_ko_risk_value(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	if player.active == null:
		return 420.0
	var opponent_damage := _best_available_damage(state, 1 - actor, catalog)
	if opponent_damage <= 0:
		return 0.0
	var hp := player.active.current_hp(catalog)
	if opponent_damage < hp:
		if opponent_damage >= hp * 0.65:
			return float(SCORE_WEIGHTS["active_damage_pressure"])
		return 0.0
	var risk := float(SCORE_WEIGHTS["active_ko_risk"])
	risk += catalog.prize_value(player.active.card_id) * 105.0
	risk += _effective_energy_unit_count(player.active, catalog) * 30.0
	if AIDeckProfiles.contains(deck_key, "core", player.active.card_id):
		risk += 70.0
	return risk


func _resource_outs_value(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var player := state.get_player(actor)
	var value := 0.0
	if _has_energy_target_with_missing_cost(state, actor, catalog):
		var energy_outs := 0
		for card_id in player.hand + player.deck:
			if catalog.is_energy(card_id) and (
				deck_key.is_empty() or _energy_matches_profile(card_id, deck_key, catalog)
			):
				energy_outs += 1
		value += min(110.0, energy_outs * float(SCORE_WEIGHTS["resource_out"]))
	var evolution_outs := 0
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null or not pokemon.can_evolve_this_turn:
			continue
		for card_id in player.hand + player.deck:
			if (
				catalog.is_pokemon(card_id)
				and AIDeckProfiles.contains(deck_key, "evolution", card_id)
				and _card_priority(card_id, deck_key, catalog) > 0.0
			):
				evolution_outs += 1
				break
	value += min(90.0, evolution_outs * 34.0)
	if _semantic_v2_enabled():
		value += _core_evolution_line_progress_value(state, actor, deck_key, catalog)
	return value


func _core_evolution_line_progress_value(
	state: GameState,
	actor: int,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	if deck_key.is_empty():
		return 0.0
	var player := state.get_player(actor)
	var total := 0.0
	for core_value in AIDeckProfiles.get_profile(deck_key).get("core", []):
		var core_id := str(core_value)
		if core_id.is_empty() or not catalog.is_pokemon(core_id):
			continue
		var parts := _core_evolution_line_parts(core_id, deck_key, catalog)
		var stage1_ids: Array[String] = []
		stage1_ids.assign(parts.get("stage1", []))
		var basic_ids: Array[String] = []
		basic_ids.assign(parts.get("basic", []))
		if stage1_ids.is_empty() and basic_ids.is_empty():
			continue
		var has_core := _player_has_any_pokemon_id_in_play(player, [core_id])
		var has_stage1 := _player_has_any_pokemon_id_in_play(player, stage1_ids)
		var has_basic := _player_has_any_pokemon_id_in_play(player, basic_ids)
		var core_available := _zone_has_any_card_id(player.hand, [core_id]) or _zone_has_any_card_id(player.deck, [core_id])
		var stage1_available := _zone_has_any_card_id(player.hand, stage1_ids) or _zone_has_any_card_id(player.deck, stage1_ids)
		var basic_available := _zone_has_any_card_id(player.hand, basic_ids) or _zone_has_any_card_id(player.deck, basic_ids)
		var line_value := 0.0
		if has_core:
			line_value += 112.0
		elif has_stage1:
			line_value += 86.0
			if core_available:
				line_value += 56.0
		elif has_basic:
			line_value += 62.0
			if stage1_available:
				line_value += 48.0
			if core_available:
				line_value += 22.0
		elif basic_available:
			line_value += 34.0
			if stage1_available:
				line_value += 18.0
		if catalog.is_stage2(core_id):
			line_value *= 1.18
		if catalog.prize_value(core_id) >= 2:
			line_value *= 1.1
		line_value *= _core_line_focus_multiplier(state, actor, core_id, deck_key, catalog)
		total += min(165.0, line_value)
	return min(260.0, total * 0.72 + float(SCORE_WEIGHTS["evolution_line_plan"]) * 0.25)


func _zone_has_any_card_id(cards: Array[String], card_ids: Array[String]) -> bool:
	if cards.is_empty() or card_ids.is_empty():
		return false
	for card_id in cards:
		if card_id in card_ids:
			return true
	return false


func _status_lock_state_value(
	pokemon: PokemonState,
	state: GameState,
	actor: int,
	catalog: CardCatalog,
) -> float:
	if pokemon == null:
		return 0.0
	var value := 0.0
	if "ASLEEP" in pokemon.status_conditions:
		value += 35.0
	if "PARALYZED" in pokemon.status_conditions:
		value += float(SCORE_WEIGHTS["status_lock"])
	if pokemon.attack_is_locked():
		value += float(SCORE_WEIGHTS["status_lock"])
	if pokemon.has_attack_gate("dazzled"):
		value += 45.0
	if value > 0.0:
		value += min(70.0, _best_available_damage(state, actor, catalog) * 0.18)
	return value


func _protection_state_value(pokemon: PokemonState, catalog: CardCatalog) -> float:
	if pokemon == null:
		return 0.0
	var value := 0.0
	if pokemon.prevents_effects():
		value += float(SCORE_WEIGHTS["protection"]) + pokemon.current_hp(catalog) * 0.18
	elif pokemon.prevents_damage():
		value += 78.0 + pokemon.current_hp(catalog) * 0.12
	var outgoing_reduction := maxi(0, -pokemon.modifier_operation_sum("damage_delta"))
	if outgoing_reduction > 0:
		value -= min(80.0, outgoing_reduction * 1.5)
	return value


func _energy_damage_delta(card: Dictionary, scope: String) -> int:
	var result := 0
	for effect_value in card.get("energy_effects", []):
		if not effect_value is Dictionary:
			continue
		var effect: Dictionary = effect_value
		if (
			str(effect.get("kind", "")) != "modifier"
			or str(effect.get("hook", "")) != MODIFY_DAMAGE_HOOK
			or str(effect.get("scope", "")) != scope
		):
			continue
		var operation: Variant = effect.get("effect", {})
		if operation is Dictionary and Dictionary(operation).get("delta") is int:
			result += int(Dictionary(operation)["delta"])
	return result


static func _decode_choice_view(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"ok": false, "error": "invalid_choice_view"}
	var row: Dictionary = value
	if row.size() != CHOICE_VIEW_FIELDS.size():
		return {"ok": false, "error": "invalid_choice_view"}
	for field in CHOICE_VIEW_FIELDS:
		if not row.has(field):
			return {"ok": false, "error": "invalid_choice_view"}
	if (
		not row["schema_version"] is int
		or int(row["schema_version"]) != ChoiceView.SCHEMA_VERSION
		or not row["base_revision"] is int
		or int(row["base_revision"]) < 0
		or not row["player"] is int
		or int(row["player"]) not in [0, 1]
		or not row["request_id"] is String
		or str(row["request_id"]).is_empty()
		or not row["request_type"] is String
		or str(row["request_type"]).is_empty()
		or not row["prompt"] is String
		or not row["options"] is Array
		or not row["min_select"] is int
		or not row["max_select"] is int
		or int(row["min_select"]) < 0
		or int(row["max_select"]) < int(row["min_select"])
		or not row["allow_duplicates"] is bool
		or not row["can_cancel"] is bool
		or not row["presentation"] is Dictionary
	):
		return {"ok": false, "error": "invalid_choice_view"}
	for option_value in row["options"]:
		if not option_value is Dictionary:
			return {"ok": false, "error": "invalid_choice_view"}
		var option: Dictionary = option_value
		for option_field in option:
			if option_field not in ["option_id", "label", "ref"]:
				return {"ok": false, "error": "private_choice_field"}
		if option.size() not in [2, 3] or not option.has("option_id") or not option.has("label"):
			return {"ok": false, "error": "invalid_choice_view"}
		if (
			not option["option_id"] is String
			or str(option["option_id"]).is_empty()
			or not option["label"] is String
		):
			return {"ok": false, "error": "invalid_choice_view"}
		if option.has("ref") and (
			not option["ref"] is Dictionary
			or not EntityRef.validate_dict(option["ref"]).is_empty()
		):
			return {"ok": false, "error": "invalid_choice_ref"}
	var view := ChoiceView.from_dict(row)
	# Round-tripping through ChoiceView enforces the presentation whitelist and
	# prize/privacy projection in addition to the explicit envelope checks above.
	if view.to_dict() != row:
		return {"ok": false, "error": "invalid_choice_view"}
	return {"ok": true, "view": view}


func _deck_pressure_penalty(player: PlayerState) -> float:
	if player.deck.is_empty():
		return 520.0
	if player.deck.size() <= 2:
		return float(SCORE_WEIGHTS["deck_danger"]) + (3 - player.deck.size()) * 65.0
	if player.deck.size() <= 5:
		return 70.0 + (6 - player.deck.size()) * 12.0
	if player.deck.size() <= 8:
		return 38.0 + (9 - player.deck.size()) * 5.0
	if player.deck.size() <= 12:
		return 18.0
	return 0.0


func _evaluate_raw(state: GameState, perspective: int, catalog: CardCatalog) -> float:
	if state.result_status == GameState.RESULT_DRAW:
		return 0.0
	if state.winner >= 0:
		return 1800.0 if state.winner == perspective else -1800.0
	var own := state.get_player(perspective)
	var opponent := state.get_player(1 - perspective)
	var native_math: Variant = _cached_native_math()
	var base_score := 0.0
	if native_math != null:
		base_score = float(native_math.call(
			"evaluate_board_features",
			float(opponent.prizes.size() - own.prizes.size()),
			float(own.hand.size() - opponent.hand.size()),
			float(own.deck.size() - opponent.deck.size()),
			_pokemon_strength_features(own, catalog),
			_pokemon_strength_features(opponent, catalog),
		))
	else:
		base_score = _evaluate_raw_gdscript(state, perspective, catalog)
	if _semantic_v2_enabled():
		base_score += _strategic_evaluation_delta(state, perspective, catalog)
	return base_score


func _evaluate_raw_gdscript(state: GameState, perspective: int, catalog: CardCatalog) -> float:
	if state.result_status == GameState.RESULT_DRAW:
		return 0.0
	if state.winner >= 0:
		return 1800.0 if state.winner == perspective else -1800.0
	var own := state.get_player(perspective)
	var opponent := state.get_player(1 - perspective)
	var score := float(opponent.prizes.size() - own.prizes.size()) * 220.0
	score += (own.hand.size() - opponent.hand.size()) * 4.0
	score += (own.deck.size() - opponent.deck.size()) * 0.5
	for row in own.get_all_pokemon():
		score += _pokemon_strength_gdscript(row["pokemon"], catalog) if row["pokemon"] else 0.0
	for row in opponent.get_all_pokemon():
		score -= _pokemon_strength_gdscript(row["pokemon"], catalog) if row["pokemon"] else 0.0
	return score


func _dynamic_budget_config(raw: Variant) -> Dictionary:
	var config := DYNAMIC_BUDGET_DEFAULTS.duplicate(true)
	if raw is bool:
		config["enabled"] = bool(raw)
	elif raw is Dictionary:
		var source := Dictionary(raw)
		for key in config.keys():
			if source.has(key):
				config[key] = source[key]
	config["enabled"] = bool(config.get("enabled", false))
	config["min_simulations"] = maxi(1, int(config.get("min_simulations", 128)))
	config["ambiguous_min_simulations"] = maxi(
		int(config["min_simulations"]),
		int(config.get("ambiguous_min_simulations", 512))
	)
	config["check_interval"] = maxi(1, int(config.get("check_interval", 32)))
	config["stable_checks"] = maxi(1, int(config.get("stable_checks", 3)))
	config["ambiguous_stable_checks"] = maxi(
		1,
		int(config.get("ambiguous_stable_checks", 5))
	)
	config["min_mean_gap"] = max(0.0, float(config.get("min_mean_gap", 0.10)))
	config["ambiguous_mean_gap"] = max(
		0.0,
		float(config.get("ambiguous_mean_gap", 0.14))
	)
	config["min_best_visits"] = maxi(1, int(config.get("min_best_visits", 32)))
	config["min_best_visit_share"] = clampf(
		float(config.get("min_best_visit_share", 0.35)),
		0.0,
		1.0
	)
	config["clear_prior_gap"] = max(0.0, float(config.get("clear_prior_gap", 0.25)))
	config["max_root_actions_for_clear"] = maxi(
		1,
		int(config.get("max_root_actions_for_clear", 10))
	)
	config["single_action_simulations"] = maxi(
		0,
		int(config.get("single_action_simulations", 0))
	)
	return config


func _deck_key_for_actor(state: GameState, actor: int, fallback: String) -> String:
	if actor >= 0 and actor < state.public_deck_keys.size():
		var deck_key := str(state.public_deck_keys[actor])
		if not deck_key.is_empty():
			return deck_key
	return fallback
