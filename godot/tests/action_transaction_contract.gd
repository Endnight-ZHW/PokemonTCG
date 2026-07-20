extends SceneTree

var failures: Array[String] = []


class SuccessfulChoiceKnockoutSettlement:
	extends VMKnockoutSettlement

	func _init(
		p_catalog: CardCatalog,
		p_validator: RulesValidator,
		p_trigger_commands: VMTriggerCommands,
	) -> void:
		super(p_catalog, p_validator, p_trigger_commands)

	func apply_ko_trigger_choice(
		state: GameState,
		_response: ChoiceResponse,
		stack: ResolutionStack,
		_rng: PortableRandomSource = null,
	) -> Dictionary:
		state.action_log.append("ko-choice-provisional")
		stack.pending_request = null
		var result := VMResult.ok("KO choice accepted")
		result["events"] = [{"event_type": "ko_choice_provisional"}]
		return result

	func resolve_empty_boards_and_promotions(_state: GameState) -> void:
		pass


class FailingTurnSettlement:
	extends VMTurnSettlement

	func _init(p_knockout_settlement: VMKnockoutSettlement) -> void:
		super(p_knockout_settlement)

	func finish_end_turn_after_knockouts(
		state: GameState,
		_actor: int,
		rng: PortableRandomSource,
		events: Array[Dictionary] = [],
	) -> StepResult:
		state.action_log.append("turn-finalizer-mutated")
		state.event_stream.push("turn_finalizer_mutated")
		rng.next_u32()
		return StepResult.new(
			false, "forced turn finalizer failure", null, events,
			state.winner, false, "vm_error")


class FailingAttackSettlement:
	extends VMAttackSettlement

	func _init(
		p_catalog: CardCatalog,
		p_validator: RulesValidator,
		p_knockout_settlement: VMKnockoutSettlement,
		p_effect_engine: EffectEngine,
	) -> void:
		super(p_catalog, p_validator, p_knockout_settlement, p_effect_engine)

	func finish_attack_after_prizes(
		state: GameState,
		_stack: ResolutionStack,
		_actor: int,
		rng: PortableRandomSource,
		events: Array[Dictionary] = [],
	) -> StepResult:
		state.action_log.append("attack-finalizer-mutated")
		state.event_stream.push("attack_finalizer_mutated")
		rng.next_u32()
		return StepResult.new(
			false, "forced attack finalizer failure", null, events,
			state.winner, false, "vm_error")


