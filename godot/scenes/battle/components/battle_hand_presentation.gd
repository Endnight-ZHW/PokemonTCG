class_name BattleHandPresentation
extends Node

var table: BattleTable
var _presentation_hand_source_proxies: Array[Control] = []
var _presentation_opponent_hand_proxies: Array[Control] = []
var _presentation_opponent_hand_nodes: Array[Control] = []
var _presentation_opponent_hand_event_ids: Array[String] = []
var _presentation_opponent_hand_stage_count := 0
var _presentation_opponent_hand_event_deltas: Dictionary = {}
var _presentation_opponent_hand_planned_deltas: Dictionary = {}
var _presentation_opponent_hand_target_cursor := 0
var _presentation_hand_virtual_keys: Array[String] = []
var _presentation_hand_geometry_staged := false
var _presentation_hand_old_count := 0
var _presentation_hand_final_count := 0
var _presentation_hand_stage_count := 0
var _presentation_hand_stage_generation := 0
var _hand_layout_motion_handles: Dictionary = {}
var _hand_transition_sequences: Dictionary = {}


func configure(p_table: BattleTable) -> void:
	table = p_table


func pending_hand_transition_count() -> int:
	return _hand_transition_sequences.size() if table else 0


func _stage_snapshot_hand_sources(
	events: Array[Dictionary],
	previous_snapshot: Dictionary,
) -> void:
	_clear_snapshot_hand_sources()
	if (
		table.effects == null
		or int(previous_snapshot.get("view_player", -1)) != table.view_player
	):
		return
	var snapshot_hand: Array = previous_snapshot.get("hand", [])
	if snapshot_hand.is_empty():
		return
	var virtual_rows: Array[Dictionary] = []
	for snapshot_index in range(snapshot_hand.size()):
		if not snapshot_hand[snapshot_index] is Dictionary:
			continue
		var row: Dictionary = Dictionary(snapshot_hand[snapshot_index]).duplicate(true)
		var key := "snapshot:%d" % snapshot_index
		row["snapshot_key"] = key
		row["snapshot_index"] = snapshot_index
		virtual_rows.append(row)
		table.presentation_runtime.hand_snapshot_rows[key] = row
		_presentation_hand_virtual_keys.append(key)

	var staged_keys: Dictionary = {}
	for event in events:
		var source := table.presentation_runtime._event_source_endpoint(event)
		var target := table.presentation_runtime._event_target_endpoint(event)
		if (
			int(source.get("player", table.view_player)) != table.view_player
			or str(source.get("zone", "")) != "hand"
			or str(target.get("zone", "")) == "hand"
		):
			continue
		var event_id := str(event.get("event_id", ""))
		if event_id.is_empty():
			continue
		var selected_rows := _select_virtual_hand_source_rows(event, virtual_rows)
		if selected_rows.is_empty():
			continue
		var event_keys: Array[String] = []
		for row in selected_rows:
			var key := str(row.get("snapshot_key", ""))
			if key.is_empty():
				continue
			event_keys.append(key)
			staged_keys[key] = true
		table.presentation_runtime.event_hand_sources[event_id] = event_keys
		for row in selected_rows:
			var key := str(row.get("snapshot_key", ""))
			for virtual_index in range(virtual_rows.size() - 1, -1, -1):
				if str(virtual_rows[virtual_index].get("snapshot_key", "")) == key:
					virtual_rows.remove_at(virtual_index)
					break

	var drag_snapshot_key := ""
	if table._presentation_drag_proxy != null and table._drag_session != null:
		var drag_index := int(table._drag_session.hand_index)
		var candidate_key := "snapshot:%d" % drag_index
		var candidate_row: Dictionary = table.presentation_runtime.hand_snapshot_rows.get(
			candidate_key,
			{},
		)
		if (
			staged_keys.has(candidate_key)
			and str(candidate_row.get("card_id", "")) == table._drag_session.card_id
		):
			drag_snapshot_key = candidate_key

	for key_value in staged_keys.keys():
		var key := str(key_value)
		if key == drag_snapshot_key:
			# The user's drag entity already owns this visual card and may be parked
			# at its target. Creating a snapshot copy here would briefly put a second
			# complete face back into the hand.
			continue
		var row: Dictionary = table.presentation_runtime.hand_snapshot_rows.get(key, {})
		var card_id := str(row.get("card_id", ""))
		var texture := table.card_motion_layer._texture_for_card_id(card_id)
		if texture == null:
			continue
		var size_value := table.motion_geometry._vector_or_default(row.get("size"), table.hand_view._current_hand_card_size())
		var center := table.motion_geometry._vector_or_default(row.get("center"), table._own_hand_center())
		var proxy := table.motion_entities._create_paper_card_token(
			texture,
			size_value,
			"SnapshotHandProxy",
			84 + int(row.get("snapshot_index", 0)),
			table.motion_geometry._motion_depth_for_point(center),
		)
		proxy.position = center - size_value * 0.5
		proxy.rotation_degrees = float(row.get("rotation_degrees", 0.0))
		var motion_proxy := proxy as CardMotionEntity
		if motion_proxy != null:
			motion_proxy.configure_motion(
				str(row.get("visual_id", key)),
				{
					"position": proxy.position,
					"size": size_value,
					"rotation_degrees": proxy.rotation_degrees,
				},
			)
		proxy.set_meta("snapshot_hand_key", key)
		proxy.set_meta("snapshot_card_id", card_id)
		table.effects.add_child(proxy)
		_presentation_hand_source_proxies.append(proxy)
		table.presentation_runtime.hand_proxy_by_key[key] = proxy

