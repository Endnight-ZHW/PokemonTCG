extends SceneTree

const FIXTURE_PATH := "res://tests/fixtures/rules_golden.json"
const CARDS_PATH := "res://data/cards.json"
const RuntimeStateProjection = preload("res://ai/runtime_state_projection.gd")


func _initialize() -> void:
	var model_path := OS.get_environment("PTCG_V3_TEST_ONNX")
	if model_path.is_empty():
		push_error("PTCG_V3_TEST_ONNX is required")
		quit(1)
		return
	var fixture := _read_json(FIXTURE_PATH)
	var cards := _read_json(CARDS_PATH)
	cards.merge(Dictionary(fixture.get("test_cards", {})), true)
	var state: Dictionary = Dictionary(
		Dictionary(fixture.get("cases", {}))
		.get("basic_attach_attack", {})
	).get("initial_state", {}).duplicate(true)
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
	var forced_players: Array = state.get("players", [])
	var actor_row: Dictionary = forced_players[0]
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
	var opponent_row: Dictionary = forced_players[1]
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
	state["players"] = forced_players
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
		push_error("formal legal action query failed")
		quit(1)
		return
	var actions: Array = []
	var expected_signatures: Array[String] = []
	for action in legal.concrete_actions():
		actions.append(action.to_dict())
		expected_signatures.append(AIPositionEvaluator.action_signature(action))

	var runtime_state := RuntimeStateProjection.project(formal_state, 0)

	var backend: Variant = ClassDB.instantiate("OnnxInference")
	var loaded: bool = backend.load_model(model_path, {
		"format_version": 4,
		"opset": 17,
		"model_variant": "universal_infoset_transformer_v3",
		"state_global_size": 192,
		"entity_slots": 160,
		"entity_numeric_size": 24,
		"entity_type_fields": 4,
		"candidate_numeric_size": 48,
		"candidate_ref_fields": 8,
		"onnx_sha256": FileAccess.get_sha256(model_path),
	})
	if not loaded:
		push_error("test ONNX load failed: %s" % backend.get_last_error())
		quit(1)
		return
	var kernel: Variant = ClassDB.instantiate("NativeDeepSearch")
	kernel.set_catalog(cards)
	kernel.set_decks(decks)
	var planner := InformationSetPUCT.new()
	planner._native = kernel
	var result: Dictionary = planner.decide({
		"kind": "action",
		"state": runtime_state,
		"actor": 0,
		"revision": int(runtime_state.get("revision", 0)),
		"request_id": "native-runtime-contract",
		"match_instance_id": "native-runtime-choice-chain",
		"seed": 918273,
		"actions": actions,
	}, Callable(), backend)
	if (
		not bool(result.get("success", false))
		or str(result.get("action_signature", "")) not in expected_signatures
		or int(result.get("simulations", 0)) <= 0
		or float(result.get("elapsed_ms", 99999.0)) > 2100.0
	):
		push_error("native runtime search failed: %s" % JSON.stringify(result))
		quit(1)
		return

	var selected_action := GameAction.from_dict(result.get("action", {}))
	if selected_action == null or selected_action.kind != "PLAY_TRAINER":
		push_error(
			"native runtime fixture did not select the forced trainer: %s"
			% JSON.stringify(result)
		)
		backend.unload_model()
		quit(1)
		return
	selected_action.action_id = "native-runtime-choice-action"
	var applied := engine.apply_action(
		formal_state,
		selected_action,
		PortableRandomSource.new(918273),
	)
	var pending := engine.query_pending_choice(formal_state, 0)
	if not applied.success or pending == null:
		push_error("forced trainer did not produce a formal choice root")
		backend.unload_model()
		quit(1)
		return
	var choice_runtime_state := RuntimeStateProjection.project(formal_state, 0)
	var choice_result: Dictionary = planner.decide({
		"kind": "choice",
		"state": choice_runtime_state,
		"choice": pending.to_dict(),
		"actor": 0,
		"revision": formal_state.revision,
		"request_id": "native-runtime-choice",
		"match_instance_id": "native-runtime-choice-chain",
		"seed": 918274,
	}, Callable(), backend)
	if not bool(choice_result.get("success", false)):
		push_error(
			"native runtime choice search failed: %s"
			% JSON.stringify(choice_result)
		)
		backend.unload_model()
		quit(1)
		return
	var response := ChoiceResponse.from_dict(
		choice_result.get("choice_response", {})
	)
	var choice_step := engine.apply_choice_response(
		formal_state,
		response,
		PortableRandomSource.new(918274),
	)
	backend.unload_model()
	if not choice_step.success:
		push_error(
			"native runtime choice was rejected by formal rules: %s"
			% choice_step.message
		)
		quit(1)
		return
	print(
		"NATIVE_SEARCH_RUNTIME_CONTRACT_OK simulations=%d choice_simulations=%d elapsed_ms=%.3f"
		% [
			int(result.get("simulations", 0)),
			int(choice_result.get("simulations", 0)),
			float(result.get("elapsed_ms", 0.0)),
		]
	)
	quit(0)


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}
