class_name BattleTableLayoutContract
extends RefCounted


const SAFE_INSET := 48.0
const EPSILON := 1.5
const MIN_BENCH_CENTER_SPACING := 48.0


static func run() -> Array[String]:
	var failures: Array[String] = []
	var viewport_cases: Array[Vector2] = [
		Vector2(1280.0, 720.0),
		Vector2(1600.0, 900.0),
		Vector2(2000.0, 900.0),
		Vector2(900.0, 540.0),
	]
	for viewport_size in viewport_cases:
		_check_layout_case(failures, viewport_size, 0.0)
		_check_layout_case(failures, viewport_size, SAFE_INSET)

	var metrics := BattleTableLayout.board_metrics(
		1600.0,
		900.0,
		_default_config(),
	)
	_expect_close(
		failures,
		float(metrics["layout_scale"]),
		1.0666667,
		0.0001,
		"desktop layout scale changed",
	)
	var compact := BattleTableLayout.board_metrics(900.0, 540.0, _default_config())
	_expect_close(
		failures,
		float(compact["layout_scale"]),
		0.76,
		0.0001,
		"compact layout no longer uses the minimum scale",
	)
	_expect_close(
		failures,
		BattleTableLayout.perspective_depth(float(metrics["arena_top"]) - 10.0, metrics),
		0.0,
		0.0001,
		"perspective depth must clamp above the arena",
	)
	_expect_close(
		failures,
		BattleTableLayout.perspective_depth(float(metrics["arena_bottom"]) + 10.0, metrics),
		1.0,
		0.0001,
		"perspective depth must clamp below the arena",
	)
	var far_rect: Rect2 = BattleTableLayout.perspective_card_rect(
		Vector2(float(metrics["center_x"]), float(metrics["arena_top"])),
		Vector2(100.0, 140.0),
		metrics,
	)["rect"]
	var near_rect: Rect2 = BattleTableLayout.perspective_card_rect(
		Vector2(float(metrics["center_x"]), float(metrics["arena_bottom"])),
		Vector2(100.0, 140.0),
		metrics,
	)["rect"]
	_expect(
		failures,
		near_rect.size.x > far_rect.size.x and near_rect.size.y > far_rect.size.y,
		"near-side cards must remain larger than far-side cards",
	)

	var own_hand := BattleTableLayout.own_hand_plan(
		5, 650.0, Vector2(96.0, 135.0), 52.0, 6.0
	)
	var own_items: Array[Dictionary] = own_hand["items"]
	_expect(failures, own_items.size() == 5, "own hand planner lost cards")
	if own_items.size() == 5:
		_expect_close(
			failures,
			float(own_items[0]["rotation_degrees"]),
			-float(own_items[4]["rotation_degrees"]),
			0.001,
			"own hand fan rotations are no longer symmetric",
		)
		_expect_close(
			failures,
			float(own_items[2]["rotation_degrees"]),
			0.0,
			0.001,
			"own hand center card must remain unrotated",
		)
		_expect(
			failures,
			int(own_items[0]["z_index"]) < int(own_items[1]["z_index"])
			and int(own_items[1]["z_index"]) < int(own_items[2]["z_index"])
			and int(own_items[2]["z_index"]) < int(own_items[3]["z_index"])
			and int(own_items[3]["z_index"]) < int(own_items[4]["z_index"]),
			"overlapping hand cards no longer have a deterministic parent Z order",
		)
	_check_hand_centering(failures)
	_check_prize_hit_order(failures)
	_check_mulligan_bonus_placement_controls(failures)
	_check_pending_promotion_hints(failures)
	var opponent_hand := BattleTableLayout.opponent_hand_plan(
		5, 360.0, Vector2(70.0, 98.0), 26.0, 6.0
	)
	var opponent_items: Array[Dictionary] = opponent_hand["items"]
	_expect(failures, opponent_items.size() == 5, "opponent hand planner lost cards")
	if opponent_items.size() == 5:
		_expect(
			failures,
			float(opponent_items[0]["rotation_degrees"]) > 0.0
			and float(opponent_items[4]["rotation_degrees"]) < 0.0,
			"opponent hand fan must face the opposite direction",
		)

	var union := BattleTableLayout.union_rects([
		Rect2(10.0, 20.0, 30.0, 40.0),
		Rect2(35.0, 10.0, 20.0, 20.0),
	])
	_expect(
		failures,
		union == Rect2(10.0, 10.0, 45.0, 50.0),
		"field guide rectangle union changed",
	)
	return failures


