extends Node

## Device-only scene, excluded from product exports. Uses the real renderer,
## native rules and input pipeline at the device's own resolution.
var main: Control
var settings: Node
var window: Window
var pointer := Vector2.ZERO
var failures: Array[String] = []
var report := {"profiles": [], "completed_matches": 0, "hand_taps": 0, "prize_taps": 0}
var soak_seconds := 0
var _soak_started_msec := 0
var _progress_label: Label
var _progress_second := -1
var _soak_frames: Array[float] = []


func _process(_delta: float) -> void:
	if _soak_started_msec <= 0 or _progress_label == null:
		return
	var elapsed := int((Time.get_ticks_msec() - _soak_started_msec) / 1000)
	if elapsed != _progress_second:
		_progress_second = elapsed
		_progress_label.text = "真机性能测试 · %d / %d 秒 · %.0f FPS\n固定局面采样中，完成后自动返回首页" % [
			mini(elapsed, soak_seconds), soak_seconds, Engine.get_frames_per_second()]


func _ready() -> void:
	var options: Variant = null
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--device-network-config="):
			options = JSON.parse_string(FileAccess.get_file_as_string(argument.get_slice("=", 1)))
	if options == null and FileAccess.file_exists("user://device-network-config.json"):
		options = JSON.parse_string(FileAccess.get_file_as_string("user://device-network-config.json"))
	if options is Dictionary:
		if options.get("mode", "") == "home_probe":
			call_deferred("run_home_probe", options)
			return
		if options.get("mode", "") == "acceptance":
			call_deferred("run", options)
			return
		var runner := load("res://tests/device_network_acceptance.gd").new() as Node
		add_child(runner)
		runner.call_deferred("run", options)
		return
	call_deferred("run")


func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error("ANDROID_TOUCH_CHECK: " + message)


func settle(frames: int = 5) -> void:
	for frame in range(frames):
		await get_tree().process_frame


func touch(pressed: bool, point: Vector2) -> void:
	pointer = point
	var event := InputEventScreenTouch.new()
	event.position = window.get_final_transform() * point
	event.pressed = pressed
	Input.parse_input_event(event)


func move(point: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.position = window.get_final_transform() * point
	event.relative = window.get_final_transform().basis_xform(point - pointer)
	pointer = point
	Input.parse_input_event(event)


func tap(point: Vector2) -> void:
	touch(true, point)
	await settle(1)
	touch(false, point)
	await settle()


func swipe(point: Vector2, offset: Vector2) -> void:
	touch(true, point)
	for index in range(1, 9):
		move(point + offset * float(index) / 8.0)
		await settle(1)
	touch(false, pointer)
	await settle()


func capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var path := "user://android-touch-%s.png" % label
	check(window.get_texture().get_image().save_png(path) == OK, "Could not capture " + label)
	print("ANDROID_TOUCH_PHASE ", label, " path=", ProjectSettings.globalize_path(path))
	await get_tree().create_timer(1.0).timeout


func check_home(label: String) -> void:
	check(main.current_screen == "title", label + ": homepage route is wrong")
	var title := main.screen_host.get_child(0) as TitlePage
	if title == null:
		check(false, label + ": homepage is missing")
		return
	var stage := title.card_stage
	check(stage._active and not stage._suspended, label + ": showcase is inactive")
	check(stage.viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED,
		label + ": visible showcase has stopped rendering")
	await RenderingServer.frame_post_draw
	var pixels := stage.viewport.get_texture().get_image()
	print("ANDROID_HOME_STATE ", JSON.stringify({"label": label,
		"draw_calls": stage.stats().draw_calls, "current_camera": stage.viewport.get_camera_3d() == stage.camera,
		"viewport_size": str(stage.viewport.size), "disabled_3d": stage.viewport.disable_3d,
		"world_same": stage._world.get_world_3d() == stage.viewport.find_world_3d(),
		"card_visible": stage.cards[0].is_visible_in_tree(), "stage_alpha": stage.modulate.a}))
	check(pixels != null and not pixels.is_empty(), label + ": no viewport image")
	if pixels == null or pixels.is_empty():
		return
	check(stage.cards[0].face_texture != null, label + ": representative card texture is missing")
	for world_point in [stage.cards[0].global_position, stage._case_root.to_global(Vector3(0, 0.9, 0))]:
		var point := Vector2i(stage.camera.unproject_position(world_point))
		check(Rect2i(Vector2i.ZERO, pixels.get_size()).has_point(point), label + ": showcase outside viewport")
		if Rect2i(Vector2i.ZERO, pixels.get_size()).has_point(point):
			check(pixels.get_pixelv(point).a > 0.9, label + ": transparent showcase")
	await capture(label)


func measure(label: String, count: int = 60) -> void:
	await settle(15)
	var frames: Array[float] = []
	var previous := Time.get_ticks_usec()
	for index in range(count):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		frames.append(float(now - previous) / 1000.0)
		previous = now
	frames.sort()
	if label.begins_with("soak-"):
		_soak_frames.append_array(frames)
	var row := {"label": label, "p50_ms": frames[frames.size() / 2],
		"p95_ms": frames[ceili(frames.size() * 0.95) - 1], "target_fps": Engine.max_fps,
		"static_bytes": OS.get_static_memory_usage(),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"texture_bytes": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)}
	report.profiles.append(row)
	print("ANDROID_TOUCH_PERFORMANCE ", JSON.stringify(row))


