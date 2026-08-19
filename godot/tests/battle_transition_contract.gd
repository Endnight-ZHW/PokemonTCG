extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var settings := root.get_node_or_null("AppSettings")
	var previous_mode := str(settings.get("animation_mode"))
	var previous_reduced := bool(settings.get("reduced_motion"))
	var previous_quality := str(settings.get("quality_profile"))
	settings.set("animation_mode", "cinematic")
	settings.set("reduced_motion", false)

	var battle_scene := load("res://scenes/battle/components/battle_table.tscn") as PackedScene
	var battle := battle_scene.instantiate()
	root.add_child(battle)
	battle.initialize_ui()
	await process_frame
	await process_frame

	var before := UIPreviewStateFactory.battle_state(20260714)
	before.revision = 20
	before.players[0].hand = ["sv1-104", "sv1-ener-5"]
	before.players[0].deck = ["sv1-151"]
	var empty_rows: Array[Dictionary] = []
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	var old_positions: Array[Vector2] = [
		battle.hand_views[0].position,
		battle.hand_views[1].position,
	]

	var after := before.clone_state()
	after.revision = 21
	after.players[0].deck.clear()
	after.players[0].hand.append("sv1-151")
	var event := {
		"event_type": "cards_drawn",
		"actor": 0,
		"card_id": "sv1-151",
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "hand"},
		"amount": 1,
		"data": {"player": 0, "count": 1, "card_ids": ["sv1-151"]},
	}
	var target_view := BattleViewModel.capture(
		after, 0, empty_rows, "", false, "test")
	var request := BattleTransitionRequest.create(
		target_view,
		[event],
		0,
		BattleTransitionRequest.CAUSE_LOCAL_ACTION,
	)
	var handle: RefCounted = battle.submit_transition(request)
	_expect(
		battle.input_blocker.visible,
		"critical transition did not block table input on its submit frame",
	)
	await process_frame
	await process_frame
	_expect(not handle.is_completed(), "draw transition completed before its real motion")
	_expect(
		battle.hand_views.size() == 3
		and battle.hand_views[2].is_presentation_hidden(),
		"incoming hand anchor was not hidden while the card was in flight",
	)
	_expect(
		battle.hand_views[0].position.distance_to(old_positions[0]) < 0.5
		and battle.hand_views[1].position.distance_to(old_positions[1]) < 0.5,
		"existing hand cards reserved the draw slot before contact",
	)
	_expect(
		_count_motion_entities(battle) == 1,
		"draw start did not contain exactly one flying card face",
	)
	var draw_motion_entities := _motion_entities(battle)
	var draw_image := (
		draw_motion_entities[0].get_node_or_null("PaperImage") as TextureRect
		if not draw_motion_entities.is_empty()
		else null
	)
	_expect(
		not draw_motion_entities.is_empty()
		and _maximum_visible_canvas_z(draw_motion_entities[0])
		< _effective_canvas_z(battle.world_feedback)
		and _effective_canvas_z(battle.world_feedback)
		< _effective_canvas_z(battle.hud),
		"world feedback can still be covered by an in-flight card",
	)
	_expect(
		draw_image != null
		and draw_image.texture == battle._texture_for_card_id(""),
		"local deck draw did not start with the physical card back",
	)

	await create_timer(0.27).timeout
	_expect(
		draw_image != null
		and draw_image.texture == battle._texture_for_card_id("sv1-151"),
		"hidden-to-public draw did not flip to its face during flight",
	)
	_expect(
		battle.hand_views[0].position.distance_to(old_positions[0]) > 1.0
		or battle.hand_views[1].position.distance_to(old_positions[1]) > 1.0,
		"incoming card did not push the existing hand after contact",
	)
	var staged_count_before_resize: int = battle._presentation_hand_stage_count
	battle.board_canvas.size.x = maxf(640.0, battle.board_canvas.size.x - 48.0)
	battle._layout_board()
	_expect(
		battle._presentation_hand_stage_count == staged_count_before_resize
		and battle.hand_views[2].is_presentation_hidden(),
		"resize bypassed the active hand staging transaction",
	)
	_expect(
		battle._hand_layout_motion_handles.is_empty(),
		"resize left a pre-resize hand tween writing stale coordinates",
	)
	_expect(
		not battle._hand_transition_sequences.is_empty(),
		"draw reflow/landing was not registered in the event MotionGroup",
	)

	await _wait_for_handle(handle, battle)
	_expect(handle.status == PresentationHandle.COMPLETED, "draw handle did not complete")
	_expect(not battle.input_blocker.visible, "critical blocker remained after completion")
	_expect(
		battle.hand_views.size() == 3
		and battle.hand_views[2].card_id == "sv1-151"
		and not battle.hand_views[2].is_presentation_hidden(),
		"draw landing did not hand off to the real hand node",
	)
	_expect(_count_motion_entities(battle) == 0, "draw left a motion proxy behind")

	await _run_multi_draw_contract(battle, empty_rows)
	await _run_professor_snapshot_proxy_contract(battle, empty_rows)
	await _run_caitlin_full_hand_batch_contract(battle, empty_rows, settings)
	await _run_opponent_judge_hand_contract(battle, empty_rows)
	await _run_hidden_opponent_draw_contract(battle, empty_rows)
	await _run_queued_revision_contract(battle, empty_rows)
	await _run_reduced_transition_contract(battle, empty_rows, settings)
	await _run_feedback_layer_contract(battle, empty_rows)
	await _run_local_drag_success_contract(battle, empty_rows)
	await _run_bench_search_anchor_contract(battle, empty_rows)
	await _run_cards_selected_hand_contract(battle, empty_rows)
	await _run_attachment_motion_contract(battle, empty_rows)
	await _run_tool_attachment_landing_contract(battle, empty_rows)
	await _run_attachment_batch_anchor_contract(battle, empty_rows)
	await _run_slot_visual_transaction_contract(battle, empty_rows)
	await _run_prize_stack_transaction_contract(battle, empty_rows)
	await _run_public_coin_contract(battle)
	await _run_empty_public_reveal_contract(battle, settings)
	await _run_public_reveal_damage_sequence_contract(battle, empty_rows, settings)
	await _run_startup_shuffle_contract(battle)
	await _run_preflight_and_event_cleanup_contract(battle, empty_rows)

	battle._on_hand_drag_started(0)
	await process_frame
	var drag_context: Dictionary = battle.active_drag_context()
	_expect(not drag_context.is_empty(), "drag session was not created")
	_expect(
		battle.hand_views[0].is_drag_masked()
		and not battle.hand_views[0].content_root.visible
		and battle._drag_session.proxy != null,
		"drag displayed both the source card and proxy",
	)
	var drag_proxy := battle._drag_session.proxy as Control
	_expect(
		_is_full_face_motion_token(drag_proxy),
		"drag proxy still rendered a paper edge, filled shadow, or white frame",
	)
	_expect(
		_maximum_visible_canvas_z(drag_proxy)
		< _effective_canvas_z(battle.world_feedback),
		"world feedback can still be covered by the drag card proxy",
	)
	var session_id: String = battle.mark_drag_pending("contract:drag", true)
	battle._on_hand_drag_ended()
	await process_frame
	_expect(
		battle.active_drag_context().get("session_id", "") == session_id,
		"native drag end destroyed a pending authority proxy",
	)
	var pending_proxy_id: int = battle._drag_session.proxy.get_instance_id()
	var secondary_index := 1 if battle.hand_views.size() > 1 else 0
	battle._on_hand_drag_started(secondary_index)
	await process_frame
	_expect(
		battle.active_drag_context().get("session_id", "") == session_id
		and battle._drag_session.proxy.get_instance_id() == pending_proxy_id
		and battle.hand_views[0].is_drag_masked()
		and (
			secondary_index == 0
			or not battle.hand_views[secondary_index].is_drag_masked()
		),
		"pending authority drag allowed a second card/proxy transaction",
	)
	battle.clear_pending_drag("contract_cancel")
	await _wait_for_drag_idle(battle)
	_expect(
		not battle.hand_views[0].is_drag_masked()
		and battle.active_drag_context().is_empty(),
		"cancelled drag did not return ownership to the real card",
	)

	battle._on_hand_drag_started(0)
	await process_frame
	battle.mark_drag_pending("contract:resync", true)
	battle.world_feedback.floating_text(
		"resync feedback",
		Vector2(80.0, 80.0),
		Color.WHITE,
	)
	battle.world_feedback.burst(Vector2(80.0, 80.0), Color.WHITE, "impact")
	battle.announcement_layer.show_announcement(
		"resync announcement",
		DesignTokens.BLUE,
		false,
	)
	battle.cancel_presentations("contract_resync")
	_expect(
		battle.active_drag_context().is_empty()
		and not battle.hand_views[0].is_drag_masked()
		and _count_motion_entities(battle) == 0
		and _feedback_layers_are_clear(battle),
		"resync cancellation left a proxy, world feedback, or announcement behind",
	)
	await process_frame
	await process_frame
	_expect(
		_feedback_layers_are_clear(battle),
		"a killed feedback tween recreated visuals after resync cleanup",
	)

	await _run_drag_identity_contract(battle, empty_rows)
	await _run_dense_hand_hover_order_contract(battle, empty_rows)

	battle.queue_free()
	await process_frame
	await process_frame
	await _run_local_handoff_contract()
	await _run_main_shell_flow_contract()
	# Let queue_free, killed Tween callbacks and their one-shot MotionHandle
	# connections drain before the SceneTree exits; otherwise very fast headless
	# runs can report the two just-cancelled feedback handles as ObjectDB leaks.
	for _frame in range(8):
		await process_frame
	settings.set("animation_mode", previous_mode)
	settings.set("reduced_motion", previous_reduced)
	settings.set("quality_profile", previous_quality)
	if failures.is_empty():
		print("BATTLE_TRANSITION_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_dense_hand_hover_order_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var previous_window_size := root.size
	var hand_card_ids: Array[String] = [
		"sv1-104",
		"sv1-106",
		"sv1-108",
		"sv2-delib",
		"sv1-151",
		"svf-potion",
		"sv1-189",
		"svi-jete",
		"svi-dtur",
		"svi-hrot",
		"sv1-ener-1",
		"sv1-ener-2",
		"sv1-ener-3",
		"sv1-ener-4",
		"sv1-ener-5",
	]
	var viewport_sizes: Array[Vector2i] = [
		Vector2i(900, 540),
		Vector2i(1280, 720),
		Vector2i(1600, 900),
	]
	var fixture_index := 0
	for viewport_size in viewport_sizes:
		root.size = viewport_size
		for _frame in range(4):
			await process_frame
		for hand_count in [10, 15]:
			fixture_index += 1
			var fixture_label := "%d cards at %dx%d" % [
				hand_count,
				viewport_size.x,
				viewport_size.y,
			]
			var dense_state := UIPreviewStateFactory.battle_state(
				20260810 + fixture_index,
			)
			dense_state.revision = 200 + fixture_index
			dense_state.players[0].hand.clear()
			for card_index in range(hand_count):
				dense_state.players[0].hand.append(
					hand_card_ids[card_index % hand_card_ids.size()],
				)
			battle.update_view(
				dense_state,
				0,
				empty_rows,
				"",
				false,
				"test",
			)
			battle._layout_board()
			for _frame in range(4):
				await process_frame
			_expect(
				battle.hand_views.size() >= hand_count,
				"Dense-hand fixture did not create %s" % fixture_label,
			)
			if battle.hand_views.size() < hand_count:
				continue
			# Exercise a user-owned scroll position whenever this fan overflows. The
			# hover contract must not silently snap it back to the layout center.
			var horizontal_bar := (
				battle.hand_scroll.get_h_scroll_bar() as HScrollBar
			)
			var maximum_scroll := maxi(
				0,
				roundi(horizontal_bar.max_value - horizontal_bar.page),
			)
			if maximum_scroll > 4:
				battle.hand_scroll.scroll_horizontal = maxi(
					1,
					roundi(float(maximum_scroll) * 0.27),
				)
				await process_frame

			var middle_index := floori(float(hand_count) * 0.5)
			var middle_view := _visible_hand_view_at_index(battle, middle_index)
			var middle_right := _visible_hand_view_at_index(
				battle,
				middle_index + 1,
			)
			var base_geometry := _dense_hand_geometry_snapshot(battle, hand_count)
			var base_order := _dense_hand_order_snapshot(battle, hand_count)
			middle_view._on_mouse_entered()
			await process_frame
			_expect(
				_dense_hand_geometry_matches(battle, hand_count, base_geometry),
				"Hover changed hand positions, content width, or scroll for %s"
				% fixture_label,
			)
			_expect(
				_dense_hand_order_snapshot(battle, hand_count) == base_order
				and _dense_hand_is_canonical(battle, hand_count)
				and _hand_view_draws_above(middle_right, middle_view),
				"Middle hover raised a card above its right neighbor for %s"
				% fixture_label,
			)
			_expect(
				_card_hover_target_is_active(middle_view),
				"Middle hover lost its lift/scale feedback for %s" % fixture_label,
			)

			middle_view._on_mouse_exited()
			var switched_index := maxi(0, middle_index - 1)
			var switched_view := _visible_hand_view_at_index(
				battle,
				switched_index,
			)
			switched_view._on_mouse_entered()
			await process_frame
			_expect(
				_dense_hand_order_snapshot(battle, hand_count) == base_order
				and _dense_hand_geometry_matches(
					battle,
					hand_count,
					base_geometry,
				),
				"Switching hover changed canonical hand geometry/order for %s"
				% fixture_label,
			)
			switched_view._on_mouse_exited()

			var last_view := _visible_hand_view_at_index(battle, hand_count - 1)
			last_view._on_mouse_entered()
			await process_frame
			_expect(
				_dense_hand_order_snapshot(battle, hand_count) == base_order
				and _dense_hand_geometry_matches(
					battle,
					hand_count,
					base_geometry,
				)
				and _card_hover_target_is_active(last_view),
				"Last-card hover changed the fan contract for %s" % fixture_label,
			)
			last_view._on_mouse_exited()
			await process_frame
			_expect(
				_dense_hand_order_snapshot(battle, hand_count) == base_order
				and _dense_hand_is_canonical(battle, hand_count),
				"Hover exit did not preserve canonical order for %s" % fixture_label,
			)

			battle.update_view(
				dense_state,
				0,
				empty_rows,
				"hand:%d" % middle_index,
				false,
				"test",
			)
			for _frame in range(2):
				await process_frame
			var selected_view := _visible_hand_view_at_index(battle, middle_index)
			var selected_geometry := _dense_hand_geometry_snapshot(
				battle,
				hand_count,
			)
			var selected_order := _dense_hand_order_snapshot(battle, hand_count)
			var hover_while_selected := _visible_hand_view_at_index(
				battle,
				mini(hand_count - 1, middle_index + 1),
			)
			hover_while_selected._on_mouse_entered()
			await process_frame
			_expect(
				_selected_hand_is_topmost(battle, hand_count, selected_view)
				and _dense_hand_order_snapshot(battle, hand_count) == selected_order,
				"Hover displaced the selected top card for %s" % fixture_label,
			)
			_expect(
				_dense_hand_geometry_matches(
					battle,
					hand_count,
					selected_geometry,
				),
				"Hover changed selected-hand positions or scroll for %s"
				% fixture_label,
			)
			hover_while_selected._on_mouse_exited()
			selected_view._on_mouse_entered()
			await process_frame
			_expect(
				_selected_hand_is_topmost(battle, hand_count, selected_view)
				and _dense_hand_order_snapshot(battle, hand_count) == selected_order
				and _card_hover_target_is_active(selected_view),
				"Selected+hover did not retain the selected top layer for %s"
				% fixture_label,
			)
			selected_view._on_mouse_exited()
			battle.update_view(
				dense_state,
				0,
				empty_rows,
				"",
				false,
				"test",
			)
			for _frame in range(2):
				await process_frame
			_expect(
				_dense_hand_is_canonical(battle, hand_count),
				"Clearing selection did not restore canonical order for %s"
				% fixture_label,
			)

	root.size = previous_window_size
	for _frame in range(4):
		await process_frame
	battle._layout_board()
	await process_frame


func _run_multi_draw_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260715)
	before.revision = 30
	before.players[0].hand = ["sv1-104", "sv1-ener-5"]
	before.players[0].deck = ["sv1-104", "sv1-151", "sv1-104"]
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var old_positions: Array[Vector2] = [
		battle.hand_views[0].position,
		battle.hand_views[1].position,
	]
	var preserved_visual_id: String = battle.hand_views[0].local_visual_id

	var after := before.clone_state()
	after.revision = 31
	after.players[0].deck.clear()
	after.players[0].hand.append_array([
		"sv1-104",
		"sv1-151",
		"sv1-104",
	])
	var event := _draw_event(0, ["sv1-104", "sv1-151", "sv1-104"])
	var target_view := BattleViewModel.capture(
		after, 0, empty_rows, "", false, "test")
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			target_view,
			[event],
			0,
			BattleTransitionRequest.CAUSE_LOCAL_ACTION,
		)
	)
	await process_frame
	await process_frame
	_expect(
		battle._presentation_hand_stage_count == 2,
		"multi-draw reserved incoming hand slots before contact",
	)
	_expect(
		battle.hand_views[0].position.distance_to(old_positions[0]) < 0.5
		and battle.hand_views[1].position.distance_to(old_positions[1]) < 0.5,
		"multi-draw moved the old hand before contact",
	)
	_expect(
		_count_motion_entities(battle) == 3,
		"multi-draw did not create exactly three staggered motion entities",
	)
	var all_incoming_hidden: bool = battle.hand_views.size() >= 5
	for index in range(2, mini(5, battle.hand_views.size())):
		all_incoming_hidden = (
			all_incoming_hidden
			and battle.hand_views[index].is_presentation_hidden()
		)
	_expect(all_incoming_hidden, "multi-draw exposed an incoming real hand node")

	var first_wait_frames := await _wait_for_hand_stage_count(battle, 3)
	_expect(
		first_wait_frames >= 0
		and battle._presentation_hand_stage_count == 3,
		"multi-draw did not insert only its first anchor at contact",
	)
	await process_frame
	_expect(
		battle._presentation_hand_stage_count == 3,
		"multi-draw inserted its second anchor without the configured stagger",
	)
	_expect(
		battle.hand_views[0].position.distance_to(old_positions[0]) > 1.0
		or battle.hand_views[1].position.distance_to(old_positions[1]) > 1.0,
		"first multi-draw anchor did not push the old hand",
	)
	var second_wait_frames := await _wait_for_hand_stage_count(battle, 4)
	_expect(
		second_wait_frames >= 2
		and battle._presentation_hand_stage_count == 4,
		"multi-draw second anchor was not inserted as a distinct staggered step",
	)
	await process_frame
	_expect(
		battle._presentation_hand_stage_count == 4,
		"multi-draw inserted its third anchor without the configured stagger",
	)
	var third_wait_frames := await _wait_for_hand_stage_count(battle, 5)
	_expect(
		third_wait_frames >= 2
		and battle._presentation_hand_stage_count == 5,
		"multi-draw third anchor was not inserted as a distinct staggered step",
	)
	var first_landing_handed_off := false
	for _frame in range(120):
		if (
			battle.hand_views.size() >= 3
			and not battle.hand_views[2].is_presentation_hidden()
		):
			first_landing_handed_off = true
			break
		await process_frame
	var stale_completed_flyer_visible := false
	for flyer_value in battle._active_flyers:
		var flyer := flyer_value as Control
		if (
			flyer != null
			and bool(flyer.get_meta("motion_completed", false))
			and flyer.visible
		):
			stale_completed_flyer_visible = true
			break
	_expect(
		first_landing_handed_off and not stale_completed_flyer_visible,
		"multi-draw kept an early landing flyer over the reflowing real hand card",
	)

	await _wait_for_handle(handle, battle)
	_expect(handle.status == PresentationHandle.COMPLETED, "multi-draw handle failed")
	_expect(
		_count_motion_entities(battle) == 0,
		"multi-draw left a motion proxy after its real nodes took ownership",
	)
	var visible_ids: Dictionary = {}
	var duplicate_count := 0
	var real_hand_is_complete: bool = battle.hand_views.size() >= 5
	for index in range(mini(5, battle.hand_views.size())):
		var view: CardView = battle.hand_views[index]
		real_hand_is_complete = (
			real_hand_is_complete
			and view.visible
			and not view.is_presentation_hidden()
			and not view.local_visual_id.is_empty()
			and not visible_ids.has(view.local_visual_id)
		)
		visible_ids[view.local_visual_id] = true
		if view.card_id == "sv1-104":
			duplicate_count += 1
	_expect(
		real_hand_is_complete
		and duplicate_count == 3
		and battle.hand_views[0].local_visual_id == preserved_visual_id,
		"multi-draw did not preserve old identity while assigning unique duplicate IDs",
	)


