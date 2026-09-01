class_name BattleCardMotionLayer
extends Node

var table: BattleTable
var geometry: BattleMotionGeometry
var motion_entities: BattleMotionEntities
var root: Control
var entities: Array[Control] = []
var tweens: Dictionary = {}
var batches: Dictionary = {}
var event_motion_completions: Dictionary = {}
var batch_sequence := 0
var neutral_public_texture: Texture2D


func configure(p_table: BattleTable, p_root: Control) -> void:
	table = p_table
	root = p_root
	geometry = table.motion_geometry
	motion_entities = table.motion_entities


func add(entity: Control) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	if entity.get_parent() == null and root != null:
		root.add_child(entity)
	if entity not in entities:
		entities.append(entity)


func bind_tween(entity: Control, tween: Tween) -> void:
	if entity == null or not is_instance_valid(entity) or tween == null:
		return
	tweens[entity.get_instance_id()] = tween


func forget(entity: Control) -> void:
	if entity == null:
		return
	entities.erase(entity)
	if is_instance_valid(entity):
		tweens.erase(entity.get_instance_id())


func prune() -> void:
	var live: Array[Control] = []
	for entity in entities:
		if is_instance_valid(entity) and not entity.is_queued_for_deletion():
			live.append(entity)
	entities.assign(live)


func active_motion_count() -> int:
	prune()
	return entities.size()


func _motion_landing_control(
	target: Dictionary,
	event: Dictionary,
	index: int,
	staged_hand_nodes: Array,
) -> Control:
	if index < staged_hand_nodes.size():
		var staged := table.presentation_runtime._valid_control(staged_hand_nodes[index])
		if staged != null:
			return staged
	# Authoritative slot CardViews already contain the final state of the whole
	# batch. An attachment that precedes a switch must land on the currently
	# staged Pokemon stack, otherwise contact both targets the wrong identity and
	# consumes the later switch's mask.
	if not str(target.get("attachment_type", "")).is_empty():
		var slot_name := str(target.get("slot", ""))
		if not slot_name.is_empty():
			var staged_key := "%d:%s" % [
				int(target.get("player", table.view_player)),
				slot_name,
			]
			var staged_slot := table.presentation_runtime._valid_card_view(
				table.presentation_runtime.slot_covers.get(staged_key),
			)
			if staged_slot != null:
				return staged_slot
	var slot_view := geometry._slot_view_for_endpoint(target)
	if slot_view != null:
		return slot_view
	var zone_name := str(target.get("zone", ""))
	var target_player := int(target.get("player", table.view_player))
	if zone_name == "hand":
		var hand_targets: Array = (
			table.hand_presentation._hand_target_views_for_incoming(event)
			if target_player == table.view_player
			else table.hand_presentation._opponent_hand_target_views_for_incoming(event)
		)
		if index < hand_targets.size():
			return table.presentation_runtime._valid_control(hand_targets[index])
	return geometry._zone_view_for_endpoint(target)


func _motion_card_id_from_control(control: Control) -> String:
	if control == null or not is_instance_valid(control):
		return ""
	for metadata_key in ["motion_card_id", "snapshot_card_id"]:
		var metadata_id := str(control.get_meta(metadata_key, ""))
		if not metadata_id.is_empty():
			return metadata_id
	var card_view := control as CardView
	if (
		card_view != null
		and not card_view.is_hidden_card
		and not card_view.card_id.is_empty()
	):
		return card_view.card_id
	return ""


func _infer_visible_motion_card_id(
	source: Dictionary,
	target: Dictionary,
	existing_flyer: Control,
	landing_view: Control,
) -> String:
	# Rules events are authoritative, but a viewer-visible source/landing node is
	# a safe final defence against compatibility or replay events that omit the
	# identity. Never infer through a hidden endpoint.
	if not geometry._endpoint_hidden_from_view(source):
		var source_id := _motion_card_id_from_control(existing_flyer)
		if not source_id.is_empty():
			return source_id
		var source_slot := str(source.get("slot", ""))
		if not source_slot.is_empty():
			var snapshot_row := geometry._snapshot_slot_row(
				int(source.get("player", table.view_player)),
				source_slot,
			)
			if not bool(snapshot_row.get("hidden", false)):
				source_id = str(snapshot_row.get("card_id", ""))
				if not source_id.is_empty():
					return source_id
	if not geometry._endpoint_hidden_from_view(target):
		var target_id := _motion_card_id_from_control(landing_view)
		if not target_id.is_empty():
			return target_id
		var target_slot := str(target.get("slot", ""))
		if not target_slot.is_empty():
			var target_view := table.get_slot_view(
				int(target.get("player", table.view_player)),
				target_slot,
			)
			if (
				target_view != null
				and not target_view.is_hidden_card
				and not target_view.card_id.is_empty()
			):
				return target_view.card_id
	return ""


func _set_paper_card_texture(flying: Control, texture: Texture2D) -> void:
	if flying == null or texture == null or not is_instance_valid(flying):
		return
	var image := flying.get_node_or_null("PaperImage") as TextureRect
	if image == null:
		return
	image.texture = texture
	image.visible = true
	image.modulate.a = 1.0


func _landing_attachment_index_for_event(
	target: Dictionary,
	landing_view: Control,
	card_id: String,
	ordinal: int,
	visible_count: int,
) -> int:
	var attachment_type := str(target.get("attachment_type", ""))
	if attachment_type != "energy":
		return table._endpoint_attachment_index(target, -1)
	var inferred := maxi(0, ordinal)
	var card_view := landing_view as CardView
	if card_view != null and card_view.pokemon != null:
		var energy_ids := card_view.pokemon.energy_card_ids
		if (
			card_view in table.presentation_runtime.slot_covers.values()
			and table._endpoint_attachment_index(target, -1) < 0
		):
			# The staged cover still represents the pre-contact state.  Predict the
			# append index; CardView will resolve the corresponding prospective badge
			# without exposing that badge before the flyer arrives.
			return energy_ids.size() + ordinal
		# Energy attachment/transfer commands append their physical cards to the
		# destination list. Infer from that appended tail when the event endpoint
		# has no explicit index; this avoids ordinal zero snapping a new Fire badge
		# onto an existing Water badge.
		var appended_start := maxi(0, energy_ids.size() - maxi(1, visible_count))
		var candidate := mini(energy_ids.size() - 1, appended_start + ordinal)
		if (
			candidate >= 0
			and (
				card_id.is_empty()
				or str(energy_ids[candidate]) == card_id
			)
		):
			inferred = candidate
		elif not card_id.is_empty():
			# Compatibility events can describe a non-appending target. Prefer the
			# last matching physical copy, which is the newly attached copy for the
			# normal append path.
			for index in range(energy_ids.size() - 1, -1, -1):
				if str(energy_ids[index]) == card_id:
					inferred = index
					break
	return table._endpoint_attachment_index(target, inferred)


func _motion_entity_finish(flying: Control, fallback: Vector2) -> Vector2:
	if flying == null or not flying.has_meta("motion_landing_view"):
		return fallback
	var landing_view := table.presentation_runtime._valid_control(flying.get_meta("motion_landing_view"))
	if landing_view == null:
		return fallback
	var attachment_type := str(flying.get_meta(
		"motion_landing_attachment_type",
		"",
	))
	if landing_view is CardView and not attachment_type.is_empty():
		return table._effects_local(
			(landing_view as CardView).prospective_attachment_visual_global_rect(
				attachment_type,
				str(flying.get_meta("motion_landing_attachment_card_id", "")),
				int(flying.get_meta("motion_landing_attachment_index", -1)),
			).get_center()
		)
	if landing_view is CardView:
		return table._effects_local((landing_view as CardView).global_center())
	return table._effects_local(landing_view.get_global_rect().get_center())


