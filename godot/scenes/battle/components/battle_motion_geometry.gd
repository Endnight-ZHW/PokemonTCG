class_name BattleMotionGeometry
extends Node

var table: BattleTable


func configure(p_table: BattleTable) -> void:
	table = p_table


func _event_card_ids(event: Dictionary) -> Array:
	var data: Dictionary = event.get("data", {})
	var raw_cards: Array = []
	var raw_value: Variant = data.get("card_ids", data.get("cards", []))
	if raw_value is Array:
		raw_cards = raw_value
	var result: Array = []
	for value in raw_cards:
		var card_id := (
			str(Dictionary(value).get("card_id", ""))
			if value is Dictionary
			else str(value)
		)
		if not card_id.is_empty():
			result.append(card_id)
	var event_card_id := str(event.get("card_id", data.get("card_id", "")))
	if result.is_empty() and not event_card_id.is_empty():
		result.append(event_card_id)
	return result

func _is_transient_opening_draw(event: Dictionary) -> bool:
	if PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	) != "cards_drawn":
		return false
	var data: Dictionary = event.get("data", {})
	return (
		str(data.get("purpose", "")) in ["opening_hand", "mulligan_redraw"]
		and not bool(data.get("final_opening_hand", false))
	)

func _reveal_rows(event: Dictionary) -> Array[Dictionary]:
	var data: Dictionary = event.get("data", {})
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	var raw_value: Variant = data.get(
		"cards",
		(
			data.get("card_ids", data.get("selected_card_ids", []))
			if event_type == "cards_selected"
			else []
		),
	)
	var result: Array[Dictionary] = []
	if not raw_value is Array:
		return result
	for value in Array(raw_value):
		var row := (
			Dictionary(value).duplicate(true)
			if value is Dictionary
			else {"card_id": str(value)}
		)
		if str(row.get("card_id", "")).is_empty():
			continue
		if event_type == "cards_selected":
			var destination: Dictionary = Dictionary(
				event.get("target", {}),
			).duplicate(true)
			row["matched"] = true
			row["destination"] = destination
			row["outcome_label"] = _public_selection_outcome_label(destination)
		result.append(row)
	return result


func _public_selection_outcome_label(destination: Dictionary) -> String:
	if not str(destination.get("slot", "")).is_empty():
		return "放到场上"
	match str(destination.get("zone", "")):
		"hand":
			return "加入手牌"
		"bench":
			return "放入备战区"
		"discard":
			return "放入弃牌区"
		"deck":
			return "放回牌库"
	return "公开选择"

func _reveal_destination(row: Dictionary, fallback_player: int) -> Dictionary:
	var destination_value: Variant = row.get("destination", {})
	var destination := (
		Dictionary(destination_value).duplicate(true)
		if destination_value is Dictionary
		else {}
	)
	if int(destination.get("player", -1)) < 0:
		destination["player"] = fallback_player
	if str(destination.get("zone", "")).is_empty():
		destination["zone"] = "deck"
	return destination

func _event_amount(event: Dictionary, card_ids: Array) -> int:
	var data: Dictionary = event.get("data", {})
	return maxi(1, int(event.get(
		"amount",
		data.get("count", card_ids.size()),
	)))

func _append_unique_control(result: Array[Control], node: Control) -> void:
	if node == null or not is_instance_valid(node):
		return
	if result.has(node):
		return
	result.append(node)

func _slot_view_for_endpoint(endpoint: Dictionary) -> CardView:
	var slot_name := str(endpoint.get("slot", ""))
	if slot_name.is_empty():
		return null
	return table.get_slot_view(int(endpoint.get("player", table.view_player)), slot_name)

func _zone_view_for_endpoint(endpoint: Dictionary) -> ZoneView:
	var zone_name := str(endpoint.get("zone", ""))
	if zone_name.is_empty():
		return null
	if zone_name == "stadium":
		return table.zones.get("stadium") as ZoneView
	var player := int(endpoint.get("player", table.view_player))
	var prefix := "own" if player == table.view_player else "opponent"
	return table.zones.get("%s_%s" % [prefix, zone_name]) as ZoneView

func _logical_zone_key(scene_zone_key: String) -> String:
	match scene_zone_key:
		"own_deck":
			return "%d:deck" % table.view_player
		"own_discard":
			return "%d:discard" % table.view_player
		"own_prizes":
			return "%d:prizes" % table.view_player
		"opponent_deck":
			return "%d:deck" % (1 - table.view_player)
		"opponent_discard":
			return "%d:discard" % (1 - table.view_player)
		"opponent_prizes":
			return "%d:prizes" % (1 - table.view_player)
		"stadium":
			return "-1:stadium"
	return scene_zone_key

