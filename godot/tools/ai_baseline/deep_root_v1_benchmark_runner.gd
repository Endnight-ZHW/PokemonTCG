extends SceneTree

## This runner is copied into an isolated worktree at the retired DeepRoot
## commit. It never loads current planner code, model weights, or manifests.

const HISTORICAL_PLANNER_PATH := "res://ai/deep_root_ismcts.gd"
const SIMULATIONS := 64


class UniformInference:
	extends RefCounted

	func is_loaded() -> bool:
		return true

	func supports_choice_head() -> bool:
		return true

	func infer(
		_state_numeric: PackedFloat32Array,
		_state_cards: PackedInt64Array,
		_action_numeric: PackedFloat32Array,
		action_cards: PackedInt64Array,
		_choice_numeric: PackedFloat32Array,
		choice_cards: PackedInt64Array,
	) -> Dictionary:
		var action_logits := PackedFloat32Array()
		action_logits.resize(action_cards.size())
		action_logits.fill(0.0)
		var choice_logits := PackedFloat32Array()
		choice_logits.resize(choice_cards.size())
		choice_logits.fill(0.0)
		return {
			"success": true,
			"action_logits": action_logits,
			"choice_logits": choice_logits,
			"value": 0.0,
			"duration_ms": 0.0,
		}


func _initialize() -> void:
	var options := _arguments()
	var output_path := str(options.get("output", ""))
	var repeats := int(options.get("repeats", 3))
	var seed := int(options.get("seed", 3907))
	if output_path.is_empty() or repeats <= 0:
		push_error("output and positive repeats are required")
		quit(2)
		return
	var planner_script: Variant = load(HISTORICAL_PLANNER_PATH)
	if planner_script == null:
		push_error("retired DeepRoot script is unavailable")
		quit(2)
		return
	var fixture := _find_search_fixture(planner_script, seed)
	if fixture.is_empty():
		push_error("unable to find a retired 64-simulation search fixture")
		quit(1)
		return
	var samples: Array[float] = []
	for repeat in range(repeats + 1):
		var run_seed := seed + repeat * 104729
		var result := _run_once(
			planner_script,
			Dictionary(fixture.get("request", {})),
			run_seed,
		)
		if (
			not bool(result.get("success", false))
			or int(result.get("simulations", -1)) != SIMULATIONS
			or str(result.get("completion_reason", "")) != "search_complete"
		):
			push_error(
				"retired DeepRoot benchmark did not complete 64 simulations: %s"
				% JSON.stringify(result)
			)
			quit(1)
			return
		if repeat > 0:
			samples.append(float(result.get("measured_seconds", 0.0)))
	samples.sort()
	var median_seconds := samples[samples.size() / 2]
	if samples.size() % 2 == 0:
		median_seconds = (
			samples[samples.size() / 2 - 1]
			+ samples[samples.size() / 2]
		) / 2.0
	var payload := {
		"schema": "retired_deeproot_ismcts_v1_measurement/1",
		"historical_commit": "b0f12b5",
		"planner_id": "deep_root_ismcts_v1",
		"simulations_per_search": SIMULATIONS,
		"repeats": repeats,
		"seed": seed,
		"samples_seconds": samples,
		"median_seconds": median_seconds,
		"simulations_per_second": SIMULATIONS / median_seconds,
		"fixture_name": str(fixture.get("name", "")),
		"state": fixture.get("state", {}),
		"actor": int(fixture.get("actor", 0)),
		"decks": fixture.get("decks", {}),
		"compatibility_patch": (
			"pending_promotion_player alias mapped to pending_promotions[0]"
		),
	}
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write historical benchmark output: %s" % output_path)
		quit(2)
		return
	file.store_string(JSON.stringify(payload, "\t") + "\n")
	file.close()
	print(
		"RETIRED_DEEP_ROOT_BENCHMARK_OK median_seconds=%.6f"
		% median_seconds
	)
	quit(0)