static func _check_mulligan_bonus_placement_controls(
	failures: Array[String],
) -> void:
	var state := GameState.new()
	state.phase = "SETUP"
	state.setup_stage = GameState.SETUP_BONUS_PLACEMENT
	state.setup_actor_idx = 0
	# Both players already completed their initial placement before the bonus
	# draw. setup_ready therefore cannot identify who owns this continuation.
	state.setup_ready.assign([true, true])
	state.players[0].active = PokemonState.new("bonus-placement-active")

	var header_scene := load(
		"res://scenes/battle/components/battle_header.tscn") as PackedScene
	var header := header_scene.instantiate() as BattleHeader
	header.update_header(state, 0, false)
	_expect(
		failures,
		header.task_hint_label.text == "可继续放置备战宝可梦，或完成准备",
		"mulligan bonus placement incorrectly tells its actor to wait",
	)
	header.update_header(state, 1, false)
	_expect(
		failures,
		header.task_hint_label.text == "等待对手完成准备"
		and "玩家 1" in header.turn_label.text,
		"mulligan bonus placement does not mark the non-actor as waiting",
	)
	header.free()

	var hud_scene := load(
		"res://scenes/battle/components/battle_phase_hud.tscn") as PackedScene
	var hud := hud_scene.instantiate() as BattlePhaseHud
	var setup_done := GameAction.create("SETUP_DONE", {}, 0)
	hud.update_phase(state, 0, false, "challenge", [setup_done])
	_expect(
		failures,
		hud.phase_advance_button.text == "完成准备"
		and not hud.phase_advance_button.disabled
		and hud.phase_advance_button.get_meta("action") == setup_done,
		"mulligan bonus placement actor cannot submit SETUP_DONE",
	)
	hud.update_phase(state, 1, false, "challenge", [setup_done])
	_expect(
		failures,
		hud.phase_advance_button.text == "等待对手"
		and hud.phase_advance_button.disabled,
		"mulligan bonus placement exposes controls to the non-actor",
	)
	hud.free()

	var table := BattleTable.new()
	table.state_ref = state
	table.view_player = 1
	_expect(
		failures,
		table._disabled_reason_for_source("hand:0") == "等待对手完成准备",
		"setup non-actor receives a misleading card disabled reason",
	)
	state.players[0].hand.assign(["sv1-ener-1"])
	table.view_player = 0
	_expect(
		failures,
		table._disabled_reason_for_source("hand:0")
		== "准备阶段只能放置基础宝可梦",
		"setup actor receives a main-phase disabled reason for a non-Pokemon card",
	)
	table.free()


static func _check_pending_promotion_hints(failures: Array[String]) -> void:
	var state := GameState.new()
	state.phase = "MAIN"
	state.setup_stage = GameState.SETUP_COMPLETE
	state.active_player_idx = 0
	state.pending_promotions.assign([1])

	var header_scene := load(
		"res://scenes/battle/components/battle_header.tscn") as PackedScene
	var header := header_scene.instantiate() as BattleHeader
	header.update_header(state, 0, false)
	_expect(
		failures,
		header.task_hint_label.text == "等待对手选择新的战斗宝可梦",
		"pending promotion incorrectly tells the turn owner to act",
	)
	header.update_header(state, 1, false)
	_expect(
		failures,
		header.task_hint_label.text == "选择备战宝可梦晋升到战斗区",
		"pending promotion does not instruct its actual actor",
	)
	header.free()

	var table := BattleTable.new()
	table.state_ref = state
	table.view_player = 0
	_expect(
		failures,
		table._disabled_reason_for_source("hand:0")
		== "等待对手选择新的战斗宝可梦",
		"turn owner receives a misleading card reason during opponent promotion",
	)
	table.view_player = 1
	_expect(
		failures,
		table._disabled_reason_for_source("hand:0")
		== "请先选择新的战斗宝可梦",
		"promotion actor receives a misleading card reason",
	)
	table.free()


static func _check_prize_hit_order(failures: Array[String]) -> void:
	var zone := ZoneView.new()
	zone.count = 6
	zone.stack_visual_mode = "prizes"
	zone.stack_visual_max_count = 6
	zone._stack_card_size = Vector2(100.0, 140.0)
	_expect(
		failures,
		zone._prize_index_at_point(Vector2(50.0, 70.0)) == 0,
		"prize fan selected a covered card underneath the top face",
	)
	_expect(
		failures,
		zone._prize_index_at_point(Vector2(105.0, 70.0)) == 1,
		"first exposed prize strip did not select its visible card",
	)
	_expect(
		failures,
		zone._prize_index_at_point(Vector2(122.0, 70.0)) == 2,
		"second exposed prize strip did not select its visible card",
	)
	zone.free()


