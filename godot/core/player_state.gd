class_name PlayerState
extends RefCounted

const MAX_BENCH_SIZE := 5

var name: String
var deck: Array[String] = []
var hand: Array[String] = []
var discard: Array[String] = []
var prizes: Array[String] = []
var active: PokemonState
var bench: Array = [null, null, null, null, null]
var supporter_played_this_turn := false
var energy_attached_this_turn := false
var retreated_this_turn := false
var stadium_played_this_turn := false
var stadium_used_this_turn := false
var healed_this_turn := false
var vstar_power_used := false
var was_ko_by_attack := false


func _init(p_name: String = "玩家") -> void:
	name = p_name


func draw_cards(count: int) -> Array[String]:
	var drawn: Array[String] = []
	for _index in range(count):
		if deck.is_empty():
			break
		drawn.append(deck.pop_back())
	hand.append_array(drawn)
	return drawn


func set_prizes(count: int = 6) -> void:
	for _index in range(count):
		if deck.is_empty():
			break
		prizes.append(deck.pop_back())


func take_prize(index: int = 0) -> String:
	if prizes.is_empty() or index < 0 or index >= prizes.size():
		return ""
	var card_id: String = prizes.pop_at(index)
	hand.append(card_id)
	return card_id


func bench_count() -> int:
	var count := 0
	for pokemon in bench:
		if pokemon is PokemonState:
			count += 1
	return count


func find_empty_bench_slot() -> int:
	for index in range(bench.size()):
		if bench[index] == null:
			return index
	return -1


func get_pokemon(slot: String) -> PokemonState:
	if slot == "active":
		return active
	if slot.begins_with("bench_"):
		var index := slot.trim_prefix("bench_").to_int()
		if index >= 0 and index < bench.size():
			return bench[index]
	return null


func get_all_pokemon() -> Array[Dictionary]:
	var result: Array[Dictionary] = [{"slot": "active", "pokemon": active}]
	for index in range(bench.size()):
		result.append({"slot": "bench_%d" % index, "pokemon": bench[index]})
	return result


func place_active(card_id: String) -> PokemonState:
	active = PokemonState.new(card_id)
	return active


func place_bench(card_id: String, index: int = -1) -> PokemonState:
	if index < 0:
		index = find_empty_bench_slot()
	if index < 0 or index >= MAX_BENCH_SIZE or bench[index] != null:
		return null
	var pokemon := PokemonState.new(card_id)
	bench[index] = pokemon
	return pokemon


func promote_from_bench(index: int) -> bool:
	if active != null or index < 0 or index >= bench.size() or bench[index] == null:
		return false
	active = bench[index]
	bench[index] = null
	return true


func switch_active_to_bench(index: int) -> bool:
	if active == null or index < 0 or index >= bench.size() or bench[index] == null:
		return false
	active.status_conditions.clear()
	var previous_active := active
	active = bench[index]
	bench[index] = previous_active
	return true


func has_any_pokemon_in_play() -> bool:
	return active != null or bench_count() > 0


func discard_from_hand(indices: Array[int]) -> Array[String]:
	var sorted_indices := indices.duplicate()
	sorted_indices.sort()
	sorted_indices.reverse()
	var discarded: Array[String] = []
	for index in sorted_indices:
		if index >= 0 and index < hand.size():
			var card_id: String = hand.pop_at(index)
			discard.append(card_id)
			discarded.append(card_id)
	return discarded


func discard_entire_hand() -> int:
	var count := hand.size()
	discard.append_array(hand)
	hand.clear()
	return count


func reset_turn_flags() -> void:
	supporter_played_this_turn = false
	energy_attached_this_turn = false
	retreated_this_turn = false
	stadium_played_this_turn = false
	stadium_used_this_turn = false
	healed_this_turn = false
	for row in get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon:
			pokemon.placed_this_turn = false
			pokemon.can_evolve_this_turn = true
			pokemon.used_abilities.clear()
			pokemon.damage_prevented_next_turn = false
			pokemon.all_prevented_next_turn = false


func to_dict() -> Dictionary:
	var bench_payload: Array = []
	for pokemon in bench:
		bench_payload.append(pokemon.to_dict() if pokemon is PokemonState else null)
	return {
		"name": name,
		"deck": deck.duplicate(),
		"hand": hand.duplicate(),
		"discard": discard.duplicate(),
		"prizes": prizes.duplicate(),
		"active": active.to_dict() if active else null,
		"bench": bench_payload,
		"supporter_played_this_turn": supporter_played_this_turn,
		"energy_attached_this_turn": energy_attached_this_turn,
		"retreated_this_turn": retreated_this_turn,
		"stadium_played_this_turn": stadium_played_this_turn,
		"stadium_used_this_turn": stadium_used_this_turn,
		"healed_this_turn": healed_this_turn,
		"vstar_power_used": vstar_power_used,
		"was_ko_by_attack": was_ko_by_attack,
	}


static func from_dict(data: Dictionary) -> PlayerState:
	var result := PlayerState.new(str(data.get("name", "玩家")))
	result.deck.assign(data.get("deck", []))
	result.hand.assign(data.get("hand", []))
	result.discard.assign(data.get("discard", []))
	result.prizes.assign(data.get("prizes", []))
	if data.get("active") is Dictionary:
		result.active = PokemonState.from_dict(data["active"])
	result.bench = []
	for pokemon in data.get("bench", []):
		result.bench.append(PokemonState.from_dict(pokemon) if pokemon is Dictionary else null)
	while result.bench.size() < MAX_BENCH_SIZE:
		result.bench.append(null)
	result.bench.resize(MAX_BENCH_SIZE)
	result.supporter_played_this_turn = bool(data.get("supporter_played_this_turn", false))
	result.energy_attached_this_turn = bool(data.get("energy_attached_this_turn", false))
	result.retreated_this_turn = bool(data.get("retreated_this_turn", false))
	result.stadium_played_this_turn = bool(data.get("stadium_played_this_turn", false))
	result.stadium_used_this_turn = bool(data.get("stadium_used_this_turn", false))
	result.healed_this_turn = bool(data.get("healed_this_turn", false))
	result.vstar_power_used = bool(data.get("vstar_power_used", false))
	result.was_ko_by_attack = bool(data.get("was_ko_by_attack", false))
	return result
