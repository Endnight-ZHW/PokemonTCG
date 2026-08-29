class_name BattleBoardView
extends Node

var table: BattleTable


func configure(p_table: BattleTable) -> void:
	table = p_table


func _refresh_header(display_state: GameState = null) -> void:
	var active_state := display_state if display_state != null else table.state_ref
	if active_state == null:
		return
	if table.header:
		table.header.update_header(
			active_state,
			table.view_player,
			table.ai_thinking,
			_current_task_hint(),
		)
	else:
		var display_actor := (
			active_state.setup_actor_idx
			if (
				active_state.phase == "SETUP"
				and active_state.setup_actor_idx in [0, 1]
			)
			else active_state.active_player_idx
		)
		table.turn_label.text = "第 %d 回合 · %s · 玩家 %d" % [
			active_state.turn_number,
			table._phase_name(active_state.phase),
			display_actor + 1,
		]


func _refresh_field() -> void:
	_refresh_field_info(table.state_ref)
	var own := table.state_ref.get_player(table.view_player)
	var opponent := table.state_ref.get_player(1 - table.view_player)
	_configure_slot(table.opponent_active, opponent.active, 1 - table.view_player, "active")
	_configure_slot(table.own_active, own.active, table.view_player, "active")
	for index in range(5):
		_configure_slot(
			table.opponent_bench[index],
			opponent.bench[index],
			1 - table.view_player,
			"bench_%d" % index,
		)
		_configure_slot(
			table.own_bench[index],
			own.bench[index],
			table.view_player,
			"bench_%d" % index,
		)
	_refresh_field_zones(own, opponent)


func _refresh_field_info(display_state: GameState) -> void:
	if display_state == null:
		return
	var own := display_state.get_player(table.view_player)
	var opponent := display_state.get_player(1 - table.view_player)
	table.opponent_info.text = "%s　手牌 %d　牌库 %d　奖赏卡 %d" % [
		opponent.name,
		opponent.hand.size(),
		opponent.deck.size(),
		opponent.prizes.size(),
	]
	table.own_info.text = "%s　手牌 %d　牌库 %d　奖赏卡 %d" % [
		own.name,
		own.hand.size(),
		own.deck.size(),
		own.prizes.size(),
	]
	_refresh_turn_allowance_chips(own)


func _refresh_field_zones(own: PlayerState, opponent: PlayerState) -> void:
	(table.zones["opponent_deck"] as ZoneView).configure(
		"牌库",
		"",
		opponent.deck.size(),
		true,
		table._zone_context(1 - table.view_player, "deck", [], opponent.deck.size(), true),
	)
	(table.zones["opponent_discard"] as ZoneView).configure(
		"弃牌",
		opponent.discard[-1] if not opponent.discard.is_empty() else "",
		opponent.discard.size(),
		false,
		table._zone_context(1 - table.view_player, "discard", opponent.discard, opponent.discard.size(), false),
	)
	(table.zones["opponent_prizes"] as ZoneView).configure(
		"奖赏卡",
		"",
		opponent.prizes.size(),
		true,
		table._zone_context(1 - table.view_player, "prizes", [], opponent.prizes.size(), true),
	)
	(table.zones["own_deck"] as ZoneView).configure(
		"牌库",
		"",
		own.deck.size(),
		true,
		table._zone_context(table.view_player, "deck", [], own.deck.size(), true),
	)
	(table.zones["own_discard"] as ZoneView).configure(
		"弃牌",
		own.discard[-1] if not own.discard.is_empty() else "",
		own.discard.size(),
		false,
		table._zone_context(table.view_player, "discard", own.discard, own.discard.size(), false),
	)
	(table.zones["own_prizes"] as ZoneView).configure(
		"奖赏卡",
		"",
		own.prizes.size(),
		true,
		table._zone_context(table.view_player, "prizes", [], own.prizes.size(), true),
	)
	(table.zones["stadium"] as ZoneView).configure(
		"竞技场",
		table.state_ref.stadium_card_id,
		0 if table.state_ref.stadium_card_id.is_empty() else 1,
		false,
		table._zone_context(-1, "stadium", [table.state_ref.stadium_card_id] if not table.state_ref.stadium_card_id.is_empty() else [], 0 if table.state_ref.stadium_card_id.is_empty() else 1, false),
	)


func _refresh_actions() -> void:
	table.interaction_router.rebuild(_routed_action_rows(), table.selected_entity_key)
	if table.hud:
		table.hud.update_phase(table.state_ref, table.view_player, table.ai_thinking, table.game_mode, table.action_rows)
	table.phase_advance_button = table.hud.phase_advance_button if table.hud else null

	# CardView only receives read-only legality state. It never creates action
	# buttons and never derives rules from card data.
	for hand_view in table.hand_views:
		if not hand_view.visible:
			continue
		var source_key := BattleInteractionController.hand_key(hand_view.hand_index)
		var source_actionable := table.interaction_router.has_source(source_key)
		hand_view.set_interaction_state(
			source_actionable,
			_disabled_reason_for_source(source_key) if hand_view.selected and not source_actionable else "",
		)
	for slot_key_value in table.slot_views.keys():
		var slot_key := str(slot_key_value)
		var slot_view := table.slot_views[slot_key] as CardView
		var source_key := "pokemon:%s" % slot_key
		var source_actionable := table.interaction_router.has_source(source_key)
		slot_view.set_interaction_state(
			source_actionable,
			_disabled_reason_for_source(source_key) if slot_view.selected and not source_actionable else "",
		)

	var stadium_zone := table.zones["stadium"] as ZoneView
	var stadium_actionable := table.interaction_router.has_source("stadium")
	stadium_zone.set_action({})
	stadium_zone.set_action_menu(stadium_actionable)
	stadium_zone.set_actionable(stadium_actionable)
	for scene_key in ["own_discard", "opponent_discard"]:
		var discard_zone := table.zones[scene_key] as ZoneView
		var discard_player := (
			table.view_player if scene_key == "own_discard" else 1 - table.view_player
		)
		var discard_actionable := table.interaction_router.has_source(
			BattleInteractionController.zone_key(discard_player, "discard"),
		)
		discard_zone.set_action({})
		discard_zone.set_action_menu(discard_actionable)
		discard_zone.set_actionable(discard_actionable)
	_refresh_action_popover()


func _refresh_log(display_state: GameState = null) -> void:
	var active_state := display_state if display_state != null else table.state_ref
	if active_state == null:
		return
	if table.log_panel:
		table.log_panel.update_entries(active_state.action_log)
		return
	var lines: Array[String] = []
	for index in range(active_state.action_log.size()):
		lines.append("[color=#62d7ff]◆[/color] " + active_state.action_log[index])
	if table.log_label:
		table.log_label.text = "\n".join(lines)
		table.log_label.scroll_to_line(maxi(0, lines.size() - 1))