func _stage_opponent_hand_transaction(
	events: Array[Dictionary],
	previous_snapshot: Dictionary,
) -> void:
	_clear_opponent_hand_transaction(false)
	if table.effects == null:
		return
	var opponent := 1 - table.view_player
	var incoming_count := 0
	for event in events:
		if _opponent_hand_event_amount(event) <= 0:
			continue
		var source := table.presentation_runtime._event_source_endpoint(event)
		var target := table.presentation_runtime._event_target_endpoint(event)
		var touches_opponent_hand := (
			(str(source.get("zone", "")) == "hand"
				and int(source.get("player", -1)) == opponent)
			or (str(target.get("zone", "")) == "hand"
				and int(target.get("player", -1)) == opponent)
		)
		if not touches_opponent_hand:
			continue
		var event_id := str(event.get("event_id", ""))
		if not event_id.is_empty() and event_id not in _presentation_opponent_hand_event_ids:
			_presentation_opponent_hand_event_ids.append(event_id)
		var event_delta := _opponent_hand_event_delta(event)
		if not event_id.is_empty():
			_presentation_opponent_hand_planned_deltas[event_id] = event_delta
		if event_delta > 0:
			incoming_count += event_delta
	if _presentation_opponent_hand_event_ids.is_empty():
		return
	var final_visible_count := 0
	for view in table.opponent_hand_views:
		if view == null or not view.visible:
			continue
		final_visible_count += 1
		table.presentation_runtime._mask_presentation_node(view)
		_presentation_opponent_hand_nodes.append(view)
	_presentation_opponent_hand_target_cursor = maxi(
		0,
		final_visible_count - mini(incoming_count, final_visible_count),
	)
	var snapshot_rows: Array = previous_snapshot.get("opponent_hand", [])
	var back_texture := table.card_motion_layer._texture_for_card_id("")
	if back_texture == null:
		_clear_opponent_hand_transaction(true)
		return
	for index in range(snapshot_rows.size()):
		var row: Dictionary = snapshot_rows[index]
		var size_value := table.motion_geometry._vector_or_default(row.get("size"), table.opponent_hand_card_size)
		var center := table.motion_geometry._vector_or_default(row.get("center"), table._opponent_hand_center())
		var proxy := table.motion_entities._create_paper_card_token(
			back_texture,
			size_value,
			"SnapshotOpponentHandProxy",
			86 + index,
			table.motion_geometry._motion_depth_for_point(center),
		)
		# This entity is a stationary replacement for the pre-transition hand,
		# not an in-flight card. It becomes a motion entity only if a later event
		# claims it as an outgoing source.
		proxy.remove_meta("card_motion_entity")
		proxy.position = center - size_value * 0.5
		proxy.rotation_degrees = float(row.get("rotation_degrees", 0.0))
		proxy.set_meta("snapshot_opponent_hand_index", index)
		table.effects.add_child(proxy)
		_presentation_opponent_hand_proxies.append(proxy)
	var state_value: Variant = previous_snapshot.get("state", {})
	if state_value is Dictionary and not Dictionary(state_value).is_empty():
		var previous_state := GameState.from_dict(Dictionary(state_value))
		var count_value := previous_state.get_player(opponent).hand.size()
		_presentation_opponent_hand_stage_count = count_value
		table.opponent_hand_count_badge.visible = count_value > 0
		table.opponent_hand_count_badge.text = str(count_value)
	else:
		_presentation_opponent_hand_stage_count = snapshot_rows.size()
	_reconcile_opponent_hand_proxy_count()

func _opponent_hand_event_amount(event: Dictionary) -> int:
	var card_ids := table.motion_geometry._event_card_ids(event)
	var data: Dictionary = event.get("data", {})
	return maxi(0, int(event.get(
		"amount",
		data.get("count", card_ids.size()),
	)))

func _opponent_hand_event_delta(event: Dictionary) -> int:
	var opponent := 1 - table.view_player
	var source := table.presentation_runtime._event_source_endpoint(event)
	var target := table.presentation_runtime._event_target_endpoint(event)
	var source_is_hand := (
		str(source.get("zone", "")) == "hand"
		and int(source.get("player", -1)) == opponent
	)
	var target_is_hand := (
		str(target.get("zone", "")) == "hand"
		and int(target.get("player", -1)) == opponent
	)
	if source_is_hand == target_is_hand:
		return 0
	var amount := _opponent_hand_event_amount(event)
	return amount if target_is_hand else -amount

func _apply_opponent_hand_stage_delta(
	event_id: String,
	delta: int,
	reflow: bool = true,
) -> void:
	if delta == 0:
		return
	_presentation_opponent_hand_stage_count = maxi(
		0,
		_presentation_opponent_hand_stage_count + delta,
	)
	_presentation_opponent_hand_event_deltas[event_id] = (
		int(_presentation_opponent_hand_event_deltas.get(event_id, 0)) + delta
	)
	_sync_opponent_hand_stage_visuals(reflow)

func _claim_opponent_hand_sources(event: Dictionary) -> Array[Control]:
	var result: Array[Control] = []
	var event_id := str(event.get("event_id", ""))
	var amount_value := _opponent_hand_event_amount(event)
	if amount_value <= 0:
		return result
	var amount := mini(
		amount_value,
		_presentation_opponent_hand_proxies.size(),
	)
	var requested_indices: Array[int] = []
	var data: Dictionary = event.get("data", {})
	var raw_indices: Variant = data.get("source_indices", [])
	if raw_indices is Array:
		for value in raw_indices:
			var source_index := int(value)
			if (
				source_index >= 0
				and source_index < _presentation_opponent_hand_proxies.size()
				and source_index not in requested_indices
			):
				requested_indices.append(source_index)
	if requested_indices.is_empty():
		var first_index := int(table.presentation_runtime._event_source_endpoint(event).get("index", -1))
		if first_index >= 0:
			for offset in range(amount):
				var source_index := first_index + offset
				if source_index >= 0 and source_index < _presentation_opponent_hand_proxies.size():
					requested_indices.append(source_index)
	var selected: Array[Control] = []
	for source_index in requested_indices:
		if selected.size() >= amount:
			break
		var indexed_proxy := _presentation_opponent_hand_proxies[source_index]
		if indexed_proxy != null and is_instance_valid(indexed_proxy) and indexed_proxy not in selected:
			selected.append(indexed_proxy)
	for index in range(_presentation_opponent_hand_proxies.size() - 1, -1, -1):
		if selected.size() >= amount:
			break
		var fallback_proxy := _presentation_opponent_hand_proxies[index]
		if fallback_proxy != null and is_instance_valid(fallback_proxy) and fallback_proxy not in selected:
			selected.push_front(fallback_proxy)
	for proxy in selected:
		_presentation_opponent_hand_proxies.erase(proxy)
		if proxy != null and is_instance_valid(proxy):
			_cancel_hand_layout_motion(proxy)
			result.append(proxy)
	var event_delta := _opponent_hand_event_delta(event)
	if event_delta < 0:
		_apply_opponent_hand_stage_delta(
			event_id,
			event_delta,
			not _opponent_hand_next_event_consumes_remainder(
				event_id,
				event_delta,
			),
		)
	return result

func _opponent_hand_next_event_consumes_remainder(
	event_id: String,
	current_delta: int,
) -> bool:
	var event_index := _presentation_opponent_hand_event_ids.find(event_id)
	if event_index < 0 or event_index + 1 >= _presentation_opponent_hand_event_ids.size():
		return false
	var next_event_id := _presentation_opponent_hand_event_ids[event_index + 1]
	var next_delta := int(_presentation_opponent_hand_planned_deltas.get(
		next_event_id,
		0,
	))
	var projected_count := maxi(
		0,
		_presentation_opponent_hand_stage_count + current_delta,
	)
	return (
		next_delta < 0
		and -next_delta >= projected_count
	)

func _finish_opponent_hand_event(event: Dictionary) -> void:
	var event_id := str(event.get("event_id", ""))
	if event_id.is_empty() or event_id not in _presentation_opponent_hand_event_ids:
		return
	_adopt_opponent_hand_landing_flyers(event_id)
	var expected_delta := _opponent_hand_event_delta(event)
	var applied_delta := int(_presentation_opponent_hand_event_deltas.get(event_id, 0))
	var remaining_delta := expected_delta - applied_delta
	if remaining_delta != 0:
		_apply_opponent_hand_stage_delta(event_id, remaining_delta)
	_presentation_opponent_hand_event_deltas.erase(event_id)
	_presentation_opponent_hand_event_ids.erase(event_id)
	if not _presentation_opponent_hand_event_ids.is_empty():
		return
	_clear_opponent_hand_transaction(true)

