class_name BattlePresentationRuntime
extends Node

var table: BattleTable
var snapshot: Dictionary = {}
var hud_state: GameState
var actions_suppressed := false
var active_event_id := ""

var reveals: Dictionary = {}
var mask_counts: Dictionary = {}
var feedbacks: Dictionary = {}
var landing_feedbacks: Dictionary = {}
var covers: Dictionary = {}
var cover_tweens: Dictionary = {}
var slot_covers: Dictionary = {}
var slot_cover_states: Dictionary = {}
var slot_event_queues: Dictionary = {}
var slot_event_plans: Dictionary = {}
var deferred_ko_slots: Dictionary = {}
var event_hand_targets: Dictionary = {}
var hand_target_cursor: Dictionary = {}
var hand_removed_counts: Dictionary = {}
var event_hand_sources: Dictionary = {}
var hand_proxy_by_key: Dictionary = {}
var hand_snapshot_rows: Dictionary = {}
var attachment_source_proxies: Dictionary = {}
var attachment_source_specs: Dictionary = {}
var zone_states: Dictionary = {}


func configure(p_table: BattleTable) -> void:
	table = p_table


func clear() -> void:
	for registry in _registries():
		registry.clear()


func active_mask_count() -> int:
	return mask_counts.size()


func active_cover_count() -> int:
	return covers.size() + slot_covers.size()


func staged_hand_event_count() -> int:
	return event_hand_targets.size() + event_hand_sources.size()


func _registries() -> Array[Dictionary]:
	return [
		reveals, mask_counts, feedbacks, landing_feedbacks, covers, cover_tweens,
		slot_covers, slot_cover_states, slot_event_queues, slot_event_plans,
		deferred_ko_slots, event_hand_targets, hand_target_cursor,
		hand_removed_counts, event_hand_sources, hand_proxy_by_key,
		hand_snapshot_rows, attachment_source_proxies, attachment_source_specs,
		zone_states,
	]

func _on_floating_text_requested(
	text: String,
	target: Dictionary,
	color: Color,
) -> void:
	if (
		str(target.get(PresentationDirector.FEEDBACK_CHANNEL_KEY, ""))
		== PresentationDirector.FEEDBACK_CHANNEL_ANNOUNCEMENT
	):
		if table.announcement_layer:
			var handle := table.announcement_layer.show_announcement(
				text,
				color,
				MotionPolicy.reduced(),
			)
			_register_presentation_feedback_motion(handle)
		return
	var layer := _world_feedback_layer()
	if layer:
		var handle := layer.floating_text(
			text,
			_world_feedback_point(table.resolve_endpoint_center(target)),
			color,
			not MotionPolicy.reduced(),
		)
		_register_presentation_feedback_motion(handle)


func _register_presentation_feedback_motion(handle: MotionHandle) -> void:
	if handle == null or handle.is_finished():
		return
	if (
		not active_event_id.is_empty()
		and table.card_motion_layer.event_motion_completions.has(active_event_id)
	):
		table.card_motion_layer._register_event_motion_handle(active_event_id, handle)
	elif table.director != null:
		table.director.register_feedback_motion(handle)


func _on_burst_requested(
	kind: String,
	target: Dictionary,
	color: Color,
) -> void:
	_burst_world_at_motion_point(table.resolve_endpoint_center(target), color, kind)
	var player := int(target.get("player", -1))
	var slot_name := str(target.get("slot", ""))
	var view := _valid_card_view(slot_covers.get(
		"%d:%s" % [player, slot_name],
	))
	if view == null:
		view = table.get_slot_view(player, slot_name)
	if view:
		_register_presentation_feedback_motion(view.flash(color, 0.36))
		if kind in ["impact", "ko"]:
			_register_presentation_feedback_motion(
				view.shake(8.0 if kind == "impact" else 11.0, 0.3),
			)


func _on_card_landing_feedback_scheduled(
	event: Dictionary,
	feedback: Dictionary,
) -> void:
	var event_id := str(event.get("event_id", ""))
	if event_id.is_empty():
		return
	landing_feedbacks[event_id] = feedback.duplicate(true)


func _play_card_landing_feedback(
	flying: Control,
	finish: Vector2,
) -> bool:
	if flying == null:
		return false
	var event_id := str(flying.get_meta("motion_event_id", ""))
	if event_id.is_empty() or not landing_feedbacks.has(event_id):
		return false
	var feedback: Dictionary = landing_feedbacks.get(event_id, {})
	landing_feedbacks.erase(event_id)
	_burst_world_at_motion_point(
		finish,
		feedback.get("color", DesignTokens.CYAN) as Color,
		str(feedback.get("kind", "card_land")),
	)
	var camera_strength := float(feedback.get("camera_strength", 0.0))
	var camera_duration := float(feedback.get("camera_duration", 0.0))
	if table.camera_rig != null and camera_strength > 0.0:
		table.camera_rig.impulse(
			camera_strength,
			camera_duration,
			table._settings_reduced_motion(),
		)
	return true


func _world_feedback_layer() -> BattleEffectLayer:
	if table.world_feedback != null and is_instance_valid(table.world_feedback):
		return table.world_feedback
	return null


func _world_feedback_point(motion_point: Vector2) -> Vector2:
	var layer := _world_feedback_layer()
	if layer == null or table.effects == null or layer == table.effects:
		return motion_point
	var global_point := table.effects.get_global_transform_with_canvas() * motion_point
	return layer.get_global_transform_with_canvas().affine_inverse() * global_point


func _burst_world_at_motion_point(
	motion_point: Vector2,
	color: Color,
	kind: String,
) -> void:
	if MotionPolicy.reduced():
		return
	var layer := _world_feedback_layer()
	if layer:
		layer.burst(_world_feedback_point(motion_point), color, kind)


func _stage_presentation_hud(previous_snapshot: Dictionary) -> void:
	var state_value: Variant = previous_snapshot.get("state", {})
	if not state_value is Dictionary or Dictionary(state_value).is_empty():
		return
	var previous_state := GameState.from_dict(Dictionary(state_value))
	hud_state = previous_state
	actions_suppressed = true
	table.board_view._refresh_header(previous_state)
	table.board_view._refresh_field_info(previous_state)
	# The action log is public, committed state. Keeping the previous revision's
	# log during a long presentation made the latest player actions look missing
	# until every animation finished, even though the server had already accepted
	# them. Other counters remain staged from the previous snapshot.
	table.board_view._refresh_log(table.state_ref if table.state_ref != null else previous_state)
	table.board_view._refresh_actions()
	table.board_view._refresh_target_hints()
	var previous_opponent_hand := previous_state.get_player(1 - table.view_player).hand.size()
	if table.opponent_hand_count_badge != null:
		table.opponent_hand_count_badge.visible = previous_opponent_hand > 0
		table.opponent_hand_count_badge.text = str(previous_opponent_hand)


