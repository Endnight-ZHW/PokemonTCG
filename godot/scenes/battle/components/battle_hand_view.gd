class_name BattleHandView
extends Node

var host: Node
var table: BattleTable
var tween_registry: Dictionary = {}


func configure(p_host: Node) -> void:
	host = p_host
	table = p_host as BattleTable


func move_card(
	view: CardView,
	target_position: Vector2,
	target_rotation: float,
	duration: float,
	completion: Callable = Callable(),
) -> MotionHandle:
	var handle := MotionHandle.new()
	if view == null or not is_instance_valid(view):
		handle.cancel()
		return handle
	var instance_id := view.get_instance_id()
	_cancel_entry(instance_id)
	if duration <= 0.0 or host == null:
		view.position = target_position
		view.rotation_degrees = target_rotation
		view.remember_base_position()
		if completion.is_valid():
			completion.call()
		handle.finish()
		return handle
	var tween := host.create_tween().set_parallel(true)
	tween_registry[instance_id] = tween
	tween.tween_property(view, "position", target_position, duration).set_trans(
		Tween.TRANS_QUAD,
	).set_ease(Tween.EASE_OUT)
	tween.tween_property(
		view, "rotation_degrees", target_rotation, duration,
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.chain().tween_callback(
		_finish_entry.bind(view, instance_id, completion),
	)
	handle.bind_tween(tween)
	return handle


func cancel_all() -> void:
	if tween_registry == null:
		return
	for tween_value in tween_registry.values():
		var tween := tween_value as Tween
		if tween != null and tween.is_valid():
			tween.kill()
	tween_registry.clear()


func pending_transition_count() -> int:
	return tween_registry.size() if tween_registry != null else 0


func _cancel_entry(instance_id: int) -> void:
	if tween_registry == null:
		return
	var previous := tween_registry.get(instance_id) as Tween
	if previous != null and previous.is_valid():
		previous.kill()
	tween_registry.erase(instance_id)


func _finish_entry(
	view: CardView,
	instance_id: int,
	completion: Callable,
) -> void:
	if tween_registry != null:
		tween_registry.erase(instance_id)
	if view != null and is_instance_valid(view):
		view.remember_base_position()
	if completion.is_valid():
		completion.call()

func _refresh_hand() -> void:
	var hand := table.state_ref.get_player(table.view_player).hand
	var preserve_visible_identity := table._hand_identity_player == table.view_player
	var previous_views := table.hand_views.duplicate()
	var ordered_views: Array[CardView] = []
	var used: Dictionary = {}
	# First reserve every unchanged card by local visual identity/occurrence. Only
	# after that pass may an unmatched final card reuse a leftover anchor.
	for card_id_value in hand:
		var card_id := str(card_id_value)
		var matched: CardView
		if preserve_visible_identity:
			for candidate_value in previous_views:
				var candidate := candidate_value as CardView
				if (
					candidate == null
					or not candidate.visible
					or used.has(candidate.get_instance_id())
					or table._pending_removed_hand_visual_ids.has(candidate.local_visual_id)
					or candidate.card_id != card_id
				):
					continue
				matched = candidate
				used[matched.get_instance_id()] = true
				break
		ordered_views.append(matched)
	for index in range(ordered_views.size()):
		if ordered_views[index] != null:
			continue
		var matched: CardView
		# Prefer an already-hidden spare, then recycle a card that left the hand.
		for candidate_value in previous_views:
			var candidate := candidate_value as CardView
			if (
				candidate != null
				and not candidate.visible
				and not used.has(candidate.get_instance_id())
			):
				matched = candidate
				break
		if matched == null:
			for candidate_value in previous_views:
				var candidate := candidate_value as CardView
				if candidate == null or used.has(candidate.get_instance_id()):
					continue
				matched = candidate
				break
		if matched == null:
			matched = table.board_view._new_card_view()
			table.hand_surface.add_child(matched)
			previous_views.append(matched)
		_assign_new_hand_visual_id(matched)
		used[matched.get_instance_id()] = true
		ordered_views[index] = matched
	for candidate_value in previous_views:
		var candidate := candidate_value as CardView
		if candidate != null and not used.has(candidate.get_instance_id()):
			ordered_views.append(candidate)
	table.hand_views.assign(ordered_views)
	table._pending_removed_hand_visual_ids.clear()
	table._hand_identity_player = table.view_player
	for index in range(table.hand_views.size()):
		var view := table.hand_views[index]
		if index >= hand.size():
			view.visible = false
			continue
		view.visible = true
		view.configure(hand[index], null, false, index, table.view_player, "", true)
		view.set_selected(table.selected_entity_key == "hand:%d" % index)
	_layout_hand(_current_hand_card_size())

func _assign_new_hand_visual_id(view: CardView) -> void:
	if view == null:
		return
	table._hand_visual_sequence += 1
	view.set_local_visual_id("hand:%d:%d:%d" % [
		table.view_player,
		table.state_ref.revision if table.state_ref != null else -1,
		table._hand_visual_sequence,
	])

func invalidate_hand_visual_identities() -> void:
	for view in table.hand_views:
		if view != null and view.visible:
			_assign_new_hand_visual_id(view)

func prepare_hand_identity_transition(
	raw_events: Array,
	previous_snapshot: Dictionary,
) -> void:
	table._pending_removed_hand_visual_ids.clear()
	var snapshot_hand: Array = previous_snapshot.get("hand", [])
	var virtual_rows: Array[Dictionary] = []
	for snapshot_index in range(snapshot_hand.size()):
		if not snapshot_hand[snapshot_index] is Dictionary:
			continue
		var row: Dictionary = Dictionary(snapshot_hand[snapshot_index]).duplicate(true)
		row["snapshot_key"] = "snapshot:%d" % snapshot_index
		row["snapshot_index"] = snapshot_index
		virtual_rows.append(row)
	for event_index in range(raw_events.size()):
		var raw_event_value: Variant = raw_events[event_index]
		if not raw_event_value is Dictionary:
			continue
		var event := PresentationEvent.normalize(
			raw_event_value,
			table.state_ref.revision if table.state_ref != null else -1,
			table.view_player,
			event_index,
		)
		var source: Dictionary = event.get("source", {})
		var target: Dictionary = event.get("target", {})
		if (
			int(source.get("player", -1)) != table.view_player
			or str(source.get("zone", "")) != "hand"
			or str(target.get("zone", "")) == "hand"
		):
			continue
		var selected_rows := table.hand_presentation._select_virtual_hand_source_rows(event, virtual_rows)
		for row in selected_rows:
			_mark_snapshot_hand_visual_removed(
				snapshot_hand,
				int(row.get("snapshot_index", -1)),
			)
			var key := str(row.get("snapshot_key", ""))
			for virtual_index in range(virtual_rows.size() - 1, -1, -1):
				if str(virtual_rows[virtual_index].get("snapshot_key", "")) == key:
					virtual_rows.remove_at(virtual_index)
					break

func _mark_snapshot_hand_visual_removed(snapshot_hand: Array, index: int) -> void:
	if index < 0 or index >= snapshot_hand.size():
		return
	var row := snapshot_hand[index] as Dictionary
	var visual_id := str(row.get("visual_id", ""))
	if not visual_id.is_empty():
		table._pending_removed_hand_visual_ids[visual_id] = true

func _refresh_opponent_hand() -> void:
	if table.opponent_hand_surface == null or table.state_ref == null:
		return
	var opponent_player := 1 - table.view_player
	var hand_count := table.state_ref.get_player(opponent_player).hand.size()
	var visible_count := mini(
		maxi(0, hand_count),
		maxi(0, table.opponent_hand_max_visible),
	)
	while table.opponent_hand_views.size() < visible_count:
		var card := table.board_view._new_card_view()
		table.opponent_hand_surface.add_child(card)
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.focus_mode = Control.FOCUS_NONE
		card.mouse_default_cursor_shape = Control.CURSOR_ARROW
		table.opponent_hand_views.append(card)
	for index in range(table.opponent_hand_views.size()):
		var view := table.opponent_hand_views[index]
		if index >= visible_count:
			view.visible = false
			continue
		view.visible = true
		view.configure("", null, true, -1, opponent_player, "", true)
		view.set_selected(false)
		view.set_targetable(false)
		view.tooltip_text = ""
		view.accessibility_name = "对手手牌（隐藏）"
	table.opponent_hand_surface.visible = hand_count > 0
	table.opponent_hand_count_badge.visible = hand_count > 0
	table.opponent_hand_count_badge.text = str(hand_count)
	_layout_opponent_hand()

func _layout_player_hands(metrics: Dictionary) -> void:
	var center_x := float(metrics["center_x"])
	var top_margin := float(metrics["top_margin"])
	var hidden_hand_size: Vector2 = metrics["hidden_hand_size"]
	var opponent_hand_width := float(metrics["opponent_hand_width"])
	var top_hand_height := float(metrics["top_hand_height"])
	var opponent_hand_y := float(metrics["opponent_hand_y"])
	table.opponent_hand_surface.position = Vector2(
		center_x - opponent_hand_width * 0.5,
		opponent_hand_y,
	)
	table.opponent_hand_surface.size = Vector2(
		opponent_hand_width,
		top_hand_height + hidden_hand_size.y,
	)
	table.opponent_hand_count_badge.position = Vector2(
		table.opponent_hand_surface.position.x + table.opponent_hand_surface.size.x - 18.0,
		float(metrics.get("top_interaction_clearance", top_margin)) + 4.0,
	)
	table.opponent_hand_count_badge.size = Vector2(34.0, 34.0)
	table.opponent_info.position = Vector2(
		float(metrics["field_left"]),
		float(metrics["opponent_info_y"]),
	)
	table.opponent_info.size = Vector2(304.0, 24.0)

	var own_hand_y := float(metrics["own_hand_y"])
	var hand_width := float(metrics["hand_width"])
	var hand_center_x := float(metrics.get("hand_center_x", center_x))
	table.hand_scroll.position = Vector2(hand_center_x - hand_width * 0.5, own_hand_y)
	table.hand_scroll.size = Vector2(hand_width, float(metrics["own_hand_height"]))
	table.hand_surface.custom_minimum_size.y = float(metrics["own_hand_height"]) - 8.0

func _layout_hand(card_size: Vector2 = Vector2(96, 135)) -> void:
	if table.hand_surface == null:
		return
	var visible_count := 0
	for view in table.hand_views:
		if _hand_view_participates_in_layout(view):
			visible_count += 1
	var plan := BattleTableLayout.own_hand_plan(
		visible_count,
		table.hand_scroll.size.x,
		card_size,
		table.hand_minimum_spacing,
		table.hand_rotation_degrees,
	)
	_apply_hand_layout_geometry(plan, card_size)
	var items: Array[Dictionary] = plan["items"]
	var visible_index := 0
	for view in table.hand_views:
		if not _hand_view_participates_in_layout(view):
			continue
		var item: Dictionary = items[visible_index]
		view.custom_minimum_size = card_size
		view.size = card_size
		view.position = item["position"]
		view.rotation_degrees = float(item["rotation_degrees"])
		var is_selected := table.selected_entity_key == "hand:%d" % view.hand_index
		view.z_index = mini(table.HAND_CARD_MAX_Z, int(item["z_index"]))
		view.set_table_depth(0.96, true)
		view.remember_base_position()
		view.set_selected(is_selected)
		visible_index += 1
	_apply_hand_interaction_order()

func _apply_hand_layout_geometry(plan: Dictionary, card_size: Vector2) -> void:
	if table.hand_surface == null or table.hand_scroll == null:
		return
	table.hand_surface.custom_minimum_size.x = float(plan.get(
		"surface_width",
		table.hand_scroll.size.x,
	))
	var items: Array = plan.get("items", [])
	var geometry_signature := "%d|%d|%d|%d|%d|%d" % [
		items.size(),
		roundi(table.hand_scroll.size.x * 100.0),
		roundi(card_size.x * 100.0),
		roundi(card_size.y * 100.0),
		roundi(float(plan.get("content_width", 0.0)) * 100.0),
		roundi(float(plan.get("surface_width", 0.0)) * 100.0),
	]
	if geometry_signature == table._hand_layout_geometry_signature:
		return
	table._hand_layout_geometry_signature = geometry_signature
	table._hand_scroll_center_generation += 1
	var generation := table._hand_scroll_center_generation
	var center_scroll := maxi(0, roundi(float(plan.get("center_scroll", 0.0))))
	_set_hand_scroll_center(center_scroll)
	# ScrollContainer updates its range during the container sort that follows a
	# custom-minimum-table.size change. Repeat after that sort so growing from a small
	# hand cannot clamp the new center against the previous maximum.
	call_deferred(
		"_finish_hand_scroll_center",
		generation,
		center_scroll,
		0,
	)

func _set_hand_scroll_center(center_scroll: int) -> void:
	if table.hand_scroll == null:
		return
	table.hand_scroll.scroll_horizontal = maxi(0, center_scroll)

func _finish_hand_scroll_center(
	generation: int,
	center_scroll: int,
	attempt: int,
) -> void:
	if generation != table._hand_scroll_center_generation or table.hand_scroll == null:
		return
	_set_hand_scroll_center(center_scroll)
	if abs(table.hand_scroll.scroll_horizontal - center_scroll) > 1 and attempt < 2:
		call_deferred(
			"_finish_hand_scroll_center",
			generation,
			center_scroll,
			attempt + 1,
		)

func _apply_hand_interaction_order() -> void:
	if table.hand_surface == null:
		return
	# GUI picking uses sibling order for overlapping Controls. Rebuild a stable
	# canonical left-to-right order first. Hover only transforms InteractionRoot,
	# so a dense hand keeps the card on the right above the card on its left.
	# Only an explicitly selected source rises above the fan for its action UI.
	for canonical_index in range(table.hand_views.size()):
		var canonical_view := table.hand_views[canonical_index]
		if (
			canonical_view != null
			and is_instance_valid(canonical_view)
			and canonical_view.get_parent() == table.hand_surface
			and canonical_view.get_index() != canonical_index
		):
			table.hand_surface.move_child(canonical_view, canonical_index)
	var selected_hand_view: CardView
	var visible_index := 0
	for view in table.hand_views:
		if not _hand_view_participates_in_layout(view):
			continue
		view.z_index = mini(table.HAND_CARD_MAX_Z, 70 + visible_index)
		if table.selected_entity_key == "hand:%d" % view.hand_index:
			selected_hand_view = view
		visible_index += 1
	if selected_hand_view != null:
		selected_hand_view.z_index = table.SELECTED_HAND_CARD_Z
		table.hand_surface.move_child(
			selected_hand_view,
			maxi(0, table.hand_surface.get_child_count() - 1),
		)

func _snap_staged_hand_layout(card_size: Vector2) -> void:
	var visible_views: Array[CardView] = []
	for view in table.hand_views:
		if view != null and view.visible:
			visible_views.append(view)
	if visible_views.is_empty():
		return
	var stage_count := maxi(0, table.hand_presentation._presentation_hand_stage_count)
	var final_count := visible_views.size()
	var stage_plan := BattleTableLayout.own_hand_plan(
		stage_count,
		table.hand_scroll.size.x,
		card_size,
		table.hand_minimum_spacing,
		table.hand_rotation_degrees,
	)
	var final_plan := BattleTableLayout.own_hand_plan(
		final_count,
		table.hand_scroll.size.x,
		card_size,
		table.hand_minimum_spacing,
		table.hand_rotation_degrees,
	)
	_apply_hand_layout_geometry(stage_plan, card_size)
	var stage_items: Array[Dictionary] = stage_plan["items"]
	var final_items: Array[Dictionary] = final_plan["items"]
	var snapshot_hand: Array = table.presentation_runtime.snapshot.get("hand", [])
	var used_snapshot_rows: Dictionary = {}
	for index in range(visible_views.size()):
		var view := visible_views[index]
		var item: Dictionary
		if stage_count > final_count:
			var snapshot_index := _snapshot_hand_index_for_view(
				view,
				snapshot_hand,
				used_snapshot_rows,
			)
			item = (
				stage_items[snapshot_index]
				if snapshot_index >= 0 and snapshot_index < stage_items.size()
				else final_items[index]
			)
		elif index < stage_count and index < stage_items.size():
			item = stage_items[index]
		else:
			# Incoming anchors remain hidden at their eventual landing endpoints;
			# existing cards still use the smaller staged fan until contact.
			item = final_items[index]
		view.custom_minimum_size = card_size
		view.size = card_size
		view.position = item["position"]
		view.rotation_degrees = float(item["rotation_degrees"])
		view.z_index = mini(table.HAND_CARD_MAX_Z, int(item["z_index"]))
		view.set_table_depth(0.96, true)
		view.remember_base_position()
	_apply_hand_interaction_order()

func _snapshot_hand_index_for_view(
	view: CardView,
	snapshot_hand: Array,
	used_rows: Dictionary,
) -> int:
	if view == null:
		return -1
	if not view.local_visual_id.is_empty():
		for index in range(snapshot_hand.size()):
			if used_rows.has(index):
				continue
			var row := snapshot_hand[index] as Dictionary
			if str(row.get("visual_id", "")) == view.local_visual_id:
				used_rows[index] = true
				return index
	for index in range(snapshot_hand.size()):
		if used_rows.has(index):
			continue
		var row := snapshot_hand[index] as Dictionary
		if str(row.get("card_id", "")) == view.card_id:
			used_rows[index] = true
			return index
	return -1

func _hand_view_participates_in_layout(view: CardView) -> bool:
	if view == null or not view.visible:
		return false
	if table._drag_session == null or table._drag_session.source_view != view:
		return true
	return table._drag_session.state in [
		table.CARD_DRAG_SESSION.CANDIDATE,
		table.CARD_DRAG_SESSION.RETURNING,
		table.CARD_DRAG_SESSION.CANCELLED,
	]

func _current_hand_card_size() -> Vector2:
	if table.board_canvas == null or table.board_canvas.size.x <= 0.0 or table.board_canvas.size.y <= 0.0:
		return table.hand_card_size
	var metrics := table.board_view._board_layout_metrics(table.board_canvas.size.x, table.board_canvas.size.y)
	var value: Variant = metrics.get("own_hand_size", table.hand_card_size)
	return value if value is Vector2 else table.hand_card_size

func _current_opponent_hand_card_size() -> Vector2:
	if table.board_canvas == null or table.board_canvas.size.x <= 0.0 or table.board_canvas.size.y <= 0.0:
		return table.opponent_hand_card_size
	var metrics := table.board_view._board_layout_metrics(table.board_canvas.size.x, table.board_canvas.size.y)
	var value: Variant = metrics.get("hidden_hand_size", table.opponent_hand_card_size)
	return value if value is Vector2 else table.opponent_hand_card_size

func _layout_opponent_hand(card_size: Vector2 = Vector2(70, 98)) -> void:
	if table.opponent_hand_surface == null:
		return
	var visible_count := 0
	for view in table.opponent_hand_views:
		if view.visible:
			visible_count += 1
	var plan := BattleTableLayout.opponent_hand_plan(
		visible_count,
		table.opponent_hand_surface.size.x,
		card_size,
		table.opponent_hand_minimum_spacing,
		table.opponent_hand_rotation_degrees,
	)
	var items: Array[Dictionary] = plan["items"]
	var visible_index := 0
	for view in table.opponent_hand_views:
		if not view.visible:
			continue
		var item: Dictionary = items[visible_index]
		view.custom_minimum_size = card_size
		view.size = card_size
		view.position = item["position"]
		view.rotation_degrees = float(item["rotation_degrees"])
		view.z_index = int(item["z_index"])
		view.set_table_depth(0.18, false)
		view.remember_base_position()
		visible_index += 1

func _on_hand_drag_started(hand_index: int) -> void:
	if hand_index < 0 or hand_index >= table.hand_views.size():
		return
	var source_view := table.hand_views[hand_index]
	if source_view == null or not source_view.visible or source_view.card_id.is_empty():
		return
	if table._drag_session != null:
		# A parked/pending proxy owns the only visual copy of its card until the
		# authoritative transition resolves. Reject a second native drag without
		# tearing down that first transaction; clearing it here used to orphan the
		# parked entity and enabled duplicate actions from the same revision.
		source_view.cancel_drag_state()
		if source_view == table._drag_session.source_view:
			source_view.set_drag_masked(true)
		var viewport := get_viewport()
		if viewport != null and viewport.gui_is_dragging():
			viewport.gui_cancel_drag()
		if table.header:
			table.header.set_task_hint("上一张卡仍在等待结算")
		return
	table._drag_session_sequence += 1
	table._drag_session = table.CARD_DRAG_SESSION.new()
	table._drag_session.session_id = "drag:%d:%d:%d" % [
		table.state_ref.revision if table.state_ref != null else -1,
		hand_index,
		table._drag_session_sequence,
	]
	table._drag_session.state = table.CARD_DRAG_SESSION.DRAGGING
	table._drag_session.revision = table.state_ref.revision if table.state_ref != null else -1
	table._drag_session.actor = table.view_player
	table._drag_session.hand_index = hand_index
	table._drag_session.card_id = source_view.card_id
	table._drag_session.visual_id = "%s:%s" % [table._drag_session.session_id, source_view.card_id]
	table._drag_session.source_view = source_view
	table._drag_session.source_position = source_view.position
	table._drag_session.source_size = source_view.size
	table._drag_session.source_rotation = source_view.rotation_degrees
	table._drag_session.grab_offset = source_view.drag_grab_offset_local()
	source_view.set_drag_masked(true)
	_ensure_drag_proxy(_drag_pointer_position())
	table._drag_source_key = BattleInteractionController.hand_key(hand_index)
	if table.action_popover:
		table.action_popover.dismiss(false)
	table.board_view._refresh_target_hints()
	if table.header:
		table.header.set_task_hint("将卡牌拖到青色合法目标")
	_tween_drag_hand_layout()

func _on_hand_drag_ended() -> void:
	if table._drag_session == null:
		return
	table._drag_source_key = ""
	table.board_view._refresh_target_hints()
	table.board_view._refresh_header()
	if table._drag_session.is_pending():
		return
	_return_drag_session("cancelled")

func active_drag_context() -> Dictionary:
	if table._drag_session == null:
		return {}
	return {
		"session_id": table._drag_session.session_id,
		"revision": table._drag_session.revision,
		"actor": table._drag_session.actor,
		"hand_index": table._drag_session.hand_index,
		"card_id": table._drag_session.card_id,
		"state": table._drag_session.state,
		"origin_action_id": table._drag_session.origin_action_id,
	}

func mark_drag_pending(action_id: String, network_pending: bool) -> String:
	if table._drag_session == null:
		return ""
	if table.state_ref == null or not table._drag_session.matches(
		table._drag_session.hand_index,
		table._drag_session.card_id,
		table.state_ref.revision,
	):
		_return_drag_session("stale_drag")
		return ""
	table._drag_session.origin_action_id = action_id
	table._drag_session.state = (
		table.CARD_DRAG_SESSION.PENDING_AUTHORITY
		if network_pending
		else table.CARD_DRAG_SESSION.COMMITTED
	)
	if network_pending and table.header:
		table.header.set_task_hint("等待对局服务器确认…")
	return table._drag_session.session_id

func drag_session_id_for_origin(action_id: String) -> String:
	if (
		table._drag_session != null
		and not action_id.is_empty()
		and table._drag_session.origin_action_id == action_id
	):
		return table._drag_session.session_id
	return ""

func prepare_pending_drag_for_transition(session_id: String) -> void:
	if table._drag_session == null or table._drag_session.session_id != session_id:
		return
	table._presentation_drag_proxy = table._drag_session.proxy

func commit_pending_drag_source(session_id: String) -> void:
	if table._drag_session == null or table._drag_session.session_id != session_id:
		return
	if table._drag_session.source_view != null and is_instance_valid(table._drag_session.source_view):
		table._drag_session.source_view.clear_drag_mask()
	table._drag_session.state = table.CARD_DRAG_SESSION.COMMITTED
	_layout_hand(_current_hand_card_size())

func finish_pending_drag_transition(session_id: String) -> void:
	if table._drag_session == null or table._drag_session.session_id != session_id:
		return
	if table._drag_session.proxy != null and is_instance_valid(table._drag_session.proxy):
		table.motion_entities._dispose_flyer(table._drag_session.proxy)
	table._presentation_drag_proxy = null
	table._drag_session = null
	table._drag_source_key = ""
	_layout_hand(_current_hand_card_size())

func clear_pending_drag(reason: String = "cancelled") -> void:
	if table._drag_session == null:
		return
	if (
		table.state_ref != null
		and table.state_ref.revision == table._drag_session.revision
		and table._drag_session.source_view != null
		and is_instance_valid(table._drag_session.source_view)
		and table._drag_session.source_view.card_id == table._drag_session.card_id
	):
		_return_drag_session(reason)
	else:
		_clear_drag_session_immediately()

func clear_pending_drag_immediately(_reason: String = "cancelled") -> void:
	if table._drag_session == null:
		return
	_clear_drag_session_immediately()

func _park_drag_session(target_player: int, target_slot: String) -> void:
	if table._drag_session == null:
		return
	table._drag_session.release_position = _drag_pointer_position()
	table._drag_session.target_player = target_player
	table._drag_session.target_slot = target_slot
	var proxy := _ensure_drag_proxy(table._drag_session.release_position)
	if proxy == null:
		return
	var finish := table.resolve_endpoint_center({
		"player": target_player,
		"slot": target_slot,
	})
	_animate_drag_proxy(proxy, finish, 0.14, Callable())

func _ensure_drag_proxy(start: Vector2) -> Control:
	if table._drag_session == null:
		return null
	if table._drag_session.proxy != null and is_instance_valid(table._drag_session.proxy):
		return table._drag_session.proxy
	var texture := table.card_motion_layer._texture_for_card_id(table._drag_session.card_id)
	if texture == null or table.effects == null:
		return null
	var size_value: Vector2 = table._drag_session.source_size
	if size_value == Vector2.ZERO:
		size_value = _current_hand_card_size()
	var proxy := table.motion_entities._create_paper_card_token(
		texture,
		size_value,
		"DragMotionEntity",
		150,
		1.0,
		true,
	)
	proxy.set_meta("drag_session_id", table._drag_session.session_id)
	proxy.set_meta("motion_card_id", table._drag_session.card_id)
	proxy.set_meta("card_motion_entity", true)
	proxy.position = _drag_proxy_position_for_pointer(start, proxy)
	proxy.rotation_degrees = table._drag_session.source_rotation
	proxy.modulate.a = 1.0
	table.card_motion_layer.add(proxy)
	table._drag_session.proxy = proxy
	return proxy

func _return_drag_session(reason: String) -> void:
	if table._drag_session == null:
		return
	var session_id: String = table._drag_session.session_id
	table._drag_session.state = table.CARD_DRAG_SESSION.RETURNING
	var proxy := _ensure_drag_proxy(_drag_pointer_position())
	_tween_drag_hand_layout()
	var finish_pose := _drag_source_layout_pose()
	var finish: Vector2 = finish_pose.get("center", table._own_hand_center())
	if proxy == null or MotionPolicy.reduced():
		_finish_drag_return(session_id, reason)
		return
	_animate_drag_proxy(
		proxy,
		finish,
		MotionPolicy.duration("return"),
		_finish_drag_return.bind(session_id, reason),
		float(finish_pose.get("rotation_degrees", 0.0)),
	)

func _finish_drag_return(session_id: String, _reason: String = "") -> void:
	if table._drag_session == null or table._drag_session.session_id != session_id:
		return
	if table._drag_session.source_view != null and is_instance_valid(table._drag_session.source_view):
		table._drag_session.source_view.clear_drag_mask()
	if table._drag_session.proxy != null and is_instance_valid(table._drag_session.proxy):
		table.motion_entities._dispose_flyer(table._drag_session.proxy)
	table._drag_session.state = table.CARD_DRAG_SESSION.CANCELLED
	table._drag_session = null
	table._presentation_drag_proxy = null
	_layout_hand(_current_hand_card_size())

func _clear_drag_session_immediately() -> void:
	if table._drag_session == null:
		return
	if table._drag_session.source_view != null and is_instance_valid(table._drag_session.source_view):
		table._drag_session.source_view.cancel_drag_state()
	var viewport := get_viewport()
	if viewport != null and viewport.gui_is_dragging():
		viewport.gui_cancel_drag()
	if table._drag_session.proxy != null and is_instance_valid(table._drag_session.proxy):
		table.motion_entities._dispose_flyer(table._drag_session.proxy)
	table._drag_session = null
	table._presentation_drag_proxy = null
	table._drag_source_key = ""
	_layout_hand(_current_hand_card_size())

func _animate_drag_proxy(
	proxy: Control,
	finish: Vector2,
	duration: float,
	completion: Callable,
	finish_rotation: float = 0.0,
) -> void:
	if proxy == null or not is_instance_valid(proxy):
		if completion.is_valid():
			completion.call()
		return
	var instance_id := proxy.get_instance_id()
	var previous := table.card_motion_layer.tweens.get(instance_id) as Tween
	if previous != null and previous.is_valid():
		previous.kill()
	table.card_motion_layer.tweens.erase(instance_id)
	if duration <= 0.0:
		proxy.position = finish - proxy.size * 0.5
		proxy.rotation_degrees = finish_rotation
		if completion.is_valid():
			completion.call()
		return
	var tween := create_tween().set_parallel(true)
	table.card_motion_layer.bind_tween(proxy, tween)
	tween.tween_property(
		proxy,
		"position",
		finish - proxy.size * 0.5,
		duration,
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(proxy, "rotation_degrees", finish_rotation, duration).set_trans(
		Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if completion.is_valid():
		tween.chain().tween_callback(completion)

func _reconcile_drag_after_layout_change() -> void:
	if table._drag_session == null:
		return
	var proxy := table._drag_session.proxy as Control
	if proxy == null or not is_instance_valid(proxy):
		return
	match table._drag_session.state:
		table.CARD_DRAG_SESSION.DRAGGING:
			proxy.position = _drag_proxy_position_for_pointer(
				_drag_pointer_position(),
				proxy,
			)
		table.CARD_DRAG_SESSION.AWAITING_VARIANT, table.CARD_DRAG_SESSION.PENDING_AUTHORITY:
			_cancel_proxy_position_tween(proxy)
			var finish: Vector2 = (
				table.resolve_endpoint_center({
					"player": table._drag_session.target_player,
					"slot": table._drag_session.target_slot,
				})
				if not table._drag_session.target_slot.is_empty()
				else table._drag_session.release_position
			)
			proxy.position = finish - proxy.size * 0.5
		table.CARD_DRAG_SESSION.RETURNING:
			var session_id: String = table._drag_session.session_id
			_cancel_proxy_position_tween(proxy)
			var finish_pose := _drag_source_layout_pose()
			proxy.position = Vector2(
				finish_pose.get("center", table._own_hand_center()),
			) - proxy.size * 0.5
			proxy.rotation_degrees = float(finish_pose.get("rotation_degrees", 0.0))
			_finish_drag_return(session_id, "layout_changed")

func _cancel_proxy_position_tween(proxy: Control) -> void:
	if proxy == null or not is_instance_valid(proxy):
		return
	var instance_id := proxy.get_instance_id()
	var tween := table.card_motion_layer.tweens.get(instance_id) as Tween
	if tween != null and tween.is_valid():
		tween.kill()
	table.card_motion_layer.tweens.erase(instance_id)

func _tween_drag_hand_layout() -> void:
	var layout_views: Array[CardView] = []
	for view in table.hand_views:
		if _hand_view_participates_in_layout(view):
			layout_views.append(view)
	var card_size := _current_hand_card_size()
	var plan := BattleTableLayout.own_hand_plan(
		layout_views.size(),
		table.hand_scroll.size.x,
		card_size,
		table.hand_minimum_spacing,
		table.hand_rotation_degrees,
	)
	_apply_hand_layout_geometry(plan, card_size)
	var items: Array[Dictionary] = plan["items"]
	var duration := MotionPolicy.duration("hand_reflow")
	for index in range(layout_views.size()):
		var view := layout_views[index]
		var item: Dictionary = items[index]
		view.custom_minimum_size = card_size
		view.size = card_size
		view.z_index = mini(table.HAND_CARD_MAX_Z, int(item["z_index"]))
		table.hand_presentation._move_hand_card(
			view,
			item["position"],
			float(item["rotation_degrees"]),
			duration,
		)
	_apply_hand_interaction_order()

func _drag_source_layout_pose() -> Dictionary:
	if table._drag_session == null or table._drag_session.source_view == null:
		return {"center": table._own_hand_center(), "rotation_degrees": 0.0}
	var layout_views: Array[CardView] = []
	for view in table.hand_views:
		if _hand_view_participates_in_layout(view):
			layout_views.append(view)
	var card_size := _current_hand_card_size()
	var plan := BattleTableLayout.own_hand_plan(
		layout_views.size(),
		table.hand_scroll.size.x,
		card_size,
		table.hand_minimum_spacing,
		table.hand_rotation_degrees,
	)
	var source_index := layout_views.find(table._drag_session.source_view)
	if source_index < 0:
		return {"center": table._own_hand_center(), "rotation_degrees": 0.0}
	var items: Array[Dictionary] = plan["items"]
	var item: Dictionary = items[source_index]
	var local_center: Vector2 = item["position"] + card_size * 0.5
	var viewport_center: Vector2 = (
		table.hand_surface.get_global_transform_with_canvas() * local_center
	)
	return {
		"center": table._effects_local(viewport_center),
		"rotation_degrees": float(item.get("rotation_degrees", 0.0)),
	}

func _drag_proxy_position_for_pointer(pointer: Vector2, proxy: Control) -> Vector2:
	if proxy == null or table._drag_session == null:
		return pointer
	var source_size: Vector2 = table._drag_session.source_size
	var grab_offset: Vector2 = table._drag_session.grab_offset
	if source_size.x > 0.0 and source_size.y > 0.0:
		grab_offset *= Vector2(
			proxy.size.x / source_size.x,
			proxy.size.y / source_size.y,
		)
	else:
		grab_offset = proxy.size * 0.5
	var center := proxy.size * 0.5
	var rendered_grab_offset := center + (grab_offset - center).rotated(
		deg_to_rad(proxy.rotation_degrees),
	)
	return pointer - rendered_grab_offset

func _drag_pointer_position() -> Vector2:
	var viewport := get_viewport()
	if viewport != null and table.effects != null:
		return table._effects_local(viewport.get_mouse_position())
	if table._drag_session != null and table._drag_session.source_view != null:
		var source_view: CardView = table._drag_session.source_view
		if is_instance_valid(source_view) and table.effects != null:
			return table._effects_local(source_view.global_center())
	return table._own_hand_center()