func _run_professor_snapshot_proxy_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260719)
	before.revision = 70
	before.players[0].hand = ["sv1-104", "sv1-189", "svf-potion"]
	before.players[0].deck = [
		"sv1-ener-1",
		"sv1-ener-2",
		"sv1-ener-3",
		"sv1-ener-4",
		"sv1-ener-5",
		"sv1-ener-6",
		"sv1-ener-7",
	]
	before.players[0].discard.clear()
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame

	var drawn_ids: Array[String] = before.players[0].deck.duplicate()
	var after := before.clone_state()
	after.revision = 71
	after.players[0].hand = drawn_ids.duplicate()
	after.players[0].deck.clear()
	after.players[0].discard = ["sv1-189", "sv1-104", "svf-potion"]
	var trainer_event_id := "contract:professor:trainer"
	var discard_event_id := "contract:professor:discard"
	var draw_event_id := "contract:professor:draw"
	var events: Array[Dictionary] = [
		{
			"event_id": trainer_event_id,
			"event_type": "trainer_played",
			"actor": 0,
			"card_id": "sv1-189",
			"source": {"player": 0, "zone": "hand", "index": 1},
			"target": {"player": 0, "zone": "discard"},
			"amount": 1,
			"data": {
				"player": 0,
				"card_id": "sv1-189",
				"source_indices": [1],
			},
		},
		{
			"event_id": discard_event_id,
			"event_type": "cards_discarded",
			"actor": 0,
			"source": {"player": 0, "zone": "hand", "index": 0},
			"target": {"player": 0, "zone": "discard"},
			"amount": 2,
			"data": {
				"player": 0,
				"count": 2,
				"card_ids": ["sv1-104", "svf-potion"],
				# Relative to the hand after the middle-index Supporter has left it.
				"source_indices": [0, 1],
			},
		},
		{
			"event_id": draw_event_id,
			"event_type": "cards_drawn",
			"actor": 0,
			"source": {"player": 0, "zone": "deck"},
			"target": {"player": 0, "zone": "hand"},
			"amount": drawn_ids.size(),
			"visibility": "owner",
			"data": {
				"player": 0,
				"count": drawn_ids.size(),
				"card_ids": drawn_ids.duplicate(),
			},
		},
	]
	var started_types: Array[String] = []
	var started_callback := func(event: Dictionary) -> void:
		started_types.append(str(event.get("event_type", "")))
	battle.director.event_started.connect(started_callback)
	var target_view := BattleViewModel.capture(
		after, 0, empty_rows, "", false, "test")
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			target_view,
			events,
			0,
			BattleTransitionRequest.CAUSE_LOCAL_ACTION,
		)
	)

	await _wait_for_director_event(started_types, "trainer_played")
	var trainer_keys: Array = battle._presentation_event_hand_sources.get(
		trainer_event_id,
		[],
	)
	var discard_keys: Array = battle._presentation_event_hand_sources.get(
		discard_event_id,
		[],
	)
	_expect(
		trainer_keys == ["snapshot:1"]
		and discard_keys == ["snapshot:0", "snapshot:2"],
		"Professor snapshot sources did not consume middle-index occurrences in order: trainer=%s discard=%s"
		% [str(trainer_keys), str(discard_keys)],
	)
	var remaining_proxy_keys := _snapshot_proxy_keys(
		battle._presentation_hand_source_proxies)
	var active_trainer_keys := _snapshot_proxy_keys(battle._active_flyers)
	var trainer_motion_is_full_face := false
	for flyer_value in battle._active_flyers:
		var flyer := flyer_value as Control
		if flyer != null and str(flyer.get_meta("snapshot_hand_key", "")) == "snapshot:1":
			trainer_motion_is_full_face = _is_full_face_motion_token(flyer)
			break
	_expect(
		remaining_proxy_keys == ["snapshot:0", "snapshot:2"]
		and active_trainer_keys == ["snapshot:1"]
		and trainer_motion_is_full_face,
		"Professor flight hid or consumed the other old hand proxies: remaining=%s active=%s"
		% [str(remaining_proxy_keys), str(active_trainer_keys)],
	)
	for proxy in battle._presentation_hand_source_proxies:
		_expect(
			proxy != null and is_instance_valid(proxy) and proxy.visible,
			"An old hand proxy was not visible while Professor's Research was in flight",
		)

	await _wait_for_director_event(started_types, "cards_discarded")
	var active_discard_keys := _snapshot_proxy_keys(battle._active_flyers)
	_expect(
		battle._presentation_hand_source_proxies.is_empty()
		and active_discard_keys == ["snapshot:0", "snapshot:2"],
		"Remaining hand proxies were not consumed by the later discard event: %s"
		% str(active_discard_keys),
	)
	await _wait_for_handle(handle, battle)
	_expect(
		handle.status == PresentationHandle.COMPLETED
		and battle._presentation_hand_source_proxies.is_empty()
		and battle._presentation_hand_proxy_by_key.is_empty()
		and battle.effects.find_children(
			"SnapshotHandProxy", "", true, false).is_empty(),
		"Professor transition left a snapshot hand proxy behind",
	)
	if battle.director.event_started.is_connected(started_callback):
		battle.director.event_started.disconnect(started_callback)


func _run_opponent_judge_hand_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260722)
	before.revision = 72
	before.players[1].hand = [
		"sv1-104",
		"sv1-176",
		"sv1-151",
		"svf-potion",
	]
	before.players[1].deck = [
		"sv1-ener-1",
		"sv1-ener-2",
		"sv1-ener-3",
		"sv1-ener-4",
		"sv1-ener-5",
		"sv1-ener-6",
	]
	before.players[1].discard.clear()
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var original_centers: Array[Vector2] = []
	for view_value in battle.opponent_hand_views:
		var view := view_value as CardView
		if view != null and view.visible:
			original_centers.append(battle._effects_local(view.global_center()))

	var after := before.clone_state()
	after.revision = 73
	after.players[1].hand = [
		"sv1-ener-1",
		"sv1-ener-2",
		"sv1-ener-3",
		"sv1-ener-4",
	]
	after.players[1].deck = [
		"sv1-104",
		"sv1-151",
		"svf-potion",
		"sv1-ener-5",
		"sv1-ener-6",
	]
	after.players[1].discard = ["sv1-176"]
	var trainer_event_id := "contract:judge:trainer"
	var return_event_id := "contract:judge:return"
	var events: Array[Dictionary] = [
		{
			"event_id": trainer_event_id,
			"event_type": "trainer_played",
			"actor": 1,
			"card_id": "sv1-176",
			"source": {"player": 1, "zone": "hand", "index": 1},
			"target": {"player": 1, "zone": "discard"},
			"amount": 1,
			"data": {
				"player": 1,
				"card_id": "sv1-176",
				"source_indices": [1],
			},
		},
		{
			"event_id": return_event_id,
			"event_type": "card_moved",
			"actor": 1,
			"visibility": "owner",
			"source": {"player": 1, "zone": "hand"},
			"target": {"player": 1, "zone": "deck"},
			"amount": 3,
			"data": {
				"player": 1,
				"count": 3,
				"source_indices": [0, 1, 2],
			},
		},
		{
			"event_id": "contract:judge:shuffle",
			"event_type": "deck_shuffled",
			"actor": 1,
			"source": {"player": 1, "zone": "deck"},
			"target": {"player": 1, "zone": "deck"},
			"data": {"player": 1},
		},
		{
			"event_id": "contract:judge:draw",
			"event_type": "cards_drawn",
			"actor": 1,
			"visibility": "owner",
			"source": {"player": 1, "zone": "deck"},
			"target": {"player": 1, "zone": "hand"},
			"amount": 4,
			"data": {"player": 1, "count": 4, "card_ids": []},
		},
	]
	var started_ids: Array[String] = []
	var started_callback := func(event: Dictionary) -> void:
		started_ids.append(str(event.get("event_id", "")))
	battle.director.event_started.connect(started_callback)
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			BattleViewModel.capture(
				after, 0, empty_rows, "", false, "test"),
			events,
			1,
			BattleTransitionRequest.CAUSE_NETWORK,
		)
	)
	await _wait_for_director_event(started_ids, trainer_event_id)
	await process_frame
	var stationary_sources_are_exact := original_centers.size() == 4
	for proxy_value in battle._presentation_opponent_hand_proxies:
		var proxy := proxy_value as Control
		var original_index := int(proxy.get_meta(
			"snapshot_opponent_hand_index",
			-1,
		)) if proxy != null else -1
		stationary_sources_are_exact = (
			stationary_sources_are_exact
			and original_index >= 0
			and original_index < original_centers.size()
			and (proxy.position + proxy.size * 0.5).distance_to(
				original_centers[original_index]) < 0.5
			and not battle._hand_layout_motion_handles.has(
				proxy.get_instance_id())
		)
	_expect(
		stationary_sources_are_exact
		and battle._presentation_opponent_hand_proxies.size() == 3,
		"Judge moved the opponent's remaining hand before its return-to-deck event",
	)
	await _wait_for_director_event(started_ids, return_event_id)
	await process_frame
	var outgoing_sources := 0
	var outgoing_sources_are_exact := original_centers.size() == 4
	for flyer_value in battle._active_flyers:
		var flyer := flyer_value as Control
		if flyer == null or str(flyer.get_meta("motion_event_id", "")) != return_event_id:
			continue
		outgoing_sources += 1
		var original_index := int(flyer.get_meta(
			"snapshot_opponent_hand_index",
			-1,
		))
		outgoing_sources_are_exact = (
			outgoing_sources_are_exact
			and original_index >= 0
			and original_index < original_centers.size()
			and (flyer.get_meta("motion_start") as Vector2).distance_to(
				original_centers[original_index]) < 0.5
		)
	_expect(
		outgoing_sources == 3 and outgoing_sources_are_exact,
		"Judge return-to-deck motion did not continue from the unmoved opponent hand poses",
	)
	await _wait_for_handle(handle, battle)
	_expect(
		handle.status == PresentationHandle.COMPLETED
		and battle.opponent_hand_views.size() >= 4,
		"Judge opponent-hand replacement did not reconcile after its draw",
	)
	if battle.director.event_started.is_connected(started_callback):
		battle.director.event_started.disconnect(started_callback)


func _run_hidden_opponent_draw_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260716)
	before.revision = 40
	before.players[0].hand = ["sv1-ener-5"]
	before.players[1].hand = ["sv1-104"]
	before.players[1].deck = ["sv1-151"]
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var after := before.clone_state()
	after.revision = 41
	after.players[1].deck.clear()
	after.players[1].hand.append("sv1-151")
	var target_view := BattleViewModel.capture(
		after, 0, empty_rows, "", false, "test")
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			target_view,
			[_draw_event(1, ["sv1-151"])],
			1,
			BattleTransitionRequest.CAUSE_NETWORK,
		)
	)
	await process_frame
	await process_frame
	var entities: Array[Control] = _motion_entities(battle)
	_expect(entities.size() == 1, "opponent draw did not create one hidden proxy")
	if entities.size() == 1:
		var entity := entities[0] as Control
		var image := entity.get_node_or_null("PaperImage") as TextureRect
		var back_texture: Texture2D = battle._texture_for_card_id("")
		var front_texture: Texture2D = battle._texture_for_card_id("sv1-151")
		var metadata_leaked := false
		for meta_name in entity.get_meta_list():
			if str(entity.get_meta(meta_name)).contains("sv1-151"):
				metadata_leaked = true
				break
		_expect(
			image != null
			and image.texture == back_texture
			and (front_texture == back_texture or image.texture != front_texture)
			and not metadata_leaked
			and not str(entity.get("visual_id")).contains("sv1-151"),
			"opponent hidden draw proxy exposed its private card identity",
		)
	await _wait_for_handle(handle, battle)
	_expect(
		handle.status == PresentationHandle.COMPLETED
		and _count_motion_entities(battle) == 0
		and battle.opponent_hand_views.size() >= 2,
		"opponent hidden draw did not reconcile to hand backs",
	)


func _run_queued_revision_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260717)
	before.revision = 50
	before.players[0].hand = ["sv1-ener-5"]
	before.players[0].deck = ["sv1-151", "sv1-104"]
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var first_after := before.clone_state()
	first_after.revision = 51
	first_after.players[0].deck = ["sv1-104"]
	first_after.players[0].hand.append("sv1-151")
	var second_after := first_after.clone_state()
	second_after.revision = 52
	second_after.players[0].deck.clear()
	second_after.players[0].hand.append("sv1-104")
	var first_view := BattleViewModel.capture(
		first_after, 0, empty_rows, "", false, "test")
	var second_view := BattleViewModel.capture(
		second_after, 0, empty_rows, "", false, "test")
	var started_rows: Array[Dictionary] = []
	var completed_batches: Array[int] = []
	var started_callback := func(started_handle: PresentationHandle) -> void:
		started_rows.append({
			"batch_id": started_handle.batch_id,
			"revision_before_apply": (
				battle.state_ref.revision
				if battle.state_ref != null
				else -1
			),
		})
	battle.transition_started.connect(started_callback)
	var first_handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			first_view,
			[_draw_event(0, ["sv1-151"])],
			0,
			BattleTransitionRequest.CAUSE_LOCAL_ACTION,
		)
	)
	var second_handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			second_view,
			[_draw_event(0, ["sv1-104"])],
			0,
			BattleTransitionRequest.CAUSE_LOCAL_ACTION,
		)
	)
	first_handle.completed.connect(func(done: PresentationHandle) -> void:
		completed_batches.append(done.batch_id)
	)
	second_handle.completed.connect(func(done: PresentationHandle) -> void:
		completed_batches.append(done.batch_id)
	)
	# Mutating the authoritative fixtures after capture must not mutate either
	# queued immutable view.
	first_after.players[0].hand.clear()
	second_after.players[0].hand.clear()
	_expect(
		first_handle.status == PresentationHandle.QUEUED
		and second_handle.status == PresentationHandle.QUEUED,
		"queued revision handles did not begin in queued state",
	)
	await process_frame
	await process_frame
	_expect(
		first_handle.status == PresentationHandle.RUNNING
		and second_handle.status == PresentationHandle.QUEUED,
		"second revision began before the first revision completed",
	)
	await _wait_for_handle(first_handle, battle)
	_expect(
		first_handle.status == PresentationHandle.COMPLETED
		and not second_handle.is_completed(),
		"queued handles did not preserve completion order",
	)
	var second_started := await _wait_for_handle_status(
		second_handle, PresentationHandle.RUNNING)
	_expect(second_started, "second queued revision never began")
	var second_snapshot_hand: Array = battle._presentation_snapshot.get("hand", [])
	_expect(
		started_rows.size() == 2
		and int(started_rows[0].get("revision_before_apply", -1)) == 50
		and int(started_rows[1].get("revision_before_apply", -1)) == 51
		and second_snapshot_hand.size() == 2
		and battle.state_ref.revision == 52,
		"second revision did not own a snapshot of the first revision target",
	)
	await _wait_for_handle(second_handle, battle)
	_expect(
		completed_batches == [first_handle.batch_id, second_handle.batch_id]
		and battle.state_ref.revision == 52
		and battle.state_ref.players[0].hand.size() == 3
		and _count_motion_entities(battle) == 0,
		"queued revisions did not reconcile in batch order",
	)
	if battle.transition_started.is_connected(started_callback):
		battle.transition_started.disconnect(started_callback)


func _run_reduced_transition_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
	settings: Node,
) -> void:
	settings.set("animation_mode", "reduced")
	settings.set("reduced_motion", true)
	var before := UIPreviewStateFactory.battle_state(20260718)
	before.revision = 60
	before.players[0].hand = ["sv1-ener-5"]
	before.players[0].deck = ["sv1-151"]
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	var after := before.clone_state()
	after.revision = 61
	after.players[0].deck.clear()
	after.players[0].hand.append("sv1-151")
	var target_view := BattleViewModel.capture(
		after, 0, empty_rows, "", false, "test")
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			target_view,
			[_draw_event(0, ["sv1-151"])],
			0,
			BattleTransitionRequest.CAUSE_LOCAL_ACTION,
		)
	)
	var completion_probe := {"count": 0}
	handle.completed.connect(func(_done: PresentationHandle) -> void:
		completion_probe["count"] = int(completion_probe["count"]) + 1
	)
	_expect(
		not handle.is_completed()
		and battle.state_ref.revision == 60,
		"reduced transition completed synchronously before callers could connect",
	)
	await process_frame
	_expect(
		handle.status == PresentationHandle.COMPLETED
		and int(completion_probe["count"]) == 1,
		"reduced transition did not complete exactly once on the next frame",
	)
	_expect(
		battle.state_ref.revision == 61
		and battle.state_ref.players[0].hand.size() == 2
		and battle.hand_views.size() >= 2
		and not battle.hand_views[1].is_presentation_hidden()
		and _count_motion_entities(battle) == 0,
		"reduced transition did not reconcile immediately to its target view",
	)
	if not handle.is_completed():
		battle.cancel_presentations("reduced_contract_cleanup", target_view)
		await process_frame

	var switch_before: GameState = battle.state_ref.clone_state()
	switch_before.players[0].active = PokemonState.new("sv1-104")
	switch_before.players[0].active.energy_card_ids.assign([
		"sv1-ener-2",
		"sv1-ener-2",
	])
	switch_before.players[0].bench[0] = PokemonState.new("svi-chim")
	battle.update_view(switch_before, 0, empty_rows, "", false, "test")
	await process_frame
	var switch_after: GameState = switch_before.clone_state()
	switch_after.revision = switch_before.revision + 1
	var old_active := switch_after.players[0].active
	switch_after.players[0].active = switch_after.players[0].bench[0]
	switch_after.players[0].bench[0] = old_active
	var reduced_switch_view := BattleViewModel.capture(
		switch_after, 0, empty_rows, "", false, "test",
	)
	var reduced_switch: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			reduced_switch_view,
			[{
				"event_id": "contract:reduced-switch",
				"event_type": "switched",
				"actor": 0,
				"data": {"player": 0, "slot": "bench_0"},
			}],
			0,
			BattleTransitionRequest.CAUSE_LOCAL_ACTION,
		)
	)
	await process_frame
	await process_frame
	var reduced_active: CardView = battle.get_slot_view(0, "active")
	var reduced_bench: CardView = battle.get_slot_view(0, "bench_0")
	_expect(
		reduced_switch.status == PresentationHandle.COMPLETED
		and _count_motion_entities(battle) == 0
		and battle._presentation_slot_covers.is_empty()
		and reduced_active != null
		and reduced_bench != null
		and not reduced_active.is_presentation_hidden()
		and not reduced_bench.is_presentation_hidden(),
		"reduced switch left a tween, composite cover, or masked landing view",
	)

	# Reduced motion still has to preserve the incoming Pokemon as the staged
	# active stack when later events in the same revision mutate that slot.  The
	# two swap sources must be claimed before either destination is retained.
	var reduced_tail_before := UIPreviewStateFactory.battle_state(20260810)
	reduced_tail_before.revision = 62
	reduced_tail_before.players[0].active = PokemonState.new("sv1-104")
	reduced_tail_before.players[0].bench[0] = PokemonState.new("svi-chim")
	reduced_tail_before.players[0].discard = ["sv1-ener-2"]
	battle.update_view(reduced_tail_before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var reduced_tail_snapshot: Dictionary = battle.capture_presentation_snapshot()
	var reduced_tail_after := reduced_tail_before.clone_state()
	reduced_tail_after.revision = 63
	var reduced_tail_old_active := reduced_tail_after.players[0].active
	reduced_tail_after.players[0].active = reduced_tail_after.players[0].bench[0]
	reduced_tail_after.players[0].bench[0] = reduced_tail_old_active
	reduced_tail_after.players[0].active.damage_counters = 3
	reduced_tail_after.players[0].active.energy_card_ids.append("sv1-ener-2")
	reduced_tail_after.players[0].discard.clear()
	var reduced_tail_events: Array[Dictionary] = PresentationEvent.normalize_all([
		{
			"event_id": "contract:reduced-switch-tail",
			"event_type": "switched",
			"actor": 0,
			"data": {"player": 0, "slot": "bench_0"},
		},
		{
			"event_id": "contract:reduced-switch-damage",
			"event_type": "damage_dealt",
			"actor": 1,
			"amount": 30,
			"target": {"player": 0, "slot": "active"},
			"data": {"player": 0, "slot": "active", "amount": 30},
		},
		{
			"event_id": "contract:reduced-switch-attach",
			"event_type": "energy_attached",
			"actor": 0,
			"card_id": "sv1-ener-2",
			"source": {"player": 0, "zone": "discard", "index": 0},
			"target": {"player": 0, "slot": "active"},
			"data": {
				"player": 0,
				"slot": "active",
				"card_ids": ["sv1-ener-2"],
			},
		},
	], 63, 0)
	battle.update_view(reduced_tail_after, 0, empty_rows, "", false, "test")
	battle._stage_presentation_targets(
		reduced_tail_events,
		reduced_tail_snapshot,
	)
	var expected_incoming_cover := battle._presentation_slot_covers.get(
		"0:bench_0",
	) as CardView
	battle._on_presentation_event_started(reduced_tail_events[0])
	battle._spawn_slot_transition(
		reduced_tail_events[0],
		0.0,
		str(reduced_tail_events[0].get("event_id", "")),
	)
	var reduced_tail_cover := battle._presentation_slot_covers.get(
		"0:active",
	) as CardView
	var live_slot_covers := 0
	for child in battle.effects.find_children("*", "CardView", true, false):
		if (
			str(child.get_meta("battle_transient_kind", "")) == "SlotStateCover"
			and not child.is_queued_for_deletion()
		):
			live_slot_covers += 1
	_expect(
		reduced_tail_cover == expected_incoming_cover
		and reduced_tail_cover != null
		and reduced_tail_cover.pokemon != null
		and reduced_tail_cover.pokemon.card_id == "svi-chim"
		and live_slot_covers == 1
		and battle._active_flyers.is_empty(),
		"reduced switch replaced the incoming staged Pokemon or orphaned a source cover",
	)
	battle._on_presentation_event_finished(reduced_tail_events[0])
	for tail_index in range(1, reduced_tail_events.size()):
		battle._on_presentation_event_started(reduced_tail_events[tail_index])
		battle._on_presentation_event_finished(reduced_tail_events[tail_index])
	await process_frame
	var reduced_tail_active: CardView = battle.get_slot_view(0, "active")
	_expect(
		battle._presentation_slot_covers.is_empty()
		and battle._presentation_mask_counts.is_empty()
		and reduced_tail_active != null
		and reduced_tail_active.pokemon != null
		and reduced_tail_active.pokemon.card_id == "svi-chim"
		and reduced_tail_active.pokemon.damage_counters == 3
		and reduced_tail_active.pokemon.energy_card_ids == ["sv1-ener-2"]
		and not reduced_tail_active.is_presentation_hidden()
		and reduced_tail_active.modulate.a > 0.99,
		"reduced switch mutation tail left the wrong identity, mask, or cover",
	)
	settings.set("animation_mode", "cinematic")
	settings.set("reduced_motion", false)


func _run_drag_identity_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var duplicate_state := UIPreviewStateFactory.battle_state(20260719)
	duplicate_state.revision = 70
	duplicate_state.players[0].hand = [
		"sv1-104",
		"sv1-104",
		"sv1-ener-5",
	]
	battle.update_view(duplicate_state, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var first_duplicate_id: String = battle.hand_views[0].local_visual_id
	var second_duplicate_id: String = battle.hand_views[1].local_visual_id
	_expect(
		not first_duplicate_id.is_empty()
		and not second_duplicate_id.is_empty()
		and first_duplicate_id != second_duplicate_id,
		"duplicate hand cards did not receive distinct local visual identities",
	)

	battle._on_hand_drag_started(1)
	await process_frame
	var variant_session_id: String = str(
		battle.active_drag_context().get("session_id", ""))
	if battle._drag_session != null:
		battle._drag_session.state = CardDragSession.AWAITING_VARIANT
	battle._on_hand_drag_ended()
	await process_frame
	_expect(
		not variant_session_id.is_empty()
		and battle.active_drag_context().get("session_id", "") == variant_session_id
		and battle.active_drag_context().get("state", "")
		== CardDragSession.AWAITING_VARIANT,
		"native drag end destroyed an awaiting-variant proxy",
	)
	battle.clear_pending_drag("variant_contract_cancel")
	await _wait_for_drag_idle(battle)

	battle._on_hand_drag_started(1)
	await process_frame
	var stale_context: Dictionary = battle.active_drag_context()
	_expect(
		int(stale_context.get("revision", -1)) == 70
		and int(stale_context.get("hand_index", -1)) == 1
		and str(stale_context.get("card_id", "")) == "sv1-104"
		and battle.hand_views[1].local_visual_id == second_duplicate_id,
		"duplicate drag did not bind its indexed local occurrence",
	)
	var advanced_state := duplicate_state.clone_state()
	advanced_state.revision = 71
	battle.update_view(advanced_state, 0, empty_rows, "", false, "test")
	await process_frame
	var stale_session_id: String = battle.mark_drag_pending("stale:duplicate", true)
	_expect(stale_session_id.is_empty(), "stale duplicate drag was accepted")
	await _wait_for_drag_idle(battle)
	var duplicate_ids_after: Dictionary = {}
	var duplicate_nodes_clear := true
	for index in range(2):
		var view: CardView = battle.hand_views[index]
		duplicate_nodes_clear = duplicate_nodes_clear and not view.is_drag_masked()
		duplicate_ids_after[view.local_visual_id] = true
	_expect(
		battle.active_drag_context().is_empty()
		and duplicate_nodes_clear
		and duplicate_ids_after.size() == 2
		and _count_motion_entities(battle) == 0,
		"stale duplicate drag did not return or clear without losing identity",
	)


func _run_local_drag_success_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260720)
	before.revision = 80
	before.players[0].hand = ["svi-chim", "sv1-ener-5"]
	before.players[0].bench = [null, null, null, null, null]
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var source_view := _visible_hand_view_at_index(battle, 0)
	_expect(source_view != null, "local drag fixture did not render its source card")
	if source_view == null:
		return
	var snapshot_source_center: Vector2 = battle._effects_local(
		source_view.global_center())

	battle._on_hand_drag_started(0)
	await process_frame
	var session = battle._drag_session
	var proxy := session.proxy as Control if session != null else null
	_expect(proxy != null, "local drag success fixture did not create a proxy")
	if proxy == null:
		battle.clear_pending_drag("local_drag_fixture_missing_proxy")
		await _wait_for_drag_idle(battle)
		return
	var proxy_instance_id := proxy.get_instance_id()
	battle._park_drag_session(0, "bench_0")
	session.state = CardDragSession.AWAITING_VARIANT
	await create_timer(0.16).timeout
	var parked_center := proxy.position + proxy.size * 0.5
	var action_id := "contract:local-drag:80"
	var session_id: String = battle.mark_drag_pending(action_id, false)
	_expect(
		not session_id.is_empty()
		and battle.active_drag_context().get("state", "") == CardDragSession.COMMITTED,
		"local drag was not reserved on its base revision",
	)

	var after := before.clone_state()
	after.revision = 81
	after.players[0].hand.remove_at(0)
	after.players[0].bench[0] = PokemonState.new("svi-chim")
	var play_event := {
		"event_type": "pokemon_played",
		"actor": 0,
		"card_id": "svi-chim",
		"source": {"player": 0, "zone": "hand", "index": 0},
		"target": {"player": 0, "slot": "bench_0"},
		"amount": 1,
		"data": {
			"player": 0,
			"card_id": "svi-chim",
			"source_zone": "hand",
			"source_index": 0,
			"target_slot": "bench_0",
		},
	}
	var target_view := BattleViewModel.capture(
		after, 0, empty_rows, "", false, "test")
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			target_view,
			[play_event],
			0,
			BattleTransitionRequest.CAUSE_LOCAL_ACTION,
			action_id,
			"",
			session_id,
		)
	)
	await process_frame
	await process_frame
	var entities := _motion_entities(battle)
	var reused_proxy := (
		entities.size() == 1
		and entities[0] != null
		and entities[0].get_instance_id() == proxy_instance_id
	)
	_expect(
		reused_proxy,
		"R to R+1 local drag regenerated a second card instead of reusing its proxy",
	)
	if reused_proxy:
		var motion_start: Vector2 = entities[0].get_meta(
			"motion_start", Vector2.ZERO)
		_expect(
			motion_start.distance_to(parked_center) < 2.0
			and motion_start.distance_to(snapshot_source_center) > 2.0,
			"successful local drag restarted its flight from the hand snapshot",
		)
	await _wait_for_handle(handle, battle)
	var landed_view = battle.get_slot_view(0, "bench_0")
	_expect(
		handle.status == PresentationHandle.COMPLETED
		and battle.active_drag_context().is_empty()
		and _count_motion_entities(battle) == 0
		and landed_view != null
		and not landed_view.is_presentation_hidden(),
		"local drag proxy did not hand ownership to the real target card",
	)