func _apply_event_to_presentation_hud(event: Dictionary) -> void:
	if hud_state == null:
		return
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", table.view_player)))
	var card_ids := table.motion_geometry._event_card_ids(event)
	var amount := table.motion_geometry._event_amount(event, card_ids)
	match event_type:
		"cards_drawn":
			_hud_move_endpoint_cards(
				_event_source_endpoint(event),
				_event_target_endpoint(event),
				card_ids,
				amount,
			)
		"prize_taken":
			_hud_move_endpoint_cards(
				_event_source_endpoint(event),
				_event_target_endpoint(event),
				card_ids,
				amount,
			)
		"cards_discarded":
			var endpoints := _discard_endpoints_for_event(event)
			_hud_move_endpoint_cards(endpoints.get("source", {}), endpoints.get("target", {}), card_ids, amount)
		"cards_revealed":
			var reveal_source := _event_source_endpoint(event)
			var reveal_player := int(reveal_source.get("player", actor))
			for row in table.motion_geometry._reveal_rows(event):
				var destination := table.motion_geometry._reveal_destination(row, reveal_player)
				if str(destination.get("zone", "deck")) != "deck":
					_hud_move_zone_cards(reveal_player, "deck", int(destination.get("player", reveal_player)), str(destination.get("zone", "deck")), [str(row.get("card_id", ""))], 1)
		"pokemon_played", "trainer_played", "stadium_changed", "tool_attached", "energy_attached", "card_moved", "cards_selected":
			_hud_move_endpoint_cards(_event_source_endpoint(event), _event_target_endpoint(event), card_ids, amount)
		"turn_end", "checkup":
			hud_state.phase = "POKEMON_CHECKUP"
		"turn_start":
			hud_state.active_player_idx = actor
			hud_state.turn_number = int(data.get("turn", hud_state.turn_number))
			hud_state.phase = "DRAW"
		"deck_exhausted", "game_over":
			hud_state.phase = "GAME_OVER"
			if table.state_ref != null:
				hud_state.winner = table.state_ref.winner
	table.board_view._refresh_header(hud_state)
	table.board_view._refresh_field_info(hud_state)
	var opponent_count := hud_state.get_player(1 - table.view_player).hand.size()
	if table.opponent_hand_count_badge != null:
		table.opponent_hand_count_badge.visible = opponent_count > 0
		table.opponent_hand_count_badge.text = str(opponent_count)


func _hud_move_endpoint_cards(
	source_value: Variant,
	target_value: Variant,
	card_ids: Array,
	amount: int,
) -> void:
	var source := Dictionary(source_value) if source_value is Dictionary else {}
	var target := Dictionary(target_value) if target_value is Dictionary else {}
	_hud_move_zone_cards(
		int(source.get("player", -1)),
		str(source.get("zone", "")),
		int(target.get("player", -1)),
		str(target.get("zone", "")),
		card_ids,
		amount,
	)


func _hud_move_zone_cards(
	source_player: int,
	source_zone: String,
	target_player: int,
	target_zone: String,
	card_ids: Array,
	amount: int,
) -> void:
	if source_player in [0, 1] and not source_zone.is_empty():
		var source_cards := _hud_zone_cards(source_player, source_zone)
		for index in range(amount):
			var card_id := str(card_ids[index]) if index < card_ids.size() else ""
			if not card_id.is_empty() and card_id in source_cards:
				source_cards.erase(card_id)
			elif not source_cards.is_empty():
				source_cards.pop_back()
	if target_player in [0, 1] and not target_zone.is_empty():
		var target_cards := _hud_zone_cards(target_player, target_zone)
		for index in range(amount):
			target_cards.append(str(card_ids[index]) if index < card_ids.size() else "")


func _hud_zone_cards(player: int, zone: String) -> Array[String]:
	var owner := hud_state.get_player(player)
	match zone:
		"hand":
			return owner.hand
		"deck":
			return owner.deck
		"discard":
			return owner.discard
		"prizes":
			return owner.prizes
	return []


func _stage_slot_visual_transactions(
	events: Array[Dictionary],
	previous_snapshot: Dictionary,
) -> void:
	_clear_slot_visual_transactions()
	var event_queues: Dictionary = {}
	for event in events:
		var event_id := str(event.get("event_id", ""))
		if event_id.is_empty():
			continue
		for key in _slot_visual_keys_for_event(event):
			var queue: Array = event_queues.get(key, [])
			if event_id not in queue:
				queue.append(event_id)
			event_queues[key] = queue
			if (
				PresentationEvent.canonical_event_type(
					str(event.get("event_type", "")),
				) == "pokemon_ko"
				and bool(Dictionary(event.get("data", {})).get(
					"defer_leave_play",
					false,
				))
			):
				deferred_ko_slots[key] = true
	for key_value in event_queues.keys():
		var key := str(key_value)
		slot_event_plans[key] = Array(
			event_queues.get(key, []),
		).duplicate()
	var snapshot_slots: Dictionary = previous_snapshot.get("slots", {})
	for key_value in event_queues.keys():
		var key := str(key_value)
		var row: Dictionary = snapshot_slots.get(key, {})
		if row.is_empty() or bool(row.get("empty", true)):
			continue
		var pokemon_data: Dictionary = row.get("pokemon", {})
		if pokemon_data.is_empty():
			continue
		var state := PokemonState.from_dict(pokemon_data)
		var cover := _spawn_slot_state_cover(key, row, state)
		if cover == null:
			continue
		slot_covers[key] = cover
		slot_cover_states[key] = state
		slot_event_queues[key] = event_queues[key]


func _slot_visual_keys_for_event(event: Dictionary) -> Array[String]:
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	if event_type not in [
		"card_moved",
		"cards_discarded",
		"confusion_failed",
		"damage_counters_placed",
		"damage_dealt",
		"dazzled_failed",
		"energy_attached",
		"healed",
		"pokemon_evolved",
		"pokemon_ko",
		"pokemon_played",
		"promoted",
		"retreat",
		"status_applied",
		"status_removed",
		"switched",
		"tool_attached",
	]:
		return []
	var result: Array[String] = []
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", table.view_player)))
	for endpoint in [_event_source_endpoint(event), _event_target_endpoint(event)]:
		var slot_name := str(endpoint.get("slot", ""))
		if slot_name.is_empty():
			continue
		var key := "%d:%s" % [int(endpoint.get("player", actor)), slot_name]
		if key not in result:
			result.append(key)
	if event_type == "pokemon_ko":
		var ko_key := "%d:%s" % [
			int(data.get("player", actor)),
			str(data.get("slot", "active")),
		]
		if ko_key not in result:
			result.append(ko_key)
	if event_type in ["retreat", "switched", "promoted"]:
		var player := int(data.get("player", actor))
		for slot_name in ["active", table.motion_geometry._bench_slot_from_event(event)]:
			if slot_name.is_empty():
				continue
			var switch_key := "%d:%s" % [player, slot_name]
			if switch_key not in result:
				result.append(switch_key)
	return result


