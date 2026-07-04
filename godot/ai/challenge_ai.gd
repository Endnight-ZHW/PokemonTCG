class_name NativeChallengeAI
extends RefCounted

const STRONGEST_DIFFICULTY := "strongest"
const HEURISTIC_VARIANT_LEGACY := "legacy"
const HEURISTIC_VARIANT_SEMANTIC_V2 := "semantic_v2"
const DEFAULT_HEURISTIC_VARIANT := HEURISTIC_VARIANT_SEMANTIC_V2
const DIFFICULTIES := {
	"strongest": {"simulations": 12000, "seconds": 10.0, "depth": 24},
	# Compatibility aliases for older saves/tests that still send a difficulty.
	"fast": {"simulations": 12000, "seconds": 10.0, "depth": 24},
	"standard": {"simulations": 12000, "seconds": 10.0, "depth": 24},
	"hard": {"simulations": 12000, "seconds": 10.0, "depth": 24},
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
const ROLLOUT_LOOKAHEAD_MAX_ACTIONS := 8
const ROLLOUT_LOOKAHEAD_TOP_N := 2

var _catalog_cache: CardCatalog = null
var _engine_cache: GameEngine = null
var _native_math: Variant = null
var _native_math_checked := false
var _disable_native_math := false
var _heuristic_variant := DEFAULT_HEURISTIC_VARIANT
var _pre_evolution_ids_cache: Dictionary = {}
var _core_evolution_line_cache: Dictionary = {}


static func strongest_preset() -> Dictionary:
	return Dictionary(DIFFICULTIES[STRONGEST_DIFFICULTY]).duplicate(true)


static func diagnostic_labels() -> Array:
	return DIAGNOSTIC_LABELS.duplicate()


static func heuristic_variants() -> Array[String]:
	return [HEURISTIC_VARIANT_LEGACY, HEURISTIC_VARIANT_SEMANTIC_V2]


func _normalize_heuristic_variant(value: String) -> String:
	if value == HEURISTIC_VARIANT_SEMANTIC_V2:
		return HEURISTIC_VARIANT_SEMANTIC_V2
	return HEURISTIC_VARIANT_LEGACY


func _semantic_v2_enabled() -> bool:
	return _heuristic_variant == HEURISTIC_VARIANT_SEMANTIC_V2


func _cached_catalog() -> CardCatalog:
	if _catalog_cache == null:
		_catalog_cache = CardCatalog.new()
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
	var previous_heuristic_variant := _heuristic_variant
	_disable_native_math = bool(request.get("disable_native_math", false))
	_heuristic_variant = _normalize_heuristic_variant(str(
		request.get("heuristic_variant", DEFAULT_HEURISTIC_VARIANT)))
	var context_started := _profile_start(profile)
	var disable_cache := bool(request.get("disable_cache", false))
	var catalog := CardCatalog.new() if disable_cache else _cached_catalog()
	var engine := GameEngine.new(catalog) if disable_cache else _cached_engine(catalog)
	var state := GameState.from_dict(request["state"])
	var actor := int(request["actor"])
	_profile_add_elapsed(profile, "request_context_ms", context_started)
	var result: Dictionary
	if str(request.get("kind", "action")) == "choice":
		var choice_started := _profile_start(profile)
		result = _choose_request(
			state,
			ChoiceRequest.from_dict(request["choice"]),
			actor,
			str(request.get("deck_key", "")),
			catalog,
			engine,
			int(request.get("seed", 17)),
			inference,
			str(request.get("mode", "challenge")),
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
		)
	result["revision"] = int(request["revision"])
	result["request_id"] = str(request.get("request_id", ""))
	result["elapsed_ms"] = (Time.get_ticks_usec() - started) / 1000.0
	result["heuristic_variant"] = _heuristic_variant
	if _profile_enabled(profile):
		result["profile"] = _public_decision_profile(profile)
	_disable_native_math = previous_disable_native_math
	_heuristic_variant = previous_heuristic_variant
	return result


func _search_action(
	request: Dictionary,
	state: GameState,
	actor: int,
	catalog: CardCatalog,
	engine: GameEngine,
	cancel_check: Callable,
	inference: Variant,
	profile: Dictionary = {},
) -> Dictionary:
	var decode_started := _profile_start(profile)
	var actions: Array[GameAction] = []
	for row in request.get("actions", []):
		actions.append(GameAction.from_dict(row))
	if actions.is_empty():
		actions = engine.legal_actions(state, actor, false)
	_profile_add_elapsed(profile, "decode_actions_ms", decode_started)
	if actions.is_empty():
		return {"success": false, "error": "no_legal_action"}
	_profile_count(profile, "root_action_count", actions.size())
	var deck_key := _deck_key_for_actor(state, actor, str(request.get("deck_key", "")))
	var mode := str(request.get("mode", "challenge"))
	var preset := strongest_preset()
	var simulation_budget := int(
		256 if mode == "deep" else request.get("simulation_budget", preset["simulations"])
	)
	var budget_requested := simulation_budget
	var seconds := float(8.0 if mode == "deep" else request.get("seconds", preset["seconds"]))
	var max_depth := int(request.get("max_depth", preset["depth"]))
	var deterministic := bool(request.get("deterministic", false))
	var deadline := Time.get_ticks_usec() + int(seconds * 1000000.0)
	var request_seed := int(request.get("seed", 17))
	var dynamic_budget := _dynamic_budget_config(request.get("dynamic_budget", {}))
	if mode == "deep":
		dynamic_budget["enabled"] = false
	var dynamic_enabled := bool(dynamic_budget.get("enabled", false))
	if dynamic_enabled and actions.size() == 1 and int(dynamic_budget["single_action_simulations"]) <= 0:
		_profile_count(profile, "dynamic_budget_single_action_stops")
		return {
			"success": true,
			"kind": "action",
			"action": actions[0].to_dict(),
			"simulations": 0,
			"budget_requested": budget_requested,
			"budget_stop_reason": "single_action",
			"dynamic_budget_enabled": true,
			"deep_fallback": false,
			"fallback_reason": "",
		}
	if dynamic_enabled and actions.size() == 1:
		simulation_budget = mini(simulation_budget, int(dynamic_budget["single_action_simulations"]))
	var priors: Array[float] = []
	var deep_error := ""
	if mode == "deep" and inference != null:
		var neural_started := _profile_start(profile)
		var neural := _neural_action_priors(state, actor, actions, deck_key, catalog, inference)
		_profile_add_elapsed(profile, "neural_priors_ms", neural_started)
		if bool(neural.get("success", false)):
			priors.assign(neural["priors"])
		else:
			deep_error = str(neural.get("error", "inference_failed"))
	elif mode == "deep":
		deep_error = "runtime_unavailable"
	if mode == "deep" and not deep_error.is_empty():
		var fallback_preset := strongest_preset()
		simulation_budget = int(request.get("simulation_budget", fallback_preset["simulations"]))
		budget_requested = simulation_budget
		seconds = float(request.get("seconds", fallback_preset["seconds"]))
		max_depth = int(request.get("max_depth", fallback_preset["depth"]))
		deadline = Time.get_ticks_usec() + int(seconds * 1000000.0)
	if priors.size() != actions.size():
		var priors_started := _profile_start(profile)
		priors = _heuristic_priors(state, actor, actions, deck_key, catalog, profile)
		_profile_add_elapsed(profile, "heuristic_priors_ms", priors_started)

	var visits: Array[int] = []
	var totals: Array[float] = []
	visits.resize(actions.size())
	totals.resize(actions.size())
	visits.fill(0)
	totals.fill(0.0)
	var completed := 0
	var stop_reason := "disabled"
	var dynamic_ambiguous := _dynamic_budget_is_ambiguous(actions.size(), priors, dynamic_budget)
	var dynamic_min_simulations := int(
		dynamic_budget["ambiguous_min_simulations"]
		if dynamic_ambiguous
		else dynamic_budget["min_simulations"]
	)
	var dynamic_stable_required := int(
		dynamic_budget["ambiguous_stable_checks"]
		if dynamic_ambiguous
		else dynamic_budget["stable_checks"]
	)
	var dynamic_check_interval := int(dynamic_budget["check_interval"])
	var dynamic_last_best := -1
	var dynamic_stable_checks := 0
	while completed < simulation_budget:
		if cancel_check.call():
			return {"success": false, "cancelled": true, "error": "cancelled"}
		if not deterministic and Time.get_ticks_usec() >= deadline:
			stop_reason = "deadline"
			break
		var selected := _select_ucb(visits, totals, priors, completed)
		var determinize_started := _profile_start(profile)
		var simulation := AIObservationBuilder.determinize_state(
			state,
			actor,
			request_seed + completed * 7919,
			catalog,
		)
		_profile_add_elapsed(profile, "determinize_ms", determinize_started)
		var simulation_rng := PortableRandomSource.new(
			request_seed + completed * 104729
		)
		var simulate_started := _profile_start(profile)
		var value := _simulate(
			simulation,
			actor,
			actions[selected],
			deck_key,
			catalog,
			engine,
			simulation_rng,
			max_depth,
			profile,
		)
		_profile_add_elapsed(profile, "simulate_total_ms", simulate_started)
		visits[selected] += 1
		totals[selected] += value
		completed += 1
		_profile_count(profile, "simulations")
		if (
			dynamic_enabled
			and completed >= dynamic_min_simulations
			and completed % dynamic_check_interval == 0
		):
			_profile_count(profile, "dynamic_budget_checks")
			var confidence_best := _dynamic_budget_confident_index(
				visits, totals, priors, completed, dynamic_budget, dynamic_ambiguous)
			if confidence_best >= 0:
				if confidence_best == dynamic_last_best:
					dynamic_stable_checks += 1
				else:
					dynamic_last_best = confidence_best
					dynamic_stable_checks = 1
				if dynamic_stable_checks >= dynamic_stable_required:
					stop_reason = "confidence"
					_profile_count(profile, "dynamic_budget_confidence_stops")
					break
			else:
				dynamic_last_best = -1
				dynamic_stable_checks = 0
	if completed == 0 and mode == "deep":
		var fallback_request: Dictionary = request.duplicate(true)
		fallback_request["mode"] = "challenge"
		fallback_request["difficulty"] = STRONGEST_DIFFICULTY
		fallback_request.erase("simulation_budget")
		fallback_request.erase("seconds")
		fallback_request.erase("max_depth")
		fallback_request.erase("dynamic_budget")
		var fallback := _search_action(
			fallback_request,
			state,
			actor,
			catalog,
			engine,
			cancel_check,
			null,
			profile,
		)
		fallback["deep_fallback"] = true
		fallback["fallback_reason"] = "zero_valid_simulations"
		return fallback
	if dynamic_enabled:
		if stop_reason == "disabled":
			stop_reason = "budget_exhausted"
			_profile_count(profile, "dynamic_budget_budget_exhausted")
		elif stop_reason == "deadline":
			_profile_count(profile, "dynamic_budget_deadline_stops")
	var best := _best_search_index(visits, totals, priors)
	var selected_action := _validated_or_fallback_action(
		state,
		actor,
		actions[best],
		actions,
		deck_key,
		catalog,
		engine,
		request_seed + completed * 15485863,
		profile,
	)
	if _semantic_v2_enabled() and selected_action.action == "END_TURN":
		var terminal_attack := _best_productive_attack(
			state,
			actor,
			actions,
			deck_key,
			catalog,
			engine,
			request_seed + completed * 15485863 + 47,
			profile,
		)
		if terminal_attack != null:
			selected_action = terminal_attack
	return {
		"success": true,
		"kind": "action",
		"action": selected_action.to_dict(),
		"simulations": completed,
		"budget_requested": budget_requested,
		"budget_stop_reason": stop_reason,
		"dynamic_budget_enabled": dynamic_enabled,
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
	profile: Dictionary = {},
) -> float:
	var apply_started := _profile_start(profile)
	var step := engine.apply_action(state, first_action, rng)
	_profile_add_elapsed(profile, "rollout_apply_action_ms", apply_started)
	if not step.success:
		return -1.0
	var resolve_started := _profile_start(profile)
	if not _resolve_choices(state, perspective, deck_key, catalog, engine, rng):
		_profile_add_elapsed(profile, "rollout_resolve_choices_ms", resolve_started)
		return -1.0
	_profile_add_elapsed(profile, "rollout_resolve_choices_ms", resolve_started)
	if state.winner >= 0:
		return 1.0 if state.winner == perspective else -1.0
	var opponent_rollout_lookahead_used := false
	for _depth in range(max_depth):
		var actor := _current_actor(state)
		var legal_started := _profile_start(profile)
		var actions := engine.legal_actions(state, actor, false)
		_profile_add_elapsed(profile, "rollout_legal_actions_ms", legal_started)
		if actions.is_empty():
			break
		_profile_count(profile, "rollout_depth_steps")
		_profile_count(profile, "rollout_action_count", actions.size())
		var action_deck_key := _deck_key_for_actor(state, actor, deck_key)
		var heuristic_started := _profile_start(profile)
		var allow_opponent_lookahead := (
			not opponent_rollout_lookahead_used
			and actor != perspective
			and state.phase == "MAIN"
		)
		var action := _rollout_policy_action(
			state,
			perspective,
			actor,
			actions,
			action_deck_key,
			catalog,
			engine,
			allow_opponent_lookahead,
			profile,
		)
		if allow_opponent_lookahead:
			opponent_rollout_lookahead_used = true
		_profile_add_elapsed(profile, "rollout_heuristic_action_ms", heuristic_started)
		apply_started = _profile_start(profile)
		step = engine.apply_action(state, action, rng)
		_profile_add_elapsed(profile, "rollout_apply_action_ms", apply_started)
		if not step.success:
			break
		resolve_started = _profile_start(profile)
		if not _resolve_choices(state, perspective, deck_key, catalog, engine, rng):
			_profile_add_elapsed(profile, "rollout_resolve_choices_ms", resolve_started)
			break
		_profile_add_elapsed(profile, "rollout_resolve_choices_ms", resolve_started)
		if state.winner >= 0:
			return 1.0 if state.winner == perspective else -1.0
		if state.active_player_idx == perspective and actor != perspective:
			break
	var evaluate_started := _profile_start(profile)
	var evaluation := _evaluate(state, perspective, catalog)
	_profile_add_elapsed(profile, "rollout_evaluate_ms", evaluate_started)
	_profile_count(profile, "rollout_evaluations")
	return evaluation


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
	engine: GameEngine,
	seed: int,
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
			engine,
			seed,
			true,
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
	engine: GameEngine = null,
	seed: int = 17,
	enable_lookahead: bool = false,
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
	if enable_lookahead and _semantic_v2_enabled() and engine != null:
		var lookahead := _semantic_lookahead_choice(
			state, request, deck_key, catalog, engine, seed, mode)
		if lookahead != null:
			return lookahead
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


func _semantic_lookahead_choice(
	state: GameState,
	request: ChoiceRequest,
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
		var option_ids := _ranked_choice_option_ids(request, candidate_ranked, count)
		if option_ids.is_empty() and min_count > 0:
			continue
		var response := ChoiceResponse.new(request.request_id, option_ids, false)
		var simulation := state.clone_state()
		var rng := PortableRandomSource.new(seed + candidate_offset * 7919 + anchor * 101)
		var step := engine.apply_choice(simulation, request, response, rng)
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


func _choice_request_matches_pending(state: GameState, request: ChoiceRequest) -> bool:
	var pending := ResolutionStack.from_dict(state.resolution_stack).pending_request
	return pending != null and pending.request_id == request.request_id


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
	if request.request_type == "select_energy_source" or operation == "energy_relocate_source":
		return "energy_source"
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
	var continuation := _pending_choice_continuation(state)
	if mode == "energy_source":
		return _energy_source_choice_value(
			state,
			_choice_option_player(option, request.player),
			_choice_option_slot(option),
			continuation,
			deck_key,
			catalog,
		)
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
				state,
				target_player,
				slot,
				_choice_energy_card_id(continuation, catalog),
				deck_key,
				catalog,
			)
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


func _choice_energy_card_id(continuation: Dictionary, catalog: CardCatalog) -> String:
	for value in continuation.get("card_ids", []):
		var card_id := str(value)
		if catalog.is_energy(card_id):
			return card_id
	var card_id := str(continuation.get("card_id", ""))
	if catalog.is_energy(card_id):
		return card_id
	return ""


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
		if _semantic_v2_enabled():
			value += _core_evolution_line_card_bonus(
				state, actor, card_id, deck_key, catalog)
	if catalog.is_energy(card_id) and _has_energy_target_with_missing_cost(state, actor, catalog):
		value += 50.0
	if catalog.is_trainer(card_id):
		value += 18.0
		if _semantic_v2_enabled():
			value += _bench_setup_search_card_bonus(state, actor, card_id, deck_key, catalog)
	var duplicate_count := 0
	for hand_card_id in player.hand:
		if hand_card_id == card_id:
			duplicate_count += 1
	if duplicate_count >= 2:
		value -= min(90.0, float(duplicate_count - 1) * 35.0)
	return value


func _core_evolution_line_card_bonus(
	state: GameState,
	actor: int,
	card_id: String,
	deck_key: String,
	catalog: CardCatalog,
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
		var bonus := 0.0
		if card_id == core_id:
			if catalog.is_stage2(core_id):
				if has_stage1:
					bonus = 170.0
				elif has_basic:
					bonus = 70.0
				elif not has_core:
					bonus = -145.0
			elif catalog.is_stage1(core_id):
				if has_basic:
					bonus = 130.0
				elif not has_core:
					bonus = -55.0
		elif card_id in stage1_ids:
			if has_basic:
				bonus = 145.0
			elif not has_stage1 and not has_core:
				bonus = 25.0
		elif card_id in basic_ids:
			if not has_basic and not has_stage1 and not has_core:
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
	var power_before := _high_impact_missing_energy(pokemon, "", catalog)
	var power_after := (
		_high_impact_missing_energy(pokemon, energy_card_id, catalog)
		if not energy_card_id.is_empty() and catalog.is_energy(energy_card_id)
		else power_before
	)
	var power_progress: int = max(0, power_before - power_after)
	var damage_ceiling := _best_pokemon_damage(pokemon, catalog)
	var high_impact_floor := AIDeckProfiles.high_impact_damage_floor(deck_key)
	var value := progress * 85.0
	if before > 0 and after == 0:
		value += 155.0 + damage_ceiling * 0.25
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
	continuation: Dictionary,
	deck_key: String,
	catalog: CardCatalog,
) -> float:
	var pokemon := state.get_player(actor).get_pokemon(slot)
	if pokemon == null:
		return -INF
	var energy_type := str(continuation.get("energy_type", "any"))
	var energy_index := _matching_energy_index_for_type(pokemon, energy_type, catalog)
	if energy_index < 0:
		return -INF
	var energy_id := str(pokemon.energy_card_ids[energy_index])
	var before_missing := _best_missing_energy(pokemon, catalog)
	var before_high_impact := _high_impact_missing_energy(pokemon, "", catalog)
	var before_ready_damage := _best_ready_pokemon_damage(state, actor, pokemon, catalog)
	var damage_ceiling := _best_pokemon_damage(pokemon, catalog)
	pokemon.energy_card_ids.remove_at(energy_index)
	var after_missing := _best_missing_energy(pokemon, catalog)
	var after_high_impact := _high_impact_missing_energy(pokemon, "", catalog)
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
	if pokemon.energy_card_ids.size() >= 3 and after_missing == 0:
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
		if _energy_card_matches_type(str(pokemon.energy_card_ids[index]), energy_type, catalog):
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
		if _best_pokemon_damage(pokemon, catalog) < AIDeckProfiles.high_impact_damage_floor(deck_key):
			bonus -= 25.0
	if slot != "active" and AIDeckProfiles.contains(deck_key, "bench", pokemon.card_id):
		bonus += 34.0
	if "ex" in card.get("subtypes", []):
		bonus += 45.0
	var damage_ceiling := _best_pokemon_damage(pokemon, catalog)
	bonus += min(120.0, damage_ceiling * 0.35)
	var missing := _best_missing_energy(pokemon, catalog)
	var high_impact_missing := _high_impact_missing_energy(pokemon, "", catalog)
	var high_impact_after := (
		_high_impact_missing_energy(pokemon, energy_card_id, catalog)
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
	return bonus


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
		and _best_pokemon_damage(player.active, catalog) >= high_impact_floor
	):
		return false
	var active_before := _best_missing_energy(player.active, catalog)
	var active_after := _best_missing_energy_with_extra(player.active, energy_card_id, catalog)
	var active_damage := _best_pokemon_damage(player.active, catalog)
	var active_power_before := _high_impact_missing_energy(player.active, "", catalog)
	var active_power_after := _high_impact_missing_energy(player.active, energy_card_id, catalog)
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
		var bench_damage := _best_pokemon_damage(pokemon, catalog)
		var bench_power_before := _high_impact_missing_energy(pokemon, "", catalog)
		var bench_power_after := _high_impact_missing_energy(pokemon, energy_card_id, catalog)
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
	profile: Dictionary = {},
) -> Array[float]:
	var scores: Array[float] = []
	var maximum := -INF
	for action in actions:
		var score := _action_score(state, actor, action, deck_key, catalog, profile)
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
	profile: Dictionary = {},
) -> GameAction:
	var best := actions[0]
	var best_score := -INF
	for action in actions:
		var score := _action_score(state, actor, action, deck_key, catalog, profile)
		if score > best_score:
			best = action
			best_score = score
	return best


