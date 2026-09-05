extends SceneTree

const RELEASE_MANIFEST_PATH := "res://data/release_manifest.json"
const RuntimeStateProjection = preload("res://ai/runtime_state_projection.gd")

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
	var requested_deck := ""
	for argument in OS.get_cmdline_user_args():
		if str(argument).begins_with("--ai-deck="):
			requested_deck = str(argument).trim_prefix("--ai-deck=")
	if not requested_deck.is_empty() and requested_deck not in deck_keys:
		push_error("Unknown AI regression deck filter: %s" % requested_deck)
		quit(1)
		return
	var catalog := CardCatalog.new()
	var engine := GameEngine.new(catalog)
	var worker := ChallengeAIClient.new()
	var summaries: Array[Dictionary] = []
	for failure in _new_choice_policy_contract_failures(worker):
		failures.append(failure)
	for mode in ["challenge"]:
		for index in range(deck_keys.size()):
			var deck_key := str(deck_keys[index])
			if not requested_deck.is_empty() and deck_key != requested_deck:
				continue
			var opponent_key := str(deck_keys[(index + 1) % deck_keys.size()])
			var game_started := Time.get_ticks_msec()
			var summary := _play_game(
				mode,
				deck_key,
				opponent_key,
				20260621 + index * 101,
				catalog,
				engine,
				worker,
			)
			summary["elapsed_ms"] = Time.get_ticks_msec() - game_started
			summaries.append(summary)
			print("AI_REGRESSION_GAME ", JSON.stringify(summary))
			if not bool(summary.get("success", false)):
				failures.append("%s %s: %s" % [
					mode, deck_key, summary.get("error", "unknown")])
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
	return {"ok": true, "value": deck_keys}


