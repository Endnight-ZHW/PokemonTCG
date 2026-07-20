class_name VMEnergyContinuations
extends RefCounted

var energy_commands: VMEnergyCommands
var trigger_commands: VMTriggerCommands


func _init(p_energy_commands: VMEnergyCommands, p_trigger_commands: VMTriggerCommands) -> void:
	energy_commands = p_energy_commands
	trigger_commands = p_trigger_commands


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"energy_attach_sources": Callable(self, "continue_energy_attach_sources"),
		"energy_attach_target": Callable(self, "continue_energy_attach_target"),
		"energy_attach_distribution": Callable(self, "continue_energy_attach_distribution"),
		"discard_energy_attachments": Callable(self, "continue_discard_energy_attachments"),
		"energy_relocate_source": Callable(self, "continue_energy_relocate_source"),
		"energy_relocate_attachments": Callable(self, "continue_energy_relocate_attachments"),
		"energy_relocate_target": Callable(self, "continue_energy_relocate_target"),
		"energy_relocate_distribution": Callable(self, "continue_energy_relocate_distribution"),
		"detached_energy_distribution": Callable(self, "continue_detached_energy_distribution"),
	}
	for operation in registrations:
		interpreter.register_continuation(str(operation), registrations[operation])


func continue_energy_attach_sources(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data.get("player_idx", -1))
	var zone := str(data.get("source_zone", ""))
	var source := VMZoneHelpers.zone(state.get_player(player_idx), zone)
	var card_refs: Array[Dictionary] = []
	var seen_indices: Dictionary = {}
	for option in selected:
		var ref_value: Variant = option.get("ref", {})
		if not ref_value is Dictionary:
			return VMResult.fail("能量来源引用无效。", "stale_choice")
		var ref: Dictionary = ref_value
		var index := int(ref.get("index", -1))
		var card_id := str(ref.get("card_id", ""))
		if (
			str(ref.get("kind", "")) != "card"
			or int(ref.get("player", -1)) != player_idx
			or str(ref.get("zone", "")) != zone
			or index < 0
			or index >= source.size()
			or seen_indices.has(index)
			or str(source[index]) != card_id
		):
			return VMResult.fail("选择的能量已不存在。", "stale_choice")
		seen_indices[index] = true
		card_refs.append(ref.duplicate(true))
	if card_refs.is_empty():
		if zone == "deck":
			VMZoneHelpers.shuffle_deck(state, rng, player_idx, events)
		return VMResult.ok("未选择要附着的能量。")
	var target_slots: Array[String] = []
	for slot in data.get("target_slots", []):
		target_slots.append(str(slot))
	return energy_commands.request_energy_target(
		state,
		stack,
		player_idx,
		zone,
		card_refs,
		target_slots,
		int(data.get("max_per_target", 99)),
		-1,
		-1,
		bool(data.get("same_target", false)),
	)


