extends SceneTree

var _failed := false
var _previous_animation_mode := "standard"
var _previous_reduced_motion := false
var _settings: Node
var _stage := "initialize"
var _finished := false


func _initialize() -> void:
	root.size = Vector2i(1280, 720)
	call_deferred("_run")
	call_deferred("_watchdog")


func _watchdog() -> void:
	await create_timer(10.0, true, false, true).timeout
	if _finished:
		return
	_failed = true
	push_error("UI Workbench transition contract timed out at %s" % _stage)
	_finish()


func _run() -> void:
	_settings = root.get_node_or_null("AppSettings")
	_check(_settings != null, "AppSettings autoload is unavailable")
	if _settings == null:
		_finish()
		return
	_previous_animation_mode = str(_settings.get("animation_mode"))
	_previous_reduced_motion = bool(_settings.get("reduced_motion"))
	_settings.set("animation_mode", "fast")
	_settings.set("reduced_motion", false)
	var scene := load("res://tools/ui_workbench.tscn") as PackedScene
	_check(scene != null, "UI Workbench scene could not be loaded")
	if scene == null:
		_finish()
		return
	var workbench := scene.instantiate()
	root.add_child(workbench)
	_check(
		workbench.has_method("load_native_scenario")
		and workbench.has_method("replay_match_journal"),
		"UI Workbench Native ABI 2 scenario/journal tools are missing",
	)
	if ClassDB.class_exists("NativeRulesSession"):
		var catalog := CardCatalog.shared()
		var native: Variant = ClassDB.instantiate("NativeRulesSession")
		var created: Dictionary = native.create(
			catalog.native_rules_catalog(),
			[catalog.expand_deck("fire"), catalog.expand_deck("water")],
			{"forced_first": 0, "public_deck_keys": ["fire", "water"]},
			4242,
		)
		_check(bool(created.get("success", false)),
			"Workbench native replay fixture could not start")
		if bool(created.get("success", false)):
			var replay_decks: Array[String] = ["fire", "water"]
			var replayed: Dictionary = workbench.call(
				"replay_match_journal", native.journal(), replay_decks, 0, false)
			_check(
				bool(replayed.get("success", false))
				and int(replayed.get("mismatch_index", -2)) == -1,
				"Workbench MatchJournal v1 replay diverged",
			)
			var loaded: Dictionary = workbench.call(
				"load_native_scenario", native.snapshot(), native.rng_state(), 0, false)
			_check(bool(loaded.get("success", false)),
				"Workbench Snapshot 3 scenario load failed")
	await process_frame
	_check(
		workbench.find_child("Checkpoint0", true, false) != null
		and workbench.find_child("Checkpoint50", true, false) != null
		and workbench.find_child("Checkpoint100", true, false) != null,
		"UI Workbench checkpoint controls are missing",
	)

	_stage = "checkpoint_0"
	await workbench.capture_presentation_checkpoint(0, "draw")
	var checkpoint: Dictionary = workbench.call("get_presentation_checkpoint")
	var before_view: Variant = checkpoint.get("before_view")
	var after_view: Variant = checkpoint.get("after_view")
	var request: Variant = checkpoint.get("request")
	var before_state: Variant = before_view.call("state_for_render")
	var after_state: Variant = after_view.call("state_for_render")
	_check(int(checkpoint.get("percent", -1)) == 0, "0% checkpoint was not ready")
	_check(
		after_state.players[0].hand.size() == before_state.players[0].hand.size() + 1
		and after_state.players[0].deck.size() == before_state.players[0].deck.size() - 1,
		"Draw fixture before/after states are not a real state transition",
	)
	_check(
		request != null
		and request.target_view == after_view
		and request.events.size() == 1
		and str(request.events[0].get("event_type", "")) == "cards_drawn",
		"Draw fixture did not build an atomic BattleTransitionRequest",
	)

	_stage = "checkpoint_50"
	await workbench.capture_presentation_checkpoint(50, "draw")
	checkpoint = workbench.call("get_presentation_checkpoint")
	_check(int(checkpoint.get("percent", -1)) == 50, "50% checkpoint was not ready")
	_check(
		workbench.current_battle.process_mode == Node.PROCESS_MODE_DISABLED,
		"50% checkpoint did not pause the battle motion subtree",
	)
	_check_motion_card_faces(
		workbench.current_battle,
		"draw checkpoint",
		"sv1-151",
	)
	_check(
		workbench.current_battle.log_label != null
		and "预览玩家抽到了 妙蛙种子。" in workbench.current_battle.log_label.text,
		"50% checkpoint hid the committed action log until animation completion",
	)

	_stage = "checkpoint_100"
	await workbench.capture_presentation_checkpoint(100, "draw")
	checkpoint = workbench.call("get_presentation_checkpoint")
	var rendered_state: Variant = workbench.current_battle.state_ref
	var final_view: Variant = checkpoint.get("after_view")
	var target_state: Variant = final_view.call("state_for_render")
	_check(int(checkpoint.get("percent", -1)) == 100, "100% checkpoint was not ready")
	_check(
		workbench.current_battle.process_mode == Node.PROCESS_MODE_INHERIT
		and rendered_state.revision == target_state.revision
		and rendered_state.players[0].hand.size() == target_state.players[0].hand.size(),
		"100% checkpoint did not reconcile to the target BattleViewModel",
	)

	# Compatibility journals may contain the old sparse payload shape. The
	# visible landing CardView must still supply the real face instead of a
	# neutral placeholder while the authoritative event contract is upgraded.
	_stage = "checkpoint_sparse_50"
	await workbench.capture_presentation_checkpoint(50, "draw_sparse")
	checkpoint = workbench.call("get_presentation_checkpoint")
	request = checkpoint.get("request")
	var sparse_event: Dictionary = request.events[0] if request != null else {}
	var sparse_data: Dictionary = sparse_event.get("data", {})
	_check(
		str(sparse_event.get("card_id", "")).is_empty()
		and Array(sparse_data.get("card_ids", [])).is_empty(),
		"Sparse draw fixture unexpectedly supplied a card identity",
	)
	_check_motion_card_faces(
		workbench.current_battle,
		"sparse draw checkpoint",
		"sv1-151",
	)

	_stage = "checkpoint_cross_owner_draw_50"
	await workbench.capture_presentation_checkpoint(50, "cross_owner_draw")
	checkpoint = workbench.call("get_presentation_checkpoint")
	request = checkpoint.get("request")
	var cross_owner_event: Dictionary = request.events[0] if request != null else {}
	var cross_owner_event_id := str(cross_owner_event.get("event_id", ""))
	_check_motion_card_faces(
		workbench.current_battle,
		"cross-owner draw checkpoint",
		"sv1-151",
	)
	_check(
		int(cross_owner_event.get("actor", -1)) == 1
		and int(Dictionary(cross_owner_event.get("target", {})).get(
			"player", -1)) == 0
		and Array(workbench.current_battle._presentation_event_hand_targets.get(
			cross_owner_event_id, [])).size() == 1
		and workbench.current_battle._hand_transition_sequences.has(
			cross_owner_event_id),
		"Cross-player effect skipped the physical owner's hand landing/reflow choreography",
	)

	_stage = "checkpoint_damage_50"
	await workbench.capture_presentation_checkpoint(50, "damage")
	checkpoint = workbench.call("get_presentation_checkpoint")
	before_view = checkpoint.get("before_view")
	before_state = before_view.call("state_for_render")
	var cover_states: Dictionary = (
		workbench.current_battle._presentation_slot_cover_states
	)
	var source_cover := cover_states.get("0:active") as PokemonState
	var target_cover := cover_states.get("1:active") as PokemonState
	_check(
		source_cover != null
		and target_cover != null
		and source_cover.damage_counters
			== before_state.players[0].active.damage_counters
		and target_cover.damage_counters
			== before_state.players[1].active.damage_counters + 9,
		"Damage feedback mutated the attacker before the defender",
	)
	var target_cover_view := workbench.current_battle._presentation_slot_covers.get(
		"1:active"
	) as CardView
	_check_presentation_inspection_hit(
		workbench.current_battle,
		target_cover_view,
		"damage checkpoint target cover",
	)

	_stage = "checkpoint_identical_retreat_50"
	await workbench.capture_presentation_checkpoint(50, "retreat_identical")
	checkpoint = workbench.call("get_presentation_checkpoint")
	_check(
		int(checkpoint.get("percent", -1)) == 50,
		"Identical retreat 50% checkpoint was not ready",
	)
	_check_identical_slot_swap_motion(
		workbench.current_battle,
		"identical retreat checkpoint",
	)
	var retreat_mover: CardView
	for value in workbench.current_battle._active_flyers:
		var candidate := value as CardView
		if candidate != null and bool(candidate.get_meta("slot_composite_motion", false)):
			retreat_mover = candidate
			break
	_check_presentation_inspection_hit(
		workbench.current_battle,
		retreat_mover,
		"retreat checkpoint moving Pokemon",
	)
	_stage = "checkpoint_identical_retreat_100"
	await workbench.capture_presentation_checkpoint(100, "retreat_identical")
	checkpoint = workbench.call("get_presentation_checkpoint")
	final_view = checkpoint.get("after_view")
	target_state = final_view.call("state_for_render")
	rendered_state = workbench.current_battle.state_ref
	_check(
		int(checkpoint.get("percent", -1)) == 100
		and workbench.current_battle.process_mode == Node.PROCESS_MODE_INHERIT
		and rendered_state.revision == target_state.revision
		and rendered_state.players[0].active.card_id == "svi-chim"
		and rendered_state.players[0].bench[0].card_id == "svi-chim",
		"Identical retreat did not reconcile after the visible slot swap",
	)
	_stage = "live_pointer_dispatch"
	var live_handle: Variant = workbench.call("trigger_presentation", "damage")
	var live_battle: BattleTable = workbench.current_battle
	var live_target: CardView
	for _attempt in range(24):
		await create_timer(0.01, true, false, true).timeout
		live_target = live_battle._presentation_slot_covers.get("1:active") as CardView
		if (
			live_target != null
			and live_battle.input_blocker != null
			and live_battle.input_blocker.visible
		):
			break
	_check(
		live_handle != null
		and live_target != null
		and live_battle.input_blocker.visible,
		"Live presentation did not expose a clickable target behind its blocker",
	)
	if live_target != null and live_battle.input_blocker != null:
		var live_point := live_target.global_center()
		Input.warp_mouse(live_point)
		var live_press := InputEventMouseButton.new()
		live_press.button_index = MOUSE_BUTTON_LEFT
		live_press.pressed = true
		live_press.position = live_point
		live_press.global_position = live_point
		root.push_input(live_press, true)
		await process_frame
		var live_detail := live_battle.detail_panel as BattleDetailPanel
		_check(
			live_detail != null
			and live_detail.visible
			and live_detail.current_card_id == live_target.card_id,
			"Real GUI pointer dispatch did not open detail during live presentation: "
			+ "hovered=%s point=%s blocker=%s rect=%s target=%s target_rect=%s" % [
				root.gui_get_hovered_control(),
				live_point,
				live_battle.input_blocker.visible,
				live_battle.input_blocker.get_global_rect(),
				live_target,
				live_target.visual_global_bounds(),
			],
		)
		var live_release := InputEventMouseButton.new()
		live_release.button_index = MOUSE_BUTTON_LEFT
		live_release.pressed = false
		live_release.position = live_point
		live_release.global_position = live_point
		root.push_input(live_release, true)
		live_battle.hide_card_detail()
	if live_handle != null and not bool(live_handle.call("is_completed")):
		await live_handle.completed
	for kind in ["attach_energy", "evolve", "attack", "damage", "ko"]:
		_stage = "atomic_%s" % kind
		var handle: Variant = workbench.call("trigger_presentation", kind)
		_check(handle != null, "%s fixture did not return a PresentationHandle" % kind)
		if handle != null and not bool(handle.call("is_completed")):
			await handle.completed
		checkpoint = workbench.call("get_presentation_checkpoint")
		final_view = checkpoint.get("after_view")
		target_state = final_view.call("state_for_render")
		rendered_state = workbench.current_battle.state_ref
		_check(
			handle != null
			and str(handle.get("status")) == "completed"
			and rendered_state.revision == target_state.revision,
			"%s fixture did not complete its atomic transition" % kind,
		)
	_stage = "shuffle_proxy_count"
	var battle: BattleTable = workbench.current_battle
	var deck_zone := battle.call("_zone_view_for_endpoint", {
		"player": battle.view_player,
		"zone": "deck",
	}) as ZoneView
	_check(deck_zone != null, "Shuffle proxy contract could not resolve the deck zone")
	if deck_zone != null:
		battle.call("_clear_active_flyers")
		deck_zone.configure("牌库", "", 0, true)
		var empty_spawned := bool(battle.call(
			"_spawn_shuffle_motion",
			{"player": battle.view_player, "zone": "deck"},
			1.2,
			"",
		))
		_check(
			not empty_spawned and battle._active_flyers.is_empty(),
			"Empty deck shuffle created a phantom packet of cards",
		)
		deck_zone.configure("牌库", "", 1, true)
		var single_spawned := bool(battle.call(
			"_spawn_shuffle_motion",
			{"player": battle.view_player, "zone": "deck"},
			1.2,
			"",
		))
		_check(
			single_spawned and battle._active_flyers.size() == 1,
			"One-card deck shuffle did not cap its proxy count to one",
		)
		battle.call("_clear_active_flyers")
	workbench.queue_free()
	await process_frame
	_finish()


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	push_error(message)