func _adopt_opponent_hand_landing_flyers(event_id: String) -> void:
	for flyer in table.card_motion_layer.entities.duplicate():
		if (
			flyer == null
			or not is_instance_valid(flyer)
			or str(flyer.get_meta("motion_event_id", "")) != event_id
			or not bool(flyer.get_meta("opponent_hand_staged_landing", false))
		):
			continue
		_adopt_opponent_hand_landing_flyer(flyer)

func _adopt_opponent_hand_landing_flyer(flyer: Control) -> bool:
	if (
		flyer == null
		or not is_instance_valid(flyer)
		or not bool(flyer.get_meta("opponent_hand_staged_landing", false))
	):
		return false
	var event_id := str(flyer.get_meta("motion_event_id", ""))
	var stage_delta := int(flyer.get_meta("opponent_hand_stage_count_delta", 1))
	table.card_motion_layer.entities.erase(flyer)
	table.card_motion_layer.tweens.erase(flyer.get_instance_id())
	table.card_motion_layer.forget(flyer)
	_cancel_hand_layout_motion(flyer)
	flyer.name = "SnapshotOpponentHandProxy_%d" % flyer.get_instance_id()
	flyer.remove_meta("card_motion_entity")
	flyer.remove_meta("motion_landing_view")
	flyer.remove_meta("opponent_hand_staged_landing")
	flyer.remove_meta("opponent_hand_stage_count_delta")
	flyer.set_meta("battle_transient_kind", "SnapshotOpponentHandProxy")
	flyer.z_index = 86 + _presentation_opponent_hand_proxies.size()
	_presentation_opponent_hand_proxies.append(flyer)
	if stage_delta != 0:
		_apply_opponent_hand_stage_delta(event_id, stage_delta)
	else:
		_sync_opponent_hand_stage_visuals()
	return true

func _sync_opponent_hand_stage_visuals(reflow: bool = true) -> void:
	_reconcile_opponent_hand_proxy_count()
	if table.opponent_hand_count_badge != null:
		table.opponent_hand_count_badge.visible = _presentation_opponent_hand_stage_count > 0
		table.opponent_hand_count_badge.text = str(_presentation_opponent_hand_stage_count)
	if reflow:
		_reflow_opponent_hand_proxies()

func _reconcile_opponent_hand_proxy_count() -> void:
	var live: Array[Control] = []
	for proxy in _presentation_opponent_hand_proxies:
		if proxy != null and is_instance_valid(proxy) and not proxy.is_queued_for_deletion():
			live.append(proxy)
	_presentation_opponent_hand_proxies.assign(live)
	var desired := mini(
		_presentation_opponent_hand_stage_count,
		maxi(0, table.opponent_hand_max_visible),
	)
	while _presentation_opponent_hand_proxies.size() > desired:
		var oldest: Control = _presentation_opponent_hand_proxies.pop_front()
		if oldest != null and is_instance_valid(oldest):
			table.motion_entities._dispose_flyer(oldest)
	var back_texture := table.card_motion_layer._texture_for_card_id("")
	while (
		_presentation_opponent_hand_proxies.size() < desired
		and table.effects != null
		and back_texture != null
	):
		var size_value := table.hand_view._current_opponent_hand_card_size()
		var center := table._opponent_hand_center()
		var proxy := table.motion_entities._create_paper_card_token(
			back_texture,
			size_value,
			"SnapshotOpponentHandProxy",
			86 + _presentation_opponent_hand_proxies.size(),
			table.motion_geometry._motion_depth_for_point(center),
		)
		proxy.remove_meta("card_motion_entity")
		proxy.position = center - size_value * 0.5
		table.effects.add_child(proxy)
		_presentation_opponent_hand_proxies.append(proxy)

func _reflow_opponent_hand_proxies() -> void:
	if _presentation_opponent_hand_proxies.is_empty() or table.opponent_hand_surface == null:
		return
	var size_value := table.hand_view._current_opponent_hand_card_size()
	var plan := BattleTableLayout.opponent_hand_plan(
		_presentation_opponent_hand_proxies.size(),
		table.opponent_hand_surface.size.x,
		size_value,
		table.opponent_hand_minimum_spacing,
		table.opponent_hand_rotation_degrees,
	)
	var items: Array[Dictionary] = plan.get("items", [])
	for index in range(mini(items.size(), _presentation_opponent_hand_proxies.size())):
		var proxy := _presentation_opponent_hand_proxies[index]
		if proxy == null or not is_instance_valid(proxy):
			continue
		_cancel_hand_layout_motion(proxy)
		var item: Dictionary = items[index]
		var local_center: Vector2 = item.get("position", Vector2.ZERO) + size_value * 0.5
		var global_center := table.opponent_hand_surface.get_global_transform_with_canvas() * local_center
		_move_snapshot_hand_source(
			proxy,
			table._effects_local(global_center),
			float(item.get("rotation_degrees", 0.0)),
			size_value,
			MotionPolicy.duration("hand_reflow"),
		)

func _clear_opponent_hand_transaction(reconcile: bool) -> void:
	if reconcile:
		table.hand_view._layout_opponent_hand(table.hand_view._current_opponent_hand_card_size())
		if table.state_ref != null and table.opponent_hand_count_badge != null:
			var count_value := table.state_ref.get_player(1 - table.view_player).hand.size()
			table.opponent_hand_count_badge.visible = count_value > 0
			table.opponent_hand_count_badge.text = str(count_value)
	# A newer network update may supersede a hand transaction before its final
	# event callback. Always release the old destination masks, even when the
	# caller intentionally skips an intermediate layout reconciliation.
	for node in _presentation_opponent_hand_nodes:
		var control := table.presentation_runtime._valid_control(node)
		if control == null:
			continue
		table.presentation_runtime.mask_counts.erase(control.get_instance_id())
		if control is CardView:
			(control as CardView).set_presentation_hidden(false)
		else:
			control.modulate.a = 1.0
	for proxy in _presentation_opponent_hand_proxies.duplicate():
		if proxy != null and is_instance_valid(proxy):
			_cancel_hand_layout_motion(proxy)
			table.motion_entities._dispose_flyer(proxy)
	_presentation_opponent_hand_proxies.clear()
	_presentation_opponent_hand_nodes.clear()
	_presentation_opponent_hand_event_ids.clear()
	_presentation_opponent_hand_event_deltas.clear()
	_presentation_opponent_hand_planned_deltas.clear()
	_presentation_opponent_hand_stage_count = 0
	_presentation_opponent_hand_target_cursor = 0

