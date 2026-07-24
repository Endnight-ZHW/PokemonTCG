extends SceneTree

const RELEASE_MANIFEST_PATH := "res://data/release_manifest.json"

var failures: Array[String] = []


func _initialize() -> void:
	var suite_started := Time.get_ticks_msec()
	var memory_before := OS.get_static_memory_usage()
	var release_decks_result := _load_release_deck_keys()
	if not bool(release_decks_result.get("ok", false)):
		push_error(str(release_decks_result.get("error", "Invalid release manifest")))
		quit(1)
		return
	var deck_keys: Array[String] = []
	deck_keys.assign(release_decks_result["value"])
	var catalog := CardCatalog.new()
	var engine := GameEngine.new(catalog)
	var worker := NativeChallengeAI.new()
	var runtime := DeepAIRuntime.new()
	var summaries: Array[Dictionary] = []
	for failure in _budget_contract_failures(catalog, engine, worker):
		failures.append(failure)
	for failure in _new_choice_policy_contract_failures(worker):
		failures.append(failure)
	if runtime.runtime_enabled or runtime.is_available():
		failures.append("legacy Deep runtime must remain disabled for rules v4")
	if runtime.load_for_deck("fire") or runtime.last_error != "deep_runtime_disabled":
		failures.append("disabled Deep runtime did not fail deterministically")
	summaries.append({
		"success": true,
		"mode": "deep",
		"skipped": true,
		"reason": "deep_runtime_disabled",
		"fallback": "challenge",
	})
	for mode in ["challenge"]:
		for index in range(deck_keys.size()):
			var deck_key := str(deck_keys[index])
			var opponent_key := str(deck_keys[(index + 1) % deck_keys.size()])
			var game_started := Time.get_ticks_msec()
			var summary := _play_game(
				mode,
				deck_key,
				opponent_key,
				20260621 + index * 101 + (10000 if mode == "deep" else 0),
				catalog,
				engine,
				worker,
				null,
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


func _load_release_deck_keys() -> Dictionary:
	var file := FileAccess.open(RELEASE_MANIFEST_PATH, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Unable to open %s" % RELEASE_MANIFEST_PATH}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return {"ok": false, "error": "Invalid JSON in %s" % RELEASE_MANIFEST_PATH}
	var manifest: Dictionary = parsed
	var release_decks_value: Variant = manifest.get("release_decks", null)
	if not release_decks_value is Array:
		return {"ok": false, "error": "Release manifest has no release_decks array"}
	var deck_keys: Array[String] = []
	for value in release_decks_value:
		if typeof(value) != TYPE_STRING or str(value).is_empty():
			return {"ok": false, "error": "Release manifest has an invalid deck key"}
		var deck_key := str(value)
		if deck_key in deck_keys:
			return {"ok": false, "error": "Release manifest has duplicate deck keys"}
		deck_keys.append(deck_key)
	if deck_keys.is_empty():
		return {"ok": false, "error": "Release manifest has no release decks"}
	if deck_keys.size() != int(manifest.get("model_count", -1)):
		return {"ok": false, "error": "Release manifest model_count does not match release_decks"}
	if (
		bool(manifest.get("deep_runtime_enabled", true))
		or str(manifest.get("deep_fallback", "")) != "challenge"
		or int(manifest.get("compatible_model_count", -1)) != 0
		or int(manifest.get("legacy_model_count", -1)) != deck_keys.size()
	):
		return {"ok": false, "error": "Release manifest Deep fallback contract is invalid"}
	return {"ok": true, "value": deck_keys}


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
	if str(main_budget.get("engine", "")) != NativeChallengeAI.TRADITIONAL_ENGINE_ID:
		errors.append("gameplay must use turn_beam_v2")
	if int(main_budget.get("max_depth", -1)) != NativeChallengeAI.GAMEPLAY_DEFAULT_DEPTH:
		errors.append("gameplay must use fixed depth eight")
	for retired_key in ["simulation_budget", "seconds", "dynamic_budget", "time_budget_ms"]:
		if main_budget.has(retired_key):
			errors.append("gameplay profile must not expose %s" % retired_key)

	var setup_state := GameState.new()
	setup_state.phase = "SETUP"
	var setup_actions: Array[GameAction] = []
	setup_actions.append(GameAction.new("PLAY_BASIC", {}, false, 0))
	setup_actions.append(GameAction.new("SETUP_DONE", {}, true, 0))
	var setup_budget := NativeChallengeAI.gameplay_action_budget(setup_state, setup_actions)
	if setup_budget != main_budget:
		errors.append("mandatory phases must not silently select a weaker profile")

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
	# Setup now begins with a serialized turn-order Choice. Action budgets are
	# only meaningful after that pending decision has been consumed.
	var setup_pending := engine.query_pending_choice(state, 0)
	if setup_pending == null:
		setup_pending = engine.query_pending_choice(state, 1)
	if setup_pending != null:
		var setup_choice := engine.apply_choice_response(
			state, _automatic_choice(setup_pending), rng)
		if not setup_choice.success:
			errors.append(
				"budget contract setup choice failed: %s" % setup_choice.message)
			return errors
	var actor := _actor(state)
	var legal := RulesTestHarness.legal_actions(engine, state, actor, true)
	if legal.is_empty():
		var budget_pending := engine.query_pending_choice(state, 0)
		if budget_pending == null:
			budget_pending = engine.query_pending_choice(state, 1)
		errors.append(
			(
				"budget contract has no legal action phase=%s setup_stage=%s "
				+ "actor=%d pending_type=%s pending_player=%d"
			) % [
				state.phase,
				state.setup_stage,
				actor,
				budget_pending.request_type if budget_pending != null else "",
				budget_pending.player if budget_pending != null else -1,
			]
		)
		return errors
	var single_actions: Array[GameAction] = []
	single_actions.append(legal[0])
	var single_rows: Array = []
	single_rows.append(legal[0].to_dict())
	var single_decision := worker.decide({
		"kind": "action",
		"state": state.snapshot(),
		"actor": actor,
		"revision": state.revision,
		"request_id": "budget-single",
		"mode": "challenge",
		"deck_key": str(state.public_deck_keys[actor]),
		"seed": 424242,
		"internal_evaluation_smoke": true,
		"deterministic": true,
		"actions": single_rows,
	}, func() -> bool: return false)
	if not bool(single_decision.get("success", false)):
		errors.append("single-action budget decision failed: %s" % single_decision.get("error", "unknown"))
	elif int(single_decision.get("simulations", -1)) != 0:
		errors.append("single-action budget decision must return zero simulations")
	elif str(single_decision.get("completion_reason", "")) != "forced_tactic":
		errors.append("single-action decision must report forced_tactic completion")
	elif str(single_decision.get("planner", "")) != "turn_beam_v2":
		errors.append("single-action decision must report turn_beam_v2")
	else:
		var applied_state := state.clone_state()
		var selected := GameAction.from_dict(single_decision["action"])
		selected.action_id = "budget-contract:%d" % state.revision
		var step := _apply_test_action(engine, applied_state, selected, rng)
		if not step.success:
			errors.append("single-action budget decision produced illegal action: %s" % step.message)

	var choice_options: Array[Dictionary] = []
	choice_options.append({"option_id": "a", "label": "a"})
	choice_options.append({"option_id": "b", "label": "b"})
	var choice_request := ChoiceView.new(
		"budget-choice",
		state.revision,
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
		"internal_evaluation_smoke": true,
		"deterministic": true,
	}, func() -> bool: return false)
	if not bool(choice_result.get("success", false)):
		errors.append("choice budget decision failed: %s" % choice_result.get("error", "unknown"))
	elif int(choice_result.get("simulations", -1)) != 0:
		errors.append("choice budget decision must return zero simulations")
	return errors


func _new_choice_policy_contract_failures(
	worker: NativeChallengeAI,
) -> Array[String]:
	var errors: Array[String] = []
	var state := GameState.new()
	state.public_deck_keys = ["fire", "water"]
	var cases: Array[Dictionary] = [
		{
			"type": "choose_turn_order",
			"options": ["turn:second", "turn:first"],
			"expected": "turn:first",
		},
		{
			"type": "choose_mulligan_draw_count",
			"options": ["draw:0", "draw:2", "draw:1"],
			"expected": "draw:2",
		},
		{
			"type": "select_prize",
			"options": ["prize:5", "prize:1", "prize:3"],
			"expected": "prize:0",
		},
		{
			"type": "confirm_trigger",
			"options": ["trigger:yes", "trigger:no"],
			"expected": "trigger:yes",
		},
		{
			"type": "choose_trigger_order",
			"options": ["trigger:2", "trigger:1"],
			"expected": "",
		},
	]
	for case_index in range(cases.size()):
		var case: Dictionary = cases[case_index]
		var options: Array[Dictionary] = []
		for option_id in case["options"]:
			options.append({"option_id": str(option_id), "label": str(option_id)})
		var request := ChoiceView.new(
			"new-choice:%d" % case_index,
			state.revision,
			str(case["type"]),
			0,
			"choice policy contract",
			options,
			1,
			1,
			false,
			false,
		)
		var payload := {
			"kind": "choice",
			"state": state.snapshot(),
			"choice": request.to_dict(),
			"actor": 0,
			"revision": state.revision,
			"request_id": request.request_id,
			"mode": "challenge",
			"deck_key": "fire",
			"seed": 20260716,
			"deterministic": true,
		}
		var first := worker.decide(payload, func() -> bool: return false)
		var second := worker.decide(payload, func() -> bool: return false)
		if (
			not bool(first.get("success", false))
			or first.get("choice_response", {}) != second.get("choice_response", {})
		):
			errors.append("%s choice was not successful and deterministic" % case["type"])
			continue
		var response := ChoiceResponse.from_dict(first.get("choice_response", {}))
		var public_option_ids: Array[String] = []
		for option in request.options:
			public_option_ids.append(str(option.get("option_id", "")))
		if response.option_ids.size() != 1 or response.option_ids[0] not in public_option_ids:
			errors.append("%s choice returned an illegal option" % case["type"])
			continue
		var expected := str(case["expected"])
		if not expected.is_empty() and response.option_ids[0] != expected:
			errors.append("%s choice policy returned %s, expected %s" % [
				case["type"], response.option_ids[0], expected,
			])

	# Multi-energy effects such as Hawlucha's Display of Power require every
	# selected Energy to use one target. Both Challenge AI and the deterministic
	# opponent policy must repeat a single target option instead of spreading.
	var same_target_options: Array[Dictionary] = [
		{
			"option_id": "pokemon:0:bench_0:first",
			"label": "first",
			"ref": EntityRef.new(
				"pokemon", 0, "", "bench_0", -1, "", "first").to_dict(),
		},
	]
	var same_target_request := ChoiceView.new(
		"new-choice:same-target",
		state.revision,
		"distribute_energy",
		0,
		"same target policy contract",
		same_target_options,
		2,
		2,
		true,
		false,
		{"same_target": true, "max_per_target": 99},
	)
	var same_target_payload := {
		"kind": "choice",
		"state": state.snapshot(),
		"choice": same_target_request.to_dict(),
		"actor": 0,
		"revision": state.revision,
		"request_id": same_target_request.request_id,
		"mode": "challenge",
		"deck_key": "fire",
		"seed": 20260717,
		"deterministic": true,
	}
	var same_target_first := worker.decide(
		same_target_payload, func() -> bool: return false)
	var same_target_second := worker.decide(
		same_target_payload, func() -> bool: return false)
	var challenge_same_target_ids: Array[String] = []
	if bool(same_target_first.get("success", false)):
		challenge_same_target_ids = ChoiceResponse.from_dict(
			same_target_first.get("choice_response", {})).option_ids
	var automatic_same_target_ids := _automatic_choice(
		same_target_request).option_ids
	if (
		not bool(same_target_first.get("success", false))
		or same_target_first.get("choice_response", {})
		!= same_target_second.get("choice_response", {})
		or challenge_same_target_ids.size() != 2
		or challenge_same_target_ids[0] != challenge_same_target_ids[1]
		or automatic_same_target_ids.size() != 2
		or automatic_same_target_ids[0] != automatic_same_target_ids[1]
	):
		errors.append(
			"same_target distribute_energy choice was illegal or nondeterministic")

	# The production worker accepts only the public v2 envelope. A legacy
	# authoritative request and any option-level private payload must fail closed.
	var legacy_request := ChoiceRequest.new(
		"legacy-choice", "select", 0, "legacy", [{"option_id": "a", "label": "a"}])
	var legacy_result := worker.decide({
		"kind": "choice",
		"state": state.snapshot(),
		"choice": legacy_request.to_dict(),
		"actor": 0,
		"revision": state.revision,
		"request_id": legacy_request.request_id,
		"mode": "challenge",
		"deck_key": "fire",
		"seed": 20260718,
	}, func() -> bool: return false)
	if (
		bool(legacy_result.get("success", false))
		or str(legacy_result.get("error", "")) != "invalid_choice_view"
	):
		errors.append("Challenge AI accepted a legacy authoritative ChoiceRequest")
	var private_payload := same_target_request.to_dict()
	private_payload["options"][0]["value"] = {"slot": "bench_0"}
	var private_result := worker.decide({
		"kind": "choice",
		"state": state.snapshot(),
		"choice": private_payload,
		"actor": 0,
		"revision": state.revision,
		"request_id": same_target_request.request_id,
		"mode": "challenge",
		"deck_key": "fire",
		"seed": 20260719,
	}, func() -> bool: return false)
	if (
		bool(private_result.get("success", false))
		or str(private_result.get("error", "")) != "private_choice_field"
	):
		errors.append("Challenge AI accepted a private option value payload")
	var private_presentation := same_target_request.to_dict()
	private_presentation["presentation"]["continuation"] = {"op": "draw"}
	var private_presentation_result := worker.decide({
		"kind": "choice",
		"state": state.snapshot(),
		"choice": private_presentation,
		"actor": 0,
		"revision": state.revision,
		"request_id": same_target_request.request_id,
		"mode": "challenge",
		"deck_key": "fire",
		"seed": 20260720,
	}, func() -> bool: return false)
	if (
		bool(private_presentation_result.get("success", false))
		or str(private_presentation_result.get("error", "")) != "invalid_choice_view"
	):
		errors.append("Challenge AI accepted private presentation continuation data")
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
	while not state.is_terminal() and actions_taken < 1200:
		var pending := engine.query_pending_choice(state, 0)
		if pending == null:
			pending = engine.query_pending_choice(state, 1)
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
					"internal_evaluation_smoke": true,
					"deterministic": true,
				}, func() -> bool: return false, backend)
				if not choice_result.get("success", false):
					return {"success": false, "error": choice_result.get("error", "choice")}
				response = ChoiceResponse.from_dict(choice_result["choice_response"])
				choices += 1
			else:
				response = _automatic_choice(pending, state, catalog)
			var choice_step := engine.apply_choice_response(state, response, rng)
			if not choice_step.success:
				return {
					"success": false,
					"error": (
						"illegal choice: %s phase=%s turn=%d actions=%d "
						+ "request_type=%s request_player=%d presentation=%s "
						+ "response=%s options=%s"
					) % [
						choice_step.message,
						state.phase,
						state.turn_number,
						actions_taken,
						pending.request_type,
						pending.player,
						JSON.stringify(pending.presentation),
						JSON.stringify(response.to_dict()),
						JSON.stringify(pending.options),
					],
				}
			continue

		var actor := _actor(state)
		var legal := RulesTestHarness.legal_actions(engine, state, actor, true)
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
				"internal_evaluation_smoke": true,
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
		var step := _apply_test_action(engine, state, action, rng)
		if not step.success:
			return {
				"success": false,
				"error": "illegal action: %s actor=%d action=%s hand=%s" % [
					step.message,
					actor,
					JSON.stringify(action.to_dict()),
					JSON.stringify(state.get_player(actor).hand),
				],
			}
		actions_taken += 1
	return {
		"success": state.is_terminal(),
		"mode": mode,
		"deck": deck_key,
		"opponent": opponent_key,
		"winner": state.winner,
		"result_status": state.result_status,
		"actions": actions_taken,
		"decisions": decisions,
		"choices": choices,
		"turns": state.turn_number,
		"error": "" if state.is_terminal() else "action guard exceeded",
	}


