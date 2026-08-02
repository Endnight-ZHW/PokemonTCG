extends SceneTree

const FIXTURE_PATH := "res://tests/fixtures/rules_golden.json"
const CARDS_PATH := "res://data/cards.json"

var failures: Array[String] = []


func _initialize() -> void:
	_run()
	if failures.is_empty():
		print("NATIVE_GAME_GOLDEN_OK")
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
	var cards := _read_json(CARDS_PATH)
	cards.merge(Dictionary(fixture.get("test_cards", {})), true)
	var catalog := CardCatalog.new(true)
	catalog.cards = cards.duplicate(true)
	var engine := GameEngine.new(catalog)
	var kernel: Variant = ClassDB.instantiate("NativeDeepSearch")
	kernel.vm_set_cards(cards)
	var contract: Dictionary = kernel.vm_contract()
	_check(
		int(contract.get("implemented_op_count", 0)) == 80
		and int(contract.get("required_op_count", 0)) == 80
		and int(contract.get("game_abi_version", 0)) == 1
		and int(contract.get("game_card_count", 0)) == cards.size(),
		"native game/VM contract is incomplete",
	)
	var cases: Dictionary = fixture.get("cases", {})
	_check(cases.size() == 23, "native game golden must contain 23 cases")
	for case_name_value in cases:
		_run_case(
			str(case_name_value),
			Dictionary(cases[case_name_value]),
			kernel,
			engine,
		)
	_check_choice_candidates(kernel)


func _check_choice_candidates(kernel: Variant) -> void:
	var candidates: Array = kernel.game_choice_candidates({
		"request_id": "choice-17",
		"min_select": 1,
		"max_select": 2,
		"allow_duplicates": false,
		"can_cancel": true,
		"options": [
			{"option_id": "a"},
			{"option_id": "b"},
			{"option_id": "c"},
		],
	})
	var signatures: Array[String] = []
	for row in candidates:
		signatures.append(str(Dictionary(row).get("signature", "")))
	_check(
		signatures == [
			"choice:choice-17:a",
			"choice:choice-17:b",
			"choice:choice-17:c",
			"choice:choice-17:a|b",
			"choice:choice-17:a|c",
			"choice:choice-17:b|c",
			"choice:choice-17:cancel",
		],
		"native choice candidates do not cover combinations/cancel",
	)


func _run_case(
	case_name: String,
	row: Dictionary,
	kernel: Variant,
	engine: GameEngine,
) -> void:
	var state: Dictionary = Dictionary(row.get("initial_state", {})).duplicate(true)
	var initial_actions: Array = row.get("actions", [])
	if not initial_actions.is_empty():
		var actor := int(Dictionary(initial_actions[0]).get("actor", -1))
		_check_legal_actions(case_name, state, actor, kernel, engine)
	var rng_state := int(row.get("portable_seed", 0))
	var trace: Array = row.get("trace", [])
	var trace_index := 0
	var last_result: Dictionary = {}
	for action_value in row.get("actions", []):
		last_result = kernel.game_apply_action(
			state,
			Dictionary(action_value),
			rng_state,
		)
		if not _check_step(
			case_name,
			trace_index,
			Dictionary(trace[trace_index]),
			last_result,
		):
			return
		state = Dictionary(last_result.get("state", {}))
		rng_state = int(last_result.get("rng_state", 0))
		trace_index += 1

	var pending: Dictionary = row.get("pending_after_action", {})
	if not pending.is_empty():
		_check(
			_deep_equal(last_result.get("pending", {}), pending.get("request", {})),
			"native game pending request mismatch for %s" % case_name,
		)
		var response: Dictionary = row.get("choice_response", {})
		last_result = kernel.game_resume_choice(
			state,
			Dictionary(last_result.get("continuation", {})),
			Array(response.get("selected_options", [])),
			bool(response.get("cancelled", false)),
			rng_state,
		)
		if not _check_step(
			case_name,
			trace_index,
			Dictionary(trace[trace_index]),
			last_result,
		):
			return
		state = Dictionary(last_result.get("state", {}))
		rng_state = int(last_result.get("rng_state", 0))
		trace_index += 1

	for action_value in row.get("followup_actions", []):
		last_result = kernel.game_apply_action(
			state,
			Dictionary(action_value),
			rng_state,
		)
		if not _check_step(
			case_name,
			trace_index,
			Dictionary(trace[trace_index]),
			last_result,
		):
			return
		state = Dictionary(last_result.get("state", {}))
		rng_state = int(last_result.get("rng_state", 0))
		trace_index += 1

	_check(
		trace_index == trace.size(),
		"native game trace count mismatch for %s" % case_name,
	)
	_check(
		_deep_equal(_state_projection(state), row.get("expected", {})),
		"native game final state mismatch for %s" % case_name,
	)
	_check(
		rng_state == int(row.get("expected_rng_state", -1)),
		"native game final RNG mismatch for %s" % case_name,
	)