func _refresh_target_hints() -> void:
	var selected_rows := _rows_for_active_selection()
	# A drag is an explicit interaction with its own source card. It must take
	# precedence over any card that happened to remain selected before the drag;
	# otherwise the table highlights the old card's targets and can reject a
	# completely legal drop from the card currently under the pointer.
	if not table._drag_source_key.is_empty():
		selected_rows = table.interaction_router.rows_for_source(table._drag_source_key)
	var selected_target_labels: Dictionary = {}
	for row in selected_rows:
		var action := row.get("action") as GameAction
		if action == null:
			continue
		for target_key in BattleInteractionController.target_keys_for_action(action, row):
			selected_target_labels[target_key] = _target_hint_for_action(action)
	for target_key_value in table.choice_target_options.keys():
		var choice_value: Variant = table.choice_target_options[target_key_value]
		selected_target_labels[str(target_key_value)] = (
			"选择能量"
			if choice_value is Dictionary
			and str(Dictionary(choice_value).get("kind", "")) == "attachment_group"
			else "选择"
		)

	for slot_key_value in table.slot_views.keys():
		var slot_key := str(slot_key_value)
		var target_key := "pokemon:%s" % slot_key
		var view := table.slot_views[slot_key] as CardView
		var allowed_hand_indices: Array[int] = []
		for source_key in table.interaction_router.source_keys():
			if not source_key.begins_with("hand:"):
				continue
			if table.interaction_router.is_target_legal(source_key, target_key):
				allowed_hand_indices.append(source_key.trim_prefix("hand:").to_int())
		var source_key := target_key
		var source_actionable := table.interaction_router.has_source(source_key)
		var disabled_reason := (
			_disabled_reason_for_source(source_key)
			if view.selected and not source_actionable
			else ""
		)
		var target_hint := str(selected_target_labels.get(target_key, ""))
		var slot_choice_value: Variant = table.choice_target_options.get(target_key)
		var is_attachment_source := (
			slot_choice_value is Dictionary
			and str(Dictionary(slot_choice_value).get("kind", ""))
			== "attachment_group"
		)
		if view.has_method("set_target_accent"):
			view.call(
				"set_target_accent",
				DesignTokens.GOLD if is_attachment_source else DesignTokens.CYAN,
			)
		view.set_interaction_state(
			source_actionable,
			disabled_reason,
			target_hint,
			allowed_hand_indices,
			not is_attachment_source,
		)
		if target_hint.is_empty():
			view.set_targetable(false)

	var stadium_hand_indices: Array[int] = []
	for source_key in table.interaction_router.source_keys():
		if source_key.begins_with("hand:"):
			var hand_index := source_key.trim_prefix("hand:").to_int()
			if table.interaction_router.is_drop_legal(hand_index, table.view_player, "stadium"):
				stadium_hand_indices.append(hand_index)
	(table.zones["stadium"] as ZoneView).set_drop_target(
		table.view_player,
		"stadium",
		stadium_hand_indices,
	)
	var stadium_highlighted := false
	if not table._drag_source_key.is_empty():
		for row in selected_rows:
			var action := row.get("action") as GameAction
			if action and "stadium" in BattleInteractionController.drag_target_keys_for_action(action, row):
				stadium_highlighted = true
				break
	(table.zones["stadium"] as ZoneView).set_drop_highlight(stadium_highlighted)
	for own_zone in [true, false]:
		var zone_key := "own_prizes" if own_zone else "opponent_prizes"
		var prize_player := table.view_player if own_zone else 1 - table.view_player
		var prize_zone := table.zones[zone_key] as ZoneView
		var has_choice := false
		for index in range(prize_zone.count):
			if table.choice_target_options.has(
				"prize:%d:%d" % [prize_player, index]
			):
				has_choice = true
				break
		prize_zone.set_actionable(has_choice)


func _configure_slot(
	view: CardView,
	pokemon: PokemonState,
	player: int,
	slot_name: String,
) -> void:
	table.slot_views["%d:%s" % [player, slot_name]] = view
	var setup_hidden := (
		pokemon != null
		and table.state_ref != null
		and table.state_ref.phase == "SETUP"
		and table.state_ref.setup_stage != GameState.SETUP_COMPLETE
		and player != table.view_player
	)
	view.configure(
		pokemon.card_id if pokemon and not setup_hidden else "",
		pokemon if not setup_hidden else null,
		setup_hidden,
		-1,
		player,
		slot_name,
		false,
	)
	view.configure_target(player, slot_name)
	view.set_empty_label("战斗区" if slot_name == "active" else "备战 %d" % (
		slot_name.trim_prefix("bench_").to_int() + 1
	))
	view.set_selected(table.selected_entity_key == "pokemon:%d:%s" % [player, slot_name])


func _layout_board() -> void:
	if table.board_canvas == null:
		return
	var width := table.board_canvas.size.x
	var height := table.board_canvas.size.y
	if width <= 0.0 or height <= 0.0:
		return
	# A responsive layout invalidates every hand-space endpoint. Cancel the old
	# property owners before writing rebased coordinates so a stale Tween cannot
	# pull cards back toward the pre-resize layout on the following frame.
	table.hand_presentation._clear_hand_layout_tweens()
	var metrics := _board_layout_metrics(width, height)
	table.hand_view._layout_player_hands(metrics)
	var field_plan := BattleTableLayout.field_plan(metrics, table.bench_spacing)
	_layout_field_slots(metrics, field_plan)
	_layout_table_zones(metrics, field_plan)
	table.presentation_runtime._reposition_slot_state_covers()
	_layout_own_status(metrics, field_plan)
	table.hand_view._layout_opponent_hand(metrics["hidden_hand_size"])
	table.hand_presentation._reposition_opponent_hand_proxies()
	if table.hand_presentation._presentation_hand_geometry_staged:
		table.hand_view._snap_staged_hand_layout(metrics["own_hand_size"])
	else:
		table.hand_view._layout_hand(metrics["own_hand_size"])
	_layout_overlay_drawers()
	_layout_coin_showcase()
	table.hand_view._reconcile_drag_after_layout_change()
	table._refresh_ai_thinking_indicator()
	if table.playmat:
		table.playmat.queue_redraw()
	if table.effects:
		table.effects.queue_redraw()
	if table.world_feedback:
		table.world_feedback.queue_redraw()


func _layout_coin_showcase() -> void:
	if table.coin_showcase == null:
		return
	var showcase_size := table.coin_showcase.custom_minimum_size
	table.coin_showcase.size = showcase_size
	table.coin_showcase.position = Vector2(
		maxf(16.0, (table.size.x - showcase_size.x) * 0.5),
		maxf(16.0, (table.size.y - showcase_size.y) * 0.5),
	)


func _board_layout_metrics(width: float, height: float) -> Dictionary:
	return BattleTableLayout.board_metrics(width, height, {
		"active_card_size": table.active_card_size,
		"bench_card_size": table.bench_card_size,
		"zone_size": table.zone_size,
		"hand_card_size": table.hand_card_size,
		"opponent_hand_card_size": table.opponent_hand_card_size,
		"table_side_margin": table.table_side_margin,
		"table_top_margin": table.table_top_margin,
		"table_bottom_margin": table.table_bottom_margin,
		"hand_bottom_padding": table.hand_bottom_padding,
	})


func _layout_field_slots(metrics: Dictionary, plan: Dictionary) -> void:
	var active_size: Vector2 = plan["active_size"]
	var bench_size: Vector2 = plan["bench_size"]
	var opponent_bench_centers: Array[Vector2] = plan["opponent_bench_centers"]
	var own_bench_centers: Array[Vector2] = plan["own_bench_centers"]
	var opponent_bench_rects: Array[Rect2] = plan["opponent_bench_rects"]
	var own_bench_rects: Array[Rect2] = plan["own_bench_rects"]
	for index in range(5):
		_place_perspective_card(
			table.opponent_bench[index],
			opponent_bench_centers[index],
			bench_size,
			metrics,
			-2.4 + float(index - 2) * 0.22,
			index,
		)
		_place_perspective_card(
			table.own_bench[index],
			own_bench_centers[index],
			bench_size,
			metrics,
			2.4 + float(index - 2) * 0.22,
			20 + index,
		)
	_place_perspective_card(
		table.opponent_active,
		plan["opponent_active_center"],
		active_size,
		metrics,
		-1.2,
		12,
	)
	_place_perspective_card(
		table.own_active,
		plan["own_active_center"],
		active_size,
		metrics,
		1.2,
		34,
	)
	_update_playmat_field_guides(
		opponent_bench_rects,
		own_bench_rects,
		plan["opponent_active_rect"],
		plan["own_active_rect"],
		metrics,
	)


func _layout_table_zones(metrics: Dictionary, field_plan: Dictionary) -> void:
	var plan := BattleTableLayout.zone_plan(metrics, field_plan)
	var positions: Dictionary = plan["positions"]
	var zone_visual_size: Vector2 = plan["size"]
	for key in [
		"opponent_prizes",
		"opponent_deck",
		"opponent_discard",
		"stadium",
		"own_discard",
		"own_deck",
		"own_prizes",
	]:
		var placed_position: Vector2 = positions[key]
		var placed_size := zone_visual_size
		if key == "stadium":
			var stadium_scale := float(plan.get("stadium_scale", 1.0))
			placed_size *= stadium_scale
			placed_position += (zone_visual_size - placed_size) * 0.5
		_place_perspective_zone(key, placed_position, placed_size, metrics)
	_layout_prize_stack_bounds(metrics)
	_layout_pile_docks(metrics)


