extends SceneTree

const DECK_KEYS := [
	"fire", "water", "psychic", "lightning",
	"fighting", "colorless", "dragon", "grass",
]

var failures: Array[String] = []


func _initialize() -> void:
	var suite_started := Time.get_ticks_msec()
	var memory_before := OS.get_static_memory_usage()
	var catalog := CardCatalog.new()
	var engine := GameEngine.new(catalog)
	var worker := NativeChallengeAI.new()
	var runtime := DeepAIRuntime.new()
	var summaries: Array[Dictionary] = []
	for mode in ["challenge", "deep"]:
		for index in range(DECK_KEYS.size()):
			var deck_key := str(DECK_KEYS[index])
			var opponent_key := str(DECK_KEYS[(index + 1) % DECK_KEYS.size()])
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
					"difficulty": "fast",
					"deck_key": deck_key,
					"seed": game_seed + actions_taken * 31,
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
				"difficulty": "fast",
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
			action = _automatic_action(legal)
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


func _automatic_action(actions: Array[GameAction]) -> GameAction:
	var priority := [
		"PROMOTE", "PLAY_BASIC", "EVOLVE", "ATTACH_ENERGY", "PLAY_TRAINER",
		"USE_ABILITY", "USE_STADIUM", "RETREAT", "DECLARE_ATTACK",
		"SETUP_DONE", "END_TURN",
	]
	for action_name in priority:
		for action in actions:
			if action.action == action_name:
				return action
	return actions[0]


func _automatic_choice(request: ChoiceRequest) -> ChoiceResponse:
	if request.options.is_empty():
		return ChoiceResponse.new(request.request_id, [])
	var count := mini(
		request.options.size(),
		maxi(request.min_select, request.max_select),
	)
	var selected: Array[String] = []
	for index in range(count):
		var option_index := 0 if request.allow_duplicates else index
		selected.append(str(request.options[option_index]["option_id"]))
	return ChoiceResponse.new(request.request_id, selected)