func run(options: Dictionary = {}) -> void:
	preload("res://tests/graphics_test_driver.gd").attach(get_tree())
	window = get_window()
	settings = get_node("/root/AppSettings")
	settings.reset_defaults(false)
	settings.muted = true
	settings.quality_profile = "auto"
	settings.animation_mode = "standard"
	Input.use_accumulated_input = false
	Input.emulate_mouse_from_touch = true
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--tablet-soak-seconds="):
			soak_seconds = clampi(argument.get_slice("=", 1).to_int(), 0, 1800)
	soak_seconds = clampi(int(options.get("seconds", soak_seconds)), 0, 1800)
	get_tree().create_timer(240 + soak_seconds).timeout.connect(func() -> void:
		push_error("ANDROID_TOUCH_ACCEPTANCE_TIMEOUT")
		get_tree().quit(1))
	report["platform"] = OS.get_name()
	report["gpu"] = RenderingServer.get_video_adapter_name()
	report["rendering_method"] = RenderingServer.get_current_rendering_method()
	report["rendering_driver"] = RenderingServer.get_current_rendering_driver_name()
	report["resolution"] = str(window.size)
	print("ANDROID_TOUCH_DEVICE ", JSON.stringify(report))
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await settle(20)
	await check_home("initial")
	await measure("home-auto")
	await check_audio()
	await check_frontend()
	await check_settings()
	for profile in ["auto", "low", "medium", "auto"]:
		settings.quality_profile = profile
		settings.animation_mode = "reduced" if profile == "medium" else "standard"
		settings.changed.emit()
		await finish_match(profile)
	settings.quality_profile = "auto"
	settings.animation_mode = "standard"
	settings.changed.emit()
	await check_render_recovery()
	await measure("home-after-matches")
	await run_soak()
	report["failures"] = failures
	var output := FileAccess.open("user://android-touch-report.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("ANDROID_TOUCH_REPORT ", JSON.stringify(report))
	print("ANDROID_TOUCH_ACCEPTANCE_OK" if failures.is_empty() else "ANDROID_TOUCH_ACCEPTANCE_FAILED")
	await get_tree().create_timer(3.0).timeout
	get_tree().quit(0 if failures.is_empty() else 1)


func check_settings() -> void:
	var title := main.screen_host.get_child(0) as TitlePage
	await tap((title.get_node("%SettingsButton") as Control).get_global_rect().get_center())
	await settle(10)
	check(main.modal_layer.visible, "One settings tap did not open settings")
	var panel := main.modal_body.get_child(0) as SettingsPanel
	var slider := panel.music_volume_slider
	var scroll := panel.get_node("%CategoryContent").get_parent() as ScrollContainer
	check(scroll != null, "Settings must use its own reading pane")
	var before := slider.value
	await swipe(slider.get_global_rect().get_center(), Vector2(0, -140))
	if scroll.get_v_scroll_bar().max_value > scroll.size.y + 1:
		check(scroll.scroll_vertical > 0, "Vertical slider gesture did not scroll overflowing settings")
	check(is_equal_approx(before, slider.value), "Vertical slider gesture changed volume")
	scroll.scroll_vertical = 0
	await settle(15)
	await swipe(slider.get_global_rect().get_center(), Vector2(100, 0))
	check(slider.value > before, "Horizontal slider gesture did not change volume")
	check(scroll.scroll_vertical == 0, "Horizontal slider gesture scrolled settings")
	check(not get_tree().quit_on_go_back, "Engine auto-quit overrides Android system Back")
	main.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle(12)
	check(not main.modal_layer.visible, "One cancel tap did not close settings")
	await check_home("after-settings")


func showcase_point(stage: FrontendCardShowcase3D, world_point: Vector3) -> Vector2:
	var local := stage.camera.unproject_position(world_point) * stage.size / Vector2(stage.viewport.size)
	return stage.get_global_transform_with_canvas() * local


func check_frontend() -> void:
	var title := main.screen_host.get_child(0) as TitlePage
	var stage := title.card_stage
	await tap(showcase_point(stage, stage._case_root.to_global(Vector3(0, 1.2, ShowcaseCaseGeometry.DEPTH * 0.5))))
	await get_tree().create_timer(0.6).timeout
	check(stage._lid_angle > 89, "One physical box tap did not open its lid")
	stage._toggle_case()
	await get_tree().create_timer(0.6).timeout
	var card_point := showcase_point(stage, stage.cards[0].global_position)
	await swipe(card_point, Vector2(60, 0))
	check(not main.modal_layer.visible and absf(stage._camera_yaw) > 0.1,
		"Showcase drag opened artwork or failed to rotate")
	await tap(showcase_point(stage, stage.cards[0].global_position))
	check(main.modal_layer.visible, "One physical card tap did not open artwork")
	main.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle(8)
	check(not main.modal_layer.visible, "Back did not close artwork")
	var previous_rng := stage._cosmetic_rng.state
	await tap(showcase_point(stage, stage._coin.global_position))
	check(stage._cosmetic_rng.state != previous_rng, "Physical coin tap did not toss the coin")
	await get_tree().create_timer(1).timeout
	await tap((title.get_node("%NetworkButton") as Control).get_global_rect().get_center())
	await settle(10)
	check(main.current_screen == "network" and main.current_network_page.kind == "relay",
		"Homepage did not default to internet play")
	check(main.current_network_page.address_input.text == settings.DEFAULT_RELAY_URL,
		"Public relay was not prefilled")
	await capture("network-default")
	main.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle(10)
	title = main.screen_host.get_child(0) as TitlePage
	await tap((title.get_node("%LocalTwoPlayerButton") as Control).get_global_rect().get_center())
	await settle(10)
	var decks := main.screen_host.get_child(0) as DeckSelectPage
	check(decks != null and decks.deck_count() == 14, "Tablet deck gallery is incomplete")
	await capture("deck-gallery")
	main.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle(10)
	title = main.screen_host.get_child(0) as TitlePage
	await tap((title.get_node("%HelpButton") as Control).get_global_rect().get_center())
	check(main.modal_layer.visible, "Help did not open")
	await capture("help")
	main.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle(10)


func check_audio() -> void:
	var director: AudioDirector = main.audio_director
	var capture_effect := AudioEffectCapture.new()
	capture_effect.buffer_length = 2.0
	var master := AudioServer.get_bus_index("Master")
	var effect_index := AudioServer.get_bus_effect_count(master)
	AudioServer.add_bus_effect(master, capture_effect)
	settings.muted = false
	settings.changed.emit()
	await get_tree().create_timer(1.2).timeout
	var audible_peak := audio_peak(capture_effect)
	check(audible_peak > 0.0001, "Android mixer produced no homepage music samples")
	check(director.music.current == &"title", "Homepage selected the wrong music")
	settings.muted = true
	settings.changed.emit()
	await get_tree().create_timer(0.2).timeout
	capture_effect.clear_buffer()
	await get_tree().create_timer(0.4).timeout
	var muted_peak := audio_peak(capture_effect)
	check(AudioServer.is_bus_mute(master) or muted_peak < audible_peak * 0.01,
		"Mute did not silence the Android mixer")
	director.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	check(director.music_player.stream_paused, "Background did not pause music")
	director.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	check(not director.music_player.stream_paused, "Foreground did not resume music")
	check(director.music.players.size() == 2, "Music recovery created extra players")
	report["audio"] = {"audible_peak": audible_peak, "muted_peak": muted_peak,
		"pause_resume": true, "music_players": director.music.players.size()}
	AudioServer.remove_bus_effect(master, effect_index)


func audio_peak(effect: AudioEffectCapture) -> float:
	var peak := 0.0
	for frame in effect.get_buffer(effect.get_frames_available()):
		peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
	return peak


func run_soak() -> void:
	# Keep the real battle renderer and audio active; do not save diagnostic preferences.
	settings.muted = false
	settings.animation_mode = "standard"
	settings.quality_profile = "auto"
	settings.changed.emit()
	main.game_mode = "local"
	main.native_rules = NativeRulesSessionAdapter.new(main.catalog)
	check(main.native_rules.restore(fixture().snapshot(), 17), "Soak fixture restore failed")
	main.state = main.native_rules.state
	main.current_view_player = 0
	main.shell_view.build_game_screen()
	main.battle_screen.set_local_hand_privacy_hidden(false)
	await settle(30)
	check(main.battle_screen.hand_scroll.visible, "Soak fixture retained the hot-seat privacy gate")
	var started := Time.get_ticks_msec()
	_soak_started_msec = started
	var overlay := CanvasLayer.new()
	overlay.layer = 100
	add_child(overlay)
	_progress_label = Label.new()
	_progress_label.position = Vector2(24, 24)
	_progress_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress_label.add_theme_font_size_override("font_size", 20)
	_progress_label.add_theme_color_override("font_color", Color.WHITE)
	_progress_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_progress_label.add_theme_constant_override("outline_size", 6)
	overlay.add_child(_progress_label)
	var block := 0
	print("ANDROID_SOAK_STARTED seconds=", soak_seconds)
	while Time.get_ticks_msec() - started < soak_seconds * 1000:
		await measure("soak-%02d" % block, 600)
		var table: BattleTable = main.battle_screen
		var card: CardView = table.hand_views[block % table.hand_views.size()]
		await tap(table.render3d.global_bounds(card).get_center())
		main._clear_battle_selection("", false)
		block += 1
		report["soak_elapsed_seconds"] = (Time.get_ticks_msec() - started) / 1000.0
		var output := FileAccess.open("user://android-soak-progress.json", FileAccess.WRITE)
		output.store_string(JSON.stringify(report, "\t"))
		output.close()
	_soak_started_msec = 0
	_progress_label = null
	overlay.queue_free()
	if not _soak_frames.is_empty():
		_soak_frames.sort()
		report["soak_summary"] = {"samples": _soak_frames.size(),
			"p50_ms": _soak_frames[_soak_frames.size() / 2],
			"p95_ms": _soak_frames[ceili(_soak_frames.size() * 0.95) - 1]}
	main.shell_view.show_title()
	await settle(15)
	print("ANDROID_HOME_BEFORE_READBACK")
	await get_tree().create_timer(3.0).timeout
	var before_check := failures.size()
	await check_home("after-soak")
	if failures.size() > before_check:
		await inspect_home_frames()


func run_home_probe(options: Dictionary) -> void:
	preload("res://tests/graphics_test_driver.gd").attach(get_tree())
	window = get_window()
	settings = get_node("/root/AppSettings")
	settings.reset_defaults(false)
	settings.muted = true
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await settle(30)
	soak_seconds = int(options.get("seconds", 1))
	await run_soak()
	if failures.is_empty():
		await inspect_home_frames()
	print("HOME_PROBE_DONE")
	get_tree().quit()


func inspect_home_frames() -> void:
	for attempt in range(4):
		await settle(60)
		var title := main.screen_host.get_child(0) as TitlePage
		var stage := title.card_stage
		var pixels := stage.viewport.get_texture().get_image()
		var point := Vector2i(stage.camera.unproject_position(stage.cards[0].global_position))
		print("HOME_PROBE ", JSON.stringify({"attempt": attempt,
			"pixel": str(pixels.get_pixelv(point)), "alpha": pixels.get_pixelv(point).a, "stage_size": str(stage.size),
			"viewport_size": str(stage.viewport.size), "surface_visible": stage._surface.visible,
			"camera_position": str(stage.camera.position), "current": stage.camera.current,
			"viewport_camera": stage.viewport.get_camera_3d() == stage.camera,
			"card_visible": stage.cards[0].is_visible_in_tree(), "active": stage._active,
			"world_same": stage._world.get_world_3d() == stage.viewport.find_world_3d(),
			"stats": stage.stats(), "world_children": stage._world.get_child_count()}))
	await capture("home-probe-final")


func fixture() -> GameState:
	var state := GameState.new()
	state.revision = 100
	state.setup_stage = GameState.SETUP_COMPLETE
	state.active_player_idx = 0
	state.first_player_idx = 1
	state.turn_number = 10
	state.phase = "MAIN"
	state.public_deck_keys.assign(["fighting", "colorless"])
	for player in state.players:
		player.prizes.assign(["sv1-151"])
		player.deck.assign(["sv1-ener-6", "sv1-151", "sv1-189", "sv1-ener-6"])
	state.players[0].active = PokemonState.new("svf-luca")
	state.players[0].active.energy_card_ids.assign([
		"sv1-ener-6", "sv1-ener-6", "sv1-ener-6", "sv1-ener-6"])
	state.players[0].hand.assign(["sv1-ener-6", "sv1-151", "svf-potion"])
	state.players[0].bench[0] = PokemonState.new("svf-klea")
	state.players[1].active = PokemonState.new("svi-maus")
	state.players[1].bench[0] = PokemonState.new("svi-maus")
	return state


func finish_match(profile: String) -> void:
	main.game_mode = "challenge"
	main.native_rules = NativeRulesSessionAdapter.new(main.catalog)
	check(main.native_rules.restore(fixture().snapshot(), 17), "Native fixture restore failed")
	main.state = main.native_rules.state
	main.rng = PortableRandomSource.new(17)
	main.current_view_player = 0
	main.shell_view.build_game_screen()
	await settle(20)
	await measure("battle-" + profile)
	var card: CardView = main.battle_screen.hand_views[0]
	var hand_taps := [0]
	card.activated.connect(func(_a, _b, _c, _d): hand_taps[0] += 1)
	var presenter: Battle3DPresenter = main.battle_screen.render3d
	var point := presenter.global_bounds(card).get_center()
	await swipe(point, Vector2(120, 0))
	check(hand_taps[0] == 0, "Hand swipe was treated as a card tap")
	point = presenter.global_bounds(card).get_center()
	await tap(point)
	check(hand_taps[0] == 1, "One physical hand tap was lost or duplicated")
	report.hand_taps += hand_taps[0]
	main._clear_battle_selection("", false)
	var attack: GameAction
	for action in main._rules_legal_actions(0).concrete_actions():
		if action.kind == "DECLARE_ATTACK":
			attack = action
			break
	check(attack != null, "No legal final attack")
	if attack == null:
		return
	var step: StepResult = main._execute_action_now(attack)
	check(step.success, "Final attack failed")
	var deadline := Time.get_ticks_msec() + 15000
	var prize_tapped := false
	while main.current_screen == "game" and Time.get_ticks_msec() < deadline:
		await settle(1)
		if main.battle_screen == null or main.battle_screen.is_presentation_busy():
			continue
		if main.active_request != null and not prize_tapped:
			check(main.active_request.request_type == "select_prize", "Unexpected final attack choice")
			var prizes: ZoneView = main.battle_screen.zones["own_prizes"]
			await settle(4)
			prize_tapped = true
			report.prize_taps += 1
			await tap(main.battle_screen.render3d.global_bounds(prizes).get_center())
	check(main.current_screen == "end" and main.state.players[0].prizes.is_empty(),
		"One prize tap did not complete the match: " + profile)
	if main.current_screen != "end":
		main.shell_view.show_title()
		return
	await settle(20)
	await capture("results-%d" % report.completed_matches)
	var victory: Control = main.screen_host.get_child(0)
	await tap(victory.title_button.get_global_rect().get_center())
	await settle(20)
	report.completed_matches += 1
	await check_home("match-%d-%s" % [report.completed_matches, profile])
	check(settings._battle_owner == 0, "Battle quality session leaked after match")


func check_render_recovery() -> void:
	var title := main.screen_host.get_child(0) as TitlePage
	var stage := title.card_stage
	stage.viewport.disable_3d = true
	await settle(16)
	stage.viewport.disable_3d = false
	await settle(8)
	await check_home("delayed-drawing")
	var dimensions := stage.viewport.size
	stage.viewport.size = dimensions + Vector2i(1, 1)
	stage.viewport.size = dimensions
	await settle(8)
	await check_home("recreated-target")
	stage._surface.hide()
	stage.viewport.size = dimensions + Vector2i(2, 2)
	await settle(8)
	var image := stage.viewport.get_texture().get_image()
	var center := Vector2i(stage.camera.unproject_position(stage.cards[0].global_position))
	check(image.get_pixelv(center).a > 0.9, "Recreated viewport waits for its first UI sample")
	stage._surface.show()
	await settle(8)
	await check_home("first-ui-sample")