func _layout_prize_stack_bounds(metrics: Dictionary) -> void:
	var layout_scale := float(metrics["layout_scale"])
	var left_safe_edge := float(metrics["left_zone_x"])
	var top_safe_edge := maxf(
		70.0,
		float(metrics["top_interaction_clearance"])
			+ clampf(8.0 * layout_scale, 6.0, 10.0),
	)
	var bottom_safe_edge := (
		float(metrics["height"])
		- clampf(18.0 * layout_scale, 14.0, 20.0)
	)
	var right_safe_edge := float(metrics["stadium_x"]) - clampf(
		14.0 * layout_scale,
		11.0,
		16.0,
	)
	var stadium := table.zones.get("stadium") as ZoneView
	if stadium:
		var stadium_bounds := _visual_rect_in_control(
			stadium,
			Rect2(Vector2.ZERO, stadium.size).grow(4.0),
			table.board_canvas,
		)
		right_safe_edge = stadium_bounds.position.x - clampf(
			10.0 * layout_scale,
			8.0,
			12.0,
		)
	for key in ["opponent_prizes", "own_prizes"]:
		var prize_stack := table.zones.get(key) as ZoneView
		if prize_stack == null:
			continue
		# The root already spans the six-card fan. Transform all capacity corners so
		# its subtle table rotation is included in the safe-area calculation.
		var visual_bounds := _visual_rect_in_control(
			prize_stack,
			prize_stack.get_stack_visual_max_rect().grow(6.0),
			table.board_canvas,
		)
		var minimum_shift := Vector2(
			left_safe_edge - visual_bounds.position.x,
			top_safe_edge - visual_bounds.position.y,
		)
		var maximum_shift := Vector2(
			right_safe_edge - visual_bounds.end.x,
			bottom_safe_edge - visual_bounds.end.y,
		)
		var safe_shift := Vector2(
			(
				clampf(0.0, minimum_shift.x, maximum_shift.x)
				if minimum_shift.x <= maximum_shift.x
				else (minimum_shift.x + maximum_shift.x) * 0.5
			),
			(
				clampf(0.0, minimum_shift.y, maximum_shift.y)
				if minimum_shift.y <= maximum_shift.y
				else (minimum_shift.y + maximum_shift.y) * 0.5
			),
		)
		prize_stack.position += safe_shift


func _visual_rect_in_control(
	control: Control,
	local_rect: Rect2,
	target: CanvasItem,
) -> Rect2:
	if control == null or target == null:
		return Rect2()
	var transform_to_target := (
		target.get_global_transform_with_canvas().affine_inverse()
		* control.get_global_transform_with_canvas()
	)
	var points := PackedVector2Array([
		transform_to_target * local_rect.position,
		transform_to_target * Vector2(local_rect.end.x, local_rect.position.y),
		transform_to_target * local_rect.end,
		transform_to_target * Vector2(local_rect.position.x, local_rect.end.y),
	])
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return Rect2(minimum, maximum - minimum)


func _layout_pile_docks(metrics: Dictionary) -> void:
	if table.playmat == null:
		return
	var guides: Array[Dictionary] = []
	var layout_scale := float(metrics["layout_scale"])
	var horizontal_padding := clampf(4.8 * layout_scale, 4.0, 5.5)
	var vertical_padding := clampf(7.5 * layout_scale, 6.0, 9.0)
	var pile_gap := float(metrics["pile_gap"])
	var outer_right := minf(
		float(metrics["command_dock_left"])
		- float(metrics["zone_gap"])
		+ float(metrics.get("pile_dock_shift", 0.0)),
		float(metrics["width"]) - float(metrics["side_margin"]),
	)
	var right_safe_edge := minf(
		outer_right + clampf(2.0 * layout_scale, 1.5, 2.5),
		float(metrics["width"]) - float(metrics["side_margin"]),
	)
	var top_safe_edge := maxf(
		70.0,
		float(metrics["top_interaction_clearance"])
			+ clampf(8.0 * layout_scale, 6.0, 10.0),
	)
	var bottom_safe_edge := (
		float(metrics["height"])
		- clampf(18.0 * layout_scale, 14.0, 20.0)
	)
	for row in [
		{"prefix": "opponent", "side": "opponent"},
		{"prefix": "own", "side": "own"},
	]:
		var prefix := str(row["prefix"])
		var deck := table.zones.get("%s_deck" % prefix) as ZoneView
		var discard := table.zones.get("%s_discard" % prefix) as ZoneView
		if deck == null or discard == null:
			continue
		# Anchor the rendered card table.size, not only the planner's base table.size, to the
		# command-dock clearance. Near-side perspective therefore cannot consume
		# the reserved gap on wide or compact screens.
		discard.position.x = outer_right - discard.size.x
		deck.position.x = discard.position.x - deck.size.x - pile_gap
		# Top cards no longer overlap; matching Z lets the later discard sibling
		# naturally cover only any decorative paper edge that reaches the gap.
		deck.z_index = discard.z_index
		# Use transformed AABBs for both the top-card recess and full paper stack.
		# ZoneView carries a subtle perspective rotation and draws shadows outside
		# its raw rect, so position/table.size merging alone clips the lower-left depth.
		var deck_rect := _visual_rect_in_control(
			deck,
			deck.get_stack_face_rect().grow(2.5),
			table.board_canvas,
		)
		var discard_rect := _visual_rect_in_control(
			discard,
			discard.get_stack_face_rect().grow(2.5),
			table.board_canvas,
		)
		var deck_visual := _visual_rect_in_control(
			deck,
			deck.get_stack_visual_max_rect().grow(6.0),
			table.board_canvas,
		)
		var discard_visual := _visual_rect_in_control(
			discard,
			discard.get_stack_visual_max_rect().grow(6.0),
			table.board_canvas,
		)
		var visual_bounds := deck_visual.merge(discard_visual)
		var dock_rect := Rect2(
			visual_bounds.position - Vector2(horizontal_padding, vertical_padding),
			visual_bounds.size + Vector2(horizontal_padding, vertical_padding) * 2.0,
		)
		var safe_shift := Vector2.ZERO
		if dock_rect.end.x > right_safe_edge:
			safe_shift.x = right_safe_edge - dock_rect.end.x
		if prefix == "own" and dock_rect.end.y > bottom_safe_edge:
			safe_shift.y = bottom_safe_edge - dock_rect.end.y
		elif prefix == "opponent" and dock_rect.position.y < top_safe_edge:
			safe_shift.y = top_safe_edge - dock_rect.position.y
		if not safe_shift.is_zero_approx():
			deck.position += safe_shift
			discard.position += safe_shift
			deck_rect.position += safe_shift
			discard_rect.position += safe_shift
			dock_rect.position += safe_shift
		guides.append({
			"rect": dock_rect,
			"deck_rect": deck_rect,
			"discard_rect": discard_rect,
			"side": str(row["side"]),
			"depth": (deck.table_depth + discard.table_depth) * 0.5,
		})
	table.playmat.set_pile_guides(guides)


func _place_perspective_card(
	view: CardView,
	center: Vector2,
	base_size: Vector2,
	metrics: Dictionary,
	rotation_value: float,
	z_bias: int,
) -> void:
	var row := _perspective_card_rect(center, base_size, metrics)
	var depth := float(row.get("depth", 0.5))
	var rect: Rect2 = row.get("rect", Rect2(center - base_size * 0.5, base_size))
	table._place_card(
		view,
		rect.position,
		rect.size,
		depth,
		rotation_value,
		int(10 + depth * 42.0) + z_bias,
	)


func _perspective_card_rect(
	center: Vector2,
	base_size: Vector2,
	metrics: Dictionary,
) -> Dictionary:
	return BattleTableLayout.perspective_card_rect(center, base_size, metrics)


func _update_playmat_field_guides(
	opponent_bench_rects: Array[Rect2],
	own_bench_rects: Array[Rect2],
	opponent_active_rect: Rect2,
	own_active_rect: Rect2,
	metrics: Dictionary,
) -> void:
	if table.playmat == null:
		return
	var guides: Array[Dictionary] = []
	guides.append({
		"kind": "bench",
		"side": "opponent",
		"rect": _union_rects(opponent_bench_rects).grow(
			12.0 * float(metrics["layout_scale"])
		),
		"slots": opponent_bench_rects,
		"depth": _perspective_depth(_union_rects(opponent_bench_rects).get_center().y, metrics),
	})
	guides.append({
		"kind": "bench",
		"side": "own",
		"rect": _union_rects(own_bench_rects).grow(
			12.0 * float(metrics["layout_scale"])
		),
		"slots": own_bench_rects,
		"depth": _perspective_depth(_union_rects(own_bench_rects).get_center().y, metrics),
	})
	guides.append({
		"kind": "active",
		"side": "opponent",
		"rect": opponent_active_rect,
		"depth": _perspective_depth(opponent_active_rect.get_center().y, metrics),
	})
	guides.append({
		"kind": "active",
		"side": "own",
		"rect": own_active_rect,
		"depth": _perspective_depth(own_active_rect.get_center().y, metrics),
	})
	table.playmat.set_field_guides(guides)


