class_name VMActionAvailability
extends RefCounted

var catalog: CardCatalog
var validator: RulesValidator
var availability: VMAvailability
var attack_settlement: VMAttackSettlement


func _init(
	p_catalog: CardCatalog,
	p_validator: RulesValidator,
	p_availability: VMAvailability,
	p_attack_settlement: VMAttackSettlement,
) -> void:
	catalog = p_catalog
	validator = p_validator
	availability = p_availability
	attack_settlement = p_attack_settlement


func legal_actions(
	state: GameState,
	actor: int,
	validate_effects: bool = true,
	apply_action_for_simulation: Callable = Callable(),
) -> Array[GameAction]:
	var actions: Array[GameAction] = []
	if actor not in [0, 1]:
		return actions
	if state.resolution_stack.get("pending_request") is Dictionary:
		return actions
	if not state.pending_promotions.is_empty():
		if actor != int(state.pending_promotions[0]):
			return actions
		var promote_player := state.get_player(actor)
		for bench_idx in range(promote_player.bench.size()):
			var pokemon: PokemonState = promote_player.bench[bench_idx]
			if pokemon:
				actions.append(GameAction.create(
					"PROMOTE",
					{},
					actor,
					null,
					EntityRef.new(
						"pokemon", actor, "", "bench_%d" % bench_idx,
						-1, "", pokemon.card_id),
					"",
					state.revision,
				))
		return actions
	if state.phase == "SETUP":
		return setup_actions(state, actor)
	if state.phase == "ATTACK":
		if state.active_player_idx == actor:
			actions.append(GameAction.create(
				"END_TURN", {}, actor, null, null, "", state.revision))
		return actions
	if state.phase != "MAIN" or state.active_player_idx != actor:
		return actions

	var player := state.get_player(actor)
	var empty_slots: Array[String] = []
	for index in range(player.bench.size()):
		if player.bench[index] == null:
			empty_slots.append("bench_%d" % index)
	# Candidate generation is pure, so one board projection can be shared by all
	# physical hand sources and the Ability pass. Rebuilding the row dictionaries
	# for every Energy/Evolution/Tool duplicated allocation work on the query hot
	# path without providing any additional validation.
	var pokemon_rows := player.get_all_pokemon()

	for hand_idx in range(player.hand.size()):
		var card_id := player.hand[hand_idx]
		var source := EntityRef.new("card", actor, "hand", "", hand_idx, "", card_id)
		# CardCatalog's type predicates are all projections of these same frozen
		# fields. Classify once per physical card instead of repeating up to seven
		# supertype/subtype cache lookups through the elif chain.
		var card: Dictionary = catalog.get_card(card_id)
		var supertype := str(card.get("supertype", ""))
		var subtypes: Array = card.get("subtypes", [])
		if supertype == "Pokémon" and "Basic" in subtypes:
			for target_slot in empty_slots:
				_add_action(actions, GameAction.create(
					"PLAY_BASIC",
					{},
					actor,
					source,
					EntityRef.new("slot", actor, "", target_slot),
					"",
					state.revision,
				))
		elif supertype == "Pokémon" and (
			"Stage 1" in subtypes or "Stage 2" in subtypes
		):
			for row in pokemon_rows:
				var pokemon: PokemonState = row["pokemon"]
				var slot := str(row["slot"])
				if pokemon:
					_add_action(actions, GameAction.create(
						"EVOLVE",
						{},
						actor,
						source,
						EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
						"",
						state.revision,
					))
		elif supertype == "Energy":
			for row in pokemon_rows:
				var pokemon: PokemonState = row["pokemon"]
				var slot := str(row["slot"])
				if pokemon:
					_add_action(actions, GameAction.create(
						"ATTACH_ENERGY",
						{},
						actor,
						source,
						EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
						"",
						state.revision,
					))
		elif supertype == "Trainer" and "Tool" in subtypes:
			for row in pokemon_rows:
				var pokemon: PokemonState = row["pokemon"]
				var slot := str(row["slot"])
				if pokemon:
					_add_action(actions, GameAction.create(
						"PLAY_TRAINER",
						{},
						actor,
						source,
						EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
						"",
						state.revision,
					))
		elif supertype == "Trainer":
			var trainer_action := GameAction.create(
				"PLAY_TRAINER", {}, actor, source, null, "", state.revision)
			_add_action(actions, trainer_action)

	for row in pokemon_rows:
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var slot := str(row["slot"])
		for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
			var ability: Dictionary = ability_value
			var ability_name := str(ability.get("name", ""))
			var ability_action := GameAction.create(
				"USE_ABILITY",
				{"ability_name": ability_name},
				actor,
				EntityRef.new("pokemon", actor, "", slot, -1, "", pokemon.card_id),
				null,
				"",
				state.revision,
			)
			_add_action(actions, ability_action)

	# Some Abilities explicitly originate from the discard pile. Keep the
	# physical discard index in both the action slot and EntityRef so duplicate
	# copies remain distinguishable and stale actions are rejected safely.
	if player.hand.is_empty() and player.find_empty_bench_slot() >= 0:
		for discard_index in range(player.discard.size()):
			var discard_card_id := str(player.discard[discard_index])
			for ability_value in catalog.get_card(discard_card_id).get("abilities", []):
				var ability: Dictionary = ability_value
				var effects := _ability_runtime_effects(ability)
				var is_discard_ability := false
				for effect_value in effects:
					if str(Dictionary(effect_value).get("op", "")) == "discard_then_revive":
						is_discard_ability = true
						break
				if not is_discard_ability:
					continue
				_add_action(actions, GameAction.create(
					"USE_ABILITY",
					{"ability_name": str(ability.get("name", ""))},
					actor,
					EntityRef.new(
						"card", actor, "discard", "", discard_index, "", discard_card_id),
					null,
					"",
					state.revision,
				))

	if not state.stadium_card_id.is_empty():
		var stadium_action := GameAction.create(
			"USE_STADIUM",
			{},
			actor,
			EntityRef.new(
				"card", actor, "stadium", "", 0, "",
				state.stadium_card_id),
			null,
			"",
			state.revision,
		)
		_add_action(actions, stadium_action)

	for bench_idx in range(player.bench.size()):
		var bench_pokemon: PokemonState = player.bench[bench_idx]
		if bench_pokemon == null:
			continue
		if validator.can_start_retreat(state, actor, bench_idx).is_empty():
			_add_action(actions, GameAction.create(
				"RETREAT",
				{},
				actor,
				EntityRef.new(
					"pokemon", actor, "", "active", -1, "", player.active.card_id),
				EntityRef.new(
					"pokemon", actor, "", "bench_%d" % bench_idx,
					-1, "", bench_pokemon.card_id),
				"",
				state.revision,
			))

	if player.active:
		var attacks: Array = catalog.get_card(player.active.card_id).get("attacks", [])
		for attack_idx in range(attacks.size()):
			if validator.can_attack(state, actor, attack_idx).is_empty():
				var attack_action := GameAction.create(
					"DECLARE_ATTACK",
					{"attack_index": attack_idx},
					actor,
					EntityRef.new("pokemon", actor, "", "active", -1, "", player.active.card_id),
					null,
					"",
					state.revision,
				)
				_add_action(actions, attack_action)
	_add_action(actions, GameAction.create(
		"END_TURN", {}, actor, null, null, "", state.revision))
	return actions


