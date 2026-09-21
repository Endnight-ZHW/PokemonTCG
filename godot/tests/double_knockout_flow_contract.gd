extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	Engine.max_fps = 60
	root.size = Vector2i(1600, 900)
	var settings := root.get_node("AppSettings")
	var previous_mode: String = settings.animation_mode
	create_timer(120).timeout.connect(func() -> void:
		push_error("Double knockout flow contract timed out")
		quit(1))
	for mode in ["standard", "fast", "reduced"]:
		settings.animation_mode = mode
		await _check_double_knockout(mode)
	settings.animation_mode = previous_mode
	if failures.is_empty():
		print("DOUBLE_KNOCKOUT_FLOW_OK modes=3 prizes=2,1 promotions=2 ai_resumed=1")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _fixture() -> GameState:
	var state := GameState.new()
	state.revision = 100
	state.setup_stage = GameState.SETUP_COMPLETE
	state.active_player_idx = 0
	state.first_player_idx = 1
	state.turn_number = 10
	state.phase = "MAIN"
	state.public_deck_keys.assign(["fighting", "colorless"])
	for player in state.players:
		player.prizes.assign(["sv1-151", "sv1-151", "sv1-151", "sv1-151", "sv1-151"])
		player.deck.assign(["sv1-ener-6", "sv1-151", "sv1-189", "sv1-ener-6"])
	state.players[0].active = PokemonState.new("svf-luca")
	state.players[0].active.damage_counters = 8
	state.players[0].active.energy_card_ids.assign([
		"sv1-ener-6", "sv1-ener-6", "sv1-ener-6", "sv1-ener-6",
	])
	state.players[0].bench[0] = PokemonState.new("svf-klea")
	state.players[1].active = PokemonState.new("svi-maus")
	state.players[1].bench[0] = PokemonState.new("svi-maus")
	return state


func _check_double_knockout(mode: String) -> void:
	var main: Node = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.game_mode = "challenge"
	main.ai_deck_key = "colorless"
	main.last_match_seed = 17
	main.ai_match_instance_id = "double-ko:" + mode
	main.native_rules = NativeRulesSessionAdapter.new(main.catalog)
	if not main.native_rules.restore(_fixture().snapshot(), 17):
		_check(false, mode + ": native fixture restore failed")
		main.queue_free()
		return
	main.state = main.native_rules.state
	main.rng = PortableRandomSource.new(17)
	main.current_view_player = 0
	main.shell_view.build_game_screen()
	await process_frame
	var attack: GameAction
	for action in main._rules_legal_actions(0).concrete_actions():
		if action.kind == "DECLARE_ATTACK":
			attack = action
			break
	_check(attack != null, mode + ": Lucario has no legal attack")
	var step: StepResult = main._execute_action_now(attack)
	_check(step.success, mode + ": Lucario attack failed")
	_check(main.state.players[0].active == null and main.state.players[1].active == null,
		mode + ": the real attack and reactive damage did not knock out both Active Pokemon")
	var deadline := Time.get_ticks_msec() + 30000
	# Only submit human inputs after Main has actually exposed their choice or
	# promotion. The native coordinator must handle every AI choice and action.
	while Time.get_ticks_msec() < deadline and main.state.turn_number == 10:
		await process_frame
		if main.battle_screen.is_presentation_busy():
			continue
		var pending: ChoiceView = main._query_any_pending_choice()
		var active: ChoiceView = main.active_request
		if pending != null and pending.player == 0 and active != null and pending.request_id == active.request_id:
			main._toggle_choice(str(pending.options[0].option_id))
			main._confirm_choice()
		elif pending == null and main._current_actor() == 0:
			for action in main._rules_legal_actions(0).concrete_actions():
				if action.kind == "PROMOTE":
					main._execute_action_now(action)
					break
	_check(main.state.turn_number == 11 and main.state.active_player_idx == 1,
		mode + ": double knockout stranded the match before the AI's next turn")
	_check(main.state.players[0].prizes.size() == 3 and main.state.players[1].prizes.size() == 4,
		mode + ": double knockout did not award exactly two and one prizes")
	_check(main.state.pending_promotions.is_empty()
		and main.state.players[0].active != null and main.state.players[1].active != null,
		mode + ": both players did not complete their mandatory promotions")
	var settled_revision: int = main.state.revision
	while Time.get_ticks_msec() < deadline and not main.ai_thinking and main.state.revision == settled_revision:
		await process_frame
	_check(main.ai_thinking or main.state.revision > settled_revision,
		mode + ": AI did not resume after the final promotion presentation")
	_check(not main.battle_screen.is_presentation_busy(),
		mode + ": a completed knockout left the presentation barrier locked")
	main._stop_ai()
	while main.ai_coordinator.needs_poll():
		main.ai_coordinator.poll_result()
		await process_frame
	main.queue_free()
	await process_frame
	await process_frame
	print("DOUBLE_KNOCKOUT_CASE ", mode)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
