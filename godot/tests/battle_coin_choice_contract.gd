extends SceneTree

const CASES := [
	{"id": "catcher-heads", "card": "sv2-catch", "seed": 2, "heads": true},
	{"id": "catcher-tails", "card": "sv2-catch", "seed": 1, "heads": false},
	{"id": "hammer-heads", "card": "svg2-hamm", "seed": 2, "heads": true},
	{"id": "hammer-tails", "card": "svg2-hamm", "seed": 1, "heads": false},
	{"id": "triple", "card": "sv1-107", "seed": 2, "attack": true},
	{"id": "double", "card": "svf-klea", "seed": 1, "attack": true},
	{"id": "until-tails", "card": "svg-swa", "seed": 2, "attack": true},
]
var failures: Array[String] = []
var records: Array[Dictionary] = []
var main: Node
var graphics := false
var _table_coins := 0
var _audio: Array[Dictionary] = []


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	node_added.connect(_watch_coin)
	call_deferred("_run")


func _watch_coin(node: Node) -> void:
	if node is CoinShowcase and not node.render_in_table:
		var showcase := node as CoinShowcase
		showcase.audio_requested.connect(func(cue: String) -> void:
			_audio.append({"cue": cue, "progress": showcase._toss_progress, "index": showcase._current_index}))


func _check(ok: bool, message: String) -> void:
	if not ok and message not in failures:
		failures.append(message)


func _frames(count: int = 1) -> void:
	for i in range(count):
		await process_frame
		if graphics: await RenderingServer.frame_post_draw


func _run() -> void:
	graphics = DisplayServer.get_name() != "headless"
	Engine.max_fps = 60
	root.get_node("AppSettings").quality_profile = "high"
	root.size = Vector2i(1600, 900)
	root.content_scale_size = root.size
	create_timer(180).timeout.connect(func() -> void:
		push_error("Coin choice contract timed out")
		quit(1))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../build/coin-choice"))
	main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	await _frames(2)
	main.game_mode = "local"
	main.rng = PortableRandomSource.new(2)
	main.native_rules = NativeRulesSessionAdapter.new(main.catalog)
	main.native_rules.restore(_fixture(CASES[0], 0).snapshot(), 2)
	main.state = main.native_rules.state
	main.current_view_player = 0
	main.shell_view.build_game_screen()
	main.battle_screen.coin_showcase.audio_requested.connect(func(cue: String) -> void:
		if cue == "coin_toss": _table_coins += 1)
	await _frames(5)
	for mode in ["standard", "cinematic", "fast", "reduced"]:
		root.get_node("AppSettings").animation_mode = mode
		for case in CASES:
			await _run_case(case, mode, 0)
		await _run_case(CASES[0], mode, 1)
	root.get_node("AppSettings").animation_mode = "standard"
	await _check_lifecycle()
	await _check_old_feedback()
	await _check_workbench()
	var file := FileAccess.open("res://../build/coin-choice/validation-%s.json" % ("graphics" if graphics else "headless"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"cases": records, "failures": failures}, "\t"))
	file.close()
	main.queue_free()
	await _frames(8)
	if failures.is_empty(): print("BATTLE_COIN_CHOICE_OK cases=%d graphics=%s" % [records.size(), graphics])
	else:
		for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _fixture(case: Dictionary, actor: int) -> GameState:
	var state := GameState.new()
	state.revision = 100 + records.size() * 100
	state.setup_stage = GameState.SETUP_COMPLETE
	state.phase = "MAIN"
	state.turn_number = 4
	state.active_player_idx = actor
	state.first_player_idx = 1 - actor
	state.public_deck_keys.assign(["lightning", "psychic"])
	for player in state.players:
		player.active = PokemonState.new("sv1-104")
		player.active.energy_card_ids.assign(["sv1-ener-4"])
		player.bench[0] = PokemonState.new("svl-emol")
		player.bench[1] = PokemonState.new("svl-chin")
		player.prizes.assign(["sv1-ener-4", "sv1-ener-4", "sv1-151"])
		player.deck.assign(["sv1-ener-4", "sv1-151", "sv1-153", "sv1-189"])
		player.hand.assign(["sv1-151", "sv1-ener-4"])
	var own := state.players[actor]
	if bool(case.get("attack", false)):
		own.active = PokemonState.new(str(case.card))
		own.active.energy_card_ids.assign(["sv1-ener-5", "sv1-ener-6", "sv1-ener-4", "sv1-ener-1"])
	else:
		own.hand.push_front(str(case.card))
	return state