func _new_choice_policy_contract_failures(
	worker: ChallengeAIClient,
) -> Array[String]:
	var errors: Array[String] = []
	var history_request := {
		"kind": "action",
		"state": {},
		"actor": 1,
		"revision": 0,
		"actions": [],
		"public_history": [{
			"event_type": "cards_selected",
			"visibility": "public",
			"source": {"player": 0, "zone": "deck"},
			"target": {"player": 0, "zone": "hand"},
			"data": {"player": 0, "card_ids": ["sv1-151"]},
		}],
	}
	if not ChallengeAIClient._request_error(history_request).is_empty():
		errors.append("valid sanitized Challenge public history was rejected")
	var leaked_history_request: Dictionary = history_request.duplicate(true)
	leaked_history_request["public_history"][0]["visibility"] = "owner"
	leaked_history_request["public_history"][0]["data"]["visibility_owner"] = 0
	if ChallengeAIClient._request_error(leaked_history_request) \
			!= "private_public_history":
		errors.append("Challenge request accepted an opponent-private card identity")
	var oversized_history_request: Dictionary = history_request.duplicate(true)
	oversized_history_request["public_history"] = []
	for index in range(ChallengeAIClient.MAX_PUBLIC_HISTORY + 1):
		oversized_history_request["public_history"].append({
			"event_type": "turn_start",
			"visibility": "public",
			"source": {},
			"target": {},
			"data": {},
		})
	if ChallengeAIClient._request_error(oversized_history_request) \
			!= "invalid_public_history":
		errors.append("Challenge request accepted oversized public history")
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
			"state": RuntimeStateProjection.project(state, 0),
			"choice": request.to_dict(),
			"actor": 0,
			"revision": state.revision,
			"request_id": request.request_id,
			"mode": "challenge",
			"deck_key": "fire",
			"seed": 20260716,
			"deterministic": true,
			"public_history": history_request["public_history"].duplicate(true),
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

	# Arven may expose only Item cards when no Tool remains in the deck. Both
	# native Challenge AI and the deterministic opponent must respect the
	# one-per-category contract instead of blindly filling max_select.
	var arven_options: Array[Dictionary] = []
	var arven_card_ids: Array[String] = [
		"sv1-150",
		"sv1-153",
		"sv2-catch",
	]
	for index in range(3):
		var card_id: String = arven_card_ids[index]
		arven_options.append({
			"option_id": "option:%d" % index,
			"label": card_id,
			"ref": EntityRef.new(
				"card", 0, "deck", "", index, "", card_id,
			).to_dict(),
		})
	var arven_request := ChoiceView.new(
		"new-choice:arven-category",
		state.revision,
		"arven",
		0,
		"选择物品与宝可梦道具",
		arven_options,
		0,
		2,
		false,
		false,
		{"domain": "search", "purpose": "arven", "category_limits": {
			"item": 1, "tool": 1,
		}},
	)
	var arven_payload := {
		"kind": "choice",
		"state": RuntimeStateProjection.project(state, 0),
		"choice": arven_request.to_dict(),
		"actor": 0,
		"revision": state.revision,
		"request_id": arven_request.request_id,
		"mode": "challenge",
		"deck_key": "fire",
		"seed": 20260716,
		"deterministic": true,
	}
	var arven_result := worker.decide(
		arven_payload, func() -> bool: return false)
	var arven_response := ChoiceResponse.from_dict(
		arven_result.get("choice_response", {}))
	var automatic_arven := _automatic_choice(
		arven_request, state, CardCatalog.shared())
	if (
		not bool(arven_result.get("success", false))
		or arven_response.option_ids.size() != 1
		or automatic_arven.option_ids.size() != 1
	):
		errors.append("Arven category limits were not preserved by both AI policies")

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
		"state": RuntimeStateProjection.project(state, 0),
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
	var legacy_request := {
		"request_id": "legacy-choice",
		"request_type": "select",
		"player": 0,
		"prompt": "legacy",
		"options": [{"option_id": "a", "label": "a"}],
		"min_select": 1,
		"max_select": 1,
		"allow_duplicates": false,
		"can_cancel": false,
	}
	var legacy_result := worker.decide({
		"kind": "choice",
		"state": RuntimeStateProjection.project(state, 0),
		"choice": legacy_request,
		"actor": 0,
		"revision": state.revision,
		"request_id": str(legacy_request["request_id"]),
		"mode": "challenge",
		"deck_key": "fire",
		"seed": 20260718,
	}, func() -> bool: return false)
	if (
		bool(legacy_result.get("success", false))
		or str(legacy_result.get("error", "")) != "invalid_choice_view"
	):
		errors.append("Challenge AI accepted an unversioned choice envelope")
	var private_payload := same_target_request.to_dict()
	private_payload["options"][0]["value"] = {"slot": "bench_0"}
	var private_result := worker.decide({
		"kind": "choice",
		"state": RuntimeStateProjection.project(state, 0),
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
		"state": RuntimeStateProjection.project(state, 0),
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
	worker: ChallengeAIClient,
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
	var recent_actions: Array[Dictionary] = []
	var match_instance_id := "ai-regression:%s:%d" % [mode, game_seed]
	while not state.is_terminal() and actions_taken < 1200:
		var pending := engine.query_pending_choice(state, 0)
		if pending == null:
			pending = engine.query_pending_choice(state, 1)
		if pending:
			var response: ChoiceResponse
			if pending.player == 0:
				var choice_result := worker.decide({
					"kind": "choice",
					"state": RuntimeStateProjection.project(state, 0),
					"choice": pending.to_dict(),
					"actor": 0,
					"revision": state.revision,
					"request_id": "choice:%d" % actions_taken,
					"mode": mode,
					"match_instance_id": match_instance_id,
					"deck_key": deck_key,
					"seed": game_seed + actions_taken * 31,
					"internal_evaluation_smoke": true,
					"deterministic": true,
				}, func() -> bool: return false)
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
		var legal_query := engine.query_legal_action_groups(state, actor)
		var legal := legal_query.concrete_actions() if legal_query.success else []
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
				"state": RuntimeStateProjection.project(state, 0),
				"actor": 0,
				"revision": state.revision,
				"request_id": "action:%d" % actions_taken,
				"mode": mode,
				"match_instance_id": match_instance_id,
				"deck_key": deck_key,
				"seed": game_seed + actions_taken * 7919,
				"internal_evaluation_smoke": true,
				"deterministic": true,
				"actions": rows,
			}, func() -> bool: return false)
			if not decision.get("success", false):
				return {"success": false, "error": decision.get("error", "decision")}
			action = GameAction.from_dict(decision["action"])
			decisions += 1
		else:
			action = _automatic_action(legal, state, catalog)
		action.action_id = "regression:%d:%d" % [state.revision, actions_taken]
		recent_actions.append({
			"turn": state.turn_number,
			"phase": state.phase,
			"actor": actor,
			"kind": action.kind,
			"source": action.source.to_dict() if action.source else null,
			"target": action.target.to_dict() if action.target else null,
			"payload": action.payload.duplicate(true),
		})
		if recent_actions.size() > 40:
			recent_actions.pop_front()
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
		"error": (
			""
			if state.is_terminal()
			else "action guard exceeded recent=%s" % JSON.stringify(
				recent_actions)
		),
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
			if action.kind != action_name:
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
	if action.kind != "USE_ABILITY":
		return false
	var actor := action.actor if action.actor >= 0 else state.active_player_idx
	if actor not in [0, 1]:
		return false
	var pokemon := state.get_player(actor).get_pokemon(str(action.primary_slot()))
	if pokemon == null:
		return false
	var ability_name := str(action.ability_name())
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
		return _retreat_payment_response(state, request, catalog)
	var count := maxi(request.min_select, request.max_select)
	if not request.allow_duplicates:
		count = mini(request.options.size(), count)
	var selected: Array[String] = []
	var category_limits: Dictionary = request.presentation.get("category_limits", {})
	var category_counts: Dictionary = {}
	for index in range(count):
		var chosen_id := ""
		for offset in range(request.options.size()):
			var option_index := (index + offset) % request.options.size()
			var option: Dictionary = request.options[option_index]
			var option_id := str(option.get("option_id", ""))
			if option_id.is_empty() or (not request.allow_duplicates and option_id in selected):
				continue
			var category := _automatic_choice_category(option, catalog)
			var limit := int(category_limits.get(category, 2147483647))
			if not category.is_empty() and int(category_counts.get(category, 0)) >= limit:
				continue
			chosen_id = option_id
			if not category.is_empty():
				category_counts[category] = int(category_counts.get(category, 0)) + 1
			break
		if chosen_id.is_empty():
			break
		selected.append(chosen_id)
	return ChoiceResponse.new(request.request_id, selected)