func _source_points_for_event(
	source: Dictionary,
	card_ids: Array,
	visible_count: int,
	fallback_start: Vector2,
	event: Dictionary = {},
) -> Array[Vector2]:
	var player := int(source.get("player", table.view_player))
	var zone_name := str(source.get("zone", ""))
	var source_index := int(source.get("index", -1))
	if (
		zone_name == "hand"
		and player == table.view_player
		and int(table.presentation_runtime.snapshot.get("view_player", table.view_player)) == table.view_player
	):
		return _hand_start_points_from_snapshot(
			card_ids,
			visible_count,
			fallback_start,
			source_index,
		)
	if zone_name == "hand" and player != table.view_player:
		return _opponent_hand_points(visible_count, fallback_start)
	if not str(source.get("slot", "")).is_empty():
		var component_result: Array[Vector2] = []
		for index in range(visible_count):
			var card_id := str(card_ids[index]) if index < card_ids.size() else ""
			var component_endpoint := _slot_component_endpoint(
				source,
				card_id,
				index,
			)
			component_result.append(_snapshot_endpoint_center(
				component_endpoint,
				fallback_start,
			))
		return component_result
	if not str(source.get("attachment_type", "")).is_empty():
		var attachment_result: Array[Vector2] = []
		for index in range(visible_count):
			var exact_source := source.duplicate(true)
			if index < card_ids.size():
				exact_source["attachment_card_id"] = str(card_ids[index])
			exact_source["index"] = table._endpoint_attachment_index(source, index)
			attachment_result.append(_snapshot_endpoint_center(
				exact_source,
				fallback_start,
			))
		return attachment_result
	var start := _snapshot_endpoint_center(source, fallback_start)
	var result: Array[Vector2] = []
	var data: Dictionary = event.get("data", {})
	var source_indices: Array = data.get("source_indices", [])
	for index in range(visible_count):
		var exact_source := source.duplicate(true)
		if index < source_indices.size():
			exact_source["index"] = int(source_indices[index])
		result.append(start + _zone_motion_offset(
			exact_source,
			index,
			visible_count,
			true,
		))
	return result

func _target_points_for_event(
	target: Dictionary,
	card_ids: Array,
	visible_count: int,
	fallback_finish: Vector2,
	event: Dictionary,
) -> Array[Vector2]:
	var zone_name := str(target.get("zone", ""))
	var player := int(target.get("player", table.view_player))
	var result: Array[Vector2] = []
	if zone_name == "hand" and player == table.view_player:
		for view_value in table.hand_presentation._hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(table._effects_local(view.global_center()))
		if result.size() >= visible_count:
			return result
	elif zone_name == "hand" and player != table.view_player:
		for view_value in table.hand_presentation._opponent_hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(table._effects_local(view.global_center()))
		if result.size() >= visible_count:
			return result
	if not str(target.get("attachment_type", "")).is_empty():
		for index in range(visible_count):
			var exact_target := target.duplicate(true)
			if index < card_ids.size():
				exact_target["attachment_card_id"] = str(card_ids[index])
			exact_target["index"] = table._endpoint_attachment_index(target, index)
			result.append(table.resolve_endpoint_center(exact_target))
		return result
	for index in range(visible_count):
		var offset := _stack_offset(index, visible_count, zone_name == "hand")
		if not zone_name.is_empty() and zone_name != "hand":
			offset = _zone_motion_offset(target, index, visible_count, false)
		result.append(fallback_finish + offset)
	return result

func _source_sizes_for_event(
	source: Dictionary,
	card_ids: Array,
	visible_count: int,
	fallback_size: Vector2,
) -> Array[Vector2]:
	var player := int(source.get("player", table.view_player))
	var zone_name := str(source.get("zone", ""))
	var source_index := int(source.get("index", -1))
	var result: Array[Vector2] = []
	if (
		zone_name == "hand"
		and player == table.view_player
		and int(table.presentation_runtime.snapshot.get("view_player", table.view_player)) == table.view_player
	):
		for row in _hand_motion_rows_from_snapshot(
			card_ids,
			visible_count,
			Vector2.ZERO,
			fallback_size,
			source_index,
		):
			result.append(_vector_or_default(row.get("size"), fallback_size))
		return result
	var size_value := _snapshot_endpoint_size(
		source,
		_current_endpoint_size(source, fallback_size),
	)
	for index in range(visible_count):
		if not str(source.get("slot", "")).is_empty():
			var card_id := str(card_ids[index]) if index < card_ids.size() else ""
			var component_endpoint := _slot_component_endpoint(source, card_id, index)
			result.append(_snapshot_endpoint_size(component_endpoint, size_value))
		else:
			result.append(size_value)
	return result