func _run_bench_search_anchor_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260721)
	before.revision = 90
	before.players[0].bench = [null, null, null, null, null]
	before.players[0].deck = ["svi-chim", "svi-ente", "sv1-ener-5"]
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame

	var after := before.clone_state()
	var events: Array[Dictionary] = []
	var move_result := VMZoneHelpers.move_selected_cards(
		after,
		PortableRandomSource.new(20260721),
		{
			"player_idx": 0,
			"source_zone": "deck",
			"destination": "bench",
			"shuffle": false,
		},
		[
			{"option_id": "bench:0", "value": {"index": 0}},
			{"option_id": "bench:1", "value": {"index": 1}},
		],
		events,
	)
	after.revision = 91
	var exact_events := bool(move_result.get("success", false)) and events.size() == 2
	for index in range(events.size()):
		var event: Dictionary = events[index]
		exact_events = (
			exact_events
			and str(event.get("event_type", "")) == "card_moved"
			and str(event.get("target", {}).get("slot", ""))
			== "bench_%d" % index
			and int(event.get("source", {}).get("index", -1)) == index
		)
	_expect(
		exact_events
		and after.players[0].get_pokemon("bench_0") != null
		and after.players[0].get_pokemon("bench_0").card_id == "svi-chim"
		and after.players[0].get_pokemon("bench_1") != null
		and after.players[0].get_pokemon("bench_1").card_id == "svi-ente",
		"bench search did not emit one exact card_moved endpoint per occupied slot",
	)
	if not exact_events:
		return

	var target_view := BattleViewModel.capture(
		after, 0, empty_rows, "", false, "test")
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			target_view,
			events,
			0,
			BattleTransitionRequest.CAUSE_CHOICE,
		)
	)
	await process_frame
	await process_frame
	var bench_zero = battle.get_slot_view(0, "bench_0")
	var bench_one = battle.get_slot_view(0, "bench_1")
	var entities := _motion_entities(battle)
	var actual_finish: Vector2 = (
		battle._effects_local(bench_zero.global_center())
		if bench_zero != null
		else Vector2.ZERO
	)
	var screen_center: Vector2 = battle.effects.size * Vector2(0.5, 0.5)
	var motion_finish_value: Variant = (
		entities[0].get_meta("motion_finish", Vector2.ZERO)
		if not entities.is_empty()
		else Vector2.ZERO
	)
	var motion_finish: Vector2 = (
		motion_finish_value
		if motion_finish_value is Vector2
		else Vector2.ZERO
	)
	_expect(
		entities.size() == 1
		and bench_zero != null
		and bench_one != null
		and bench_zero.is_presentation_hidden()
		and bench_one.is_presentation_hidden()
		and motion_finish.distance_to(actual_finish) < 0.1
		and motion_finish.distance_to(screen_center) > 4.0,
		"bench search motion did not land on bench_0's real anchor",
	)
	await _wait_for_handle(handle, battle)
	_expect(
		handle.status == PresentationHandle.COMPLETED
		and not bench_zero.is_presentation_hidden()
		and not bench_one.is_presentation_hidden()
		and _count_motion_entities(battle) == 0,
		"multi-card bench search did not reconcile both real target nodes",
	)


func _run_cards_selected_hand_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260722)
	before.revision = 100
	before.players[0].hand = ["sv1-ener-5", "svf-potion"]
	before.players[0].deck = ["sv1-104"]
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var first_view := _visible_hand_view_at_index(battle, 0)
	var second_view := _visible_hand_view_at_index(battle, 1)
	var old_positions: Array[Vector2] = [
		first_view.position if first_view != null else Vector2.ZERO,
		second_view.position if second_view != null else Vector2.ZERO,
	]

	var after := before.clone_state()
	after.revision = 101
	after.players[0].deck.clear()
	after.players[0].hand.append("sv1-104")
	var selected_event := VMZoneHelpers.cards_selected_event(
		0,
		"deck",
		"hand",
		["sv1-104"],
		1,
		[0],
		[2],
	)
	var target_view := BattleViewModel.capture(
		after, 0, empty_rows, "", false, "test")
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			target_view,
			[selected_event],
			0,
			BattleTransitionRequest.CAUSE_CHOICE,
		)
	)
	await process_frame
	await process_frame
	var incoming := _visible_hand_view_at_index(battle, 2)
	_expect(
		incoming != null
		and incoming.card_id == "sv1-104"
		and incoming.is_presentation_hidden()
		and first_view != null
		and second_view != null
		and first_view.position.distance_to(old_positions[0]) < 0.5
		and second_view.position.distance_to(old_positions[1]) < 0.5
		and _count_motion_entities(battle) == 1,
		"cards_selected exposed or reserved space for its real hand node before flight",
	)
	await create_timer(0.12).timeout
	_expect(
		incoming != null and incoming.is_presentation_hidden(),
		"cards_selected revealed its real hand node before the moving card landed",
	)
	await _wait_for_handle(handle, battle)
	_expect(
		handle.status == PresentationHandle.COMPLETED
		and incoming != null
		and not incoming.is_presentation_hidden()
		and _count_motion_entities(battle) == 0,
		"cards_selected did not hand off to its real hand node on landing",
	)


func _run_caitlin_full_hand_batch_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
	settings: Node,
) -> void:
	var previous_quality := str(settings.get("quality_profile"))
	settings.set("quality_profile", "low")
	battle._apply_runtime_settings()
	var returned_ids: Array[String] = [
		"sv1-104",
		"sv1-ener-1",
		"sv1-ener-2",
		"sv1-ener-3",
		"sv1-ener-4",
		"sv1-ener-5",
		"sv1-ener-6",
		"sv1-ener-7",
		"sv1-ener-8",
	]
	var drawn_ids: Array[String] = [
		"sv1-151",
		"svf-potion",
		"sv1-ener-8",
		"sv1-ener-7",
		"sv1-ener-6",
		"sv1-ener-5",
		"sv1-ener-4",
		"sv1-ener-3",
		"sv1-ener-2",
	]
	var all_indices: Array[int] = []
	for index in range(returned_ids.size()):
		all_indices.append(index)
	var before := UIPreviewStateFactory.battle_state(20260728)
	before.revision = 102
	before.players[0].hand.assign(returned_ids)
	before.players[0].deck.assign(drawn_ids)
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame

	var after := before.clone_state()
	after.revision = 103
	after.players[0].hand.assign(drawn_ids)
	after.players[0].deck.assign(returned_ids)
	var return_event_id := "contract:caitlin-return-all"
	var draw_event_id := "contract:caitlin-redraw-all"
	var return_event := VMZoneHelpers.cards_selected_event(
		0,
		"hand",
		"deck",
		returned_ids,
		returned_ids.size(),
		all_indices,
		all_indices,
	)
	return_event["event_id"] = return_event_id
	var draw_event := _draw_event(0, drawn_ids)
	draw_event["event_id"] = draw_event_id
	var target_view := BattleViewModel.capture(
		after, 0, empty_rows, "", false, "test")
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			target_view,
			[return_event, draw_event],
			0,
			BattleTransitionRequest.CAUSE_CHOICE,
		)
	)

	var seen_return_ordinals: Dictionary = {}
	var seen_draw_ordinals: Dictionary = {}
	var peak_active := 0
	var observed_rolling_queue := false
	var draw_started_before_return_complete := false
	for _frame in range(960):
		peak_active = maxi(peak_active, battle._active_flyers.size())
		if not battle._card_motion_batches.is_empty():
			observed_rolling_queue = true
		for flyer_value in battle._active_flyers:
			var flyer := flyer_value as Control
			if flyer == null or not flyer.has_meta("motion_batch_ordinal"):
				continue
			var ordinal := int(flyer.get_meta("motion_batch_ordinal"))
			var event_id := str(flyer.get_meta("motion_event_id", ""))
			if event_id == return_event_id:
				seen_return_ordinals[ordinal] = true
			elif event_id == draw_event_id:
				seen_draw_ordinals[ordinal] = true
		if (
			battle._active_presentation_event_id == draw_event_id
			and seen_return_ordinals.size() < returned_ids.size()
		):
			draw_started_before_return_complete = true
		if handle.is_completed():
			break
		await process_frame

	_expect(
		observed_rolling_queue
		and seen_return_ordinals.size() == returned_ids.size()
		and seen_draw_ordinals.size() == drawn_ids.size(),
		"Caitlin full-hand motion omitted a returned or redrawn card: return=%s draw=%s"
		% [str(seen_return_ordinals.keys()), str(seen_draw_ordinals.keys())],
	)
	_expect(
		peak_active <= battle._max_active_flyers()
		and not draw_started_before_return_complete,
		"Caitlin rolling batch exceeded its quality budget or released the event barrier early",
	)
	_expect(
		handle.status == PresentationHandle.COMPLETED
		and battle._card_motion_batches.is_empty()
		and battle._presentation_hand_source_proxies.is_empty()
		and _count_motion_entities(battle) == 0
		and battle.state_ref.players[0].hand == drawn_ids,
		"Caitlin full-hand transition did not reconcile or left queued proxies behind",
	)
	if not handle.is_completed():
		battle.cancel_presentations("caitlin_batch_contract_cleanup", target_view)
		await process_frame

	# A resync can arrive while the ninth proxy is still queued. It must cancel
	# the coordinator before active-handle cancellation tries to refill the queue.
	var cancel_before: GameState = battle.state_ref.clone_state()
	var cancel_after: GameState = cancel_before.clone_state()
	cancel_after.revision = cancel_before.revision + 1
	cancel_after.players[0].hand.clear()
	cancel_after.players[0].deck.append_array(drawn_ids)
	var cancel_event := VMZoneHelpers.cards_selected_event(
		0,
		"hand",
		"deck",
		drawn_ids,
		drawn_ids.size(),
		all_indices,
		all_indices,
	)
	cancel_event["event_id"] = "contract:caitlin-return-cancelled"
	var cancel_target := BattleViewModel.capture(
		cancel_after, 0, empty_rows, "", false, "test")
	var cancel_handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			cancel_target,
			[cancel_event],
			0,
			BattleTransitionRequest.CAUSE_CHOICE,
		)
	)
	await process_frame
	await process_frame
	_expect(
		not battle._card_motion_batches.is_empty(),
		"Caitlin cancellation contract did not reach an oversized queued batch",
	)
	battle.cancel_presentations("caitlin_batch_cancelled", cancel_target)
	await process_frame
	await process_frame
	_expect(
		cancel_handle.status == PresentationHandle.SNAPPED
		and battle._card_motion_batches.is_empty()
		and battle._event_motion_completions.is_empty()
		and battle._active_flyers.is_empty()
		and battle.effects.find_children(
			"SnapshotHandProxy", "", true, false).is_empty(),
		"Cancelling Caitlin's queued full-hand motion left state behind: status=%s batches=%d barriers=%d flyers=%d proxies=%d"
		% [
			cancel_handle.status,
			battle._card_motion_batches.size(),
			battle._event_motion_completions.size(),
			battle._active_flyers.size(),
			battle.effects.find_children(
				"SnapshotHandProxy", "", true, false).size(),
		],
	)
	settings.set("quality_profile", previous_quality)
	battle._apply_runtime_settings()