func _prepare(case: Dictionary, actor: int) -> GameAction:
	main.choice_presenter.clear()
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)
	main.battle_screen.clear_presentation_for_resync()
	_check(main.native_rules.restore(_fixture(case, actor).snapshot(), int(case.seed)), str(case.id) + ": native restore failed")
	main.state = main.native_rules.state
	main.rng.set_state(main.native_rules.rng_state)
	main.current_view_player = actor
	main.battle_screen.set_local_hand_privacy_hidden(false)
	main._refresh_game()
	await _frames(4)
	for action in main._rules_legal_actions(actor).concrete_actions():
		if (bool(case.get("attack", false)) and action.kind == "DECLARE_ATTACK" and action.attack_index() == 0) or (action.kind == "PLAY_TRAINER" and action.source.card_id == case.card):
			return action
	return null


func _open_case(case: Dictionary, actor: int) -> CoinShowcase:
	var action := await _prepare(case, actor)
	_check(action != null, str(case.id) + ": no legal real card action")
	if action == null: return null
	var step: StepResult = main._execute_action_now(action)
	_check(step.success and step.pending_choice != null and step.pending_choice.request_type == "coin_flip", str(case.id) + ": real card did not request coin confirmation")
	var deadline := Time.get_ticks_msec() + 7000
	while main.choice_presenter.active_coin_showcase == null and Time.get_ticks_msec() < deadline:
		await _frames()
	return main.choice_presenter.active_coin_showcase