func _union_rects(rects: Array[Rect2]) -> Rect2:
	return BattleTableLayout.union_rects(rects)


func _place_perspective_zone(
	key: String,
	position_value: Vector2,
	base_size: Vector2,
	metrics: Dictionary,
) -> void:
	var center_y := position_value.y + base_size.y * 0.5
	var depth := _perspective_depth(center_y, metrics)
	var size_value := base_size * lerpf(0.88, 1.05, depth)
	var near_side := depth >= 0.52
	var adjusted := position_value
	if near_side:
		adjusted.y -= (size_value.y - base_size.y) * 0.5
	table._place_zone(
		key,
		adjusted,
		size_value,
		depth,
		-1.6 if depth < 0.45 else 1.2,
		int(8 + depth * 34.0),
	)
	var zone := table.zones.get(key) as ZoneView
	if zone and zone.stack_visual_mode == "prizes":
		# Keep the card face at the perspective table.size while the ZoneView root grows
		# to the six-card capacity, making the complete visible fan interactive.
		zone.set_stack_card_size(size_value)


func _perspective_depth(y: float, metrics: Dictionary) -> float:
	return BattleTableLayout.perspective_depth(y, metrics)


func _layout_overlay_drawers() -> void:
	if table.hud:
		var overlay_width := maxf(504.0, table.hud.get_combined_minimum_size().x)
		var overlay_height := maxf(400.0, table.size.y - 80.0)
		table.hud.position = Vector2(
			maxf(
				0.0,
				table.size.x - overlay_width - BattlePhaseHud.DOCK_RIGHT_MARGIN,
			),
			68.0,
		)
		table.hud.size = Vector2(overlay_width, overlay_height)
	if table.action_popover and table.action_popover.visible:
		_reposition_action_popover()
	if table.detail_panel and table.detail_panel.visible:
		_layout_detail_panel()
	if table.action_popover and table.action_popover.visible:
		_reposition_action_popover()


func _on_log_drawer_toggled(is_open: bool) -> void:
	if is_open and table.action_popover and table.action_popover.visible:
		table.action_popover.dismiss()
	# BattlePhaseHud completes its own drawer layout after emitting the signal.
	# Reflow transient side surfaces on the following frame using final geometry.
	call_deferred("_layout_overlay_drawers")


func _layout_detail_panel() -> void:
	if table.detail_panel == null or table.board_panel == null:
		return
	var inverse := table.get_global_transform_with_canvas().affine_inverse()
	var board_global_rect := table.board_panel.get_global_rect()
	var board_start := inverse * board_global_rect.position
	var board_end := inverse * board_global_rect.end
	var board_rect := Rect2(board_start, board_end - board_start)
	var inset := 12.0
	var safe_rect := Rect2(
		board_rect.position + Vector2(inset, inset),
		board_rect.size - Vector2(inset * 2.0, inset * 2.0),
	)
	if safe_rect.size.x <= 1.0 or safe_rect.size.y <= 1.0:
		return

	# The detail surface owns the fixed left corridor between both six-card prize
	# rows. Capacity bounds keep this position stable as prizes are taken. The
	# panel's shadow halo participates in every bound, so the rendered surface—not
	# merely its Control rectangle—stays clear of prizes and Stadium.
	var detail_halo := 10.0
	var corridor_top := safe_rect.position.y
	var corridor_bottom := safe_rect.end.y
	var prize_gap := 10.0
	var opponent_prizes := table.zones.get("opponent_prizes") as ZoneView
	if opponent_prizes:
		var opponent_bounds := _visual_rect_in_control(
			opponent_prizes,
			opponent_prizes.get_stack_visual_max_rect().grow(6.0),
			table,
		)
		corridor_top = maxf(
			corridor_top,
			opponent_bounds.end.y + prize_gap + detail_halo,
		)
	var own_prizes := table.zones.get("own_prizes") as ZoneView
	if own_prizes:
		var own_bounds := _visual_rect_in_control(
			own_prizes,
			own_prizes.get_stack_visual_max_rect().grow(6.0),
			table,
		)
		corridor_bottom = minf(
			corridor_bottom,
			own_bounds.position.y - prize_gap - detail_halo,
		)

	var minimum_fixed_x := safe_rect.position.x + detail_halo
	var maximum_detail_right := safe_rect.end.x - detail_halo
	var stadium := table.zones.get("stadium") as ZoneView
	if stadium:
		var stadium_bounds := _visual_rect_in_control(
			stadium,
			Rect2(Vector2.ZERO, stadium.size).grow(4.0),
			table,
		)
		maximum_detail_right = minf(
			maximum_detail_right,
			stadium_bounds.position.x - 8.0 - detail_halo,
		)

	var available_width := maxf(1.0, maximum_detail_right - minimum_fixed_x)
	var available_height := maxf(1.0, corridor_bottom - corridor_top)
	var component := table.detail_panel as BattleDetailPanel
	var use_bottom_layout := (
		available_width < BattleDetailPanel.NORMAL_PANEL_SIZE.x
		or available_height < BattleDetailPanel.NORMAL_PANEL_SIZE.y
	)
	if component:
		component.set_compact_layout(use_bottom_layout)
	var base_panel_size := (
		component.layout_size()
		if component
		else table.detail_panel.get_combined_minimum_size()
	)
	if base_panel_size.x <= 1.0 or base_panel_size.y <= 1.0:
		base_panel_size = BattleDetailPanel.NORMAL_PANEL_SIZE
	table.detail_panel.pivot_offset = Vector2.ZERO
	table.detail_panel.scale = Vector2.ONE
	if use_bottom_layout:
		# A narrow prize corridor must not make text and touch targets microscopic.
		# Dock the preview at the bottom of the safe board instead; DetailText owns
		# its vertical scrolling while the table.header and 48 px close action stay fixed.
		var bottom_size := Vector2(
			minf(base_panel_size.x, safe_rect.size.x - detail_halo * 2.0),
			minf(base_panel_size.y, safe_rect.size.y - detail_halo * 2.0),
		)
		bottom_size.x = maxf(1.0, bottom_size.x)
		bottom_size.y = maxf(1.0, bottom_size.y)
		var bottom_position := Vector2(
			roundf(safe_rect.position.x + (safe_rect.size.x - bottom_size.x) * 0.5),
			roundf(safe_rect.end.y - bottom_size.y - detail_halo),
		)
		if table.action_popover and table.action_popover.visible:
			var popover_global := table.action_popover.panel_global_rect()
			var popover_start := inverse * popover_global.position
			var popover_end := inverse * popover_global.end
			var popover_rect := Rect2(popover_start, popover_end - popover_start)
			var candidate_rect := Rect2(bottom_position, bottom_size)
			if candidate_rect.intersects(popover_rect.grow(8.0)):
				var right_x := popover_rect.end.x + 12.0
				var left_x := popover_rect.position.x - bottom_size.x - 12.0
				if right_x + bottom_size.x <= safe_rect.end.x - detail_halo:
					bottom_position.x = right_x
				elif left_x >= safe_rect.position.x + detail_halo:
					bottom_position.x = left_x
		table.detail_panel.position = bottom_position
		table.detail_panel.size = bottom_size
		return
	var panel_size := base_panel_size

	var maximum_fixed_x := maximum_detail_right - panel_size.x
	var fixed_x := clampf(
		minimum_fixed_x,
		minimum_fixed_x,
		maxf(minimum_fixed_x, maximum_fixed_x),
	)
	var corridor_height := maxf(0.0, corridor_bottom - corridor_top)
	var fixed_y := roundf(
		corridor_top + (corridor_height - panel_size.y) * 0.5
	)
	fixed_y = clampf(
		fixed_y,
		corridor_top,
		maxf(corridor_top, corridor_bottom - panel_size.y),
	)
	table.detail_panel.position = Vector2(fixed_x, fixed_y)
	table.detail_panel.size = base_panel_size


func _new_card_view() -> CardView:
	var view := table.CARD_SCENE.instantiate() as CardView
	table._bind_card_view(view)
	return view