func _run_attachment_motion_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260723)
	before.revision = 110
	before.players[0].discard.clear()
	before.players[1].discard.clear()
	before.players[1].bench[0] = PokemonState.new("sv2-delib")
	before.players[1].bench[0].energy_card_ids.assign([
		"sv1-ener-4",
		"sv1-ener-5",
	])
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame

	var source_view: CardView = battle.get_slot_view(1, "bench_0")
	_expect(source_view != null, "attachment motion fixture did not render opponent bench_0")
	if source_view == null:
		return
	var source_badge: Vector2 = battle._effects_local(
		source_view.attachment_anchor_global("energy", "sv1-ener-5", 1)
	)
	var first_energy_badge: Vector2 = battle._effects_local(
		source_view.attachment_anchor_global("energy", "sv1-ener-4", 0)
	)
	_expect(
		source_badge.distance_to(first_energy_badge) > 2.0,
		"distinct attached energy identities still resolved to the first badge",
	)
	var source_card_center: Vector2 = battle._effects_local(
		source_view.global_center()
	)
	var own_hand_center: Vector2 = battle.resolve_endpoint_center({
		"player": 0,
		"zone": "hand",
	})
	var opponent_discard_center: Vector2 = battle.resolve_endpoint_center({
		"player": 1,
		"zone": "discard",
	})
	var own_discard_center: Vector2 = battle.resolve_endpoint_center({
		"player": 0,
		"zone": "discard",
	})
	var source_snapshot: Dictionary = battle.capture_presentation_snapshot()
	var source_slot_row: Dictionary = source_snapshot.get("slots", {}).get(
		"1:bench_0",
		{},
	)
	var snapshot_attachment_centers: Dictionary = source_slot_row.get(
		"attachment_centers",
		{},
	)
	_expect(
		snapshot_attachment_centers.has("energy:sv1-ener-5")
		and (snapshot_attachment_centers.get("energy:sv1-ener-5") as Vector2).distance_to(
			source_badge) < 0.1,
		"presentation snapshot did not preserve the selected energy badge anchor",
	)

	var after := before.clone_state()
	var runtime := VMRuntime.new(CardCatalog.new())
	var events: Array[Dictionary] = []
	var discard_result := runtime.board_continuations.resolve_discard_attachment(
		after,
		{"player_idx": 0},
		[{
			"value": {
				"player": 1,
				"slot": "bench_0",
				"index": 1,
				"card_id": "sv1-ener-5",
			},
		}],
		events,
	)
	after.revision = 111
	_expect(
		bool(discard_result.get("success", false)) and events.size() == 1,
		"attachment motion fixture could not discard the selected energy",
	)
	if not bool(discard_result.get("success", false)) or events.size() != 1:
		return
	var target_view := BattleViewModel.capture(
		after, 0, empty_rows, "", false, "test")
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			target_view,
			events,
			0,
			BattleTransitionRequest.CAUSE_CHOICE,
		)
	)
	await process_frame
	await process_frame
	var entities := _motion_entities(battle)
	# The coordinator applies the target view before dispatching the event, which
	# may relayout the board. Compare against the endpoint geometry from the same
	# rendered frame as the motion entity.
	opponent_discard_center = battle.resolve_endpoint_center({
		"player": 1,
		"zone": "discard",
	})
	own_discard_center = battle.resolve_endpoint_center({
		"player": 0,
		"zone": "discard",
	})
	var motion_start := Vector2.ZERO
	var motion_finish := Vector2.ZERO
	var attachment_motion_image: TextureRect
	if not entities.is_empty():
		motion_start = entities[0].get_meta("motion_start", Vector2.ZERO)
		motion_finish = entities[0].get_meta("motion_finish", Vector2.ZERO)
		attachment_motion_image = entities[0].get_node_or_null("PaperImage") as TextureRect
	_expect(
		entities.size() == 1
		and motion_start.distance_to(source_badge) < 0.1
		and motion_start.distance_to(source_card_center) > 4.0
		and motion_start.distance_to(own_hand_center) > 4.0
		and attachment_motion_image != null
		and attachment_motion_image.texture == EnergyIconCatalog.texture_for("Psychic")
		and entities[0].get_meta("motion_flip_texture", null)
		== battle._public_motion_texture_for_card_id("sv1-ener-5"),
		"opponent attachment discard did not start at its snapshot energy badge",
	)
	_expect(
		entities.size() == 1
		and motion_finish.distance_to(opponent_discard_center) < 8.0
		and motion_finish.distance_to(own_discard_center) > 8.0,
		"opponent attachment discard did not land on the opponent discard pile "
		+ "(finish=%s opponent=%s own=%s)" % [
			motion_finish,
			opponent_discard_center,
			own_discard_center,
		],
	)
	await _wait_for_handle(handle, battle)
	_expect(
		handle.status == PresentationHandle.COMPLETED
		and _count_motion_entities(battle) == 0,
		"attachment discard motion did not complete cleanly",
	)

	# Attachment destinations are moving sub-controls inside a CardView. Verify
	# both endpoint resolution and the in-flight landing callback read their live
	# badge positions instead of caching the Pokemon card centre.
	var badge_state := before.clone_state()
	badge_state.revision = 112
	badge_state.players[0].active.energy_card_ids = [
		"sv1-ener-5",
		"sv1-ener-2",
	]
	badge_state.players[0].active.attached_tool_id = "sv1-202"
	battle.update_view(badge_state, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var target_view_node: CardView = battle.get_slot_view(0, "active")
	_expect(
		target_view_node != null
		and target_view_node.energy_row.visible
		and target_view_node.tool_badge.visible,
		"attachment target fixture did not render both energy and tool badges",
	)
	if target_view_node == null:
		return
	var card_center: Vector2 = battle._effects_local(
		target_view_node.global_center()
	)
	var landing_probe := Control.new()
	landing_probe.set_meta("motion_landing_view", target_view_node)
	for attachment_type in ["energy", "tool"]:
		var anchor_control: Control = (
			target_view_node.energy_row
			if attachment_type == "energy"
			else target_view_node.tool_badge
		)
		var original_position := anchor_control.position
		anchor_control.position += Vector2(11.0, 7.0)
		var expected_anchor: Vector2 = battle._effects_local(
			target_view_node.attachment_anchor_global(attachment_type)
		)
		var endpoint := {
			"player": 0,
			"slot": "active",
			"attachment_type": attachment_type,
		}
		landing_probe.set_meta("motion_landing_attachment_type", attachment_type)
		var resolved_anchor: Vector2 = battle.resolve_endpoint_center(endpoint)
		var dynamic_finish: Vector2 = battle._motion_entity_finish(
			landing_probe,
			card_center,
		)
		_expect(
			resolved_anchor.distance_to(expected_anchor) < 0.1
			and dynamic_finish.distance_to(expected_anchor) < 0.1
			and dynamic_finish.distance_to(card_center) > 4.0,
			"%s attachment landing did not follow its live badge anchor" % attachment_type,
		)
		anchor_control.position = original_position
	var indexed_expected: Vector2 = battle._effects_local(
		target_view_node.attachment_anchor_global("energy", "sv1-ener-2", 1),
	)
	var canonical_indexed := {
		"player": 0,
		"slot": "active",
		"attachment_type": "energy",
		"attachment_card_id": "sv1-ener-2",
		"index": 1,
	}
	var legacy_indexed := canonical_indexed.duplicate(true)
	legacy_indexed["attachment_index"] = legacy_indexed["index"]
	legacy_indexed.erase("index")
	_expect(
		battle.resolve_endpoint_center(canonical_indexed).distance_to(
			indexed_expected,
		) < 0.1
		and battle.resolve_endpoint_center(legacy_indexed).distance_to(
			indexed_expected,
		) < 0.1,
		"canonical attachment index or legacy attachment_index fallback resolved the wrong badge",
	)
	var inferred_fire_index: int = battle._landing_attachment_index_for_event(
		{
			"player": 0,
			"slot": "active",
			"attachment_type": "energy",
		},
		target_view_node,
		"sv1-ener-2",
		0,
		1,
	)
	landing_probe.set_meta("motion_landing_attachment_type", "energy")
	landing_probe.set_meta("motion_landing_attachment_card_id", "sv1-ener-2")
	landing_probe.set_meta("motion_landing_attachment_index", inferred_fire_index)
	_expect(
		inferred_fire_index == 1
		and battle._motion_entity_finish(
			landing_probe,
			card_center,
		).distance_to(indexed_expected) < 0.1,
		"new Fire energy landed on the existing first energy badge when target index was omitted",
	)
	landing_probe.free()

	# Every slot attachment proxy uses descriptor semantics. Unknown/tool visuals
	# retain a readable fallback marker, while Colorless-providing Special Energy
	# deliberately uses the shared Colorless icon without a card-specific marker.
	var descriptor_rows := [
		{"type": "tool", "card_id": "sv1-202", "expected": "道", "marker": true},
		{"type": "energy", "card_id": "missing-energy", "expected": "?", "marker": true},
		{"type": "energy", "card_id": "svi-mirc", "expected": "", "marker": false},
	]
	for descriptor_index in range(descriptor_rows.size()):
		var descriptor_row: Dictionary = descriptor_rows[descriptor_index]
		var descriptor := AttachmentVisualDescriptor.resolve(
			str(descriptor_row.get("type", "")),
			str(descriptor_row.get("card_id", "")),
			descriptor_index,
			battle.catalog,
		)
		var expected_marker := str(descriptor_row.get("expected", ""))
		var expects_marker := bool(descriptor_row.get("marker", true))
		var badge_texture: Texture2D = (
			descriptor.icon
			if descriptor.icon != null
			else battle._neutral_public_card_texture()
		)
		var badge_proxy: Control = battle._create_paper_card_token(
			badge_texture,
			Vector2(24.0, 24.0),
			"ContractAttachmentBadge",
			1,
		)
		badge_proxy.set_meta("attachment_badge_proxy", true)
		battle._configure_attachment_badge_marker(badge_proxy, descriptor)
		var marker := badge_proxy.get_node_or_null("AttachmentBadgeMarker") as Label
		var marker_matches := (
			marker != null
			and marker.visible
			and marker.text == expected_marker
			if expects_marker
			else marker == null or not marker.visible
		)
		_expect(
			marker_matches
			and bool(badge_proxy.get_meta("attachment_badge_proxy", false)),
			"%s attachment motion did not match its descriptor marker policy"
			% descriptor.card_id,
		)
		if str(descriptor_row.get("card_id", "")) == "svi-mirc":
			_expect(
				descriptor.group_key == "energy:type:Colorless"
				and descriptor.energy_type == "Colorless"
				and descriptor.icon != null
				and descriptor.marker.is_empty(),
				"Colorless Special Energy motion retained a card-specific visual",
			)
		badge_proxy.free()


func _run_tool_attachment_landing_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260814)
	before.revision = 146
	before.players[0].active = PokemonState.new("sv1-104")
	before.players[0].hand = ["sv1-202"]
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var snapshot: Dictionary = battle.capture_presentation_snapshot()

	var after := before.clone_state()
	after.revision = 147
	after.players[0].hand.clear()
	after.players[0].active.attached_tool_id = "sv1-202"
	var events: Array[Dictionary] = PresentationEvent.normalize_all([{
		"event_id": "contract:attachment:tool-landing",
		"event_type": "tool_attached",
		"actor": 0,
		"card_id": "sv1-202",
		"source": {"player": 0, "zone": "hand", "index": 0},
		"target": {"player": 0, "slot": "active"},
		"data": {
			"player": 0,
			"slot": "active",
			"card_id": "sv1-202",
		},
	}], 147, 0)
	battle.update_view(after, 0, empty_rows, "", false, "test")
	battle._stage_presentation_targets(events, snapshot)
	var event: Dictionary = events[0]
	var cover := battle._presentation_slot_covers.get(
		"0:active",
	) as CardView
	var authoritative_target: CardView = battle.get_slot_view(0, "active")
	_expect(
		cover != null
		and authoritative_target != null
		and not cover.tool_badge.visible,
		"Tool-attach tween fixture did not stage its pre-event CardView",
	)
	if cover == null or authoritative_target == null:
		battle._clear_transient_visuals()
		return

	var prospective_rect := cover.prospective_attachment_visual_global_rect(
		"tool",
		"sv1-202",
	)
	var prospective_center: Vector2 = battle._effects_local(
		prospective_rect.get_center()
	)
	var staged_card_center: Vector2 = battle._effects_local(
		cover.global_center()
	)
	var completion := _start_staged_event_motion(battle, event, 0.46)
	await process_frame
	var flyer := _event_motion_entity(
		battle,
		"contract:attachment:tool-landing",
	)
	var dynamic_finish: Vector2 = (
		battle._motion_entity_finish(flyer, Vector2.ZERO)
		if flyer != null
		else Vector2.ZERO
	)
	_expect(
		flyer != null
		and flyer.get_meta("motion_landing_view", null) == cover
		and prospective_rect.size.x > 0.0
		and prospective_rect.size.y > 0.0
		and not cover.tool_badge.visible
		and dynamic_finish.distance_to(prospective_center) < 0.2
		and dynamic_finish.distance_to(staged_card_center) > 4.0,
		"Tool-attach tween targeted the Pokemon centre instead of its future badge",
	)
	if not completion.is_finished():
		await completion.completed
	var landed_center := (
		flyer.position + flyer.size * 0.5
		if flyer != null and is_instance_valid(flyer)
		else Vector2.ZERO
	)
	_expect(
		flyer != null
		and is_instance_valid(flyer)
		and bool(flyer.get_meta("motion_completed", false))
		and not cover.tool_badge.visible
		and landed_center.distance_to(prospective_center) < 0.2,
		"Tool-attach tween did not finish on the prospective badge geometry",
	)

	battle._on_presentation_event_finished(event)
	await process_frame
	var rendered_tool_rect := authoritative_target.attachment_visual_global_rect(
		"tool",
		"sv1-202",
	)
	var rendered_tool_center: Vector2 = battle._effects_local(
		rendered_tool_rect.get_center()
	)
	_expect(
		authoritative_target.tool_badge.visible
		and not authoritative_target.is_presentation_hidden()
		and rendered_tool_rect.size.x > 0.0
		and rendered_tool_center.distance_to(landed_center) < 0.2
		and rendered_tool_center.distance_to(
			battle._effects_local(authoritative_target.global_center())
		) > 4.0
		and not battle._presentation_slot_covers.has("0:active")
		and _event_motion_entity(
			battle,
			"contract:attachment:tool-landing",
		) == null,
		"Tool badge jumped at handoff or left staged motion state behind",
	)
	battle._clear_transient_visuals()