func setup_actions(state: GameState, actor: int) -> Array[GameAction]:
	var actions: Array[GameAction] = []
	if actor != state.setup_actor_idx:
		return actions
	if state.setup_stage not in [
		GameState.SETUP_INITIAL_PLACEMENT,
		GameState.SETUP_BONUS_PLACEMENT,
	]:
		return actions
	if (
		state.setup_stage == GameState.SETUP_INITIAL_PLACEMENT
		and state.setup_ready[actor]
	):
		return actions
	var player := state.get_player(actor)
	for hand_idx in range(player.hand.size()):
		var card_id := player.hand[hand_idx]
		if not catalog.is_basic_pokemon(card_id):
			continue
		if (
			state.setup_stage == GameState.SETUP_BONUS_PLACEMENT
			and card_id not in state.setup_bonus_card_ids[actor]
		):
			continue
		var source := EntityRef.new("card", actor, "hand", "", hand_idx, "", card_id)
		if (
			state.setup_stage == GameState.SETUP_INITIAL_PLACEMENT
			and player.active == null
		):
			actions.append(GameAction.create(
				"PLAY_BASIC",
				{},
				actor,
				source,
				EntityRef.new("slot", actor, "", "active"),
				"",
				state.revision,
			))
		elif player.active != null:
			for bench_idx in range(player.bench.size()):
				if player.bench[bench_idx] == null:
					var slot := "bench_%d" % bench_idx
					actions.append(GameAction.create(
						"PLAY_BASIC",
						{},
						actor,
						source,
						EntityRef.new("slot", actor, "", slot),
						"",
						state.revision,
					))
	if (
		state.setup_stage == GameState.SETUP_BONUS_PLACEMENT
		or player.active != null
	):
		actions.append(GameAction.create(
			"SETUP_DONE", {}, actor, null, null, "", state.revision))
	return actions