static func _check_hand_centering(failures: Array[String]) -> void:
	for viewport_size in [
		Vector2(900.0, 540.0),
		Vector2(1280.0, 720.0),
		Vector2(1600.0, 900.0),
	]:
		var metrics := BattleTableLayout.board_metrics(
			viewport_size.x,
			viewport_size.y,
			_default_config(),
		)
		var available_width := float(metrics["hand_width"])
		var card_size: Vector2 = metrics["own_hand_size"]
		for card_count in [0, 1, 10, 15]:
			var label := "%dx%d hand=%d" % [
				int(viewport_size.x),
				int(viewport_size.y),
				card_count,
			]
			var plan := BattleTableLayout.own_hand_plan(
				card_count,
				available_width,
				card_size,
				52.0,
				6.0,
			)
			var items: Array[Dictionary] = plan["items"]
			var content_width := float(plan["content_width"])
			var surface_width := float(plan["surface_width"])
			var center_scroll := float(plan["center_scroll"])
			_expect(
				failures,
				items.size() == card_count,
				"%s planner changed the visible card count" % label,
			)
			_expect_close(
				failures,
				surface_width,
				maxf(available_width, content_width),
				0.001,
				"%s surface width does not cover viewport and content" % label,
			)
			_expect_close(
				failures,
				center_scroll,
				maxf(0.0, (content_width - available_width) * 0.5),
				0.001,
				"%s center scroll is not half the overflow" % label,
			)
			if card_count == 0:
				_expect_close(
					failures,
					content_width,
					0.0,
					0.001,
					"%s empty hand retained phantom card width" % label,
				)
				continue
			var first_item: Dictionary = items[0]
			var last_item: Dictionary = items[items.size() - 1]
			var visible_center := (
				float(first_item["position"].x)
				+ float(last_item["position"].x)
				+ card_size.x
			) * 0.5 - center_scroll
			_expect_close(
				failures,
				visible_center,
				available_width * 0.5,
				0.01,
				"%s hand content is not centered in the viewport" % label,
			)


static func _check_layout_case(
	failures: Array[String],
	viewport_size: Vector2,
	safe_inset: float,
) -> void:
	var content_size := viewport_size - Vector2.ONE * safe_inset * 2.0
	var label := "%dx%d+safe%d (content=%dx%d)" % [
		int(viewport_size.x),
		int(viewport_size.y),
		int(safe_inset),
		int(content_size.x),
		int(content_size.y),
	]
	_expect(
		failures,
		content_size.x > 0.0 and content_size.y > 0.0,
		"%s has no positive safe content area" % label,
	)
	if content_size.x <= 0.0 or content_size.y <= 0.0:
		return

	var metrics := BattleTableLayout.board_metrics(
		content_size.x,
		content_size.y,
		_default_config(),
	)
	var field := BattleTableLayout.field_plan(metrics, 16.0)
	var zones := BattleTableLayout.zone_plan(metrics, field)
	var zone_size: Vector2 = zones["size"]
	var zone_positions: Dictionary = zones["positions"]
	var content_rect := Rect2(Vector2.ZERO, content_size)

	_expect_close(
		failures,
		float(metrics["width"]),
		content_size.x,
		0.001,
		"%s planner width ignored the safe content size" % label,
	)
	_expect_close(
		failures,
		float(metrics["height"]),
		content_size.y,
		0.001,
		"%s planner height ignored the safe content size" % label,
	)
	_expect(
		failures,
		float(metrics["field_left"]) < float(metrics["center_x"])
		and float(metrics["center_x"]) < float(metrics["field_right"]),
		"%s field center escaped the field bounds" % label,
	)
	_expect(
		failures,
		float(metrics["arena_top"]) < float(metrics["arena_bottom"]),
		"%s arena has no positive height" % label,
	)
	_expect(
		failures,
		float(field["battle_scale"]) > 0.0
		and float(field["battle_scale"]) <= 1.0,
		"%s battle scale escaped its valid range" % label,
	)

	var command_dock_left := float(metrics["command_dock_left"])
	var required_command_reserve := BattlePhaseHud.RESERVED_BOARD_WIDTH
	_expect(
		failures,
		command_dock_left
		<= content_size.x - required_command_reserve + EPSILON,
		"%s did not reserve %.0fpx for the command rail and right margin"
		% [label, required_command_reserve],
	)

	_check_field_slots(failures, label, metrics, field, content_rect)
	_check_status_region(
		failures,
		label,
		metrics,
		field,
		zone_positions,
		zone_size,
		float(zones.get("stadium_scale", 1.0)),
		content_rect,
	)
	_check_zone_plan(
		failures,
		label,
		metrics,
		zone_positions,
		zone_size,
		content_rect,
	)

	var visible_hand_height := content_size.y - float(metrics["own_hand_y"])
	_expect(
		failures,
		visible_hand_height >= float(metrics["own_hand_height"]) * 0.65
		and visible_hand_height < float(metrics["own_hand_height"]),
		"%s hand peek escaped its intended lower-edge range" % label,
	)


