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
	events.append(VMZoneHelpers.discard_event(player_idx, "hand", discarded_cards, hand_size))
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
	for energy_id in source.energy_card_ids:
		if "Fighting" in catalog.provides_energy(energy_id):
			player.discard.append(energy_id)
			discarded += 1
		else:
			kept.append(energy_id)
	source.energy_card_ids = kept
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
	for card_id in exposed:
		if catalog.is_energy(card_id):
			player.discard.append(card_id)
			energies += 1
		else:
			player.deck.append(card_id)
	rng.shuffle(player.deck)
	events.append({"event_type": "deck_shuffled", "data": {"player": player_idx}})
	return damage.deal_attack_or_effect_damage(
		state, stack, player_idx, 1 - player_idx, "active",
		energies * int(params.get("damage_per", 0)), events)