func _run_case(case: Dictionary, mode: String, actor: int) -> void:
	var tag := "%s-%s-view%d" % [case.id, mode, actor]
	_audio.clear()
	var showcase := await _open_case(case, actor)
	_check(showcase != null, tag + ": actual ChoicePresenter did not create a showcase")
	if showcase == null: return
	var request: ChoiceView = main.active_request
	var authoritative: Array = request.presentation.get("predetermined_flips", [])
	_check(showcase.results == authoritative, tag + ": modal changed authoritative flips")
	if case.has("heads"): _check(authoritative == [case.heads], tag + ": seed does not cover intended branch")
	if case.id == "triple": _check(authoritative.size() == 3, tag + ": triple toss missing")
	if case.id == "until-tails": _check(authoritative.size() >= 3 and authoritative[-1] == false, tag + ": until-tails chain missing")
	var stage := showcase.embedded_stage
	_check(stage != null and stage.coin != null, tag + ": real card still uses the old flat coin")
	_check(bool((stage.coin._shadow.material_override as ShaderMaterial).get_shader_parameter("round_shadow")), tag + ": coin still casts a rectangular card shadow")
	_check(main.battle_screen.coin_showcase.embedded_stage == null, tag + ": table allocates an unnecessary coin viewport")
	var revision: int = main.state.revision
	main.choice_presenter.refresh_selection()
	_check(main.modal_confirm.disabled, tag + ": refresh unlocked confirmation during playback")
	main._confirm_choice()
	_check(main.active_request == request and main.state.revision == revision, tag + ": premature confirmation settled the rule")
	var captured := false
	var started := Time.get_ticks_msec()
	var motion_frames: Array[Image] = []
	var frame_times: Array[int] = []
	while showcase.is_playing() and Time.get_ticks_msec() - started < 10000:
		await _frames()
		if graphics and mode == "standard" and actor == 0 and case.id in ["catcher-heads", "triple"]:
			motion_frames.append(root.get_texture().get_image().get_region(Rect2i(440, 180, 720, 540)))
			frame_times.append(Time.get_ticks_msec() - started)
		if showcase._current_index >= 0:
			_check(stage.coin.result_heads == authoritative[showcase._current_index], tag + ": rendered result disagrees with rule")
			var bounds := _coin_bounds(stage)
			_check(not bounds.intersects(showcase._title_label.get_rect()), tag + ": airborne coin overlaps the title")
			_check(not bounds.intersects(showcase._result_rect()), tag + ": coin overlaps the result history")
		_check(not main.battle_screen.render3d.world.coin.visible, tag + ": modal and table coins render simultaneously")
		if mode == "standard" and showcase._toss_progress > 0.35 and showcase._toss_progress < 0.65 and not captured:
			_capture(tag + "-airborne")
			captured = true
	_check(not showcase.is_playing() and not main.modal_confirm.disabled, tag + ": completed toss left confirmation locked")
	_check(showcase._history_count == authoritative.size(), tag + ": missing result history")
	_check((stage.coin.transform.basis.y.normalized().y > 0) == bool(authoritative[-1]), tag + ": physical face is wrong")
	var lands := 0
	for sound in _audio:
		if sound.cue == "coin_land":
			lands += 1
			_check(mode == "reduced" or (sound.progress >= MotionPolicy.PROFILE.coin_contact_fraction and sound.progress < 0.98), tag + ": landing audio missed contact")
	_check(lands == (1 if mode == "reduced" else authoritative.size()), tag + ": landing audio repeated or missing")
	var frozen := stage.coin.transform
	await _frames(3)
	_check(frozen.is_equal_approx(stage.coin.transform), tag + ": result did not settle")
	if mode == "standard" or case.id == "triple": _capture(tag + "-result")
	if not motion_frames.is_empty():
		var folder := "res://../build/coin-choice/" + str(case.id) + "-motion"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
		for i in range(motion_frames.size()):
			motion_frames[i].save_png(folder.path_join("%04d.png" % i))
		var metadata := FileAccess.open(folder.path_join("frames.json"), FileAccess.WRITE)
		metadata.store_string(JSON.stringify(frame_times))
		metadata.close()
	var flips_before := _table_coins
	main.modal_confirm.pressed.emit()
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		await _frames()
		if main.modal_host_controller.closing or main.battle_screen.is_presentation_busy(): continue
		var next: ChoiceView = main.active_request
		if next != null and next.request_type != "coin_flip":
			if not next.options.is_empty():
				main._on_battle_choice_target_selected(str(next.options[0].option_id))
				continue
		break
	_check(_table_coins == flips_before, tag + ": confirmation replays a table toss")
	_check(main.state.revision > revision, tag + ": real choice was never submitted")
	if case.card == "sv2-catch":
		_check(main.state.players[1 - actor].active.card_id == ("svl-emol" if case.heads else "sv1-104"), tag + ": Catcher applied the wrong switch branch")
	if case.card == "svg2-hamm":
		_check(main.state.players[1 - actor].active.energy_card_ids.size() == (0 if case.heads else 1), tag + ": Crushing Hammer applied the wrong discard branch")
	var record := {"case": case.id, "mode": mode, "actor": actor, "flips": authoritative, "landing_sounds": lands}
	records.append(record)
	print("COIN_CHOICE_CASE ", JSON.stringify(record))


func _check_lifecycle() -> void:
	var showcase := await _open_case(CASES[0], 0)
	if showcase == null: return
	var request: ChoiceView = main.active_request
	var old_handle := showcase._active_handle
	var old_stage: WeakRef = weakref(showcase.embedded_stage)
	# Re-presenting after resync must cancel the old timeline without its callback
	# enabling the new modal's button. Both choices retain the same rule result.
	main._show_choice_overlay(request)
	await _frames(3)
	showcase = main.choice_presenter.active_coin_showcase
	_check(old_handle.status == MotionHandle.CANCELLED and old_stage.get_ref() == null, "Resync retained a previous coin timeline or viewport")
	_check(main.modal_confirm.disabled and showcase.results == request.presentation.predetermined_flips, "Resync changed the coin result or prematurely unlocked confirmation")
	var stage := showcase.embedded_stage
	stage._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_check(stage.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Coin viewport keeps drawing while suspended")
	stage._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	_check(stage.viewport.render_target_update_mode == SubViewport.UPDATE_WHEN_VISIBLE, "Coin viewport failed to resume")
	var handle := showcase._active_handle
	main.choice_presenter.clear()
	_check(handle.status == MotionHandle.CANCELLED and not showcase.visible, "Clearing choice did not cancel and hide coin")
	_check(main.modal_confirm.disabled, "Cancelled coin unlocked confirmation")
	for quality in ["high", "medium", "low"]:
		root.get_node("AppSettings").quality_profile = quality
		for dimensions in [Vector2i(1280, 720), Vector2i(900, 540), Vector2i(720, 1280)]:
			root.size = dimensions
			root.content_scale_size = dimensions
			showcase = await _open_case(CASES[0], 0)
			if showcase == null: continue
			while showcase.is_playing(): await _frames()
			await _frames(3)
			stage = showcase.embedded_stage
			var projected := _coin_bounds(stage)
			_check(Rect2(Vector2.ZERO, stage.size).encloses(projected), "Coin cropped at %s/%s" % [quality, dimensions])
			_capture("catcher-%s-%dx%d" % [quality, dimensions.x, dimensions.y])
	# Retargeting during the toss must preserve its clock and result, including
	# the actual render-target pixel size after consecutive DPI/layout changes.
	showcase = await _open_case(CASES[0], 0)
	if showcase != null:
		var progress := showcase._toss_progress
		for dimensions in [Vector2i(1280, 720), Vector2i(900, 540), Vector2i(1000, 700), Vector2i(720, 1280)]:
			root.size = dimensions
			root.content_scale_size = dimensions
			await _frames(2)
			_check(showcase._toss_progress >= progress and showcase.results == [true], "Resizing restarted or changed the coin toss")
			progress = showcase._toss_progress
	root.size = Vector2i(1600, 900)
	root.content_scale_size = root.size
	root.get_node("AppSettings").quality_profile = "high"
	showcase = await _open_case(CASES[0], 0)
	if showcase == null: return
	handle = showcase._active_handle
	old_stage = weakref(showcase.embedded_stage)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)
	await _frames(3)
	_check(handle.status == MotionHandle.CANCELLED and old_stage.get_ref() == null, "Closing modal leaked a running coin or render target")