func _spawn_slot_state_cover(
	key: String,
	row: Dictionary,
	pokemon_state: PokemonState,
) -> CardView:
	if table.effects == null or pokemon_state == null:
		return null
	var parts := key.split(":")
	if parts.size() < 2:
		return null
	var cover := table.CARD_SCENE.instantiate() as CardView
	if cover == null:
		return null
	cover.name = "SlotStateCover_%s" % key.replace(":", "_")
	cover.set_meta("battle_transient_visual", true)
	cover.set_meta("battle_transient_kind", "SlotStateCover")
	cover.set_meta("presentation_slot_key", key)
	cover.z_index = 94
	table.effects.add_child(cover)
	cover.set_catalog(table.catalog)
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover.focus_mode = Control.FOCUS_NONE
	cover.configure(
		pokemon_state.card_id,
		pokemon_state,
		bool(row.get("hidden", false)),
		-1,
		int(parts[0]),
		str(parts[1]),
		false,
	)
	var size_value := table.motion_geometry._vector_or_default(row.get("size"), table.active_card_size)
	cover.custom_minimum_size = size_value
	cover.size = size_value
	cover.position = table.motion_geometry._vector_or_default(row.get("center"), Vector2.ZERO) - size_value * 0.5
	cover.rotation_degrees = float(row.get("rotation_degrees", 0.0))
	cover.set_table_depth(table.motion_geometry._motion_depth_for_point(cover.position + size_value * 0.5), true)
	cover.remember_base_position()
	return cover


func _on_presentation_event_started(event: Dictionary) -> void:
	active_event_id = str(event.get("event_id", ""))
	# Attachment covers are mutable across a serialized batch (attach, switch,
	# discard and transfer can all target the same physical stack). Create their
	# source visual at takeoff, before this event mutates the cover, so it peels
	# from the badge that is actually visible now rather than the batch snapshot.
	table.hand_presentation._activate_attachment_source_proxies(event)
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	var data: Dictionary = event.get("data", {})
	var keys := _slot_visual_keys_for_event(event)
	if event_type == "card_moved":
		for key in keys:
			# Once a deferred KO has been declared, unrelated trigger movement
			# must not remove its old rendered stack. Only the explicit serialized
			# KO leave-play event is allowed to do that.
			if (
				not deferred_ko_slots.has(key)
				or bool(data.get("ko_leave_play", false))
			):
				_release_slot_state_cover(key)
				deferred_ko_slots.erase(key)
		return
	if event_type in ["promoted", "retreat", "switched"]:
		for key in keys:
			if event_type in ["retreat", "switched"]:
				_apply_event_to_slot_cover(key, event, "takeoff")
			# Slot movement claims the staged CardView itself.  Keeping this cover
			# alive until the motion request means HP, status, energy and tool
			# overlays travel as one physical stack instead of being rebuilt as
			# unrelated paper-card flyers.
			deferred_ko_slots.erase(key)
		return
	# KO feedback must land on the old stack. Deferred KO declarations also keep
	# that stack alive for intervening triggers such as Exp. Share; the later
	# ko_leave_play card_moved event owns the actual departure.
	if event_type == "pokemon_ko":
		return
	if event_type in [
		"cards_discarded",
		"confusion_failed",
		"damage_counters_placed",
		"damage_dealt",
		"energy_attached",
		"healed",
		"status_applied",
		"status_removed",
	]:
		for key in keys:
			_apply_event_to_slot_cover(key, event, "takeoff")


func _apply_event_to_slot_cover(
	key: String,
	event: Dictionary,
	phase: String = "complete",
) -> void:
	var state := slot_cover_states.get(key) as PokemonState
	var cover := _valid_card_view(slot_covers.get(key))
	if state == null or cover == null:
		return
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	var data: Dictionary = event.get("data", {})
	if event_type in [
		"confusion_failed",
		"damage_counters_placed",
		"damage_dealt",
		"healed",
		"status_applied",
		"status_removed",
	]:
		# Feedback mutations belong exclusively to the target stack. The event's
		# source is retained for camera/attack context, but must never receive the
		# target's damage counters or status in the staged presentation state.
		var target := _event_target_endpoint(event)
		var target_key := "%d:%s" % [
			int(target.get("player", -1)),
			str(target.get("slot", "")),
		]
		if key != target_key:
			return
	var amount := maxi(0, int(event.get("amount", data.get("amount", 0))))
	match event_type:
		"damage_dealt", "damage_counters_placed", "confusion_failed":
			var counters := int(data.get("counter_count", 0))
			if counters <= 0 and amount > 0:
				counters = ceili(float(amount) / 10.0)
			state.damage_counters += maxi(0, counters)
		"healed":
			state.damage_counters = maxi(
				0,
				state.damage_counters - ceili(float(amount) / 10.0),
			)
		"status_applied":
			var status := str(data.get("status", event.get("status", "")))
			if not status.is_empty() and status not in state.status_conditions:
				state.status_conditions.append(status)
		"status_removed":
			var removed_status := str(data.get("status", event.get("status", "")))
			state.status_conditions.erase(removed_status)
		"retreat", "switched":
			var source := _event_source_endpoint(event)
			var source_key := "%d:%s" % [
				int(source.get("player", -1)),
				str(source.get("slot", "")),
			]
			if key == source_key and str(source.get("slot", "")) == "active":
				# Leaving the Active Spot removes every Special Condition before the
				# physical stack arrives on the Bench.  Without staging this mutation,
				# status badges visibly travelled with a retreated/switched Pokémon and
				# only vanished at the final state reconciliation.
				state.status_conditions.clear()
		"cards_discarded":
			if phase != "landing":
				var source := _discard_endpoints_for_event(event).get("source", {}) as Dictionary
				match str(source.get("attachment_type", "")):
					"energy":
						_remove_event_energy_cards(state, event, source)
					"tool":
						if table.motion_geometry._event_card_ids(event).is_empty() or state.attached_tool_id in table.motion_geometry._event_card_ids(event):
							state.attached_tool_id = ""
		"energy_attached":
			var source := _event_source_endpoint(event)
			var target := _event_target_endpoint(event)
			var key_parts := key.split(":")
			var key_player := int(key_parts[0])
			var key_slot := str(key_parts[1])
			if phase != "landing" and int(source.get("player", -99)) == key_player and str(source.get("slot", "")) == key_slot:
				_remove_event_energy_cards(state, event, source)
			for card_id_value in table.motion_geometry._event_card_ids(event):
				var card_id := str(card_id_value)
				if (
					phase != "takeoff"
					and
					int(target.get("player", -99)) == key_player
					and str(target.get("slot", "")) == key_slot
				):
					# Physical energy cards are not a set. Attaching a second copy of
					# the same basic/special card must survive into the staged stack so
					# a later switch carries both badges/counts.
					state.energy_card_ids.append(card_id)
		"tool_attached":
			var card_ids := table.motion_geometry._event_card_ids(event)
			if not card_ids.is_empty():
				state.attached_tool_id = str(card_ids[0])
		"pokemon_evolved":
			if state.card_id not in state.evolution_stack_ids:
				state.evolution_stack_ids.append(state.card_id)
			state.card_id = str(event.get("card_id", data.get("card_id", state.card_id)))
			state.status_conditions.clear()
	cover.configure(
		state.card_id,
		state,
		false,
		-1,
		cover.owner_player,
		cover.slot,
		false,
	)
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover.remember_base_position()