func _target_sizes_for_event(
	target: Dictionary,
	visible_count: int,
	fallback_size: Vector2,
	event: Dictionary,
) -> Array[Vector2]:
	var zone_name := str(target.get("zone", ""))
	var player := int(target.get("player", table.view_player))
	var result: Array[Vector2] = []
	if zone_name == "hand" and player == table.view_player:
		for view_value in table.hand_presentation._hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(view.size)
		if result.size() >= visible_count:
			return result
	elif zone_name == "hand" and player != table.view_player:
		for view_value in table.hand_presentation._opponent_hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(view.size)
		if result.size() >= visible_count:
			return result
	var size_value := _current_endpoint_size(target, fallback_size)
	while result.size() < visible_count:
		result.append(size_value)
	return result

func _source_rotations_for_event(
	source: Dictionary,
	card_ids: Array,
	visible_count: int,
	fallback_rotation: float,
) -> Array[float]:
	var player := int(source.get("player", table.view_player))
	var zone_name := str(source.get("zone", ""))
	var source_index := int(source.get("index", -1))
	var result: Array[float] = []
	if (
		zone_name == "hand"
		and player == table.view_player
		and int(table.presentation_runtime.snapshot.get("view_player", table.view_player)) == table.view_player
	):
		for row in _hand_motion_rows_from_snapshot(
			card_ids,
			visible_count,
			Vector2.ZERO,
			Vector2.ZERO,
			source_index,
		):
			result.append(float(row.get("rotation_degrees", fallback_rotation)))
		return result
	var rotation := _snapshot_endpoint_rotation(
		source,
		_current_endpoint_rotation(source, fallback_rotation),
	)
	for _index in range(visible_count):
		result.append(rotation)
	return result

func _slot_component_endpoint(
	source: Dictionary,
	card_id: String,
	component_index: int,
) -> Dictionary:
	var result := source.duplicate(true)
	if card_id.is_empty() or str(source.get("slot", "")).is_empty():
		return result
	var row := _snapshot_slot_row(
		int(source.get("player", table.view_player)),
		str(source.get("slot", "")),
	)
	var pokemon_data: Dictionary = row.get("pokemon", {})
	if pokemon_data.is_empty():
		return result
	if card_id == str(pokemon_data.get("attached_tool_id", "")):
		result["attachment_type"] = "tool"
		result["attachment_card_id"] = card_id
	elif card_id in Array(pokemon_data.get("energy_card_ids", [])):
		result["attachment_type"] = "energy"
		result["attachment_card_id"] = card_id
		var energy_start := 1 + Array(pokemon_data.get("evolution_stack_ids", [])).size()
		if not str(pokemon_data.get("attached_tool_id", "")).is_empty():
			energy_start += 1
		var energy_index := component_index - energy_start
		result["index"] = energy_index if energy_index >= 0 else 0
	return result

func _target_rotations_for_event(
	target: Dictionary,
	visible_count: int,
	fallback_rotation: float,
	event: Dictionary,
) -> Array[float]:
	var zone_name := str(target.get("zone", ""))
	var player := int(target.get("player", table.view_player))
	var result: Array[float] = []
	if zone_name == "hand" and player == table.view_player:
		for view_value in table.hand_presentation._hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(view.rotation_degrees)
		if result.size() >= visible_count:
			return result
	elif zone_name == "hand" and player != table.view_player:
		for view_value in table.hand_presentation._opponent_hand_target_views_for_incoming(event):
			var view := view_value as CardView
			if view:
				result.append(view.rotation_degrees)
		if result.size() >= visible_count:
			return result
	var rotation := _current_endpoint_rotation(target, fallback_rotation)
	while result.size() < visible_count:
		result.append(rotation)
	return result

func _hand_start_points_from_snapshot(
	card_ids: Array,
	visible_count: int,
	fallback_start: Vector2,
	source_index: int = -1,
) -> Array[Vector2]:
	var rows := _hand_motion_rows_from_snapshot(
		card_ids,
		visible_count,
		fallback_start,
		table.hand_card_size,
		source_index,
	)
	var result: Array[Vector2] = []
	for row in rows:
		result.append(_vector_or_default(row.get("center"), fallback_start))
	return result