func _rollout_policy_action(
	state: GameState,
	perspective: int,
	actor: int,
	actions: Array[GameAction],
	deck_key: String,
	catalog: CardCatalog,
	engine: GameEngine,
	allow_opponent_lookahead: bool,
	profile: Dictionary = {},
) -> GameAction:
	if (
		not _semantic_v2_enabled()
		or not allow_opponent_lookahead
		or actions.size() > ROLLOUT_LOOKAHEAD_MAX_ACTIONS
	):
		return _best_heuristic_action(state, actor, actions, deck_key, catalog, profile)
	var ranked: Array[int] = []
	for index in range(actions.size()):
		ranked.append(index)
	ranked.sort_custom(func(left: int, right: int) -> bool:
		var left_score := _action_score(state, actor, actions[left], deck_key, catalog, profile)
		var right_score := _action_score(state, actor, actions[right], deck_key, catalog, profile)
		if is_equal_approx(left_score, right_score):
			return left < right
		return left_score > right_score
	)
	var base_perspective_score := _evaluate_raw(state, perspective, catalog)
	var best_action := actions[ranked[0]]
	var best_actor_score := -INF
	var candidate_count: int = mini(ranked.size(), ROLLOUT_LOOKAHEAD_TOP_N)
	for candidate_offset in range(candidate_count):
		var action_index := ranked[candidate_offset]
		var action := actions[action_index]
		var sim_score := _simulated_action_score(
			state,
			actor,
			action,
			deck_key,
			catalog,
			engine,
			state.revision + actor * 104729 + action_index * 7919,
			profile,
		)
		if sim_score <= -INF / 2.0:
			continue
		var perspective_after := _simulated_action_score(
			state,
			perspective,
			action,
			deck_key,
			catalog,
			engine,
			state.revision + perspective * 65537 + action_index * 3571,
			profile,
		)
		if perspective_after <= -INF / 2.0:
			perspective_after = base_perspective_score
		var actor_value: float = (
			sim_score
			- max(0.0, perspective_after - base_perspective_score) * 0.35
			+ _action_score(state, actor, action, deck_key, catalog, profile) * 0.03
		)
		if actor_value > best_actor_score:
			best_actor_score = actor_value
			best_action = action
	return best_action


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
	var ko_attack := _best_immediate_ko_attack(
		state, actor, actions, deck_key, catalog, engine, seed, profile)
	if ko_attack != null and _should_override_with_ko(preferred, ko_attack, state, actor, catalog):
		return ko_attack

	if preferred.action == "DECLARE_ATTACK":
		if (
			_attack_draw_pressure_is_unsafe(state, actor, preferred, catalog)
			or _attack_feeds_dangerous_retaliation(state, actor, preferred, catalog)
		):
			var safe_development := _best_productive_nonterminal_action(
				state, actor, actions, deck_key, catalog, engine, seed + 11, preferred, profile)
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
			var safe_development := _best_productive_nonterminal_action(
				state, actor, actions, deck_key, catalog, engine, seed + 18, preferred, profile)
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
		if _semantic_v2_enabled():
			var direct_attack := _best_productive_attack_candidate(
				state, actor, actions, deck_key, catalog)
			if direct_attack != null:
				return direct_attack
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
	heuristic_variant: String = "",
) -> Dictionary:
	var previous_heuristic_variant := _heuristic_variant
	if not heuristic_variant.is_empty():
		_heuristic_variant = _normalize_heuristic_variant(heuristic_variant)
	var result := {}
	for label in DIAGNOSTIC_LABELS:
		result[label] = 0
	if selected == null or actions.is_empty():
		if not heuristic_variant.is_empty():
			_heuristic_variant = previous_heuristic_variant
		return result

	var ko_attack := _best_immediate_ko_attack(
		state, actor, actions, deck_key, catalog, engine, seed + 101)
	if (
		ko_attack != null
		and not _diagnostic_same_action(selected, ko_attack)
		and not _selected_attack_takes_active_ko(
			state, actor, selected, deck_key, catalog, engine, seed + 102)
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

	if not heuristic_variant.is_empty():
		_heuristic_variant = previous_heuristic_variant
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
	var opponent := state.get_player(1 - actor)
	if opponent.active == null:
		return false
	var estimated_damage := _estimated_attack_damage(
		state, actor, int(selected.params.get("attack_idx", -1)), catalog)
	if estimated_damage >= opponent.active.current_hp(catalog):
		return true
	var simulation := state.clone_state()
	var action := GameAction.from_dict(selected.to_dict())
	action.actor = actor
	var rng := PortableRandomSource.new(seed)
	var step := engine.apply_action(simulation, action, rng)
	if not step.success:
		return false
	var simulated_opponent := simulation.get_player(1 - actor)
	return simulated_opponent.active == null


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
	for action in actions:
		if action.action != "DECLARE_ATTACK":
			continue
		var damage := _estimated_attack_damage(state, actor, int(action.params.get("attack_idx", -1)), catalog)
		if damage < opponent.active.current_hp(catalog):
			continue
		var value := damage + catalog.prize_value(opponent.active.card_id) * 140.0
		if value > best_value and _action_executes_successfully(
			state, actor, action, deck_key, catalog, engine, seed + int(value), profile):
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
	profile: Dictionary = {},
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
		state, actor, actions, deck_key, catalog, engine, seed, attack_action, profile)


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
	if request == null:
		request = ResolutionStack.from_dict(simulation.resolution_stack).pending_request
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
			var damage_ceiling := _best_pokemon_damage(target, catalog)
			var power_before := _high_impact_missing_energy(target, "", catalog)
			var power_after := _high_impact_missing_energy(target, card_id, catalog)
			var power_progress: int = max(0, power_before - power_after)
			var attach_value: float = progress * 95.0
			if before > 0 and after == 0:
				attach_value += 175.0 + damage_ceiling * 0.25
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
					return 65.0 + _effects_tactical_value(
						state, actor, ability.get("effects", []), slot, catalog, deck_key)
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
	var attached_energy := evolve_target.energy_card_ids.size()
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
				and (bench_pokemon.energy_card_ids.size() >= 1 or bench_missing <= 1)
			)
		):
			penalty += 115.0
			break
	if after_retreat >= 2 and evolved_ready_damage <= 40:
		penalty += 70.0
	return min(430.0, penalty)


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
			"search", "conditional_search_extra", "search_any_and_switch", "arven", "houb":
				value += 125.0
				if player.bench_count() < 2:
					value += 35.0
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
	var value := 0.0
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
			"search", "conditional_search_extra", "search_any_and_switch", "arven", "houb":
				value += _semantic_search_value(state, actor, params, profile_key, catalog)
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
				value += _semantic_energy_disruption_value(state, actor, catalog)
			"discard", "discard_hand_conditional_bonus":
				value += _semantic_hand_disruption_value(state, actor)
			"prevent_damage", "prevent_all", "prevent_effects":
				value += _semantic_protection_effect_value(state, actor, profile_key, catalog)
			"status", "conditional_status", "dazzling_beam", "attack_lock_basic", "apply_outgoing_damage_reduction", "self_attack_lock":
				value += _semantic_status_effect_value(state, actor, effect_type, params, catalog)
			"damage", "any_pokemon_damage", "place_counters_and_self_ko", "bench_damage", "damage_and_self_heal":
				value += _semantic_damage_effect_value(state, actor, effect, catalog)
			"damage_counter_self":
				value -= int(params.get("amount", params.get("damage", 20))) * 1.0
			"attack_damage_formula", "conditional_damage_bonus", "discard_fighting_energy_damage", "discard_hand_conditional_bonus":
				value += _semantic_damage_effect_value(state, actor, effect, catalog)
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
		value -= 70.0 + draw_count * 12.0
		if hand_plan > 0.0:
			value += min(85.0, hand_plan * 0.38)
	elif player.hand.size() >= 6:
		value -= 25.0
		if hand_plan > 0.0:
			value += min(45.0, hand_plan * 0.22)
	if hand_plan > 0.0:
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
	var value := float(EFFECT_VALUE_WEIGHTS["disruption_base"]) + opponent.active.energy_card_ids.size() * 32.0
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
	if not opponent.active.status_conditions.is_empty() or opponent.active.attack_locked:
		value -= 35.0
	return value