func _compact_card_action_row(row: Dictionary) -> Dictionary:
	var result := row.duplicate()
	var action: GameAction = row.get("action")
	if action == null:
		return result
	match action.kind:
		"PLAY_BASIC":
			result["label"] = "放置到场上"
		"EVOLVE":
			result["label"] = "进化"
		"ATTACH_ENERGY":
			result["label"] = "附能"
		"PLAY_TRAINER":
			var trainer_type := _trainer_type_for_action(action)
			result["label"] = (
				"打出竞技场"
				if trainer_type == "Stadium"
				else "附着道具"
				if trainer_type in ["Tool", "Pokémon Tool"]
				else "使用"
			)
		"DECLARE_ATTACK":
			result.merge(_attack_popover_metadata(action, row), true)
		"USE_ABILITY":
			result["label"] = "特性 · %s（可用）" % str(
				action.ability_name("发动特性"),
			)
			result["hint"] = "发动特性"
		"RETREAT":
			result["label"] = "撤退到这里 · %s" % _retreat_compact_suffix(action)
		"PROMOTE":
			result["label"] = "晋升为战斗宝可梦"
		"USE_STADIUM":
			result["label"] = "发动效果"
	return result


func _trainer_type_for_action(action: GameAction) -> String:
	if action == null or table.state_ref == null:
		return ""
	var hand_index := action.hand_index()
	if hand_index < 0 or action.actor not in [0, 1]:
		return ""
	var hand := table.state_ref.get_player(action.actor).hand
	if hand_index >= hand.size():
		return ""
	var card_id := str(hand[hand_index])
	if table.catalog.is_stadium(card_id):
		return "Stadium"
	if table.catalog.is_tool(card_id):
		return "Tool"
	if table.catalog.is_supporter(card_id):
		return "Supporter"
	if table.catalog.is_item(card_id):
		return "Item"
	return str(table.catalog.get_card(card_id).get("trainer_type", ""))


func _attack_popover_metadata(action: GameAction, row: Dictionary) -> Dictionary:
	var fallback := str(row.get("label", "攻击")).trim_prefix("攻击 · ")
	var result := {
		"label": fallback,
		"hint": "攻击后结束回合",
	}
	if table.state_ref == null or action.actor not in [0, 1]:
		return result
	var active := table.state_ref.get_player(action.actor).active
	if active == null:
		return result
	var attacks: Array = table.catalog.get_card(active.card_id).get("attacks", [])
	var attack_index := action.attack_index()
	if attack_index < 0 or attack_index >= attacks.size():
		return result
	var attack: Dictionary = attacks[attack_index]
	var cost_labels: Array[String] = []
	var attack_cost: Array = attack.get("cost", [])
	for value in attack_cost:
		cost_labels.append({
			"Grass": "草", "Fire": "火", "Water": "水", "Lightning": "雷",
			"Psychic": "超", "Fighting": "斗", "Darkness": "恶",
			"Metal": "钢", "Colorless": "无",
		}.get(str(value), str(value).left(1)))
	var name := str(attack.get("name", fallback))
	var damage := str(attack.get("damage_text", ""))
	if damage.is_empty() and int(attack.get("damage", 0)) > 0:
		damage = str(attack.get("damage", 0))
	result["label"] = "%s%s%s\n攻击后结束回合" % [
		("[%s] " % "".join(cost_labels)) if not cost_labels.is_empty() else "",
		name,
		(" · %s" % damage) if not damage.is_empty() else "",
	]
	if not attack_cost.is_empty():
		result["icon"] = table.ENERGY_ICONS.texture_for(str(attack_cost[0]))
	return result


func _retreat_compact_suffix(action: GameAction) -> String:
	if action == null:
		return "确认后结算"
	var indices: Array = action.payload.get("energy_indices", [])
	if indices.is_empty():
		if action.payload.has("energy_indices"):
			return "免费"
		var printed_cost := 0
		if table.state_ref and action.actor in [0, 1]:
			var active := table.state_ref.get_player(action.actor).active
			if active:
				printed_cost = maxi(0, int(
					table.catalog.get_card(active.card_id).get("retreat_cost", 0),
				))
		return "卡面撤退费%d，确认后结算" % printed_cost if printed_cost > 0 else "确认后结算"
	var names: Array[String] = []
	if table.state_ref and action.actor in [0, 1]:
		var active := table.state_ref.get_player(action.actor).active
		if active:
			for raw_index in indices:
				var index := int(raw_index)
				if index >= 0 and index < active.energy_card_ids.size():
					var name := table.catalog.card_name(active.energy_card_ids[index])
					names.append(name)
	if names.is_empty():
		return "丢%d能量" % indices.size()
	return "丢%s" % "、".join(names)


func _refresh_turn_allowance_chips(player: PlayerState) -> void:
	if player == null or table.own_allowance_labels.is_empty():
		return
	var rows := {
		"energy": ["附能", player.energy_attached_this_turn],
		"supporter": ["支援", player.supporter_played_this_turn],
		"retreat": ["撤退", player.retreated_this_turn],
		"stadium": ["竞技场", player.stadium_played_this_turn],
	}
	for key_value in rows.keys():
		var key := str(key_value)
		var row: Array = rows[key]
		var used := bool(row[1])
		var allowance_label := table.own_allowance_labels.get(key) as Label
		if allowance_label == null:
			continue
		allowance_label.text = "%s  %s" % [str(row[0]), "已用" if used else "可用"]
		allowance_label.add_theme_stylebox_override(
			"normal",
			_allowance_chip_style(used),
		)
		allowance_label.add_theme_color_override(
			"font_color",
			Color(0.52, 0.60, 0.70, 0.86) if used else DesignTokens.GREEN,
		)


func _allowance_chip_style(used: bool) -> StyleBoxFlat:
	return DesignTokens.panel_style(
		Color(0.025, 0.040, 0.060, 0.90) if used else Color(0.025, 0.105, 0.090, 0.94),
		7,
		Color(0.25, 0.34, 0.45, 0.62) if used else Color(0.36, 0.78, 0.58, 0.78),
		1,
		5,
	)


func _layout_own_status(metrics: Dictionary, field_plan: Dictionary) -> void:
	if table.own_info == null or table.own_allowance_row == null:
		return
	var stadium_rect := Rect2()
	var stadium := table.zones.get("stadium") as ZoneView
	if stadium:
		stadium_rect = _visual_rect_in_control(
			stadium,
			Rect2(Vector2.ZERO, stadium.size).grow(4.0),
			table.board_canvas,
		)
	var status_height := 48.0 if float(metrics["height"]) < 600.0 else 56.0
	var status_plan := BattleTableLayout.own_status_plan(
		metrics,
		field_plan["own_active_rect"],
		Vector2(304.0, status_height),
		stadium_rect,
	)
	var info_rect: Rect2 = status_plan["info_rect"]
	var allowance_rect: Rect2 = status_plan["allowance_rect"]
	table.own_info.position = info_rect.position
	table.own_info.size = info_rect.size
	table.own_allowance_row.position = allowance_rect.position
	table.own_allowance_row.size = allowance_rect.size
	var compact_status := allowance_rect.size.x < 300.0
	var separation := 3 if compact_status else 6
	table.own_allowance_row.add_theme_constant_override("separation", separation)
	table.own_info.add_theme_font_size_override("font_size", 11 if compact_status else 12)
	var compact_unit := maxf(
		1.0,
		(allowance_rect.size.x - float(separation * 3)) / 4.2,
	)
	for key in ["energy", "supporter", "retreat", "stadium"]:
		var label := table.own_allowance_labels.get(key) as Label
		if label == null:
			continue
		label.add_theme_font_size_override("font_size", 10 if compact_status else 12)
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if compact_status:
			label.custom_minimum_size.x = compact_unit * (1.2 if key == "stadium" else 1.0)
		else:
			label.custom_minimum_size.x = 82.0 if key == "stadium" else 68.0


func _routed_action_rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if table.presentation_runtime.actions_suppressed:
		return result
	for value in table.action_rows:
		var row := value.duplicate()
		var action := row.get("action") as GameAction
		# Playing a Stadium is a no-target action on the rules layer, but the UI
		# also accepts the same action when that hand card is dragged onto the
		# Stadium zone. This metadata never enters GameAction serialization.
		if action and action.kind == "PLAY_TRAINER" and _trainer_type_for_action(action) == "Stadium":
			row["drag_target_keys"] = ["stadium"]
		result.append(row)
	return result


