extends SceneTree

## Fixed-fixture CPU probe. Headless frame timings do not measure GPU rendering.
const Factory = preload("res://tools/ui_preview_state_factory.gd")
var _report: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _distribution(samples: Array[float]) -> Dictionary:
	samples.sort()
	return {"p50_us": samples[samples.size() / 2],
		"p95_us": samples[mini(samples.size() - 1, ceili(samples.size() * 0.95) - 1)],
		"samples": samples.size()}

func _measure(operation: Callable, count: int = 1000) -> Dictionary:
	for _i in range(100):
		operation.call()
	var samples: Array[float] = []
	for _i in range(count):
		var started := Time.get_ticks_usec()
		operation.call()
		samples.append(float(Time.get_ticks_usec() - started))
	return _distribution(samples)

func _run() -> void:
	Engine.max_fps = 0
	var settings := root.get_node("AppSettings")
	# Load a fixture through the public settings boundary so both old and current
	# clients resolve the same mode, regardless of saved developer preferences.
	var config := ConfigFile.new()
	var config_path := "user://project-performance-settings.cfg"
	config.set_value("accessibility", "animation_mode", "reduced")
	assert(config.save(config_path) == OK)
	assert(settings.load_settings(config_path))
	DirAccess.remove_absolute(config_path)
	root.size = Vector2i(1280, 720)
	var state: GameState = Factory.battle_state()
	var rows: Array[Dictionary] = Factory.action_rows(state)
	var rules := NativeRulesSessionAdapter.new()
	var started := rules.start_match("fire", "water", 20260623, 0)
	if not started.success:
		push_error("Performance fixture rules setup failed")
		quit(1)
		return
	_report = {"schema": "ptcg.project_performance/1", "seed": 20260623,
		"renderer": DisplayServer.get_name(), "godot": Engine.get_version_info().string,
		"memory_start": OS.get_static_memory_usage()}
	_report["capture_player_view"] = _measure(func() -> void:
		BattleViewModel.capture_player_view(state, 0, rows, "", false, "local"))
	var view := BattleViewModel.capture_player_view(state, 0, rows, "", false, "local")
	_report["render_snapshot"] = _measure(func() -> void: view.state_for_render())
	_report["rules_legal_actions"] = _measure(func() -> void: rules.legal_actions(0))
	_report["rules_snapshot"] = _measure(func() -> void: rules.snapshot())
	var table := load("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	root.add_child(table)
	table.update_view(view.state_for_render(), 0, rows, "", false, "local")
	for _i in range(30):
		await process_frame
	var transition_events: Array = [{"event_type": "cards_drawn", "actor": 0,
		"data": {"player": 0, "cards": ["svi-chim", "sv1-ener-2"]}},
		{"event_type": "cards_drawn", "actor": 1,
		"data": {"player": 1, "cards": ["sv1-ener-3"]}}]
	# Measure the complete preparation boundary, including normalization on either
	# side of its refactor and warm-cache prefetch; never compare only the moved work.
	_report["prepare_transition_assets"] = _measure(func() -> void:
		var request := BattleTransitionRequest.create(view, transition_events)
		table.render3d.prefetch_transition_assets(request.target_view, request.events), 300)
	_report["refresh_battle"] = _measure(func() -> void:
		table.update_view(view.state_for_render(), 0, rows, "", false, "local"), 200)
	var card := table.own_active
	_report["unchanged_interaction"] = _measure(func() -> void:
		card.set_interaction_state(true))
	await create_timer(0.3).timeout
	var frames: Array[float] = []
	for _i in range(300):
		var frame_started := Time.get_ticks_usec()
		await process_frame
		frames.append(float(Time.get_ticks_usec() - frame_started))
	_report["idle_frame_interval"] = _distribution(frames)
	var processing_cards := 0
	var card_count := 0
	for node in table.find_children("*", "CardView", true, false):
		card_count += 1
		if node.is_processing():
			processing_cards += 1
	_report["card_nodes"] = card_count
	_report["processing_cards"] = processing_cards
	_report["table_processing"] = table.is_processing()
	_report["node_count"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_report["memory_end"] = OS.get_static_memory_usage()
	_report["texture_cache"] = root.get_node("CardTextureCache").stats()
	table.queue_free()
	await process_frame
	print("PROJECT_PERFORMANCE_JSON=" + JSON.stringify(_report))
	quit(0)
