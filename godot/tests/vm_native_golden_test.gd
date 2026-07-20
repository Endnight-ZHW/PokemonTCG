extends SceneTree

const FIXTURE_PATH := "res://tests/fixtures/vm_native_golden.json"

var failures: Array[String] = []


func _initialize() -> void:
	_run_tests()
	if failures.is_empty():
		print("VM_NATIVE_GOLDEN_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_tests() -> void:
	var fixture := _read_json(FIXTURE_PATH)
	var cases: Dictionary = fixture.get("cases", {})
	var catalog := CardCatalog.new(true)
	var game_engine := GameEngine.new(catalog)
	var effect_engine := RulesTestHarness.effect_engine_for(game_engine)
	var runtime_ops: Array = effect_engine.native_command_ops()
	runtime_ops.sort()
	var registered_ops: Array = fixture.get("registered_ops", [])
	registered_ops.sort()
	_check(
		int(fixture.get("fixture_version", 0)) == 2
		and int(fixture.get("vm_ir_version", 0)) == VMContract.IR_VERSION
		and str(fixture.get("contract", {}).get("name", ""))
		== "native-vm-semantic-parity-v2",
		"native VM golden fixture contract/version mismatch",
	)
	_check(
		cases.size() == 80
		and int(fixture.get("counts", {}).get("registered_ops", 0)) == 80
		and int(fixture.get("counts", {}).get("executed_ops", 0)) == 80
		and int(fixture.get("counts", {}).get("successful_ops", 0)) == 80
		and int(fixture.get("counts", {}).get("pending_ops", 0)) == 28
		and int(fixture.get("counts", {}).get("continued_ops", 0)) == 27
		and int(fixture.get("counts", {}).get("choice_rounds", 0)) == 33,
		"native VM golden fixture must contain 80 successful direct executions",
	)
	_check(
		_deep_equal(runtime_ops, registered_ops)
		and _deep_equal(runtime_ops, fixture.get("executed_ops", [])),
		"native VM golden op inventory differs from the frozen Godot registry",
	)
	for op_value in runtime_ops:
		var op := str(op_value)
		_check(effect_engine.supports_command_handler(op),
			"native VM golden op has no executable Godot handler: %s" % op)
		_check(cases.has(op), "native VM golden case is missing: %s" % op)
		if cases.has(op):
			_run_case(op, Dictionary(cases[op]), game_engine)


func _run_case(op: String, row: Dictionary, game_engine: GameEngine) -> void:
	var effect_engine := RulesTestHarness.effect_engine_for(game_engine)
	var descriptor: Dictionary = row.get("descriptor", {})
	var spec: Dictionary = row.get("command_spec", {})
	_check(
		str(descriptor.get("op", "")) == op
		and bool(descriptor.get("requires_boolean_success", false))
		and str(spec.get("op", "")) == op
		and effect_engine.supports_command_spec(spec),
		"native VM descriptor/spec is invalid for %s" % op,
	)
	var state := GameState.from_dict(Dictionary(row.get("initial_state", {})))
	var rng := PortableRandomSource.new(int(row.get("portable_seed", 0)))
	var stack := ResolutionStack.new()
	var context_mode := str(row.get("context_mode", "ability"))
	if context_mode == "attack":
		stack.context = {
			"finish_attack": true,
			"actor": int(row.get("actor", 0)),
			"base_damage": 30,
		}
	elif context_mode in ["ability", "trainer"]:
		stack.context["effect_source_kind"] = context_mode
	stack.push_effect(
		spec,
		int(row.get("actor", 0)),
		str(row.get("source_slot", "active")),
	)
	var step := effect_engine.resolve(state, stack, rng)
	var expected: Dictionary = row.get("expected", {})
	var actual := {
		"success": step.success,
		"error_code": step.error_code,
		"revision": state.revision,
		"rng_state": rng.get_state(),
		"event_types": _event_types(step),
		"pending": _pending_projection(stack, op),
		"state": _state_projection(state),
		"context": _context_projection(stack.context),
		"modifier": _modifier_probe(state, op),
	}
	var allowlist: Dictionary = row.get("parity_allowlist", {})
	for field in expected:
		if _deep_equal(actual.get(field), expected[field]):
			continue
		if allowlist.has(field):
			continue
		failures.append(
			"VM semantic mismatch %s.%s paths=%s\nexpected=%s\nactual=%s" % [
				op,
				str(field),
				JSON.stringify(_diff_paths(expected[field], actual.get(field))),
				_display_value(expected[field]),
				_display_value(actual.get(field)),
			]
		)
	for allowed_field in allowlist:
		_check(
			not _deep_equal(actual.get(allowed_field), expected.get(allowed_field)),
			"stale VM parity allowlist entry %s.%s" % [op, str(allowed_field)],
		)
	var choice_trace: Array = row.get("choice_trace", [])
	for choice_index in range(choice_trace.size()):
		var choice_row: Dictionary = choice_trace[choice_index]
		var request := stack.pending_request
		if request == null:
			failures.append(
				"VM semantic continuation missing request %s[%d]" % [
					op, choice_index,
				]
			)
			return
		var expected_request: Dictionary = choice_row.get("request", {})
		var actual_request := _pending_projection(stack, op)
		if not _deep_equal(actual_request, expected_request):
			failures.append(
				"VM semantic continuation request mismatch %s[%d] paths=%s" % [
					op,
					choice_index,
					JSON.stringify(_diff_paths(expected_request, actual_request)),
				]
			)
			return
		var response_row: Dictionary = choice_row.get("response", {})
		var selected_semantics: Array = response_row.get("selected_options", [])
		var option_ids := _selected_option_ids(request, selected_semantics)
		if option_ids.size() != selected_semantics.size():
			failures.append(
				"VM semantic continuation cannot bind response %s[%d] selected=%s" % [
					op,
					choice_index,
					JSON.stringify(selected_semantics),
				]
			)
			return
		step = game_engine.apply_choice_response(
			state,
			ChoiceResponse.new(
				request.request_id,
				option_ids,
				bool(response_row.get("cancelled", false)),
			),
			rng,
		)
		stack = ResolutionStack.from_dict(state.resolution_stack)
		var choice_expected: Dictionary = choice_row.get("expected", {})
		var choice_actual := {
			"success": step.success,
			"error_code": step.error_code,
			"revision": state.revision,
			"rng_state": rng.get_state(),
			"event_types": _event_types(step),
			"pending": _pending_projection(stack, op),
			"state": _state_projection(state),
			"context": _context_projection(stack.context),
			"modifier": _modifier_probe(state, op),
		}
		for field in choice_expected:
			if _deep_equal(choice_actual.get(field), choice_expected[field]):
				continue
			failures.append(
				"VM semantic continuation mismatch %s[%d].%s paths=%s\nexpected=%s\nactual=%s" % [
					op,
					choice_index,
					str(field),
					JSON.stringify(_diff_paths(
						choice_expected[field], choice_actual.get(field))),
					_display_value(choice_expected[field]),
					_display_value(choice_actual.get(field)),
				]
			)


func _selected_option_ids(
	request: ChoiceRequest,
	selected_semantics: Array,
) -> Array[String]:
	var result: Array[String] = []
	var used: Dictionary = {}
	for semantic_value in selected_semantics:
		if not semantic_value is Dictionary:
			return []
		var semantic: Dictionary = semantic_value
		var matched_id := ""
		for option_value in request.options:
			var option: Dictionary = option_value
			var option_id := str(option.get("option_id", ""))
			if option_id.is_empty():
				continue
			if not request.allow_duplicates and used.has(option_id):
				continue
			if _deep_equal(
				_canonical_pending_option(option, request.player),
				semantic,
			):
				matched_id = option_id
				break
		if matched_id.is_empty():
			return []
		result.append(matched_id)
		used[matched_id] = true
	return result


func _event_types(step: StepResult) -> Array:
	var result: Array = []
	for event in step.events:
		result.append(str(event.get("event_type", "")))
	return result


func _state_projection(state: GameState) -> Dictionary:
	var payload := state.to_dict()
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
				pokemon.erase("modifiers")
				if pokemon.get("used_abilities") is Dictionary:
					var used: Array = Dictionary(pokemon["used_abilities"]).keys()
					used.sort()
					pokemon["used_abilities"] = used
	return payload


func _pending_projection(stack: ResolutionStack, op: String) -> Dictionary:
	var request := stack.pending_request
	if request == null:
		return {}
	var continuation: Dictionary = Dictionary(request.metadata.get("continuation", {}))
	var continuation_kind := _canonical_continuation_kind(
		continuation.get("kind", ""))
	if continuation_kind.is_empty() and not stack.frames.is_empty():
		var frame: Dictionary = stack.frames[-1]
		if str(frame.get("kind", "")) == "continuation":
			continuation_kind = _canonical_continuation_kind(
				frame.get("operation", ""))
	var request_type := request.request_type
	if continuation_kind == "search_move":
		request_type = "search_move"
	elif continuation_kind == "heal_target":
		request_type = "select_heal_target"
	elif request_type == "search_deck":
		request_type = "search_move"
	request_type = {
		"damage_target": "damage_target",
		"discard_cards": "discard_cards",
		"houb": "houb",
		"hand_bottom_draw": "hand_bottom_draw",
		"look_top_attach_energy": "look_top_attach_energy",
		"look_top": "look_top",
		"place_counters_self_ko": "place_counters_self_ko",
		"clara": "clara",
		"search_any_switch": "search_any_switch",
		"arven": "arven",
		"shuffle_from_discard": "shuffle_from_discard",
		"switch": "select_opponent_bench",
		"zinnia": "zinnia",
	}.get(continuation_kind, request_type)
	var options: Array = []
	for option in request.options:
		options.append(_canonical_pending_option(option, request.player))
	var allow_duplicates := request.allow_duplicates
	if continuation_kind == "look_top_attach_target":
		request_type = "select_energy_target"
	elif continuation_kind in [
		"energy_relocate_distribution",
		"energy_relocate_target",
	]:
		continuation_kind = "energy_relocate_target"
		request_type = "select_energy_target"
		allow_duplicates = false
	if op == "search_any_and_switch":
		var has_confirm_options := (
			options.size() == 2
			and str(options[0].get("option_id", "")) == "confirm:yes"
			and str(options[1].get("option_id", "")) == "confirm:no"
		)
		if has_confirm_options:
			continuation_kind = "search_any_switch_confirm"
			request_type = "confirm"
		elif continuation_kind == "switch" or request_type in [
			"select_bench",
			"select_opponent_bench",
		]:
			continuation_kind = "search_any_switch_bench"
			request_type = "select_bench"
		else:
			continuation_kind = "search_any_switch"
			request_type = "search_any_switch"
	if op == "draw_and_attach_energy":
		continuation_kind = "draw_attach_distribution"
		allow_duplicates = true
		var unique_options: Array = []
		for option in options:
			if not unique_options.has(option):
				unique_options.append(option)
		options = unique_options
	return {
		"request_type": request_type,
		"player": request.player,
		"min_select": request.min_select,
		"max_select": request.max_select,
		"allow_duplicates": allow_duplicates,
		"can_cancel": request.can_cancel,
		"options": options,
		"continuation_kind": continuation_kind,
	}


func _canonical_continuation_kind(value: Variant) -> String:
	var kind := str(value)
	return {
		"search_cards": "search_move",
		"choose_heal_damage": "heal_target",
		"choose_damage_target": "damage_target",
		"damage_target": "damage_target",
		"discard_hand_cards": "discard_cards",
		"discard_cards": "discard_cards",
		"flip_coin_branch": "coin",
		"coin_energy_discard": "coin",
		"coin_special": "coin",
		"coin": "coin",
		"hand_to_bottom_draw_until": "houb",
		"houb": "houb",
		"hand_to_bottom_then_draw": "hand_bottom_draw",
		"hand_bottom_draw": "hand_bottom_draw",
		"look_top_deck": "look_top",
		"look_top": "look_top",
		"place_counters_then_self_ko": "place_counters_self_ko",
		"place_counters_self_ko": "place_counters_self_ko",
		"recover_clara": "clara",
		"clara": "clara",
		"recover_from_discard_to_deck": "shuffle_from_discard",
		"shuffle_from_discard": "shuffle_from_discard",
		"search_any_and_switch": "search_any_switch",
		"search_any_switch": "search_any_switch",
		"search_item_and_tool": "arven",
		"arven": "arven",
		"switch_bench": "switch",
		"switch": "switch",
		"zinnia_resolve": "zinnia",
		"zinnia": "zinnia",
	}.get(kind, kind)


func _canonical_pending_option(option: Dictionary, player: int) -> Dictionary:
	var ref_value: Variant = option.get("ref")
	if ref_value is Dictionary and not str(ref_value.get("kind", "")).is_empty():
		var ref: Dictionary = ref_value
		var kind := str(ref.get("kind", ""))
		var result := {
			"kind": kind,
			"player": int(ref.get("player", -1)),
			"card_id": str(ref.get("card_id", "")),
		}
		if kind == "card":
			result["zone"] = str(ref.get("zone", ""))
			result["index"] = int(ref.get("index", -1))
		else:
			result["slot"] = str(ref.get("slot", ""))
		if kind == "attachment":
			result["attachment_type"] = str(ref.get("attachment_type", ""))
			result["index"] = int(ref.get("index", -1))
		return result
	var value_variant: Variant = option.get("value")
	if value_variant is Dictionary and not str(value_variant.get("slot", "")).is_empty():
		var value: Dictionary = value_variant
		return {
			"kind": "pokemon",
			"player": player,
			"card_id": str(value.get("card_id", "")),
			"slot": str(value.get("slot", "")),
		}
	return {"kind": "id", "option_id": str(option.get("option_id", ""))}


func _context_projection(context: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in [
		"base_damage",
		"ignore_weakness",
		"ignore_resistance",
		"ignore_defender_damage_effects",
		"attack_failed",
	]:
		if context.has(key):
			result[key] = context[key]
	return result


func _modifier_probe(state: GameState, op: String) -> Dictionary:
	var kinds := {
		"register_aura_damage_boost": "aura_damage_boost",
		"register_aura_damage_reduction": "aura_damage_reduction",
		"register_conditional_hp_boost": "conditional_hp_boost",
		"register_conditional_zero_retreat": "conditional_zero_retreat",
		"register_reactive_thorns": "reactive_thorns",
		"register_tool_exp_share": "tool_exp_share",
		"register_tool_modifier": "tool",
	}
	if not kinds.has(op):
		return {}
	var pokemon := state.get_player(0).active
	if pokemon == null:
		return {"registered": false}
	var modifier_kind := str(kinds[op])
	# Reactive thorns and Exp. Share are trigger descriptors.  They are
	# intentionally absent from the continuous Modifier registry.
	if modifier_kind in ["reactive_thorns", "tool_exp_share"]:
		return {"registered": false}
	for modifier_value in pokemon.modifiers:
		var modifier: Dictionary = modifier_value
		var operation: Dictionary = modifier.get("operation", {})
		var condition: Dictionary = modifier.get("condition", {})
		var params: Dictionary = {}
		match modifier_kind:
			"aura_damage_boost":
				if str(operation.get("kind", "")) != "damage_delta" \
				or str(modifier.get("layer", "")) != "attacker_adjust":
					continue
				params = {
					"amount": int(operation.get("amount", 0)),
					"attacker_subtype": str(condition.get("attacker_subtype", "")),
					"defender_type": str(condition.get("defender_type", "")),
				}
			"aura_damage_reduction":
				if str(operation.get("kind", "")) != "damage_delta" \
				or str(modifier.get("layer", "")) != "defender_adjust":
					continue
				params = {"reduction": abs(int(operation.get("amount", 0)))}
				if bool(condition.get("requires_attached_energy", false)):
					params["requires_attached_energy"] = true
			"conditional_hp_boost":
				if str(operation.get("kind", "")) != "hp_delta":
					continue
				params = {
					"amount": int(operation.get("amount", 0)),
					"energy_type": str(condition.get("energy_type", "")),
					"threshold": int(condition.get("threshold", 0)),
				}
			"conditional_zero_retreat":
				if str(operation.get("kind", "")) != "retreat_set":
					continue
				params = {"energy_type": str(condition.get("energy_type", ""))}
			"tool":
				if str(operation.get("kind", "")) != "damage_delta" \
				or str(modifier.get("layer", "")) != "defender_adjust" \
				or str(condition.get("target_stage", "")) != "stage1":
					continue
				params = {
					"effect": "damage_reduction_stage1",
					"amount": abs(int(operation.get("amount", 0))),
				}
			_:
				continue
		if params.is_empty():
			continue
		return {
			"registered": true,
			"modifier_kind": modifier_kind,
			"player": 0,
			"slot": "active",
			"card_id": pokemon.card_id,
			"params": params,
		}
	return {"registered": false}


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


func _display_value(value: Variant) -> String:
	var encoded := JSON.stringify(value)
	if encoded.length() <= 700:
		return encoded
	return "<json length=%d hash=%d>" % [encoded.length(), hash(encoded)]


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


func _diff_paths(left: Variant, right: Variant, path: String = "") -> Array[String]:
	var result: Array[String] = []
	if left is Dictionary and right is Dictionary:
		var keys: Array = left.keys()
		for key in right:
			if not keys.has(key):
				keys.append(key)
		keys.sort()
		for key in keys:
			var child := "%s.%s" % [path, str(key)] if not path.is_empty() else str(key)
			if not left.has(key) or not right.has(key):
				result.append(child)
			else:
				result.append_array(_diff_paths(left[key], right[key], child))
			if result.size() >= 12:
				return result.slice(0, 12)
		return result
	if left is Array and right is Array:
		if left.size() != right.size():
			result.append("%s.size" % path)
		for index in range(min(left.size(), right.size())):
			result.append_array(_diff_paths(
				left[index], right[index], "%s[%d]" % [path, index]))
			if result.size() >= 12:
				return result.slice(0, 12)
		return result
	if not _deep_equal(left, right):
		result.append(path)
	return result


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