func _automatic_choice_category(option: Dictionary, catalog: CardCatalog) -> String:
	if catalog == null:
		return ""
	var ref: Dictionary = option.get("ref", {})
	var card: Dictionary = catalog.get_card(str(ref.get("card_id", "")))
	var supertype := str(card.get("supertype", ""))
	var subtypes: Array = card.get("subtypes", [])
	if supertype == "Pokémon":
		return "pokemon"
	if supertype == "Energy":
		return "energy"
	if supertype == "Trainer" and "Item" in subtypes:
		return "item"
	if supertype == "Trainer" and "Tool" in subtypes:
		return "tool"
	return "trainer" if supertype == "Trainer" else ""


func _retreat_payment_response(
	state: GameState,
	request: ChoiceView,
	catalog: CardCatalog,
) -> ChoiceResponse:
	var required_units := maxi(0, int(request.presentation.get("required_units", 0)))
	var active: PokemonState = state.get_player(request.player).active
	if required_units <= 0 or active == null:
		return ChoiceResponse.new(request.request_id, [], request.can_cancel)
	var candidates: Array[Dictionary] = []
	for option_order in range(request.options.size()):
		var option: Dictionary = request.options[option_order]
		var ref: Dictionary = option.get("ref", {})
		var index := int(ref.get("index", -1))
		if (
			str(ref.get("attachment_type", "")) != "energy"
			or index < 0
			or index >= active.energy_card_ids.size()
		):
			continue
		var units := EnergyView.units_provided_by_card(
			active.energy_card_ids, index, catalog)
		if units > 0:
			candidates.append({
				"option_id": str(option.get("option_id", "")),
				"units": units,
				"index": index,
				"order": option_order,
			})
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
	for index in range(selected.size() - 1, -1, -1):
		if paid_units - int(selected[index]["units"]) >= required_units:
			paid_units -= int(selected[index]["units"])
			selected.remove_at(index)
	var option_ids: Array[String] = []
	for candidate in selected:
		option_ids.append(str(candidate["option_id"]))
	return ChoiceResponse.new(request.request_id, option_ids)


func _apply_test_action(
	engine: GameEngine,
	state: GameState,
	action: GameAction,
	rng: PortableRandomSource,
) -> StepResult:
	return engine.apply_action(state, action, rng)