func _semantic_damage_effect_value(
	state: GameState,
	actor: int,
	effect: Dictionary,
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
	if effect_type == "place_counters_and_self_ko" and state.get_player(actor).active != null:
		value -= 120.0 + catalog.prize_value(state.get_player(actor).active.card_id) * 80.0
	return value


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
			"coin_flip_triple",
			"coin_flip_until_tails",
			"coin_flip_double_ko",
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
	var value := _pokemon_strength(pokemon, catalog)
	var missing := _best_missing_energy(pokemon, catalog)
	var ready_damage := _best_ready_pokemon_damage(state, actor, pokemon, catalog)
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
	value += pokemon.energy_card_ids.size() * 18.0
	var opponent_damage := _best_available_damage_against_candidate(state, actor, pokemon, catalog)
	var survives := opponent_damage <= 0 or opponent_damage < pokemon.current_hp(catalog)
	if survives:
		value += 90.0 + ready_damage * 0.35 + pokemon.current_hp(catalog) * 0.18
	else:
		var asset_value := (
			_card_priority(pokemon.card_id, deck_key, catalog)
			+ pokemon.energy_card_ids.size() * 45.0
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


func _high_impact_missing_energy(
	pokemon: PokemonState,
	energy_card_id: String,
	catalog: CardCatalog,
) -> int:
	if pokemon == null:
		return 99
	var attacks: Array = catalog.get_card(pokemon.card_id).get("attacks", [])
	if attacks.is_empty():
		return 99
	var best_damage := -1
	var best_missing := 99
	for attack in attacks:
		var damage := int(attack.get("damage", 0))
		var missing := (
			_missing_energy_count_with_extra(pokemon, attack.get("cost", []), energy_card_id, catalog)
			if not energy_card_id.is_empty()
			else _missing_energy_count(pokemon, attack.get("cost", []), catalog)
		)
		if damage > best_damage or (damage == best_damage and missing < best_missing):
			best_damage = damage
			best_missing = missing
	return best_missing


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
				"damage_self_penalty":
					damage = max(damage, max(0, int(params.get("base", 0)) - pokemon.damage_counters * int(params.get("per_counter", 0))))
				"conditional_damage_bonus":
					damage += int(params.get("bonus", params.get("amount", 0)))
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
					damage = max(damage, int(params.get("base", 0)) + pokemon.energy_card_ids.size() * int(params.get("per_energy", 0)))
				"damage_self_penalty":
					damage = max(damage, max(0, int(params.get("base", 0)) - pokemon.damage_counters * int(params.get("per_counter", 0))))
				"conditional_damage_bonus":
					damage += int(params.get("bonus", params.get("amount", 0)))
				"attack_damage_formula":
					var formula_damage := int(params.get("base", 0))
					formula_damage += int(params.get("per_own_bench", 0)) * 3
					if not str(params.get("per_self_energy_type", "")).is_empty():
						formula_damage += pokemon.energy_card_ids.size() * int(params.get("per_energy", 0))
					formula_damage += int(Dictionary(params.get("condition_bonus", {})).get("bonus", 0))
					damage = max(damage, formula_damage)
		best_damage = max(best_damage, damage)
	result[0] = float(pokemon.current_hp(catalog))
	result[1] = float(best_damage)
	result[2] = float(pokemon.energy_card_ids.size())
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
		var missing := _best_missing_energy(pokemon, catalog)
		var damage := _best_pokemon_damage(pokemon, catalog)
		if missing == 0 and damage > 0:
			value += float(SCORE_WEIGHTS["ready_attacker"]) + min(70.0, damage * 0.22)
		elif missing == 1 and damage >= AIDeckProfiles.high_impact_damage_floor(deck_key):
			value += float(SCORE_WEIGHTS["backup_attacker"]) + min(45.0, damage * 0.12)
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
	risk += player.active.energy_card_ids.size() * 30.0
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
	if pokemon.attack_locked or pokemon.attack_locked_names.has("__all__"):
		value += float(SCORE_WEIGHTS["status_lock"])
	if pokemon.dazzled:
		value += 45.0
	if value > 0.0:
		value += min(70.0, _best_available_damage(state, actor, catalog) * 0.18)
	return value


func _protection_state_value(pokemon: PokemonState, catalog: CardCatalog) -> float:
	if pokemon == null:
		return 0.0
	var value := 0.0
	if pokemon.all_prevented_next_turn:
		value += float(SCORE_WEIGHTS["protection"]) + pokemon.current_hp(catalog) * 0.18
	elif pokemon.damage_prevented_next_turn:
		value += 78.0 + pokemon.current_hp(catalog) * 0.12
	if pokemon.outgoing_damage_reduction_next_turn > 0:
		value -= min(80.0, pokemon.outgoing_damage_reduction_next_turn * 1.5)
	return value


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


func _evaluate(state: GameState, perspective: int, catalog: CardCatalog) -> float:
	return clampf(_evaluate_raw(state, perspective, catalog) / 1800.0, -1.0, 1.0)


func _evaluate_raw(state: GameState, perspective: int, catalog: CardCatalog) -> float:
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


func _dynamic_budget_is_ambiguous(
	action_count: int,
	priors: Array[float],
	config: Dictionary,
) -> bool:
	if action_count > int(config.get("max_root_actions_for_clear", 10)):
		return true
	if action_count < 2 or priors.size() < 2:
		return false
	var top := -INF
	var second := -INF
	for prior in priors:
		var value := float(prior)
		if value > top:
			second = top
			top = value
		elif value > second:
			second = value
	return top - second < float(config.get("clear_prior_gap", 0.25))


func _all_actions_visited(visits: Array[int]) -> bool:
	for count in visits:
		if count <= 0:
			return false
	return true


func _best_search_index(
	visits: Array[int],
	totals: Array[float],
	priors: Array[float],
) -> int:
	var best := 0
	var best_visits := -1
	var best_average := -INF
	var best_prior := -INF
	for index in range(visits.size()):
		var count := int(visits[index])
		var average := totals[index] / count if count > 0 else -INF
		var prior := priors[index] if index < priors.size() else 0.0
		if count > best_visits:
			best = index
			best_visits = count
			best_average = average
			best_prior = prior
		elif count == best_visits:
			if average > best_average:
				best = index
				best_average = average
				best_prior = prior
			elif is_equal_approx(average, best_average) and prior > best_prior:
				best = index
				best_prior = prior
	return best


func _dynamic_budget_confident_index(
	visits: Array[int],
	totals: Array[float],
	priors: Array[float],
	completed: int,
	config: Dictionary,
	ambiguous: bool,
) -> int:
	if completed <= 0 or not _all_actions_visited(visits):
		return -1
	var best := _best_search_index(visits, totals, priors)
	var best_visits := int(visits[best])
	if best_visits < int(config.get("min_best_visits", 32)):
		return -1
	if float(best_visits) / float(completed) < float(config.get("min_best_visit_share", 0.35)):
		return -1
	var best_average := totals[best] / best_visits
	var next_average := -INF
	for index in range(visits.size()):
		if index == best:
			continue
		var count := int(visits[index])
		if count <= 0:
			return -1
		next_average = max(next_average, totals[index] / count)
	var margin_required := float(
		config.get("ambiguous_mean_gap", 0.14)
		if ambiguous
		else config.get("min_mean_gap", 0.10)
	)
	if best_average - next_average < margin_required:
		return -1
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
