class_name BattleRevealTransfer3D
extends RefCounted

static func start(cards: Array[Control], duration: float, table: BattleTable, event: Dictionary) -> MotionHandle:
	var completion := MotionHandle.new()
	var group := MotionGroup.new()
	var owned: Array[Control] = []
	var rows := table.motion_geometry._reveal_rows(event)
	var event_id := str(event.get("event_id", ""))
	var actor := int(event.get("actor", table.view_player))
	var target := table.presentation_runtime._event_target_endpoint(event)
	var hand_targets: Array = table.presentation_runtime.event_hand_targets.get(event_id, []).duplicate()
	var is_hand := str(target.get("zone", "")) == "hand"
	if is_hand and int(target.get("player", actor)) == table.view_player:
		var stage := table.hand_presentation
		if stage._presentation_hand_geometry_staged:
			stage._presentation_hand_stage_count = mini(stage._presentation_hand_final_count, stage._presentation_hand_stage_count + cards.size())
			for handle in stage._tween_hand_to_stage_count(stage._presentation_hand_stage_count, minf(0.18, duration * 0.4)):
				group.add(handle)
	elif is_hand and not table.hand_presentation._presentation_opponent_hand_event_ids.is_empty():
		# Reserve hidden physical hand slots before flight. Reflow all old cards
		# once, then hand each arrival directly to its matching stationary slot.
		var stage := table.hand_presentation
		var first := stage._presentation_opponent_hand_proxies.size()
		stage._apply_opponent_hand_stage_delta(event_id, cards.size())
		hand_targets = stage._presentation_opponent_hand_proxies.slice(first)
		for destination in hand_targets: table.presentation_runtime._mask_presentation_node(destination)
		for handle in stage._hand_layout_motion_handles.values(): group.add(handle)
	for index in range(mini(cards.size(), rows.size())):
		var card := cards[index] as CardMotionEntity
		if not is_instance_valid(card): continue
		var destination := table.motion_geometry._reveal_destination(rows[index], actor)
		var landing := table.card_motion_layer._motion_landing_control(destination, event, index, hand_targets)
		table.render3d._sync_token(card)
		var pose: Transform3D = card.current_pose()
		card.reparent(table.effects)
		table.register_3d_surface(card)
		card.world_pose = pose
		card.has_world_pose = true
		card.texture = card.get_meta("face_texture") as Texture2D
		for key in ["face_texture", "physical_flip_progress", "physical_flip_source", "motion_flip_texture"]:
			if card.has_meta(key): card.remove_meta(key)
		for label in ["OutcomeBadge", "OutcomeOutline"]:
			var overlay := card.get_node_or_null(label) as CanvasItem
			if overlay != null: overlay.visible = false
		card.set_meta("reveal_transferred", true)
		var hidden := table.motion_geometry._endpoint_hidden_from_view(destination)
		var finish := table.resolve_endpoint_center(destination)
		var flyer := table.card_motion_layer._spawn_card_motion_spec({
			"texture": card.texture, "texture_authoritative": true, "card_id": str(rows[index].get("card_id", "")),
			"existing_flyer": card, "start": card.position + card.size * 0.5, "finish": finish,
			"start_size": card.size, "finish_size": landing.size if landing != null else card.size,
			"duration": maxf(0.01, duration), "delay": 0.1 + index * 0.055 if duration > 0 else 0.0,
			"event_type": str(event.get("event_type", "cards_selected")), "landing_view": landing,
			"flip_texture": CardEntity3D.BACK if hidden else null,
		}, event_id, "")
		if flyer == null: continue
		owned.append(flyer)
		var motion := flyer.get_meta("motion_handle") as MotionHandle
		group.add(motion)
		var flyer_ref: WeakRef = weakref(flyer)
		motion.completed.connect(func(_handle: MotionHandle) -> void:
			var remaining := flyer_ref.get_ref() as Control
			if remaining != null: table.motion_entities._dispose_flyer(remaining), CONNECT_ONE_SHOT)
	completion.completed.connect(func(result: MotionHandle) -> void:
		if result.status == MotionHandle.CANCELLED: group.cancel()
		for card in owned:
			if is_instance_valid(card): table.motion_entities._dispose_flyer(card), CONNECT_ONE_SHOT)
	group.completed.connect(func(_group: MotionGroup) -> void: completion.finish(), CONNECT_ONE_SHOT)
	group.seal()
	return completion