func _run_attachment_batch_anchor_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	# Attach -> switch: the attachment must contact the staged old-active stack,
	# while the authoritative final active CardView remains masked for the later
	# switch. Advance the real flyer far enough to prove this is not a metadata-
	# only endpoint check.
	var attach_before := UIPreviewStateFactory.battle_state(20260812)
	attach_before.revision = 142
	attach_before.players[0].active = PokemonState.new("sv1-104")
	attach_before.players[0].active.energy_card_ids.assign(["sv1-ener-5"])
	attach_before.players[0].bench[0] = PokemonState.new("svi-chim")
	attach_before.players[0].discard = ["sv1-ener-2"]
	battle.update_view(attach_before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var attach_snapshot: Dictionary = battle.capture_presentation_snapshot()
	var attach_after := attach_before.clone_state()
	attach_after.revision = 143
	attach_after.players[0].discard.clear()
	attach_after.players[0].active.energy_card_ids.append("sv1-ener-2")
	var attached_old_active := attach_after.players[0].active
	attach_after.players[0].active = attach_after.players[0].bench[0]
	attach_after.players[0].bench[0] = attached_old_active
	var attach_events: Array[Dictionary] = PresentationEvent.normalize_all([
		{
			"event_id": "contract:batch-anchor:attach",
			"event_type": "energy_attached",
			"actor": 0,
			"card_id": "sv1-ener-2",
			"source": {"player": 0, "zone": "discard", "index": 0},
			"target": {"player": 0, "slot": "active"},
			"data": {
				"player": 0,
				"slot": "active",
				"card_ids": ["sv1-ener-2"],
			},
		},
		{
			"event_id": "contract:batch-anchor:switch",
			"event_type": "switched",
			"actor": 0,
			"data": {"player": 0, "slot": "bench_0"},
		},
	], 143, 0)
	battle.update_view(attach_after, 0, empty_rows, "", false, "test")
	battle._stage_presentation_targets(attach_events, attach_snapshot)
	var attach_real_active: CardView = battle.get_slot_view(0, "active")
	var attach_cover := battle._presentation_slot_covers.get(
		"0:active",
	) as CardView
	var real_active_mask_before := int(
		battle._presentation_mask_counts.get(
			attach_real_active.get_instance_id(),
			0,
		)
	)
	var attach_completion := _start_staged_event_motion(
		battle,
		attach_events[0],
		0.46,
	)
	await process_frame
	var attach_flyer := _event_motion_entity(
		battle,
		"contract:batch-anchor:attach",
	)
	var attach_start := (
		Vector2(attach_flyer.get_meta("motion_start", Vector2.ZERO))
		if attach_flyer != null
		else Vector2.ZERO
	)
	var prospective_fire_anchor: Vector2 = (
		battle._effects_local(
			attach_cover.prospective_attachment_visual_global_rect(
				"energy",
				"sv1-ener-2",
				1,
			).get_center()
		)
		if attach_cover != null
		else Vector2.ZERO
	)
	var existing_psychic_anchor: Vector2 = (
		battle._effects_local(attach_cover.attachment_anchor_global(
			"energy",
			"sv1-ener-5",
			0,
		))
		if attach_cover != null
		else Vector2.ZERO
	)
	var attach_dynamic_finish: Vector2 = (
		battle._motion_entity_finish(attach_flyer, Vector2.ZERO)
		if attach_flyer != null
		else Vector2.ZERO
	)
	_expect(
		attach_flyer != null
		and attach_cover != null
		and attach_flyer.get_meta("motion_landing_view", null) == attach_cover
		and attach_dynamic_finish.distance_to(prospective_fire_anchor) < 0.2
		and attach_dynamic_finish.distance_to(existing_psychic_anchor) > 8.0
		and attach_real_active.is_presentation_hidden()
		and real_active_mask_before > 0,
		"attach-before-switch did not bind its prospective badge to the staged composite",
	)
	await create_timer(0.18).timeout
	_expect(
		attach_flyer != null
		and is_instance_valid(attach_flyer)
		and (attach_flyer.position + attach_flyer.size * 0.5).distance_to(
			attach_start,
		) > 5.0,
		"attach-before-switch flyer did not actually advance",
	)
	if not attach_completion.is_finished():
		await attach_completion.completed
	_expect(
		attach_real_active.is_presentation_hidden()
		and int(battle._presentation_mask_counts.get(
			attach_real_active.get_instance_id(),
			0,
		)) == real_active_mask_before,
		"attachment landing consumed the later switch mask",
	)
	battle._on_presentation_event_finished(attach_events[0])
	var switch_completion := _start_staged_event_motion(
		battle,
		attach_events[1],
		0.46,
	)
	await process_frame
	var attached_switch_mover: CardView
	for mover in _slot_composite_movers(battle):
		if str(mover.get_meta("slot_composite_from", "")) == "active":
			attached_switch_mover = mover
			break
	_expect(
		attached_switch_mover != null
		and attached_switch_mover.pokemon != null
		and attached_switch_mover.pokemon.energy_card_ids == [
			"sv1-ener-5",
			"sv1-ener-2",
		],
		"attach-before-switch did not carry the contacted badge in its composite",
	)
	if not switch_completion.is_finished():
		await switch_completion.completed
	battle._on_presentation_event_finished(attach_events[1])
	battle._clear_transient_visuals()

	# Switch -> discard -> transfer: later source proxies must resolve from the
	# remapped retained cover. Discarding the first energy also moves Fire from the
	# second group to the first, so the transfer catches any stale batch anchor.
	var chain_before := UIPreviewStateFactory.battle_state(20260813)
	chain_before.revision = 144
	chain_before.players[0].active = PokemonState.new("sv1-104")
	chain_before.players[0].bench[0] = PokemonState.new("svi-chim")
	chain_before.players[0].bench[0].energy_card_ids.assign([
		"sv1-ener-5",
		"sv1-ener-2",
	])
	battle.update_view(chain_before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var chain_snapshot: Dictionary = battle.capture_presentation_snapshot()
	var chain_after := chain_before.clone_state()
	chain_after.revision = 145
	var old_chain_active := chain_after.players[0].active
	chain_after.players[0].active = chain_after.players[0].bench[0]
	chain_after.players[0].bench[0] = old_chain_active
	chain_after.players[0].active.energy_card_ids.clear()
	chain_after.players[0].bench[0].energy_card_ids.assign(["sv1-ener-2"])
	chain_after.players[0].discard = ["sv1-ener-5"]
	var chain_events: Array[Dictionary] = PresentationEvent.normalize_all([
		{
			"event_id": "contract:batch-anchor:switch-first",
			"event_type": "switched",
			"actor": 0,
			"data": {"player": 0, "slot": "bench_0"},
		},
		{
			"event_id": "contract:batch-anchor:discard-psychic",
			"event_type": "cards_discarded",
			"actor": 0,
			"source": {
				"player": 0,
				"slot": "active",
				"attachment_type": "energy",
				"index": 0,
			},
			"target": {"player": 0, "zone": "discard"},
			"data": {
				"player": 0,
				"card_ids": ["sv1-ener-5"],
				"source_indices": [0],
			},
		},
		{
			"event_id": "contract:batch-anchor:transfer-fire",
			"event_type": "energy_attached",
			"actor": 0,
			"source": {
				"player": 0,
				"slot": "active",
				"attachment_type": "energy",
				"index": 0,
			},
			"target": {"player": 0, "slot": "bench_0"},
			"data": {
				"player": 0,
				"card_ids": ["sv1-ener-2"],
				"source_indices": [0],
			},
		},
	], 145, 0)
	battle.update_view(chain_after, 0, empty_rows, "", false, "test")
	battle._stage_presentation_targets(chain_events, chain_snapshot)
	var chain_switch_completion := _start_staged_event_motion(
		battle,
		chain_events[0],
		0.46,
	)
	if not chain_switch_completion.is_finished():
		await chain_switch_completion.completed
	battle._on_presentation_event_finished(chain_events[0])
	var retained_active := battle._presentation_slot_covers.get(
		"0:active",
	) as CardView
	var retained_bench := battle._presentation_slot_covers.get(
		"0:bench_0",
	) as CardView
	var fire_anchor_before_discard: Vector2 = (
		battle._effects_local(
			retained_active.attachment_layout_visual_global_rect(
				"energy",
				"sv1-ener-2",
				1,
			).get_center()
		)
		if retained_active != null
		else Vector2.ZERO
	)
	var psychic_anchor_before_discard: Vector2 = (
		battle._effects_local(
			retained_active.attachment_layout_visual_global_rect(
				"energy",
				"sv1-ener-5",
				0,
			).get_center()
		)
		if retained_active != null
		else Vector2.ZERO
	)
	var real_chain_active: CardView = battle.get_slot_view(0, "active")
	var chain_active_mask := int(battle._presentation_mask_counts.get(
		real_chain_active.get_instance_id(),
		0,
	))
	var discard_completion := _start_staged_event_motion(
		battle,
		chain_events[1],
		0.46,
	)
	await process_frame
	var discard_flyer := _event_motion_entity(
		battle,
		"contract:batch-anchor:discard-psychic",
	)
	var discard_start := (
		Vector2(discard_flyer.get_meta("motion_start", Vector2.ZERO))
		if discard_flyer != null
		else Vector2.ZERO
	)
	_expect(
		retained_active != null
		and discard_flyer != null
		and discard_start.distance_to(psychic_anchor_before_discard) < 0.2,
		"post-switch discard did not launch from the retained composite badge",
	)
	await create_timer(0.18).timeout
	_expect(
		discard_flyer != null
		and is_instance_valid(discard_flyer)
		and (discard_flyer.position + discard_flyer.size * 0.5).distance_to(
			discard_start,
		) > 5.0,
		"post-switch discard flyer did not actually advance",
	)
	if not discard_completion.is_finished():
		await discard_completion.completed
	battle._on_presentation_event_finished(chain_events[1])
	retained_active = battle._presentation_slot_covers.get(
		"0:active",
	) as CardView
	var shifted_fire_anchor: Vector2 = (
		battle._effects_local(
			retained_active.attachment_layout_visual_global_rect(
				"energy",
				"sv1-ener-2",
				0,
			).get_center()
		)
		if retained_active != null
		else Vector2.ZERO
	)
	_expect(
		shifted_fire_anchor.distance_to(fire_anchor_before_discard) > 8.0
		and real_chain_active.is_presentation_hidden()
		and int(battle._presentation_mask_counts.get(
			real_chain_active.get_instance_id(),
			0,
		)) == chain_active_mask,
		"discard did not preserve the switch barrier or reflow the remaining badge",
	)
	var real_chain_bench: CardView = battle.get_slot_view(0, "bench_0")
	var chain_bench_mask := int(battle._presentation_mask_counts.get(
		real_chain_bench.get_instance_id(),
		0,
	))
	var transfer_completion := _start_staged_event_motion(
		battle,
		chain_events[2],
		0.46,
	)
	await process_frame
	var transfer_flyer := _event_motion_entity(
		battle,
		"contract:batch-anchor:transfer-fire",
	)
	var transfer_start := (
		Vector2(transfer_flyer.get_meta("motion_start", Vector2.ZERO))
		if transfer_flyer != null
		else Vector2.ZERO
	)
	var transfer_landing := (
		transfer_flyer.get_meta("motion_landing_view", null) as CardView
		if transfer_flyer != null
		else null
	)
	var prospective_transfer_anchor: Vector2 = (
		battle._effects_local(
			retained_bench.prospective_attachment_visual_global_rect(
				"energy",
				"sv1-ener-2",
				0,
			).get_center()
		)
		if retained_bench != null
		else Vector2.ZERO
	)
	var transfer_finish: Vector2 = (
		battle._motion_entity_finish(transfer_flyer, Vector2.ZERO)
		if transfer_flyer != null
		else Vector2.ZERO
	)
	_expect(
		transfer_flyer != null
		and transfer_start.distance_to(shifted_fire_anchor) < 0.2
		and transfer_start.distance_to(fire_anchor_before_discard) > 8.0
		and transfer_landing == retained_bench
		and transfer_finish.distance_to(prospective_transfer_anchor) < 0.2,
		(
			"post-discard transfer used a stale source or final-slot landing anchor "
			+ "(start=%s shifted=%s old=%s landing=%s retained=%s finish=%s expected=%s)"
		) % [
			transfer_start,
			shifted_fire_anchor,
			fire_anchor_before_discard,
			transfer_landing,
			retained_bench,
			transfer_finish,
			prospective_transfer_anchor,
		],
	)
	await create_timer(0.18).timeout
	_expect(
		transfer_flyer != null
		and is_instance_valid(transfer_flyer)
		and (transfer_flyer.position + transfer_flyer.size * 0.5).distance_to(
			transfer_start,
		) > 5.0,
		"post-discard transfer flyer did not actually advance",
	)
	if not transfer_completion.is_finished():
		await transfer_completion.completed
	_expect(
		real_chain_bench.is_presentation_hidden()
		and int(battle._presentation_mask_counts.get(
			real_chain_bench.get_instance_id(),
			0,
		)) == chain_bench_mask,
		"transfer landing consumed the retained switch mask before its barrier",
	)
	battle._on_presentation_event_finished(chain_events[2])
	_expect(
		battle._presentation_slot_covers.is_empty()
		and battle._presentation_mask_counts.is_empty()
		and not real_chain_active.is_presentation_hidden()
		and not real_chain_bench.is_presentation_hidden(),
		"attachment batch left a retained cover or half-transparent target",
	)
	battle._clear_transient_visuals()

	# Attachment staging used to apply the same 12/8 cap before the generic card
	# motion path even saw the batch. Keep all physical indices so a large discard
	# or transfer can use the rolling scheduler instead of silently losing one.
	var dense_attachment_state := UIPreviewStateFactory.battle_state(20260814)
	dense_attachment_state.revision = 146
	dense_attachment_state.players[0].active = PokemonState.new("sv1-104")
	var dense_energy_ids: Array[String] = []
	var dense_indices: Array[int] = []
	for index in range(13):
		dense_energy_ids.append("sv1-ener-%d" % (index % 8 + 1))
		dense_indices.append(index)
	dense_attachment_state.players[0].active.energy_card_ids.assign(
		dense_energy_ids,
	)
	battle.update_view(
		dense_attachment_state, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var dense_attachment_event := {
		"event_id": "contract:attachment-overflow-batch",
		"event_type": "cards_discarded",
		"actor": 0,
		"source": {
			"player": 0,
			"slot": "active",
			"attachment_type": "energy",
			"index": 0,
		},
		"target": {"player": 0, "zone": "discard"},
		"amount": dense_energy_ids.size(),
		"data": {
			"player": 0,
			"card_ids": dense_energy_ids,
			"source_indices": dense_indices,
		},
	}
	var dense_attachment_events: Array[Dictionary] = [dense_attachment_event]
	battle._stage_attachment_source_proxies(dense_attachment_events)
	var dense_specs: Array = battle._presentation_attachment_source_specs.get(
		"contract:attachment-overflow-batch",
		[],
	)
	battle._activate_attachment_source_proxies(dense_attachment_event)
	var dense_proxies: Array = battle._presentation_attachment_source_proxies.get(
		"contract:attachment-overflow-batch",
		[],
	)
	_expect(
		dense_specs.size() == dense_energy_ids.size()
		and dense_proxies.size() == dense_energy_ids.size(),
		"Oversized attachment batch was truncated before entering the rolling scheduler",
	)
	battle._clear_attachment_source_proxies()


func _start_staged_event_motion(
	battle: Control,
	event: Dictionary,
	duration: float,
) -> PresentationDirector.EventCompletion:
	battle._on_presentation_event_started(event)
	var completion := PresentationDirector.EventCompletion.new(duration)
	battle._on_presentation_event_completion_requested(event, completion)
	battle._on_card_motion_requested(event, duration)
	return completion


func _event_motion_entity(battle: Control, event_id: String) -> Control:
	for entity in _motion_entities(battle):
		if (
			str(entity.get_meta("motion_event_id", "")) == event_id
			and not bool(entity.get_meta("slot_composite_motion", false))
		):
			return entity
	return null


func _run_slot_visual_transaction_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260730)
	before.revision = 130
	before.action_log = ["事务前日志"]
	before.players[0].active = PokemonState.new("sv1-104")
	before.players[0].active.energy_card_ids = ["sv1-ener-5"]
	before.players[0].bench[0] = PokemonState.new("svi-chim")
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var snapshot: Dictionary = battle.capture_presentation_snapshot()
	var after := before.clone_state()
	after.revision = 131
	after.action_log.append("不应提前出现的事务后日志")
	after.players[0].active.damage_counters = 3
	after.players[0].active.energy_card_ids.clear()
	var previous_active := after.players[0].active
	after.players[0].active = after.players[0].bench[0]
	after.players[0].bench[0] = previous_active
	var events: Array[Dictionary] = PresentationEvent.normalize_all([
		{
			"event_id": "contract:slot:damage",
			"event_type": "damage_dealt",
			"actor": 1,
			"amount": 30,
			"target": {"player": 0, "slot": "active"},
			"data": {"player": 0, "slot": "active", "amount": 30},
		},
		{
			"event_id": "contract:slot:discard",
			"event_type": "cards_discarded",
			"actor": 0,
			"source": {
				"player": 0,
				"slot": "active",
				"attachment_type": "energy",
				"index": 0,
			},
			"target": {"player": 0, "zone": "discard"},
			"amount": 1,
			"data": {"player": 0, "card_ids": ["sv1-ener-5"], "count": 1},
		},
		{
			"event_id": "contract:slot:retreat",
			"event_type": "retreat",
			"actor": 0,
			"data": {"player": 0, "bench_idx": 0, "slot": "bench_0"},
		},
	], 131, 0)
	battle.update_view(after, 0, empty_rows, "", false, "test")
	battle._stage_presentation_targets(events, snapshot)
	var active_cover := battle._presentation_slot_covers.get(
		"0:active",
	) as CardView
	var active_cover_state := battle._presentation_slot_cover_states.get(
		"0:active",
	) as PokemonState
	_expect(
		active_cover != null
		and active_cover_state != null
		and active_cover_state.damage_counters == 0
		and active_cover_state.energy_card_ids == ["sv1-ener-5"],
		"slot transaction exposed final damage/retreat state before its event",
	)
	_expect(
		battle.log_panel.log_label != null
		and not battle.log_panel.log_label.text.contains("事务后日志"),
		"battle log committed the final action before presentation contact",
	)
	battle._on_presentation_event_started(events[0])
	_expect(
		active_cover_state.damage_counters == 3,
		"damage cover did not commit counters on the impact event",
	)
	battle._on_presentation_event_finished(events[0])
	_expect(
		battle._presentation_slot_covers.has("0:active"),
		"damage cover disappeared before the later retreat sequence",
	)
	battle._on_presentation_event_started(events[1])
	battle._on_presentation_event_finished(events[1])
	var retreat_source_row: Dictionary = battle._snapshot_slot_row(0, "active")
	var retreat_source_state: Dictionary = retreat_source_row.get("pokemon", {})
	_expect(
		active_cover_state.energy_card_ids.is_empty()
		and Array(retreat_source_state.get("energy_card_ids", [])).is_empty()
		and battle._presentation_slot_covers.has("0:active"),
		"retreat cost did not advance the visual source state before movement",
	)
	battle._on_presentation_event_started(events[2])
	_expect(
		battle._presentation_slot_covers.has("0:active")
		and battle._presentation_slot_covers.has("0:bench_0"),
		"retreat released its composite slot covers before motion claimed them",
	)
	var retreat_flyer_start_count: int = battle._active_flyers.size()
	var retreat_spawned: bool = battle._spawn_slot_transition(
		events[2],
		0.46,
		str(events[2].get("event_id", "")),
	)
	var retreat_flyer_count: int = (
		battle._active_flyers.size() - retreat_flyer_start_count
	)
	_expect(
		retreat_spawned and retreat_flyer_count == 2,
		"paid retreat energy was launched again as a ghost attachment (%d flyers)"
		% retreat_flyer_count,
	)
	var retreat_movers := _slot_composite_movers(battle)
	var retreat_active_mover: CardView
	var retreat_z: Dictionary = {}
	var retreat_is_composite := retreat_movers.size() == 2
	for mover in retreat_movers:
		retreat_is_composite = (
			retreat_is_composite
			and mover.get_node_or_null("PaperImage") == null
			and mover.pokemon != null
		)
		retreat_z[mover.z_index] = true
		if str(mover.get_meta("slot_composite_from", "")) == "active":
			retreat_active_mover = mover
	_expect(
		retreat_is_composite
		and retreat_z.size() == 2
		and retreat_active_mover != null
		and retreat_active_mover.pokemon.energy_card_ids.is_empty(),
		"retreat did not move two complete, uniquely layered Pokemon stacks",
	)
	if retreat_movers.size() == 2:
		var first_start := Vector2(retreat_movers[0].get_meta("motion_start"))
		var first_finish := Vector2(retreat_movers[0].get_meta("motion_finish"))
		var second_start := Vector2(retreat_movers[1].get_meta("motion_start"))
		var second_finish := Vector2(retreat_movers[1].get_meta("motion_finish"))
		var first_control: Vector2 = battle._slot_composite_control_point(
			first_start,
			first_finish,
			float(retreat_movers[0].get_meta("slot_composite_lane_offset", 0.0)),
		)
		var second_control: Vector2 = battle._slot_composite_control_point(
			second_start,
			second_finish,
			float(retreat_movers[1].get_meta("slot_composite_lane_offset", 0.0)),
		)
		_expect(
			first_control.distance_to(second_control) > 50.0,
			"bidirectional retreat movers still shared the same collision lane",
		)
		for mover in retreat_movers:
			battle._update_slot_composite_motion(
				0.5,
				mover,
				Vector2(mover.get_meta("motion_start")),
				Vector2(mover.get_meta("motion_finish")),
				float(mover.get_meta("slot_composite_lane_offset", 0.0)),
				float(mover.get_meta("slot_composite_start_rotation", 0.0)),
			)
		var first_midpoint_bounds := retreat_movers[0].visual_global_bounds()
		var second_midpoint_bounds := retreat_movers[1].visual_global_bounds()
		_expect(
			not first_midpoint_bounds.intersects(second_midpoint_bounds),
			(
				"bidirectional retreat composite bounds overlapped at 50%% "
				+ "(%s vs %s)"
			) % [first_midpoint_bounds, second_midpoint_bounds],
		)
		var retarget_probe := retreat_movers[0]
		var retarget_view := retarget_probe.get_meta(
			"motion_landing_view",
			null,
		) as CardView
		if retarget_view != null:
			var original_target_position: Vector2 = retarget_view.position
			battle._update_slot_composite_motion(
				0.5,
				retarget_probe,
				Vector2(retarget_probe.get_meta("motion_start")),
				Vector2(retarget_probe.get_meta("motion_finish")),
				float(retarget_probe.get_meta("slot_composite_lane_offset", 0.0)),
				float(retarget_probe.get_meta("slot_composite_start_rotation", 0.0)),
			)
			var center_before_retarget: Vector2 = retarget_probe.position + retarget_probe.size * 0.5
			retarget_view.position += Vector2(40.0, 0.0)
			battle._update_slot_composite_motion(
				0.5,
				retarget_probe,
				Vector2(retarget_probe.get_meta("motion_start")),
				Vector2(retarget_probe.get_meta("motion_finish")),
				float(retarget_probe.get_meta("slot_composite_lane_offset", 0.0)),
				float(retarget_probe.get_meta("slot_composite_start_rotation", 0.0)),
			)
			var center_after_retarget: Vector2 = retarget_probe.position + retarget_probe.size * 0.5
			retarget_view.position = original_target_position
			_expect(
				center_after_retarget.distance_to(center_before_retarget) > 8.0,
				"slot composite kept a stale landing point after target layout moved",
			)
	_expect(
		retreat_movers.is_empty()
		or _maximum_visible_canvas_z(retreat_movers[0])
		< _effective_canvas_z(battle.world_feedback),
		"slot composite rendered above world feedback",
	)
	battle._clear_transient_visuals()

	var attach_switch_before := UIPreviewStateFactory.battle_state(20260807)
	attach_switch_before.revision = 134
	attach_switch_before.players[0].active = PokemonState.new("sv1-104")
	attach_switch_before.players[0].active.energy_card_ids.assign([
		"sv1-ener-1",
		"sv1-ener-2",
		"sv1-ener-3",
		"sv1-ener-4",
		"sv1-ener-5",
		"sv1-ener-6",
		"sv1-ener-7",
		"sv1-ener-8",
	])
	attach_switch_before.players[0].active.attached_tool_id = "sv1-202"
	attach_switch_before.players[0].bench[0] = PokemonState.new("svi-chim")
	attach_switch_before.players[0].discard = ["sv1-ener-5"]
	battle.update_view(attach_switch_before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var attach_switch_snapshot: Dictionary = battle.capture_presentation_snapshot()
	var attach_switch_after := attach_switch_before.clone_state()
	attach_switch_after.revision = 135
	attach_switch_after.players[0].discard.clear()
	attach_switch_after.players[0].active.energy_card_ids.append("sv1-ener-5")
	var attached_active := attach_switch_after.players[0].active
	attach_switch_after.players[0].active = attach_switch_after.players[0].bench[0]
	attach_switch_after.players[0].bench[0] = attached_active
	var attach_switch_events: Array[Dictionary] = PresentationEvent.normalize_all([
		{
			"event_id": "contract:slot:attach-before-switch",
			"event_type": "energy_attached",
			"actor": 0,
			"card_id": "sv1-ener-5",
			"source": {"player": 0, "zone": "discard", "index": 0},
			"target": {"player": 0, "slot": "active"},
			"data": {
				"player": 0,
				"slot": "active",
				"card_id": "sv1-ener-5",
				"card_ids": ["sv1-ener-5"],
			},
		},
		{
			"event_id": "contract:slot:switch-after-attach",
			"event_type": "switched",
			"actor": 0,
			"data": {"player": 0, "slot": "bench_0"},
		},
	], 135, 0)
	battle.update_view(attach_switch_after, 0, empty_rows, "", false, "test")
	battle._stage_presentation_targets(
		attach_switch_events,
		attach_switch_snapshot,
	)
	battle._on_presentation_event_started(attach_switch_events[0])
	battle._on_presentation_event_finished(attach_switch_events[0])
	var attached_source_row: Dictionary = battle._snapshot_slot_row(0, "active")
	var attached_source_state: Dictionary = attached_source_row.get("pokemon", {})
	_expect(
		Array(attached_source_state.get("energy_card_ids", [])).size() == 9
		and Array(attached_source_state.get("energy_card_ids", [])).count(
			"sv1-ener-5",
		) == 2,
		"attached energy was not committed to the next movement source snapshot",
	)
	battle._on_presentation_event_started(attach_switch_events[1])
	_expect(
		battle._presentation_slot_covers.has("0:active")
		and battle._presentation_slot_covers.has("0:bench_0"),
		"switch released the attached composite before its motion request",
	)
	var switch_flyer_start_count: int = battle._active_flyers.size()
	var switch_spawned: bool = battle._spawn_slot_transition(
		attach_switch_events[1],
		0.46,
		str(attach_switch_events[1].get("event_id", "")),
	)
	var switch_flyer_count: int = (
		battle._active_flyers.size() - switch_flyer_start_count
	)
	_expect(
		switch_spawned and switch_flyer_count == 2,
		"switch split an attached energy into a paper-card flyer (%d movers)"
		% switch_flyer_count,
	)
	var switch_movers := _slot_composite_movers(battle)
	var attached_composite_found := false
	var switch_contains_paper_attachment := false
	for mover in switch_movers:
		if mover.get_node_or_null("PaperImage") != null:
			switch_contains_paper_attachment = true
		if (
			str(mover.get_meta("slot_composite_from", "")) == "active"
			and mover.pokemon != null
			and mover.pokemon.energy_card_ids.size() == 9
			and mover.pokemon.energy_card_ids.count("sv1-ener-5") == 2
			and mover.pokemon.attached_tool_id == "sv1-202"
		):
			attached_composite_found = true
	_expect(
		switch_movers.size() == 2
		and attached_composite_found
		and not switch_contains_paper_attachment,
		"energy attached earlier in the batch did not remain a badge on its composite Pokemon",
	)
	battle._clear_transient_visuals()

	var promotion_before := UIPreviewStateFactory.battle_state(20260808)
	promotion_before.revision = 136
	promotion_before.players[0].active = null
	promotion_before.players[0].bench[0] = PokemonState.new("svi-chim")
	promotion_before.players[0].bench[0].energy_card_ids.assign(["sv1-ener-2"])
	promotion_before.players[0].discard = ["sv1-ener-5"]
	battle.update_view(promotion_before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var promotion_snapshot: Dictionary = battle.capture_presentation_snapshot()
	var promotion_after := promotion_before.clone_state()
	promotion_after.revision = 137
	promotion_after.players[0].active = promotion_after.players[0].bench[0]
	promotion_after.players[0].bench[0] = null
	promotion_after.players[0].active.damage_counters = 3
	promotion_after.players[0].active.energy_card_ids.append("sv1-ener-5")
	promotion_after.players[0].discard.clear()
	var promotion_events: Array[Dictionary] = PresentationEvent.normalize_all([
		{
			"event_id": "contract:slot:promotion-composite",
			"event_type": "promoted",
			"actor": 0,
			"data": {"player": 0, "bench_idx": 0, "slot": "bench_0"},
		},
		{
			"event_id": "contract:slot:damage-after-promotion",
			"event_type": "damage_dealt",
			"actor": 1,
			"amount": 30,
			"target": {"player": 0, "slot": "active"},
			"data": {"player": 0, "slot": "active", "amount": 30},
		},
		{
			"event_id": "contract:slot:attach-after-promotion",
			"event_type": "energy_attached",
			"actor": 0,
			"card_id": "sv1-ener-5",
			"source": {"player": 0, "zone": "discard", "index": 0},
			"target": {"player": 0, "slot": "active"},
			"data": {
				"player": 0,
				"slot": "active",
				"card_ids": ["sv1-ener-5"],
			},
		},
	], 137, 0)
	var promotion_event: Dictionary = promotion_events[0]
	battle.update_view(promotion_after, 0, empty_rows, "", false, "test")
	battle._stage_presentation_targets(promotion_events, promotion_snapshot)
	battle._on_presentation_event_started(promotion_event)
	var promotion_start_count: int = battle._active_flyers.size()
	var promotion_spawned: bool = battle._spawn_slot_transition(
		promotion_event,
		0.46,
		str(promotion_event.get("event_id", "")),
	)
	var promotion_movers := _slot_composite_movers(battle)
	_expect(
		promotion_spawned
		and battle._active_flyers.size() - promotion_start_count == 1
		and promotion_movers.size() == 1
		and promotion_movers[0].pokemon != null
		and promotion_movers[0].pokemon.energy_card_ids == ["sv1-ener-2"]
		and promotion_movers[0].get_node_or_null("PaperImage") == null
		and Array(promotion_movers[0].get_meta(
			"slot_composite_remaining_queue",
			[],
		)).size() == 2,
		"promotion did not use exactly one complete Pokemon composite",
	)
	if not promotion_movers.is_empty():
		var promotion_tween := battle._flyer_tweens.get(
			promotion_movers[0].get_instance_id(),
		) as Tween
		if promotion_tween != null and promotion_tween.is_valid():
			promotion_tween.kill()
		battle._finish_retained_slot_composite(
			promotion_movers[0],
			promotion_movers[0].get_meta("motion_landing_view") as CardView,
			"0:active",
			Array(promotion_movers[0].get_meta("slot_composite_remaining_queue", [])),
			Vector2(promotion_movers[0].get_meta("motion_finish")),
			"promoted",
		)
	battle._on_presentation_event_finished(promotion_events[0])
	var promoted_cover_state := battle._presentation_slot_cover_states.get(
		"0:active",
	) as PokemonState
	_expect(
		promoted_cover_state != null
		and promoted_cover_state.damage_counters == 0
		and promoted_cover_state.energy_card_ids == ["sv1-ener-2"],
		"empty active destination lost its planned post-promotion mutation queue",
	)
	battle._on_presentation_event_started(promotion_events[1])
	battle._on_presentation_event_finished(promotion_events[1])
	battle._on_presentation_event_started(promotion_events[2])
	battle._on_presentation_event_finished(promotion_events[2])
	var promoted_real_view: CardView = battle.get_slot_view(0, "active")
	_expect(
		not battle._presentation_slot_covers.has("0:active")
		and promoted_real_view != null
		and not promoted_real_view.is_presentation_hidden(),
		"promotion mutation tail did not release the final active CardView",
	)
	battle._clear_transient_visuals()

	var chained_before := UIPreviewStateFactory.battle_state(20260809)
	chained_before.revision = 138
	chained_before.players[0].active = PokemonState.new("sv1-104")
	chained_before.players[0].bench[0] = PokemonState.new("svi-chim")
	chained_before.players[0].discard = ["sv1-ener-2"]
	battle.update_view(chained_before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var chained_snapshot: Dictionary = battle.capture_presentation_snapshot()
	var chained_after := chained_before.clone_state()
	chained_after.revision = 139
	var chained_old_active := chained_after.players[0].active
	chained_after.players[0].active = chained_after.players[0].bench[0]
	chained_after.players[0].bench[0] = chained_old_active
	chained_after.players[0].active.damage_counters = 3
	chained_after.players[0].active.energy_card_ids.append("sv1-ener-2")
	chained_after.players[0].discard.clear()
	var chained_events: Array[Dictionary] = PresentationEvent.normalize_all([
		{
			"event_id": "contract:slot:switch-before-mutations",
			"event_type": "switched",
			"actor": 0,
			"data": {"player": 0, "slot": "bench_0"},
		},
		{
			"event_id": "contract:slot:damage-after-switch",
			"event_type": "damage_dealt",
			"actor": 1,
			"amount": 30,
			"target": {"player": 0, "slot": "active"},
			"data": {"player": 0, "slot": "active", "amount": 30},
		},
		{
			"event_id": "contract:slot:attach-after-switch",
			"event_type": "energy_attached",
			"actor": 0,
			"card_id": "sv1-ener-2",
			"source": {"player": 0, "zone": "discard", "index": 0},
			"target": {"player": 0, "slot": "active"},
			"data": {
				"player": 0,
				"slot": "active",
				"card_id": "sv1-ener-2",
				"card_ids": ["sv1-ener-2"],
			},
		},
	], 139, 0)
	battle.update_view(chained_after, 0, empty_rows, "", false, "test")
	battle._stage_presentation_targets(chained_events, chained_snapshot)
	battle._on_presentation_event_started(chained_events[0])
	battle._spawn_slot_transition(
		chained_events[0],
		0.46,
		str(chained_events[0].get("event_id", "")),
	)
	var chained_active_mover: CardView
	for mover in _slot_composite_movers(battle):
		if str(mover.get_meta("slot_composite_to", "")) == "active":
			chained_active_mover = mover
			break
	_expect(
		chained_active_mover != null
		and Array(chained_active_mover.get_meta(
			"slot_composite_remaining_queue",
			[],
		)).size() == 2,
		"switch did not preserve the destination slot's later mutation queue",
	)
	if chained_active_mover != null:
		var chained_tween := battle._flyer_tweens.get(
			chained_active_mover.get_instance_id(),
		) as Tween
		if chained_tween != null and chained_tween.is_valid():
			chained_tween.kill()
		battle._finish_retained_slot_composite(
			chained_active_mover,
			chained_active_mover.get_meta("motion_landing_view") as CardView,
			"0:active",
			Array(chained_active_mover.get_meta("slot_composite_remaining_queue", [])),
			Vector2(chained_active_mover.get_meta("motion_finish")),
			"switched",
		)
	battle._on_presentation_event_finished(chained_events[0])
	var chained_cover_state := battle._presentation_slot_cover_states.get(
		"0:active",
	) as PokemonState
	var chained_snapshot_state: Dictionary = battle._snapshot_slot_row(
		0,
		"active",
	).get("pokemon", {})
	_expect(
		chained_cover_state != null
		and chained_cover_state.card_id == "svi-chim"
		and chained_cover_state.damage_counters == 0
		and chained_cover_state.energy_card_ids.is_empty()
		and str(chained_snapshot_state.get("card_id", "")) == "svi-chim",
		"switch landing did not remap the incoming Pokemon cover/snapshot before later mutations",
	)
	battle._on_presentation_event_started(chained_events[1])
	_expect(
		chained_cover_state != null
		and chained_cover_state.damage_counters == 3
		and battle.get_slot_view(0, "active").is_presentation_hidden(),
		"post-switch damage bypassed the retained incoming-Pokemon cover",
	)
	battle._on_presentation_event_finished(chained_events[1])
	_expect(
		battle._presentation_slot_covers.has("0:active"),
		"post-switch cover released before the later attachment event",
	)
	battle._on_presentation_event_started(chained_events[2])
	battle._on_presentation_event_finished(chained_events[2])
	var chained_real_view: CardView = battle.get_slot_view(0, "active")
	_expect(
		not battle._presentation_slot_covers.has("0:active")
		and chained_real_view != null
		and not chained_real_view.is_presentation_hidden()
		and chained_real_view.modulate.a > 0.99,
		"post-switch mutation queue did not hand off its final state cleanly",
	)
	battle._clear_transient_visuals()

	var ko_before := UIPreviewStateFactory.battle_state(20260731)
	ko_before.revision = 132
	ko_before.players[1].active = PokemonState.new("sv1-104")
	ko_before.players[1].active.attached_tool_id = "sv1-202"
	ko_before.players[1].active.energy_card_ids = [
		"sv1-ener-4",
		"sv1-ener-5",
	]
	battle.update_view(ko_before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	var ko_snapshot: Dictionary = battle.capture_presentation_snapshot()
	var ko_after := ko_before.clone_state()
	ko_after.revision = 133
	ko_after.players[1].active = null
	ko_after.players[1].discard.append_array([
		"sv1-104",
		"sv1-202",
		"sv1-ener-4",
		"sv1-ener-5",
	])
	var ko_events: Array[Dictionary] = PresentationEvent.normalize_all([
		{
			"event_id": "contract:slot:ko-damage",
			"event_type": "damage_dealt",
			"actor": 0,
			"amount": 120,
			"target": {"player": 1, "slot": "active"},
			"data": {"player": 1, "slot": "active", "amount": 120},
		},
		{
			"event_id": "contract:slot:ko",
			"event_type": "pokemon_ko",
			"actor": 1,
			"source": {"player": 1, "slot": "active"},
			"target": {"player": 1, "slot": "active"},
			"amount": 4,
			"data": {
				"player": 1,
				"slot": "active",
				"defer_leave_play": true,
				"card_ids": ["sv1-104", "sv1-202", "sv1-ener-4", "sv1-ener-5"],
			},
		},
		{
			"event_id": "contract:slot:ko-leave",
			"event_type": "card_moved",
			"actor": 1,
			"source": {"player": 1, "slot": "active"},
			"target": {"player": 1, "zone": "discard"},
			"amount": 4,
			"data": {
				"player": 1,
				"slot": "active",
				"ko_leave_play": true,
				"card_ids": ["sv1-104", "sv1-202", "sv1-ener-4", "sv1-ener-5"],
			},
		},
	], 133, 0)
	battle.update_view(ko_after, 0, empty_rows, "", false, "test")
	battle._stage_presentation_targets(ko_events, ko_snapshot)
	var ko_cover_state := battle._presentation_slot_cover_states.get(
		"1:active",
	) as PokemonState
	var source_endpoint := {"player": 1, "slot": "active"}
	var component_ids := ["sv1-104", "sv1-202", "sv1-ener-4", "sv1-ener-5"]
	var component_points: Array[Vector2] = battle._source_points_for_event(
		source_endpoint,
		component_ids,
		component_ids.size(),
		Vector2.ZERO,
	)
	var component_sizes: Array[Vector2] = battle._source_sizes_for_event(
		source_endpoint,
		component_ids,
		component_ids.size(),
		Vector2(94.0, 132.0),
	)
	var slot_row: Dictionary = ko_snapshot.get("slots", {}).get("1:active", {})
	var attachment_centers: Dictionary = slot_row.get("attachment_centers", {})
	_expect(
		component_points.size() == 4
		and component_points[1].distance_to(
			attachment_centers.get("tool:sv1-202", Vector2.ZERO)) < 0.1
		and component_points[2].distance_to(
			attachment_centers.get("energy:sv1-ener-4", Vector2.ZERO)) < 0.1
		and component_points[3].distance_to(
			attachment_centers.get("energy:sv1-ener-5", Vector2.ZERO)) < 0.1
		and component_sizes[1].y < component_sizes[0].y
		and component_sizes[2].y < component_sizes[0].y
		and absf(component_sizes[1].x - component_sizes[1].y) < 0.1
		and absf(component_sizes[2].x - component_sizes[2].y) < 0.1,
		"KO components did not leave from their rendered badges at attachment size",
	)
	_expect(
		battle._public_motion_texture_for_card_id(
			"contract-missing-public-attachment",
		) != battle._texture_for_card_id(""),
		"public missing attachment art still masqueraded as a concealed card back",
	)
	battle._on_presentation_event_started(ko_events[0])
	battle._on_presentation_event_finished(ko_events[0])
	_expect(
		ko_cover_state != null
		and ko_cover_state.damage_counters == 12
		and battle._presentation_slot_covers.has("1:active"),
		"KO target disappeared before its damage/impact completed",
	)
	battle._on_presentation_event_started(ko_events[1])
	_expect(
		battle._presentation_slot_covers.has("1:active"),
		"KO source cover disappeared before KO feedback could hit the old stack",
	)
	battle._on_card_motion_requested(ko_events[1], 0.24)
	_expect(
		battle._presentation_slot_covers.has("1:active"),
		"Deferred KO declaration incorrectly started leave-play motion",
	)
	battle._on_presentation_event_finished(ko_events[1])
	battle._on_presentation_event_started(ko_events[2])
	_expect(
		not battle._presentation_slot_covers.has("1:active"),
		"KO source cover remained over the explicit leave-play motion",
	)
	battle._clear_transient_visuals()


func _run_prize_stack_transaction_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260801)
	before.revision = 134
	before.players[0].prizes = ["sv1-104", "sv1-151"]
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	var snapshot: Dictionary = battle.capture_presentation_snapshot()
	var after := before.clone_state()
	after.revision = 135
	after.players[0].hand.append_array(after.players[0].prizes)
	after.players[0].prizes.clear()
	var events: Array[Dictionary] = PresentationEvent.normalize_all([
		{
			"event_id": "contract:prize:first",
			"event_type": "prize_taken",
			"actor": 0,
			"amount": 1,
			"data": {"player": 0, "count": 1, "card_ids": ["sv1-151"]},
		},
		{
			"event_id": "contract:prize:second",
			"event_type": "prize_taken",
			"actor": 0,
			"amount": 1,
			"data": {"player": 0, "count": 1, "card_ids": ["sv1-104"]},
		},
	], 135, 0)
	battle.update_view(after, 0, empty_rows, "", false, "test")
	battle._stage_presentation_targets(events, snapshot)
	var endpoint := {"player": 0, "zone": "prizes"}
	var first_offset: Vector2 = battle._zone_motion_offset(endpoint, 0, 1, true)
	battle._apply_presentation_zone_event(events[0])
	var second_offset: Vector2 = battle._zone_motion_offset(endpoint, 0, 1, true)
	_expect(
		first_offset.distance_to(second_offset) > 2.0
		and first_offset.length() > second_offset.length(),
		"consecutive prizes reused the same source fan slot",
	)
	battle._clear_transient_visuals()


func _run_local_handoff_contract() -> void:
	var main_scene := load("res://scenes/main/main.tscn") as PackedScene
	_expect(main_scene != null, "Main scene is unavailable for local handoff contract")
	if main_scene == null:
		return
	var ui := main_scene.instantiate()
	root.add_child(ui)
	ui.initialize_ui()
	ui.game_mode = "local"

	# The first SETUP_DONE only changes setup ownership and deliberately emits no
	# presentation event.  The handoff must therefore be atomic: never render the
	# ready player on an inert "waiting for opponent" screen while a deferred empty
	# transition is expected to open the privacy gate later.  Exercise player 2 as
	# the first player because that is the asymmetric field/view arrangement that
	# exposed the live regression.
	var ready_state := GameState.new()
	ready_state.revision = 78
	ready_state.phase = "SETUP"
	ready_state.turn_number = 1
	ready_state.first_player_idx = 1
	ready_state.active_player_idx = 1
	ready_state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	ready_state.setup_actor_idx = 1
	ready_state.setup_ready = [false, false]
	ready_state.players[1].active = PokemonState.new("svi-chim")
	ready_state.players[0].hand = ["sv1-ener-1"]
	ready_state.players[1].hand = ["sv1-ener-2"]
	ui.state = ready_state
	ui.current_view_player = 1
	ui._build_game_screen()
	var ready_result: StepResult = ui._execute_action_now(
		GameAction.create("SETUP_DONE", {}, 1, null, null, "", 78),
	)
	_expect(
		ready_result.success
		and ready_result.events.is_empty()
		and ui.state.setup_ready == [false, true]
		and ui.state.setup_actor_idx == 0
		and ui.current_view_player == 0
		and ui.modal_layer.visible
		and ui.modal_title.text == "准备阶段"
		and not ui.modal_confirm.disabled
		and ui.battle_screen._local_hand_privacy_hidden
		and not ui.battle_screen.hand_scroll.visible
		and not ui.battle_screen.is_presentation_busy(),
		(
			"Eventless player-2 setup completion exposed or stranded the ready player's waiting view "
			+ "success=%s message=%s events=%d ready=%s actor=%d view=%d modal=%s title=%s "
			+ "confirm_disabled=%s privacy=%s hand=%s busy=%s"
		) % [
			str(ready_result.success),
			ready_result.message,
			ready_result.events.size(),
			str(ui.state.setup_ready),
			ui.state.setup_actor_idx,
			ui.current_view_player,
			str(ui.modal_layer.visible),
			ui.modal_title.text,
			str(ui.modal_confirm.disabled),
			str(ui.battle_screen._local_hand_privacy_hidden),
			str(ui.battle_screen.hand_scroll.visible),
			str(ui.battle_screen.is_presentation_busy()),
		],
	)
	ui.modal_confirm.pressed.emit()
	await create_timer(0.18).timeout
	_expect(
		not ui.modal_layer.visible
		and not ui.battle_screen._local_hand_privacy_hidden,
		"Eventless setup handoff privacy gate did not release to the next player modal=%s privacy=%s"
		% [
			str(ui.modal_layer.visible),
			str(ui.battle_screen._local_hand_privacy_hidden),
		],
	)

	# Completing setup does not change active_player_idx: turn order was already
	# chosen before opening hands were dealt. The first turn still needs the same
	# privacy gate and pre-draw view as every later hot-seat handoff.
	var opening_state := UIPreviewStateFactory.battle_state(20260719)
	opening_state.revision = 79
	opening_state.active_player_idx = 0
	opening_state.first_player_idx = 0
	opening_state.turn_number = 1
	opening_state.phase = "MAIN"
	opening_state.setup_stage = GameState.SETUP_COMPLETE
	opening_state.players[0].hand = ["svi-chim", "sv1-151"]
	opening_state.players[0].deck = ["sv1-ener-1", "sv1-ener-2"]
	opening_state.action_log.append("—— 玩家 1的第1回合 ——")
	ui.state = opening_state
	ui.current_view_player = 1
	var opening_events: Array[Dictionary] = [
		{
			"event_type": "setup_revealed",
			"data": {"first_player": 0, "players": []},
		},
		{
			"event_type": "turn_start",
			"actor": 0,
			"target": {"player": 0, "slot": "active"},
			"data": {"player": 0, "turn": 1},
		},
		{
			"event_type": "cards_drawn",
			"actor": 0,
			"card_id": "sv1-151",
			"visibility": "owner",
			"source": {"player": 0, "zone": "deck"},
			"target": {"player": 0, "zone": "hand"},
			"data": {
				"player": 0,
				"count": 1,
				"card_ids": ["sv1-151"],
				"purpose": "turn_draw",
				"turn": 1,
			},
		},
	]
	var opening_plan: Dictionary = ui._build_local_handoff_plan(
		opening_events,
		0,
		"SETUP",
	)
	var opening_incoming_view := opening_plan.get(
		"incoming_view",
	) as BattleViewModel
	var opening_pre_draw := (
		opening_incoming_view.state_for_render()
		if opening_incoming_view != null
		else null
	) as GameState
	_expect(
		not opening_plan.is_empty()
		and _event_types(opening_plan.get("prefix_events", []))
		== ["setup_revealed"]
		and _event_types(opening_plan.get("suffix_events", []))
		== ["turn_start", "cards_drawn"]
		and int(opening_plan.get("incoming_player", -1)) == 0
		and opening_pre_draw != null
		and opening_pre_draw.phase == "DRAW"
		and opening_pre_draw.players[0].hand == ["svi-chim"],
		"First SETUP-to-MAIN turn did not stage privacy, announcement, then draw",
	)

	var final_state := UIPreviewStateFactory.battle_state(20260720)
	final_state.revision = 80
	final_state.winner = -1
	final_state.active_player_idx = 1
	final_state.turn_number = 4
	final_state.phase = "MAIN"
	final_state.players[1].hand = ["svi-chim", "sv1-151"]
	final_state.players[1].deck = ["sv1-ener-1", "sv1-ener-2"]
	final_state.action_log.append("—— 玩家 2的第4回合 ——")
	ui.state = final_state
	ui.current_view_player = 0

	var raw_events: Array[Dictionary] = [
		{
			"event_type": "promoted",
			"actor": 0,
			"source": {"player": 0, "slot": "bench_0"},
			"target": {"player": 0, "slot": "active"},
			"data": {"player": 0, "bench_idx": 0, "slot": "bench_0"},
		},
		{
			"event_type": "turn_start",
			"actor": 1,
			"target": {"player": 1, "slot": "active"},
			"data": {"player": 1, "turn": 4},
		},
		{
			"event_type": "cards_drawn",
			"actor": 1,
			"card_id": "sv1-151",
			"visibility": "owner",
			"source": {"player": 1, "zone": "deck"},
			"target": {"player": 1, "zone": "hand"},
			"data": {
				"player": 1,
				"count": 1,
				"card_ids": ["sv1-151"],
				"purpose": "turn_draw",
				"turn": 4,
			},
		},
	]
	# Simulate simultaneous checkup KOs: the incoming player was already made
	# active before both promotions, and the outgoing player performs the second
	# promotion while still holding the hot-seat view.
	var plan: Dictionary = ui._build_local_handoff_plan(raw_events, 1, "DRAW")
	var prefix_events: Array = plan.get("prefix_events", [])
	var suffix_events: Array = plan.get("suffix_events", [])
	var outgoing_view := plan.get("outgoing_view") as BattleViewModel
	var incoming_view := plan.get("incoming_view") as BattleViewModel
	var outgoing_pre_draw_view: GameState = (
		outgoing_view.state_for_render() if outgoing_view != null else null
	)
	var pre_draw_state: GameState = (
		incoming_view.state_for_render() if incoming_view != null else null
	)
	var authoritative_pre_draw: GameState = ui._state_before_handoff_draw(
		suffix_events,
		1,
	)
	_expect(
		not plan.is_empty()
		and _event_types(prefix_events) == ["promoted"]
		and _event_types(suffix_events) == ["turn_start", "cards_drawn"],
		"Local handoff plan did not split before the incoming turn announcement: prefix=%s suffix=%s"
		% [str(_event_types(prefix_events)), str(_event_types(suffix_events))],
	)
	_expect(
		outgoing_view != null
		and incoming_view != null
		and outgoing_view.view_player == 0
		and incoming_view.view_player == 1
		and authoritative_pre_draw != null
		and authoritative_pre_draw.phase == "DRAW"
		and authoritative_pre_draw.players[1].hand == ["svi-chim"]
		and authoritative_pre_draw.players[1].deck == [
			"sv1-ener-1", "sv1-ener-2", "sv1-151"
		]
		and pre_draw_state != null
		and pre_draw_state.phase == "DRAW"
		and pre_draw_state.players[1].hand == ["svi-chim"]
		and pre_draw_state.players[1].deck.size() == 3
		and pre_draw_state.players[1].deck.all(
			func(card_id: String) -> bool: return card_id.is_empty())
		and outgoing_pre_draw_view != null
		and outgoing_pre_draw_view.players[1].hand.size() == 1
		and outgoing_pre_draw_view.players[1].hand.all(
			func(card_id: String) -> bool: return card_id.is_empty())
		and outgoing_pre_draw_view.players[1].deck.size() == 3
		and outgoing_pre_draw_view.players[1].deck.all(
			func(card_id: String) -> bool: return card_id.is_empty())
		and final_state.players[1].hand == ["svi-chim", "sv1-151"]
		and final_state.players[1].deck == ["sv1-ener-1", "sv1-ener-2"],
		"Local handoff pre-draw state was not restored or its player views leaked",
	)

	ui._build_game_screen()
	await process_frame
	await process_frame


	var started_types: Array[String] = []
	var started_callback := func(event: Dictionary) -> void:
		started_types.append(str(event.get("event_type", "")))
	ui.battle_screen.director.event_started.connect(started_callback)
	var finished_types: Array[String] = []
	var finished_callback := func(event: Dictionary) -> void:
		finished_types.append(str(event.get("event_type", "")))
	ui.battle_screen.director.event_finished.connect(finished_callback)
	var suffix_submission := {"while_modal_visible": false}
	var transition_started_callback := func(_handle: PresentationHandle) -> void:
		suffix_submission["while_modal_visible"] = (
			bool(suffix_submission["while_modal_visible"]) or ui.modal_layer.visible
		)
	ui.battle_screen.transition_started.connect(transition_started_callback)
	var step := StepResult.new(true, "回合开始。", null, raw_events)
	ui._open_local_handoff_gate(
		step,
		plan,
		1,
		"DRAW",
		"contract:handoff",
		"",
		BattleTransitionRequest.CAUSE_LOCAL_ACTION,
	)
	var gated_state: GameState = ui.battle_screen.state_ref
	_expect(
		ui.modal_layer.visible
		and float(ui.modal_shade.color.a) >= 0.99
		and not ui.modal_confirm.disabled
		and not ui.battle_screen.is_presentation_busy()
		and started_types.is_empty(),
		"Local handoff gate was not fully opaque and ready before suffix submission",
	)
	_expect(
		gated_state != null
		and ui.current_view_player == 1
		and gated_state.players[1].hand == ["svi-chim"]
		and gated_state.players[1].deck.size() == 3
		and gated_state.players[1].deck.all(
			func(card_id: String) -> bool: return card_id.is_empty()),
		"Local handoff gate did not stage the incoming pre-draw view",
	)
	await process_frame
	await process_frame
	_expect(
		"turn_start" not in started_types
		and "cards_drawn" not in started_types
		and not ui.battle_screen.is_presentation_busy(),
		"Incoming turn presentation started before the privacy gate was confirmed",
	)

	var gate_was_visible_before_confirm: bool = ui.modal_layer.visible
	ui.modal_confirm.pressed.emit()
	_expect(
		gate_was_visible_before_confirm
		and ui.modal_layer.visible
		and not ui.battle_screen.is_presentation_busy(),
		"Confirm submitted the suffix before the privacy gate finished closing",
	)
	await create_timer(0.16).timeout
	_expect(
		not ui.modal_layer.visible
		and ui.battle_screen.is_presentation_busy()
		and not bool(suffix_submission["while_modal_visible"]),
		"Privacy-gated suffix did not start strictly after ModalLayer became hidden",
	)
	await _wait_for_director_event(started_types, "turn_start")
	var staged_turn_draw := _visible_hand_view_at_index(ui.battle_screen, 1)
	_expect(
		started_types == ["turn_start"]
		and "cards_drawn" not in started_types
		and finished_types.is_empty()
		and staged_turn_draw != null
		and staged_turn_draw.is_presentation_hidden(),
		(
			"Incoming draw became visible before the turn-start announcement finished "
			+ "(started=%s finished=%s view=%s hidden=%s)"
		) % [
			str(started_types),
			str(finished_types),
			str(staged_turn_draw),
			str(
				staged_turn_draw.is_presentation_hidden()
				if staged_turn_draw != null
				else false
			),
		],
	)
	await _wait_for_director_event(started_types, "cards_drawn")
	_expect(
		started_types == ["turn_start", "cards_drawn"]
		and "turn_start" in finished_types
		and ui.battle_screen.state_ref.players[1].hand
		== ["svi-chim", "sv1-151"],
		"Turn draw started before the turn-start announcement completion barrier",
	)
	await _wait_for_presentation_idle(ui.battle_screen)
	var landed_turn_draw := _visible_hand_view_at_index(ui.battle_screen, 1)
	_expect(
		_event_types(suffix_events) == started_types
		and landed_turn_draw != null
		and not landed_turn_draw.is_presentation_hidden(),
		"Local handoff suffix did not complete turn-start then draw presentation",
	)

	# A KO/Prize/trigger chain can hand the next Choice to the other player
	# without producing a turn_start event. Both action settlement and the shared
	# choice/cancel continuation must establish the same opaque handoff gate before
	# rendering that owner's view or opening the secret Choice UI.
	var chained_choice := ChoiceView.new(
		"contract:chained-choice:p0",
		ui.state.revision,
		"select_prize",
		0,
		"请选择1张奖赏卡。",
		[{"option_id": "prize:0", "label": "奖赏卡 1"}],
		1,
		1,
		false,
		false,
		{"domain": "knockout", "purpose": "select_prize"},
	)
	ui.current_view_player = 1
	ui.active_request = null
	ui.battle_screen.set_local_hand_privacy_hidden(false)
	ui._continue_after_choice_transition(
		StepResult.new(true, "继续选择。", chained_choice),
		ui.state.active_player_idx,
		ui.state.phase,
	)
	_expect(
		ui.current_view_player == 0
		and ui.modal_layer.visible
		and float(ui.modal_shade.color.a) >= 0.99
		and ui.modal_title.text == "规则选择"
		and ui.active_request == null
		and ui.battle_screen._local_hand_privacy_hidden
		and not ui.battle_screen.hand_scroll.visible,
		"Chained Choice owner change exposed the next player's view before its privacy gate",
	)
	await process_frame
	_expect(
		ui.active_request == null and ui.modal_title.text == "规则选择",
		"Chained Choice UI opened before the pass-device gate was confirmed",
	)
	ui.modal_confirm.pressed.emit()
	await create_timer(0.18).timeout
	_expect(
		ui.active_request == chained_choice
		and not ui.battle_screen._local_hand_privacy_hidden,
		"Confirmed chained Choice handoff did not open the new owner's request",
	)
	ui._close_modal()
	await create_timer(0.18).timeout

	var action_choice := ChoiceView.new(
		"contract:action-choice:p1",
		ui.state.revision,
		"confirm_trigger",
		1,
		"是否发动触发效果？",
		[{"option_id": "trigger:yes", "label": "发动"}],
		0,
		1,
		false,
		true,
		{"domain": "knockout", "purpose": "confirm_trigger"},
	)
	ui.current_view_player = 0
	ui.active_request = null
	ui._continue_after_player_transition(
		StepResult.new(true, "等待触发。", action_choice),
		ui.state.active_player_idx,
		ui.state.phase,
	)
	_expect(
		ui.current_view_player == 1
		and ui.modal_layer.visible
		and float(ui.modal_shade.color.a) >= 0.99
		and ui.modal_title.text == "规则选择"
		and ui.active_request == null
		and ui.battle_screen._local_hand_privacy_hidden,
		"Action-result Choice owner change bypassed the shared privacy gate",
	)
	ui.modal_confirm.pressed.emit()
	await create_timer(0.18).timeout
	_expect(
		ui.active_request == action_choice,
		"Action-result handoff did not open its Choice after gate confirmation",
	)
	ui._close_modal()
	await create_timer(0.18).timeout
	if ui.battle_screen.director.event_started.is_connected(started_callback):
		ui.battle_screen.director.event_started.disconnect(started_callback)
	if ui.battle_screen.director.event_finished.is_connected(finished_callback):
		ui.battle_screen.director.event_finished.disconnect(finished_callback)
	if ui.battle_screen.transition_started.is_connected(transition_started_callback):
		ui.battle_screen.transition_started.disconnect(transition_started_callback)
	ui.queue_free()
	await process_frame
	await process_frame


func _run_main_shell_flow_contract() -> void:
	var main_scene := load("res://scenes/main/main.tscn") as PackedScene
	_expect(main_scene != null, "Main scene is unavailable for shell flow contract")
	if main_scene == null:
		return
	var ui := main_scene.instantiate()
	root.add_child(ui)
	ui.initialize_ui()

	var coin_choice := ChoiceView.new(
		"contract:coin-modal",
		0,
		"coin_flip",
		0,
		"硬币结果",
		[],
		0,
		0,
		false,
		false,
		{"predetermined_flips": [true, false, true]},
	)
	ui._show_choice_overlay(coin_choice)
	_expect(
		ui.modal_layer.visible and ui.modal_confirm.disabled,
		"Coin result modal allowed continuation before its reveal animation",
	)
	# Three cinematic tosses run the full 0.90 s first toss and 0.55 s
	# follow-ups before the modal becomes actionable.
	await create_timer(2.72).timeout
	_expect(
		ui.modal_layer.visible and not ui.modal_confirm.disabled,
		"Coin result modal did not unlock after its real reveal animation",
	)
	var filtered_events: Array = ui._choice_presentation_events(
		coin_choice,
		[
			{"event_type": "coin_flip", "data": {"results": [true, false, true]}},
			{"event_type": "damage_dealt", "data": {"amount": 30}},
		],
	)
	_expect(
		_event_types(filtered_events) == ["damage_dealt"],
		"A locally revealed coin result was left queued for a duplicate world burst",
	)
	var close_completion := {"saw_hidden": false}
	ui._close_modal(func() -> void:
		close_completion["saw_hidden"] = not ui.modal_layer.visible
	)
	_expect(
		ui.modal_layer.visible and not bool(close_completion["saw_hidden"]),
		"Modal close continuation ran when close animation merely started",
	)
	await create_timer(0.16).timeout
	_expect(
		not ui.modal_layer.visible and bool(close_completion["saw_hidden"]),
		"Modal close continuation did not run after the shade became hidden",
	)

	var safe_rect := Rect2(0.0, 0.0, 900.0, 540.0)
	var opponent_hand_rect := Rect2(170.0, 18.0, 560.0, 150.0)
	var compact_toast: Rect2 = ui._toast_rect_outside_obstacle(
		Rect2(270.0, 28.0, 360.0, 64.0),
		opponent_hand_rect,
		safe_rect,
	)
	_expect(
		ui.toast_label.z_index == 350
		and not ui.toast_label.z_as_relative
		and safe_rect.encloses(compact_toast)
		and not compact_toast.intersects(opponent_hand_rect),
		"Compact battle toast can still render below or over the opponent hand",
	)

	var ai_state := UIPreviewStateFactory.battle_state(20260721)
	ai_state.revision = 90
	ai_state.phase = "MAIN"
	ai_state.active_player_idx = 1
	ui.state = ai_state
	ui.game_mode = "challenge"
	ui.current_view_player = 0
	ui._build_game_screen()
	await process_frame
	await process_frame


	var ai_barrier_handle: PresentationHandle = ui._submit_battle_transition(
		[{
			"event_type": "turn_end",
			"actor": 0,
			"data": {"player": 0},
		}],
		0,
		BattleTransitionRequest.CAUSE_LOCAL_ACTION,
	)
	ui._maybe_start_ai()
	_expect(
		ai_barrier_handle != null
		and ui.battle_screen.is_presentation_busy()
		and ui._pending_ai_resume_revision == ai_state.revision
		and not ui.ai_thinking,
		"AI resumed through the pause/menu path while presentation was still busy",
	)
	# Keep the contract from launching a real worker after the barrier opens.
	ai_state.active_player_idx = 0
	await _wait_for_handle(ai_barrier_handle, ui.battle_screen)
	await process_frame
	_expect(
		not ui.ai_thinking and ui._pending_ai_resume_revision < 0,
		"Deferred AI resume was not cleared safely after the presentation barrier",
	)
	ui.queue_free()
	await process_frame
	await process_frame


func _run_public_coin_contract(battle: Control) -> void:
	battle.play_presentation([{
		"event_type": "coin_flip",
		"actor": 1,
		"visibility": "public",
		"data": {"results": [false]},
	}], 91, 1)
	await process_frame
	await process_frame
	var showcase: CoinShowcase = battle.coin_showcase
	_expect(
		showcase != null
		and showcase.visible
		and showcase.results == [false]
		and battle.director.is_playing(),
		"Public coin event did not open the shared screen-space showcase",
	)
	await create_timer(0.25).timeout
	_expect(
		battle.director.is_playing(),
		"Public coin event bypassed its real-motion completion barrier",
	)
	var deadline := Time.get_ticks_msec() + 3000
	while battle.director.is_playing() and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(
		not battle.director.is_playing()
		and not showcase.visible
		and not battle.input_blocker.visible,
		"Public coin event did not release its barrier or clear its proxy",
	)


func _run_empty_public_reveal_contract(battle: Control, settings: Node) -> void:
	for mode in ["standard", "reduced"]:
		settings.set("animation_mode", mode)
		settings.set("reduced_motion", mode == "reduced")
		battle.play_presentation([{
			"event_type": "cards_revealed",
			"actor": 0,
			"visibility": "public",
			"source": {"player": 0, "zone": "deck"},
			"target": {"player": 0, "zone": "deck"},
			"data": {
				"player": 0,
				"cards": [],
				"summary": {
					"kind": "energy_damage",
					"matched_count": 0,
					"amount": 0,
				},
			},
		}], 92 if mode == "standard" else 93, 0)
		await process_frame
		await process_frame
		var showcase: Control = battle.reveal_layer._showcase as Control
		var summary := (
			showcase.get_node_or_null("RevealSummary") as Label
			if showcase != null
			else null
		)
		_expect(
			showcase != null
			and battle.reveal_layer.is_presenting()
			and Array(showcase.get_meta("reveal_cards", [])).is_empty()
			and summary != null
			and summary.text == "未翻到能量"
			and battle.director.is_playing(),
			"%s zero-card reveal did not show its semantic result" % mode,
		)
		var deadline := Time.get_ticks_msec() + 4500
		while battle.director.is_playing() and Time.get_ticks_msec() < deadline:
			await process_frame
		_expect(
			not battle.director.is_playing()
			and not battle.reveal_layer.is_presenting()
			and not battle.input_blocker.visible,
			"%s zero-card reveal did not release its completion barrier" % mode,
		)
	settings.set("animation_mode", "cinematic")
	settings.set("reduced_motion", false)


func _run_public_reveal_damage_sequence_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
	settings: Node,
) -> void:
	settings.set("animation_mode", "fast")
	settings.set("reduced_motion", false)
	var before := UIPreviewStateFactory.battle_state(20260808)
	before.revision = 140
	before.players[0].deck = ["sv2-delib", "sv1-ener-1", "sv1-ener-2"]
	before.players[0].discard.clear()
	before.players[1].active = PokemonState.new("sv1-104")
	before.players[1].active.damage_counters = 0
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame

	var after := before.clone_state()
	after.revision = 141
	after.players[0].deck = ["sv2-delib"]
	after.players[0].discard = ["sv1-ener-2", "sv1-ener-1"]
	after.players[1].active.damage_counters = 8
	var events: Array[Dictionary] = [
		{
			"event_type": "cards_revealed",
			"actor": 0,
			"visibility": "public",
			"source": {"player": 0, "zone": "deck"},
			"target": {"player": 0, "zone": "deck"},
			"data": {
				"player": 0,
				"purpose": "mill_then_damage",
				"cards": [
					{
						"card_id": "sv1-ener-2",
						"matched": true,
						"destination": {"player": 0, "zone": "discard"},
					},
					{
						"card_id": "sv1-ener-1",
						"matched": true,
						"destination": {"player": 0, "zone": "discard"},
					},
					{
						"card_id": "sv2-delib",
						"matched": false,
						"destination": {"player": 0, "zone": "deck"},
					},
				],
				"summary": {
					"kind": "energy_damage",
					"matched_count": 2,
					"amount": 80,
				},
			},
		},
		{
			"event_type": "deck_shuffled",
			"actor": 0,
			"data": {"player": 0},
		},
		{
			"event_type": "damage_dealt",
			"actor": 0,
			"amount": 80,
			"target": {"player": 1, "slot": "active"},
			"data": {"player": 1, "slot": "active", "amount": 80},
		},
	]
	var lifecycle: Array[String] = []
	var probes := {
		"damage_started_while_revealing": false,
		"cover_before_damage": -1,
		"cover_at_damage": -1,
	}
	var on_started := func(event: Dictionary) -> void:
		var event_type := PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		)
		lifecycle.append("start:%s" % event_type)
		var cover_state := battle._presentation_slot_cover_states.get(
			"1:active",
		) as PokemonState
		if event_type == "deck_shuffled" and cover_state != null:
			probes["cover_before_damage"] = cover_state.damage_counters
		if event_type == "damage_dealt":
			probes["damage_started_while_revealing"] = (
				battle.reveal_layer.is_presenting()
			)
			if cover_state != null:
				probes["cover_at_damage"] = cover_state.damage_counters
	var on_finished := func(event: Dictionary) -> void:
		lifecycle.append("finish:%s" % PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		))
	battle.director.event_started.connect(on_started)
	battle.director.event_finished.connect(on_finished)
	var target_view := BattleViewModel.capture(
		after, 0, empty_rows, "", false, "test")
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			target_view,
			events,
			0,
			BattleTransitionRequest.CAUSE_LOCAL_ACTION,
		)
	)
	await process_frame
	await process_frame
	var showcase := battle.reveal_layer._showcase as Control
	var summary := (
		showcase.get_node_or_null("RevealSummary") as Label
		if showcase != null
		else null
	)
	var staged_damage := battle._presentation_slot_cover_states.get(
		"1:active",
	) as PokemonState
	_expect(
		showcase != null
		and summary != null
		and summary.text == "正在翻牌…"
		and staged_damage != null
		and staged_damage.damage_counters == 0,
		"Public reveal exposed its result or target damage before cards flipped",
	)

	var reveal_deadline := Time.get_ticks_msec() + 2500
	while (
		summary != null
		and summary.text == "正在翻牌…"
		and Time.get_ticks_msec() < reveal_deadline
	):
		await process_frame
	var all_faces_revealed := showcase != null
	if showcase != null:
		for card_value in showcase.get_meta("reveal_cards", []):
			var card := card_value as Control
			all_faces_revealed = (
				all_faces_revealed
				and card != null
				and bool(card.get_meta("face_swapped", false))
			)
	_expect(
		summary != null
		and summary.text == "翻到 2 张能量"
		and not summary.text.contains("伤害")
		and all_faces_revealed,
		"Public reveal announced damage/result before every card was face up",
	)

	await _wait_for_handle(handle, battle)
	var expected_prefix: Array[String] = [
		"start:cards_revealed",
		"finish:cards_revealed",
		"start:deck_shuffled",
		"finish:deck_shuffled",
		"start:damage_dealt",
	]
	_expect(
		handle.status == PresentationHandle.COMPLETED
		and lifecycle.size() >= expected_prefix.size()
		and lifecycle.slice(0, expected_prefix.size()) == expected_prefix
		and not bool(probes["damage_started_while_revealing"])
		and int(probes["cover_before_damage"]) == 0
		and int(probes["cover_at_damage"]) == 8,
		"Reveal/destination/shuffle/damage presentation order was not causal: %s"
		% [lifecycle],
	)
	if battle.director.event_started.is_connected(on_started):
		battle.director.event_started.disconnect(on_started)
	if battle.director.event_finished.is_connected(on_finished):
		battle.director.event_finished.disconnect(on_finished)
	settings.set("animation_mode", "cinematic")
	settings.set("reduced_motion", false)


