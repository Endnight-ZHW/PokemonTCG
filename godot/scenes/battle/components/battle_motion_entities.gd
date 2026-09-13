class_name BattleMotionEntities
extends Node

var table: BattleTable


func configure(p_table: BattleTable) -> void:
	table = p_table


func _create_paper_card_token(
	texture: Texture2D, size_value: Vector2, transient_kind: String,
	z_value: int, depth: float = 0.55, single_face: bool = true,
) -> Control:
	var card := CardMotionEntity.new()
	card.name = transient_kind
	card.configure_motion("visual:%d" % card.get_instance_id())
	card.texture = texture
	card.set_meta("battle_transient_visual", true)
	card.set_meta("battle_transient_kind", transient_kind)
	card.set_meta("paper_card_token", true)
	card.set_meta("paper_card_single_face", single_face)
	card.set_meta("table_depth", depth)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.size = size_value
	card.custom_minimum_size = size_value
	card.pivot_offset = size_value * 0.5
	card.z_index = z_value
	table.register_3d_surface(card)
	return card


func _resize_paper_card_token(card: Control, size_value: Vector2) -> void:
	if card == null or not is_instance_valid(card):
		return
	card.custom_minimum_size = size_value
	card.size = size_value
	card.pivot_offset = size_value * 0.5


