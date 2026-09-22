extends Node

## Device-only scene, excluded from product exports. Uses the real renderer,
## native rules and input pipeline at the device's own resolution.
var main: Control
var settings: Node
var window: Window
var pointer := Vector2.ZERO
var failures: Array[String] = []
var report := {"profiles": [], "completed_matches": 0, "hand_taps": 0, "prize_taps": 0}


func _ready() -> void:
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
	check(pixels != null and not pixels.is_empty(), label + ": no viewport image")
	if pixels == null or pixels.is_empty():
		return
	for x in [-2.2, 2.2]:
		var point := Vector2i(stage.camera.unproject_position(stage._mat.global_position + Vector3(x, 0.025, 1.3)))
		check(Rect2i(Vector2i.ZERO, pixels.get_size()).has_point(point), label + ": cloth outside viewport")
		if Rect2i(Vector2i.ZERO, pixels.get_size()).has_point(point):
			check(pixels.get_pixelv(point).a > 0.9, label + ": transparent cloth")
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
	var row := {"label": label, "p50_ms": frames[frames.size() / 2],
		"p95_ms": frames[ceili(frames.size() * 0.95) - 1], "target_fps": Engine.max_fps}
	report.profiles.append(row)
	print("ANDROID_TOUCH_PERFORMANCE ", JSON.stringify(row))


func run() -> void:
	window = get_window()
	settings = get_node("/root/AppSettings")
	settings.muted = true
	settings.quality_profile = "auto"
	settings.animation_mode = "standard"
	Input.use_accumulated_input = false
	Input.emulate_mouse_from_touch = true
	get_tree().create_timer(180).timeout.connect(func() -> void:
		push_error("ANDROID_TOUCH_ACCEPTANCE_TIMEOUT")
		get_tree().quit(1))
	report["platform"] = OS.get_name()
	report["gpu"] = RenderingServer.get_video_adapter_name()
	report["resolution"] = str(window.size)
	print("ANDROID_TOUCH_DEVICE ", JSON.stringify(report))
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await settle(20)
	await check_home("initial")
	await measure("home-auto")
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
	var scroll: ScrollContainer = main.modal_host_controller.modal_scroll
	var before := slider.value
	await swipe(slider.get_global_rect().get_center(), Vector2(0, -140))
	check(scroll.scroll_vertical > 0, "Vertical slider gesture did not scroll the settings page")
	check(is_equal_approx(before, slider.value), "Vertical slider gesture changed volume")
	scroll.scroll_vertical = 0
	await settle(15)
	await swipe(slider.get_global_rect().get_center(), Vector2(100, 0))
	check(slider.value > before, "Horizontal slider gesture did not change volume")
	check(scroll.scroll_vertical == 0, "Horizontal slider gesture scrolled settings")
	await tap(main.modal_cancel.get_global_rect().get_center())
	await settle(12)
	check(not main.modal_layer.visible, "One cancel tap did not close settings")
	await check_home("after-settings")


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
