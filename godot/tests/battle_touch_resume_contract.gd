extends "res://tests/touch_scroll_contract.gd"


func run() -> void:
	Input.use_accumulated_input = false
	Input.emulate_mouse_from_touch = true
	mouse_first = true
	router = root.get_node("TouchInput")
	root.get_node("AppSettings").animation_mode = "reduced"
	root.get_node("AppSettings").quality_profile = "medium"
	Engine.max_fps = 30
	create_timer(120).timeout.connect(func() -> void:
		push_error("Battle touch/resume contract timed out")
		quit(1))
	await check_projected_taps()
	await check_showcase_render_recovery()
	await check_return_to_title()
	await check_completed_match_return()
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("BATTLE_TOUCH_RESUME_CONTRACT_OK")
	quit(0 if failures.is_empty() else 1)


func check_projected_taps() -> void:
	var table := load("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	root.add_child(table)
	var state := UIPreviewStateFactory.battle_state()
	table.update_view(state, 0, UIPreviewStateFactory.action_rows(state), "", false, "local")
	var presenter := table.render3d
	var taps := [0, 0]
	for card in table.hand_views:
		card.activated.connect(func(_id, _index, _player, _slot): taps[0] += 1)
	var prizes := table.zones["own_prizes"] as ZoneView
	prizes.stack_index_activated.connect(func(_index): taps[1] += 1)
	var outside_samples := [0, 0]
	for dimensions in [Vector2i(900, 540), Vector2i(1280, 800), Vector2i(2000, 1200)]:
		root.size = dimensions
		await settle(6)
		presenter.sync_surfaces()
		var anchors: Array[Control] = [table.hand_views[0], prizes]
		for index in range(anchors.size()):
			var anchor := anchors[index]
			var point := projected_point_outside_layout(presenter, anchor)
			if not point.is_finite():
				continue
			outside_samples[index] += 1
			var before: int = taps[index]
			touch_button(true, point)
			check(router._source_control() == anchor,
				"Projected tap must start on %s, got %s" % [anchor.name, router._source_control()])
			await settle(1)
			move_touch(point + Vector2(1, 0))
			if anchor is CardView:
				check(not anchor._hovered, "Touch jitter applied mouse-hover lift to the hand")
				anchor.mouse_exited.emit()
			await settle(2)
			touch_button(false, point)
			await settle(3)
			check(taps[index] == before + 1,
				"One projected %s tap was rejected at %s (point=%s layout=%s)" % [anchor.name, dimensions, point, anchor.get_global_rect()])
	check(outside_samples[0] > 0 and outside_samples[1] > 0,
		"Physical hand/prize fixtures must exercise hits outside 2D layout rectangles: %s" % [outside_samples])
	table.queue_free()
	await settle(4)


func projected_point_outside_layout(presenter: Battle3DPresenter, anchor: Control) -> Vector2:
	var bounds := presenter.global_bounds(anchor)
	var layout_rect := anchor.get_global_rect()
	for y in [0.2, 0.4, 0.6, 0.8]:
		for x in [0.15, 0.35, 0.55, 0.75, 0.9]:
			var point := bounds.position + bounds.size * Vector2(x, y)
			if not layout_rect.has_point(point) and presenter.contains_global_point(anchor, point):
				return point
	return Vector2(INF, INF)


func check_showcase_render_recovery() -> void:
	if DisplayServer.get_name() == "headless":
		return
	root.get_node("AppSettings").quality_profile = "low"
	var stage := FrontendCardShowcase3D.new()
	stage.size = Vector2(500, 400)
	root.add_child(stage)
	# Fault injection: the window keeps drawing while this viewport cannot yet
	# draw 3D. Global frame_post_draw notifications are not a readiness signal.
	stage.viewport.disable_3d = true
	await settle(16)
	stage.viewport.disable_3d = false
	await settle(6)
	await RenderingServer.frame_post_draw
	check_showcase_image(stage, "delayed 3D readiness")
	check(not stage.is_processing(), "Low quality keeps an unnecessary animation loop running")
	# Reallocate the render target without a UI resize. A static pose must still
	# repaint after renderer-side invalidation instead of preserving blank pixels.
	var dimensions := stage.viewport.size
	stage.viewport.size = dimensions + Vector2i(1, 1)
	stage.viewport.size = dimensions
	await settle(6)
	await RenderingServer.frame_post_draw
	check_showcase_image(stage, "render target recreated")
	stage.set_active(false)
	check(stage.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"Covered homepage did not suspend its viewport")
	stage.set_active(true)
	stage.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	check(stage.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"Paused homepage did not suspend its viewport")
	stage.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await settle(6)
	await RenderingServer.frame_post_draw
	check_showcase_image(stage, "application resumed")
	stage.queue_free()
	await settle(4)


func check_return_to_title() -> void:
	root.size = Vector2i(1280, 800)
	var main := load("res://scenes/main/main.tscn").instantiate() as Control
	root.add_child(main)
	await settle(8)
	var settings := root.get_node("AppSettings")
	for profile in ["low", "medium"]:
		for mode in ["standard", "reduced"]:
			settings.quality_profile = profile
			settings.animation_mode = mode
			settings.changed.emit()
			main.state = UIPreviewStateFactory.battle_state()
			main.game_mode = "local"
			main.current_view_player = 0
			main.shell_view.build_game_screen()
			main.battle_screen.set_local_hand_privacy_hidden(false)
			await settle(8)
			main._show_pause_overlay()
			await settle(8)
			await tap(main.modal_cancel)
			await settle(8)
			await tap(main.modal_confirm)
			await settle(15)
			check(main.current_screen == "title", "Exit confirmation did not return to title")
			var title := main.screen_host.get_child(0) as TitlePage
			if title == null:
				continue
			var stage := title.card_stage
			check(stage._active and not stage._suspended and stage.is_visible_in_tree(),
				"Returning from battle left the homepage showcase inactive")
			if DisplayServer.get_name() != "headless":
				await RenderingServer.frame_post_draw
				check_showcase_image(stage, "%s/%s after battle" % [profile, mode])
				var capture_path := "res://../build/tablet-home-return-%s-%s.png" % [profile, mode]
				check(root.get_texture().get_image().save_png(capture_path) == OK, "Could not capture homepage return")
	main.queue_free()
	await settle(4)


func last_prize_state() -> GameState:
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
		"sv1-ener-6", "sv1-ener-6", "sv1-ener-6", "sv1-ener-6",
	])
	state.players[0].bench[0] = PokemonState.new("svf-klea")
	state.players[1].active = PokemonState.new("svi-maus")
	state.players[1].bench[0] = PokemonState.new("svi-maus")
	return state