func _check_motion_card_faces(
	battle: BattleTable,
	context: String,
	expected_card_id: String = "",
) -> void:
	_check(battle != null, "%s has no BattleTable" % context)
	if battle == null:
		return
	var paper_flyers := 0
	for value in battle._active_flyers:
		var flyer := value as Control
		if flyer == null or not bool(flyer.get_meta("paper_card_token", false)):
			continue
		paper_flyers += 1
		var image := flyer.get_node_or_null("PaperImage") as TextureRect
		_check(image != null, "%s flyer has no PaperImage" % context)
		if image == null:
			continue
		_check(image.texture != null, "%s flyer lost its card texture" % context)
		if not expected_card_id.is_empty():
			_check(
				str(flyer.get_meta("motion_card_id", "")) == expected_card_id,
				"%s flyer lost its card identity" % context,
			)
			var expected_texture: Texture2D = battle.call(
				"_public_motion_texture_for_card_id",
				expected_card_id,
			)
			var back_texture: Texture2D = battle.call(
				"_texture_for_card_id",
				"",
			)
			_check(
				expected_texture != null
				and image.texture in [expected_texture, back_texture],
				"%s flyer rendered neither the expected face nor card back" % context,
			)
		_check(
			image.visible
			and image.modulate.a > 0.99
			and image.size.x >= 1.0
			and image.size.y >= 1.0,
			"%s flyer image became invisible or collapsed" % context,
		)
	_check(paper_flyers > 0, "%s created no paper-card flyer" % context)


