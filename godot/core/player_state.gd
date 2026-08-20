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
var attack_locked_names: Dictionary = {}


func _init(p_name: String = "玩家") -> void:
	name = p_name


func bench_count() -> int:
	var count := 0
	for pokemon in bench:
		if pokemon is PokemonState:
			count += 1
	return count


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


func to_dict() -> Dictionary:
	var bench_payload: Array = []
	for pokemon in bench:
		bench_payload.append(pokemon.to_dict() if pokemon is PokemonState else null)
	var payload := {
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
	if not attack_locked_names.is_empty():
		payload["attack_locked_names"] = attack_locked_names.duplicate(true)
	return payload


func clone_state() -> PlayerState:
	var result := PlayerState.new(name)
	result.deck.assign(deck)
	result.hand.assign(hand)
	result.discard.assign(discard)
	result.prizes.assign(prizes)
	result.active = active.clone_state() if active else null
	result.bench = []
	for pokemon in bench:
		result.bench.append(pokemon.clone_state() if pokemon is PokemonState else null)
	while result.bench.size() < MAX_BENCH_SIZE:
		result.bench.append(null)
	result.bench.resize(MAX_BENCH_SIZE)
	result.supporter_played_this_turn = supporter_played_this_turn
	result.energy_attached_this_turn = energy_attached_this_turn
	result.retreated_this_turn = retreated_this_turn
	result.stadium_played_this_turn = stadium_played_this_turn
	result.stadium_used_this_turn = stadium_used_this_turn
	result.healed_this_turn = healed_this_turn
	result.vstar_power_used = vstar_power_used
	result.was_ko_by_attack = was_ko_by_attack
	result.attack_locked_names = attack_locked_names.duplicate(true)
	return result


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
	result.attack_locked_names = Dictionary(
		data.get("attack_locked_names", {})
	).duplicate(true)
	return result