func _on_card_motion_requested(event: Dictionary, duration: float) -> void:
	var data: Dictionary = event.get("data", {})
	var motion_event_id := str(event.get("event_id", ""))
	var source := table.presentation_runtime._event_source_endpoint(event)
	var target := table.presentation_runtime._event_target_endpoint(event)
	var event_type := str(event.get("event_type", ""))
	var actor := int(event.get("actor", table.view_player))
	if event_type == "pokemon_ko":
		if bool(data.get("defer_leave_play", false)):
			_finish_event_motion_dispatch(motion_event_id)
			return
		for key in table.presentation_runtime._slot_visual_keys_for_event(event):
			table.presentation_runtime._release_slot_state_cover(key)
	if event_type == "coin_flip":
		_spawn_coin_motion(event, motion_event_id, actor)
		_finish_event_motion_dispatch(motion_event_id)
		return
	var card_ids: Array = data.get(
		"card_ids",
		data.get("cards", data.get("selected_card_ids", [])),
	)
	var event_card_id := str(event.get("card_id", data.get("card_id", "")))
	if card_ids.is_empty() and not event_card_id.is_empty():
		card_ids = [event_card_id]
	var has_explicit_card_count := event.has("amount") or data.has("count")
	var declared_card_count := int(event.get(
		"amount",
		data.get("count", card_ids.size()),
	))
	if (
		has_explicit_card_count
		and declared_card_count <= 0
		and card_ids.is_empty()
		and event_card_id.is_empty()
		and event_type not in table.ZERO_CARD_SEMANTIC_MOTION_TYPES
	):
		# Zero-result searches/shuffles are semantic events, not physical cards.
		# Creating the old forced single proxy here produced a blank phantom flyer.
		_finish_event_motion_dispatch(motion_event_id)
		return
	if (
		event_type == "cards_selected"
		and str(event.get("visibility", PresentationEvent.PUBLIC))
			== PresentationEvent.PUBLIC
		and not card_ids.is_empty()
	):
		_spawn_reveal_motion(event, duration, motion_event_id)
		_finish_event_motion_dispatch(motion_event_id)
		return
	var amount := maxi(1, int(event.get(
		"amount",
		data.get("count", card_ids.size()),
	)))
	# The quality limit is a concurrency budget, not a semantic-card limit. Every
	# moved card receives a motion entity; oversized batches are fed through a
	# rolling queue below so low quality never drops the ninth card (and high
	# quality never drops the thirteenth).
	var motion_count := maxi(amount, card_ids.size())
	if event_type == "cards_drawn":
		var draw_player := int(data.get(
			"player",
			target.get("player", source.get("player", actor)),
		))
		if str(source.get("zone", "")).is_empty():
			source = {"player": draw_player, "zone": "deck"}
		if str(target.get("zone", "")).is_empty():
			target = {"player": draw_player, "zone": "hand"}
	elif event_type == "cards_discarded":
		var discard_endpoints := table.presentation_runtime._discard_endpoints_for_event(event)
		source = discard_endpoints["source"]
		target = discard_endpoints["target"]
	elif event_type == "prize_taken":
		var prize_player := int(data.get(
			"player",
			target.get("player", source.get("player", actor)),
		))
		if str(source.get("zone", "")).is_empty():
			source = {"player": prize_player, "zone": "prizes"}
		if str(target.get("zone", "")).is_empty():
			target = {"player": prize_player, "zone": "hand"}
	elif event_type == "pokemon_ko":
		source = {
			"player": int(data.get("player", actor)),
			"slot": str(data.get("slot", "active")),
		}
		target = {
			"player": int(data.get("player", actor)),
			"zone": "discard",
		}
	elif event_type == "deck_shuffled":
		source = {
			"player": int(data.get("player", actor)),
			"zone": "deck",
		}
		target = source.duplicate(true)
	elif event_type == "cards_revealed":
		if str(source.get("zone", "")).is_empty():
			source = {
				"player": int(data.get("player", actor)),
				"zone": "deck",
			}
		target = source.duplicate(true)
		_spawn_reveal_motion(event, duration, motion_event_id)
		_finish_event_motion_dispatch(motion_event_id)
		return
	var staged_source_proxies: Array[Control] = []
	if (
		str(source.get("zone", "")) == "hand"
		and int(source.get("player", actor)) == table.view_player
	):
		staged_source_proxies = table.hand_presentation._claim_snapshot_hand_sources(event)
	elif (
		str(source.get("zone", "")) == "hand"
		and int(source.get("player", actor)) == 1 - table.view_player
	):
		staged_source_proxies = table.hand_presentation._claim_opponent_hand_sources(event)
	var staged_attachment_proxies := table.hand_presentation._claim_attachment_source_proxies(event)
	table.hand_presentation._schedule_hand_transition_for_event(event.merged({
		"source": source,
		"target": target,
	}, true), duration)
	if table._settings_reduced_motion():
		for proxy in staged_source_proxies:
			table.hand_presentation._dispose_snapshot_hand_source(proxy)
		for proxy in staged_attachment_proxies:
			motion_entities._dispose_flyer(proxy)
		if event_type in ["promoted", "retreat", "switched"]:
			# Reuse the slot transaction path with a zero duration. It performs an
			# immediate visual handoff while still remapping any later same-batch
			# mutations to the Pokemon that just entered each destination slot.
			_spawn_slot_transition(event, 0.0, motion_event_id)
		var reduced_feedback: Dictionary = table.presentation_runtime.landing_feedbacks.get(
			motion_event_id,
			{},
		)
		table.presentation_runtime.landing_feedbacks.erase(motion_event_id)
		table.presentation_runtime._burst_world_at_motion_point(
			table.resolve_endpoint_center(target),
			reduced_feedback.get(
				"color",
				_motion_landing_color(event_type),
			) as Color,
			str(reduced_feedback.get("kind", "card_move")),
		)
		_finish_event_motion_dispatch(motion_event_id)
		return
	if event_type == "deck_shuffled":
		_spawn_shuffle_motion(source, duration, motion_event_id)
		_finish_event_motion_dispatch(motion_event_id)
		return
	if _spawn_slot_transition(event, duration, motion_event_id):
		_finish_event_motion_dispatch(motion_event_id)
		return
	var base_start := table.resolve_endpoint_center(source)
	var base_finish := table.resolve_endpoint_center(target)
	var base_size := geometry._flying_card_size(event_type)
	var starts := geometry._source_points_for_event(
		source,
		card_ids,
		motion_count,
		base_start,
		event,
	)
	var finishes := geometry._target_points_for_event(
		target,
		card_ids,
		motion_count,
		base_finish,
		event,
	)
	var start_sizes := geometry._source_sizes_for_event(
		source,
		card_ids,
		motion_count,
		base_size,
	)
	var finish_sizes := geometry._target_sizes_for_event(
		target,
		motion_count,
		base_size,
		event,
	)
	var start_rotations := geometry._source_rotations_for_event(
		source,
		card_ids,
		motion_count,
		0.0,
	)
	var finish_rotations := geometry._target_rotations_for_event(
		target,
		motion_count,
		0.0,
		event,
	)
	var landing_nodes: Array = table.presentation_runtime.event_hand_targets.get(
		str(event.get("event_id", "")),
		[],
	)
	var motion_specs: Array[Dictionary] = []
	for index in range(motion_count):
		var existing_flyer: Control
		if index < staged_source_proxies.size():
			existing_flyer = staged_source_proxies[index]
		elif index < staged_attachment_proxies.size():
			existing_flyer = staged_attachment_proxies[index]
		if index == 0 and str(source.get("zone", "")) == "hand":
			if table._presentation_drag_proxy != null:
				table.hand_presentation._dispose_snapshot_hand_source(existing_flyer)
				existing_flyer = table._presentation_drag_proxy
		var card_id := str(card_ids[index]) if index < card_ids.size() else event_card_id
		var landing_view := _motion_landing_control(
			target,
			event,
			index,
			landing_nodes,
		)
		if card_id.is_empty():
			card_id = _infer_visible_motion_card_id(
				source,
				target,
				existing_flyer,
				landing_view,
			)
		var source_hidden := geometry._endpoint_hidden_from_view(source)
		var target_hidden := geometry._endpoint_hidden_from_view(target)
		var texture := (
			_texture_for_card_id("")
			if source_hidden
			else _public_motion_texture_for_card_id(card_id)
		)
		var flip_texture: Texture2D
		if source_hidden != target_hidden and not card_id.is_empty():
			flip_texture = (
				_texture_for_card_id("")
				if target_hidden
				else _public_motion_texture_for_card_id(card_id)
			)
		var target_attachment_type := str(target.get("attachment_type", ""))
		var source_is_badge_proxy := (
			existing_flyer != null
			and bool(existing_flyer.get_meta("attachment_badge_proxy", false))
		)
		if source_is_badge_proxy and target_attachment_type.is_empty():
			flip_texture = (
				_texture_for_card_id("")
				if target_hidden
				else _public_motion_texture_for_card_id(card_id)
			)
		elif not source_is_badge_proxy and not target_attachment_type.is_empty():
			var target_descriptor := AttachmentVisualDescriptor.resolve(
				target_attachment_type,
				card_id,
				index,
				table.catalog,
			)
			flip_texture = (
				target_descriptor.icon
				if target_descriptor.icon != null
				else _neutral_public_card_texture()
			)
		if texture == null:
			table.hand_presentation._dispose_snapshot_hand_source(existing_flyer)
			continue
		var start := starts[index] if index < starts.size() else base_start
		var finish := finishes[index] if index < finishes.size() else base_finish
		var timing := geometry._flying_card_timing(index, motion_count, duration)
		if not bool(timing.get("spawn", false)):
			table.hand_presentation._dispose_snapshot_hand_source(existing_flyer)
			_landing_burst(finish, event_type)
			continue
		var landing_attachment_type := str(target.get("attachment_type", ""))
		var landing_attachment_index := _landing_attachment_index_for_event(
			target,
			landing_view,
			card_id,
			index,
			motion_count,
		)
		motion_specs.append({
			"texture": texture,
			"card_id": card_id,
			"texture_authoritative": (
				source_hidden
				or (
					not card_id.is_empty()
					and not source_is_badge_proxy
				)
			),
			"start": start,
			"finish": finish,
			"duration": float(timing.get("duration", 0.0)),
			"delay": float(timing.get("delay", 0.0)),
			"event_type": event_type,
			"ordinal": index,
			"start_size": (
				start_sizes[index] if index < start_sizes.size() else base_size
			),
			"finish_size": (
				finish_sizes[index] if index < finish_sizes.size() else base_size
			),
			"start_rotation": (
				start_rotations[index] if index < start_rotations.size() else 0.0
			),
			"finish_rotation": (
				finish_rotations[index] if index < finish_rotations.size() else 0.0
			),
			"landing_view": landing_view,
			"existing_flyer": existing_flyer,
			"landing_attachment_type": landing_attachment_type,
			"landing_attachment_card_id": (
				card_id if not landing_attachment_type.is_empty() else ""
			),
			"landing_attachment_index": landing_attachment_index,
			"flip_texture": flip_texture,
			"stage_opponent_hand_landing": (
				str(target.get("zone", "")) == "hand"
				and int(target.get("player", actor)) == 1 - table.view_player
				and not table.hand_presentation._presentation_opponent_hand_event_ids.is_empty()
			),
			"opponent_hand_stage_count_delta": (
				0
				if (
					str(source.get("zone", "")) == "hand"
					and int(source.get("player", actor)) == 1 - table.view_player
				)
				else 1
			),
		})
		if index == 0 and str(source.get("zone", "")) == "hand":
			table._presentation_drag_proxy = null
	for index in range(motion_count, staged_source_proxies.size()):
		table.hand_presentation._dispose_snapshot_hand_source(staged_source_proxies[index])
	for index in range(motion_count, staged_attachment_proxies.size()):
		motion_entities._dispose_flyer(staged_attachment_proxies[index])
	_spawn_card_motion_batch(motion_specs, motion_event_id)
	_finish_event_motion_dispatch(motion_event_id)