func _check_old_feedback() -> void:
	var table: BattleTable = main.battle_screen
	for mode in ["standard", "reduced"]:
		root.get_node("AppSettings").animation_mode = mode
		for kind in ["setup_reveal", "attachment_release"]:
			var card := table.get_slot_view(0, "active")
			var hud_rects := card.find_children("*", "ColorRect", true, false).size()
			table.presentation_runtime._on_burst_requested(kind, {"player": 0, "slot": "active"}, DesignTokens.GOLD)
			_check(card.find_children("*", "ColorRect", true, false).size() == hud_rects, kind + ": feedback created a rectangular flash overlay")
			if mode == "standard":
				_check(not table.render3d.world.feedback._bursts.is_empty(), kind + ": missing physical replacement")
			else:
				_check(not table.world_feedback.static_outlines.is_empty(), kind + ": missing reduced-motion outline")
			await _frames(2)
			_capture(kind + "-" + mode)
			table.clear_presentation_for_resync()


func _capture(tag: String) -> void:
	if graphics:
		root.get_texture().get_image().save_png("res://../build/coin-choice/%s.png" % tag)


func _coin_bounds(stage: CoinStage3D) -> Rect2:
	var bounds := Rect2(stage.projection.world_to_screen(stage.coin.position), Vector2.ZERO)
	for i in range(32):
		var angle := i * TAU / 32.0
		for height in [-0.06, 0.06]:
			bounds = bounds.expand(stage.projection.world_to_screen(stage.coin.transform * Vector3(cos(angle) * 0.50, height, sin(angle) * 0.50)))
	return bounds


func _check_workbench() -> void:
	main.visible = false
	root.get_node("AppSettings").animation_mode = "fast"
	var bench: Node = load("res://tools/ui_workbench.tscn").instantiate()
	root.add_child(bench)
	await _frames(3)
	for kind in ["coin_choice_heads", "coin_choice_tails", "coin_choice_multi"]:
		bench.show_preview(kind)
		await _frames(3)
		var match_ui: Node = bench.preview_host.get_child(0)
		var deadline := Time.get_ticks_msec() + 5000
		while match_ui.choice_presenter.active_coin_showcase == null and Time.get_ticks_msec() < deadline:
			await _frames()
		var coin: CoinShowcase = match_ui.choice_presenter.active_coin_showcase
		_check(coin != null and coin.embedded_stage != null, kind + ": Workbench misses the actual coin choice")
		if coin != null:
			_check(coin.results == ([true] if kind == "coin_choice_heads" else [false] if kind == "coin_choice_tails" else [true, true, true, true, true, false]), kind + ": Workbench did not execute the intended real rule")
	bench.queue_free()
	await _frames(5)