func _remove_event_energy_cards(
	state: PokemonState,
	event: Dictionary,
	source: Dictionary,
) -> void:
	var card_ids := table.motion_geometry._event_card_ids(event)
	var data: Dictionary = event.get("data", {})
	var raw_indices: Variant = data.get("source_indices", [])
	var rows: Array[Dictionary] = []
	for index in range(card_ids.size()):
		var source_index := int(source.get("index", -1))
		if raw_indices is Array and index < Array(raw_indices).size():
			source_index = int(Array(raw_indices)[index])
		rows.append({"card_id": str(card_ids[index]), "index": source_index})
	rows.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.get("index", -1)) > int(right.get("index", -1))
	)
	for row in rows:
		var index := int(row.get("index", -1))
		var card_id := str(row.get("card_id", ""))
		if (
			index >= 0
			and index < state.energy_card_ids.size()
			and state.energy_card_ids[index] == card_id
		):
			state.energy_card_ids.remove_at(index)
		else:
			state.energy_card_ids.erase(card_id)


func _sync_slot_snapshot_from_cover(key: String) -> void:
	# `snapshot` starts as the pre-batch board, but later events
	# must launch from the visual state left by earlier events in the same batch.
	# In particular, retreat payment must not fly discarded energy a second time,
	# while an energy attached before a switch must travel with its Pokemon.
	var state := slot_cover_states.get(key) as PokemonState
	var cover := _valid_card_view(slot_covers.get(key))
	if state == null or cover == null:
		return
	var slots: Dictionary = snapshot.get("slots", {})
	var row: Dictionary = Dictionary(slots.get(key, {})).duplicate(true)
	var attachment_centers: Dictionary = {}
	for energy_index in range(state.energy_card_ids.size()):
		var energy_id := str(state.energy_card_ids[energy_index])
		var energy_center := table._effects_local(cover.attachment_anchor_global(
			"energy",
			energy_id,
			energy_index,
		))
		if not attachment_centers.has("energy"):
			attachment_centers["energy"] = energy_center
		attachment_centers["energy:%s" % energy_id] = energy_center
		attachment_centers["energy:%d" % energy_index] = energy_center
		attachment_centers[
			"energy:%d:%s" % [energy_index, energy_id]
		] = energy_center
	if not state.attached_tool_id.is_empty():
		var tool_center := table._effects_local(cover.attachment_anchor_global(
			"tool",
			state.attached_tool_id,
		))
		attachment_centers["tool"] = tool_center
		attachment_centers["tool:%s" % state.attached_tool_id] = tool_center
	row["card_id"] = state.card_id
	row["center"] = table._effects_local(cover.global_center())
	row["size"] = cover.size
	row["rotation_degrees"] = cover.rotation_degrees
	row["empty"] = false
	row["hidden"] = cover.is_hidden_card
	row["attachment_centers"] = attachment_centers
	row["pokemon"] = state.to_dict()
	slots[key] = row
	snapshot["slots"] = slots


func _finish_slot_visual_event(event: Dictionary) -> void:
	var event_id := str(event.get("event_id", ""))
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	for key in _slot_visual_keys_for_event(event):
		var planned_queue: Array = Array(
			slot_event_plans.get(key, []),
		).duplicate()
		planned_queue.erase(event_id)
		if planned_queue.is_empty():
			slot_event_plans.erase(key)
		else:
			slot_event_plans[key] = planned_queue
		if not slot_event_queues.has(key):
			continue
		if event_type in [
			"energy_attached",
			"pokemon_evolved",
			"tool_attached",
		]:
			_apply_event_to_slot_cover(key, event, "landing")
		_sync_slot_snapshot_from_cover(key)
		var queue: Array = slot_event_queues.get(key, [])
		queue.erase(event_id)
		slot_event_queues[key] = queue
		if queue.is_empty():
			_release_slot_state_cover(key)


func _release_slot_state_cover(key: String) -> void:
	var cover := _valid_card_view(slot_covers.get(key))
	slot_covers.erase(key)
	slot_cover_states.erase(key)
	slot_event_queues.erase(key)
	if cover != null:
		if bool(cover.get_meta("retained_slot_cover", false)):
			_release_retained_slot_target_mask(key)
		cover.visible = false
		cover.queue_free()


func _claim_slot_state_cover(key: String) -> CardView:
	var cover := _valid_card_view(slot_covers.get(key))
	if cover != null and bool(cover.get_meta("retained_slot_cover", false)):
		# This cover's outstanding mask is replaced by the new slot-movement
		# event's mask. Retire exactly one count without exposing a destination
		# that is still reserved by the new event.
		_release_retained_slot_target_mask(key)
	slot_covers.erase(key)
	slot_cover_states.erase(key)
	slot_event_queues.erase(key)
	deferred_ko_slots.erase(key)
	return cover


func _release_retained_slot_target_mask(key: String) -> void:
	var parts := key.split(":")
	if parts.size() < 2:
		return
	var target := table.get_slot_view(int(parts[0]), str(parts[1]))
	if target == null:
		return
	_reveal_presentation_node(target, false, 0.0)
	target.modulate.a = 1.0


func _clear_slot_visual_transactions() -> void:
	for key_value in slot_covers.keys():
		_release_slot_state_cover(str(key_value))
	slot_covers.clear()
	slot_cover_states.clear()
	slot_event_queues.clear()
	slot_event_plans.clear()
	deferred_ko_slots.clear()
	table.motion_entities._clear_effect_child_controls(["SlotStateCover"])


func _reposition_slot_state_covers() -> void:
	for key_value in slot_covers.keys():
		var key := str(key_value)
		var cover := _valid_card_view(slot_covers.get(key))
		var parts := key.split(":")
		if cover == null or parts.size() < 2:
			continue
		var slot_view := table.get_slot_view(int(parts[0]), str(parts[1]))
		if slot_view == null:
			continue
		cover.custom_minimum_size = slot_view.size
		cover.size = slot_view.size
		cover.position = table._effects_local(slot_view.global_center()) - cover.size * 0.5
		cover.rotation_degrees = slot_view.rotation_degrees
		cover.remember_base_position()