func _spawn_card_motion_batch(
	specs: Array[Dictionary],
	event_id: String,
) -> void:
	if specs.is_empty():
		return
	var concurrency_limit := maxi(1, _max_active_flyers())
	if specs.size() <= concurrency_limit:
		for spec in specs:
			_spawn_card_motion_spec(spec, event_id, "")
		return

	batch_sequence += 1
	var batch_key := "%s#%d" % [
		event_id if not event_id.is_empty() else "local-card-motion",
		batch_sequence,
	]
	var coordinator := MotionHandle.new()
	batches[batch_key] = {
		"event_id": event_id,
		"specs": specs.duplicate(true),
		"cursor": 0,
		"active": 0,
		"limit": concurrency_limit,
		"coordinator": coordinator,
	}
	_register_event_motion_handle(event_id, coordinator)
	coordinator.completed.connect(
		_on_card_motion_batch_coordinator_completed.bind(
			batch_key,
			coordinator,
		),
		CONNECT_ONE_SHOT,
	)
	_fill_card_motion_batch(batch_key)


func _fill_card_motion_batch(batch_key: String) -> void:
	if not batches.has(batch_key):
		return
	var row: Dictionary = batches[batch_key]
	var specs: Array = row.get("specs", [])
	var cursor := int(row.get("cursor", 0))
	var active := int(row.get("active", 0))
	var concurrency_limit := maxi(1, int(row.get("limit", 1)))
	var event_id := str(row.get("event_id", ""))
	while cursor < specs.size() and active < concurrency_limit:
		var spec := Dictionary(specs[cursor]).duplicate(true)
		# Waiting for an earlier entity already supplies the stagger for queued
		# cards. Reapplying the original absolute index delay would introduce a
		# multi-second dead gap for large hands.
		if cursor >= concurrency_limit:
			spec["delay"] = 0.0
		spec["visual_index"] = cursor % concurrency_limit
		cursor += 1
		row["cursor"] = cursor
		batches[batch_key] = row
		var flying := _spawn_card_motion_spec(spec, event_id, batch_key)
		if flying == null:
			_dispose_queued_card_motion_spec(spec)
			continue
		var handle := flying.get_meta("motion_handle", null) as MotionHandle
		if handle == null or handle.is_finished():
			_dispose_card_motion_batch_flyer(flying, batch_key)
			continue
		active += 1
		row["active"] = active
		batches[batch_key] = row
		handle.completed.connect(
			_on_card_motion_batch_item_completed.bind(
				batch_key,
				flying,
				handle,
			),
			CONNECT_ONE_SHOT,
		)
	if cursor >= specs.size() and active <= 0:
		_complete_card_motion_batch(batch_key)


func _spawn_card_motion_spec(
	spec: Dictionary,
	event_id: String,
	batch_key: String,
) -> Control:
	var texture := spec.get("texture") as Texture2D
	if texture == null:
		return null
	var existing_flyer := table.presentation_runtime._valid_control(spec.get("existing_flyer"))
	if existing_flyer != null and bool(spec.get("texture_authoritative", false)):
		# Reused drag/snapshot entities retain their node tree. Refresh the face at
		# authority handoff so a stale placeholder cannot survive into flight.
		_set_paper_card_texture(existing_flyer, texture)
	var flying := motion_entities._spawn_flying_card(
		texture,
		geometry._vector_or_default(spec.get("start"), Vector2.ZERO),
		geometry._vector_or_default(spec.get("finish"), Vector2.ZERO),
		float(spec.get("duration", 0.0)),
		float(spec.get("delay", 0.0)),
		str(spec.get("event_type", "")),
		int(spec.get("visual_index", spec.get("ordinal", 0))),
		geometry._vector_or_default(spec.get("start_size"), Vector2.ZERO),
		geometry._vector_or_default(spec.get("finish_size"), Vector2.ZERO),
		float(spec.get("start_rotation", 0.0)),
		float(spec.get("finish_rotation", 0.0)),
		table.presentation_runtime._valid_control(spec.get("landing_view")),
		existing_flyer,
		event_id,
		str(spec.get("landing_attachment_type", "")),
		str(spec.get("landing_attachment_card_id", "")),
		int(spec.get("landing_attachment_index", -1)),
		spec.get("flip_texture") as Texture2D,
		bool(spec.get("stage_opponent_hand_landing", false)),
		int(spec.get("opponent_hand_stage_count_delta", 0)),
	)
	if flying != null:
		var motion_card_id := str(spec.get("card_id", ""))
		if not motion_card_id.is_empty():
			flying.set_meta("motion_card_id", motion_card_id)
	if flying != null and not batch_key.is_empty():
		flying.set_meta("motion_batch_ordinal", int(spec.get("ordinal", 0)))
		flying.set_meta("motion_batch_key", batch_key)
	return flying


