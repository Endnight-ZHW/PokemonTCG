extends SceneTree

const DEEP_DECK_KEYS := [
	"fire", "water", "psychic", "lightning",
	"fighting", "colorless", "dragon", "grass", "darkness", "steel",
]

const CHALLENGE_DECK_KEYS := [
	"fire", "water", "psychic", "lightning",
	"fighting", "colorless", "dragon", "grass", "darkness", "steel",
]

var failures: Array[String] = []


func _initialize() -> void:
	var suite_started := Time.get_ticks_msec()
	var memory_before := OS.get_static_memory_usage()
	var catalog := CardCatalog.new()
	var engine := GameEngine.new(catalog)
	var worker := NativeChallengeAI.new()
	var runtime := DeepAIRuntime.new()
	var runtime_manifest_encoder := int(
		Dictionary(runtime.manifest.get("compatibility_bridge", {})).get("python_encoder_version", 0)
	)
	var deep_runtime_current := (
		runtime_manifest_encoder == int(DeepAIRuntime.EXPECTED_PYTHON_ENCODER_VERSION)
	)
	var summaries: Array[Dictionary] = []
	for failure in _budget_contract_failures(catalog, engine, worker):
		failures.append(failure)
	for mode in ["challenge", "deep"]:
		if mode == "deep" and not deep_runtime_current:
			summaries.append({
				"success": true,
				"mode": "deep",
				"skipped": true,
				"reason": "python_encoder_version_mismatch",
				"manifest_encoder_version": runtime_manifest_encoder,
				"expected_encoder_version": DeepAIRuntime.EXPECTED_PYTHON_ENCODER_VERSION,
			})
			continue
		var deck_keys := CHALLENGE_DECK_KEYS if mode == "challenge" else DEEP_DECK_KEYS
		for index in range(deck_keys.size()):
			var deck_key := str(deck_keys[index])
			var opponent_key := str(deck_keys[(index + 1) % deck_keys.size()])
			var backend: Variant = null
			if mode == "deep":
				if not runtime.load_for_deck(deck_key):
					failures.append("%s model load failed: %s" % [deck_key, runtime.last_error])
					continue
				backend = runtime.get_backend()
			var game_started := Time.get_ticks_msec()
			var summary := _play_game(
				mode,
				deck_key,
				opponent_key,
				20260621 + index * 101 + (10000 if mode == "deep" else 0),
				catalog,
				engine,
				worker,
				backend,
			)
			summary["elapsed_ms"] = Time.get_ticks_msec() - game_started
			summaries.append(summary)
			if not bool(summary.get("success", false)):
				failures.append("%s %s: %s" % [
					mode, deck_key, summary.get("error", "unknown")])
			runtime.unload()
	if failures.is_empty():
		print("AI_REGRESSION_OK ", JSON.stringify({
			"games": summaries,
			"performance": {
				"elapsed_ms": Time.get_ticks_msec() - suite_started,
				"memory_before": memory_before,
				"memory_after": OS.get_static_memory_usage(),
				"memory_peak": OS.get_static_memory_peak_usage(),
			},
		}))
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _budget_contract_failures(
	catalog: CardCatalog,
	engine: GameEngine,
	worker: NativeChallengeAI,
) -> Array[String]:
	var errors: Array[String] = []
	var main_state := GameState.new()
	main_state.phase = "MAIN"
	var main_actions: Array[GameAction] = []
	main_actions.append(GameAction.new("END_TURN", {}, true, 0))
	main_actions.append(GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0))
	var main_budget := NativeChallengeAI.gameplay_action_budget(main_state, main_actions)
	if int(main_budget.get("simulation_budget", -1)) != NativeChallengeAI.GAMEPLAY_DEFAULT_SIMULATIONS:
		errors.append("gameplay main budget must use responsive simulations")
	if not is_equal_approx(float(main_budget.get("seconds", -1.0)), NativeChallengeAI.GAMEPLAY_DEFAULT_SECONDS):
		errors.append("gameplay main budget must use responsive seconds")
	if int(main_budget.get("max_depth", -1)) != NativeChallengeAI.GAMEPLAY_DEFAULT_DEPTH:
		errors.append("gameplay main budget must use responsive depth")
	if not bool(Dictionary(main_budget.get("dynamic_budget", {})).get("enabled", false)):
		errors.append("gameplay main budget must enable dynamic budget")

	var setup_state := GameState.new()
	setup_state.phase = "SETUP"
	var setup_actions: Array[GameAction] = []
	setup_actions.append(GameAction.new("PLAY_BASIC", {}, false, 0))
	setup_actions.append(GameAction.new("SETUP_DONE", {}, true, 0))
	var setup_budget := NativeChallengeAI.gameplay_action_budget(setup_state, setup_actions)
	if int(setup_budget.get("simulation_budget", -1)) != NativeChallengeAI.GAMEPLAY_LOW_SIMULATIONS:
		errors.append("setup gameplay budget must use low simulations")
	if int(setup_budget.get("max_depth", -1)) != NativeChallengeAI.GAMEPLAY_LOW_DEPTH:
		errors.append("setup gameplay budget must use low depth")

	var state := GameState.new()
	state.public_deck_keys = ["fire", "water"]
	var rng := PortableRandomSource.new(424242)
	var setup := engine.setup_game(
		state,
		catalog.expand_deck("fire"),
		catalog.expand_deck("water"),
		rng,
	)
	if not setup.success:
		errors.append("budget contract setup failed: %s" % setup.message)
		return errors
	var actor := _actor(state)
	var legal := engine.legal_actions(state, actor, true)
	if legal.is_empty():
		errors.append("budget contract has no legal action")
		return errors
	var single_actions: Array[GameAction] = []
	single_actions.append(legal[0])
	var single_rows: Array = []
	single_rows.append(legal[0].to_dict())
	var single_budget := NativeChallengeAI.gameplay_action_budget(state, single_actions)
	var single_decision := worker.decide({
		"kind": "action",
		"state": state.snapshot(),
		"actor": actor,
		"revision": state.revision,
		"request_id": "budget-single",
		"mode": "challenge",
		"deck_key": str(state.public_deck_keys[actor]),
		"seed": 424242,
		"simulation_budget": int(single_budget["simulation_budget"]),
		"seconds": float(single_budget["seconds"]),
		"max_depth": int(single_budget["max_depth"]),
		"dynamic_budget": single_budget["dynamic_budget"],
		"deterministic": true,
		"actions": single_rows,
	}, func() -> bool: return false)
	if not bool(single_decision.get("success", false)):
		errors.append("single-action budget decision failed: %s" % single_decision.get("error", "unknown"))
	elif int(single_decision.get("simulations", -1)) != 0:
		errors.append("single-action budget decision must return zero simulations")
	elif str(single_decision.get("budget_stop_reason", "")) != "single_action":
		errors.append("single-action budget decision must report single_action stop")
	elif not bool(single_decision.get("dynamic_budget_enabled", false)):
		errors.append("single-action budget decision must enable dynamic budget")
	else:
		var applied_state := state.clone_state()
		var selected := GameAction.from_dict(single_decision["action"])
		selected.action_id = "budget-contract:%d" % state.revision
		var step := engine.apply_action(applied_state, selected, rng)
		if not step.success:
			errors.append("single-action budget decision produced illegal action: %s" % step.message)

	var choice_options: Array[Dictionary] = []
	choice_options.append({"option_id": "a"})
	choice_options.append({"option_id": "b"})
	var choice_request := ChoiceRequest.new(
		"budget-choice",
		"select",
		actor,
		"Budget choice",
		choice_options,
		1,
		1,
		false,
		false,
	)
	var choice_result := worker.decide({
		"kind": "choice",
		"state": state.snapshot(),
		"choice": choice_request.to_dict(),
		"actor": actor,
		"revision": state.revision,
		"request_id": "budget-choice",
		"mode": "challenge",
		"deck_key": str(state.public_deck_keys[actor]),
		"seed": 434343,
		"simulation_budget": NativeChallengeAI.GAMEPLAY_DEFAULT_SIMULATIONS,
		"seconds": NativeChallengeAI.GAMEPLAY_DEFAULT_SECONDS,
		"max_depth": NativeChallengeAI.GAMEPLAY_DEFAULT_DEPTH,
		"dynamic_budget": NativeChallengeAI.gameplay_dynamic_budget(),
		"deterministic": true,
	}, func() -> bool: return false)
	if not bool(choice_result.get("success", false)):
		errors.append("choice budget decision failed: %s" % choice_result.get("error", "unknown"))
	elif int(choice_result.get("simulations", -1)) != 0:
		errors.append("choice budget decision must return zero simulations")
	return errors