func continue_energy_attach_target(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		if str(data.get("source_zone", "")) == "deck":
			var player_idx := int(data["player_idx"])
			rng.shuffle(state.get_player(player_idx).deck)
			events.append({
				"event_type": "deck_shuffled",
				"data": {"player": player_idx},
			})
		return VMResult.ok("未选择附能目标。")
	return energy_commands.attach_cards(
		state,
		int(data["player_idx"]),
		str(data["source_zone"]),
		Array(data.get("card_refs", data.get("card_ids", []))),
		str(selected[0].get("value", {}).get("slot", "")),
		events,
		rng,
		stack)


func continue_energy_attach_distribution(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var player := state.get_player(player_idx)
	var zone := str(data["source_zone"])
	var source: Array[String] = VMZoneHelpers.zone(player, zone)
	var raw_refs: Array = data.get("card_refs", data.get("card_ids", []))
	var refs := energy_commands.normalize_zone_card_refs(
		player_idx, zone, source, raw_refs)
	if refs.size() != raw_refs.size() or selected.size() > refs.size():
		return VMResult.fail("选择的能量已不存在。", "stale_choice")
	if selected.is_empty():
		if zone == "deck":
			rng.shuffle(player.deck)
			events.append({"event_type": "deck_shuffled", "data": {
				"player": player_idx,
			}})
		return VMResult.ok("未选择附着能量。")
	var max_per_target := int(data.get("max_per_target", 99))
	var forced_slot := ""
	if bool(data.get("same_target", false)) and not selected.is_empty():
		forced_slot = str(selected[0].get("value", {}).get("slot", ""))
	var per_target: Dictionary = {}
	var plan: Array[Dictionary] = []
	for index in range(selected.size()):
		var ref: Dictionary = refs[index]
		var energy_id := str(ref.get("card_id", ""))
		var source_index := int(ref.get("index", -1))
		var target_slot := str(selected[index].get("value", {}).get("slot", ""))
		if not forced_slot.is_empty():
			if target_slot != forced_slot:
				return VMResult.fail("这些能量必须附于同一只宝可梦。", "invalid_choice")
			target_slot = forced_slot
		if int(per_target.get(target_slot, 0)) >= max_per_target:
			return VMResult.fail("同一目标附着的能量过多。", "invalid_choice")
		var target := player.get_pokemon(target_slot)
		if target == null or str(selected[index].get("value", {}).get(
			"card_id", target.card_id)) != target.card_id:
			return VMResult.fail("附能目标已不存在。", "stale_choice")
		per_target[target_slot] = int(per_target.get(target_slot, 0)) + 1
		plan.append({
			"card_id": energy_id,
			"source_index": source_index,
			"target_slot": target_slot,
		})
	var removal_order := plan.duplicate(true)
	removal_order.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.get("source_index", -1)) > int(right.get("source_index", -1))
	)
	for row in removal_order:
		source.remove_at(int(row.get("source_index", -1)))
	var trigger_candidates: Array[Dictionary] = []
	for row in plan:
		var energy_id := str(row.get("card_id", ""))
		var source_index := int(row.get("source_index", -1))
		var target_slot := str(row.get("target_slot", ""))
		var target := player.get_pokemon(target_slot)
		if target == null:
			return VMResult.fail("附能目标已不存在。", "stale_choice")
		target.energy_card_ids.append(energy_id)
		var attachment_index := target.energy_card_ids.size() - 1
		events.append({
				"event_type": "energy_attached",
				"actor": player_idx,
				"card_id": energy_id,
				"source": {
					"player": player_idx,
					"zone": zone,
					"index": source_index,
				},
				"target": {
					"player": player_idx,
					"slot": target_slot,
				},
				"data": {
					"player": player_idx,
					"slot": target_slot,
					"card_id": energy_id,
					"source_zone": zone,
					"source_index": source_index,
				},
			})
		trigger_commands.collect_on_attach_triggers(
			energy_id,
			player_idx,
			target_slot,
			zone,
			trigger_candidates,
			attachment_index,
		)
	var trigger_result := trigger_commands.queue_candidates(
		stack,
		trigger_candidates,
		VMModifierManager.ON_ATTACH,
		state.active_player_idx,
		"apnap",
		"effect",
	) if not trigger_candidates.is_empty() else VMResult.ok()
	if not bool(trigger_result.get("success", false)):
		return trigger_result
	if zone == "deck":
		rng.shuffle(player.deck)
		events.append({"event_type": "deck_shuffled", "data": {
			"player": player_idx,
		}})
	return VMResult.ok()