func _hand_motion_rows_from_snapshot(
	card_ids: Array,
	visible_count: int,
	fallback_start: Vector2,
	fallback_size: Vector2,
	source_index: int = -1,
) -> Array[Dictionary]:
	var snapshot_hand: Array = table.presentation_runtime.snapshot.get("hand", [])
	var result: Array[Dictionary] = []
	if snapshot_hand.is_empty():
		for _index in range(visible_count):
			result.append({
				"center": fallback_start,
				"size": fallback_size,
				"rotation_degrees": 0.0,
			})
		return result
	var used: Array[bool] = []
	for _row in snapshot_hand:
		used.append(false)
	var requested_ids: Array[String] = []
	var has_identity := false
	for value in card_ids:
		var card_id := str(value)
		requested_ids.append(card_id)
		if not card_id.is_empty():
			has_identity = true
	for index in range(visible_count):
		var target_id := requested_ids[index] if index < requested_ids.size() else ""
		var start := fallback_start
		var size_value := fallback_size
		var rotation := 0.0
		var preferred_index := source_index + index if source_index >= 0 else -1
		if preferred_index >= 0 and preferred_index < snapshot_hand.size():
			var preferred: Dictionary = snapshot_hand[preferred_index]
			if (
				not used[preferred_index]
				and (
					target_id.is_empty()
					or str(preferred.get("card_id", "")) == target_id
				)
			):
				used[preferred_index] = true
				start = _vector_or_default(preferred.get("center"), fallback_start)
				size_value = _vector_or_default(preferred.get("size"), fallback_size)
				rotation = float(preferred.get("rotation_degrees", 0.0))
		if start == fallback_start and has_identity and not target_id.is_empty():
			for hand_index in range(snapshot_hand.size()):
				var row: Dictionary = snapshot_hand[hand_index]
				if used[hand_index] or str(row.get("card_id", "")) != target_id:
					continue
				used[hand_index] = true
				start = _vector_or_default(row.get("center"), fallback_start)
				size_value = _vector_or_default(row.get("size"), fallback_size)
				rotation = float(row.get("rotation_degrees", 0.0))
				break
		result.append({
			"center": start,
			"size": size_value,
			"rotation_degrees": rotation,
		})
	return result

func _snapshot_endpoint_center(endpoint: Dictionary, fallback: Vector2) -> Vector2:
	var player := int(endpoint.get("player", table.view_player))
	var slot_name := str(endpoint.get("slot", ""))
	if not slot_name.is_empty():
		var slot_row := _snapshot_slot_row(player, slot_name)
		if not slot_row.is_empty():
			var attachment_type := str(endpoint.get("attachment_type", ""))
			if not attachment_type.is_empty():
				var attachment_centers: Dictionary = slot_row.get(
					"attachment_centers",
					{},
				)
				var attachment_card_id := str(endpoint.get(
					"attachment_card_id",
					endpoint.get("card_id", ""),
				))
				var attachment_key := (
					"%s:%s" % [attachment_type, attachment_card_id]
					if not attachment_card_id.is_empty()
					else attachment_type
				)
				var attachment_index := table._endpoint_attachment_index(endpoint)
				if attachment_index >= 0:
					var indexed_key := (
						"%s:%d:%s" % [attachment_type, attachment_index, attachment_card_id]
						if not attachment_card_id.is_empty()
						else "%s:%d" % [attachment_type, attachment_index]
					)
					if attachment_centers.has(indexed_key):
						return _vector_or_default(attachment_centers.get(indexed_key), fallback)
				if attachment_centers.has(attachment_key):
					return _vector_or_default(
						attachment_centers.get(attachment_key),
						fallback,
					)
				if attachment_centers.has(attachment_type):
					return _vector_or_default(
						attachment_centers.get(attachment_type),
						fallback,
					)
			return _vector_or_default(slot_row.get("center"), fallback)
	var zone_name := str(endpoint.get("zone", ""))
	if not zone_name.is_empty():
		if zone_name == "hand":
			return (
				_snapshot_own_hand_center(fallback)
				if player == table.view_player
				else _vector_or_default(
					table.presentation_runtime.snapshot.get("opponent_hand_center"),
					fallback,
				)
			)
		var zone_row := _snapshot_zone_row(player, zone_name)
		if not zone_row.is_empty():
			return _vector_or_default(zone_row.get("center"), fallback)
	return fallback

func _snapshot_endpoint_size(endpoint: Dictionary, fallback: Vector2) -> Vector2:
	var player := int(endpoint.get("player", table.view_player))
	var slot_name := str(endpoint.get("slot", ""))
	if not slot_name.is_empty():
		var slot_row := _snapshot_slot_row(player, slot_name)
		if not slot_row.is_empty():
			if not str(endpoint.get("attachment_type", "")).is_empty():
				return _attachment_motion_size(
					_vector_or_default(slot_row.get("size"), fallback),
					fallback,
				)
			return _vector_or_default(slot_row.get("size"), fallback)
	var zone_name := str(endpoint.get("zone", ""))
	if not zone_name.is_empty():
		var zone_row := _snapshot_zone_row(player, zone_name)
		if not zone_row.is_empty():
			return _vector_or_default(zone_row.get("size"), fallback)
	return fallback

