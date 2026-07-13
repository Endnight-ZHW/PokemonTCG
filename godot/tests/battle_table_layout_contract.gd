class_name BattleTableLayoutContract
extends RefCounted


static func run() -> Array[String]:
	var failures: Array[String] = []
	var metrics := BattleTableLayout.board_metrics(1600.0, 900.0, _default_config())
	_expect_close(
		failures,
		float(metrics["layout_scale"]),
		1.0666667,
		0.0001,
		"desktop layout scale changed",
	)
	_expect(
		failures,
		float(metrics["field_left"]) < float(metrics["center_x"])
		and float(metrics["center_x"]) < float(metrics["field_right"]),
		"desktop field center escaped the field bounds",
	)
	_expect(
		failures,
		float(metrics["arena_top"]) < float(metrics["arena_bottom"]),
		"desktop arena has no positive height",
	)

	var compact := BattleTableLayout.board_metrics(900.0, 540.0, _default_config())
	_expect_close(
		failures,
		float(compact["layout_scale"]),
		0.76,
		0.0001,
		"compact layout no longer uses the minimum scale",
	)
	_expect(
		failures,
		float(compact["field_left"]) < float(compact["field_right"]),
		"compact field bounds inverted",
	)

	var field := BattleTableLayout.field_plan(metrics, 16.0)
	var opponent_centers: Array[Vector2] = field["opponent_bench_centers"]
	var own_centers: Array[Vector2] = field["own_bench_centers"]
	_expect(
		failures,
		opponent_centers.size() == 5 and own_centers.size() == 5,
		"field planner must produce five bench slots per player",
	)
	if opponent_centers.size() == 5 and own_centers.size() == 5:
		_expect(
			failures,
			opponent_centers[0].x < opponent_centers[4].x
			and own_centers[0].x < own_centers[4].x,
			"bench slots are not ordered from left to right",
		)
		_expect_close(
			failures,
			opponent_centers[2].x,
			float(metrics["center_x"]),
			0.01,
			"opponent bench is no longer centered",
		)
		_expect_close(
			failures,
			own_centers[2].x,
			float(metrics["center_x"]),
			0.01,
			"own bench is no longer centered",
		)
	_expect(
		failures,
		Vector2(field["opponent_active_center"]).y
		< Vector2(field["own_active_center"]).y,
		"active slots lost opponent/own perspective ordering",
	)
	_expect(
		failures,
		float(field["battle_scale"]) > 0.0 and float(field["battle_scale"]) <= 1.0,
		"battle scale escaped its valid range",
	)
	for board_size in [
		Vector2(1024.0, 630.0),
		Vector2(1320.0, 790.0),
		Vector2(1690.0, 790.0),
	]:
		var responsive_metrics := BattleTableLayout.board_metrics(
			board_size.x, board_size.y, _default_config()
		)
		var responsive_field := BattleTableLayout.field_plan(responsive_metrics, 16.0)
		var status_plan := BattleTableLayout.own_status_plan(
			responsive_metrics,
			responsive_field["own_active_rect"],
		)
		var status_rect: Rect2 = status_plan["rect"]
		var active_rect: Rect2 = responsive_field["own_active_rect"]
		_expect(
			failures,
			bool(status_plan["clears_left_column"])
			and status_rect.end.x <= active_rect.position.x
			and not status_rect.intersects(active_rect)
			and status_rect.end.y < float(responsive_metrics["own_hand_y"]),
			"own status group overlaps a field/hand region at %s" % board_size,
		)
		var visible_hand_height: float = (
			board_size.y - float(responsive_metrics["own_hand_y"])
		)
		_expect(
			failures,
			visible_hand_height
			>= float(responsive_metrics["own_hand_height"]) * 0.65
			and visible_hand_height < float(responsive_metrics["own_hand_height"]),
			"hand peek no longer preserves the original lower-edge position at %s"
			% board_size,
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

	var zones := BattleTableLayout.zone_plan(metrics)
	var zone_positions: Dictionary = zones["positions"]
	_expect(
		failures,
		zone_positions.keys().size() == 7,
		"zone planner must return all seven table zones",
	)
	_expect_close(
		failures,
		Vector2(zone_positions["opponent_deck"]).x,
		Vector2(zone_positions["own_deck"]).x,
		0.001,
		"deck zones no longer share the side column",
	)
	_expect(
		failures,
		Vector2(zone_positions["opponent_deck"]).y
		< Vector2(zone_positions["own_deck"]).y,
		"deck zones lost opponent/own ordering",
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