func _initialize() -> void:
	_test_setup_choice_failure_rolls_back_everything()
	_test_knockout_end_turn_failure_rolls_back_everything()
	_test_knockout_attack_failure_rolls_back_everything()
	_test_setup_game_invalidates_revision_zero_cache()
	_test_authoritative_session_rejects_non_strict_choice_dicts()
	if failures.is_empty():
		print("ACTION_TRANSACTION_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_setup_choice_failure_rolls_back_everything() -> void:
	var engine := GameEngine.new()
	var state := GameState.new()
	state.revision = 17
	state.phase = "SETUP"
	state.setup_stage = GameState.SETUP_TURN_ORDER
	state.setup_actor_idx = 0
	state.opening_coin_winner_idx = 0
	state.players[0].deck.assign(_repeat_card("sv1-ener-5", 7))
	state.players[1].deck.assign(_repeat_card("sv1-ener-5", 7))
	state.event_stream.push("before_setup_choice", {"stable": true})
	var request := ChoiceRequest.new(
		"setup:rollback",
		"choose_turn_order",
		0,
		"choose",
		[{"option_id": "turn:first", "value": {"goes_first": true}}],
		1,
		1,
		false,
		false,
		{
			"domain": "setup",
			"purpose": "choose_turn_order",
			"revision": state.revision,
			"continuation_frame_id": "setup:rollback:frame",
		},
	)
	var stack := ResolutionStack.new()
	stack.pending_request = request
	state.resolution_stack = stack.to_dict()
	var rng := PortableRandomSource.new(91001)
	var before_state := state.snapshot()
	var before_events := state.event_stream._events.duplicate(true)
	var before_rng := rng.get_state()
	var result := engine.apply_choice_response(
		state, ChoiceResponse.new(request.request_id, ["turn:first"]), rng)
	_check(
		not result.success
		and result.error_code == "mulligan_guard"
		and _deep_equal(state.snapshot(), before_state)
		and _deep_equal(state.event_stream._events, before_events)
		and rng.get_state() == before_rng
		and result.events.is_empty(),
		"failed setup choice did not restore state/RNG/events atomically",
	)


func _test_knockout_end_turn_failure_rolls_back_everything() -> void:
	var engine := GameEngine.new()
	var fake_knockout := SuccessfulChoiceKnockoutSettlement.new(
		engine.catalog, RulesTestHarness.validator_for(engine), RulesTestHarness.effect_engine_for(engine).trigger_commands())
	RulesTestHarness.set_knockout_settlement(engine, fake_knockout)
	RulesTestHarness.set_turn_settlement(
		engine, FailingTurnSettlement.new(fake_knockout))
	var fixture := _knockout_choice_fixture({
		"finish_end_turn_after_knockouts": true,
		"end_turn_actor": 0,
	})
	_assert_failed_knockout_finalizer_rolls_back(
		engine, fixture["state"], fixture["request"], "end-turn")


func _test_knockout_attack_failure_rolls_back_everything() -> void:
	var engine := GameEngine.new()
	var fake_knockout := SuccessfulChoiceKnockoutSettlement.new(
		engine.catalog, RulesTestHarness.validator_for(engine), RulesTestHarness.effect_engine_for(engine).trigger_commands())
	RulesTestHarness.set_knockout_settlement(engine, fake_knockout)
	RulesTestHarness.set_attack_settlement(
		engine,
		FailingAttackSettlement.new(
			engine.catalog, RulesTestHarness.validator_for(engine), fake_knockout, RulesTestHarness.effect_engine_for(engine)),
	)
	var fixture := _knockout_choice_fixture({
		"finish_attack_after_prizes": true,
		"actor": 0,
	})
	_assert_failed_knockout_finalizer_rolls_back(
		engine, fixture["state"], fixture["request"], "attack")


func _assert_failed_knockout_finalizer_rolls_back(
	engine: GameEngine,
	state: GameState,
	request: ChoiceRequest,
	label: String,
) -> void:
	var rng := PortableRandomSource.new(92001)
	state.event_stream.push("before_ko_choice", {"label": label})
	var before_state := state.snapshot()
	var before_events := state.event_stream._events.duplicate(true)
	var before_rng := rng.get_state()
	var result := engine.apply_choice_response(
		state, ChoiceResponse.new(request.request_id, ["ko:accept"]), rng)
	_check(
		not result.success
		and result.error_code == "vm_error"
		and _deep_equal(state.snapshot(), before_state)
		and _deep_equal(state.event_stream._events, before_events)
		and rng.get_state() == before_rng
		and result.pending_choice == null
		and result.events.is_empty(),
		"failed %s KO finalizer did not restore the choice checkpoint" % label,
	)


func _knockout_choice_fixture(context: Dictionary) -> Dictionary:
	var state := GameState.new()
	state.revision = 23
	state.phase = "ATTACK"
	state.active_player_idx = 0
	var request := ChoiceRequest.new(
		"ko:rollback:%d" % context.hash(),
		"fake_knockout_choice",
		0,
		"choose",
		[{"option_id": "ko:accept", "value": {"accepted": true}}],
		1,
		1,
		false,
		false,
		{
			"domain": "knockout",
			"purpose": "fake_knockout_choice",
			"revision": state.revision,
			"continuation_frame_id": "ko:rollback:frame",
		},
	)
	var stack := ResolutionStack.new()
	stack.context = context.duplicate(true)
	stack.pending_request = request
	state.resolution_stack = stack.to_dict()
	return {"state": state, "request": request}


func _test_setup_game_invalidates_revision_zero_cache() -> void:
	var engine := GameEngine.new()
	var state := GameState.new()
	var before_setup := engine.query_legal_action_groups(state, 0)
	var deck := engine.catalog.expand_deck("fire")
	var setup := engine.setup_game(
		state, deck, deck, PortableRandomSource.new(93001), 0)
	var after_setup := engine.query_legal_action_groups(state, 0)
	_check(
		before_setup.success
		and before_setup.groups.is_empty()
		and setup.success
		and state.revision == 0
		and after_setup.success
		and not after_setup.groups.is_empty(),
		"setup_game reused a stale revision-zero legal-action cache entry",
	)


func _test_authoritative_session_rejects_non_strict_choice_dicts() -> void:
	var session := AuthoritativeSession.new("strict-choice")
	var state := GameState.new()
	state.revision = 31
	var request := ChoiceRequest.new(
		"choice:strict",
		"confirm",
		0,
		"confirm",
		[{"option_id": "confirm", "value": true}],
		1,
		1,
		false,
		false,
		{
			"domain": "rules",
			"revision": state.revision,
			"continuation_frame_id": "choice:strict:frame",
		},
	)
	var stack := ResolutionStack.new()
	stack.pending_request = request
	state.resolution_stack = stack.to_dict()
	session.state = state
	var before_state := state.snapshot()
	var before_rng := session.rng.get_state()
	for response in [
		{
			"request_id": request.request_id,
			"option_ids": ["confirm"],
			"cancelled": false,
			"extra": "forged",
		},
		{
			"request_id": request.request_id,
			"option_ids": ["confirm"],
			"cancelled": "false",
		},
		{
			"request_id": request.request_id,
			"option_ids": "confirm",
			"cancelled": false,
		},
	]:
		var result := session.submit_choice(0, response)
		_check(
			not result.success
			and result.error_code == "invalid_choice"
			and _deep_equal(state.snapshot(), before_state)
			and session.rng.get_state() == before_rng,
			"AuthoritativeSession accepted or mutated on a non-strict Choice response",
		)


func _repeat_card(card_id: String, count: int) -> Array[String]:
	var result: Array[String] = []
	for _index in range(count):
		result.append(card_id)
	return result


func _deep_equal(left: Variant, right: Variant) -> bool:
	if typeof(left) != typeof(right):
		return false
	if left is Dictionary:
		var left_dict: Dictionary = left
		var right_dict: Dictionary = right
		if left_dict.size() != right_dict.size():
			return false
		for key in left_dict:
			if not right_dict.has(key) or not _deep_equal(left_dict[key], right_dict[key]):
				return false
		return true
	if left is Array:
		var left_array: Array = left
		var right_array: Array = right
		if left_array.size() != right_array.size():
			return false
		for index in range(left_array.size()):
			if not _deep_equal(left_array[index], right_array[index]):
				return false
		return true
	return left == right


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
