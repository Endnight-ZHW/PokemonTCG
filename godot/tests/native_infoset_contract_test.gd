extends SceneTree

const FIXTURE_PATH := "res://tests/fixtures/rules_golden.json"

var failures: Array[String] = []


func _initialize() -> void:
	_run()
	if failures.is_empty():
		print("NATIVE_INFOSET_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run() -> void:
	if not ClassDB.class_exists("NativeDeepSearch"):
		failures.append("NativeDeepSearch GDExtension class is unavailable")
		return
	var fixture := _read_json(FIXTURE_PATH)
	var cases: Dictionary = fixture.get("cases", {})
	if cases.is_empty():
		failures.append("rules golden fixture has no states")
		return
	var first_case: Dictionary = Dictionary(cases[cases.keys()[0]])
	var state: Dictionary = Dictionary(
		first_case.get("initial_state", {})
	).duplicate(true)
	state["players"][0]["hand"] = ["own-visible-a", "own-visible-b"]
	state["players"][0]["deck"] = ["own-deck-a", "own-deck-b"]
	state["players"][0]["prizes"] = ["own-prize-a"]
	state["players"][1]["hand"] = ["opponent-hand-a"]
	state["players"][1]["deck"] = ["opponent-deck-a", "opponent-deck-b"]
	state["players"][1]["prizes"] = ["opponent-prize-a"]

	var kernel: Variant = ClassDB.instantiate("NativeDeepSearch")
	var baseline: Dictionary = kernel.project_information_set(state, 0)
	_check(bool(baseline.get("success", false)), "infoset projection failed")
	var observation: Dictionary = baseline.get("observation", {})
	var players: Array = observation.get("players", [])
	_check(
		players.size() == 2
		and players[0]["hand"] == ["own-visible-a", "own-visible-b"]
		and players[0]["deck"] == ["__hidden_card__", "__hidden_card__"]
		and players[1]["hand"] == ["__hidden_card__"]
		and not observation.has("resolution_stack")
		and not observation.has("action_log"),
		"infoset projection retained a hidden identity or private frame",
	)

	var hidden_variant := state.duplicate(true)
	hidden_variant["players"][0]["deck"] = [
		"changed-own-deck-b", "changed-own-deck-a",
	]
	hidden_variant["players"][0]["prizes"] = ["changed-own-prize"]
	hidden_variant["players"][1]["hand"] = ["changed-opponent-hand"]
	hidden_variant["players"][1]["deck"] = [
		"changed-opponent-deck-b", "changed-opponent-deck-a",
	]
	hidden_variant["players"][1]["prizes"] = ["changed-opponent-prize"]
	var changed: Dictionary = kernel.project_information_set(hidden_variant, 0)
	_check(
		changed.get("observation", {}) == baseline.get("observation", {})
		and changed.get("public_hash") == baseline.get("public_hash")
		and changed.get("actor_private_hash")
			== baseline.get("actor_private_hash")
		and changed.get("tree_key") == baseline.get("tree_key"),
		"hidden-zone identities changed an observation or tree key",
	)

	var own_hand_variant := hidden_variant.duplicate(true)
	own_hand_variant["players"][0]["hand"] = [
		"own-visible-a", "changed-own-visible",
	]
	var own_changed: Dictionary = kernel.project_information_set(
		own_hand_variant, 0)
	_check(
		own_changed.get("public_hash") == baseline.get("public_hash")
		and own_changed.get("actor_private_hash")
			!= baseline.get("actor_private_hash")
		and own_changed.get("tree_key") != baseline.get("tree_key"),
		"actor-visible hand did not participate only in private/tree hashes",
	)

	var runtime_state := state.duplicate(true)
	runtime_state.erase("resolution_stack")
	for player_index in [0, 1]:
		var player: Dictionary = runtime_state["players"][player_index]
		player["deck"] = _hidden_cards(player["deck"].size(), "__hidden_card__")
		player["prizes"] = _hidden_cards(
			player["prizes"].size(), "__hidden_prize__")
		if player_index != 0:
			player["hand"] = _hidden_cards(
				player["hand"].size(), "__hidden_card__")
		runtime_state["players"][player_index] = player
	_check(
		str(kernel.validate_runtime_snapshot(runtime_state, 0)).is_empty(),
		"sanitized runtime snapshot was rejected",
	)
	var leaked := runtime_state.duplicate(true)
	leaked["players"][1]["hand"] = ["secret-card-id"]
	_check(
		str(kernel.validate_runtime_snapshot(leaked, 0))
			== "hidden_identity_exposed:players[1].hand",
		"opponent hand identity was not rejected at the native boundary",
	)


func _hidden_cards(count: int, marker: String) -> Array[String]:
	var result: Array[String] = []
	result.resize(count)
	result.fill(marker)
	return result


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("cannot open fixture: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		failures.append("fixture is not a dictionary: %s" % path)
		return {}
	return parsed


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