func _on_card_motion_batch_item_completed(
	_completed_handle: MotionHandle,
	batch_key: String,
	flying: Control,
	expected_handle: MotionHandle,
) -> void:
	if not batches.has(batch_key):
		return
	var row: Dictionary = batches[batch_key]
	if flying != null and is_instance_valid(flying):
		var actual_handle := flying.get_meta("motion_handle", null) as MotionHandle
		if actual_handle == expected_handle:
			_dispose_card_motion_batch_flyer(flying, batch_key)
	row["active"] = maxi(0, int(row.get("active", 0)) - 1)
	batches[batch_key] = row
	_fill_card_motion_batch(batch_key)


func _dispose_card_motion_batch_flyer(
	flying: Control,
	batch_key: String,
) -> void:
	if flying == null or not is_instance_valid(flying):
		return
	if str(flying.get_meta("motion_batch_key", "")) != batch_key:
		return
	flying.remove_meta("motion_batch_key")
	if flying.has_meta("motion_batch_ordinal"):
		flying.remove_meta("motion_batch_ordinal")
	# Opponent-hand arrivals are adopted as stationary hidden-hand proxies by
	# motion_entities._finish_flyer(). They no longer belong to the motion controller and must survive
	# until the opponent-hand transaction itself reconciles.
	if bool(flying.get_meta("card_motion_entity", false)):
		motion_entities._dispose_flyer(flying)
	else:
		if flying.has_meta("motion_handle"):
			flying.remove_meta("motion_handle")
		if flying.has_meta("motion_event_id"):
			flying.remove_meta("motion_event_id")


func _complete_card_motion_batch(batch_key: String) -> void:
	if not batches.has(batch_key):
		return
	var row: Dictionary = batches[batch_key]
	batches.erase(batch_key)
	var coordinator := row.get("coordinator") as MotionHandle
	if coordinator != null and not coordinator.is_finished():
		coordinator.finish()


func _on_card_motion_batch_coordinator_completed(
	_completed_handle: MotionHandle,
	batch_key: String,
	expected_handle: MotionHandle,
) -> void:
	if (
		expected_handle.status == MotionHandle.CANCELLED
		and batches.has(batch_key)
		and Dictionary(batches[batch_key]).get("coordinator")
		== expected_handle
	):
		_cancel_card_motion_batch(batch_key, false, true)


func _dispose_queued_card_motion_spec(spec: Dictionary) -> void:
	var proxy := table.presentation_runtime._valid_control(spec.get("existing_flyer"))
	if proxy == null:
		return
	if proxy.has_meta("snapshot_hand_key"):
		table.hand_presentation._dispose_snapshot_hand_source(proxy)
	else:
		motion_entities._dispose_flyer(proxy)


func _cancel_card_motion_batch(
	batch_key: String,
	cancel_coordinator: bool = true,
	dispose_active: bool = true,
) -> void:
	if not batches.has(batch_key):
		return
	var row: Dictionary = batches[batch_key]
	batches.erase(batch_key)
	var specs: Array = row.get("specs", [])
	for index in range(int(row.get("cursor", 0)), specs.size()):
		_dispose_queued_card_motion_spec(Dictionary(specs[index]))
	if dispose_active:
		for flying in entities.duplicate():
			if (
				flying != null
				and is_instance_valid(flying)
				and str(flying.get_meta("motion_batch_key", "")) == batch_key
			):
				motion_entities._dispose_flyer(flying)
	var coordinator := row.get("coordinator") as MotionHandle
	if cancel_coordinator and coordinator != null and not coordinator.is_finished():
		coordinator.cancel()


func _clear_card_motion_batches() -> void:
	for batch_key_value in batches.keys().duplicate():
		_cancel_card_motion_batch(str(batch_key_value), true, true)


func _clear_card_motion_batches_for_event(event_id: String) -> void:
	if event_id.is_empty():
		return
	for batch_key_value in batches.keys().duplicate():
		var batch_key := str(batch_key_value)
		var row: Dictionary = batches.get(batch_key, {})
		if str(row.get("event_id", "")) == event_id:
			_cancel_card_motion_batch(batch_key, true, true)


func _register_event_motion(
	flying: Control,
	event_id: String,
	tween: Tween,
) -> void:
	if flying == null or not is_instance_valid(flying):
		return
	var handle := MotionHandle.new()
	handle.bind_tween(tween)
	if not event_id.is_empty() and event_motion_completions.has(event_id):
		var row: Dictionary = event_motion_completions.get(event_id, {})
		var group := row.get("group") as MotionGroup
		if group != null:
			group.add(handle)
		if table.hand_presentation._hand_transition_sequences.has(event_id):
			var hand_row: Dictionary = table.hand_presentation._hand_transition_sequences[event_id]
			var flight_handles: Array = hand_row.get("flight_handles", [])
			flight_handles.append(handle)
			hand_row["flight_handles"] = flight_handles
			table.hand_presentation._hand_transition_sequences[event_id] = hand_row
	if not event_id.is_empty():
		flying.set_meta("motion_event_id", event_id)
	elif flying.has_meta("motion_event_id"):
		flying.remove_meta("motion_event_id")
	flying.set_meta("motion_handle", handle)


func _register_event_motion_handle(event_id: String, handle: MotionHandle) -> void:
	if (
		event_id.is_empty()
		or handle == null
		or handle.is_finished()
		or not event_motion_completions.has(event_id)
	):
		return
	var row: Dictionary = event_motion_completions.get(event_id, {})
	var group := row.get("group") as MotionGroup
	if group != null:
		group.add(handle)


func _finish_event_motion_dispatch(event_id: String) -> void:
	if event_id.is_empty() or not event_motion_completions.has(event_id):
		return
	var row: Dictionary = event_motion_completions.get(event_id, {})
	var group := row.get("group") as MotionGroup
	if group != null:
		group.seal()
	if group == null or group.is_completed():
		event_motion_completions.erase(event_id)


func _complete_event_motion_entity(flying: Control) -> void:
	if flying == null or not is_instance_valid(flying):
		return
	if not flying.has_meta("motion_handle"):
		return
	var handle := flying.get_meta("motion_handle") as MotionHandle
	if handle != null:
		handle.cancel()
	flying.remove_meta("motion_handle")


func _finish_all_event_motions() -> void:
	var rows := event_motion_completions.values().duplicate()
	event_motion_completions.clear()
	for row_value in rows:
		var row := row_value as Dictionary
		var group := row.get("group") as MotionGroup
		if group != null:
			group.cancel()
		var completion := row.get("completion") as PresentationDirector.EventCompletion
		if completion != null:
			completion.finish()


