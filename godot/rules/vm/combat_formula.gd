class_name VMCombatFormula
extends RefCounted

var catalog: CardCatalog
var damage: VMCombatDamage


func _init(p_catalog: CardCatalog, p_damage: VMCombatDamage) -> void:
	catalog = p_catalog
	damage = p_damage


func attack_damage_formula(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var source := player.get_pokemon(source_slot)
	if source == null:
		return VMResult.fail("没有攻击来源。")
	var total := int(params.get("base", 0))
	var per_own_bench := int(params.get("per_own_bench", 0))
	if per_own_bench > 0:
		total += player.bench_count() * per_own_bench
	var per_self_energy_type := str(params.get("per_self_energy_type", ""))
	if not per_self_energy_type.is_empty():
		var energy_count := _formula_matching_energy_count(
			source, per_self_energy_type.to_lower())
		total += energy_count * int(params.get("per_energy", 0))
	var per_self_damage_counter := int(params.get("per_self_damage_counter", 0))
	if per_self_damage_counter > 0:
		total += source.damage_counters * per_self_damage_counter
	var condition_bonus: Dictionary = params.get("condition_bonus", {})
	var condition := str(condition_bonus.get("condition", ""))
	var applies := false
	var formula_opponent := state.get_player(1 - player_idx)
	match condition:
		"ko_by_attack_last_turn", "ko_by_attack_damage_last_turn":
			applies = state.had_attack_knockout_last_turn(player_idx)
		"ko_last_opponent_turn":
			applies = state.had_knockout_last_turn(player_idx)
		"own_bench_damaged":
			for bench_pokemon in player.bench:
				if bench_pokemon and bench_pokemon.damage_counters > 0:
					applies = true
					break
		"opponent_active_evolved":
			applies = formula_opponent.active != null and not catalog.is_basic_pokemon(formula_opponent.active.card_id)
		"opponent_active_damaged":
			applies = formula_opponent.active != null and formula_opponent.active.damage_counters > 0
		"own_hand_empty":
			applies = player.hand.is_empty()
	if applies:
		total += int(condition_bonus.get("bonus", 0))
	stack.context["base_damage"] = total
	if bool(params.get("ignore_weakness", false)):
		stack.context["ignore_weakness"] = true
	if bool(params.get("ignore_resistance", false)):
		stack.context["ignore_resistance"] = true
	if bool(params.get(
		"ignore_defender_damage_effects",
		params.get("ignore_defender_effects", false),
	)):
		stack.context["ignore_defender_damage_effects"] = true
	return VMResult.ok()


func deal_damage_formula_spec(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	formula_kind: String,
	args: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var opponent := state.get_player(1 - player_idx)
	var total := 0
	match formula_kind:
		"per_discard_psychic":
			var psychic_count := 0
			for card_id in player.discard:
				if catalog.is_pokemon(card_id) and "Psychic" in catalog.get_card(card_id).get("energy_types", []):
					psychic_count += 1
			total = int(args.get("base", 80)) + psychic_count * int(args.get("per_card", 10))
		"per_energy":
			var energy_count := 0
			match str(args.get("count_from", "self")):
				"opponent_active":
					energy_count = _formula_matching_energy_count(
						opponent.active, "any") if opponent.active else 0
				"all_opponent":
					for row in opponent.get_all_pokemon():
						var target_pokemon: PokemonState = row["pokemon"]
						if target_pokemon:
							energy_count += _formula_matching_energy_count(
								target_pokemon, "any")
				_:
					var energy_source := player.get_pokemon(source_slot)
					energy_count = _formula_matching_energy_count(
						energy_source, "any") if energy_source else 0
			total = int(args.get("base", 0)) + energy_count * int(args.get("per_energy", 0))
		"per_evolved":
			var evolved_count := 0
			for row in player.get_all_pokemon():
				var evolved_pokemon: PokemonState = row["pokemon"]
				if evolved_pokemon and not catalog.is_basic_pokemon(evolved_pokemon.card_id):
					evolved_count += 1
			total = evolved_count * int(args.get("per_evolved", 50))
		"per_hand_size":
			total = player.hand.size() * int(args.get("per", 0))
		"plus_bench":
			total = int(args.get("base", 0)) + player.bench_count() * int(args.get("per_bench", 0))
		"per_self_damage":
			var source := player.get_pokemon(source_slot)
			total = int(args.get("base", 0)) + (
				(source.damage_counters if source else 0) * int(args.get("per_counter", 0))
			)
		"per_self_energy", "per_self_energy_type":
			var self_source := player.get_pokemon(source_slot)
			var default_filter := "Fire" if formula_kind == "per_self_energy" else "Grass"
			var filter := str(args.get("energy_filter", args.get("energy_type", default_filter))).to_lower()
			var self_energy_count := 0
			if self_source:
				self_energy_count = _formula_matching_energy_count(
					self_source, filter)
			total = int(args.get("base", 60)) + self_energy_count * int(args.get("per_energy", 20))
		_:
			return {"_handled": false}
	var result: Dictionary = damage.deal_attack_or_effect_damage(
		state, stack, player_idx, 1 - player_idx, "active", total, events)
	result["_handled"] = true
	return result


func evaluate_formula_ast(
	state: GameState,
	player_idx: int,
	source_slot: String,
	node: Variant,
) -> Dictionary:
	var result := _eval_formula_node(state, player_idx, source_slot, node)
	if not bool(result.get("success", false)):
		return result
	return {"success": true, "value": max(0, int(result.get("value", 0)))}


func _eval_formula_node(
	state: GameState,
	player_idx: int,
	source_slot: String,
	node: Variant,
) -> Dictionary:
	if node is bool:
		return _formula_value(1 if bool(node) else 0)
	if node is int or node is float:
		return _formula_value(int(node))
	if node is String:
		return _eval_formula_variable(state, player_idx, source_slot, str(node), {})
	if not node is Dictionary:
		return _formula_error("非法公式节点。")
	var ast := Dictionary(node)
	if ast.has("const"):
		return _formula_value(int(ast.get("const", 0)))
	var op := str(ast.get("op", ast.get("type", "")))
	if op in ["const", "number"]:
		return _formula_value(int(ast.get("value", 0)))
	if op in ["add", "sum"]:
		var sum_total := 0
		for child in _formula_children(ast):
			var child_result := _eval_formula_node(state, player_idx, source_slot, child)
			if not bool(child_result.get("success", false)):
				return child_result
			sum_total += int(child_result.get("value", 0))
		return _formula_value(sum_total)
	if op in ["mul", "product"]:
		var product := 1
		for child in _formula_children(ast):
			var factor_result := _eval_formula_node(state, player_idx, source_slot, child)
			if not bool(factor_result.get("success", false)):
				return factor_result
			product *= int(factor_result.get("value", 0))
		return _formula_value(product)
	if op in ["sub", "div"]:
		var children := _formula_children(ast)
		if children.size() != 2:
			return _formula_error("公式二元运算需要两个参数。")
		var left := _eval_formula_node(state, player_idx, source_slot, children[0])
		if not bool(left.get("success", false)):
			return left
		var right := _eval_formula_node(state, player_idx, source_slot, children[1])
		if not bool(right.get("success", false)):
			return right
		if op == "sub":
			return _formula_value(int(left.get("value", 0)) - int(right.get("value", 0)))
		var divisor := int(right.get("value", 0))
		if divisor == 0:
			return _formula_error("公式除数不能为0。")
		return _formula_value(int(int(left.get("value", 0)) / divisor))
	if op == "neg":
		var neg_result := _eval_formula_node(
			state, player_idx, source_slot, ast.get("value", ast.get("expr", 0)))
		if not bool(neg_result.get("success", false)):
			return neg_result
		return _formula_value(-int(neg_result.get("value", 0)))
	if op in ["max", "min"]:
		var values: Array[int] = []
		for child in _formula_children(ast):
			var value_result := _eval_formula_node(state, player_idx, source_slot, child)
			if not bool(value_result.get("success", false)):
				return value_result
			values.append(int(value_result.get("value", 0)))
		if values.is_empty():
			return _formula_value(0)
		var selected := values[0]
		for value in values:
			selected = maxi(selected, value) if op == "max" else mini(selected, value)
		return _formula_value(selected)
	if op in ["if", "conditional"]:
		var selected: Variant = ast.get("then", ast.get("on_true", 0))
		if not condition_applies(state, player_idx, source_slot, str(ast.get("condition", ""))):
			selected = ast.get("else", ast.get("on_false", 0))
		return _eval_formula_node(state, player_idx, source_slot, selected)
	if op == "condition":
		return _formula_value(
			1 if condition_applies(state, player_idx, source_slot, str(ast.get("condition", ""))) else 0)
	return _eval_formula_variable(state, player_idx, source_slot, op, ast)


func _formula_children(ast: Dictionary) -> Array:
	for key in ["terms", "factors", "values", "args"]:
		if ast.get(key, null) is Array:
			return Array(ast[key])
	if ast.has("lhs") and ast.has("rhs"):
		return [ast["lhs"], ast["rhs"]]
	if ast.has("left") and ast.has("right"):
		return [ast["left"], ast["right"]]
	var value: Variant = ast.get("value", 0)
	return value if value is Array else [value]


func _eval_formula_variable(
	state: GameState,
	player_idx: int,
	source_slot: String,
	op: String,
	ast: Dictionary,
) -> Dictionary:
	match op:
		"hand_size":
			return _formula_value(_formula_player(state, player_idx, ast.get("player", "self")).hand.size())
		"bench_count":
			return _formula_value(_formula_player(state, player_idx, ast.get("player", "self")).bench_count())
		"energy_count":
			return _formula_energy_count(state, player_idx, source_slot, ast)
		"damage_counters":
			var pokemon := _formula_pokemon_target(state, player_idx, source_slot, ast.get("target", "self"))
			return _formula_value(pokemon.damage_counters if pokemon else 0)
		"discard_count":
			var player := _formula_player(state, player_idx, ast.get("player", "self"))
			var filter_spec := Dictionary(ast.get("filter", {}))
			var count := 0
			for card_id in player.discard:
				if _formula_card_matches(str(card_id), filter_spec):
					count += 1
			return _formula_value(count)
		"evolved_count":
			var evolved := 0
			for row in _formula_player(state, player_idx, ast.get("player", "self")).get_all_pokemon():
				var pokemon: PokemonState = row["pokemon"]
				if pokemon and not catalog.is_basic_pokemon(pokemon.card_id):
					evolved += 1
			return _formula_value(evolved)
	return _formula_error("未知公式操作: %s" % op)


func condition_applies(
	state: GameState,
	player_idx: int,
	source_slot: String,
	condition: String,
) -> bool:
	var player := state.get_player(player_idx)
	var opponent := state.get_player(1 - player_idx)
	match condition:
		"ko_by_attack_last_turn", "ko_by_attack_damage_last_turn":
			return state.had_attack_knockout_last_turn(player_idx)
		"ko_last_opponent_turn":
			return state.had_knockout_last_turn(player_idx)
		"own_bench_damaged":
			for bench_pokemon in player.bench:
				if bench_pokemon and bench_pokemon.damage_counters > 0:
					return true
			return false
		"opponent_active_evolved":
			return opponent.active != null and not catalog.is_basic_pokemon(opponent.active.card_id)
		"opponent_active_damaged":
			return opponent.active != null and opponent.active.damage_counters > 0
		"own_hand_empty":
			return player.hand.is_empty()
	return false


func _formula_player(state: GameState, player_idx: int, key: Variant) -> PlayerState:
	return state.get_player(1 - player_idx) if str(key) == "opponent" else state.get_player(player_idx)


func _formula_pokemon_target(
	state: GameState,
	player_idx: int,
	source_slot: String,
	target: Variant,
) -> PokemonState:
	var target_key := str(target)
	if target_key in ["opponent", "opponent_active"]:
		return state.get_player(1 - player_idx).active
	if target_key in ["self", "self_active", "source"]:
		var source := state.get_player(player_idx).get_pokemon(source_slot)
		return source if source else state.get_player(player_idx).active
	return null


func _formula_energy_count(
	state: GameState,
	player_idx: int,
	source_slot: String,
	ast: Dictionary,
) -> Dictionary:
	var scope := str(ast.get("scope", ast.get("target", "self")))
	var energy_type := str(ast.get("energy_type", ast.get("filter", "any"))).to_lower()
	var pokemons: Array = []
	match scope:
		"self", "self_active", "source":
			pokemons.append(_formula_pokemon_target(state, player_idx, source_slot, "self"))
		"opponent", "opponent_active":
			pokemons.append(state.get_player(1 - player_idx).active)
		"all_self", "self_all":
			for row in state.get_player(player_idx).get_all_pokemon():
				pokemons.append(row["pokemon"])
		"all_opponent", "opponent_all":
			for row in state.get_player(1 - player_idx).get_all_pokemon():
				pokemons.append(row["pokemon"])
		_:
			return _formula_error("未知能量计数范围: %s" % scope)
	var count := 0
	for pokemon in pokemons:
		if pokemon:
			count += _formula_matching_energy_count(pokemon, energy_type)
	return _formula_value(count)


func _formula_matching_energy_count(pokemon: PokemonState, energy_type: String) -> int:
	var units := EnergyView.units_for_cards(pokemon.energy_card_ids, catalog)
	if energy_type.is_empty() or energy_type == "any":
		return units.size()
	var count := 0
	for provided in units:
		if str(provided).to_lower() in [energy_type, "rainbow"]:
			count += 1
	return count


func _formula_card_matches(card_id: String, filter_spec: Dictionary) -> bool:
	var card_type := str(filter_spec.get("card_type", "")).to_lower()
	if card_type == "pokemon" and not catalog.is_pokemon(card_id):
		return false
	if card_type == "energy" and not catalog.is_energy(card_id):
		return false
	var energy_type := str(filter_spec.get("energy_type", ""))
	if not energy_type.is_empty():
		if energy_type not in catalog.get_card(card_id).get("energy_types", []):
			return false
	return true


func _formula_value(value: int) -> Dictionary:
	return {"success": true, "value": value}


func _formula_error(message: String) -> Dictionary:
	return {"success": false, "message": message}


func energy_matches(card_id: String, energy_type: String) -> bool:
	var normalized := energy_type.to_lower()
	if not catalog.is_energy(card_id):
		return false
	if normalized in ["any", "energy", ""]:
		return true
	if normalized in ["basic", "basic_energy"]:
		return catalog.is_basic_energy(card_id)
	for provided in catalog.provides_energy(card_id):
		if str(provided).to_lower() == normalized:
			return true
	return false