func _stage_presentation_targets(
	events: Array[Dictionary],
	previous_snapshot: Dictionary,
) -> void:
	if table.director == null or not table.director.is_playing():
		_clear_presentation_masks(true)
	snapshot = previous_snapshot.duplicate(true)
	event_hand_targets.clear()
	hand_target_cursor.clear()
	hand_removed_counts.clear()
	_stage_presentation_hud(previous_snapshot)
	table.hand_presentation._stage_hand_transition_geometry(previous_snapshot)
	table.hand_presentation._stage_snapshot_hand_sources(events, previous_snapshot)
	table.hand_presentation._stage_opponent_hand_transaction(events, previous_snapshot)
	table.hand_presentation._stage_attachment_source_proxies(events)
	_stage_presentation_zone_states(events, previous_snapshot)
	_stage_slot_visual_transactions(events, previous_snapshot)
	for event in events:
		if PresentationEvent.canonical_event_type(
			str(event.get("event_type", "")),
		) == "deck_shuffled":
			table.hand_view.invalidate_hand_visual_identities()
			break
	for event in events:
		var event_id := str(event.get("event_id", ""))
		if event_id.is_empty():
			continue
		table.hand_presentation._record_hand_removals_for_event(event)
		table.hand_presentation._precompute_hand_targets_for_event(event)
		var targets := _presentation_targets_for_event(event)
		if not targets.is_empty():
			reveals[event_id] = targets
			for target in targets:
				_mask_presentation_node(target)
		var feedback_targets := _presentation_feedback_targets_for_event(event)
		if not feedback_targets.is_empty():
			feedbacks[event_id] = feedback_targets
		_stage_presentation_cover(event)


func _stage_presentation_zone_states(
	events: Array[Dictionary],
	previous_snapshot: Dictionary,
) -> void:
	zone_states.clear()
	var zones_snapshot: Dictionary = previous_snapshot.get("zones", {})
	if zones_snapshot.is_empty():
		return
	var affected: Dictionary = {}
	for event in events:
		for endpoint in _zone_endpoints_for_event(event):
			var key := _presentation_zone_key(endpoint)
			if key.is_empty():
				continue
			affected[key] = true
	for key_value in affected.keys():
		var key := str(key_value)
		var row: Dictionary = Dictionary(zones_snapshot.get(key, {})).duplicate(true)
		if row.is_empty():
			continue
		zone_states[key] = row
		_apply_presentation_zone_state(key)