func action_cost_error(
	state: GameState,
	action: GameAction,
	actor: int,
) -> String:
	var result := action_cost_preflight(state, action, actor)
	return "" if bool(result.get("ok", false)) and bool(
		result.get("legal", false)) else str(result.get("message", "无法支付代价。"))


func action_cost_preflight(
	state: GameState,
	action: GameAction,
	actor: int,
) -> Dictionary:
	if action.action != "PLAY_TRAINER":
		return _target_preflight_ok(true)
	var player := state.get_player(actor)
	var hand_idx := (
		action.source.index
		if action.source != null
		and action.source.kind == "card"
		and action.source.zone == "hand"
		else -1
	)
	if hand_idx < 0 or hand_idx >= player.hand.size():
		return _target_preflight_ok(true)
	var effects: Array = _trainer_runtime_effects(str(player.hand[hand_idx]))
	if effects.is_empty():
		return _target_preflight_ok(true)
	var preflight := availability.preflight_costs(
		state, actor, effects, hand_idx, "trainer")
	if not bool(preflight.get("ok", false)):
		return {
			"ok": false,
			"legal": false,
			"code": str(preflight.get("error_code", "vm_error")),
			"error_code": str(preflight.get("error_code", "vm_error")),
			"message": str(preflight.get("message", "VM 代价预检失败。")),
			"contract_error": true,
		}
	if not bool(preflight.get("legal", false)):
		return {
			"ok": true,
			"legal": false,
			"code": "cost_not_payable",
			"error_code": "cost_not_payable",
			"message": "无法支付代价。",
			"contract_error": false,
		}
	return _target_preflight_ok(true)