func _spawn_flying_card(
	texture: Texture2D,
	start: Vector2,
	finish: Vector2,
	duration: float,
	delay: float,
	event_type: String,
	index: int,
	start_size: Vector2 = Vector2.ZERO,
	finish_size: Vector2 = Vector2.ZERO,
	start_rotation: float = 0.0,
	finish_rotation: float = 0.0,
	landing_view: Control = null,
	existing_flyer: Control = null,
	motion_event_id: String = "",
	landing_attachment_type: String = "",
	landing_attachment_card_id: String = "",
	landing_attachment_index: int = -1,
	flip_texture: Texture2D = null,
	stage_opponent_hand_landing: bool = false,
	opponent_hand_stage_count_delta: int = 0,
) -> Control:
	_prune_flyers()
	while existing_flyer == null and table.card_motion_layer.entities.size() >= table.card_motion_layer._max_active_flyers():
		var oldest: Control = table.card_motion_layer.entities.pop_front()
		_dispose_flyer(oldest)
	var default_size := table.motion_geometry._flying_card_size(event_type)
	var flying_size := start_size if start_size != Vector2.ZERO else default_size
	var landing_size := finish_size if finish_size != Vector2.ZERO else default_size
	var motion_start := start
	var flying: Control
	var retained_pose: Variant = null
	if existing_flyer != null and is_instance_valid(existing_flyer):
		flying = existing_flyer
		if flying is CardMotionEntity:
			retained_pose = (flying as CardMotionEntity).current_pose()
		table.hand_presentation._cancel_hand_layout_motion(flying)
		motion_start = flying.position + flying.size * 0.5
		flying_size = flying.size
		# A staged hand proxy may already have reflowed, and a drag proxy may be
		# tilted at its parked target. Continue from that exact pose instead of
		# snapping back to the batch snapshot rotation.
		start_rotation = flying.rotation_degrees
		var previous := table.card_motion_layer.tweens.get(flying.get_instance_id()) as Tween
		if previous != null and previous.is_valid():
			previous.kill()
		table.card_motion_layer.tweens.erase(flying.get_instance_id())
		if flying not in table.card_motion_layer.entities:
			table.card_motion_layer.add(flying)
	else:
		flying = _create_paper_card_token(
			texture,
			flying_size,
			"CardMotionEntity",
			100 + index,
			table.motion_geometry._motion_depth_for_point((start + finish) * 0.5),
		)
	flying.set_meta("card_motion_entity", true)
	for stale_pose in ["physical_start_pose", "drag_start_world_pose", "physical_flip_progress"]:
		if flying.has_meta(stale_pose):
			flying.remove_meta(stale_pose)
	if flying is CardMotionEntity:
		(flying as CardMotionEntity).has_world_pose = false
		if retained_pose is Transform3D:
			flying.set_meta("physical_start_pose", retained_pose)
			(flying as CardMotionEntity).world_pose = retained_pose
			(flying as CardMotionEntity).has_world_pose = true
	flying.set_meta("motion_start", motion_start)
	flying.set_meta("motion_finish", finish)
	flying.set_meta("motion_start_size", flying_size)
	flying.set_meta("motion_finish_size", landing_size)
	if landing_view != null:
		flying.set_meta("motion_landing_view", landing_view)
	if not landing_attachment_type.is_empty():
		flying.set_meta(
			"motion_landing_attachment_type",
			landing_attachment_type,
		)
	elif flying.has_meta("motion_landing_attachment_type"):
		flying.remove_meta("motion_landing_attachment_type")
	if not landing_attachment_card_id.is_empty():
		flying.set_meta(
			"motion_landing_attachment_card_id",
			landing_attachment_card_id,
		)
		flying.set_meta("motion_landing_attachment_index", landing_attachment_index)
	if flip_texture != null:
		if flying is CardMotionEntity:
			flying.set_meta("physical_flip_source", (flying as CardMotionEntity).texture)
		flying.set_meta("motion_flip_texture", flip_texture)
		flying.set_meta("motion_flip_swapped", false)
	elif flying.has_meta("motion_flip_texture"):
		flying.remove_meta("motion_flip_texture")
		flying.remove_meta("motion_flip_swapped")
	if stage_opponent_hand_landing:
		flying.set_meta("opponent_hand_staged_landing", true)
		flying.set_meta(
			"opponent_hand_stage_count_delta",
			opponent_hand_stage_count_delta,
		)
	elif flying.has_meta("opponent_hand_staged_landing"):
		flying.remove_meta("opponent_hand_staged_landing")
		flying.remove_meta("opponent_hand_stage_count_delta")
	flying.position = motion_start - flying.size * 0.5
	flying.pivot_offset = flying.size * 0.5
	flying.rotation_degrees = start_rotation
	flying.modulate.a = 1.0
	table.card_motion_layer.add(flying)
	# Delayed cards still belong to their source pile. Showing all queued flyers
	# before their first motion update created a fan of intersecting card backs.
	if existing_flyer == null:
		flying.visible = false
	var drag_continuation := flying.has_meta("drag_session_id")
	var travel_distance := motion_start.distance_to(finish)
	if drag_continuation:
		# The player already performed the large spatial movement. Successful
		# authority only needs a short physical settle from the release/park pose;
		# replaying the normal 74 px arc reads as a second card placement.
		duration = minf(duration, clampf(travel_distance / 420.0, 0.12, 0.22))
		delay = 0.0
	var spin := 2.0 if drag_continuation else (
		16.0 + float(index) * 2.0
		if event_type in ["cards_discarded", "pokemon_ko"]
		else -7.0 + float(index) * 3.0
	)
	var tween := create_tween()
	if delay > 0.0:
		tween.tween_interval(delay)
	table.card_motion_layer.bind_tween(flying, tween)
	var flight := tween.tween_method(
		_update_flyer.bind(
			flying,
			motion_start,
			finish,
			spin,
			flying_size,
			landing_size,
			start_rotation,
			finish_rotation,
		),
		0.0,
		1.0,
		duration,
	)
	if event_type in ["cards_drawn", "prize_taken"]:
		# A dealt card should clear the pile before the next launch. The old cubic
		# ease-in kept several flights hovering over the same top face.
		flight.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	else:
		flight.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(_finish_flyer.bind(flying, finish, event_type))
	if landing_view != null:
		var landing_wait := (
			MotionPolicy.duration("draw_landing")
			if event_type in ["cards_drawn", "prize_taken"]
			else 0.22
		)
		var landing_feedback: Dictionary = table.presentation_runtime.landing_feedbacks.get(
			motion_event_id,
			{},
		)
		landing_wait = maxf(
			landing_wait,
			float(landing_feedback.get("camera_duration", 0.0)),
		)
		if bool(flying.get_meta("opponent_hand_staged_landing", false)):
			landing_wait = maxf(
				landing_wait,
				MotionPolicy.duration("hand_reflow"),
			)
		tween.tween_interval(landing_wait)
	table.card_motion_layer._register_event_motion(flying, motion_event_id, tween)
	return flying