func _play_game(
	mode: String,
	deck_key: String,
	opponent_key: String,
	game_seed: int,
	catalog: CardCatalog,
	engine: GameEngine,
	worker: NativeChallengeAI,
	backend: Variant,
) -> Dictionary:
	var state := GameState.new()
	state.public_deck_keys = [deck_key, opponent_key]
	var rng := PortableRandomSource.new(game_seed)
	var setup := engine.setup_game(
		state,
		catalog.expand_deck(deck_key),
		catalog.expand_deck(opponent_key),
		rng,
	)
	if not setup.success:
		return {"success": false, "error": setup.message}
	var actions_taken := 0
	var decisions := 0
	var choices := 0
	while state.winner < 0 and actions_taken < 1200:
		var pending := ResolutionStack.from_dict(state.resolution_stack).pending_request
		if pending:
			var response: ChoiceResponse
			if pending.player == 0:
				var choice_result := worker.decide({
					"kind": "choice",
					"state": state.snapshot(),
					"choice": pending.to_dict(),
					"actor": 0,
					"revision": state.revision,
					"request_id": "choice:%d" % actions_taken,
					"mode": mode,
					"deck_key": deck_key,
					"seed": game_seed + actions_taken * 31,
					"simulation_budget": 64,
					"max_depth": 1,
					"deterministic": true,
				}, func() -> bool: return false, backend)
				if not choice_result.get("success", false):
					return {"success": false, "error": choice_result.get("error", "choice")}
				response = ChoiceResponse.from_dict(choice_result["choice_response"])
				choices += 1
			else:
				response = _automatic_choice(pending)
			var choice_step := engine.apply_choice(state, pending, response, rng)
			if not choice_step.success:
				return {"success": false, "error": "illegal choice: " + choice_step.message}
			continue

		var actor := _actor(state)
		var legal := engine.legal_actions(state, actor, true)
		if legal.is_empty():
			return {
				"success": false,
				"error": "no legal action phase=%s actor=%d" % [state.phase, actor],
			}
		var action: GameAction
		if actor == 0:
			var rows: Array = []
			for candidate in legal:
				rows.append(candidate.to_dict())
			var decision := worker.decide({
				"kind": "action",
				"state": state.snapshot(),
				"actor": 0,
				"revision": state.revision,
				"request_id": "action:%d" % actions_taken,
				"mode": mode,
				"deck_key": deck_key,
				"seed": game_seed + actions_taken * 7919,
				"simulation_budget": 64,
				"max_depth": 1,
				"deterministic": true,
				"actions": rows,
			}, func() -> bool: return false, backend)
			if not decision.get("success", false):
				return {"success": false, "error": decision.get("error", "decision")}
			if mode == "deep" and decision.get("deep_fallback", false):
				return {
					"success": false,
					"error": "unexpected deep fallback: %s" % decision.get("fallback_reason", ""),
				}
			action = GameAction.from_dict(decision["action"])
			decisions += 1
		else:
			action = _automatic_action(legal, state, catalog)
		action.action_id = "regression:%d:%d" % [state.revision, actions_taken]
		var step := engine.apply_action(state, action, rng)
		if not step.success:
			return {"success": false, "error": "illegal action: " + step.message}
		actions_taken += 1
	return {
		"success": state.winner >= 0,
		"mode": mode,
		"deck": deck_key,
		"opponent": opponent_key,
		"winner": state.winner,
		"actions": actions_taken,
		"decisions": decisions,
		"choices": choices,
		"turns": state.turn_number,
		"error": "" if state.winner >= 0 else "action guard exceeded",
	}