static func _check_field_slots(
	failures: Array[String],
	label: String,
	metrics: Dictionary,
	field: Dictionary,
	content_rect: Rect2,
) -> void:
	var opponent_centers: Array[Vector2] = field["opponent_bench_centers"]
	var own_centers: Array[Vector2] = field["own_bench_centers"]
	var opponent_rects: Array[Rect2] = field["opponent_bench_rects"]
	var own_rects: Array[Rect2] = field["own_bench_rects"]
	_expect(
		failures,
		opponent_centers.size() == 5
		and own_centers.size() == 5
		and opponent_rects.size() == 5
		and own_rects.size() == 5,
		"%s must expose five bench slots per player" % label,
	)
	if (
		opponent_centers.size() != 5
		or own_centers.size() != 5
		or opponent_rects.size() != 5
		or own_rects.size() != 5
	):
		return

	_expect_close(
		failures,
		opponent_centers[2].x,
		float(metrics["center_x"]),
		0.01,
		"%s opponent bench is no longer centered" % label,
	)
	_expect_close(
		failures,
		own_centers[2].x,
		float(metrics["center_x"]),
		0.01,
		"%s own bench is no longer centered" % label,
	)
	_expect(
		failures,
		Vector2(field["opponent_active_center"]).y
		< Vector2(field["own_active_center"]).y,
		"%s active slots lost opponent/own perspective ordering" % label,
	)

	var bench_size: Vector2 = field["bench_size"]
	var spacing_is_possible := (
		float(metrics["table_width"])
		>= bench_size.x + MIN_BENCH_CENTER_SPACING * 4.0 - EPSILON
	)
	for index in range(5):
		_expect(
			failures,
			_rect_inside(opponent_rects[index], content_rect)
			and _rect_inside(own_rects[index], content_rect),
			"%s bench slot %d escaped the content bounds" % [label, index],
		)
		if index == 0:
			continue
		var opponent_spacing := (
			opponent_rects[index].get_center().x
			- opponent_rects[index - 1].get_center().x
		)
		var own_spacing := (
			own_rects[index].get_center().x
			- own_rects[index - 1].get_center().x
		)
		_expect(
			failures,
			opponent_spacing > 0.0 and own_spacing > 0.0,
			"%s bench slots are not ordered left to right" % label,
		)
		if spacing_is_possible:
			_expect(
				failures,
				opponent_spacing >= MIN_BENCH_CENTER_SPACING - EPSILON
				and own_spacing >= MIN_BENCH_CENTER_SPACING - EPSILON,
				"%s bench centers fell below %.0fpx although the table has room"
				% [label, MIN_BENCH_CENTER_SPACING],
			)

	for active_key in ["opponent_active_rect", "own_active_rect"]:
		var active_rect: Rect2 = field[active_key]
		_expect(
			failures,
			_rect_inside(active_rect, content_rect),
			"%s %s escaped the content bounds" % [label, active_key],
		)


static func _check_status_region(
	failures: Array[String],
	label: String,
	metrics: Dictionary,
	field: Dictionary,
	zone_positions: Dictionary,
	zone_size: Vector2,
	stadium_scale: float,
	content_rect: Rect2,
) -> void:
	var own_active_rect: Rect2 = field["own_active_rect"]
	var stadium_base_size := zone_size * stadium_scale
	var stadium_base_position := (
		Vector2(zone_positions["stadium"])
		+ (zone_size - stadium_base_size) * 0.5
	)
	var stadium_rect := _perspective_zone_rect(
		stadium_base_position,
		stadium_base_size,
		metrics,
	).grow(4.0)
	var status_size := Vector2(
		304.0,
		48.0 if float(metrics["height"]) < 600.0 else 56.0,
	)
	var status_plan := BattleTableLayout.own_status_plan(
		metrics,
		own_active_rect,
		status_size,
		stadium_rect,
	)
	var status_rect: Rect2 = status_plan["rect"]
	_expect(
		failures,
		bool(status_plan["clears_left_column"]),
		"%s status region entered the prize/Stadium column" % label,
	)
	_expect(
		failures,
		_rect_inside(status_rect, content_rect),
		"%s status region escaped the content bounds" % label,
	)
	_expect(
		failures,
		status_rect.end.x <= own_active_rect.position.x + EPSILON
		and not status_rect.intersects(own_active_rect),
		"%s status region overlaps the own active slot" % label,
	)
	_expect(
		failures,
		status_rect.position.y >= float(metrics["arena_top"]) - EPSILON
		and status_rect.end.y <= float(metrics["own_hand_y"]) - EPSILON,
		"%s status region escaped the arena/hand corridor" % label,
	)
	_expect(
		failures,
		not status_rect.intersects(stadium_rect),
		"%s status region overlaps Stadium" % label,
	)