func _snapshot_endpoint_rotation(endpoint: Dictionary, fallback: float) -> float:
	var player := int(endpoint.get("player", table.view_player))
	var slot_name := str(endpoint.get("slot", ""))
	if not slot_name.is_empty():
		var slot_row := _snapshot_slot_row(player, slot_name)
		if not slot_row.is_empty():
			return float(slot_row.get("rotation_degrees", fallback))
	var zone_name := str(endpoint.get("zone", ""))
	if not zone_name.is_empty():
		var zone_row := _snapshot_zone_row(player, zone_name)
		if not zone_row.is_empty():
			return float(zone_row.get("rotation_degrees", fallback))
	return fallback

func _current_endpoint_size(endpoint: Dictionary, fallback: Vector2) -> Vector2:
	var slot_name := str(endpoint.get("slot", ""))
	if not slot_name.is_empty():
		var view := _slot_view_for_endpoint(endpoint)
		if view:
			if not str(endpoint.get("attachment_type", "")).is_empty():
				return _attachment_motion_size(view.size, fallback)
			return view.size
	var zone_name := str(endpoint.get("zone", ""))
	if not zone_name.is_empty():
		if zone_name == "hand":
			return (
				table.hand_card_size
				if int(endpoint.get("player", table.view_player)) == table.view_player
				else table.opponent_hand_card_size
			)
		var zone := _zone_view_for_endpoint(endpoint)
		if zone:
			return table._zone_card_size(zone)
	return fallback

func _attachment_motion_size(slot_size: Vector2, fallback: Vector2) -> Vector2:
	var reference := slot_size if slot_size != Vector2.ZERO else fallback
	var diameter := clampf(
		minf(reference.x * 0.22, reference.y * 0.18),
		16.0,
		26.0,
	)
	# Attachments occupy badge geometry while they are on a Pokemon. Generic
	# motion interpolates this square to/from the paper-card geometry of hand,
	# discard and deck endpoints, producing a badge <-> card transformation
	# instead of showing an already full-sized card on the Pokemon.
	return Vector2(diameter, diameter)

func _current_endpoint_rotation(endpoint: Dictionary, fallback: float) -> float:
	var slot_name := str(endpoint.get("slot", ""))
	if not slot_name.is_empty():
		var view := _slot_view_for_endpoint(endpoint)
		if view:
			return view.rotation_degrees
	var zone_name := str(endpoint.get("zone", ""))
	if not zone_name.is_empty() and zone_name != "hand":
		var zone := _zone_view_for_endpoint(endpoint)
		if zone:
			return zone.rotation_degrees
	return fallback

func _snapshot_slot_row(player: int, slot_name: String) -> Dictionary:
	var slots: Dictionary = table.presentation_runtime.snapshot.get("slots", {})
	return Dictionary(slots.get("%d:%s" % [player, slot_name], {}))

func _snapshot_zone_row(player: int, zone_name: String) -> Dictionary:
	var zones_snapshot: Dictionary = table.presentation_runtime.snapshot.get("zones", {})
	var key := "-1:stadium" if zone_name == "stadium" else "%d:%s" % [
		player,
		zone_name,
	]
	return Dictionary(zones_snapshot.get(key, {}))

