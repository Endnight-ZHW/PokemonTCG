class_name CandidateRuntimeVerifier
extends RefCounted

const FORMAT_VERSION := 1
const RULES_FIXTURE := "res://tests/fixtures/rules_golden.json"
const CARDS_PATH := "res://data/cards.json"
const SEARCH_DEADLINE_MS := 2000.0


func verify(
	runtime_path: String,
	release_path: String,
	candidate_path: String,
) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var runtime := DeepAIRuntime.new(runtime_path, release_path)
	var release_decks: Array[String] = []
	release_decks.assign(runtime.release_manifest.get("release_decks", []))
	var model_rows_value: Variant = runtime.manifest.get("models", {})
	var model_rows: Dictionary = (
		model_rows_value if model_rows_value is Dictionary else {}
	)
	var rows := {}
	var errors: Array[String] = []
	var encoder_contract_passed := _v3_contract_available()
	if not encoder_contract_passed:
		errors.append("encoder_contract")
	if (
		not runtime.runtime_enabled
		or int(runtime.release_manifest.get("model_count", 0)) != 1
		or model_rows.size() != 1
	):
		errors.append("candidate_manifest_contract")

	for deck_key in release_decks:
		var route := str(Dictionary(runtime.manifest.get(
			"deck_routes", {})).get(deck_key, ""))
		var row_value: Variant = model_rows.get(route, {})
		var row: Dictionary = (
			row_value if row_value is Dictionary else {}
		)
		var model_path := str(row.get("onnx_path", ""))
		if not FileAccess.file_exists(model_path):
			var staged_path := (
				runtime_path.get_base_dir()
				.path_join("ai_models")
				.path_join("%s.onnx" % route)
			)
			if FileAccess.file_exists(staged_path):
				model_path = staged_path
				row["onnx_path"] = staged_path
				model_rows[route] = row
				runtime.manifest["models"] = model_rows
		var actual_hash := FileAccess.get_sha256(model_path)
		var loaded := runtime.load_for_deck(deck_key)
		var scenarios: Array = []
		if loaded:
			var backend: Variant = runtime.get_backend()
			scenarios.append(_infer_scenario(backend, false))
			scenarios.append(_infer_scenario(backend, true))
			for scenario in scenarios:
				if not bool(Dictionary(scenario).get("passed", false)):
					errors.append("%s:inference" % deck_key)
					break
		else:
			errors.append("%s:%s" % [deck_key, runtime.last_error])
		rows[deck_key] = {
			"loaded": loaded,
			"runtime_error": runtime.last_error,
			"onnx_path": model_path,
			"onnx_sha256": actual_hash,
			"expected_onnx_sha256": str(row.get("onnx_sha256", "")),
			"hash_matches": (
				not actual_hash.is_empty()
				and actual_hash == str(row.get("onnx_sha256", ""))
			),
			"scenarios": scenarios,
		}
		if not bool(rows[deck_key]["hash_matches"]):
			errors.append("%s:hash" % deck_key)
		runtime.unload()

	var search_probe := {
		"passed": false,
		"search_deadline_passed": false,
		"minimum_simulations_passed": false,
		"illegal_actions": 0,
		"timeouts": 0,
		"degraded": 0,
	}
	if not release_decks.is_empty() and runtime.load_for_deck(release_decks[0]):
		search_probe = _native_search_probe(runtime.get_backend())
	else:
		errors.append("native_search_model:%s" % runtime.last_error)
	runtime.unload()
	if not bool(search_probe.get("passed", false)):
		errors.append("native_search_contract")
	var fallback_probe := _fallback_probe()
	if not bool(fallback_probe.get("passed", false)):
		errors.append("challenge_fallback_contract")

	var backend_available := ClassDB.class_exists("OnnxInference")
	return {
		"format_version": FORMAT_VERSION,
		"kind": "deep_ai_v3_candidate_runtime/1",
		"platform": OS.get_name().to_lower(),
		"architecture": Engine.get_architecture_name(),
		"native_extension": backend_available,
		"encoder_contract_passed": encoder_contract_passed,
		"candidate_manifest_sha256": FileAccess.get_sha256(candidate_path),
		"runtime_manifest_sha256": FileAccess.get_sha256(runtime_path),
		"release_manifest_sha256": FileAccess.get_sha256(release_path),
		"deep_planner": runtime.manifest.get("deep_planner", {}),
		"model_count": model_rows.size(),
		"route_count": rows.size(),
		"models": rows,
		"search": search_probe,
		"fallback_probe": fallback_probe,
		"search_deadline_passed": bool(
			search_probe.get("search_deadline_passed", false)),
		"minimum_simulations_passed": bool(
			search_probe.get("minimum_simulations_passed", false)),
		"fallback_path_passed": bool(
			fallback_probe.get("passed", false)),
		"illegal_actions": int(search_probe.get("illegal_actions", 0)),
		"timeouts": int(search_probe.get("timeouts", 0)),
		"degraded": int(search_probe.get("degraded", 0)),
		# This counter tracks unintended Deep fallbacks. The explicit fallback
		# probe above is a contract check and is therefore not counted here.
		"fallbacks": 0,
		"errors": errors,
		"passed": errors.is_empty() and backend_available,
		"elapsed_ms": round(
			float(Time.get_ticks_usec() - started_usec) / 1000.0 * 1000.0
		) / 1000.0,
	}