func action_target_preflight(
	state: GameState,
	action: GameAction,
	actor: int,
) -> Dictionary:
	var effects: Array = []
	var source_slot := "active"
	var exclude_hand_index := -1
	var execution_context := ""
	var illegal_message := "没有合法目标，不能使用。"
	match action.action:
		"PLAY_TRAINER":
			execution_context = "trainer"
			var player := state.get_player(actor)
			var hand_idx := (
				action.source.index
				if action.source != null
				and action.source.kind == "card"
				and action.source.zone == "hand"
				else -1
			)
			if hand_idx < 0 or hand_idx >= player.hand.size():
				return _target_preflight_ok(true)
			effects = _trainer_runtime_effects(str(player.hand[hand_idx]))
			source_slot = action.target.slot if action.target != null else "active"
			if source_slot.is_empty():
				source_slot = "active"
			exclude_hand_index = hand_idx
		"USE_ABILITY":
			execution_context = "ability"
			var slot := (
				"discard_%d" % action.source.index
				if action.source != null and action.source.kind == "card"
				else action.source.slot if action.source != null else ""
			)
			var ability_card_id := ""
			if slot.begins_with("discard_"):
				var discard_index := slot.trim_prefix("discard_").to_int()
				if discard_index < 0 or discard_index >= state.get_player(actor).discard.size():
					return _target_preflight_ok(true)
				ability_card_id = str(state.get_player(actor).discard[discard_index])
			else:
				var pokemon := state.get_player(actor).get_pokemon(slot)
				if pokemon == null:
					return _target_preflight_ok(true)
				ability_card_id = pokemon.card_id
			var ability_name := str(action.payload.get("ability_name", "")).to_lower()
			for ability_value in catalog.get_card(ability_card_id).get("abilities", []):
				var ability: Dictionary = ability_value
				if str(ability.get("name", "")).to_lower() == ability_name:
					effects = _ability_runtime_effects(ability)
					break
			source_slot = slot
			illegal_message = "没有合法目标，不能使用该特性。"
		"USE_STADIUM":
			execution_context = "trainer"
			if state.stadium_card_id.is_empty():
				return _target_preflight_ok(true)
			effects = _trainer_runtime_effects(state.stadium_card_id)
			illegal_message = "没有合法目标，不能使用竞技场。"
		"DECLARE_ATTACK":
			execution_context = "attack"
			var attacker := state.get_player(actor).active
			if attacker == null:
				return _target_preflight_ok(true)
			var attack_idx := int(action.payload.get("attack_index", -1))
			var attacks: Array = catalog.get_card(attacker.card_id).get("attacks", [])
			if attack_idx < 0 or attack_idx >= attacks.size():
				return _target_preflight_ok(true)
			var attack: Dictionary = attacks[attack_idx]
			if int(attack.get("damage", 0)) > 0 and state.get_player(1 - actor).active != null:
				return _target_preflight_ok(true)
			effects = attack_settlement.attack_runtime_effects(attack)
			illegal_message = "没有合法目标，不能使用该招式。"
		_:
			return _target_preflight_ok(true)
	if effects.is_empty():
		return _target_preflight_ok(true)
	var preflight := availability.preflight_effects(
		state,
		actor,
		effects,
		source_slot,
		exclude_hand_index,
		0,
		execution_context,
	)
	if not bool(preflight.get("ok", false)):
		return {
			"ok": false,
			"legal": false,
			"code": str(preflight.get("error_code", "vm_error")),
			"error_code": str(preflight.get("error_code", "vm_error")),
			"message": str(preflight.get("message", "VM 预检失败。")),
			"contract_error": true,
		}
	if not bool(preflight.get("legal", false)):
		return {
			"ok": true,
			"legal": false,
			"code": "no_legal_target",
			"error_code": "no_legal_target",
			"message": illegal_message,
			"contract_error": false,
		}
	return _target_preflight_ok(true)


static func _target_preflight_ok(legal: bool) -> Dictionary:
	return {
		"ok": true,
		"legal": legal,
		"code": "" if legal else "no_legal_target",
		"error_code": "" if legal else "no_legal_target",
		"message": "",
		"contract_error": false,
	}


func action_target_availability_error(
	state: GameState,
	action: GameAction,
	actor: int,
) -> String:
	var result := action_target_preflight(state, action, actor)
	return "" if bool(result.get("ok", false)) and bool(
		result.get("legal", false)) else str(result.get("message", "没有合法目标，不能使用。"))


func validate_action_references(
	state: GameState,
	action: GameAction,
	validate_shape: bool = true,
) -> String:
	for ref in [action.source, action.target]:
		if ref == null:
			continue
		if validate_shape:
			var shape_error: String = ref.validation_error()
			if not shape_error.is_empty():
				return shape_error
		if ref.kind == "card":
			if ref.zone == "stadium":
				if (
					ref.index != 0
					or state.stadium_card_id != ref.card_id
				):
					return "竞技场引用内容已变化。"
				continue
			var zone: Variant = _zone(state.get_player(ref.player), ref.zone)
			if zone == null:
				return "卡牌引用区域无效。"
			if ref.index < 0 or ref.index >= zone.size():
				return "卡牌引用位置已变化。"
			if zone[ref.index] != ref.card_id:
				return "卡牌引用内容已变化。"
		elif ref.kind == "pokemon":
			var pokemon := state.get_player(ref.player).get_pokemon(ref.slot)
			if pokemon == null:
				return "宝可梦引用位置已变化。"
			if pokemon.card_id != ref.card_id:
				return "宝可梦引用内容已变化。"
		elif ref.kind == "slot":
			# Slot refs intentionally remain valid whether the destination is empty;
			# the action-specific preflight decides the required occupancy.
			continue
		elif ref.kind == "attachment":
			var owner := state.get_player(ref.player)
			var attached_to := owner.get_pokemon(ref.slot)
			if attached_to == null:
				return "附件引用所属宝可梦已变化。"
			if ref.attachment_type == "energy":
				if (
					ref.index < 0
					or ref.index >= attached_to.energy_card_ids.size()
					or attached_to.energy_card_ids[ref.index] != ref.card_id
				):
					return "能量附件引用已变化。"
			elif (
				ref.attachment_type != "tool"
				or ref.index != 0
				or attached_to.attached_tool_id != ref.card_id
			):
				return "道具附件引用已变化。"
		else:
			return "未知实体引用类型。"
	return _action_reference_semantics_error(action)