func _check_identical_slot_swap_motion(
	battle: BattleTable,
	context: String,
) -> void:
	_check(battle != null, "%s has no BattleTable" % context)
	if battle == null:
		return
	var routes: Dictionary = {}
	var mover_count := 0
	var progressed_count := 0
	for value in battle._active_flyers:
		var mover := value as CardView
		if (
			mover == null
			or not bool(mover.get_meta("slot_composite_motion", false))
		):
			continue
		mover_count += 1
		var from_slot := str(mover.get_meta("slot_composite_from", ""))
		var to_slot := str(mover.get_meta("slot_composite_to", ""))
		routes["%s->%s" % [from_slot, to_slot]] = true
		_check(
			mover.visible
			and mover.modulate.a > 0.99
			and mover.pokemon != null
			and mover.pokemon.card_id == "svi-chim",
			"%s lost one identical Pokemon face in flight" % context,
		)
		var start: Vector2 = mover.get_meta("motion_start", Vector2.ZERO)
		var finish: Vector2 = mover.get_meta("motion_finish", Vector2.ZERO)
		var center := mover.position + mover.size * 0.5
		if (
			center.distance_to(start) > 1.0
			and center.distance_to(finish) > 1.0
		):
			progressed_count += 1
	_check(
		mover_count == 2
		and routes.has("active->bench_0")
		and routes.has("bench_0->active")
		and progressed_count >= 1,
		"%s did not create both directions of the slot exchange" % context,
	)