func _native_search_probe(backend: Variant) -> Dictionary:
	var failure := {
		"passed": false,
		"search_deadline_passed": false,
		"minimum_simulations_passed": false,
		"illegal_actions": 0,
		"timeouts": 0,
		"degraded": 0,
		"error": "",
	}
	if backend == null:
		failure["error"] = "backend_unavailable"
		return failure
	var fixture := _read_json(RULES_FIXTURE)
	var cards := _read_json(CARDS_PATH)
	cards.merge(Dictionary(fixture.get("test_cards", {})), true)
	var state: Dictionary = Dictionary(
		Dictionary(fixture.get("cases", {}))
		.get("basic_attach_attack", {})
	).get("initial_state", {}).duplicate(true)
	if state.is_empty() or cards.is_empty():
		failure["error"] = "search_fixture_missing"
		return failure
	state["public_deck_keys"] = ["runtime-a", "runtime-b"]
	state["phase"] = "MAIN"
	state["turn_number"] = 3
	state["first_player_idx"] = 1
	state["active_player_idx"] = 0
	state["pending_promotions"] = []
	state["resolution_stack"] = {
		"schema_version": 3,
		"frames": [],
		"pending_request": null,
		"sequence": 0,
		"context": {},
	}
	var players: Array = state.get("players", [])
	if players.size() != 2:
		failure["error"] = "search_fixture_players"
		return failure
	var actor_row: Dictionary = players[0]
	actor_row["hand"] = ["svl-ensw"]
	actor_row["deck"] = [
		"sv1-ener-5",
		"sv1-ener-5",
		"sv1-ener-5",
		"sv1-ener-5",
		"sv1-ener-5",
	]
	actor_row["prizes"] = []
	actor_row["bench"] = []
	actor_row["discard"] = []
	actor_row["active"]["card_id"] = "svi-chim"
	actor_row["active"]["energy_card_ids"] = []
	actor_row["active"]["tool_card_ids"] = []
	actor_row["supporter_played_this_turn"] = false
	actor_row["energy_attached_this_turn"] = true
	var opponent_row: Dictionary = players[1]
	opponent_row["hand"] = []
	opponent_row["deck"] = [
		"sv1-ener-5",
		"sv1-ener-5",
		"sv1-ener-5",
		"sv1-ener-5",
		"sv1-ener-5",
	]
	opponent_row["prizes"] = []
	opponent_row["bench"] = []
	opponent_row["discard"] = []
	opponent_row["active"]["card_id"] = "svi-chim"
	opponent_row["active"]["energy_card_ids"] = []
	opponent_row["active"]["tool_card_ids"] = []
	state["players"] = players
	var decks := {
		"runtime-a": [
			"svi-chim",
			"svl-ensw",
			"sv1-ener-5",
			"sv1-ener-5",
			"sv1-ener-5",
			"sv1-ener-5",
			"sv1-ener-5",
		],
		"runtime-b": [
			"svi-chim",
			"sv1-ener-5",
			"sv1-ener-5",
			"sv1-ener-5",
			"sv1-ener-5",
			"sv1-ener-5",
		],
	}
	var catalog := CardCatalog.new(true)
	catalog.cards = cards.duplicate(true)
	var engine := GameEngine.new(catalog)
	var formal_state := GameState.from_dict(state)
	var legal := engine.query_legal_action_groups(formal_state, 0)
	if not legal.success:
		failure["error"] = "formal_legal_query"
		return failure
	var actions: Array = []
	var expected_signatures: Array[String] = []
	var trainer_action: GameAction
	for action in legal.concrete_actions():
		actions.append(action.to_dict())
		expected_signatures.append(
			AIPositionEvaluator.action_signature(action))
		if action.kind == "PLAY_TRAINER" and trainer_action == null:
			trainer_action = action
	if actions.is_empty() or trainer_action == null:
		failure["error"] = "forced_trainer_missing"
		return failure

	var kernel: Variant = ClassDB.instantiate("NativeDeepSearch")
	if kernel == null:
		failure["error"] = "native_search_extension_unavailable"
		return failure
	kernel.call("set_catalog", cards)
	kernel.call("set_decks", decks)
	var planner := InformationSetPUCT.new()
	planner._native = kernel
	var runtime_state := _mask_runtime_state(state, 0)
	var action_result: Dictionary = planner.decide({
		"kind": "action",
		"state": runtime_state,
		"actor": 0,
		"revision": int(runtime_state.get("revision", 0)),
		"request_id": "candidate-runtime-action",
		"match_instance_id": "candidate-runtime-chain",
		"seed": 918273,
		"actions": actions,
	}, Callable(), backend)
	var action_legal := (
		bool(action_result.get("success", false))
		and str(action_result.get(
			"action_signature", "")) in expected_signatures
	)
	if not action_legal:
		failure["illegal_actions"] = 1
		failure["error"] = "native_action_rejected"
		failure["action"] = action_result
		return failure
	var selected_action := GameAction.from_dict(
		action_result.get("action", {}))
	if selected_action == null:
		failure["illegal_actions"] = 1
		failure["error"] = "native_action_missing"
		return failure
	selected_action.action_id = "candidate-runtime-formal-check"
	var action_check_state := GameState.from_dict(state)
	var action_check := engine.apply_action(
		action_check_state,
		selected_action,
		PortableRandomSource.new(918273),
	)
	if not action_check.success:
		failure["illegal_actions"] = 1
		failure["error"] = "formal_selected_action_apply"
		return failure
	trainer_action.action_id = "candidate-runtime-choice-action"
	var applied := engine.apply_action(
		formal_state,
		trainer_action,
		PortableRandomSource.new(918273),
	)
	var pending := engine.query_pending_choice(formal_state, 0)
	if not applied.success or pending == null:
		failure["illegal_actions"] = 1
		failure["error"] = "formal_action_apply"
		return failure
	var choice_result: Dictionary = planner.decide({
		"kind": "choice",
		"state": _mask_runtime_state(formal_state.snapshot(), 0),
		"choice": pending.to_dict(),
		"actor": 0,
		"revision": formal_state.revision,
		"request_id": "candidate-runtime-choice",
		"match_instance_id": "candidate-runtime-chain",
		"seed": 918274,
	}, Callable(), backend)
	if not bool(choice_result.get("success", false)):
		failure["illegal_actions"] = 1
		failure["error"] = "native_choice_rejected"
		failure["choice"] = choice_result
		return failure
	var response := ChoiceResponse.from_dict(
		choice_result.get("choice_response", {}))
	var choice_step := engine.apply_choice_response(
		formal_state,
		response,
		PortableRandomSource.new(918274),
	)
	if not choice_step.success:
		failure["illegal_actions"] = 1
		failure["error"] = "formal_choice_apply"
		return failure
	var minimum := (
		InformationSetPUCT.ANDROID_MIN_SIMULATIONS
		if OS.get_name() == "Android"
		else InformationSetPUCT.WINDOWS_MIN_SIMULATIONS
	)
	var action_elapsed := float(action_result.get("elapsed_ms", INF))
	var choice_elapsed := float(choice_result.get("elapsed_ms", INF))
	var deadline_passed := (
		action_elapsed <= SEARCH_DEADLINE_MS
		and choice_elapsed <= SEARCH_DEADLINE_MS
	)
	var minimum_passed := (
		int(action_result.get("simulations", 0)) >= minimum
		and int(choice_result.get("simulations", 0)) >= minimum
	)
	var degraded := (
		int(bool(action_result.get("degraded_deadline", false)))
		+ int(bool(choice_result.get("degraded_deadline", false)))
	)
	return {
		"passed": deadline_passed and minimum_passed and degraded == 0,
		"search_deadline_passed": deadline_passed,
		"minimum_simulations_passed": minimum_passed,
		"illegal_actions": 0,
		"timeouts": 0 if deadline_passed else 1,
		"degraded": degraded,
		"error": "",
		"minimum_required": minimum,
		"action": action_result,
		"choice": choice_result,
	}


