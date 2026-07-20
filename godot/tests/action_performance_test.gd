extends SceneTree

const MAX_COLD_MEDIAN_USEC := 353.0
const MAX_APPLY_MEDIAN_USEC := 131.0

var failures: Array[String] = []


func _initialize() -> void:
	var engine := GameEngine.new()
	var state := _benchmark_state()
	for _index in range(20):
		state.revision += 1
		engine.query_legal_action_groups(state, 0)

	var samples: Array[int] = []
	for _index in range(101):
		state.revision += 1
		var started := Time.get_ticks_usec()
		var groups := engine.query_legal_action_groups(state, 0)
		samples.append(Time.get_ticks_usec() - started)
		_check(
			groups.success and not groups.groups.is_empty(),
			"cold legal action query returned no groups",
		)
	samples.sort()
	var cold_median_usec := float(samples[samples.size() / 2])
	_check(
		cold_median_usec <= MAX_COLD_MEDIAN_USEC,
		"strict grouped query median %.1fus exceeds %.1fus acceptance ceiling" % [
			cold_median_usec, MAX_COLD_MEDIAN_USEC,
		],
	)

	var original := engine.query_legal_action_groups(state, 0)
	var original_target_count := original.groups[0].targets.size()
	original.groups[0].targets.clear()
	var cached := engine.query_legal_action_groups(state, 0)
	_check(
		cached.groups[0].targets.size() == original_target_count,
		"legal action cache leaked mutable result objects",
	)
	var apply_samples: Array[int] = []
	for index in range(101):
		var apply_state := _commit_benchmark_state()
		apply_state.revision = index + 1
		var action := GameAction.create(
			"END_TURN", {}, 0, null, null, "perf-apply:%d" % index,
			apply_state.revision)
		var apply_started := Time.get_ticks_usec()
		var applied := engine.apply_action(
			apply_state, action, PortableRandomSource.new(9000 + index))
		apply_samples.append(Time.get_ticks_usec() - apply_started)
		_check(applied.success, "formal action performance fixture failed")
	apply_samples.sort()
	var apply_median_usec := float(apply_samples[apply_samples.size() / 2])
	_check(
		apply_median_usec <= MAX_APPLY_MEDIAN_USEC,
		"formal action median %.1fus exceeds %.1fus regression ceiling" % [
			apply_median_usec, MAX_APPLY_MEDIAN_USEC,
		],
	)

	if failures.is_empty():
		print("ACTION_PERFORMANCE_OK median_usec=%.1f ceiling_usec=%.1f apply_median_usec=%.1f apply_ceiling_usec=%.1f" % [
			cold_median_usec,
			MAX_COLD_MEDIAN_USEC,
			apply_median_usec,
			MAX_APPLY_MEDIAN_USEC,
		])
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _benchmark_state() -> GameState:
	var state := GameState.new()
	state.setup_stage = GameState.SETUP_COMPLETE
	state.phase = "MAIN"
	state.turn_number = 3
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].active.placed_this_turn = false
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[0].placed_this_turn = false
	state.players[0].hand = ["sv1-ener-5", "sv1-180", "svi-chim"]
	state.players[0].deck = [
		"sv1-ener-5", "sv1-ener-5", "sv1-ener-5", "sv1-ener-5",
	]
	state.players[0].prizes = ["sv1-ener-5"]
	state.players[1].active = PokemonState.new("sv1-104")
	state.players[1].active.placed_this_turn = false
	state.players[1].deck = ["sv1-ener-5", "sv1-ener-5"]
	state.players[1].prizes = ["sv1-ener-5"]
	return state


func _commit_benchmark_state() -> GameState:
	var state := GameState.new()
	state.setup_stage = GameState.SETUP_COMPLETE
	state.phase = "MAIN"
	state.turn_number = 3
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].active.placed_this_turn = false
	state.players[0].deck = ["sv1-ener-5", "sv1-ener-5"]
	state.players[0].prizes = ["sv1-ener-5"]
	state.players[1].active = PokemonState.new("sv1-104")
	state.players[1].active.placed_this_turn = false
	state.players[1].deck = ["sv1-ener-5", "sv1-ener-5"]
	state.players[1].prizes = ["sv1-ener-5"]
	return state


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