func _actor(state: GameState) -> int:
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		return 0 if not state.setup_ready[0] else 1
	return state.active_player_idx


func _automatic_action(
	actions: Array[GameAction],
	state: GameState,
	catalog: CardCatalog,
) -> GameAction:
	var priority := [
		"PROMOTE", "PLAY_BASIC", "EVOLVE", "ATTACH_ENERGY", "PLAY_TRAINER",
		"USE_ABILITY", "USE_STADIUM", "RETREAT", "DECLARE_ATTACK",
		"SETUP_DONE", "END_TURN",
	]
	var repeatable_fallback: GameAction
	for action_name in priority:
		for action in actions:
			if action.action != action_name:
				continue
			if _is_repeatable_ability_action(state, catalog, action):
				if repeatable_fallback == null:
					repeatable_fallback = action
				continue
			return action
	return repeatable_fallback if repeatable_fallback != null else actions[0]


func _is_repeatable_ability_action(
	state: GameState,
	catalog: CardCatalog,
	action: GameAction,
) -> bool:
	if action.action != "USE_ABILITY":
		return false
	var actor := action.actor if action.actor >= 0 else state.active_player_idx
	if actor not in [0, 1]:
		return false
	var pokemon := state.get_player(actor).get_pokemon(str(action.params.get("slot", "")))
	if pokemon == null:
		return false
	var ability_name := str(action.params.get("ability_name", ""))
	for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("name", "")) == ability_name:
			return str(ability.get("trigger", "")) == "repeatable"
	return false


func _automatic_choice(request: ChoiceRequest) -> ChoiceResponse:
	if request.options.is_empty():
		return ChoiceResponse.new(request.request_id, [])
	var count := mini(
		request.options.size(),
		maxi(request.min_select, request.max_select),
	)
	var selected: Array[String] = []
	if request.allow_duplicates:
		var max_per_target := int(request.metadata.get("max_per_target", 99))
		var per_target: Dictionary = {}
		for index in range(request.options.size()):
			if selected.size() >= count:
				break
			var option: Dictionary = request.options[index]
			var target_key := _automatic_choice_target_key(option)
			if (
				not target_key.is_empty()
				and int(per_target.get(target_key, 0)) >= max_per_target
			):
				continue
			if not target_key.is_empty():
				per_target[target_key] = int(per_target.get(target_key, 0)) + 1
			selected.append(str(option["option_id"]))
		while selected.size() < count:
			selected.append(str(request.options[0]["option_id"]))
	else:
		for index in range(count):
			selected.append(str(request.options[index]["option_id"]))
	return ChoiceResponse.new(request.request_id, selected)


func _automatic_choice_target_key(option: Dictionary) -> String:
	var value_variant: Variant = option.get("value", {})
	if value_variant is Dictionary:
		var value: Dictionary = value_variant
		var slot := str(value.get("slot", ""))
		if not slot.is_empty():
			return slot
	var ref_variant: Variant = option.get("ref", {})
	if ref_variant is Dictionary:
		return str(Dictionary(ref_variant).get("slot", ""))
	return ""