func continue_discard_energy_attachments(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var expected := int(data.get("amount", 0))
	if selected.size() != expected:
		return VMResult.fail("选择的能量数量无效。")
	var refs: Array[Dictionary] = []
	for option in selected:
		var ref_value: Variant = option.get("ref", {})
		if not ref_value is Dictionary:
			return VMResult.fail("能量引用无效。")
		refs.append(Dictionary(ref_value).duplicate(true))
	return energy_commands.discard_attachment_refs(
		state,
		int(data.get("player_idx", state.active_player_idx)),
		int(data.get("owner_idx", -1)),
		str(data.get("source_slot", "")),
		refs,
		events,
	)


func continue_energy_relocate_source(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.fail("没有选择能量来源。")
	return energy_commands.request_relocation_attachments(
		state,
		stack,
		int(data["player_idx"]),
		str(selected[0].get("value", {}).get("slot", "")),
		int(data["amount"]),
		str(data.get("energy_type", "any")),
		int(data.get("min_select", -1)),
		bool(data.get("same_target", false)),
	)


func continue_energy_relocate_attachments(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	_events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.ok("未选择要转附的能量。")
	var player_idx := int(data.get("player_idx", -1))
	var source_slot := str(data.get("source_slot", ""))
	var source := state.get_player(player_idx).get_pokemon(source_slot)
	if source == null:
		return VMResult.fail("能量来源已失效。")
	var refs: Array[Dictionary] = []
	var seen_indices: Dictionary = {}
	for option in selected:
		var ref_value: Variant = option.get("ref", {})
		if not ref_value is Dictionary:
			return VMResult.fail("能量引用无效。")
		var ref := Dictionary(ref_value).duplicate(true)
		var index := int(ref.get("index", -1))
		if (
			str(ref.get("kind", "")) != "attachment"
			or int(ref.get("player", -1)) != player_idx
			or str(ref.get("slot", "")) != source_slot
			or str(ref.get("attachment_type", "")) != "energy"
			or index < 0
			or index >= source.energy_card_ids.size()
			or seen_indices.has(index)
			or str(source.energy_card_ids[index]) != str(ref.get("card_id", ""))
			or not energy_commands.energy_matches(
				str(ref.get("card_id", "")), str(data.get("energy_type", "any")))
		):
			return VMResult.fail("选择的能量已不存在。")
		seen_indices[index] = true
		refs.append(ref)
	return energy_commands.request_relocation_targets(
		state,
		stack,
		player_idx,
		source_slot,
		refs,
		bool(data.get("same_target", false)),
	)


func continue_energy_relocate_target(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return resolve_energy_relocation(state, data, selected, events)


func continue_energy_relocate_distribution(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return resolve_energy_relocation(state, data, selected, events)


func resolve_energy_relocation(
	state: GameState,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data.get("player_idx", -1))
	if player_idx < 0 or player_idx > 1:
		return VMResult.fail("能量来源玩家无效。")
	var player := state.get_player(player_idx)
	var source_slot := str(data.get("source_slot", ""))
	var source := player.get_pokemon(source_slot)
	if source == null:
		return VMResult.fail("能量来源已失效。")
	var refs: Array = data.get("attachment_refs", [])
	if refs.is_empty() or refs.size() != selected.size():
		return VMResult.fail("能量转移数量无效。")
	var seen_indices: Dictionary = {}
	var plan: Array[Dictionary] = []
	var forced_slot := ""
	if bool(data.get("same_target", false)) and not selected.is_empty():
		forced_slot = str(selected[0].get("value", {}).get("slot", ""))
	var per_target: Dictionary = {}
	var max_per_target := int(data.get("max_per_target", refs.size()))
	for index in range(refs.size()):
		if not refs[index] is Dictionary:
			return VMResult.fail("能量引用无效。")
		var ref: Dictionary = refs[index]
		var source_index := int(ref.get("index", -1))
		var card_id := str(ref.get("card_id", ""))
		var option_value: Dictionary = selected[index].get("value", {})
		var selected_target_slot := str(option_value.get("slot", ""))
		var target_slot := forced_slot if not forced_slot.is_empty() else selected_target_slot
		var target := player.get_pokemon(target_slot)
		if (
			str(ref.get("kind", "")) != "attachment"
			or int(ref.get("player", -1)) != player_idx
			or str(ref.get("slot", "")) != source_slot
			or str(ref.get("attachment_type", "")) != "energy"
			or source_index < 0
			or source_index >= source.energy_card_ids.size()
			or seen_indices.has(source_index)
			or str(source.energy_card_ids[source_index]) != card_id
			or target == null
			or target_slot == source_slot
			or (not forced_slot.is_empty() and selected_target_slot != forced_slot)
			or int(option_value.get("player", player_idx)) != player_idx
			or str(option_value.get("card_id", target.card_id)) != target.card_id
			or int(per_target.get(target_slot, 0)) >= max_per_target
		):
			return VMResult.fail("能量转移引用已失效。")
		seen_indices[source_index] = true
		per_target[target_slot] = int(per_target.get(target_slot, 0)) + 1
		plan.append({
			"card_id": card_id,
			"source_index": source_index,
			"target_slot": target_slot,
		})
	var removal_order := plan.duplicate(true)
	removal_order.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left["source_index"]) > int(right["source_index"])
	)
	for row in removal_order:
		source.energy_card_ids.remove_at(int(row["source_index"]))
	for row in plan:
		var target := player.get_pokemon(str(row["target_slot"]))
		var target_index := target.energy_card_ids.size()
		target.energy_card_ids.append(str(row["card_id"]))
		events.append({
			"event_type": "energy_attached",
			"actor": player_idx,
			"card_id": str(row["card_id"]),
			"source": {
				"player": player_idx,
				"slot": source_slot,
				"attachment_type": "energy",
				"index": int(row["source_index"]),
			},
			"target": {
				"player": player_idx,
				"slot": str(row["target_slot"]),
				"attachment_type": "energy",
				"index": target_index,
			},
			"data": {
				"player": player_idx,
				"slot": str(row["target_slot"]),
				"card_id": str(row["card_id"]),
				"source_slot": source_slot,
				"source_index": int(row["source_index"]),
				"target_index": target_index,
			},
		})
	return VMResult.ok("转附了%d张能量。" % plan.size())


func continue_detached_energy_distribution(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return resolve_detached_energy_distribution(state, data, selected, events)


func resolve_detached_energy_distribution(
	state: GameState,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var player := state.get_player(player_idx)
	var card_ids: Array = data.get("card_ids", [])
	var source_indices: Array = data.get("source_indices", [])
	var max_per_target := int(data.get("max_per_target", 99))
	var per_target: Dictionary = {}
	for index in range(min(card_ids.size(), selected.size())):
		var target_slot := str(selected[index].get("value", {}).get("slot", ""))
		if int(per_target.get(target_slot, 0)) >= max_per_target:
			continue
		var target := player.get_pokemon(target_slot)
		if target == null:
			continue
		var card_id := str(card_ids[index])
		var source_index := (
			int(source_indices[index]) if index < source_indices.size() else -1
		)
		var target_index := target.energy_card_ids.size()
		target.energy_card_ids.append(card_id)
		per_target[target_slot] = int(per_target.get(target_slot, 0)) + 1
		events.append({
			"event_type": "energy_attached",
			"actor": player_idx,
			"card_id": card_id,
			"source": {"player": player_idx, "zone": "deck", "index": source_index},
			"target": {
				"player": player_idx,
				"slot": target_slot,
				"attachment_type": "energy",
				"index": target_index,
			},
			"data": {
				"player": player_idx,
				"slot": target_slot,
				"card_id": card_id,
				"source_zone": "deck",
				"source_index": source_index,
				"target_index": target_index,
			},
		})
	return VMResult.ok()