func _fallback_probe() -> Dictionary:
	var fallback := AICoordinator.new().decide_sync_for_evaluation(
		{
			"kind": "action",
			"mode": "deep",
			"engine": "turn_beam_v2",
			"state": GameState.new().to_dict(),
			"actor": 0,
			"revision": 0,
			"request_id": "candidate-runtime-fallback",
			"deck_key": "fire",
			"actions": [],
		},
		null,
	)
	var passed := (
		bool(fallback.get("deep_fallback", false))
		and str(fallback.get("fallback_reason", ""))
		== "runtime_unavailable"
		and str(Dictionary(fallback.get("deep_failure", {})).get(
			"planner", "")) == InformationSetPUCT.PLANNER_ID
	)
	return {
		"passed": passed,
		"fallback_reason": str(fallback.get("fallback_reason", "")),
		"planner": str(Dictionary(fallback.get(
			"deep_failure", {})).get("planner", "")),
	}


func _mask_runtime_state(source: Dictionary, actor: int) -> Dictionary:
	var runtime_state := source.duplicate(true)
	runtime_state.erase("resolution_stack")
	var players: Array = runtime_state.get("players", [])
	for player_index in range(players.size()):
		var player: Dictionary = players[player_index]
		var hidden_deck: Array[String] = []
		hidden_deck.resize(Array(player.get("deck", [])).size())
		hidden_deck.fill("__hidden_card__")
		player["deck"] = hidden_deck
		var hidden_prizes: Array[String] = []
		hidden_prizes.resize(Array(player.get("prizes", [])).size())
		hidden_prizes.fill("__hidden_prize__")
		player["prizes"] = hidden_prizes
		if player_index != actor:
			var hidden_hand: Array[String] = []
			hidden_hand.resize(Array(player.get("hand", [])).size())
			hidden_hand.fill("__hidden_card__")
			player["hand"] = hidden_hand
	runtime_state["players"] = players
	return runtime_state


