class_name BattleHandView
extends Node

var host: Node
var table: BattleTable
var tween_registry: Dictionary = {}
var _scroll_positions: Dictionary = {}
var _scroll_player := -1
var _scroll_width := 0.0


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
		if view.has_meta("physical_pose"): view.remove_meta("physical_pose")
		view.position = target_position
		view.rotation_degrees = target_rotation
		view.remember_base_position()
		if completion.is_valid():
			completion.call()
		handle.finish()
		return handle
	var tween := host.create_tween().set_parallel(true)
	if table.render3d != null:
		table.render3d.hand_fan.reflow_card(view, target_position, target_rotation, tween, duration)
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
	if table != null:
		for view in table.hand_views:
			if is_instance_valid(view) and view.has_meta("physical_pose"): view.remove_meta("physical_pose")
	if tween_registry == null:
		return
	for tween_value in tween_registry.values():
		var tween := tween_value as Tween
		if tween != null and tween.is_valid():
			tween.kill()
	tween_registry.clear()


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
		if view.has_meta("physical_pose"): view.remove_meta("physical_pose")
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

func prepare_hand_identity_transition(
	events: Array,
	previous_snapshot: Dictionary,
	final_hand: Array[String],
) -> void:
	table._pending_removed_hand_visual_ids.clear()
	var plan := table.hand_presentation.plan_hand_sources(events, previous_snapshot, final_hand)
	for rows in plan.values():
		for row in rows:
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
	_layout_opponent_hand(_current_opponent_hand_card_size())

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
		float(metrics["side_margin"]),
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
	var next_positions: Dictionary = {}
	var visible_index := 0
	for view in table.hand_views:
		if not _hand_view_participates_in_layout(view) or visible_index >= items.size():
			continue
		next_positions[view.local_visual_id] = Vector2(items[visible_index]["position"]).x + card_size.x * 0.5
		visible_index += 1
	var target_scroll := maxi(0, roundi(float(plan.get("center_scroll", 0.0))))
	if _scroll_player == table.view_player and not _scroll_positions.is_empty():
		var old_scroll := float(table.hand_scroll.scroll_horizontal)
		var old_width := _scroll_width if _scroll_width > 0.0 else table.hand_scroll.size.x
		var nearest_distance := INF
		for identity in next_positions:
			if not _scroll_positions.has(identity):
				continue
			var screen_x := float(_scroll_positions[identity]) - old_scroll
			var distance := absf(screen_x - old_width * 0.5)
			if distance < nearest_distance:
				nearest_distance = distance
				var next_screen_x := screen_x * table.hand_scroll.size.x / old_width
				target_scroll = maxi(0, roundi(float(next_positions[identity]) - next_screen_x))
	var geometry_signature := "%d|%d|%d|%d|%d|%d" % [
		items.size(),
		roundi(table.hand_scroll.size.x * 100.0),
		roundi(card_size.x * 100.0),
		roundi(card_size.y * 100.0),
		roundi(float(plan.get("content_width", 0.0)) * 100.0),
		roundi(float(plan.get("surface_width", 0.0)) * 100.0),
	]
	var same_player := _scroll_player == table.view_player
	_scroll_positions = next_positions
	_scroll_player = table.view_player
	_scroll_width = table.hand_scroll.size.x
	if geometry_signature == table._hand_layout_geometry_signature and same_player:
		return
	table._hand_layout_geometry_signature = geometry_signature
	table._hand_scroll_center_generation += 1
	var generation := table._hand_scroll_center_generation
	var maximum_scroll := maxi(0, ceili(float(plan.get("surface_width", 0.0)) - table.hand_scroll.size.x))
	var center_scroll := mini(target_scroll, maximum_scroll)
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
	return view != null and is_instance_valid(view) and view.visible


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
