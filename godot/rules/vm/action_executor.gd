class_name VMActionExecutor
extends RefCounted

var catalog: CardCatalog
var validator: RulesValidator
var availability: VMAvailability
var effect_engine: EffectEngine
var turn_settlement: VMTurnSettlement


func _init(
	p_catalog: CardCatalog,
	p_validator: RulesValidator,
	p_availability: VMAvailability,
	p_effect_engine: EffectEngine,
	p_turn_settlement: VMTurnSettlement,
) -> void:
	catalog = p_catalog
	validator = p_validator
	availability = p_availability
	effect_engine = p_effect_engine
	turn_settlement = p_turn_settlement


func setup_done(
	state: GameState,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	if state.phase != "SETUP":
		return _error("当前不在准备阶段。", "invalid_phase", state)
	if state.get_player(actor).active == null:
		return _error("必须先放置战斗宝可梦。", "missing_active", state)
	state.setup_ready[actor] = true
	if not state.setup_ready[0] or not state.setup_ready[1]:
		return StepResult.new(true, "玩家%d已完成准备。" % (actor + 1))
	state.set_prizes()
	state.active_player_idx = state.first_player_idx
	state.phase = "DRAW"
	state.log_action("准备完成。")
	return turn_settlement.begin_turn(state, rng)


func play_basic(
	state: GameState,
	actor: int,
	hand_idx: int,
	target: String,
	rng: PortableRandomSource,
) -> StepResult:
	var player := state.get_player(actor)
	if hand_idx < 0 or hand_idx >= player.hand.size():
		return _error("无效的手牌序号。", "invalid_hand_index", state)
	var card_id := player.hand[hand_idx]
	var reason := validator.can_play_basic(state, actor, card_id, target)
	if not reason.is_empty():
		return _error(reason, "illegal_basic", state)
	player.hand.remove_at(hand_idx)
	var pokemon := (
		player.place_active(card_id)
		if target == "active"
		else player.place_bench(card_id, target.trim_prefix("bench_").to_int())
	)
	if pokemon == null:
		return _error("无法放置宝可梦。", "placement_failed", state)
	pokemon.placed_this_turn = true
	state.log_action("%s将%s放置到%s。" % [player.name, catalog.card_name(card_id), target])
	var placement_event := {
		"event_type": "pokemon_played",
		"actor": actor,
		"card_id": card_id,
		"source": {
			"player": actor,
			"zone": "hand",
			"index": hand_idx,
		},
		"target": {
			"player": actor,
			"slot": target,
		},
		"data": {
			"player": actor,
			"slot": target,
			"card_id": card_id,
		},
	}
	var effects: Array = []
	for ability_value in catalog.get_card(card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("trigger", "")) == "on_enter_play":
			effects.append_array(_ability_runtime_effects(ability))
	if effects.is_empty():
		return StepResult.new(true, "宝可梦已放置。", null, [placement_event])
	var step := run_effects(state, effects, actor, target, rng)
	step.events.push_front(placement_event)
	return step


func evolve(
	state: GameState,
	actor: int,
	hand_idx: int,
	slot: String,
	rng: PortableRandomSource,
) -> StepResult:
	var player := state.get_player(actor)
	if hand_idx < 0 or hand_idx >= player.hand.size():
		return _error("无效的手牌序号。", "invalid_hand_index", state)
	var card_id := player.hand[hand_idx]
	var reason := validator.can_evolve(state, actor, slot, card_id)
	if not reason.is_empty():
		return _error(reason, "illegal_evolution", state)
	var pokemon := player.get_pokemon(slot)
	player.hand.remove_at(hand_idx)
	pokemon.evolution_stack_ids.append(pokemon.card_id)
	pokemon.card_id = card_id
	pokemon.status_conditions.clear()
	pokemon.can_evolve_this_turn = false
	state.log_action("%s进化为%s。" % [player.name, catalog.card_name(card_id)])
	var evolution_event := {
		"event_type": "pokemon_evolved",
		"actor": actor,
		"card_id": card_id,
		"source": {
			"player": actor,
			"zone": "hand",
			"index": hand_idx,
		},
		"target": {
			"player": actor,
			"slot": slot,
		},
		"data": {
			"player": actor,
			"slot": slot,
			"card_id": card_id,
		},
	}
	var effects: Array = []
	for ability_value in catalog.get_card(card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("trigger", "")) == "on_enter_play":
			effects.append_array(_ability_runtime_effects(ability))
	if effects.is_empty():
		return StepResult.new(true, "进化完成。", null, [evolution_event])
	var step := run_effects(state, effects, actor, slot, rng)
	step.events.push_front(evolution_event)
	return step


func attach_energy(
	state: GameState,
	actor: int,
	hand_idx: int,
	target_slot: String,
) -> StepResult:
	var player := state.get_player(actor)
	if hand_idx < 0 or hand_idx >= player.hand.size():
		return _error("无效的手牌序号。", "invalid_hand_index", state)
	var card_id := player.hand[hand_idx]
	var reason := validator.can_attach_energy(state, actor, card_id, target_slot)
	if not reason.is_empty():
		return _error(reason, "illegal_energy_attachment", state)
	var target := player.get_pokemon(target_slot)
	player.hand.remove_at(hand_idx)
	target.energy_card_ids.append(card_id)
	player.energy_attached_this_turn = true
	var events: Array[Dictionary] = [{
		"event_type": "energy_attached",
		"actor": actor,
		"card_id": card_id,
		"source": {"player": actor, "zone": "hand", "index": hand_idx},
		"target": {"player": actor, "slot": target_slot},
		"data": {"player": actor, "slot": target_slot, "card_id": card_id},
	}]
	var trigger_commands_to_resolve: Array[Dictionary] = []
	effect_engine.runtime.trigger_commands.collect_on_attach_commands(
		card_id,
		actor,
		target_slot,
		"hand",
		trigger_commands_to_resolve,
	)
	var trigger_result := effect_engine.runtime.trigger_commands.resolve_commands(
		state,
		actor,
		trigger_commands_to_resolve,
		events,
	)
	if not bool(trigger_result.get("success", false)):
		return _error(
			str(trigger_result.get("message", "触发命令结算失败。")),
			str(trigger_result.get("error_code", "trigger_command_failed")),
			state,
		)
	state.log_action("%s附着了%s。" % [player.name, catalog.card_name(card_id)])
	return StepResult.new(true, "能量已附着。", null, events)


func play_trainer(
	state: GameState,
	actor: int,
	hand_idx: int,
	target_slot: String,
	rng: PortableRandomSource,
) -> StepResult:
	var player := state.get_player(actor)
	if hand_idx < 0 or hand_idx >= player.hand.size():
		return _error("无效的手牌序号。", "invalid_hand_index", state)
	var card_id := player.hand[hand_idx]
	if not catalog.is_trainer(card_id):
		return _error("该卡不是训练家卡。", "not_trainer", state)
	var reason := validator.can_play_trainer(state, actor, card_id, target_slot)
	if not reason.is_empty():
		return _error(reason, "illegal_trainer", state)
	if card_id == "sv1-153" and player.hand.size() - 1 < 2:
		return _error("高级球需要丢弃2张其他手牌。", "cost_not_payable", state)
	player.hand.remove_at(hand_idx)
	if catalog.is_tool(card_id):
		var tool_target := player.get_pokemon(target_slot)
		tool_target.attached_tool_id = card_id
		return StepResult.new(true, "宝可梦道具已附着。", null, [{
			"event_type": "tool_attached",
			"actor": actor,
			"card_id": card_id,
			"source": {"player": actor, "zone": "hand", "index": hand_idx},
			"target": {"player": actor, "slot": target_slot},
			"data": {
				"player": actor,
				"slot": target_slot,
				"card_id": card_id,
			},
		}])
	var play_event := {
		"event_type": "trainer_played",
		"actor": actor,
		"card_id": card_id,
		"source": {"player": actor, "zone": "hand", "index": hand_idx},
		"target": {"player": actor, "zone": "discard"},
		"data": {"player": actor, "card_id": card_id},
	}
	var play_events: Array[Dictionary] = []
	if catalog.is_stadium(card_id):
		if not state.stadium_card_id.is_empty():
			var replaced_stadium_id := state.stadium_card_id
			var discard_index := player.discard.size()
			player.discard.append(replaced_stadium_id)
			play_events.append(VMZoneHelpers.card_moved_event(
				actor,
				[replaced_stadium_id],
				{"player": actor, "zone": "stadium", "index": 0},
				{"player": actor, "zone": "discard", "index": discard_index},
			))
		state.stadium_card_id = card_id
		player.stadium_played_this_turn = true
		play_event["event_type"] = "stadium_changed"
		play_event["target"] = {"player": actor, "zone": "stadium"}
	else:
		player.discard.append(card_id)
		if catalog.is_supporter(card_id):
			player.supporter_played_this_turn = true
	play_events.append(play_event)
	state.log_action("%s使用了%s。" % [player.name, catalog.card_name(card_id)])
	var effects: Array = _trainer_runtime_effects(card_id)
	if effects.is_empty():
		return StepResult.new(true, "训练家卡已使用。", null, play_events)
	var step := run_effects(state, effects, actor, "active", rng)
	step.events = play_events + step.events
	return step


func use_ability(
	state: GameState,
	actor: int,
	slot: String,
	ability_name: String,
	rng: PortableRandomSource,
) -> StepResult:
	var reason := validator.can_use_ability(state, actor, slot, ability_name)
	if not reason.is_empty():
		return _error(reason, "illegal_ability", state)
	var pokemon := state.get_player(actor).get_pokemon(slot)
	for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("name", "")).to_lower() != ability_name.to_lower():
			continue
		if str(ability.get("trigger", "")) != "repeatable":
			pokemon.used_abilities.append(ability_name)
		state.log_action("%s使用特性%s。" % [catalog.card_name(pokemon.card_id), ability_name])
		return run_effects(state, _ability_runtime_effects(ability), actor, slot, rng)
	return _error("没有找到该特性。", "ability_not_found", state)