func check_completed_match_return() -> void:
	var main := load("res://scenes/main/main.tscn").instantiate() as Control
	root.add_child(main)
	await settle(8)
	var settings := root.get_node("AppSettings")
	for profile in ["low", "medium"]:
		for mode in ["standard", "reduced"]:
			root.size = Vector2i(640, 960) if mode == "reduced" else Vector2i(1526, 1079)
			settings.quality_profile = profile
			settings.animation_mode = mode
			settings.changed.emit()
			main.game_mode = "challenge"
			main.native_rules = NativeRulesSessionAdapter.new(main.catalog)
			check(main.native_rules.restore(last_prize_state().snapshot(), 17), "Last-prize fixture restore failed")
			main.state = main.native_rules.state
			main.rng = PortableRandomSource.new(17)
			main.current_view_player = 0
			main.shell_view.build_game_screen()
			await settle(8)
			var attack: GameAction
			for action in main._rules_legal_actions(0).concrete_actions():
				if action.kind == "DECLARE_ATTACK":
					attack = action
					break
			check(attack != null, "Last-prize fixture has no legal attack")
			if attack == null:
				continue
			var result: StepResult = main._execute_action_now(attack)
			check(result.success, "Last-prize attack failed")
			var deadline := Time.get_ticks_msec() + 15000
			while main.current_screen == "game" and Time.get_ticks_msec() < deadline:
				await process_frame
				if main.battle_screen == null or main.battle_screen.is_presentation_busy():
					continue
				var request: ChoiceView = main.active_request
				if request != null and request.player == 0:
					main._toggle_choice(str(request.options[0].option_id))
					main._confirm_choice()
			check(main.state.is_terminal() and main.state.players[0].prizes.is_empty(),
				"Taking the final prize did not finish the match")
			check(main.current_screen == "end", "Completed match did not show results")
			var victory := main.screen_host.get_child(0) as Control
			if not victory.has_signal("title_requested"):
				continue
			await settle(20)
			await tap(victory.title_button)
			await settle(20)
			check(main.current_screen == "title", "Results return button did not open homepage")
			check(settings._battle_owner == 0, "Completed match retained its battle quality session")
			var title := main.screen_host.get_child(0) as TitlePage
			if title == null:
				continue
			var stage := title.card_stage
			check(stage._active and not stage._suspended and stage.is_visible_in_tree(),
				"Completed match left homepage showcase inactive")
			check(stage.viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED,
				"Completed match froze the visible homepage render target")
			if DisplayServer.get_name() != "headless":
				await RenderingServer.frame_post_draw
				check_showcase_image(stage, "%s/%s after last prize" % [profile, mode])
				var path := "res://../build/tablet-match-finished-%s-%s.png" % [profile, mode]
				check(root.get_texture().get_image().save_png(path) == OK, "Could not capture completed match return")
			print("COMPLETED_MATCH_RETURN ", profile, "/", mode)
	main.queue_free()
	await settle(4)


func check_showcase_image(stage: FrontendCardShowcase3D, label: String) -> void:
	var pixels := stage.viewport.get_texture().get_image()
	check(pixels != null and not pixels.is_empty(), "Homepage viewport is empty: " + label)
	if pixels == null or pixels.is_empty():
		return
	# Sample the clear cloth corners, away from the card fan. A transparent or
	# blank frozen viewport must not pass just because its mesh nodes exist.
	for x in [-2.2, 2.2]:
		var point := stage.camera.unproject_position(stage._mat.global_position + Vector3(x, 0.025, 1.3))
		var pixel := Vector2i(point)
		check(Rect2i(Vector2i.ZERO, pixels.get_size()).has_point(pixel), "Cloth sample is outside the viewport")
		if Rect2i(Vector2i.ZERO, pixels.get_size()).has_point(pixel):
			check(pixels.get_pixelv(pixel).a > 0.9, "Homepage cloth disappeared: " + label)