static func _check_zone_plan(
	failures: Array[String],
	label: String,
	metrics: Dictionary,
	zone_positions: Dictionary,
	zone_size: Vector2,
	content_rect: Rect2,
) -> void:
	_expect(
		failures,
		zone_positions.keys().size() == 7,
		"%s zone planner must return all seven table zones" % label,
	)
	if zone_positions.keys().size() != 7:
		return

	for zone_key in zone_positions.keys():
		var face_rect := Rect2(Vector2(zone_positions[zone_key]), zone_size)
		_expect(
			failures,
			_rect_inside(face_rect, content_rect),
			"%s %s face escaped the content bounds" % [label, zone_key],
		)

	for prefix in ["opponent", "own"]:
		var deck_position := Vector2(zone_positions["%s_deck" % prefix])
		var discard_position := Vector2(zone_positions["%s_discard" % prefix])
		_expect(
			failures,
			deck_position.x + zone_size.x <= discard_position.x + EPSILON,
			"%s %s deck must stay left of the discard pile" % [label, prefix],
		)
		_expect_close(
			failures,
			deck_position.y,
			discard_position.y,
			0.001,
			"%s %s deck/discard row lost alignment" % [label, prefix],
		)
		_expect(
			failures,
			discard_position.x + zone_size.x
			<= float(metrics["command_dock_left"]) + EPSILON,
			"%s %s discard pile entered the command dock reserve" % [label, prefix],
		)

	_expect_close(
		failures,
		Vector2(zone_positions["opponent_deck"]).x,
		Vector2(zone_positions["own_deck"]).x,
		0.001,
		"%s deck rows no longer share a column" % label,
	)
	_expect(
		failures,
		Vector2(zone_positions["opponent_deck"]).y
		< Vector2(zone_positions["own_deck"]).y,
		"%s deck rows lost opponent/own ordering" % label,
	)


static func _perspective_zone_rect(
	position: Vector2,
	base_size: Vector2,
	metrics: Dictionary,
) -> Rect2:
	var center_y := position.y + base_size.y * 0.5
	var depth := BattleTableLayout.perspective_depth(center_y, metrics)
	var rendered_size := base_size * lerpf(0.88, 1.05, depth)
	var adjusted_position := position
	if depth >= 0.52:
		adjusted_position.y -= (rendered_size.y - base_size.y) * 0.5
	return Rect2(adjusted_position, rendered_size)


static func _rect_inside(inner: Rect2, outer: Rect2) -> bool:
	return (
		inner.position.x >= outer.position.x - EPSILON
		and inner.position.y >= outer.position.y - EPSILON
		and inner.end.x <= outer.end.x + EPSILON
		and inner.end.y <= outer.end.y + EPSILON
	)


static func _default_config() -> Dictionary:
	return {
		"active_card_size": Vector2(130.0, 182.0),
		"bench_card_size": Vector2(86.0, 120.0),
		"zone_size": Vector2(96.0, 136.0),
		"hand_card_size": Vector2(112.0, 157.0),
		"opponent_hand_card_size": Vector2(76.0, 106.0),
		"table_side_margin": 22.0,
		"table_top_margin": 16.0,
		"table_bottom_margin": 10.0,
		"hand_bottom_padding": 8.0,
	}


static func _expect(failures: Array[String], condition: bool, message: String) -> void:
	if not condition:
		failures.append("BattleTable layout contract: %s" % message)


static func _expect_close(
	failures: Array[String],
	actual: float,
	expected: float,
	tolerance: float,
	message: String,
) -> void:
	_expect(
		failures,
		absf(actual - expected) <= tolerance,
		"%s (actual=%s expected=%s)" % [message, actual, expected],
	)