func _zone_endpoints_for_event(event: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var event_type := str(event.get("event_type", ""))
	var actor := int(event.get("actor", table.view_player))
	var data: Dictionary = event.get("data", {})
	var source := _event_source_endpoint(event)
	var target := _event_target_endpoint(event)
	match event_type:
		"cards_drawn":
			result.append(source)
		"cards_revealed":
			result.append(source)
			var reveal_player := int(source.get("player", actor))
			for row in table.motion_geometry._reveal_rows(event):
				var destination := table.motion_geometry._reveal_destination(row, reveal_player)
				if not destination.is_empty():
					result.append(destination)
		"prize_taken":
			result.append(source)
		"cards_discarded":
			var discard_endpoints := _discard_endpoints_for_event(event)
			source = discard_endpoints["source"]
			target = discard_endpoints["target"]
			result.append(target)
			if str(source.get("zone", "")) != "hand":
				result.append(source)
		"energy_attached":
			if (
				not str(source.get("zone", "")).is_empty()
				and str(source.get("zone", "")) != "hand"
			):
				result.append(source)
		"cards_selected":
			for endpoint in [source, target]:
				var zone_name := str(endpoint.get("zone", ""))
				if not zone_name.is_empty() and zone_name != "hand":
					result.append(endpoint)
		"trainer_played":
			result.append(target)
		"stadium_changed":
			result.append({"player": -1, "zone": "stadium"})
		"card_moved":
			result.append(source)
			result.append(target)
		"pokemon_ko":
			result.append({
				"player": int(data.get("player", actor)),
				"zone": "discard",
			})
		"deck_shuffled":
			result.append({
				"player": int(data.get("player", actor)),
				"zone": "deck",
			})
	return result


func _presentation_zone_key(endpoint: Dictionary) -> String:
	var zone_name := str(endpoint.get("zone", ""))
	if zone_name.is_empty() or zone_name == "hand":
		return ""
	if zone_name == "stadium":
		return "-1:stadium"
	return "%d:%s" % [int(endpoint.get("player", table.view_player)), zone_name]


func _apply_presentation_zone_state(key: String) -> void:
	var row: Dictionary = Dictionary(zone_states.get(key, {}))
	if row.is_empty():
		return
	var endpoint := _endpoint_from_presentation_zone_key(key)
	if endpoint.is_empty():
		return
	var zone := table.motion_geometry._zone_view_for_endpoint(endpoint)
	if zone == null:
		return
	var zone_name := str(endpoint.get("zone", ""))
	var player := int(endpoint.get("player", table.view_player))
	var count_value := maxi(0, int(row.get("count", zone.count)))
	var card_id_value := str(row.get("card_id", zone.card_id))
	if count_value <= 0:
		card_id_value = ""
	zone.configure(
		table._zone_title(zone_name),
		card_id_value,
		count_value,
		bool(row.get("hidden", zone.is_hidden_zone)),
		_presentation_zone_context(
			player,
			zone_name,
			card_id_value,
			count_value,
			bool(row.get("hidden", zone.is_hidden_zone)),
		),
	)


func _endpoint_from_presentation_zone_key(key: String) -> Dictionary:
	if key == "-1:stadium":
		return {"player": -1, "zone": "stadium"}
	var parts := key.split(":")
	if parts.size() != 2:
		return {}
	return {"player": int(parts[0]), "zone": str(parts[1])}


func _presentation_zone_context(
	player: int,
	zone_name: String,
	card_id_value: String,
	count_value: int,
	hidden: bool,
) -> Dictionary:
	var visible_ids: Array[String] = []
	if not hidden and not card_id_value.is_empty():
		visible_ids.append(card_id_value)
	return {
		"player": player,
		"zone": zone_name,
		"title": table._zone_title(zone_name),
		"card_ids": visible_ids,
		"count": count_value,
		"hidden": hidden,
		"card_id": card_id_value,
	}


func _apply_presentation_zone_event(event: Dictionary) -> void:
	if zone_states.is_empty():
		return
	var event_type := str(event.get("event_type", ""))
	var actor := int(event.get("actor", table.view_player))
	var data: Dictionary = event.get("data", {})
	var source := _event_source_endpoint(event)
	var target := _event_target_endpoint(event)
	match event_type:
		"cards_drawn":
			_adjust_presentation_zone(
				source,
				-table.motion_geometry._event_amount(event, table.motion_geometry._event_card_ids(event)),
				[],
			)
		"cards_revealed":
			var reveal_source := source
			var reveal_player := int(reveal_source.get("player", actor))
			for row in table.motion_geometry._reveal_rows(event):
				var destination := table.motion_geometry._reveal_destination(row, reveal_player)
				if _presentation_zone_key(destination) == _presentation_zone_key(
					reveal_source,
				):
					continue
				_adjust_presentation_zone(reveal_source, -1, [])
				_adjust_presentation_zone(
					destination,
					1,
					[str(row.get("card_id", ""))],
				)
		"prize_taken":
			_adjust_presentation_zone(
				source,
				-table.motion_geometry._event_amount(event, table.motion_geometry._event_card_ids(event)),
				[],
			)
		"cards_discarded":
			var discard_endpoints := _discard_endpoints_for_event(event)
			source = discard_endpoints["source"]
			target = discard_endpoints["target"]
			_adjust_presentation_zone(
				target,
				table.motion_geometry._event_amount(event, table.motion_geometry._event_card_ids(event)),
				table.motion_geometry._event_card_ids(event),
			)
			if str(source.get("zone", "")) != "hand":
				_adjust_presentation_zone(
					source,
					-table.motion_geometry._event_amount(event, table.motion_geometry._event_card_ids(event)),
					[],
				)
		"energy_attached":
			if (
				not str(source.get("zone", "")).is_empty()
				and str(source.get("zone", "")) != "hand"
			):
				_adjust_presentation_zone(
					source,
					-table.motion_geometry._event_amount(event, table.motion_geometry._event_card_ids(event)),
					[],
				)
		"cards_selected":
			var selected_ids := table.motion_geometry._event_card_ids(event)
			var selected_data: Dictionary = event.get("data", {})
			var selected_amount := maxi(0, int(event.get(
				"amount",
				selected_data.get("count", selected_ids.size()),
			)))
			if (
				not str(source.get("zone", "")).is_empty()
				and str(source.get("zone", "")) != "hand"
			):
				_adjust_presentation_zone(source, -selected_amount, [])
			if (
				not str(target.get("zone", "")).is_empty()
				and str(target.get("zone", "")) != "hand"
			):
				_adjust_presentation_zone(target, selected_amount, selected_ids)
		"trainer_played":
			_adjust_presentation_zone(
				target,
				1,
				table.motion_geometry._event_card_ids(event),
			)
		"stadium_changed":
			_set_presentation_zone_top(
				{"player": -1, "zone": "stadium"},
				str(event.get("card_id", data.get("card_id", ""))),
				1,
			)
		"card_moved":
			var card_ids := table.motion_geometry._event_card_ids(event)
			var amount := table.motion_geometry._event_amount(event, card_ids)
			_adjust_presentation_zone(source, -amount, [])
			_adjust_presentation_zone(target, amount, card_ids)
		"pokemon_ko":
			_adjust_presentation_zone(
				{"player": int(data.get("player", actor)), "zone": "discard"},
				table.motion_geometry._event_amount(event, table.motion_geometry._event_card_ids(event)),
				table.motion_geometry._event_card_ids(event),
			)


func _adjust_presentation_zone(
	endpoint: Dictionary,
	delta: int,
	card_ids: Array,
) -> void:
	var key := _presentation_zone_key(endpoint)
	if key.is_empty() or not zone_states.has(key):
		return
	var row: Dictionary = Dictionary(zone_states.get(key, {})).duplicate(true)
	var next_count := maxi(0, int(row.get("count", 0)) + delta)
	row["count"] = next_count
	if next_count <= 0:
		row["card_id"] = ""
	elif delta > 0:
		var top_card := _last_card_id(card_ids)
		if not top_card.is_empty():
			row["card_id"] = top_card
	elif delta < 0:
		var current_final := _current_zone_row(endpoint)
		row["card_id"] = str(current_final.get("card_id", row.get("card_id", "")))
	zone_states[key] = row
	_apply_presentation_zone_state(key)


func _set_presentation_zone_top(
	endpoint: Dictionary,
	card_id_value: String,
	count_value: int,
) -> void:
	var key := _presentation_zone_key(endpoint)
	if key.is_empty() or not zone_states.has(key):
		return
	var row: Dictionary = Dictionary(zone_states.get(key, {})).duplicate(true)
	row["count"] = maxi(0, count_value)
	row["card_id"] = "" if int(row["count"]) <= 0 else card_id_value
	zone_states[key] = row
	_apply_presentation_zone_state(key)


func _last_card_id(card_ids: Array) -> String:
	for index in range(card_ids.size() - 1, -1, -1):
		var card_id_value := str(card_ids[index])
		if not card_id_value.is_empty():
			return card_id_value
	return ""


func _current_zone_row(endpoint: Dictionary) -> Dictionary:
	var zone_name := str(endpoint.get("zone", ""))
	var player_idx := int(endpoint.get("player", table.view_player))
	if zone_name == "stadium":
		return {
			"card_id": table.state_ref.stadium_card_id if table.state_ref else "",
			"count": 0 if table.state_ref == null or table.state_ref.stadium_card_id.is_empty() else 1,
			"hidden": false,
		}
	if table.state_ref == null or player_idx < 0 or player_idx >= table.state_ref.players.size():
		return {}
	var player := table.state_ref.get_player(player_idx)
	match zone_name:
		"discard":
			return {
				"card_id": player.discard[-1] if not player.discard.is_empty() else "",
				"count": player.discard.size(),
				"hidden": false,
			}
		"deck":
			return {
				"card_id": "",
				"count": player.deck.size(),
				"hidden": true,
			}
		"prizes":
			return {
				"card_id": "",
				"count": player.prizes.size(),
				"hidden": true,
			}
	return {}


func _presentation_targets_for_event(event: Dictionary) -> Array[Control]:
	var result: Array[Control] = []
	var event_type := str(event.get("event_type", ""))
	var actor := int(event.get("actor", table.view_player))
	var source := _event_source_endpoint(event)
	var target := _event_target_endpoint(event)
	var data: Dictionary = event.get("data", {})
	match event_type:
		"cards_drawn":
			if not table.motion_geometry._is_transient_opening_draw(event):
				result.append_array(_target_controls_for_endpoint(target, event))
		"prize_taken":
			result.append_array(_target_controls_for_endpoint(target, event))
		"cards_discarded":
			var discard_endpoints := _discard_endpoints_for_event(event)
			source = discard_endpoints["source"]
			target = discard_endpoints["target"]
		"pokemon_played":
			if _should_mask_slot_result(event):
				table.motion_geometry._append_unique_control(result, table.motion_geometry._slot_view_for_endpoint(target))
		"trainer_played", "stadium_changed":
			pass
		"card_moved":
			if not str(target.get("slot", "")).is_empty() or str(target.get("zone", "")) == "hand":
				result.append_array(_target_controls_for_endpoint(target, event))
		"cards_selected":
			# Search continuations commit their authoritative target before the
			# presentation starts. Keep that real node hidden until the moving card
			# lands, exactly like draws and prize cards.
			if (
				not str(target.get("slot", "")).is_empty()
				or str(target.get("zone", "")) == "hand"
			):
				result.append_array(_target_controls_for_endpoint(target, event))
		"pokemon_ko":
			var player := int(data.get("player", actor))
			var slot_name := str(data.get("slot", "active"))
			table.motion_geometry._append_unique_control(result, table.get_slot_view(player, slot_name))
		"retreat", "switched", "promoted":
			for view in _switch_slot_views_for_event(event):
				table.motion_geometry._append_unique_control(result, view)
	return result


func _presentation_feedback_targets_for_event(event: Dictionary) -> Array[Control]:
	var result: Array[Control] = []
	var event_type := str(event.get("event_type", ""))
	if event_type in ["pokemon_evolved", "energy_attached", "tool_attached"]:
		table.motion_geometry._append_unique_control(
			result,
			table.motion_geometry._slot_view_for_endpoint(_event_target_endpoint(event)),
		)
	if event_type == "energy_attached":
		table.motion_geometry._append_unique_control(
			result,
			table.motion_geometry._slot_view_for_endpoint(_event_source_endpoint(event)),
		)
	elif event_type == "cards_discarded":
		var source := _event_source_endpoint(event)
		if not str(source.get("attachment_type", "")).is_empty():
			table.motion_geometry._append_unique_control(result, table.motion_geometry._slot_view_for_endpoint(source))
	return result


func _should_mask_slot_result(event: Dictionary) -> bool:
	var target := _event_target_endpoint(event)
	var slot_name := str(target.get("slot", ""))
	if slot_name.is_empty():
		return false
	var player := int(target.get("player", table.view_player))
	var snapshot_row := table.motion_geometry._snapshot_slot_row(player, slot_name)
	return snapshot_row.is_empty() or bool(snapshot_row.get("empty", true))


func _event_target_endpoint(event: Dictionary) -> Dictionary:
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", table.view_player)))
	var target := Dictionary(event.get("target", {})).duplicate(true)
	if str(target.get("slot", "")).is_empty():
		var slot_name := str(data.get("target_slot", ""))
		if slot_name.is_empty() and str(target.get("zone", "")).is_empty():
			slot_name = str(data.get("slot", ""))
		if not slot_name.is_empty():
			target["slot"] = slot_name
	if str(target.get("zone", "")).is_empty():
		var zone_name := str(data.get("target_zone", ""))
		if not zone_name.is_empty():
			target["zone"] = zone_name
	if not target.has("player"):
		target["player"] = int(data.get("target_player", data.get("player", actor)))
	var inferred_attachment_type := str({
		"energy_attached": "energy",
		"tool_attached": "tool",
	}.get(str(event.get("event_type", "")), ""))
	if (
		not inferred_attachment_type.is_empty()
		and not str(target.get("slot", "")).is_empty()
		and str(target.get("attachment_type", "")).is_empty()
	):
		target["attachment_type"] = inferred_attachment_type
	return target


func _event_source_endpoint(event: Dictionary) -> Dictionary:
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", table.view_player)))
	var source := Dictionary(event.get("source", {})).duplicate(true)
	if (
		str(source.get("slot", "")).is_empty()
		and str(source.get("zone", "")).is_empty()
	):
		var slot_name := str(data.get("source_slot", ""))
		if not slot_name.is_empty():
			source["slot"] = slot_name
	if str(source.get("zone", "")).is_empty():
		var zone_name := str(data.get("source_zone", ""))
		if not zone_name.is_empty():
			source["zone"] = zone_name
	if not source.has("player"):
		source["player"] = int(data.get("source_player", data.get("player", actor)))
	if not source.has("index") and data.has("source_index"):
		source["index"] = int(data.get("source_index", -1))
	if (
		str(event.get("event_type", "")) == "energy_attached"
		and not str(source.get("slot", "")).is_empty()
	):
		# PresentationEvent's compatibility default for a normal attach source is
		# `hand`. A slot-bearing source is already a complete location and denotes
		# an attachment transfer, so that fallback must not win over the slot or
		# stage an unrelated hand-card proxy.
		source["zone"] = ""
		if str(source.get("attachment_type", "")).is_empty():
			source["attachment_type"] = "energy"
	return source


func _discard_endpoints_for_event(event: Dictionary) -> Dictionary:
	var actor := int(event.get("actor", table.view_player))
	var source := _event_source_endpoint(event)
	var target := _event_target_endpoint(event)
	# Legacy hand-discard events sometimes omitted the source completely. A slot
	# is already a complete location, however; treating `zone == ""` alone as an
	# unknown source erased attachment player/slot/index data (Crushing Hammer,
	# retreat costs and attack energy costs all use slot-only endpoints).
	if (
		str(source.get("zone", "")).is_empty()
		and str(source.get("slot", "")).is_empty()
	):
		source["zone"] = "hand"
		if int(source.get("player", -1)) < 0:
			source["player"] = actor
	if (
		str(target.get("zone", "")).is_empty()
		and str(target.get("slot", "")).is_empty()
	):
		target["zone"] = "discard"
	# Discard ownership follows the moved card, not the player who caused the
	# effect. This matters whenever actor != source.player, such as Crushing
	# Hammer removing an opponent's attachment.
	if str(target.get("zone", "")) == "discard":
		target["player"] = int(source.get("player", actor))
	return {"source": source, "target": target}


func _target_controls_for_endpoint(
	endpoint: Dictionary,
	event: Dictionary,
) -> Array[Control]:
	var result: Array[Control] = []
	var zone := str(endpoint.get("zone", ""))
	var player := int(endpoint.get("player", table.view_player))
	if not str(endpoint.get("slot", "")).is_empty():
		table.motion_geometry._append_unique_control(result, table.motion_geometry._slot_view_for_endpoint(endpoint))
	elif zone == "hand":
		if player == table.view_player:
			result.append_array(table.hand_presentation._hand_target_views_for_incoming(event))
		else:
			result.append_array(table.hand_presentation._opponent_hand_target_views_for_incoming(event))
	else:
		table.motion_geometry._append_unique_control(result, table.motion_geometry._zone_view_for_endpoint(endpoint))
	return result


func _switch_slot_views_for_event(event: Dictionary) -> Array[Control]:
	var result: Array[Control] = []
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", table.view_player)))
	var player := int(data.get("player", actor))
	var event_type := str(event.get("event_type", ""))
	var bench_slot := table.motion_geometry._bench_slot_from_event(event)
	if event_type == "promoted":
		table.motion_geometry._append_unique_control(result, table.get_slot_view(player, "active"))
		if not bench_slot.is_empty():
			table.motion_geometry._append_unique_control(result, table.get_slot_view(player, bench_slot))
	else:
		table.motion_geometry._append_unique_control(result, table.get_slot_view(player, "active"))
		if not bench_slot.is_empty():
			table.motion_geometry._append_unique_control(result, table.get_slot_view(player, bench_slot))
	return result


func _mask_presentation_node(node: Control) -> void:
	if node == null or not is_instance_valid(node):
		return
	var instance_id := node.get_instance_id()
	mask_counts[instance_id] = (
		int(mask_counts.get(instance_id, 0)) + 1
	)
	if node is CardView:
		(node as CardView).set_presentation_hidden(true)
	elif node is ZoneView:
		(node as ZoneView).set_presentation_hidden(true)
	else:
		node.modulate.a = 0.0


func _reveal_presentation_node(
	node: Control,
	force: bool = false,
	reveal_duration: float = 0.14,
) -> MotionHandle:
	var handle := MotionHandle.new()
	if node == null or not is_instance_valid(node):
		handle.cancel()
		return handle
	var instance_id := node.get_instance_id()
	if not force:
		var count := int(mask_counts.get(instance_id, 0)) - 1
		if count > 0:
			mask_counts[instance_id] = count
			handle.finish()
			return handle
	mask_counts.erase(instance_id)
	if node is CardView:
		handle = (node as CardView).reveal_presentation(reveal_duration)
		(node as CardView).flash(DesignTokens.GOLD, 0.22)
	elif node is ZoneView:
		(node as ZoneView).reveal_presentation(reveal_duration)
		handle.finish()
	else:
		node.modulate.a = 1.0
		handle.finish()
	return handle


func _stage_presentation_cover(event: Dictionary) -> void:
	var event_type := str(event.get("event_type", ""))
	if event_type not in ["pokemon_evolved", "energy_attached", "tool_attached"]:
		return
	var event_id := str(event.get("event_id", ""))
	if event_id.is_empty() or table.effects == null:
		return
	var target := _event_target_endpoint(event)
	var slot_name := str(target.get("slot", ""))
	if slot_name.is_empty():
		return
	var player := int(target.get("player", table.view_player))
	var slot_key := "%d:%s" % [player, slot_name]
	if slot_covers.has(slot_key):
		var slot_cover := _valid_card_view(slot_covers.get(slot_key))
		if slot_cover != null:
			covers[event_id] = [slot_cover]
		return
	var view := table.get_slot_view(player, slot_name)
	if view == null or not is_instance_valid(view) or not view.visible:
		return
	var snapshot_row := table.motion_geometry._snapshot_slot_row(player, slot_name)
	if snapshot_row.is_empty() or bool(snapshot_row.get("empty", false)):
		return
	var old_card_id := str(snapshot_row.get("card_id", ""))
	if old_card_id.is_empty() or bool(snapshot_row.get("hidden", false)):
		return
	var cover := _spawn_presentation_cover(old_card_id, view)
	if cover == null:
		return
	var event_covers: Array[Control] = []
	if covers.has(event_id):
		for value in covers[event_id]:
			var existing := _valid_control(value)
			if existing:
				event_covers.append(existing)
	event_covers.append(cover)
	covers[event_id] = event_covers


func _spawn_presentation_cover(card_id_value: String, target_view: CardView) -> Control:
	var texture := table.card_motion_layer._texture_for_card_id(card_id_value)
	if texture == null:
		texture = table.card_motion_layer._texture_for_card_id("")
	if texture == null or table.effects == null:
		return null
	var cover := table.motion_entities._create_paper_card_token(
		texture,
		target_view.size,
		"PresentationCover",
		96,
		0.68,
	)
	cover.size = target_view.size
	cover.position = table._effects_local(target_view.global_center()) - cover.size * 0.5
	cover.pivot_offset = cover.size * 0.5
	table.effects.add_child(cover)
	return cover


func _finish_presentation_covers(event_id: String) -> bool:
	var covers: Array = covers.get(event_id, [])
	covers.erase(event_id)
	if covers.is_empty():
		return false
	var had_cover := false
	for cover_value in covers:
		var cover := _valid_control(cover_value)
		if cover == null:
			continue
		had_cover = true
		if cover in slot_covers.values():
			continue
		_dispose_presentation_cover(cover)
	return had_cover


func _dispose_presentation_cover(cover: Control) -> void:
	if cover == null or not is_instance_valid(cover):
		return
	cover_tweens.erase(cover.get_instance_id())
	cover.visible = false
	cover.modulate.a = 0.0
	cover.queue_free()


func _clear_presentation_covers() -> void:
	for tween_value in cover_tweens.values():
		var tween := tween_value as Tween
		if tween and tween.is_valid():
			tween.kill()
	cover_tweens.clear()
	for covers in covers.values():
		for cover_value in covers:
			var cover := _valid_control(cover_value)
			_dispose_presentation_cover(cover)
	covers.clear()
	table.motion_entities._clear_effect_child_controls(["PresentationCover"])


func _flash_presentation_feedbacks(event_id: String) -> void:
	# Landing/reveal owns the visible flash while its motion barrier is active.
	# Keeping a second flash here starts it after the event barrier has already
	# completed and sequence cleanup truncates it in the same call stack.
	feedbacks.erase(event_id)


func _on_presentation_event_finished(event: Dictionary) -> void:
	var event_id := str(event.get("event_id", ""))
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	_apply_presentation_zone_event(event)
	var nodes: Array = reveals.get(event_id, [])
	for node_value in nodes:
		_reveal_presentation_node(_valid_control(node_value))
	reveals.erase(event_id)
	_finish_slot_visual_event(event)
	table.hand_presentation._finish_opponent_hand_event(event)
	_finish_presentation_covers(event_id)
	if event_type == "cards_revealed" and table.reveal_layer != null:
		table.reveal_layer.clear()
	if event_type == "coin_flip" and table.coin_showcase != null:
		table.coin_showcase.clear()
	table.motion_entities._clear_active_flyers_for_event(event_id)
	_flash_presentation_feedbacks(event_id)
	_apply_event_to_presentation_hud(event)
	active_event_id = ""


func _clear_presentation_masks(reveal: bool) -> void:
	table.hand_presentation._presentation_hand_stage_generation += 1
	table.hand_presentation._clear_hand_layout_tweens()
	table.hand_presentation._clear_snapshot_hand_sources()
	table.hand_presentation._clear_opponent_hand_transaction(false)
	table.hand_presentation._clear_attachment_source_proxies()
	table.hand_presentation._presentation_hand_geometry_staged = false
	table.hand_presentation._presentation_hand_old_count = 0
	table.hand_presentation._presentation_hand_final_count = 0
	table.hand_presentation._presentation_hand_stage_count = 0
	if reveal:
		_clear_all_presentation_nodes()
	reveals.clear()
	mask_counts.clear()
	_clear_presentation_covers()
	_clear_slot_visual_transactions()
	feedbacks.clear()
	landing_feedbacks.clear()
	event_hand_targets.clear()
	hand_target_cursor.clear()
	hand_removed_counts.clear()
	zone_states.clear()
	hud_state = null
	actions_suppressed = false
	active_event_id = ""
	if table.state_ref != null:
		table.board_view._refresh_field()
		table.board_view._refresh_header()
		table.board_view._refresh_log()
		table.board_view._refresh_actions()
		table.board_view._refresh_target_hints()
		table.hand_view._layout_hand(table.hand_view._current_hand_card_size())


func _clear_all_presentation_nodes() -> void:
	var seen: Dictionary = {}
	for view in table.hand_views:
		_clear_presentation_control(view, seen)
	for view in table.opponent_hand_views:
		_clear_presentation_control(view, seen)
	for view_value in table.slot_views.values():
		_clear_presentation_control(_valid_control(view_value), seen)
	for zone_value in table.zones.values():
		_clear_presentation_control(_valid_control(zone_value), seen)


func _clear_presentation_control(node: Control, seen: Dictionary) -> void:
	if node == null or not is_instance_valid(node):
		return
	var instance_id := node.get_instance_id()
	if seen.has(instance_id):
		return
	seen[instance_id] = true
	if node is CardView:
		(node as CardView).clear_presentation_state()
	elif node is ZoneView:
		(node as ZoneView).clear_presentation_state()
	else:
		node.modulate.a = 1.0


func _valid_control(value: Variant) -> Control:
	if not is_instance_valid(value):
		return null
	return value as Control


func _valid_card_view(value: Variant) -> CardView:
	if not is_instance_valid(value):
		return null
	return value as CardView