func _run_preflight_and_event_cleanup_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var before := UIPreviewStateFactory.battle_state(20260804)
	before.revision = 150
	battle.update_view(before, 0, empty_rows, "", false, "test")
	await process_frame
	var preflight := MotionHandle.new()
	battle.presentation_coordinator.set_preflight(preflight)
	var after := before.clone_state()
	after.revision = 151
	after.turn_number += 1
	var target_view := BattleViewModel.capture(after, 0, empty_rows, "", false, "test")
	var request := BattleTransitionRequest.create(
		target_view,
		[],
		0,
		BattleTransitionRequest.CAUSE_NETWORK,
		"contract:preflight",
	)
	var transition: PresentationHandle = battle.submit_transition(request)
	await process_frame
	_expect(
		battle.state_ref.revision == 150 and not transition.is_completed(),
		"Authoritative transition applied underneath the coordinator preflight",
	)
	preflight.finish()
	await _wait_for_handle(transition, battle)
	_expect(
		battle.state_ref.revision == 151,
		"Queued authoritative transition did not apply after the preflight",
	)

	var pending_drag := Control.new()
	pending_drag.set_meta("drag_session_id", "contract:future-drag")
	battle.effects.add_child(pending_drag)
	battle._active_flyers.append(pending_drag)
	var old_event_flyer := Control.new()
	old_event_flyer.set_meta("motion_event_id", "contract:old-stadium")
	battle.effects.add_child(old_event_flyer)
	battle._active_flyers.append(old_event_flyer)
	battle._clear_active_flyers_for_event("contract:old-stadium")
	_expect(
		is_instance_valid(pending_drag)
		and pending_drag in battle._active_flyers
		and not is_instance_valid(old_event_flyer),
		"Finishing one event cleared the parked proxy owned by a later event",
	)
	battle._dispose_flyer(pending_drag)

	var duplicate_snapshot: Dictionary = battle.capture_presentation_snapshot()
	var duplicate_event := PresentationEvent.normalize({
		"event_id": "contract:duplicate-only",
		"event_type": "damage_dealt",
		"actor": 0,
		"target": {"player": 1, "slot": "active"},
		"amount": 10,
	}, 151, 0)
	battle.director._seen_event_ids["contract:duplicate-only"] = true
	var duplicate_view := BattleViewModel.capture(
		battle.state_ref,
		battle.view_player,
		empty_rows,
		"",
		false,
		"test",
	)
	var duplicate_transition := BattleTransitionRequest.create(
		duplicate_view,
		[duplicate_event],
		0,
		BattleTransitionRequest.CAUSE_NETWORK,
		"contract:duplicate-only",
	)
	var duplicate_handle: PresentationHandle = battle.submit_transition(
		duplicate_transition,
	)
	await _wait_for_handle(duplicate_handle, battle)
	_expect(
		battle._presentation_slot_covers.is_empty()
		and battle._presentation_reveals.is_empty()
		and battle._presentation_mask_counts.is_empty(),
		"Duplicate-only batch left presentation staging without a sequence barrier",
	)
	battle.director._seen_event_ids.erase("contract:duplicate-only")


