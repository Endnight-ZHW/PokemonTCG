class_name VMPromotionSettlement
extends RefCounted

var attack_settlement: VMAttackSettlement
var turn_settlement: VMTurnSettlement


func _init(
	p_attack_settlement: VMAttackSettlement = null,
	p_turn_settlement: VMTurnSettlement = null,
) -> void:
	attack_settlement = p_attack_settlement
	turn_settlement = p_turn_settlement


func apply_promotion(
	state: GameState,
	actor: int,
	bench_idx: int,
	rng: PortableRandomSource,
) -> StepResult:
	if state.pending_promotions.is_empty() or int(state.pending_promotions[0]) != actor:
		return StepResult.new(
			false,
			"当前没有该玩家的晋升请求。",
			null,
			[],
			state.winner,
			false,
			"invalid_promotion",
		)
	var player := state.get_player(actor)
	if not player.promote_from_bench(bench_idx):
		return StepResult.new(
			false,
			"晋升目标无效。",
			null,
			[],
			state.winner,
			false,
			"invalid_promotion_target",
		)
	state.pending_promotions.pop_front()
	var events: Array[Dictionary] = [{
		"event_type": "promoted",
		"data": {"player": actor, "bench_idx": bench_idx},
	}]
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	if (
		state.pending_promotions.is_empty()
		and bool(stack.context.get("finish_attack_after_promotions", false))
	):
		if attack_settlement == null:
			return StepResult.new(
				false,
				"晋升结算缺少攻击结算器。",
				null,
				events,
				state.winner,
				false,
				"missing_attack_settlement",
			)
		var attack_actor := int(stack.context.get("actor", state.active_player_idx))
		if not stack.has_finalize_attack_turn_frame():
			stack.push_finalize_attack_turn(attack_actor)
		stack.context.erase("finish_attack_after_promotions")
		var end_step := attack_settlement.resolve_attack_turn_frame(state, stack, rng)
		end_step.events = events + end_step.events
		return end_step
	if state.pending_promotions.is_empty() and state.phase == "DRAW":
		if turn_settlement == null:
			return StepResult.new(
				false,
				"晋升结算缺少回合状态机。",
				null,
				events,
				state.winner,
				false,
				"missing_turn_settlement",
			)
		var begin := turn_settlement.begin_turn(state, rng)
		begin.events = events + begin.events
		return begin
	return StepResult.new(true, "晋升完成。", null, events)