func _vector_or_default(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	return fallback

func _snapshot_own_hand_center(fallback: Vector2) -> Vector2:
	var snapshot_hand: Array = table.presentation_runtime.snapshot.get("hand", [])
	if snapshot_hand.is_empty():
		return fallback
	var total := Vector2.ZERO
	var count_value := 0
	for row_value in snapshot_hand:
		var row: Dictionary = row_value
		total += _vector_or_default(row.get("center"), fallback)
		count_value += 1
	return total / float(maxi(1, count_value))

func _opponent_hand_points(
	visible_count: int,
	fallback_start: Vector2,
) -> Array[Vector2]:
	var result: Array[Vector2] = []
	if not table.hand_presentation._presentation_opponent_hand_proxies.is_empty():
		var first_proxy := maxi(
			0,
			table.hand_presentation._presentation_opponent_hand_proxies.size()
			- mini(visible_count, table.hand_presentation._presentation_opponent_hand_proxies.size()),
		)
		for index in range(first_proxy, table.hand_presentation._presentation_opponent_hand_proxies.size()):
			var proxy := table.hand_presentation._presentation_opponent_hand_proxies[index]
			if proxy != null and is_instance_valid(proxy):
				result.append(proxy.position + proxy.size * 0.5)
		if result.size() >= visible_count:
			return result
	var visible_views: Array[CardView] = []
	for view in table.opponent_hand_views:
		if view and view.visible:
			visible_views.append(view)
	if not visible_views.is_empty():
		var first := maxi(
			0,
			visible_views.size() - mini(visible_count, visible_views.size()),
		)
		for index in range(first, visible_views.size()):
			result.append(table._effects_local(visible_views[index].global_center()))
	while result.size() < visible_count:
		result.append(fallback_start + _stack_offset(
			result.size(),
			visible_count,
			true,
		))
	return result

func _stack_offset(index: int, visible_count: int, hand_target: bool) -> Vector2:
	var lane_count := mini(maxi(1, visible_count), maxi(1, table.card_motion_layer._max_active_flyers()))
	var lane_index := posmod(index, lane_count)
	if hand_target:
		return Vector2(
			(float(lane_index) - float(lane_count - 1) * 0.5) * 34.0,
			18.0,
		)
	return Vector2(
		(float(lane_index) - float(lane_count - 1) * 0.5) * 7.0,
		-float(lane_index) * 3.0,
	)

func _zone_motion_offset(
	endpoint: Dictionary,
	index: int,
	visible_count: int,
	leaving_stack: bool,
) -> Vector2:
	var zone_name := str(endpoint.get("zone", ""))
	var player := int(endpoint.get("player", table.view_player))
	if zone_name.is_empty() or zone_name == "hand":
		return _stack_offset(index, visible_count, zone_name == "hand")
	var zone := _zone_view_for_endpoint(endpoint)
	var direction := "up"
	var depth := 0.55
	if zone:
		direction = zone.stack_visual_direction
		depth = zone.table_depth
	var step := (
		zone.get_stack_motion_step()
		if zone
		else _stack_visual_step(direction, depth)
	)
	if zone:
		var zone_transform := zone.get_global_transform_with_canvas()
		var step_origin := table._effects_local(zone_transform * Vector2.ZERO)
		step = table._effects_local(zone_transform * step) - step_origin
	var lane_count := mini(maxi(1, visible_count), maxi(1, table.card_motion_layer._max_active_flyers()))
	var clamped_index := posmod(index, lane_count)
	if zone_name == "prizes":
		var stack_count := zone.count if zone else visible_count
		if leaving_stack:
			var staged_key := table.presentation_runtime._presentation_zone_key({
				"player": player,
				"zone": "prizes",
			})
			var staged_row: Dictionary = table.presentation_runtime.zone_states.get(
				staged_key,
				{},
			)
			if not staged_row.is_empty():
				stack_count = int(staged_row.get("count", stack_count))
			else:
				var snapshot_row := _snapshot_zone_row(player, "prizes")
				stack_count = int(snapshot_row.get("count", stack_count))
			var explicit_source_index := int(endpoint.get("index", -1))
			if explicit_source_index >= 0:
				return step * float(clampi(
					explicit_source_index,
					0,
					maxi(0, stack_count - 1),
				))
			# With no explicit prize index, remove cards from the visible fan edge.
			# A one-card pile therefore starts exactly at the physical face center.
			var source_slot := maxi(0, stack_count - 1 - clamped_index)
			return step * float(source_slot)
		# Incoming cards occupy the newly added rightmost slots in final-state order.
		var first_target_slot := maxi(0, stack_count - visible_count)
		var target_slot := first_target_slot + clamped_index
		if zone:
			target_slot = mini(target_slot, maxi(0, zone.stack_visual_max_count - 1))
		return step * float(target_slot)
	var stack_bias := step * float(mini(clamped_index + 1, 4))
	if not leaving_stack:
		stack_bias *= 0.36 if zone_name == "discard" else 0.55
	var axis := Vector2(-step.y, step.x)
	if axis.length_squared() <= 0.0001:
		axis = Vector2.RIGHT
	else:
		axis = axis.normalized()
	var spread := 5.0 if leaving_stack else 7.0
	if zone_name == "discard" and not leaving_stack:
		spread = 12.0
	var fan := axis * (
		(float(clamped_index) - float(lane_count - 1) * 0.5) * spread
	)
	return stack_bias + fan

func _stack_visual_step(direction: String, depth: float) -> Vector2:
	var depth_scale := 0.75 + clampf(depth, 0.0, 1.0) * 0.55
	match direction:
		"down_left":
			return Vector2(-1.5, 3.6) * depth_scale
		"up_right":
			return Vector2(1.5, -3.6) * depth_scale
		"down":
			return Vector2(3.6, 3.2) * depth_scale
		"left":
			return Vector2(-3.6, 2.4) * depth_scale
		"right":
			return Vector2(3.6, 2.4) * depth_scale
	return Vector2(3.6, -3.2) * depth_scale

func _motion_card_hidden_from_view(
	card_id: String,
	source: Dictionary,
	target: Dictionary,
) -> bool:
	if card_id.is_empty():
		return true
	# True means the identity must stay hidden for the entire flight. A transition
	# from a hidden pile to a public local zone now starts on the back and flips at
	# mid-flight, so only hidden-to-hidden movement is fully concealed.
	return _endpoint_hidden_from_view(source) and _endpoint_hidden_from_view(target)

func _endpoint_hidden_from_view(endpoint: Dictionary) -> bool:
	var zone_name := str(endpoint.get("zone", ""))
	if zone_name in ["deck", "prizes"]:
		return true
	if zone_name == "hand":
		return int(endpoint.get("player", table.view_player)) != table.view_player
	return false

func _slot_composite_bidirectional_lane_offset(
	prepared_movements: Array[Dictionary],
) -> float:
	if prepared_movements.size() != 2:
		return -1.0
	var first: Dictionary = prepared_movements[0]
	var second: Dictionary = prepared_movements[1]
	var first_mover := first.get("mover") as CardView
	var second_mover := second.get("mover") as CardView
	var first_landing := first.get("finish_view") as CardView
	var second_landing := second.get("finish_view") as CardView
	if (
		first_mover == null
		or second_mover == null
		or first_landing == null
		or second_landing == null
	):
		return -1.0
	var first_start := table._effects_local(first_mover.global_center())
	var first_finish := table._effects_local(first_landing.global_center())
	var second_start := table._effects_local(second_mover.global_center())
	var second_finish := table._effects_local(second_landing.global_center())
	var first_chord := first_finish - first_start
	var second_chord := second_finish - second_start
	var distance := maxf(first_chord.length(), second_chord.length())
	var base_offset := clampf(distance * 0.18, 38.0, 78.0)
	if first_chord.length_squared() <= 0.01:
		return base_offset
	var first_normal := Vector2(-first_chord.y, first_chord.x).normalized()
	var second_normal := (
		Vector2(-second_chord.y, second_chord.x).normalized()
		if second_chord.length_squared() > 0.01
		else -first_normal
	)
	# At 50%, a quadratic Bezier contributes half of its control-point lane.
	# Combining both directions gives the center-separation coefficient below;
	# for an exact swap it is simply the chord normal with opposite sign.
	var lane_separation := (second_normal - first_normal) * 0.5
	var midpoint_delta := (
		(second_start + second_finish - first_start - first_finish) * 0.5
	)
	var first_bounds := _slot_composite_midpoint_bounds_size(
		first_mover,
		first_landing,
	)
	var second_bounds := _slot_composite_midpoint_bounds_size(
		second_mover,
		second_landing,
	)
	var required_span := (first_bounds + second_bounds) * 0.5
	required_span += Vector2.ONE * table.SLOT_COMPOSITE_CLEARANCE
	var required_x := INF
	if absf(lane_separation.x) > 0.001:
		required_x = (
			required_span.x + absf(midpoint_delta.x)
		) / absf(lane_separation.x)
	var required_y := INF
	if absf(lane_separation.y) > 0.001:
		required_y = (
			required_span.y + absf(midpoint_delta.y)
		) / absf(lane_separation.y)
	var clearance_offset := minf(required_x, required_y)
	if not is_finite(clearance_offset):
		return base_offset
	return maxf(base_offset, clearance_offset)

func _slot_composite_midpoint_bounds_size(
	mover: CardView,
	landing_view: CardView,
) -> Vector2:
	var target_scale := _slot_composite_target_scale(mover, landing_view)
	var midpoint_scale := (
		Vector2.ONE.lerp(target_scale, 0.5)
		* (1.0 + table.SLOT_COMPOSITE_LIFT_SCALE)
	)
	var visual_size := mover.size * midpoint_scale.abs()
	var midpoint_rotation := deg_to_rad(
		lerpf(mover.rotation_degrees, landing_view.rotation_degrees, 0.5)
		+ 1.8
	)
	var cosine := absf(cos(midpoint_rotation))
	var sine := absf(sin(midpoint_rotation))
	return Vector2(
		visual_size.x * cosine + visual_size.y * sine,
		visual_size.x * sine + visual_size.y * cosine,
	)

func _slot_composite_control_point(
	start: Vector2,
	finish: Vector2,
	lane_offset: float,
) -> Vector2:
	var chord := finish - start
	if chord.length_squared() <= 0.01:
		return (start + finish) * 0.5 + Vector2.UP * lane_offset
	# Reversing the chord reverses this normal, so the two halves of a swap use
	# opposite lanes without movement-order conditionals.
	var normal := Vector2(-chord.y, chord.x).normalized()
	return (start + finish) * 0.5 + normal * lane_offset

func _slot_composite_target_scale(
	mover: CardView,
	landing_view: CardView,
) -> Vector2:
	if mover == null or landing_view == null:
		return Vector2.ONE
	return Vector2(
		landing_view.size.x / maxf(1.0, mover.size.x),
		landing_view.size.y / maxf(1.0, mover.size.y),
	)

func _bench_slot_from_event(event: Dictionary) -> String:
	var data: Dictionary = event.get("data", {})
	if data.has("bench_idx"):
		return "bench_%d" % int(data.get("bench_idx", 0))
	for value in [
		data.get("slot", ""),
		data.get("target_slot", ""),
		event.get("target", {}).get("slot", ""),
		event.get("source", {}).get("slot", ""),
	]:
		var slot_name := str(value)
		if slot_name.begins_with("bench"):
			return slot_name
	return ""

func _discard_hand_start_points(
	card_ids: Array,
	visible_count: int,
	fallback_start: Vector2,
) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var requested_ids: Array[String] = []
	var has_identity := false
	for value in card_ids:
		var card_id := str(value)
		requested_ids.append(card_id)
		if not card_id.is_empty():
			has_identity = true
	if not has_identity:
		for _index in range(visible_count):
			result.append(fallback_start)
		return result
	var used: Array[bool] = []
	for _view in table.hand_views:
		used.append(false)
	for index in range(visible_count):
		var target_id := (
			requested_ids[index] if index < requested_ids.size() else ""
		)
		var start := fallback_start
		if not target_id.is_empty():
			for hand_index in range(table.hand_views.size()):
				var view := table.hand_views[hand_index] as CardView
				if (
					used[hand_index]
					or view == null
					or not view.visible
					or view.card_id != target_id
				):
					continue
				used[hand_index] = true
				start = table._effects_local(view.global_center())
				break
		result.append(start)
	return result

func _flying_card_timing(
	index: int,
	total_count: int,
	event_duration: float,
	stagger: bool = true,
) -> Dictionary:
	var playable_duration := maxf(0.0, event_duration - table.FLYING_CARD_FINISH_PAD)
	if playable_duration < table.MIN_FLYING_CARD_DURATION:
		return {"spawn": false, "delay": 0.0, "duration": 0.0}
	var count := maxi(1, total_count)
	var clamped_index := clampi(index, 0, count - 1)
	var delay_step := 0.0
	if stagger and count > 1:
		delay_step = table.motion_stagger_delay
	var delay := float(clamped_index) * delay_step
	# Each card receives the full physical flight. Subtracting its launch delay
	# made every card land on the same frame, defeating the stagger visually.
	var flight_duration := playable_duration
	if flight_duration < table.MIN_FLYING_CARD_DURATION:
		return {"spawn": false, "delay": 0.0, "duration": 0.0}
	return {"spawn": true, "delay": delay, "duration": flight_duration}

func _flying_card_size(event_type: String) -> Vector2:
	if event_type in ["pokemon_played", "pokemon_evolved", "stadium_changed"]:
		return table.PAPER_CARD_BASE_SIZE * 1.08
	if event_type == "energy_attached":
		return table.PAPER_CARD_BASE_SIZE * 0.94
	if event_type == "deck_shuffled":
		return table.PAPER_CARD_BASE_SIZE * 0.90
	return table.PAPER_CARD_BASE_SIZE

func _motion_depth_for_point(point: Vector2) -> float:
	if table.effects == null or table.effects.size.y <= 0.0:
		return 0.55
	return clampf(point.y / table.effects.size.y, 0.0, 1.0)

func _reveal_content_rect() -> Rect2:
	if table.effects == null:
		return Rect2()
	var fallback_size := table.effects.size
	if fallback_size.x <= 1.0 or fallback_size.y <= 1.0:
		fallback_size = table.size
	if fallback_size.x <= 1.0 or fallback_size.y <= 1.0:
		fallback_size = Vector2(1280.0, 720.0)
	if table.board_panel == null or table.board_panel.size.x <= 1.0 or table.board_panel.size.y <= 1.0:
		return Rect2(Vector2.ZERO, fallback_size)
	var global_rect := table.board_panel.get_global_rect()
	var first := table._effects_local(global_rect.position)
	var second := table._effects_local(global_rect.end)
	var rect_position := Vector2(
		minf(first.x, second.x),
		minf(first.y, second.y),
	)
	var resolved_size := Vector2(
		absf(second.x - first.x),
		absf(second.y - first.y),
	)
	if resolved_size.x <= 1.0 or resolved_size.y <= 1.0:
		return Rect2(Vector2.ZERO, fallback_size)
	return Rect2(rect_position, resolved_size)

func _shuffle_ease_out_cubic(value: float) -> float:
	return 1.0 - pow(1.0 - clampf(value, 0.0, 1.0), 3.0)

func _shuffle_ease_in_out_cubic(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	if t < 0.5:
		return 4.0 * t * t * t
	return 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5