func _update_flyer(
	progress: float,
	flying_value: Variant,
	start: Vector2,
	finish: Vector2,
	spin: float,
	start_size: Vector2,
	finish_size: Vector2,
	start_rotation: float,
	finish_rotation: float,
) -> void:
	if not is_instance_valid(flying_value):
		return
	var flying := flying_value as CardMotionEntity
	if flying == null:
		return
	if not table.render3d.is_projection_ready():
		flying.visible = false
		return
	flying.visible = progress > 0.0001
	_update_physical_flyer(progress, flying, start, finish,
		start_size, finish_size, start_rotation, finish_rotation, spin)


func _update_physical_flyer(
	progress: float, flying: CardMotionEntity, start: Vector2, finish: Vector2,
	start_size: Vector2, finish_size: Vector2, start_rotation: float,
	finish_rotation: float, spin: float,
) -> void:
	var projection := table.render3d.world.projection
	var to_table := table.get_global_transform_with_canvas().affine_inverse() * table.effects.get_global_transform_with_canvas()
	var destination := table.card_motion_layer._motion_entity_finish(flying, finish)
	var start_pose := projection.pose_for_screen(to_table * start, start_size.x, deg_to_rad(start_rotation), 0.14, 0.12)
	var end_pose := projection.pose_for_screen(to_table * destination, finish_size.x, deg_to_rad(finish_rotation), 0.08)
	var landing := flying.get_meta("motion_landing_view") as Control if flying.has_meta("motion_landing_view") else null
	var attachment_type := str(flying.get_meta("motion_landing_attachment_type", ""))
	if landing is CardView:
		end_pose = table.render3d.card_pose(landing as CardView) if attachment_type.is_empty() else table.render3d.attachment_pose(landing as CardView, attachment_type, int(flying.get_meta("motion_landing_attachment_index", -1)))
	elif landing is CardMotionEntity and (landing as CardMotionEntity).has_world_pose:
		end_pose = (landing as CardMotionEntity).world_pose
	elif landing is ZoneView:
		end_pose = table.render3d.zone_pose_at_screen_point(landing as ZoneView, to_table * destination)
	if flying.has_meta("drag_session_id") and flying.current_pose() is Transform3D:
		if not flying.has_meta("drag_start_world_pose"):
			flying.set_meta("drag_start_world_pose", flying.current_pose())
		start_pose = flying.get_meta("drag_start_world_pose")
	elif flying.has_meta("physical_start_pose"):
		start_pose = flying.get_meta("physical_start_pose")
	else:
		if flying.current_pose() is Transform3D:
			start_pose = flying.current_pose()
		flying.set_meta("physical_start_pose", start_pose)
	var pose := start_pose.interpolate_with(end_pose, progress)
	flying.source_pose = start_pose
	flying.target_pose = end_pose
	var arc := 0.18 if flying.has_meta("drag_session_id") else clampf(start_pose.origin.distance_to(end_pose.origin) * 0.18, 0.4, 1.4)
	pose.origin.y += sin(progress * PI) * arc
	pose.basis = BattleProjection3D.rotate_card_basis(pose.basis, Basis(Vector3.FORWARD, sin(progress * PI) * deg_to_rad(spin) * 0.45))
	if flying.has_meta("reveal_transferred"):
		pose = BattleCardPath3D.transfer(projection, start_pose, end_pose, progress)
	elif not attachment_type.is_empty() or flying.has_meta("physical_attachment_source"):
		pose = BattleCardPath3D.attachment(start_pose, end_pose, progress, flying.has_meta("physical_attachment_source"), not attachment_type.is_empty())
	flying.world_pose = pose
	flying.has_world_pose = true
	var screen_center := projection.world_to_screen(pose.origin)
	var size_value := start_size.lerp(finish_size, progress)
	_resize_paper_card_token(flying, size_value)
	flying.position = to_table.affine_inverse() * screen_center - size_value * 0.5
	flying.rotation_degrees = lerpf(start_rotation, finish_rotation, progress)
	flying.scale = Vector2.ONE
	flying.modulate.a = 1.0
	_update_flyer_flip(flying, progress)
	if flying.has_meta("motion_flip_texture"):
		var phase := clampf((progress - 0.32) / 0.34, 0.0, 1.0)
		flying.set_meta("physical_flip_progress", phase)