func _actor(state: GameState) -> int:
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0])
	if state.phase == "SETUP":
		return state.setup_actor_idx
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


func _automatic_choice(
	request: ChoiceView,
	state: GameState = null,
	catalog: CardCatalog = null,
) -> ChoiceResponse:
	if request.options.is_empty():
		return ChoiceResponse.new(request.request_id, [])
	if request.request_type == "choose_turn_order":
		return ChoiceResponse.new(request.request_id, ["turn:first"])
	if request.request_type == "choose_mulligan_draw_count":
		var best_draw := -1
		for option in request.options:
			var option_id := str(option.get("option_id", ""))
			if option_id.begins_with("draw:"):
				best_draw = maxi(best_draw, int(option_id.trim_prefix("draw:")))
		return ChoiceResponse.new(request.request_id, ["draw:%d" % maxi(0, best_draw)])
	if request.request_type == "select_prize":
		var best_prize := 999
		for option in request.options:
			var option_id := str(option.get("option_id", ""))
			if option_id.begins_with("prize:"):
				best_prize = mini(best_prize, int(option_id.trim_prefix("prize:")))
		return ChoiceResponse.new(request.request_id, [
			"prize:%d" % (0 if best_prize == 999 else best_prize)
		])
	if request.request_type == "select_retreat_payment" and state != null and catalog != null:
		return NativeChallengeAI.retreat_payment_response(state, request, catalog)
	var count := maxi(request.min_select, request.max_select)
	if not request.allow_duplicates:
		count = mini(request.options.size(), count)
	var selected: Array[String] = []
	if request.allow_duplicates:
		var max_per_target := int(request.presentation.get("max_per_target", 99))
		if bool(request.presentation.get("same_target", false)):
			for _index in range(mini(count, max_per_target)):
				selected.append(str(request.options[0]["option_id"]))
			return ChoiceResponse.new(request.request_id, selected)
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
	var ref_variant: Variant = option.get("ref", {})
	if ref_variant is Dictionary:
		var slot := str(Dictionary(ref_variant).get("slot", ""))
		if not slot.is_empty():
			return slot
	var parts := str(option.get("option_id", "")).split(":")
	if parts.size() >= 3:
		return str(parts[2])
	return ""


func _apply_test_action(
	engine: GameEngine,
	state: GameState,
	action: GameAction,
	rng: PortableRandomSource,
) -> StepResult:
	var strict_action := action
	if action != null and action.is_legacy_constructed():
		var actor := state.active_player_idx if action.actor < 0 else action.actor
		strict_action = engine._canonicalize_action(state, action, actor)
	return engine.apply_action(state, strict_action, rng)
