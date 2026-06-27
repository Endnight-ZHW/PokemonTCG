extends SceneTree

const DEEP_DECK_KEYS := [
	"fire", "water", "psychic", "lightning",
	"fighting", "colorless", "dragon", "grass",
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
	var summaries: Array[Dictionary] = []
	for mode in ["challenge", "deep"]:
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