func _update_flyer_flip(flying: CardMotionEntity, progress: float) -> void:
	if flying == null or not flying.has_meta("motion_flip_texture"):
		return
	var phase := clampf((progress - 0.32) / 0.34, 0.0, 1.0)
	if phase >= 0.5 and not bool(flying.get_meta("motion_flip_swapped", false)):
		flying.texture = flying.get_meta("motion_flip_texture") as Texture2D
		flying.set_meta("motion_flip_swapped", true)


func _finish_flyer(
	flying_value: Variant,
	finish: Vector2,
	event_type: String,
) -> void:
	if not is_instance_valid(flying_value):
		return
	var flying := flying_value as Control
	if flying == null:
		return
	if flying is CardMotionEntity:
		if flying.has_meta("physical_flip_progress"):
			flying.remove_meta("physical_flip_progress")
	finish = table.card_motion_layer._motion_entity_finish(flying, finish)
	table.card_motion_layer.tweens.erase(flying.get_instance_id())
	flying.set_meta("motion_completed", true)
	if flying.has_meta("motion_finish_size"):
		_resize_paper_card_token(
			flying,
			table.motion_geometry._vector_or_default(flying.get_meta("motion_finish_size"), flying.size),
		)
	flying.position = finish - flying.size * 0.5
	flying.scale = Vector2.ONE
	flying.modulate.a = 1.0
	_update_flyer_flip(flying as CardMotionEntity, 1.0)
	var handed_off_to_local_hand := false
	if flying.has_meta("motion_landing_view"):
		var landing_view := table.presentation_runtime._valid_control(flying.get_meta("motion_landing_view"))
		if landing_view != null:
			handed_off_to_local_hand = (
				landing_view is CardView
				and (landing_view as CardView).hand_index >= 0
				and (landing_view as CardView).owner_player == table.view_player
			)
			handed_off_to_local_hand = handed_off_to_local_hand or landing_view.has_meta("snapshot_opponent_hand_index")
			var reveal_duration := (
				0.0
				if handed_off_to_local_hand
				else MotionPolicy.duration("draw_landing")
				if event_type in ["cards_drawn", "prize_taken"]
				else 0.14
			)
			var reveal_handle := table.presentation_runtime._reveal_presentation_node(
				landing_view,
				false,
				reveal_duration,
			)
			var event_id := str(flying.get_meta("motion_event_id", ""))
			if not event_id.is_empty() and table.hand_presentation._hand_transition_sequences.has(event_id):
				var row: Dictionary = table.hand_presentation._hand_transition_sequences[event_id]
				var landing_handles: Array = row.get("landing_handles", [])
				landing_handles.append(reveal_handle)
				row["landing_handles"] = landing_handles
				table.hand_presentation._hand_transition_sequences[event_id] = row
			_remove_revealed_node_from_events(landing_view)
	if not table.presentation_runtime._play_card_landing_feedback(flying, finish):
		table.presentation_runtime._burst_world_at_motion_point(
			finish,
			table.card_motion_layer._motion_landing_color(event_type),
			"card_land",
		)
	table.hand_presentation._adopt_opponent_hand_landing_flyer(flying)
	var physical_attachment := table.render3d != null and not str(flying.get_meta("motion_landing_attachment_type", "")).is_empty()
	if (handed_off_to_local_hand or physical_attachment) and is_instance_valid(flying):
		# The hand or attachment stack now owns this card. Keeping the flyer for
		# the feedback hold duplicates it and leaves a stale pose during reflow.
		flying.visible = false
		flying.modulate.a = 0.0
		flying.set_meta("motion_visual_handed_off", true)

func _remove_revealed_node_from_events(node: Control) -> void:
	for event_id_value in table.presentation_runtime.reveals.keys():
		var event_id := str(event_id_value)
		var nodes: Array = table.presentation_runtime.reveals.get(event_id, [])
		if node in nodes:
			nodes.erase(node)
			table.presentation_runtime.reveals[event_id] = nodes

func _remove_revealed_node_for_event(node: Control, event_id: String) -> void:
	if node == null or event_id.is_empty() or not table.presentation_runtime.reveals.has(event_id):
		return
	var nodes: Array = table.presentation_runtime.reveals.get(event_id, [])
	nodes.erase(node)
	table.presentation_runtime.reveals[event_id] = nodes