func _action_reference_semantics_error(action: GameAction) -> String:
	var source := action.source
	var target := action.target
	match action.kind:
		"PLAY_BASIC":
			if not _is_owned_card_ref(source, action.actor, "hand"):
				return "基础宝可梦来源必须是行动玩家手牌。"
			if not _is_owned_slot_ref(target, action.actor):
				return "基础宝可梦目标必须是行动玩家场上槽位。"
		"EVOLVE", "ATTACH_ENERGY":
			if not _is_owned_card_ref(source, action.actor, "hand"):
				return "动作来源必须是行动玩家手牌。"
			if not _is_owned_pokemon_ref(target, action.actor):
				return "动作目标必须是行动玩家的宝可梦。"
		"PLAY_TRAINER":
			if not _is_owned_card_ref(source, action.actor, "hand"):
				return "训练家卡来源必须是行动玩家手牌。"
			if target != null and not _is_owned_pokemon_ref(target, action.actor):
				return "训练家卡目标必须是行动玩家的宝可梦。"
		"USE_ABILITY":
			if source.kind == "pokemon":
				if not _is_owned_pokemon_ref(source, action.actor):
					return "特性来源必须是行动玩家的宝可梦。"
			elif not _is_owned_card_ref(source, action.actor, "discard"):
				return "弃牌区特性来源必须是行动玩家的弃牌。"
		"USE_STADIUM":
			if (
				source.kind != "card"
				or source.zone != "stadium"
				or source.player != action.actor
			):
				return "竞技场动作必须绑定当前竞技场卡。"
		"RETREAT":
			if (
				not _is_owned_pokemon_ref(source, action.actor)
				or source.slot != "active"
			):
				return "撤退来源必须是行动玩家的战斗宝可梦。"
			if (
				not _is_owned_pokemon_ref(target, action.actor)
				or not target.slot.begins_with("bench_")
			):
				return "撤退目标必须是行动玩家的备战宝可梦。"
		"DECLARE_ATTACK":
			if (
				not _is_owned_pokemon_ref(source, action.actor)
				or source.slot != "active"
			):
				return "攻击来源必须是行动玩家的战斗宝可梦。"
		"PROMOTE":
			if (
				not _is_owned_pokemon_ref(target, action.actor)
				or not target.slot.begins_with("bench_")
			):
				return "晋升目标必须是行动玩家的备战宝可梦。"
	return ""


static func _is_owned_card_ref(ref: EntityRef, actor: int, zone: String) -> bool:
	return ref != null and ref.kind == "card" and ref.player == actor and ref.zone == zone


static func _is_owned_pokemon_ref(ref: EntityRef, actor: int) -> bool:
	return ref != null and ref.kind == "pokemon" and ref.player == actor


static func _is_owned_slot_ref(ref: EntityRef, actor: int) -> bool:
	return ref != null and ref.kind == "slot" and ref.player == actor


func _trainer_runtime_effects(card_id: String) -> Array:
	return VMRuntimeEffects.strict_trainer_effects(catalog.get_card(card_id), "trainer:%s" % card_id)


func _ability_runtime_effects(ability: Dictionary) -> Array:
	return VMRuntimeEffects.strict_ability_effects(ability)


func _zone(player: PlayerState, zone_name: String) -> Variant:
	match zone_name:
		"hand":
			return player.hand
		"discard":
			return player.discard
		"prizes":
			return player.prizes
		_:
			return null


func _add_action(
	actions: Array[GameAction],
	action: GameAction,
) -> void:
	# Candidate generation follows physical sources/targets, so duplicates are
	# collapsed centrally by LegalActionGroup. Avoid serializing every candidate
	# merely to de-duplicate this internal seed list.
	actions.append(action)