func _action_rows_semantic_signature(rows: Array[Dictionary]) -> String:
	var result: Array[String] = []
	for input_row in rows:
		var row := input_row as Dictionary
		var action_value = row.get("action")
		var action := action_value as GameAction
		if action == null and action_value is Dictionary:
			action = GameAction.from_dict(action_value as Dictionary)
		var parts: Array[String] = [
			_action_semantic_signature(action),
			str(row.get("label", "")),
			str(row.get("hint", "")),
			str(row.get("source_key", "")),
			str(row.get("target_key", "")),
			str(row.get("group_key", "")),
			_stable_value_signature(row.get("target_keys", [])),
			_stable_value_signature(row.get("drag_target_keys", [])),
			str(bool(row.get("disabled", false))),
		]
		result.append("|".join(parts))
	return "\n".join(result)


func _action_semantic_signature(action: GameAction) -> String:
	if action == null:
		return ""
	return _stable_value_signature(action.to_dict())


func _stable_value_signature(value: Variant) -> String:
	if value is Dictionary:
		var dictionary := value as Dictionary
		var keys: Array = dictionary.keys()
		keys.sort_custom(func(left: Variant, right: Variant) -> bool:
			return str(left) < str(right)
		)
		var parts: Array[String] = []
		for key in keys:
			parts.append("%s:%s" % [
				str(key),
				_stable_value_signature(dictionary[key]),
			])
		return "{" + ",".join(parts) + "}"
	if value is Array:
		var parts: Array[String] = []
		for item in value:
			parts.append(_stable_value_signature(item))
		return "[" + ",".join(parts) + "]"
	return str(value)


func _current_task_hint() -> String:
	if not table.choice_target_options.is_empty():
		return table.choice_target_prompt if not table.choice_target_prompt.is_empty() else "选择场上的卡牌"
	if table.selected_entity_key.is_empty():
		return ""
	if (
		table._popover_dismissed_source_key == table.selected_entity_key
		and table._selected_action_group_key.is_empty()
	):
		return "再次点击卡牌取消选择"
	var groups := table.interaction_router.action_groups_for_source(table.selected_entity_key)
	if groups.is_empty():
		return _disabled_reason_for_source(table.selected_entity_key)
	if not table._selected_action_group_key.is_empty():
		var selected_group := _group_by_key(groups, table._selected_action_group_key)
		var rows: Array = selected_group.get("rows", [])
		if not rows.is_empty():
			var action := (rows[0] as Dictionary).get("action") as GameAction
			return "选择%s目标" % _target_hint_for_action(action)
	if groups.size() > 1:
		return "选择一个卡牌动作"
	var only_group: Dictionary = groups[0]
	if bool(only_group.get("requires_target", false)):
		var rows: Array = only_group.get("rows", [])
		if not rows.is_empty():
			var action := (rows[0] as Dictionary).get("action") as GameAction
			return "选择%s目标" % _target_hint_for_action(action)
	return "确认要执行的卡牌动作"


func _disabled_reason_for_source(source_key: String) -> String:
	if table.state_ref == null:
		return "正在载入对局状态"
	if not table.state_ref.pending_promotions.is_empty():
		return (
			"请先选择新的战斗宝可梦"
			if int(table.state_ref.pending_promotions[0]) == table.view_player
			else "等待对手选择新的战斗宝可梦"
		)
	if (
		table.state_ref.phase == "SETUP"
		and table.state_ref.setup_actor_idx in [0, 1]
		and table.state_ref.setup_actor_idx != table.view_player
	):
		return "等待对手完成准备"
	if table.ai_thinking:
		return "等待对手行动"
	if table.state_ref.phase not in ["SETUP", "MAIN"]:
		return "当前阶段不能执行卡牌动作"
	if table.state_ref.phase != "SETUP" and table.state_ref.active_player_idx != table.view_player:
		return "现在是对手的回合"
	var player := table.state_ref.get_player(table.view_player)
	if source_key.begins_with("hand:"):
		var hand_index := source_key.trim_prefix("hand:").to_int()
		if hand_index < 0 or hand_index >= player.hand.size():
			return "这张卡已不在手牌中"
		var card := table.catalog.get_card(player.hand[hand_index])
		var supertype := str(card.get("supertype", ""))
		var card_id := str(player.hand[hand_index])
		var trainer_type := (
			"Stadium"
			if table.catalog.is_stadium(card_id)
			else "Tool"
			if table.catalog.is_tool(card_id)
			else "Supporter"
			if table.catalog.is_supporter(card_id)
			else str(card.get("trainer_type", ""))
		)
		var subtypes: Array = card.get("subtypes", [])
		if table.state_ref.phase == "SETUP" and not table.catalog.is_basic_pokemon(card_id):
			return "准备阶段只能放置基础宝可梦"
		if supertype == "Energy" and player.energy_attached_this_turn:
			return "本回合已附能"
		if supertype == "Energy":
			return "当前没有可附能的宝可梦"
		if trainer_type == "Supporter" and player.supporter_played_this_turn:
			return "本回合已使用支援者"
		if trainer_type == "Stadium" and player.stadium_played_this_turn:
			return "本回合已打出竞技场"
		if (
			trainer_type == "Stadium"
			and table.state_ref.stadium_card_id == player.hand[hand_index]
		):
			return "场上已经是同名竞技场"
		if trainer_type in ["Tool", "Pokémon Tool"]:
			return "没有可附着道具的宝可梦，或目标已有道具"
		if "Basic" in subtypes:
			return "战斗区与备战区没有合法空位"
		if "Stage 1" in subtypes or "Stage 2" in subtypes:
			return "场上没有可进化为这张卡的宝可梦"
		return "当前没有合法目标或不满足使用条件"
	if source_key.begins_with("pokemon:"):
		var parts := source_key.split(":")
		if parts.size() >= 3 and int(parts[1]) != table.view_player:
			return "对手的卡牌不能由你操作"
		if parts.size() >= 3 and str(parts[2]) == "active" and player.retreated_this_turn:
			return "本回合已撤退"
		return "当前没有可用招式、特性或撤退动作"
	if source_key == "stadium":
		return "该竞技场没有可主动发动的效果"
	if source_key.begins_with("zone:"):
		var parts := source_key.split(":")
		if parts.size() >= 3 and int(parts[1]) != table.view_player:
			return "对手的区域不能由你操作"
		return "该区域当前没有可主动发动的卡牌效果"
	return "当前没有合法卡牌动作"


func _rows_for_active_selection() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if table.selected_entity_key.is_empty():
		return result
	var groups := table.interaction_router.action_groups_for_source(table.selected_entity_key)
	if groups.is_empty():
		return result
	if not table._selected_action_group_key.is_empty():
		var selected_group := _group_by_key(groups, table._selected_action_group_key)
		for value in selected_group.get("rows", []):
			result.append(value as Dictionary)
		return result
	if groups.size() == 1:
		for value in (groups[0] as Dictionary).get("rows", []):
			result.append(value as Dictionary)
	return result