func _run_startup_shuffle_contract(battle: Control) -> void:
	battle._clear_transient_visuals()
	var startup_state := UIPreviewStateFactory.battle_state(20260725)
	startup_state.revision = 94
	startup_state.players[0].hand = ["sv1-104", "sv1-ener-5"]
	var empty_rows: Array[Dictionary] = []
	battle.update_view(startup_state, 0, empty_rows, "", false, "test")
	await process_frame
	await process_frame
	battle._on_hand_drag_started(0)
	await process_frame
	_expect(
		not battle.active_drag_context().is_empty(),
		"Startup blocker fixture did not create a pending hand drag",
	)
	battle.set_startup_blocked(true)
	_expect(
		battle._startup_input_blocked
		and battle.input_blocker.visible
		and battle.active_drag_context().is_empty()
		and not battle.hand_views[0].is_drag_masked(),
		"Startup blocker did not atomically block input and clear the active drag",
	)
	battle.set_startup_blocked(false)
	_expect(
		not battle._startup_input_blocked
		and not battle.input_blocker.visible,
		"Startup blocker remained after choreography release",
	)
	var handle: MotionHandle = battle.play_startup_shuffle([2, 0])
	await process_frame
	await process_frame
	var startup_cards := 0
	var physical_pile_cards := 0
	var physical_pile_geometry_exact := true
	var mulligan_summary_found := false
	for child in battle.effects.get_children():
		var control := child as Control
		if control == null:
			continue
		if bool(control.get_meta("startup_shuffle", false)):
			if bool(control.get_meta("shuffle_card", false)):
				startup_cards += 1
				var source_zone := control.get_meta("shuffle_source_zone", null) as ZoneView
				var start: Vector2 = control.get_meta("motion_start", Vector2.ZERO)
				var finish: Vector2 = control.get_meta("motion_finish", Vector2.ZERO)
				if (
					bool(control.get_meta("shuffle_from_physical_pile", false))
					and source_zone != null
					and source_zone.is_stack_presentation_hidden()
					and control.size.distance_to(source_zone.get_stack_face_size()) < 0.5
					and start.distance_to(finish) < 0.1
				):
					physical_pile_cards += 1
				else:
					physical_pile_geometry_exact = false
			elif control is Label and (control as Label).text == "再战 ×2":
				mulligan_summary_found = true
	var own_deck := battle.zones.get("own_deck") as ZoneView
	var opponent_deck := battle.zones.get("opponent_deck") as ZoneView
	_expect(
		not handle.is_finished()
		and startup_cards == battle._shuffle_card_count() * 2
		and physical_pile_cards == startup_cards
		and physical_pile_geometry_exact
		and own_deck != null
		and own_deck.is_stack_presentation_hidden()
		and opponent_deck != null
		and opponent_deck.is_stack_presentation_hidden()
		and mulligan_summary_found,
		"Startup choreography did not replace and shuffle both physical deck piles",
	)
	var deadline := Time.get_ticks_msec() + 2500
	while not handle.is_finished() and Time.get_ticks_msec() < deadline:
		await process_frame
	await process_frame
	var leftover := false
	for child in battle.effects.get_children():
		if child is Control and bool(child.get_meta("startup_shuffle", false)):
			leftover = true
			break
	_expect(
		handle.is_finished()
		and not leftover
		and not own_deck.is_stack_presentation_hidden()
		and not opponent_deck.is_stack_presentation_hidden()
		and battle._shuffle_source_masks.is_empty(),
		"Startup shuffle did not finish its MotionHandle or clear proxy nodes",
	)
	var cancelled_handle: MotionHandle = battle.play_startup_shuffle([])
	await process_frame
	battle._cancel_startup_shuffle()
	_expect(
		cancelled_handle.is_finished()
		and not own_deck.is_stack_presentation_hidden()
		and not opponent_deck.is_stack_presentation_hidden()
		and battle._shuffle_source_masks.is_empty(),
		"Cancelled startup shuffle did not restore the physical deck piles",
	)