func _texture_for_card_id(card_id: String) -> Texture2D:
	var texture_path := "res://assets/cards/card_back.webp"
	if not card_id.is_empty():
		texture_path = str(table.catalog.get_card(card_id).get("image_path", ""))
		if texture_path.is_empty():
			texture_path = "res://assets/cards/card_back.webp"
	var texture_cache := table._autoload_node("CardTextureCache")
	var texture := (
		texture_cache.call("get_texture", texture_path) as Texture2D
		if texture_cache != null
		else load(texture_path) as Texture2D
	)
	if texture == null and texture_path != "res://assets/cards/card_back.webp":
		texture = (
			texture_cache.call(
				"get_texture",
				"res://assets/cards/card_back.webp",
			) as Texture2D
			if texture_cache != null
			else load("res://assets/cards/card_back.webp") as Texture2D
		)
	if texture == null:
		texture = table.CARD_BACK_TEXTURE
	return texture


func _public_motion_texture_for_card_id(card_id: String) -> Texture2D:
	# A card back communicates concealed identity. Public endpoints with absent
	# table.catalog art instead use an unmistakably neutral placeholder.
	if card_id.is_empty() or table.catalog == null:
		return _neutral_public_card_texture()
	var card: Dictionary = table.catalog.get_card(card_id)
	var texture_path := str(card.get("image_path", ""))
	if (
		card.is_empty()
		or texture_path.is_empty()
		or not ResourceLoader.exists(texture_path, "Texture2D")
	):
		return _neutral_public_card_texture()
	var texture := _texture_for_card_id(card_id)
	return texture if texture != null else _neutral_public_card_texture()


func _neutral_public_card_texture() -> Texture2D:
	if neutral_public_texture != null:
		return neutral_public_texture
	var image := Image.create(64, 90, false, Image.FORMAT_RGBA8)
	image.fill(Color("#172334"))
	var border := Color("#6f8197")
	for x in range(image.get_width()):
		image.set_pixel(x, 0, border)
		image.set_pixel(x, image.get_height() - 1, border)
	for y in range(image.get_height()):
		image.set_pixel(0, y, border)
		image.set_pixel(image.get_width() - 1, y, border)
	neutral_public_texture = ImageTexture.create_from_image(image)
	return neutral_public_texture


func _spawn_slot_transition(
	event: Dictionary,
	duration: float,
	motion_event_id: String = "",
) -> bool:
	var event_type := PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	)
	if event_type not in ["retreat", "switched", "promoted"]:
		return false
	var data: Dictionary = event.get("data", {})
	var actor := int(event.get("actor", data.get("player", table.view_player)))
	var player := int(data.get("player", actor))
	var bench_slot := geometry._bench_slot_from_event(event)
	if bench_slot.is_empty():
		return false
	var movements: Array[Dictionary] = []
	if event_type == "promoted":
		movements.append({
			"from": bench_slot,
			"to": "active",
		})
	else:
		movements.append({
			"from": "active",
			"to": bench_slot,
		})
		movements.append({
			"from": bench_slot,
			"to": "active",
		})
	var remaining_queues_by_destination: Dictionary = {}
	var current_event_id := str(event.get("event_id", ""))
	for movement_value in movements:
		var destination_slot := str(Dictionary(movement_value).get("to", ""))
		var destination_key := "%d:%s" % [player, destination_slot]
		var remaining_queue: Array = Array(
			table.presentation_runtime.slot_event_plans.get(
				destination_key,
				table.presentation_runtime.slot_event_queues.get(destination_key, []),
			),
		).duplicate()
		remaining_queue.erase(current_event_id)
		remaining_queues_by_destination[destination_key] = remaining_queue
	var spawned := false
	var prepared_movements: Array[Dictionary] = []
	# Claim every pre-event source before any destination handoff.  This matters
	# when motion is disabled: retaining active -> bench immediately must not
	# replace the original bench cover before bench -> active has claimed it.
	for index in range(movements.size()):
		var movement: Dictionary = movements[index]
		var from_slot := str(movement["from"])
		var to_slot := str(movement["to"])
		var snapshot_row := geometry._snapshot_slot_row(player, from_slot)
		var card_id := str(snapshot_row.get("card_id", ""))
		if card_id.is_empty():
			continue
		var finish_view := table.get_slot_view(player, to_slot)
		if finish_view == null:
			continue
		var source_key := "%d:%s" % [player, from_slot]
		var mover := table.presentation_runtime._claim_slot_state_cover(source_key)
		if mover == null:
			var pokemon_data: Dictionary = snapshot_row.get("pokemon", {})
			if not pokemon_data.is_empty():
				mover = table.presentation_runtime._spawn_slot_state_cover(
					source_key,
					snapshot_row,
					PokemonState.from_dict(pokemon_data),
				)
		if mover == null:
			continue
		prepared_movements.append({
			"index": index,
			"from_slot": from_slot,
			"to_slot": to_slot,
			"snapshot_row": snapshot_row,
			"mover": mover,
			"finish_view": finish_view,
		})
	# Release only original staged covers that could not be consumed.  Doing this
	# before destination insertion prevents cleanup from deleting a newly retained
	# mover that happens to use the same slot key.
	for key in table.presentation_runtime._slot_visual_keys_for_event(event):
		if table.presentation_runtime.slot_covers.has(key):
			table.presentation_runtime._release_slot_state_cover(key)
	var bidirectional_lane_offset := -1.0
	if prepared_movements.size() == 2:
		bidirectional_lane_offset = geometry._slot_composite_bidirectional_lane_offset(
			prepared_movements,
		)
	for prepared_value in prepared_movements:
		var prepared: Dictionary = prepared_value
		var index := int(prepared.get("index", 0))
		var from_slot := str(prepared.get("from_slot", ""))
		var to_slot := str(prepared.get("to_slot", ""))
		var snapshot_row: Dictionary = prepared.get("snapshot_row", {})
		var mover := prepared.get("mover") as CardView
		var finish_view := prepared.get("finish_view") as CardView
		if mover == null or finish_view == null:
			continue
		var finish := table._effects_local(finish_view.global_center())
		var start := table._effects_local(mover.global_center())
		var destination_key := "%d:%s" % [player, to_slot]
		var destination_queue: Array = Array(
			remaining_queues_by_destination.get(destination_key, []),
		).duplicate()
		var start_rotation := float(snapshot_row.get("rotation_degrees", 0.0))
		var timing := geometry._flying_card_timing(index, movements.size(), duration, false)
		if not bool(timing.get("spawn", false)):
			if destination_queue.is_empty():
				_handoff_slot_composite_immediately(
					mover,
					finish_view,
					motion_event_id,
				)
			else:
				_retain_slot_composite_as_cover(
					mover,
					finish_view,
					destination_key,
					destination_queue,
					motion_event_id,
				)
			_landing_burst(finish, event_type)
			spawned = true
			continue
		_spawn_slot_composite_motion(
			mover,
			start,
			finish,
			float(timing.get("duration", 0.0)),
			float(timing.get("delay", 0.0)),
			event_type,
			index,
			start_rotation,
			finish_view,
			motion_event_id,
			from_slot,
			to_slot,
			destination_key,
			destination_queue,
			bidirectional_lane_offset,
		)
		spawned = true
	if not spawned:
		_complete_slot_transition_without_motion(event)
	# Once recognized, slot transitions must never fall through to the generic
	# empty-card motion path (which would manufacture a card-back flyer).
	return true