func _matching_active_selection_rows(target_key: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row in _rows_for_active_selection():
		var action := row.get("action") as GameAction
		if action and target_key in BattleInteractionController.target_keys_for_action(action, row):
			result.append(row)
	return result


func _group_by_key(groups: Array[Dictionary], group_key: String) -> Dictionary:
	for group in groups:
		if str(group.get("key", "")) == group_key:
			return group
	return {}


func _group_for_action(source_key: String, action: GameAction) -> Dictionary:
	for group in table.interaction_router.action_groups_for_source(source_key):
		for candidate_value in group.get("actions", []):
			if candidate_value == action:
				return group
	return {}


func _target_hint_for_action(action: GameAction) -> String:
	if action == null:
		return "选择"
	match action.kind:
		"PLAY_BASIC":
			return "放置"
		"EVOLVE":
			return "进化"
		"ATTACH_ENERGY":
			return "附能"
		"RETREAT":
			return "撤退"
		"PLAY_TRAINER":
			var hand_index := action.hand_index()
			if table.state_ref and hand_index >= 0:
				var hand := table.state_ref.get_player(action.actor).hand
				if hand_index < hand.size():
					if table.catalog.is_tool(str(hand[hand_index])):
						return "道具"
			return "使用"
		_:
			return "选择"


func _refresh_action_popover() -> void:
	if table.action_popover == null:
		return
	if not table._read_only_detail_key.is_empty():
		table.action_popover.dismiss(false)
		table._popover_source_key = ""
		return
	if table.selected_entity_key.is_empty():
		table.action_popover.dismiss(false)
		table._popover_source_key = ""
		return
	if table._popover_dismissed_source_key == table.selected_entity_key:
		table.action_popover.dismiss(false)
		return
	if not table._forced_popover_rows.is_empty():
		_present_popover_rows(table._forced_popover_source_key, table._forced_popover_rows)
		return
	var groups := table.interaction_router.action_groups_for_source(table.selected_entity_key)
	var contextual_disabled_rows := _disabled_context_rows_for_source(table.selected_entity_key)
	if groups.is_empty():
		_present_popover_rows(
			table.selected_entity_key,
			contextual_disabled_rows,
			"无法操作",
			_disabled_reason_for_source(table.selected_entity_key),
		)
		return
	if not table._selected_action_group_key.is_empty():
		table.action_popover.dismiss(false)
		return
	if (
		groups.size() == 1
		and bool(groups[0].get("requires_target", false))
	):
		# Disabled informational rows (for example, an ability already used this
		# turn) do not turn a single targeted action into a multi-action choice.
		# Keep the one-tap contract and enter target selection immediately.
		table.action_popover.dismiss(false)
		return
	var popover_rows := _popover_rows_for_groups(groups)
	popover_rows.append_array(contextual_disabled_rows)
	_present_popover_rows(
		table.selected_entity_key,
		popover_rows,
	)


func _popover_rows_for_groups(groups: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if groups.size() == 1:
		for row_value in groups[0].get("rows", []):
			result.append(_compact_card_action_row(row_value as Dictionary))
		return result
	for group in groups:
		var rows: Array = group.get("rows", [])
		if rows.is_empty():
			continue
		var row := _compact_card_action_row(rows[0] as Dictionary)
		if str(group.get("action_type", "")) == "RETREAT":
			# This button chooses the retreat action family, not a particular
			# benched Pokemon or payment. Show those details only after the target
			# card has been chosen and the concrete rows are presented.
			row["label"] = "撤退"
			row["hint"] = "选择备战宝可梦"
		elif bool(group.get("requires_target", false)):
			row["hint"] = "选择合法目标"
		result.append(row)
	return result


func _disabled_context_rows_for_source(source_key: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if table.state_ref == null or not source_key.begins_with("pokemon:"):
		return result
	var parts := source_key.split(":")
	if parts.size() < 3:
		return result
	var pokemon := table.state_ref.get_player(int(parts[1])).get_pokemon(str(parts[2]))
	if pokemon == null or pokemon.used_abilities.is_empty():
		return result
	var legal_abilities: Dictionary = {}
	for action in table.interaction_router.actions_for_source(source_key):
		if action.kind == "USE_ABILITY":
			legal_abilities[str(action.ability_name())] = true
	for ability_value in table.catalog.get_card(pokemon.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		var ability_name := str(ability.get("name", ""))
		if ability_name in pokemon.used_abilities and not legal_abilities.has(ability_name):
			result.append({
				"label": "特性 · %s（已使用）" % ability_name,
				"hint": "本回合已发动",
				"disabled": true,
			})
	return result


func _present_popover_rows(
	source_key: String,
	rows: Array[Dictionary],
	title := "卡牌操作",
	hint := "",
) -> void:
	if table.action_popover == null:
		return
	var source_control := _source_control_for_key(source_key)
	if source_control == null:
		table.action_popover.dismiss(false)
		return
	var display_rows: Array[Dictionary] = []
	for row in rows:
		display_rows.append(_compact_card_action_row(row))
	var avoidance_rows := rows
	if table._forced_popover_source_key != source_key:
		avoidance_rows = table.interaction_router.rows_for_source(source_key)
	table._popover_source_key = source_key
	table.action_popover.show_for_control(
		display_rows,
		source_control,
		_safe_popover_rect(),
		_avoid_controls_for_rows(avoidance_rows),
		title,
		hint,
	)


func _source_control_for_key(source_key: String) -> Control:
	if source_key.begins_with("hand:"):
		var hand_index := source_key.trim_prefix("hand:").to_int()
		if hand_index >= 0 and hand_index < table.hand_views.size():
			var hand_view := table.hand_views[hand_index]
			return hand_view if hand_view.visible else null
	if source_key.begins_with("pokemon:"):
		var parts := source_key.split(":")
		if parts.size() >= 3:
			return table.get_slot_view(int(parts[1]), str(parts[2]))
	if source_key == "stadium":
		return table.zones.get("stadium") as Control
	if source_key.begins_with("zone:"):
		var parts := source_key.split(":")
		if parts.size() >= 3:
			return table.motion_geometry._zone_view_for_endpoint({
				"player": int(parts[1]),
				"zone": str(parts[2]),
			})
	return null


func _safe_popover_rect() -> Rect2:
	var inset := Vector2(8.0, 8.0)
	var result := Rect2()
	if table.board_panel and table.board_panel.size.x > 16.0 and table.board_panel.size.y > 16.0:
		result = Rect2(
			table.board_panel.global_position + inset,
			table.board_panel.size - inset * 2.0,
		)
	elif table.size.x > 16.0 and table.size.y > 16.0:
		result = Rect2(table.global_position + inset, table.size - inset * 2.0)
	if result.size.x <= 0.0 or result.size.y <= 0.0:
		return Rect2()
	# The table.header is deliberately above every table-local overlay so the menu is
	# always reachable. Exclude the same strip from popover placement; otherwise
	# an upper card could put its action panel behind the visible table.header.
	if table.header and table.header.visible:
		var header_bottom := table.header.get_global_rect().end.y + inset.y
		if header_bottom > result.position.y and header_bottom < result.end.y:
			var result_bottom := result.end.y
			result.position.y = header_bottom
			result.size.y = result_bottom - header_bottom
	return result


func _avoid_controls_for_rows(rows: Array[Dictionary]) -> Array[Control]:
	var result: Array[Control] = []
	var seen: Dictionary = {}
	# Popovers are transient controls, but they should not hide the board objects
	# a player is trying to read. Reserve the fixed HUD edge, occupied table.zones and
	# visible cards before adding action-specific legal targets below.
	var persistent_controls: Array[Control] = []
	if table.header:
		persistent_controls.append(table.header)
	if table.hud:
		var phase_panel := table.hud.get_node_or_null("PhasePanel") as Control
		if phase_panel:
			persistent_controls.append(phase_panel)
	if table.log_panel and table.log_panel.visible and table.log_panel.is_visible_in_tree():
		persistent_controls.append(table.log_panel)
	for zone_value in table.zones.values():
		var zone := zone_value as ZoneView
		if zone and zone.visible and zone.count > 0:
			persistent_controls.append(zone)
	for hand_view in table.hand_views:
		if hand_view.visible and not hand_view.empty:
			persistent_controls.append(hand_view)
	for slot_value in table.slot_views.values():
		var slot_view := slot_value as CardView
		if slot_view and slot_view.visible and not slot_view.empty:
			persistent_controls.append(slot_view)
	for control in persistent_controls:
		if seen.has(control):
			continue
		seen[control] = true
		result.append(control)
	if table.detail_panel and table.detail_panel.visible:
		seen[table.detail_panel] = true
		result.append(table.detail_panel)
	for row in rows:
		var action := row.get("action") as GameAction
		if action == null:
			continue
		if action.kind == "DECLARE_ATTACK" and action.actor in [0, 1]:
			var defending_active := table.get_slot_view(1 - action.actor, "active")
			if defending_active and not seen.has(defending_active):
				seen[defending_active] = true
				result.append(defending_active)
		for target_key in BattleInteractionController.target_keys_for_action(action, row):
			var control := _source_control_for_key(target_key)
			if control and not seen.has(control):
				seen[control] = true
				result.append(control)
	return result


func _reposition_action_popover() -> void:
	if table.action_popover == null or not table.action_popover.visible:
		return
	var source_control := _source_control_for_key(table._popover_source_key)
	if source_control == null:
		table.action_popover.dismiss(false)
		return
	var detail_component := table.detail_panel as BattleDetailPanel
	table.action_popover.set_compact_preferred(
		detail_component != null
		and detail_component.visible
		and detail_component.is_compact_layout()
	)
	var avoidance_rows := table.interaction_router.rows_for_source(table._popover_source_key)
	if table._forced_popover_source_key == table._popover_source_key:
		avoidance_rows = table._forced_popover_rows
	table.action_popover.reposition_for_control(
		source_control,
		_safe_popover_rect(),
		_avoid_controls_for_rows(avoidance_rows),
	)


func _show_forced_action_rows(
	rows: Array[Dictionary],
	source_key: String = table.selected_entity_key,
) -> void:
	table._forced_popover_rows.clear()
	for row in rows:
		table._forced_popover_rows.append(_compact_card_action_row(row))
	table._forced_popover_source_key = source_key
	table._popover_dismissed_source_key = ""
	_present_popover_rows(
		source_key,
		table._forced_popover_rows,
		"选择具体动作",
		"同一目标存在多种合法执行方式",
	)


func _on_popover_action_chosen(action: GameAction) -> void:
	if action == null:
		return
	for row in table._forced_popover_rows:
		if row.get("action") == action:
			table._forced_popover_rows.clear()
			table._forced_popover_source_key = ""
			table._popover_source_key = ""
			table.action_requested.emit(action)
			return
	var group := _group_for_action(table._popover_source_key, action)
	if not group.is_empty() and bool(group.get("requires_target", false)):
		table._selected_action_group_key = str(group.get("key", ""))
		table._popover_source_key = ""
		_refresh_target_hints()
		_refresh_header()
		return
	table._popover_source_key = ""
	table.action_requested.emit(action)


func _on_popover_dismissed() -> void:
	var dismissed_forced_source := table._forced_popover_source_key
	if not table._popover_source_key.is_empty():
		table._popover_dismissed_source_key = table._popover_source_key
		if table._forced_popover_source_key == table._popover_source_key:
			table._forced_popover_rows.clear()
			table._forced_popover_source_key = ""
	table._popover_source_key = ""
	_refresh_header()
	if (
		table._drag_session != null
		and table._drag_session.state == table.CARD_DRAG_SESSION.AWAITING_VARIANT
		and dismissed_forced_source
		== BattleInteractionController.hand_key(table._drag_session.hand_index)
	):
		table.hand_view._return_drag_session("variant_cancelled")


func _reset_action_interaction_state(dismiss_popover := true) -> void:
	table._selected_action_group_key = ""
	table._popover_dismissed_source_key = ""
	table._popover_source_key = ""
	table._forced_popover_rows.clear()
	table._forced_popover_source_key = ""
	if dismiss_popover and table.action_popover and table.action_popover.visible:
		table.action_popover.dismiss(false)


func _show_attachment_choice_group(source_key: String, group: Dictionary) -> void:
	var options: Array = group.get("options", [])
	if options.is_empty():
		return
	if (
		options.size() == 1
		and int(group.get("min_select", 1)) == 1
		and int(group.get("max_select", 1)) == 1
	):
		table.choice_target_selected.emit(str(Dictionary(options[0]).get("option_id", "")))
		return
	var source_control := _source_control_for_key(source_key)
	if source_control == null or table.attachment_choice_popover == null:
		return
	if table.action_popover != null and table.action_popover.visible:
		table.action_popover.dismiss(false)
	table._attachment_popover_source_key = source_key
	table.attachment_choice_popover.show_for_source(
		options,
		group.get("selected_ids", []),
		group.get("disabled_reasons", {}),
		int(group.get("min_select", 1)),
		int(group.get("max_select", 1)),
		bool(group.get("can_cancel", false)),
		source_control,
		_safe_popover_rect(),
		table.catalog,
		str(group.get("source_label", "能量来源")),
	)


func _on_attachment_option_chosen(option_id: String) -> void:
	table._attachment_popover_source_key = ""
	if table.attachment_choice_popover != null:
		table.attachment_choice_popover.dismiss(false)
	table.choice_target_selected.emit(option_id)


func _on_attachment_selection_confirmed() -> void:
	table._attachment_popover_source_key = ""
	if table.attachment_choice_popover != null:
		table.attachment_choice_popover.dismiss(false)
	table.choice_selection_confirmed.emit()


func _on_attachment_selection_cancelled() -> void:
	table._attachment_popover_source_key = ""
	if table.attachment_choice_popover != null:
		table.attachment_choice_popover.dismiss(false)
	table.choice_cancel_requested.emit()


func _on_attachment_popover_dismissed() -> void:
	table._attachment_popover_source_key = ""


func _on_card_activated(
	card_id: String,
	hand_index: int,
	player: int,
	slot_name: String,
) -> void:
	var clicked_key := (
		BattleInteractionController.hand_key(hand_index)
		if hand_index >= 0
		else BattleInteractionController.pokemon_key(player, slot_name)
	)
	if not table.selected_entity_key.is_empty() and clicked_key == table.selected_entity_key:
		_reset_action_interaction_state()
		table.selection_clear_requested.emit(clicked_key)
		return
	if table.choice_target_options.has(clicked_key):
		var choice_value: Variant = table.choice_target_options[clicked_key]
		if (
			choice_value is Dictionary
			and str(Dictionary(choice_value).get("kind", ""))
			== "attachment_group"
		):
			_show_attachment_choice_group(clicked_key, Dictionary(choice_value))
		else:
			table.choice_target_selected.emit(str(choice_value))
		return
	if not table.selected_entity_key.is_empty() and clicked_key != table.selected_entity_key:
		var target_rows := _matching_active_selection_rows(clicked_key)
		if target_rows.size() == 1:
			var target_action := target_rows[0].get("action") as GameAction
			if target_action:
				table.action_requested.emit(target_action)
				return
		elif target_rows.size() > 1:
			_show_forced_action_rows(target_rows)
			return
	if hand_index < 0 and card_id.is_empty():
		return
	if hand_index >= 0:
		table.hand_card_selected.emit(hand_index, card_id)
	else:
		table.pokemon_selected.emit(player, slot_name, card_id)


func _on_prize_index_activated(index: int, own_zone: bool) -> void:
	var player := table.view_player if own_zone else 1 - table.view_player
	var key := "prize:%d:%d" % [player, index]
	if table.choice_target_options.has(key):
		table.choice_target_selected.emit(str(table.choice_target_options[key]))


func _on_detail_requested(card_id: String) -> void:
	table.detail_requested.emit(card_id)
	if not card_id.is_empty():
		table.inspect_card_requested.emit(table._card_inspection_context(card_id))


func _on_card_view_detail_requested(card_id: String, view: CardView) -> void:
	table.detail_requested.emit(card_id)
	if card_id.is_empty() or view == null:
		return
	var context := table._card_inspection_context(card_id)
	context["player"] = view.owner_player
	if view.hand_index >= 0:
		context["location"] = "%s 手牌" % table._player_label(view.owner_player)
		context["hand_index"] = view.hand_index
		context["slot"] = ""
		context["pokemon"] = null
	elif not view.slot.is_empty():
		context["slot"] = view.slot
		context["pokemon"] = view.pokemon
		context["location"] = "%s %s" % [
			table._player_label(view.owner_player),
			table._slot_name(view.slot),
		]
	table.inspect_card_requested.emit(context)


func _on_menu_pressed() -> void:
	var expected_key := table.selected_entity_key
	table.hide_card_detail()
	_reset_action_interaction_state()
	if table.hud and table.hud.is_log_drawer_open():
		table.hud.close_log_drawer()
	table.selection_clear_requested.emit(expected_key)
	table.menu_requested.emit()


func _on_zone_inspected(context: Dictionary) -> void:
	table.inspect_zone_requested.emit(context)


func _on_zone_action_menu_requested(context: Dictionary) -> void:
	var zone_name := str(context.get("zone", ""))
	var zone_player := int(context.get("player", -1))
	var source_key := BattleInteractionController.zone_key(zone_player, zone_name)
	if source_key.is_empty() or not table.interaction_router.has_source(source_key):
		return
	if table.action_popover and table.action_popover.visible and table._popover_source_key == source_key:
		table.action_popover.dismiss()
	else:
		table._popover_dismissed_source_key = ""
		_present_popover_rows(
			source_key,
			table.interaction_router.rows_for_source(source_key),
			"竞技场操作" if zone_name == "stadium" else "%s操作" % str(
				context.get("title", "区域"),
			),
		)


func _on_card_dropped(
	hand_index: int,
	card_id: String,
	target_player: int,
	target_slot: String,
) -> void:
	var matching_rows := table.interaction_router.matching_drag_rows(
		hand_index,
		target_player,
		target_slot,
	)
	if matching_rows.is_empty():
		return
	table.hand_view._park_drag_session(target_player, target_slot)
	if matching_rows.size() > 1:
		if table._drag_session != null:
			table._drag_session.state = table.CARD_DRAG_SESSION.AWAITING_VARIANT
		_show_forced_action_rows(
			matching_rows,
			BattleInteractionController.hand_key(hand_index),
		)
		return
	if table._drag_session != null:
		table._drag_session.state = table.CARD_DRAG_SESSION.AWAITING_VARIANT
	table.card_drop_requested.emit(
		hand_index,
		card_id,
		target_player,
		target_slot,
	)