func _draw_event(actor: int, card_ids: Array) -> Dictionary:
	return {
		"event_type": "cards_drawn",
		"actor": actor,
		"visibility": "owner",
		"card_id": str(card_ids[0]) if not card_ids.is_empty() else "",
		"source": {"player": actor, "zone": "deck"},
		"target": {"player": actor, "zone": "hand"},
		"amount": card_ids.size(),
		"data": {
			"player": actor,
			"count": card_ids.size(),
			"card_ids": card_ids.duplicate(),
		},
	}


func _run_feedback_layer_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var table = battle
	var world = battle.world_feedback
	var announcements = battle.announcement_layer
	var detail_panel := table.detail_panel as Control
	var action_popover := table.action_popover as Control
	world.clear_transients()
	table.effects.clear_transients()
	announcements.clear()

	var maximum_card_z := -4096
	for card in [table.opponent_active, table.own_active] + table.opponent_bench + table.own_bench:
		if card == null or not card.is_visible_in_tree():
			continue
		maximum_card_z = maxi(maximum_card_z, _maximum_visible_canvas_z(card))
	var world_z := _effective_canvas_z(world)
	var announcement_z := _effective_canvas_z(announcements)
	_expect(
		world != null
		and announcements != null
		and not world.z_as_relative
		and not announcements.z_as_relative
		and maximum_card_z < world_z
		and world_z < _effective_canvas_z(table.hud)
		and _effective_canvas_z(table.hud) < announcement_z
		and announcement_z < _effective_canvas_z(detail_panel)
		and _effective_canvas_z(detail_panel) < _effective_canvas_z(action_popover),
		"battle feedback layers do not occupy isolated card/HUD z bands",
	)
	_expect(
		world in table.camera_rig._targets
		and announcements not in table.camera_rig._targets,
		"world feedback and screen announcements use the wrong camera space",
	)

	table._on_floating_text_requested(
		"-30",
		{"player": 0, "slot": "active"},
		DesignTokens.RED,
	)
	var world_count: int = world.floating_texts.size()
	_expect(
		world_count == 1 and table.effects.floating_texts.is_empty(),
		"world floating text was still drawn in the card-motion layer",
	)
	var announcement_state: GameState = table.state_ref.clone_state()
	announcement_state.revision += 1
	var announcement_view := BattleViewModel.capture(
		announcement_state,
		0,
		empty_rows,
		"",
		false,
		"test",
	)
	var announcement_handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			announcement_view,
			[{
				"event_type": "turn_end",
				"actor": 0,
				"source": {"player": 0, "slot": "active"},
				"target": {"player": 0, "slot": "active"},
				"data": {"player": 0},
			}],
			0,
			BattleTransitionRequest.CAUSE_LOCAL_ACTION,
		)
	)
	await process_frame
	await process_frame
	var panel_center: Vector2 = (
		announcements.announcement_panel.get_global_rect().get_center()
	)
	_expect(
		announcements.is_presenting()
		and announcements.current_text == "回合结束"
		and world.floating_texts.size() == world_count
		and not table.own_active.get_global_rect().has_point(panel_center)
		and not table.opponent_active.get_global_rect().has_point(panel_center),
		"turn feedback did not use the non-overlapping screen announcement layer",
	)
	await _wait_for_handle(announcement_handle, battle)
	await _run_announcement_queue_modes_contract(announcements)
	_run_reduced_floating_text_slots_contract(world)
	await _run_fast_feedback_lifecycle_contract(battle, empty_rows)
	table._on_burst_requested(
		"coin",
		{"player": 0, "zone": "deck"},
		DesignTokens.GOLD,
	)
	_expect(
		not world.particles.is_empty()
		and table.effects.particles.is_empty(),
		"world burst particles were still rendered underneath cards",
	)
	world.clear_transients()
	announcements.clear()
	var settings := root.get_node_or_null("AppSettings")
	settings.set("animation_mode", "cinematic")
	settings.set("reduced_motion", false)
	battle.director.set_speed_mode("cinematic")


func _run_announcement_queue_modes_contract(announcements: Control) -> void:
	var settings := root.get_node_or_null("AppSettings")
	for mode in ["cinematic", "standard", "fast", "reduced"]:
		settings.set("animation_mode", mode)
		settings.set("reduced_motion", mode == "reduced")
		announcements.clear()
		var handles: Array[MotionHandle] = [
			announcements.show_announcement(
				"回合结束",
				DesignTokens.BLUE,
				mode == "reduced",
			),
			announcements.show_announcement(
				"宝可梦检查",
				DesignTokens.CYAN,
				mode == "reduced",
			),
			announcements.show_announcement(
				"第 4 回合",
				DesignTokens.GOLD,
				mode == "reduced",
			),
		]
		var observed: Array[String] = []
		for _frame in range(240):
			var text := str(announcements.current_text)
			if not text.is_empty() and (observed.is_empty() or observed[-1] != text):
				observed.append(text)
			if handles[-1].is_finished():
				break
			await process_frame
		var all_completed := true
		for motion_handle in handles:
			if motion_handle.status != MotionHandle.COMPLETED:
				all_completed = false
		_expect(
			observed == ["回合结束", "宝可梦检查", "第 4 回合"]
			and all_completed,
			"%s announcements were replaced, reordered, or cancelled" % mode,
		)
		if mode == "reduced":
			_expect(
				announcements.motion_root.position == Vector2.ZERO,
				"reduced announcements retained spatial motion",
			)
		announcements.clear()


func _run_reduced_floating_text_slots_contract(world: Control) -> void:
	var settings := root.get_node_or_null("AppSettings")
	settings.set("animation_mode", "reduced")
	settings.set("reduced_motion", true)
	world.clear_transients()
	var anchor := Vector2(320.0, 240.0)
	var first: MotionHandle = world.floating_text(
		"-10",
		anchor,
		DesignTokens.RED,
		false,
	)
	var second: MotionHandle = world.floating_text(
		"中毒",
		anchor,
		DesignTokens.PURPLE,
		false,
	)
	var third: MotionHandle = world.floating_text(
		"灼伤",
		anchor,
		DesignTokens.RED,
		false,
	)
	var positions: Array[Vector2] = []
	for row_value in world.floating_texts:
		var row: Dictionary = row_value
		positions.append(Vector2(row.get("position", Vector2.ZERO)))
	_expect(
		first.is_finished()
		and second.is_finished()
		and third.is_finished()
		and positions.size() == 3
		and positions[0] != positions[1]
		and positions[0] != positions[2]
		and positions[1] != positions[2],
		"same-frame reduced feedback still overlaps at one target",
	)
	world.clear_transients()


func _run_fast_feedback_lifecycle_contract(
	battle: Control,
	empty_rows: Array[Dictionary],
) -> void:
	var settings := root.get_node_or_null("AppSettings")
	settings.set("animation_mode", "fast")
	settings.set("reduced_motion", false)
	battle.director.set_speed_mode("fast")
	battle.world_feedback.clear_transients()
	var after: GameState = battle.state_ref.clone_state()
	after.revision += 1
	var target_view := BattleViewModel.capture(
		after,
		battle.view_player,
		empty_rows,
		"",
		false,
		"test",
	)
	var handle: PresentationHandle = battle.submit_transition(
		BattleTransitionRequest.create(
			target_view,
			[{
				"event_type": "damage_dealt",
				"actor": 0,
				"amount": 30,
				"source": {"player": 0, "slot": "active"},
				"target": {"player": 1, "slot": "active"},
				"data": {"player": 1, "slot": "active", "amount": 30},
			}],
			0,
			BattleTransitionRequest.CAUSE_LOCAL_ACTION,
		)
	)
	await _wait_for_handle(handle, battle)
	var camera_positions: Array[Vector2] = []
	for target_value in battle.camera_rig._targets:
		var target := target_value as Control
		camera_positions.append(target.position)
	var floating_positions: Array[Vector2] = []
	for row_value in battle.world_feedback.floating_texts:
		var row: Dictionary = row_value
		floating_positions.append(Vector2(row.get("position", Vector2.ZERO)))
	await process_frame
	await process_frame
	var positions_unchanged := true
	for index in range(camera_positions.size()):
		var target := battle.camera_rig._targets[index] as Control
		if target.position.distance_to(camera_positions[index]) > 0.01:
			positions_unchanged = false
	for index in range(mini(
		floating_positions.size(),
		battle.world_feedback.floating_texts.size(),
	)):
		var row: Dictionary = battle.world_feedback.floating_texts[index]
		if Vector2(row.get("position", Vector2.ZERO)).distance_to(
			floating_positions[index]
		) > 0.01:
			positions_unchanged = false
	_expect(
		handle.status == PresentationHandle.COMPLETED
		and battle.camera_rig._impulse_handle == null
		and positions_unchanged,
		"fast feedback kept writing positions after the event barrier",
	)
	battle.world_feedback.clear_transients()


func _maximum_visible_canvas_z(root_item: CanvasItem) -> int:
	var maximum := _effective_canvas_z(root_item)
	for child in root_item.find_children("*", "", true, false):
		var canvas_item := child as CanvasItem
		if canvas_item != null and canvas_item.is_visible_in_tree():
			maximum = maxi(maximum, _effective_canvas_z(canvas_item))
	return maximum


func _effective_canvas_z(item: CanvasItem) -> int:
	if item == null:
		return -4096
	var result := item.z_index
	var current := item
	while current.z_as_relative:
		var parent := current.get_parent() as CanvasItem
		if parent == null:
			break
		result += parent.z_index
		current = parent
	return result


func _feedback_layers_are_clear(battle: Control) -> bool:
	var effects_layer = battle.effects
	var world_layer = battle.world_feedback
	var announcements = battle.announcement_layer
	return (
		effects_layer != null
		and effects_layer.particles.is_empty()
		and effects_layer.floating_texts.is_empty()
		and effects_layer.impact_rings.is_empty()
		and not effects_layer.is_processing()
		and world_layer != null
		and world_layer.particles.is_empty()
		and world_layer.floating_texts.is_empty()
		and world_layer.impact_rings.is_empty()
		and not world_layer.is_processing()
		and announcements != null
		and not announcements.is_presenting()
		and announcements.current_text.is_empty()
		and not announcements.visible
	)


func _wait_for_hand_stage_count(
	battle: Control,
	expected_count: int,
	max_frames: int = 120,
) -> int:
	for frame in range(max_frames):
		if battle._presentation_hand_stage_count >= expected_count:
			return frame
		await process_frame
	_expect(false, "hand staging timed out at %d cards" % expected_count)
	return -1


func _wait_for_handle_status(
	handle: PresentationHandle,
	expected_status: String,
	max_frames: int = 120,
) -> bool:
	for _frame in range(max_frames):
		if handle.status == expected_status:
			return true
		if handle.is_completed():
			return false
		await process_frame
	return false


func _wait_for_handle(handle: RefCounted, battle: Control) -> void:
	# Multi-card motion now gives every card its full flight plus a 0.10 s launch
	# stagger. Headless frames advance much faster than a rendered 60 FPS frame,
	# so allow enough frames for the intentional cinematic wall-clock duration.
	for _frame in range(720):
		if handle.is_completed():
			return
		await process_frame
	var motion_rows: Dictionary = battle._event_motion_completions
	var tween_rows: Array[String] = []
	for tween_value in battle._flyer_tweens.values():
		var tween := tween_value as Tween
		tween_rows.append("valid=%s running=%s elapsed=%.3f" % [
			str(tween != null and tween.is_valid()),
			str(tween != null and tween.is_running()),
			tween.get_total_elapsed_time() if tween != null and tween.is_valid() else -1.0,
		])
	_expect(false, "transition handle timed out: director=%s motions=%s tweens=%s" % [
		str(battle.director.is_playing()),
		str(motion_rows),
		str(tween_rows),
	])


func _wait_for_drag_idle(battle: Control) -> void:
	for _frame in range(240):
		if battle.active_drag_context().is_empty():
			return
		await process_frame
	_expect(false, "drag return timed out")


func _wait_for_director_event(
	started_types: Array[String],
	event_type: String,
	max_frames: int = 240,
) -> bool:
	for _frame in range(max_frames):
		if event_type in started_types:
			return true
		await process_frame
	_expect(false, "presentation event did not start: %s" % event_type)
	return false


func _wait_for_presentation_idle(battle: Control, max_frames: int = 360) -> void:
	for _frame in range(max_frames):
		if not battle.is_presentation_busy() and not battle.director.is_playing():
			return
		await process_frame
	_expect(false, "presentation did not become idle")


func _snapshot_proxy_keys(values: Array) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		if not is_instance_valid(value):
			continue
		var proxy := value as Control
		if proxy == null:
			continue
		var key := str(proxy.get_meta("snapshot_hand_key", ""))
		if not key.is_empty():
			result.append(key)
	result.sort()
	return result


func _event_types(events: Array) -> Array[String]:
	var result: Array[String] = []
	for value in events:
		if not value is Dictionary:
			continue
		result.append(PresentationEvent.canonical_event_type(
			str(value.get("event_type", "")),
		))
	return result


func _count_motion_entities(battle: Control) -> int:
	return _motion_entities(battle).size()


func _is_full_face_motion_token(token: Control) -> bool:
	if token == null or not is_instance_valid(token):
		return false
	var shadow := token.get_node_or_null("PaperShadow") as Panel
	var shadow_style := (
		shadow.get_theme_stylebox("panel") as StyleBoxFlat
		if shadow != null
		else null
	)
	var image := token.get_node_or_null("PaperImage") as TextureRect
	return (
		bool(token.get_meta("paper_card_single_face", false))
		and token.get_node_or_null("PaperEdge") == null
		and token.get_node_or_null("PaperFace") == null
		and token.get_node_or_null("PaperGloss") == null
		and shadow_style != null
		and shadow_style.bg_color.a <= 0.001
		and image != null
		and image.position.distance_to(Vector2.ZERO) < 0.01
		and image.size.distance_to(token.size) < 0.01
		and image.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_COVERED
	)


func _motion_entities(battle: Control) -> Array[Control]:
	var result: Array[Control] = []
	for child in battle.effects.get_children():
		if bool(child.get_meta("card_motion_entity", false)) and child.visible:
			result.append(child as Control)
	return result


func _slot_composite_movers(battle: Control) -> Array[CardView]:
	var result: Array[CardView] = []
	for value in battle._active_flyers:
		var mover := value as CardView
		if (
			mover != null
			and is_instance_valid(mover)
			and bool(mover.get_meta("slot_composite_motion", false))
		):
			result.append(mover)
	return result


func _dense_hand_geometry_snapshot(battle: Control, hand_count: int) -> Dictionary:
	var positions: Array[Vector2] = []
	var global_positions: Array[Vector2] = []
	var rotations: Array[float] = []
	for hand_index in range(hand_count):
		var view := _visible_hand_view_at_index(battle, hand_index)
		if view == null:
			continue
		positions.append(view.position)
		global_positions.append(view.global_position)
		rotations.append(view.rotation_degrees)
	return {
		"positions": positions,
		"global_positions": global_positions,
		"rotations": rotations,
		"surface_minimum_width": battle.hand_surface.custom_minimum_size.x,
		"surface_width": battle.hand_surface.size.x,
		"scroll_horizontal": battle.hand_scroll.scroll_horizontal,
	}


func _dense_hand_geometry_matches(
	battle: Control,
	hand_count: int,
	expected: Dictionary,
) -> bool:
	var positions: Array = expected.get("positions", [])
	var global_positions: Array = expected.get("global_positions", [])
	var rotations: Array = expected.get("rotations", [])
	if (
		positions.size() != hand_count
		or global_positions.size() != hand_count
		or rotations.size() != hand_count
	):
		return false
	for hand_index in range(hand_count):
		var view := _visible_hand_view_at_index(battle, hand_index)
		if view == null:
			return false
		var expected_position: Vector2 = positions[hand_index]
		var expected_global_position: Vector2 = global_positions[hand_index]
		if (
			view.position.distance_to(expected_position) > 0.01
			or view.global_position.distance_to(expected_global_position) > 0.01
			or absf(view.rotation_degrees - float(rotations[hand_index])) > 0.01
		):
			return false
	return (
		is_equal_approx(
			battle.hand_surface.custom_minimum_size.x,
			float(expected.get("surface_minimum_width", -1.0)),
		)
		and is_equal_approx(
			battle.hand_surface.size.x,
			float(expected.get("surface_width", -1.0)),
		)
		and battle.hand_scroll.scroll_horizontal
		== int(expected.get("scroll_horizontal", -1))
	)


func _dense_hand_order_snapshot(battle: Control, hand_count: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for hand_index in range(hand_count):
		var view := _visible_hand_view_at_index(battle, hand_index)
		if view == null:
			continue
		result.append(Vector2i(view.z_index, view.get_index()))
	return result


func _dense_hand_is_canonical(battle: Control, hand_count: int) -> bool:
	var previous_view: CardView
	for hand_index in range(hand_count):
		var view := _visible_hand_view_at_index(battle, hand_index)
		if (
			view == null
			or view.get_parent() != battle.hand_surface
			or view.get_index() != hand_index
		):
			return false
		if previous_view != null and not _hand_view_draws_above(view, previous_view):
			return false
		previous_view = view
	return true


func _hand_view_draws_above(upper: CardView, lower: CardView) -> bool:
	if upper == null or lower == null:
		return false
	return (
		upper.z_index > lower.z_index
		or (
			upper.z_index == lower.z_index
			and upper.get_index() > lower.get_index()
		)
	)


func _selected_hand_is_topmost(
	battle: Control,
	hand_count: int,
	selected_view: CardView,
) -> bool:
	if (
		selected_view == null
		or not selected_view.selected
		or selected_view.get_index()
		!= battle.hand_surface.get_child_count() - 1
	):
		return false
	var previous_sibling_index := -1
	for hand_index in range(hand_count):
		var view := _visible_hand_view_at_index(battle, hand_index)
		if view == null:
			return false
		if view == selected_view:
			continue
		if (
			view.selected
			or selected_view.z_index <= view.z_index
			or view.get_index() <= previous_sibling_index
		):
			return false
		previous_sibling_index = view.get_index()
	return true


func _card_hover_target_is_active(view: CardView) -> bool:
	return (
		view != null
		and view._hovered
		and view._interaction_target_offset.y < -0.01
		and view._interaction_target_scale.x > 1.001
		and view._interaction_target_scale.y > 1.001
	)


func _visible_hand_view_at_index(battle: Control, hand_index: int) -> CardView:
	for view_value in battle.hand_views:
		var view := view_value as CardView
		if view != null and view.visible and view.hand_index == hand_index:
			return view
	return null


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
