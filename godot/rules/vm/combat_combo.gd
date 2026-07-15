class_name VMCombatCombo
extends RefCounted

var catalog: CardCatalog
var damage: VMCombatDamage


func _init(p_catalog: CardCatalog, p_damage: VMCombatDamage) -> void:
	catalog = p_catalog
	damage = p_damage


func discard_hand_then_damage(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var discarded_cards := player.hand.duplicate()
	var hand_size := player.discard_entire_hand()
	if hand_size > 0:
		var discard_event := VMZoneHelpers.discard_event(
			player_idx, "hand", discarded_cards, hand_size, range(hand_size))
		discard_event["data"]["presentation_phase"] = "pre_hit"
		events.append(discard_event)
	var total_damage := int(params.get("base_damage", 0))
	if hand_size >= int(params.get("threshold", 5)):
		total_damage += int(params.get("bonus", 0))
	return damage.deal_attack_or_effect_damage(
		state, stack, player_idx, 1 - player_idx, "active", total_damage, events)


func discard_fighting_energy_then_damage(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var source := player.get_pokemon(source_slot)
	if source == null:
		return VMResult.fail("没有攻击来源。")
	var kept: Array[String] = []
	var discarded := 0
	var discarded_ids: Array[String] = []
	var discarded_indices: Array[int] = []
	var discard_start := player.discard.size()
	for index in range(source.energy_card_ids.size()):
		var energy_id := source.energy_card_ids[index]
		if "Fighting" in catalog.provides_energy(energy_id):
			player.discard.append(energy_id)
			discarded_ids.append(energy_id)
			discarded_indices.append(index)
			discarded += 1
		else:
			kept.append(energy_id)
	source.energy_card_ids = kept
	if not discarded_ids.is_empty():
		var discarded_event := VMZoneHelpers.discard_event(
			player_idx,
			"",
			discarded_ids,
			discarded_ids.size(),
			discarded_indices,
			source_slot,
			discard_start,
		)
		discarded_event["source"]["attachment_type"] = "energy"
		discarded_event["data"]["presentation_phase"] = "pre_hit"
		events.append(discarded_event)
	return damage.deal_attack_or_effect_damage(
		state, stack, player_idx, 1 - player_idx, "active",
		int(params.get("base", 0)) + discarded * int(params.get("per_energy", 0)),
		events)


func mill_then_damage(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	player_idx: int,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var exposed: Array[String] = []
	for _index in range(min(int(params.get("mill_count", 0)), player.deck.size())):
		exposed.append(player.deck.pop_back())
	var energies := 0
	var reveal_rows: Array[Dictionary] = []
	for card_id in exposed:
		var matched := catalog.is_energy(card_id)
		var destination_zone := "discard" if matched else "deck"
		reveal_rows.append({
			"card_id": card_id,
			"matched": matched,
			"destination": {
				"player": player_idx,
				"zone": destination_zone,
			},
		})
		if matched:
			player.discard.append(card_id)
			energies += 1
		else:
			player.deck.append(card_id)
	var damage_amount := energies * int(params.get("damage_per", 0))
	events.append({
		"event_type": "cards_revealed",
		"actor": player_idx,
		"visibility": "public",
		"source": {"player": player_idx, "zone": "deck"},
		"target": {"player": player_idx, "zone": "deck"},
		"data": {
			"player": player_idx,
			"purpose": "mill_then_damage",
			"presentation_phase": "pre_hit",
			"visibility": "public",
			"cards": reveal_rows,
			"summary": {
				"kind": "energy_damage",
				"matched_count": energies,
				"amount": damage_amount,
			},
		},
	})
	rng.shuffle(player.deck)
	events.append({"event_type": "deck_shuffled", "data": {
		"player": player_idx,
		"presentation_phase": "pre_hit",
	}})
	return damage.deal_attack_or_effect_damage(
		state, stack, player_idx, 1 - player_idx, "active",
		damage_amount, events)