func _find_search_fixture(planner_script: Variant, seed: int) -> Dictionary:
	var catalog := CardCatalog.shared()
	var engine := GameEngine.new(catalog)
	var states: Array[Dictionary] = []
	states.append({
		"name": "battle_state_multi_action",
		"state": _battle_state().snapshot(),
	})
	var fixture_file := FileAccess.open(
		"res://tests/fixtures/rules_golden.json",
		FileAccess.READ,
	)
	if fixture_file != null:
		var parsed: Variant = JSON.parse_string(fixture_file.get_as_text())
		if parsed is Dictionary:
			for case_name_value in Dictionary(
				parsed.get("cases", {})
			):
				var case_row := Dictionary(
					Dictionary(parsed.get("cases", {}))[case_name_value]
				)
				states.append({
					"name": "rules_golden:" + str(case_name_value),
					"state": Dictionary(
						case_row.get("initial_state", {})
					).duplicate(true),
				})
	for row_value in states:
		var row := Dictionary(row_value)
		var state := GameState.from_dict(
			Dictionary(row.get("state", {}))
		)
		state.phase = "MAIN"
		state.active_player_idx = 0
		state.turn_number = maxi(3, state.turn_number)
		state.first_player_idx = 1
		state.public_deck_keys = ["psychic", "water"]
		state.set_type_matchups_enabled(false)
		if state.players[0].active == null:
			continue
		var query := engine.query_legal_action_groups(state, 0)
		if not query.success:
			continue
		var actions: Array = []
		for action in query.concrete_actions():
			actions.append(action.to_dict())
		if actions.size() < 2:
			continue
		var request := {
			"kind": "action",
			"state": state.snapshot(),
			"actor": 0,
			"revision": state.revision,
			"request_id": "retired-baseline-probe",
			"mode": "deep",
			"deck_key": "psychic",
			"seed": seed,
			"match_seed": seed,
			"actions": actions,
		}
		var result := _run_once(planner_script, request, seed)
		if (
			bool(result.get("success", false))
			and int(result.get("simulations", -1)) == SIMULATIONS
			and str(result.get("completion_reason", "")) == "search_complete"
		):
			return {
				"name": str(row.get("name", "")),
				"state": state.snapshot(),
				"actor": 0,
				"request": request,
				"decks": _deck_specs_for_state(state),
			}
	return {}


func _run_once(
	planner_script: Variant,
	request_source: Dictionary,
	seed: int,
) -> Dictionary:
	var request := request_source.duplicate(true)
	request["seed"] = seed
	request["match_seed"] = seed
	request["request_id"] = "retired-baseline-%d" % seed
	var planner: Variant = planner_script.new()
	var started := Time.get_ticks_usec()
	var result: Dictionary = planner.decide(
		request,
		func() -> bool: return false,
		UniformInference.new(),
	)
	result["measured_seconds"] = (
		float(Time.get_ticks_usec() - started) / 1000000.0
	)
	return result


func _battle_state() -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.turn_number = 3
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.public_deck_keys = ["psychic", "water"]
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.energy_card_ids = [
		"sv1-ener-5",
		"sv1-ener-5",
	]
	state.players[0].hand = [
		"sv1-ener-5",
		"svi-chim",
		"sv1-151",
	]
	state.players[0].deck = [
		"sv1-ener-5",
		"sv1-ener-5",
		"sv1-ener-5",
	]
	state.players[0].prizes = ["sv1-ener-5"]
	state.players[1].active = PokemonState.new("sv1-104")
	state.players[1].active.placed_this_turn = false
	state.players[1].deck = [
		"sv1-ener-5",
		"sv1-ener-5",
		"sv1-ener-5",
	]
	state.players[1].prizes = ["sv1-ener-5"]
	return state


func _deck_specs_for_state(state: GameState) -> Dictionary:
	var result := {}
	for player_index in [0, 1]:
		var player := state.players[player_index]
		var cards: Array[String] = []
		cards.append_array(player.hand)
		cards.append_array(player.deck)
		cards.append_array(player.discard)
		cards.append_array(player.prizes)
		for pokemon in [player.active] + player.bench:
			if pokemon == null:
				continue
			cards.append(pokemon.card_id)
			cards.append_array(pokemon.evolution_stack_ids)
			cards.append_array(pokemon.energy_card_ids)
			if not pokemon.attached_tool_id.is_empty():
				cards.append(pokemon.attached_tool_id)
		if state.stadium_owner_idx == player_index:
			if not state.stadium_card_id.is_empty():
				cards.append(state.stadium_card_id)
		result[state.public_deck_keys[player_index]] = cards
	return result


func _arguments() -> Dictionary:
	var result := {}
	var values := OS.get_cmdline_user_args()
	var index := 0
	while index < values.size():
		var key := str(values[index])
		if key.begins_with("--") and index + 1 < values.size():
			result[key.substr(2)] = values[index + 1]
			index += 2
		else:
			index += 1
	return result