func _infer_scenario(
	backend: Variant,
	empty_slots: bool,
) -> Dictionary:
	if backend == null:
		return {"passed": false, "error": "backend_unavailable"}
	var state_global := PackedFloat32Array()
	state_global.resize(192)
	var entity_numeric := PackedFloat32Array()
	entity_numeric.resize(160 * 24)
	var entity_cards := PackedInt64Array()
	entity_cards.resize(160)
	var entity_types := PackedInt64Array()
	entity_types.resize(160 * 4)
	var entity_mask := PackedByteArray()
	entity_mask.resize(160)
	if not empty_slots:
		for index in range(160):
			entity_cards[index] = 1 + index % 31
			entity_mask[index] = 1
	var candidate_numeric := PackedFloat32Array()
	candidate_numeric.resize(2 * 48)
	var candidate_cards := PackedInt64Array([1, 2])
	var candidate_types := PackedInt64Array([1, 2])
	var candidate_refs := PackedInt64Array()
	candidate_refs.resize(2 * 8)
	var candidate_mask := PackedByteArray([1, 1])
	var inferred: Dictionary = backend.call(
		"infer_v3",
		state_global,
		entity_numeric,
		entity_cards,
		entity_types,
		entity_mask,
		candidate_numeric,
		candidate_cards,
		candidate_types,
		candidate_refs,
		candidate_mask,
		PackedInt64Array([0]),
		PackedInt64Array([1]),
		1,
		2,
	)
	var finite := true
	for output_name in ["policy_logits", "wdl_logits"]:
		for value in inferred.get(output_name, []):
			finite = finite and is_finite(float(value))
	var passed: bool = (
		bool(inferred.get("success", false))
		and inferred.get("policy_logits", []).size() == 2
		and inferred.get("wdl_logits", []).size() == 3
		and finite
		and str(backend.call("get_execution_provider"))
		== "CPUExecutionProvider"
	)
	return {
		"name": "empty_slots" if empty_slots else "ordinary",
		"passed": passed,
		"error": str(inferred.get("error", "")),
		"finite": finite,
		"policy_outputs": inferred.get("policy_logits", []).size(),
		"wdl_outputs": inferred.get("wdl_logits", []).size(),
		"execution_provider": str(
			backend.call("get_execution_provider")),
	}


func _v3_contract_available() -> bool:
	if not ClassDB.class_exists("OnnxInference"):
		return false
	var probe: Variant = ClassDB.instantiate("OnnxInference")
	if probe == null:
		return false
	var contract_value: Variant = probe.call("get_contract")
	if not contract_value is Dictionary:
		return false
	var contract: Dictionary = contract_value
	return (
		int(contract.get("format_version", 0)) == 4
		and int(contract.get("encoder_version", 0)) == 8
		and str(contract.get("model_variant", ""))
		== "universal_infoset_transformer_v3"
		and int(contract.get("state_global_size", 0)) == 192
		and int(contract.get("entity_slots", 0)) == 160
		and int(contract.get("entity_numeric_size", 0)) == 24
		and int(contract.get("candidate_numeric_size", 0)) == 48
		and int(contract.get("candidate_ref_fields", 0)) == 8
		and int(contract.get("wdl_size", 0)) == 3
	)


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}