func _reposition_opponent_hand_proxies() -> void:
	if _presentation_opponent_hand_proxies.is_empty() or table.opponent_hand_surface == null:
		return
	var size_value := table.hand_view._current_opponent_hand_card_size()
	var plan := BattleTableLayout.opponent_hand_plan(
		_presentation_opponent_hand_proxies.size(),
		table.opponent_hand_surface.size.x,
		size_value,
		table.opponent_hand_minimum_spacing,
		table.opponent_hand_rotation_degrees,
	)
	var items: Array[Dictionary] = plan.get("items", [])
	for index in range(mini(items.size(), _presentation_opponent_hand_proxies.size())):
		var proxy := _presentation_opponent_hand_proxies[index]
		if proxy == null or not is_instance_valid(proxy):
			continue
		_cancel_hand_layout_motion(proxy)
		var item: Dictionary = items[index]
		table.motion_entities._resize_paper_card_token(proxy, size_value)
		var local_center: Vector2 = item.get("position", Vector2.ZERO) + size_value * 0.5
		var global_center := table.opponent_hand_surface.get_global_transform_with_canvas() * local_center
		proxy.position = table._effects_local(global_center) - size_value * 0.5
		proxy.rotation_degrees = float(item.get("rotation_degrees", 0.0))

func _stage_attachment_source_proxies(events: Array[Dictionary]) -> void:
	_clear_attachment_source_proxies()
	for event in events:
		var event_id := str(event.get("event_id", ""))
		var source := table.presentation_runtime._event_source_endpoint(event)
		if (
			event_id.is_empty()
			or str(source.get("slot", "")).is_empty()
			or str(source.get("attachment_type", "")).is_empty()
		):
			continue
		var card_ids := table.motion_geometry._event_card_ids(event)
		if card_ids.is_empty():
			continue
		var specs: Array[Dictionary] = []
		for index in range(card_ids.size()):
			var card_id := str(card_ids[index])
			var attachment_index := table._endpoint_attachment_index(source, index)
			var raw_indices: Variant = Dictionary(event.get("data", {})).get(
				"source_indices",
				[],
			)
			if raw_indices is Array and index < Array(raw_indices).size():
				attachment_index = int(Array(raw_indices)[index])
			specs.append({
				"card_id": card_id,
				"index": attachment_index,
				"ordinal": index,
			})
		if not specs.is_empty():
			table.presentation_runtime.attachment_source_specs[event_id] = specs