func _prune_flyers() -> void:
	var live: Array[Control] = []
	for flyer in table.card_motion_layer.entities:
		if is_instance_valid(flyer) and not flyer.is_queued_for_deletion():
			live.append(flyer)
	table.card_motion_layer.entities.assign(live)

func _clear_active_flyers() -> void:
	# Cancel the rolling queues first. Otherwise cancelling an active item can
	# synchronously refill its newly freed slot while a resync is clearing the
	# presentation tree.
	table.card_motion_layer._clear_card_motion_batches()
	for tween_value in table.card_motion_layer.tweens.values():
		var tween := tween_value as Tween
		if tween and tween.is_valid():
			tween.kill()
	table.card_motion_layer.tweens.clear()
	for flyer in table.card_motion_layer.entities.duplicate():
		if is_instance_valid(flyer):
			table.card_motion_layer._release_shuffle_source_zone(flyer)
			table.card_motion_layer._complete_event_motion_entity(flyer)
			if not is_instance_valid(flyer): continue
			flyer.visible = false
			flyer.modulate.a = 0.0
			flyer.free()
	table.card_motion_layer.entities.clear()
	table.card_motion_layer._clear_shuffle_source_masks()
	_clear_effect_child_controls(["CardMotionEntity", "FlyingCard"])
	table.card_motion_layer._finish_all_event_motions()

func _clear_active_flyers_for_event(event_id: String) -> void:
	if event_id.is_empty():
		return
	table.card_motion_layer._clear_card_motion_batches_for_event(event_id)
	for flyer in table.card_motion_layer.entities.duplicate():
		if (
			is_instance_valid(flyer)
			and str(flyer.get_meta("motion_event_id", "")) == event_id
		):
			_dispose_flyer(flyer)

func _dispose_flyer(flying: Control) -> void:
	if not is_instance_valid(flying):
		return
	table.hand_presentation._cancel_hand_layout_motion(flying)
	table.card_motion_layer._release_shuffle_source_zone(flying)
	table.card_motion_layer._complete_event_motion_entity(flying)
	if not is_instance_valid(flying): return
	var tween := table.card_motion_layer.tweens.get(flying.get_instance_id()) as Tween
	if tween and tween.is_valid():
		tween.kill()
	table.card_motion_layer.tweens.erase(flying.get_instance_id())
	table.card_motion_layer.forget(flying)
	flying.visible = false
	flying.modulate.a = 0.0
	flying.free()

func _clear_effect_child_controls(prefixes: Array = []) -> void:
	if table.effects == null:
		return
	var active_prefixes := prefixes.duplicate()
	if active_prefixes.is_empty():
		active_prefixes = ["PresentationCover", "CardMotionEntity", "FlyingCard"]
	for child in table.effects.get_children():
		var control := child as Control
		if control == null or not is_instance_valid(control):
			continue
		# RevealLayer is a reusable presentation executor, not one of the
		# short-lived table.card_motion_layer.entities it owns.
		if control == table.reveal_layer:
			continue
		var name_value := str(control.name)
		var kind_value := str(control.get_meta("battle_transient_kind", ""))
		if (
			not prefixes.is_empty()
			and kind_value == "SnapshotOpponentHandProxy"
		):
			continue
		var should_clear := false
		for prefix_value in active_prefixes:
			var prefix := str(prefix_value)
			if name_value.begins_with(prefix) or kind_value == prefix:
				should_clear = true
				break
		if not should_clear and prefixes.is_empty():
			should_clear = true
		if not should_clear:
			continue
		table.card_motion_layer._release_shuffle_source_zone(control)
		table.card_motion_layer._complete_event_motion_entity(control)
		if not is_instance_valid(control): continue
		var instance_id := control.get_instance_id()
		var flyer_tween := table.card_motion_layer.tweens.get(instance_id) as Tween
		if flyer_tween and flyer_tween.is_valid():
			flyer_tween.kill()
		table.card_motion_layer.tweens.erase(instance_id)
		var cover_tween := table.presentation_runtime.cover_tweens.get(instance_id) as Tween
		if cover_tween and cover_tween.is_valid():
			cover_tween.kill()
		table.presentation_runtime.cover_tweens.erase(instance_id)
		table.card_motion_layer.entities.erase(control)
		control.visible = false
		control.modulate.a = 0.0
		if not control.is_queued_for_deletion():
			control.queue_free()