func _check_presentation_inspection_hit(
	battle: BattleTable,
	visible_card: CardView,
	context: String,
) -> void:
	_check(battle != null and visible_card != null, "%s has no visible CardView" % context)
	if battle == null or visible_card == null:
		return
	var blocker := battle.input_blocker
	var point := visible_card.global_center()
	var resolved := battle.call(
		"_public_field_card_at",
		point,
		BattleTable.PRESENTATION_INSPECTION_MOUSE_MARGIN,
	) as CardView
	_check(
		blocker != null
		and blocker.visible
		and resolved != null
		and resolved.card_id == visible_card.card_id,
		"%s was not resolved through the real presentation hit map" % context,
	)
	if blocker == null:
		return
	var local_point := blocker.get_global_transform_with_canvas().affine_inverse() * point
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = local_point
	blocker.gui_input.emit(press)
	var detail := battle.detail_panel as BattleDetailPanel
	_check(
		detail != null
		and detail.visible
		and detail.current_card_id == visible_card.card_id,
		"%s did not open detail immediately on pointer press" % context,
	)
	battle.hide_card_detail()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	if _settings != null:
		_settings.set("animation_mode", _previous_animation_mode)
		_settings.set("reduced_motion", _previous_reduced_motion)
	if _failed:
		quit(1)
		return
	print("UI_WORKBENCH_TRANSITION_OK")
	quit(0)