func _select_virtual_hand_source_rows(
	event: Dictionary,
	virtual_rows: Array[Dictionary],
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if virtual_rows.is_empty():
		return result
	var data: Dictionary = event.get("data", {})
	var card_ids := table.motion_geometry._event_card_ids(event)
	var amount := table.motion_geometry._event_amount(event, card_ids)
	var requested_indices: Array[int] = []
	var raw_indices: Variant = data.get("source_indices", [])
	if raw_indices is Array:
		for value in raw_indices:
			var index := int(value)
			if index >= 0 and index < virtual_rows.size() and index not in requested_indices:
				requested_indices.append(index)
	if requested_indices.is_empty():
		var source_index := int(table.presentation_runtime._event_source_endpoint(event).get("index", -1))
		if source_index >= 0:
			for offset in range(amount):
				var index := source_index + offset
				if index >= 0 and index < virtual_rows.size():
					requested_indices.append(index)

	var used_keys: Dictionary = {}
	for requested_index in requested_indices:
		if result.size() >= amount:
			break
		var target_id := (
			str(card_ids[result.size()])
			if result.size() < card_ids.size()
			else ""
		)
		var row: Dictionary = virtual_rows[requested_index]
		if not target_id.is_empty() and str(row.get("card_id", "")) != target_id:
			row = _first_virtual_hand_row_for_card(
				virtual_rows,
				target_id,
				used_keys,
			)
		if row.is_empty():
			continue
		var key := str(row.get("snapshot_key", ""))
		if key.is_empty() or used_keys.has(key):
			continue
		used_keys[key] = true
		result.append(row)

	for card_id_value in card_ids:
		if result.size() >= amount:
			break
		var row := _first_virtual_hand_row_for_card(
			virtual_rows,
			str(card_id_value),
			used_keys,
		)
		if row.is_empty():
			continue
		var key := str(row.get("snapshot_key", ""))
		used_keys[key] = true
		result.append(row)

	for row in virtual_rows:
		if result.size() >= amount:
			break
		var key := str(row.get("snapshot_key", ""))
		if key.is_empty() or used_keys.has(key):
			continue
		used_keys[key] = true
		result.append(row)
	return result

func _first_virtual_hand_row_for_card(
	virtual_rows: Array[Dictionary],
	card_id: String,
	used_keys: Dictionary,
) -> Dictionary:
	if card_id.is_empty():
		return {}
	for row in virtual_rows:
		var key := str(row.get("snapshot_key", ""))
		if used_keys.has(key) or str(row.get("card_id", "")) != card_id:
			continue
		return row
	return {}

func _stage_hand_transition_geometry(previous_snapshot: Dictionary) -> void:
	_clear_hand_layout_tweens()
	_presentation_hand_stage_generation += 1
	_presentation_hand_geometry_staged = false
	var snapshot_hand: Array = previous_snapshot.get("hand", [])
	var current_views: Array[CardView] = []
	for view in table.hand_views:
		if view != null and view.visible:
			current_views.append(view)
	if snapshot_hand.is_empty() or current_views.is_empty():
		return
	_presentation_hand_old_count = snapshot_hand.size()
	_presentation_hand_final_count = current_views.size()
	_presentation_hand_stage_count = _presentation_hand_old_count
	# Establish the snapshot hand's scroll transform before translating saved
	# global centers back into HandSurface coordinates. Re-centering afterwards
	# would shift every restored anchor by the old/new overflow delta.
	var stage_card_size := table.hand_view._current_hand_card_size()
	var old_plan := BattleTableLayout.own_hand_plan(
		_presentation_hand_old_count,
		table.hand_scroll.size.x,
		stage_card_size,
		table.hand_minimum_spacing,
		table.hand_rotation_degrees,
	)
	table.hand_view._apply_hand_layout_geometry(old_plan, stage_card_size)
	var pending_stage_scroll_delta := (
		float(old_plan.get("center_scroll", 0.0))
		- float(table.hand_scroll.scroll_horizontal)
	)
	var used: Dictionary = {}
	var restored := 0
	for row_value in snapshot_hand:
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		var visual_id := str(row.get("visual_id", ""))
		var matched: CardView
		for candidate in current_views:
			var instance_id := candidate.get_instance_id()
			if used.has(instance_id):
				continue
			if (
				(not visual_id.is_empty() and candidate.local_visual_id != visual_id)
				or (visual_id.is_empty() and candidate.card_id != card_id)
			):
				continue
			matched = candidate
			used[instance_id] = true
			break
		if matched == null:
			continue
		var previous_size: Variant = row.get("size", matched.size)
		if previous_size is Vector2:
			matched.custom_minimum_size = previous_size
			matched.size = previous_size
		var center_value: Variant = row.get("center", Vector2.ZERO)
		if center_value is Vector2 and table.effects != null and table.hand_surface != null:
			var previous_center: Vector2 = center_value
			var global_center: Vector2 = (
				table.effects.get_global_transform_with_canvas() * previous_center
			)
			var hand_center: Vector2 = (
				table.hand_surface.get_global_transform_with_canvas().affine_inverse()
				* global_center
			)
			hand_center.x += pending_stage_scroll_delta
			matched.position = hand_center - matched.size * 0.5
		matched.rotation_degrees = float(row.get(
			"rotation_degrees", matched.rotation_degrees))
		matched.remember_base_position()
		restored += 1
	# A full hand replacement (Professor's Research, Judge, etc.) has no final
	# anchor that can be matched back to the snapshot. The snapshot proxies still
	# own all old cards, so the staged geometry must remain active even when zero
	# real anchors were restored; otherwise the incoming hand is laid out at its
	# final count before the discard sequence begins.
	_presentation_hand_geometry_staged = true

func _schedule_hand_transition_for_event(event: Dictionary, duration: float) -> void:
	if not _presentation_hand_geometry_staged:
		return
	var source := table.presentation_runtime._event_source_endpoint(event)
	var target := table.presentation_runtime._event_target_endpoint(event)
	var card_ids := table.motion_geometry._event_card_ids(event)
	var amount := table.motion_geometry._event_amount(event, card_ids)
	if amount <= 0:
		return
	var generation := _presentation_hand_stage_generation
	var event_id := str(event.get("event_id", ""))
	if (
		str(target.get("zone", "")) == "hand"
		and int(target.get("player", table.view_player)) == table.view_player
		and str(source.get("zone", "")) != "hand"
	):
		var insertion_sequence := _begin_hand_transition_sequence(event_id, generation)
		_run_hand_insertions(
			amount,
			duration,
			generation,
			event_id,
			insertion_sequence,
		)
	elif (
		str(source.get("zone", "")) == "hand"
		and int(source.get("player", table.view_player)) == table.view_player
		and str(target.get("zone", "")) != "hand"
	):
		var removal_sequence := _begin_hand_transition_sequence(event_id, generation)
		_run_hand_removal(
			amount,
			duration,
			generation,
			event_id,
			removal_sequence,
		)

func _begin_hand_transition_sequence(
	event_id: String,
	generation: int,
) -> MotionHandle:
	if event_id.is_empty() or not table.card_motion_layer.event_motion_completions.has(event_id):
		return null
	var completion_row: Dictionary = table.card_motion_layer.event_motion_completions.get(event_id, {})
	var group := completion_row.get("group") as MotionGroup
	if group == null:
		return null
	var previous_row: Dictionary = _hand_transition_sequences.get(event_id, {})
	var previous := previous_row.get("handle") as MotionHandle
	if previous != null and not previous.is_finished():
		previous.cancel()
	var handle := MotionHandle.new()
	_hand_transition_sequences[event_id] = {
		"handle": handle,
		"generation": generation,
		"reflow_handles": [],
		"flight_handles": [],
		"landing_handles": [],
	}
	handle.completed.connect(
		_on_hand_transition_sequence_completed.bind(event_id, handle),
		CONNECT_ONE_SHOT,
	)
	group.add(handle)
	return handle

func _on_hand_transition_sequence_completed(
	_completed_handle: MotionHandle,
	event_id: String,
	expected_handle: MotionHandle,
) -> void:
	var row: Dictionary = _hand_transition_sequences.get(event_id, {})
	if row.get("handle") == expected_handle:
		_hand_transition_sequences.erase(event_id)

func _set_hand_sequence_handles(event_id: String, key: String, handles: Array) -> void:
	if not _hand_transition_sequences.has(event_id):
		return
	var row: Dictionary = _hand_transition_sequences[event_id]
	row[key] = handles.duplicate()
	_hand_transition_sequences[event_id] = row

func _hand_sequence_handles(event_id: String, key: String) -> Array:
	var result: Array = []
	var row: Dictionary = _hand_transition_sequences.get(event_id, {})
	for value in row.get(key, []):
		var handle := value as MotionHandle
		if handle != null:
			result.append(handle)
	return result

func _wait_for_motion_handles(handles: Array) -> void:
	var group := MotionGroup.new()
	for value in handles:
		var handle := value as MotionHandle
		if handle != null:
			group.add(handle)
	group.seal()
	if not group.is_completed():
		await group.completed

func _finish_hand_transition_sequence(
	event_id: String,
	handle: MotionHandle,
	cancelled: bool = false,
) -> void:
	if handle == null or handle.is_finished():
		return
	var row: Dictionary = _hand_transition_sequences.get(event_id, {})
	if row.get("handle") != handle:
		handle.cancel()
		return
	if cancelled:
		handle.cancel()
	else:
		handle.finish()

func _run_hand_insertions(
	amount: int,
	flight_duration: float,
	generation: int,
	event_id: String,
	sequence: MotionHandle,
) -> void:
	var delay := flight_duration * 0.55
	if MotionPolicy.reduced():
		delay = 0.0
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	if generation != _presentation_hand_stage_generation:
		_finish_hand_transition_sequence(event_id, sequence, true)
		return
	var latest_reflow_handles: Array = []
	# Multi-card arrivals are separated by one stagger interval.  Letting every
	# insertion start the normal (longer) hand reflow means each tween is killed
	# by the next card before it can settle; the visible cards consequently bunch
	# up and only fan out after the final arrival.  A per-insertion reflow still
	# preserves the physical "incoming card pushes the hand" behaviour, but must
	# finish just before the following card reaches the hand.
	var insertion_reflow_duration := -1.0
	if amount > 1 and not MotionPolicy.reduced():
		insertion_reflow_duration = minf(
			MotionPolicy.duration("hand_reflow"),
			MotionPolicy.duration("multi_card_stagger") * 0.82,
		)
	for index in range(amount):
		_presentation_hand_stage_count = mini(
			_presentation_hand_final_count,
			_presentation_hand_stage_count + 1,
		)
		latest_reflow_handles = _tween_hand_to_stage_count(
			_presentation_hand_stage_count,
			insertion_reflow_duration,
		)
		_set_hand_sequence_handles(event_id, "reflow_handles", latest_reflow_handles)
		if index + 1 < amount and not MotionPolicy.reduced():
			await get_tree().create_timer(
				MotionPolicy.duration("multi_card_stagger")).timeout
			if generation != _presentation_hand_stage_generation:
				_finish_hand_transition_sequence(event_id, sequence, true)
				return
	if sequence == null:
		return
	await _wait_for_motion_handles(latest_reflow_handles)
	if sequence.is_finished():
		return
	await _wait_for_motion_handles(_hand_sequence_handles(event_id, "flight_handles"))
	if sequence.is_finished():
		return
	await _wait_for_motion_handles(_hand_sequence_handles(event_id, "landing_handles"))
	_finish_hand_transition_sequence(event_id, sequence)

func _run_hand_removal(
	amount: int,
	flight_duration: float,
	generation: int,
	event_id: String,
	sequence: MotionHandle,
) -> void:
	var delay := minf(0.06, flight_duration * 0.12)
	if MotionPolicy.reduced():
		delay = 0.0
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	if generation != _presentation_hand_stage_generation:
		_finish_hand_transition_sequence(event_id, sequence, true)
		return
	_presentation_hand_stage_count = maxi(
		0,
		_presentation_hand_stage_count - amount,
	)
	var reflow_handles := _tween_hand_to_stage_count(_presentation_hand_stage_count)
	reflow_handles.append_array(_tween_snapshot_hand_sources_to_virtual_layout())
	_set_hand_sequence_handles(event_id, "reflow_handles", reflow_handles)
	if sequence == null:
		return
	await _wait_for_motion_handles(reflow_handles)
	_finish_hand_transition_sequence(event_id, sequence)

func _claim_snapshot_hand_sources(event: Dictionary) -> Array[Control]:
	var result: Array[Control] = []
	var event_id := str(event.get("event_id", ""))
	var keys: Array = table.presentation_runtime.event_hand_sources.get(event_id, [])
	for key_value in keys:
		var key := str(key_value)
		_presentation_hand_virtual_keys.erase(key)
		var proxy := table.presentation_runtime._valid_control(table.presentation_runtime.hand_proxy_by_key.get(key))
		if proxy != null:
			_cancel_hand_layout_motion(proxy)
			_presentation_hand_source_proxies.erase(proxy)
		table.presentation_runtime.hand_proxy_by_key.erase(key)
		result.append(proxy)
	return result

func _tween_snapshot_hand_sources_to_virtual_layout() -> Array[MotionHandle]:
	var handles: Array[MotionHandle] = []
	if _presentation_hand_source_proxies.is_empty() or table.hand_surface == null:
		return handles
	var card_size := table.hand_view._current_hand_card_size()
	var plan := BattleTableLayout.own_hand_plan(
		_presentation_hand_virtual_keys.size(),
		table.hand_scroll.size.x,
		card_size,
		table.hand_minimum_spacing,
		table.hand_rotation_degrees,
	)
	var items: Array[Dictionary] = plan.get("items", [])
	var duration := MotionPolicy.duration("hand_reflow")
	for proxy in _presentation_hand_source_proxies.duplicate():
		if proxy == null or not is_instance_valid(proxy):
			_presentation_hand_source_proxies.erase(proxy)
			continue
		var key := str(proxy.get_meta("snapshot_hand_key", ""))
		var virtual_index := _presentation_hand_virtual_keys.find(key)
		if virtual_index < 0 or virtual_index >= items.size():
			continue
		var item: Dictionary = items[virtual_index]
		var local_center: Vector2 = item.get("position", Vector2.ZERO) + card_size * 0.5
		var global_center := table.hand_surface.get_global_transform_with_canvas() * local_center
		var target_center := table._effects_local(global_center)
		var handle := _move_snapshot_hand_source(
			proxy,
			target_center,
			float(item.get("rotation_degrees", 0.0)),
			card_size,
			duration,
		)
		if handle != null:
			handles.append(handle)
	return handles

func _move_snapshot_hand_source(
	proxy: Control,
	target_center: Vector2,
	target_rotation: float,
	target_size: Vector2,
	duration: float,
) -> MotionHandle:
	var handle := MotionHandle.new()
	if proxy == null or not is_instance_valid(proxy):
		handle.cancel()
		return handle
	_cancel_hand_layout_motion(proxy)
	table.motion_entities._resize_paper_card_token(proxy, target_size)
	var target_position := target_center - target_size * 0.5
	if duration <= 0.0:
		proxy.position = target_position
		proxy.rotation_degrees = target_rotation
		handle.finish()
		return handle
	var tween := create_tween().set_parallel(true)
	tween.tween_property(proxy, "position", target_position, duration).set_trans(
		Tween.TRANS_QUAD,
	).set_ease(Tween.EASE_OUT)
	tween.tween_property(
		proxy,
		"rotation_degrees",
		target_rotation,
		duration,
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	handle.bind_tween(tween)
	var instance_id := proxy.get_instance_id()
	_hand_layout_motion_handles[instance_id] = handle
	handle.completed.connect(
		_on_hand_layout_motion_completed.bind(instance_id, handle),
		CONNECT_ONE_SHOT,
	)
	return handle

func _cancel_hand_layout_motion(control: Control) -> void:
	if control == null or not is_instance_valid(control):
		return
	var instance_id := control.get_instance_id()
	var handle := _hand_layout_motion_handles.get(instance_id) as MotionHandle
	if handle != null and not handle.is_finished():
		handle.cancel()
	_hand_layout_motion_handles.erase(instance_id)

func _tween_hand_to_stage_count(
	stage_count: int,
	duration_override: float = -1.0,
) -> Array[MotionHandle]:
	var handles: Array[MotionHandle] = []
	var card_size := table.hand_view._current_hand_card_size()
	var layout_count := mini(stage_count, _presentation_hand_final_count)
	var plan := BattleTableLayout.own_hand_plan(
		layout_count,
		table.hand_scroll.size.x,
		card_size,
		table.hand_minimum_spacing,
		table.hand_rotation_degrees,
	)
	table.hand_view._apply_hand_layout_geometry(plan, card_size)
	var items: Array[Dictionary] = plan["items"]
	var duration := (
		duration_override
		if duration_override >= 0.0
		else MotionPolicy.duration("hand_reflow")
	)
	for index in range(layout_count):
		if index >= table.hand_views.size():
			break
		var view := table.hand_views[index]
		if view == null or not view.visible:
			continue
		var item: Dictionary = items[index]
		view.custom_minimum_size = card_size
		view.size = card_size
		view.z_index = mini(table.HAND_CARD_MAX_Z, int(item["z_index"]))
		var handle := _move_hand_card(
			view,
			item["position"],
			float(item["rotation_degrees"]),
			duration,
		)
		if handle != null:
			handles.append(handle)
	table.hand_view._apply_hand_interaction_order()
	return handles

func _move_hand_card(
	view: CardView,
	target_position: Vector2,
	target_rotation: float,
	duration: float,
) -> MotionHandle:
	if view == null or not is_instance_valid(view):
		var missing := MotionHandle.new()
		missing.cancel()
		return missing
	var instance_id := view.get_instance_id()
	var previous := _hand_layout_motion_handles.get(instance_id) as MotionHandle
	if previous != null and not previous.is_finished():
		previous.cancel()
	var handle := table.hand_view.move_card(
		view,
		target_position,
		target_rotation,
		duration,
	)
	_hand_layout_motion_handles[instance_id] = handle
	handle.completed.connect(
		_on_hand_layout_motion_completed.bind(instance_id, handle),
		CONNECT_ONE_SHOT,
	)
	return handle

func _on_hand_layout_motion_completed(
	_completed_handle: MotionHandle,
	instance_id: int,
	expected_handle: MotionHandle,
) -> void:
	if _hand_layout_motion_handles.get(instance_id) == expected_handle:
		_hand_layout_motion_handles.erase(instance_id)

func _clear_hand_layout_tweens() -> void:
	for handle_value in _hand_layout_motion_handles.values().duplicate():
		var handle := handle_value as MotionHandle
		if handle != null and not handle.is_finished():
			handle.cancel()
	_hand_layout_motion_handles.clear()
	table.hand_view.cancel_all()

func _hand_target_views_for_incoming(event: Dictionary) -> Array[Control]:
	if table.motion_geometry._is_transient_opening_draw(event):
		return []
	var event_id := str(event.get("event_id", ""))
	if table.presentation_runtime.event_hand_targets.has(event_id):
		var cached: Array[Control] = []
		for value in table.presentation_runtime.event_hand_targets[event_id]:
			var view := value as Control
			if view:
				cached.append(view)
		return cached
	var result: Array[Control] = []
	var target := table.presentation_runtime._event_target_endpoint(event)
	var card_ids := table.motion_geometry._event_card_ids(event)
	var amount := table.motion_geometry._event_amount(event, card_ids)
	if (
		str(target.get("zone", "")) != "hand"
		or int(target.get("player", table.view_player)) != table.view_player
		or amount <= 0
	):
		return result
	result.append_array(_incoming_hand_targets_for_event(event, false))
	return result

func _precompute_hand_targets_for_event(event: Dictionary) -> void:
	if table.motion_geometry._is_transient_opening_draw(event):
		return
	var event_type := str(event.get("event_type", ""))
	var target := table.presentation_runtime._event_target_endpoint(event)
	var targets_hand := event_type in ["cards_drawn", "prize_taken"]
	if str(target.get("zone", "")) == "hand":
		targets_hand = true
	if not targets_hand:
		return
	var event_id := str(event.get("event_id", ""))
	var card_ids := table.motion_geometry._event_card_ids(event)
	var amount := table.motion_geometry._event_amount(event, card_ids)
	if event_id.is_empty() or amount <= 0:
		return
	var target_player := int(target.get("player", table.view_player))
	if target_player == 1 - table.view_player:
		var opponent_targets := _opponent_hand_target_views_for_incoming(event, true)
		if not opponent_targets.is_empty():
			table.presentation_runtime.event_hand_targets[event_id] = opponent_targets
		return
	if target_player != table.view_player:
		return
	var targets := _incoming_hand_targets_for_event(event, true)
	if targets.is_empty():
		return
	table.presentation_runtime.event_hand_targets[event_id] = targets

func _record_hand_removals_for_event(event: Dictionary) -> void:
	var source := table.presentation_runtime._event_source_endpoint(event)
	if str(source.get("zone", "")) != "hand":
		return
	var player := int(source.get("player", table.view_player))
	if player != table.view_player:
		return
	var target := table.presentation_runtime._event_target_endpoint(event)
	if str(target.get("zone", "")) == "hand":
		return
	var card_ids := table.motion_geometry._event_card_ids(event)
	if card_ids.is_empty():
		return
	var player_key := str(player)
	var counts: Dictionary = Dictionary(
		table.presentation_runtime.hand_removed_counts.get(player_key, {})
	)
	for value in card_ids:
		var card_id := str(value)
		if card_id.is_empty():
			continue
		counts[card_id] = int(counts.get(card_id, 0)) + 1
	table.presentation_runtime.hand_removed_counts[player_key] = counts

func _incoming_hand_targets_for_event(
	event: Dictionary,
	consume_cursor: bool,
) -> Array[Control]:
	var result: Array[Control] = []
	var target := table.presentation_runtime._event_target_endpoint(event)
	if (
		str(target.get("zone", "")) != "hand"
		or int(target.get("player", table.view_player)) != table.view_player
	):
		return result
	var card_ids := table.motion_geometry._event_card_ids(event)
	var amount := table.motion_geometry._event_amount(event, card_ids)
	if amount <= 0:
		return result
	var candidates := _incoming_hand_candidates_from_snapshot()
	if candidates.is_empty():
		return result
	var cursor := clampi(
		int(table.presentation_runtime.hand_target_cursor.get(table.view_player, 0)),
		0,
		candidates.size(),
	)
	var available: Array[CardView] = []
	for index in range(cursor, candidates.size()):
		available.append(candidates[index])
	var selected := _select_matching_hand_targets(available, card_ids, amount)
	for view in selected:
		result.append(view)
	if consume_cursor:
		table.presentation_runtime.hand_target_cursor[table.view_player] = cursor + selected.size()
	return result

func _incoming_hand_candidates_from_snapshot() -> Array[CardView]:
	var visible_views: Array[CardView] = []
	for view in table.hand_views:
		if view and view.visible:
			visible_views.append(view)
	if visible_views.is_empty():
		return []
	var snapshot_hand: Array = table.presentation_runtime.snapshot.get("hand", [])
	if snapshot_hand.is_empty():
		return visible_views
	var snapshot_counts: Dictionary = {}
	for row_value in snapshot_hand:
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		if card_id.is_empty():
			continue
		snapshot_counts[card_id] = int(snapshot_counts.get(card_id, 0)) + 1
	var removed_counts: Dictionary = Dictionary(
		table.presentation_runtime.hand_removed_counts.get(str(table.view_player), {})
	)
	for removed_card_id_value in removed_counts.keys():
		var removed_card_id := str(removed_card_id_value)
		var remaining := (
			int(snapshot_counts.get(removed_card_id, 0))
			- int(removed_counts.get(removed_card_id, 0))
		)
		if remaining > 0:
			snapshot_counts[removed_card_id] = remaining
		else:
			snapshot_counts.erase(removed_card_id)
	var candidates: Array[CardView] = []
	for view in visible_views:
		var card_id := str(view.card_id)
		var remaining := int(snapshot_counts.get(card_id, 0))
		if not card_id.is_empty() and remaining > 0:
			snapshot_counts[card_id] = remaining - 1
		else:
			candidates.append(view)
	return candidates

func _select_matching_hand_targets(
	candidates: Array[CardView],
	card_ids: Array,
	amount: int,
) -> Array[CardView]:
	var selected: Array[CardView] = []
	if candidates.is_empty() or amount <= 0:
		return selected
	var used: Array[bool] = []
	for _candidate in candidates:
		used.append(false)
	for value in card_ids:
		if selected.size() >= amount:
			break
		var card_id := str(value)
		if card_id.is_empty():
			continue
		for index in range(candidates.size()):
			if used[index] or candidates[index].card_id != card_id:
				continue
			used[index] = true
			selected.append(candidates[index])
			break
	for index in range(candidates.size()):
		if selected.size() >= amount:
			break
		if used[index]:
			continue
		used[index] = true
		selected.append(candidates[index])
	return selected

func _opponent_hand_target_views_for_incoming(
	event: Dictionary,
	consume_cursor: bool = false,
) -> Array[Control]:
	var result: Array[Control] = []
	if table.motion_geometry._is_transient_opening_draw(event):
		return result
	var event_id := str(event.get("event_id", ""))
	if table.presentation_runtime.event_hand_targets.has(event_id):
		for value in table.presentation_runtime.event_hand_targets[event_id]:
			var cached := value as Control
			if cached != null and is_instance_valid(cached):
				result.append(cached)
		return result
	var target := table.presentation_runtime._event_target_endpoint(event)
	if (
		str(target.get("zone", "")) != "hand"
		or int(target.get("player", table.view_player)) != 1 - table.view_player
	):
		return result
	var card_ids := table.motion_geometry._event_card_ids(event)
	var amount := _opponent_hand_event_amount(event)
	if amount <= 0:
		return result
	var visible_views: Array[CardView] = []
	for view in table.opponent_hand_views:
		if view and view.visible:
			visible_views.append(view)
	var transaction_active := not _presentation_opponent_hand_event_ids.is_empty()
	var first := 0
	var finish := visible_views.size()
	if transaction_active:
		first = clampi(
			_presentation_opponent_hand_target_cursor,
			0,
			visible_views.size(),
		)
		finish = mini(visible_views.size(), first + amount)
	else:
		# Compatibility callers may resolve a single event without staging a
		# replacement transaction.  In that case incoming cards belong to the
		# newly appended tail of the visible opponent hand, not its first cards.
		first = maxi(0, visible_views.size() - mini(amount, visible_views.size()))
	for index in range(first, finish):
		result.append(visible_views[index])
	if consume_cursor and transaction_active:
		_presentation_opponent_hand_target_cursor = finish
	return result

func _dispose_snapshot_hand_source(proxy: Control) -> void:
	if proxy == null or not is_instance_valid(proxy):
		return
	_cancel_hand_layout_motion(proxy)
	_presentation_hand_source_proxies.erase(proxy)
	var key := str(proxy.get_meta("snapshot_hand_key", ""))
	if not key.is_empty() and table.presentation_runtime.hand_proxy_by_key.get(key) == proxy:
		table.presentation_runtime.hand_proxy_by_key.erase(key)
	table.motion_entities._dispose_flyer(proxy)

func _clear_snapshot_hand_sources() -> void:
	for proxy in _presentation_hand_source_proxies.duplicate():
		_dispose_snapshot_hand_source(proxy)
	_presentation_hand_source_proxies.clear()
	table.presentation_runtime.hand_proxy_by_key.clear()
	table.presentation_runtime.event_hand_sources.clear()
	table.presentation_runtime.hand_snapshot_rows.clear()
	_presentation_hand_virtual_keys.clear()

func _activate_attachment_source_proxies(event: Dictionary) -> void:
	if table.effects == null:
		return
	var event_id := str(event.get("event_id", ""))
	if event_id.is_empty() or table.presentation_runtime.attachment_source_proxies.has(event_id):
		return
	var source := table.presentation_runtime._event_source_endpoint(event)
	if (
		str(source.get("slot", "")).is_empty()
		or str(source.get("attachment_type", "")).is_empty()
	):
		return
	var specs: Array = table.presentation_runtime.attachment_source_specs.get(event_id, [])
	if specs.is_empty():
		var card_ids := table.motion_geometry._event_card_ids(event)
		var raw_indices: Variant = Dictionary(event.get("data", {})).get(
			"source_indices",
			[],
		)
		for ordinal in range(card_ids.size()):
			var attachment_index := table._endpoint_attachment_index(source, ordinal)
			if raw_indices is Array and ordinal < Array(raw_indices).size():
				attachment_index = int(Array(raw_indices)[ordinal])
			specs.append({
				"card_id": str(card_ids[ordinal]),
				"index": attachment_index,
				"ordinal": ordinal,
			})
	if specs.is_empty():
		return
	var player := int(source.get("player", table.view_player))
	var slot_name := str(source.get("slot", ""))
	var source_key := "%d:%s" % [player, slot_name]
	var source_view := table.presentation_runtime._valid_card_view(table.presentation_runtime.slot_covers.get(source_key))
	if source_view == null:
		source_view = table.get_slot_view(player, slot_name)
	var fallback_size := table.motion_geometry._flying_card_size(str(event.get("event_type", "")))
	var proxy_size := (
		table.motion_geometry._attachment_motion_size(source_view.size, fallback_size)
		if source_view != null
		else table.motion_geometry._current_endpoint_size(source, fallback_size)
	)
	var rotation := source_view.rotation_degrees if source_view != null else 0.0
	var proxies: Array[Control] = []
	for spec_value in specs:
		var spec := spec_value as Dictionary
		var card_id := str(spec.get("card_id", ""))
		var attachment_index := int(spec.get("index", -1))
		var ordinal := int(spec.get("ordinal", proxies.size()))
		var exact_source := source.duplicate(true)
		exact_source["attachment_card_id"] = card_id
		exact_source["index"] = attachment_index
		var center := (
			table._effects_local(
				source_view.attachment_layout_visual_global_rect(
					str(source.get("attachment_type", "")),
					card_id,
					attachment_index,
				).get_center()
			)
			if source_view != null
			else table.resolve_endpoint_center(exact_source)
		)
		var descriptor := AttachmentVisualDescriptor.resolve(
			str(source.get("attachment_type", "")),
			card_id,
			attachment_index,
			table.catalog,
		)
		var texture := (
			descriptor.icon
			if descriptor.icon != null
			else table.card_motion_layer._neutral_public_card_texture()
		)
		if texture == null:
			continue
		var proxy := table.motion_entities._create_paper_card_token(
			texture,
			proxy_size,
			"AttachmentSourceProxy",
			94 + ordinal,
			table.motion_geometry._motion_depth_for_point(center),
		)
		proxy.position = center - proxy.size * 0.5
		proxy.rotation_degrees = rotation
		proxy.visible = true
		proxy.set_meta("motion_start", center)
		proxy.set_meta("attachment_source_event_id", event_id)
		proxy.set_meta("attachment_badge_proxy", true)
		proxy.set_meta("motion_card_id", card_id)
		proxy.set_meta("attachment_source_index", attachment_index)
		table.motion_entities._configure_attachment_badge_marker(proxy, descriptor)
		table.effects.add_child(proxy)
		proxies.append(proxy)
	if not proxies.is_empty():
		table.presentation_runtime.attachment_source_proxies[event_id] = proxies

func _claim_attachment_source_proxies(event: Dictionary) -> Array[Control]:
	var event_id := str(event.get("event_id", ""))
	_activate_attachment_source_proxies(event)
	var result: Array[Control] = []
	for proxy_value in table.presentation_runtime.attachment_source_proxies.get(event_id, []):
		var proxy := table.presentation_runtime._valid_control(proxy_value)
		if proxy != null:
			result.append(proxy)
	table.presentation_runtime.attachment_source_proxies.erase(event_id)
	table.presentation_runtime.attachment_source_specs.erase(event_id)
	return result

func _clear_attachment_source_proxies() -> void:
	for proxies_value in table.presentation_runtime.attachment_source_proxies.values():
		for proxy_value in proxies_value:
			var proxy := table.presentation_runtime._valid_control(proxy_value)
			if proxy != null:
				table.motion_entities._dispose_flyer(proxy)
	table.presentation_runtime.attachment_source_proxies.clear()
	table.presentation_runtime.attachment_source_specs.clear()