func use_stadium(
	state: GameState,
	actor: int,
	rng: PortableRandomSource,
) -> StepResult:
	if not availability.stadium_is_activatable(state):
		return _error("场上竞技场没有可发动效果。", "stadium_not_activatable", state)
	var player := state.get_player(actor)
	if player.stadium_used_this_turn:
		return _error("本回合已使用过竞技场效果。", "stadium_already_used", state)
	player.stadium_used_this_turn = true
	var effects: Array = _trainer_runtime_effects(state.stadium_card_id)
	return run_effects(state, effects, actor, "active", rng)


func retreat(
	state: GameState,
	actor: int,
	bench_idx: int,
	energy_indices: Array,
) -> StepResult:
	var reason := validator.can_retreat(state, actor, bench_idx, energy_indices)
	if not reason.is_empty():
		return _error(reason, "illegal_retreat", state)
	var player := state.get_player(actor)
	var indices: Array[int] = []
	for value in energy_indices:
		indices.append(int(value))
	var source_indices := indices.duplicate()
	source_indices.sort()
	var paid_energy_ids: Array[String] = []
	for index in source_indices:
		if index >= 0 and index < player.active.energy_card_ids.size():
			paid_energy_ids.append(player.active.energy_card_ids[index])
	var discard_start := player.discard.size()
	indices.sort()
	indices.reverse()
	for index in indices:
		player.discard.append(player.active.energy_card_ids.pop_at(index))
	player.switch_active_to_bench(bench_idx)
	player.retreated_this_turn = true
	state.log_action("%s完成撤退。" % player.name)
	var events: Array[Dictionary] = []
	if not paid_energy_ids.is_empty():
		var discard_event := VMZoneHelpers.discard_event(
			actor,
			"",
			paid_energy_ids,
			paid_energy_ids.size(),
			source_indices,
			"active",
			discard_start,
		)
		discard_event["source"]["attachment_type"] = "energy"
		events.append(discard_event)
	events.append({
		"event_type": "retreat",
		"data": {"player": actor, "bench_idx": bench_idx},
	})
	return StepResult.new(true, "撤退完成。", null, events)


func run_effects(
	state: GameState,
	effects: Array,
	actor: int,
	source_slot: String,
	rng: PortableRandomSource,
	context: Dictionary = {},
) -> StepResult:
	var stack := ResolutionStack.new()
	stack.context = context.duplicate(true)
	stack.push_effects(effects, actor, source_slot)
	return effect_engine.resolve(state, stack, rng)


func _ability_runtime_effects(ability: Dictionary) -> Array:
	return VMRuntimeEffects.strict_ability_effects(ability)


func _trainer_runtime_effects(card_id: String) -> Array:
	return VMRuntimeEffects.strict_trainer_effects(catalog.get_card(card_id), "trainer:%s" % card_id)


func _error(
	message: String,
	code: String,
	state: GameState,
) -> StepResult:
	return StepResult.new(false, message, null, [], state.winner, false, code)