func _check_legal_actions(
	case_name: String,
	state_row: Dictionary,
	actor: int,
	kernel: Variant,
	engine: GameEngine,
) -> void:
	var state := GameState.from_dict(state_row)
	var query := engine.query_legal_action_groups(state, actor)
	if not query.success:
		failures.append(
			"formal legal query failed for %s: %s" % [
				case_name,
				query.code,
			]
		)
		return
	var expected: Array[String] = []
	for action in query.concrete_actions():
		expected.append(AIPositionEvaluator.action_signature(action))
	expected.sort()
	var actual: Array[String] = []
	for action_value in kernel.game_legal_actions(state_row, actor):
		var action_row := Dictionary(action_value)
		var action := GameAction.from_dict(action_row)
		var godot_signature := AIPositionEvaluator.action_signature(action)
		var native_signature := str(kernel.action_signature_v2(action_row))
		_check(
			native_signature == godot_signature,
			"native action signature mismatch for %s: %s != %s" % [
				case_name,
				native_signature,
				godot_signature,
			],
		)
		actual.append(native_signature)
	actual.sort()
	_check(
		actual == expected,
		"native legal action mismatch for %s expected=%s actual=%s" % [
			case_name,
			str(expected),
			str(actual),
		],
	)


func _check_step(
	case_name: String,
	trace_index: int,
	expected: Dictionary,
	actual: Dictionary,
) -> bool:
	if not bool(actual.get("success", false)):
		failures.append(
			"native game step failed %s[%d]: %s" % [
				case_name,
				trace_index,
				str(actual.get("error_code", "")),
			]
		)
		return false
	var expected_pending := _pending_projection(
		Dictionary(expected.get("pending", {}))
	)
	var matches := (
		_deep_equal(
			_state_projection(Dictionary(actual.get("state", {}))),
			expected.get("expected", {}),
		)
		and _deep_equal(
			actual.get("event_types", []),
			expected.get("event_types", []),
		)
		and _canonical_event_contract_valid(actual.get("events", null))
		and _deep_equal(actual.get("pending", {}), expected_pending)
		and int(actual.get("rng_state", -1))
		== int(expected.get("rng_state", -2))
	)
	_check(
		matches,
		"native game semantic mismatch for %s[%d]" % [
			case_name,
			trace_index,
		],
	)
	return matches


func _canonical_event_contract_valid(value: Variant) -> bool:
	if not value is Array:
		return false
	for event_value in value:
		if not event_value is Dictionary:
			return false
		var event := Dictionary(event_value)
		if (
			not event.has("event_type")
			or str(event.get("event_type", "")).is_empty()
			or not event.get("data", null) is Dictionary
		):
			return false
	return true


func _state_projection(source: Dictionary) -> Dictionary:
	var payload: Dictionary = source.duplicate(true)
	payload.erase("action_log")
	payload.erase("resolution_stack")
	payload.erase("setup_ready")
	payload.erase("processed_action_ids")
	for player_value in payload.get("players", []):
		var player: Dictionary = player_value
		var rows: Array = [player.get("active")]
		rows.append_array(player.get("bench", []))
		for pokemon_value in rows:
			if pokemon_value is Dictionary:
				var pokemon: Dictionary = pokemon_value
				for legacy_key in [
					"damage_prevented",
					"all_prevented",
					"outgoing_damage_reduction",
					"attack_locked",
					"attack_locked_names",
					"dazzled",
				]:
					pokemon.erase(legacy_key)
	return payload


func _pending_projection(source: Dictionary) -> Dictionary:
	var payload: Dictionary = source.duplicate(true)
	payload.erase("continuation_operations")
	payload.erase("frame_kinds")
	return payload


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


func _deep_equal(left: Variant, right: Variant) -> bool:
	if (left is int or left is float) and (right is int or right is float):
		return is_equal_approx(float(left), float(right))
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return false
		for key in left:
			if not right.has(key) or not _deep_equal(left[key], right[key]):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index in range(left.size()):
			if not _deep_equal(left[index], right[index]):
				return false
		return true
	return left == right


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