func _spawn_slot_composite_motion(
	mover: CardView,
	start: Vector2,
	finish: Vector2,
	duration: float,
	delay: float,
	event_type: String,
	index: int,
	start_rotation: float,
	landing_view: CardView,
	motion_event_id: String,
	from_slot: String,
	to_slot: String,
	destination_key: String,
	destination_queue: Array,
	lane_offset_override: float = -1.0,
) -> void:
	if mover == null or not is_instance_valid(mover):
		return
	mover.name = "SlotCompositeMover_%s_%d" % [event_type, index]
	mover.set_meta("battle_transient_kind", "SlotCompositeMover")
	mover.set_meta("card_motion_entity", true)
	mover.set_meta("slot_composite_motion", true)
	mover.set_meta("slot_composite_from", from_slot)
	mover.set_meta("slot_composite_to", to_slot)
	mover.set_meta("motion_start", start)
	mover.set_meta("motion_finish", finish)
	mover.set_meta("motion_landing_view", landing_view)
	mover.set_meta("slot_composite_start_rotation", start_rotation)
	if not destination_queue.is_empty():
		mover.set_meta("slot_composite_retain_key", destination_key)
		mover.set_meta("slot_composite_remaining_queue", destination_queue.duplicate())
		# The authoritative destination already contains later same-batch state.
		# Keep its switch mask until the remapped cover has consumed that queue.
		motion_entities._remove_revealed_node_for_event(landing_view, motion_event_id)
	var distance := start.distance_to(finish)
	var lane_offset := (
		lane_offset_override
		if lane_offset_override > 0.0
		else clampf(distance * 0.18, 38.0, 78.0)
	)
	mover.set_meta("slot_composite_lane_offset", lane_offset)
	mover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mover.focus_mode = Control.FOCUS_NONE
	mover.pivot_offset = mover.size * 0.5
	mover.position = start - mover.size * 0.5
	mover.rotation_degrees = start_rotation
	mover.scale = Vector2.ONE
	mover.modulate.a = 1.0
	mover.z_index = 100 + index
	mover.set_table_depth(geometry._motion_depth_for_point((start + finish) * 0.5), true)
	self.add(mover)

	var tween := create_tween()
	if delay > 0.0:
		tween.tween_interval(delay)
	self.bind_tween(mover, tween)
	tween.tween_method(
		_update_slot_composite_motion.bind(
			mover,
			start,
			finish,
			lane_offset,
			start_rotation,
		),
		0.0,
		1.0,
		duration,
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	if destination_queue.is_empty():
		tween.tween_callback(_begin_slot_composite_handoff.bind(
			mover,
			landing_view,
			motion_event_id,
		))
		tween.tween_method(
			_update_slot_composite_handoff.bind(mover, landing_view, finish),
			0.0,
			1.0,
			0.10,
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_callback(_finish_slot_composite.bind(
			mover,
			landing_view,
			finish,
			event_type,
		))
	else:
		tween.tween_callback(_finish_retained_slot_composite.bind(
			mover,
			landing_view,
			destination_key,
			destination_queue,
			finish,
			event_type,
		))
	_register_event_motion(mover, motion_event_id, tween)


func _update_slot_composite_motion(
	progress: float,
	mover_value: Variant,
	start: Vector2,
	fallback_finish: Vector2,
	lane_offset: float,
	start_rotation: float,
) -> void:
	var mover := table.presentation_runtime._valid_card_view(mover_value)
	if mover == null:
		return
	var dynamic_finish := _motion_entity_finish(mover, fallback_finish)
	var control := geometry._slot_composite_control_point(
		start,
		dynamic_finish,
		lane_offset,
	)
	var inverse := 1.0 - progress
	var point := (
		start * inverse * inverse
		+ control * 2.0 * inverse * progress
		+ dynamic_finish * progress * progress
	)
	var landing_view := table.presentation_runtime._valid_card_view(mover.get_meta("motion_landing_view", null))
	var finish_rotation := (
		landing_view.rotation_degrees if landing_view != null else start_rotation
	)
	var target_scale := geometry._slot_composite_target_scale(mover, landing_view)
	var lift := 1.0 + sin(progress * PI) * table.SLOT_COMPOSITE_LIFT_SCALE
	mover.position = point - mover.size * 0.5
	mover.rotation_degrees = (
		lerpf(start_rotation, finish_rotation, progress)
		+ sin(progress * PI) * 1.8
	)
	mover.scale = Vector2.ONE.lerp(target_scale, progress) * lift
	mover.modulate.a = 1.0


func _begin_slot_composite_handoff(
	mover_value: Variant,
	landing_value: Variant,
	event_id: String,
) -> void:
	var mover := table.presentation_runtime._valid_card_view(mover_value)
	var landing_view := table.presentation_runtime._valid_card_view(landing_value)
	if mover == null or landing_view == null:
		return
	table.presentation_runtime._reveal_presentation_node(landing_view, false, 0.0)
	landing_view.modulate.a = 0.0
	motion_entities._remove_revealed_node_for_event(landing_view, event_id)


func _update_slot_composite_handoff(
	progress: float,
	mover_value: Variant,
	landing_value: Variant,
	fallback_finish: Vector2,
) -> void:
	var mover := table.presentation_runtime._valid_card_view(mover_value)
	var landing_view := table.presentation_runtime._valid_card_view(landing_value)
	if mover == null:
		return
	var finish := _motion_entity_finish(mover, fallback_finish)
	mover.position = finish - mover.size * 0.5
	if landing_view != null:
		mover.rotation_degrees = landing_view.rotation_degrees
		mover.scale = geometry._slot_composite_target_scale(mover, landing_view)
		landing_view.modulate.a = progress
	mover.modulate.a = 1.0 - progress


func _finish_slot_composite(
	mover_value: Variant,
	landing_value: Variant,
	fallback_finish: Vector2,
	event_type: String,
) -> void:
	var mover := table.presentation_runtime._valid_card_view(mover_value)
	if mover == null:
		return
	var landing_view := table.presentation_runtime._valid_card_view(landing_value)
	var finish := _motion_entity_finish(mover, fallback_finish)
	tweens.erase(mover.get_instance_id())
	mover.set_meta("motion_completed", true)
	mover.position = finish - mover.size * 0.5
	mover.modulate.a = 0.0
	mover.visible = false
	if landing_view != null:
		landing_view.modulate.a = 1.0
	if not table.presentation_runtime._play_card_landing_feedback(mover, finish):
		_landing_burst(finish, event_type)


func _finish_retained_slot_composite(
	mover_value: Variant,
	landing_value: Variant,
	destination_key: String,
	destination_queue: Array,
	fallback_finish: Vector2,
	event_type: String,
) -> void:
	var mover := table.presentation_runtime._valid_card_view(mover_value)
	var landing_view := table.presentation_runtime._valid_card_view(landing_value)
	if mover == null or landing_view == null:
		return
	var finish := _motion_entity_finish(mover, fallback_finish)
	_retain_slot_composite_as_cover(
		mover,
		landing_view,
		destination_key,
		destination_queue,
		str(mover.get_meta("motion_event_id", "")),
	)
	if not table.presentation_runtime._play_card_landing_feedback(mover, finish):
		_landing_burst(finish, event_type)


func _retain_slot_composite_as_cover(
	mover: CardView,
	landing_view: CardView,
	destination_key: String,
	destination_queue: Array,
	event_id: String,
) -> void:
	if (
		mover == null
		or landing_view == null
		or not is_instance_valid(mover)
		or destination_key.is_empty()
	):
		return
	entities.erase(mover)
	tweens.erase(mover.get_instance_id())
	self.forget(mover)
	mover.remove_meta("card_motion_entity")
	mover.set_meta("retained_slot_cover", true)
	mover.set_meta("presentation_slot_key", destination_key)
	mover.set_meta("slot_composite_remaining_queue", destination_queue.duplicate())
	mover.name = "SlotStateCover_%s" % destination_key.replace(":", "_")
	mover.set_meta("battle_transient_kind", "SlotStateCover")
	mover.custom_minimum_size = landing_view.size
	mover.size = landing_view.size
	mover.pivot_offset = mover.size * 0.5
	mover.scale = Vector2.ONE
	mover.position = table._effects_local(landing_view.global_center()) - mover.size * 0.5
	mover.rotation_degrees = landing_view.rotation_degrees
	mover.modulate.a = 1.0
	mover.visible = true
	mover.z_index = 94
	mover.set_table_depth(
		geometry._motion_depth_for_point(mover.position + mover.size * 0.5),
		true,
	)
	table.presentation_runtime.slot_covers[destination_key] = mover
	table.presentation_runtime.slot_cover_states[destination_key] = mover.pokemon
	table.presentation_runtime.slot_event_queues[destination_key] = destination_queue.duplicate()
	motion_entities._remove_revealed_node_for_event(landing_view, event_id)


func _handoff_slot_composite_immediately(
	mover: CardView,
	landing_view: CardView,
	event_id: String,
) -> void:
	if landing_view != null:
		table.presentation_runtime._reveal_presentation_node(landing_view, false, 0.0)
		landing_view.modulate.a = 1.0
		motion_entities._remove_revealed_node_for_event(landing_view, event_id)
	if mover != null and is_instance_valid(mover):
		mover.visible = false
		mover.modulate.a = 0.0
		mover.queue_free()


func _complete_slot_transition_without_motion(event: Dictionary) -> void:
	var event_id := str(event.get("event_id", ""))
	for view_value in table.presentation_runtime._switch_slot_views_for_event(event):
		var view := table.presentation_runtime._valid_card_view(view_value)
		if view == null:
			continue
		table.presentation_runtime._reveal_presentation_node(view, false, 0.0)
		view.modulate.a = 1.0
		motion_entities._remove_revealed_node_for_event(view, event_id)
	for key in table.presentation_runtime._slot_visual_keys_for_event(event):
		table.presentation_runtime._release_slot_state_cover(key)


func _landing_burst(finish: Vector2, event_type: String) -> void:
	table.presentation_runtime._burst_world_at_motion_point(
		finish,
		_motion_landing_color(event_type),
		"card_land",
	)


func _motion_landing_color(event_type: String) -> Color:
	return (
		DesignTokens.GOLD
		if event_type in ["cards_drawn", "prize_taken"]
		else DesignTokens.CYAN
	)


func _max_active_flyers() -> int:
	return (
		table.MAX_ACTIVE_FLYERS_LOW
		if table._settings_quality_profile() == "low"
		else table.MAX_ACTIVE_FLYERS_HIGH
	)


func _shuffle_card_count() -> int:
	return int(table.SHUFFLE_CARD_LIMITS.get(table._settings_quality_profile(), 5))


func _spawn_coin_motion(
	event: Dictionary,
	motion_event_id: String,
	actor: int,
) -> bool:
	if table.coin_showcase == null:
		return false
	var data: Dictionary = event.get("data", {})
	var raw_results: Variant = data.get("results", [])
	if not raw_results is Array or Array(raw_results).is_empty():
		return false
	var results: Array = []
	for value in Array(raw_results):
		results.append(bool(value))
	table.board_view._layout_coin_showcase()
	table.coin_showcase.visible = true
	var title := "你掷硬币" if actor == table.view_player else "对手掷硬币"
	if str(data.get("purpose", "")) == "setup_first_player":
		var first_player := int(data.get("first_player", -1))
		if table.game_mode == "local":
			title = "决定先攻 · 玩家 %d 先攻" % (first_player + 1)
		else:
			title = (
				"决定先攻 · 你先攻"
				if first_player == table.view_player
				else "决定先攻 · 对手先攻"
			)
	var handle := table.coin_showcase.play(results, false, title)
	_register_event_motion_handle(motion_event_id, handle)
	return true


func _on_coin_showcase_audio_requested(cue: String) -> void:
	if table.director != null:
		table.director.audio_requested.emit(cue)


func _spawn_reveal_motion(
	event: Dictionary,
	duration: float,
	motion_event_id: String = "",
) -> bool:
	if table.reveal_layer == null or table.effects == null:
		return false
	var rows := geometry._reveal_rows(event)
	var actor := int(event.get(
		"actor",
		Dictionary(event.get("data", {})).get("player", table.view_player),
	))
	var source_endpoint := table.presentation_runtime._event_source_endpoint(event)
	if str(source_endpoint.get("zone", "")).is_empty():
		source_endpoint = {"player": actor, "zone": "deck"}
	var source_origin := geometry._snapshot_endpoint_center(
		source_endpoint,
		table.resolve_endpoint_center(source_endpoint),
	)
	var card_back := _texture_for_card_id("")
	if card_back == null and not rows.is_empty():
		return false
	var face_textures: Array[Texture2D] = []
	var destination_points: Array[Vector2] = []
	for row in rows:
		face_textures.append(_texture_for_card_id(str(row.get("card_id", ""))))
		var destination := geometry._reveal_destination(row, actor)
		destination_points.append(geometry._snapshot_endpoint_center(
			destination,
			table.resolve_endpoint_center(destination),
		))
	var data: Dictionary = event.get("data", {})
	var summary_value: Variant = data.get("summary", {})
	var summary := (
		Dictionary(summary_value).duplicate(true)
		if summary_value is Dictionary
		else {}
	)
	if PresentationEvent.canonical_event_type(
		str(event.get("event_type", "")),
	) == "cards_selected":
		summary["kind"] = "public_selection"
		summary["matched_count"] = rows.size()
		summary["title"] = (
			"公开检索结果"
			if str(source_endpoint.get("zone", "")) == "deck"
			else "公开选择结果"
		)
	var handle := table.reveal_layer.present(
		rows,
		card_back,
		face_textures,
		source_origin,
		destination_points,
		geometry._reveal_content_rect(),
		summary,
		duration,
		MotionPolicy.reduced(),
	)
	_register_event_motion_handle(motion_event_id, handle)
	return true


func _spawn_shuffle_motion(
	endpoint: Dictionary,
	duration: float,
	motion_event_id: String = "",
	startup: bool = false,
) -> bool:
	if table.effects == null:
		return false
	var texture := _texture_for_card_id("")
	if texture == null:
		return false
	var count := _shuffle_card_count()
	var source_zone := geometry._zone_view_for_endpoint(endpoint)
	if source_zone != null:
		# Shuffle proxies represent physical cards already staged in this exact
		# pile. An empty or one-card deck must never materialize a cosmetic pack.
		count = mini(count, maxi(0, source_zone.count))
	if count <= 0:
		return false
	var origin := geometry._snapshot_endpoint_center(endpoint, table.resolve_endpoint_center(endpoint))
	var card_size := geometry._snapshot_endpoint_size(
		endpoint,
		geometry._current_endpoint_size(endpoint, geometry._flying_card_size("deck_shuffled")),
	)
	var pile_extent := Vector2.ZERO
	if source_zone != null:
		var zone_transform := source_zone.get_global_transform_with_canvas()
		var extent_origin := table._effects_local(zone_transform * Vector2.ZERO)
		pile_extent = (
			table._effects_local(zone_transform * source_zone.get_stack_visual_extent())
			- extent_origin
		)
	var playable_duration := maxf(0.0, duration - table.FLYING_CARD_FINISH_PAD)
	if playable_duration < table.MIN_FLYING_CARD_DURATION:
		_landing_burst(origin, "deck_shuffled")
		return true
	var spawned := false
	for index in range(count):
		motion_entities._prune_flyers()
		while not startup and entities.size() >= _max_active_flyers():
			var oldest: Control = entities.pop_front()
			motion_entities._dispose_flyer(oldest)
		# Replace the visible pile one-for-one while it is being shuffled.  The
		# highest-z proxy begins on the physical top card, while lower proxies span
		# the pile's actual drawn paper depth.  This avoids a second, floating pack
		# appearing over an unchanged deck ZoneView.
		var depth_ratio := (
			1.0 - float(index) / float(count - 1)
			if count > 1
			else 0.0
		)
		var start: Vector2 = origin + pile_extent * depth_ratio
		var side: float = -1.0 if index % 2 == 0 else 1.0
		var row: float = floor(float(index) * 0.5)
		var pile_count := ceili(float(count) * 0.5)
		var split: Vector2 = start + Vector2(
			side * (card_size.x * 0.34 + row * 2.4),
			(row - float(pile_count - 1) * 0.5) * 2.8,
		)
		var riffle: Vector2 = origin + Vector2(
			(float(index) - float(count - 1) * 0.5) * 1.8,
			absf(float(index) - float(count - 1) * 0.5) * 0.9,
		)
		var finish: Vector2 = origin + pile_extent * depth_ratio
		var flyer := motion_entities._create_paper_card_token(
			texture,
			card_size,
			"CardMotionEntity",
			110 + index,
			geometry._motion_depth_for_point(origin),
		)
		flyer.set_meta("shuffle_card", true)
		flyer.set_meta("startup_shuffle", startup)
		flyer.set_meta("shuffle_from_physical_pile", source_zone != null)
		flyer.set_meta("shuffle_source_center", origin)
		flyer.set_meta("shuffle_source_extent", pile_extent)
		flyer.set_meta("shuffle_source_zone", source_zone)
		flyer.set_meta("card_motion_entity", true)
		flyer.set_meta("motion_start", start)
		flyer.set_meta("motion_finish", finish)
		flyer.position = start - flyer.size * 0.5
		flyer.rotation_degrees = side * -1.5
		flyer.modulate.a = 1.0
		self.add(flyer)
		_retain_shuffle_source_zone(source_zone, flyer)
		var tween := create_tween()
		self.bind_tween(flyer, tween)
		tween.tween_method(
			_update_shuffle_card.bind(
				flyer,
				start,
				split,
				riffle,
				finish,
				side,
				int(row),
				index,
				count,
			),
			0.0,
			1.0,
			playable_duration,
		).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
		tween.tween_callback(_finish_shuffle_card.bind(flyer, finish))
		_register_event_motion(flyer, motion_event_id, tween)
		spawned = true
	return spawned


func _update_shuffle_card(
	progress: float,
	flying_value: Variant,
	start: Vector2,
	split: Vector2,
	riffle: Vector2,
	finish: Vector2,
	side: float,
	pile_index: int,
	index: int,
	count: int,
) -> void:
	if not is_instance_valid(flying_value):
		return
	var flying := flying_value as Control
	if flying == null:
		return
	var normalized := clampf(progress, 0.0, 1.0)
	var point := finish
	var rotation_value := 0.0
	var scale_value := Vector2.ONE
	if normalized < 0.24:
		var split_progress := geometry._shuffle_ease_in_out_cubic(normalized / 0.24)
		point = start.lerp(split, split_progress)
		rotation_value = lerpf(side * -1.5, side * 7.0, split_progress)
	elif normalized < 0.58:
		# Each half releases from its inside edge in a short alternating cascade.
		var pile_count := ceili(float(count) * 0.5)
		var release_offset := (
			float(pile_index) / float(maxi(1, pile_count - 1)) * 0.11
		)
		var riffle_progress := clampf(
			(normalized - 0.24 - release_offset) / (0.34 - release_offset),
			0.0,
			1.0,
		)
		riffle_progress = geometry._shuffle_ease_out_cubic(riffle_progress)
		point = split.lerp(riffle, riffle_progress)
		rotation_value = lerpf(side * 7.0, side * 1.2, riffle_progress)
		scale_value = Vector2(
			1.0 + sin(riffle_progress * PI) * 0.025,
			1.0 - sin(riffle_progress * PI) * 0.035,
		)
	elif normalized < 0.82:
		# The interleaved packet arches and settles like a light bridge shuffle.
		var bridge_progress := geometry._shuffle_ease_in_out_cubic((normalized - 0.58) / 0.24)
		point = riffle.lerp(finish, bridge_progress)
		var center_distance := absf(float(index) - float(count - 1) * 0.5)
		point.y -= sin(bridge_progress * PI) * (10.0 + center_distance * 1.2)
		rotation_value = lerpf(side * 1.2, 0.0, bridge_progress)
		scale_value = Vector2(
			1.0 + sin(bridge_progress * PI) * 0.045,
			1.0 - sin(bridge_progress * PI) * 0.055,
		)
	else:
		# Finish with one compact cut: the upper packet slides out and returns.
		var cut_progress := clampf((normalized - 0.82) / 0.18, 0.0, 1.0)
		var upper_packet := index >= int(floor(float(count) * 0.5))
		var cut_offset := Vector2(
			24.0 if upper_packet else -7.0,
			-8.0 if upper_packet else 3.0,
		) * sin(cut_progress * PI)
		point = finish + cut_offset
		rotation_value = (4.0 if upper_packet else -1.5) * sin(cut_progress * PI)
	flying.position = point - flying.size * 0.5
	flying.rotation_degrees = rotation_value
	flying.scale = scale_value
	flying.modulate.a = 1.0


func _finish_shuffle_card(
	flying_value: Variant,
	finish: Vector2,
) -> void:
	if not is_instance_valid(flying_value):
		return
	var flying := flying_value as Control
	if flying == null:
		return
	tweens.erase(flying.get_instance_id())
	flying.set_meta("motion_completed", true)
	flying.position = finish - flying.size * 0.5
	flying.rotation_degrees = 0.0
	flying.scale = Vector2.ONE
	# Hand the visual back to the real deck pile as soon as every proxy has
	# returned.  The proxy stays alive (but hidden) until its MotionHandle has
	# completed, preserving the presentation barrier without a duplicate pile.
	_release_shuffle_source_zone(flying)
	flying.visible = false
	flying.modulate.a = 0.0


func _retain_shuffle_source_zone(zone: ZoneView, flying: Control) -> void:
	if zone == null or flying == null or not is_instance_valid(zone):
		return
	var instance_id := zone.get_instance_id()
	var row: Dictionary = table._shuffle_source_masks.get(instance_id, {
		"zone": zone,
		"count": 0,
	})
	row["zone"] = zone
	row["count"] = int(row.get("count", 0)) + 1
	table._shuffle_source_masks[instance_id] = row
	flying.set_meta("shuffle_source_zone_id", instance_id)
	zone.set_stack_presentation_hidden(true)


func _release_shuffle_source_zone(flying: Control) -> void:
	if flying == null or not flying.has_meta("shuffle_source_zone_id"):
		return
	var instance_id := int(flying.get_meta("shuffle_source_zone_id", 0))
	flying.remove_meta("shuffle_source_zone_id")
	var row: Dictionary = table._shuffle_source_masks.get(instance_id, {})
	if row.is_empty():
		return
	var remaining := maxi(0, int(row.get("count", 0)) - 1)
	var zone := row.get("zone") as ZoneView
	if remaining > 0:
		row["count"] = remaining
		table._shuffle_source_masks[instance_id] = row
		return
	table._shuffle_source_masks.erase(instance_id)
	if zone != null and is_instance_valid(zone):
		zone.set_stack_presentation_hidden(false)


func _clear_shuffle_source_masks() -> void:
	for row_value in table._shuffle_source_masks.values():
		var row: Dictionary = row_value
		var zone := row.get("zone") as ZoneView
		if zone != null and is_instance_valid(zone):
			zone.set_stack_presentation_hidden(false)
	table._shuffle_source_masks.clear()


func _clear_transient_visuals() -> void:
	if table.camera_rig != null:
		table.camera_rig.cancel()
	table._cancel_startup_shuffle()
	table.presentation_runtime._clear_presentation_masks(true)
	motion_entities._clear_active_flyers()
	if table.reveal_layer != null:
		table.reveal_layer.clear()
	if table.coin_showcase != null:
		table.coin_showcase.clear()
	if table.effects:
		table.effects.clear_transients()
	if table.world_feedback:
		table.world_feedback.clear_transients()
	if table.announcement_layer:
		table.announcement_layer.clear()
	motion_entities._clear_effect_child_controls()
	table.presentation_runtime._clear_all_presentation_nodes()


func _on_camera_impulse_requested(strength: float, duration: float) -> void:
	if table.camera_rig != null:
		var handle := table.camera_rig.impulse(
			strength,
			duration,
			table._settings_reduced_motion(),
		)
		table.director.register_feedback_motion(handle)
