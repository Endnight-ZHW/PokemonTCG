class_name BattleGuidanceModel
extends RefCounted

## Presentation only: consumes public choices and legal action groups. Never
## reads the private resolution stack or predicts the next rules decision.
static func target_prompt(action: GameAction) -> String:
	if action == null:
		return "请选择发光标记的合法目标"
	return str({
		"PLAY_BASIC": "请选择发光的空位，放置这只基础宝可梦",
		"ATTACH_ENERGY": "请选择一只要赋能的己方宝可梦",
		"EVOLVE": "请选择一只可进化为此卡的己方宝可梦",
		"RETREAT": "请选择一只备战宝可梦替换上场",
		"PLAY_TRAINER": "请选择发光的目标，使用这张训练家卡",
	}.get(action.kind, "请选择发光标记的合法目标"))


static func choice_prompt(request: ChoiceView, selected_count: int = 0, prompt_override: String = "") -> String:
	if request == null:
		return ""
	if request.request_type == "select_prize":
		return "请选择一张奖励卡加入手牌 · 点击己方发光的卡背"
	var prompt := (prompt_override if not prompt_override.is_empty() else request.prompt).replace("奖赏卡", "奖励卡").replace("附能", "赋能")
	if request.max_select > 1:
		var required := "%d" % request.min_select if request.min_select == request.max_select else "%d–%d" % [request.min_select, request.max_select]
		return "%s · 已选 %d，需选 %s 项" % [prompt, selected_count, required]
	return prompt


static func resolve(
	state: GameState, viewer: int, source: String, groups: Array[Dictionary],
	group_key: String, request: ChoiceView, selected_count: int,
	busy_message: String, disabled_reason: String, ai_thinking: bool,
	choice_prompt_override: String = "",
) -> Dictionary:
	var result := {"text": "选择发光卡牌，再点击操作按钮", "tone": "normal", "can_cancel": false, "can_back": false}
	if state == null:
		result.text = "正在载入对局"
		return result
	if state.is_terminal():
		result.text = "对局已结束"
		return result
	if not busy_message.is_empty():
		result.text = busy_message
		result.tone = "waiting"
		return result
	if request != null:
		result.text = choice_prompt(request, selected_count, choice_prompt_override) if request.player == viewer else "等待对手完成选择"
		result.tone = "required" if request.player == viewer else "waiting"
		result.can_cancel = request.player == viewer and request.can_cancel
		return result
	if not source.is_empty():
		result.can_cancel = true
		if not group_key.is_empty():
			for group in groups:
				if str(group.get("key", "")) == group_key and not group.get("actions", []).is_empty():
					result.text = target_prompt(group.actions[0] as GameAction)
					result.tone = "target"
					result.can_back = true
					return result
		if groups.is_empty():
			result.text = disabled_reason
			return result
		result.text = "请选择卡牌旁的操作按钮"
		return result
	if not state.pending_promotions.is_empty():
		result.text = "请选择备战宝可梦，点击「设为战斗宝可梦」" if int(state.pending_promotions[0]) == viewer else "等待对手选择新的战斗宝可梦"
		result.tone = "required" if int(state.pending_promotions[0]) == viewer else "waiting"
		return result
	if ai_thinking or (state.phase == "SETUP" and state.setup_actor_idx in [0, 1] and state.setup_actor_idx != viewer) or (state.phase != "SETUP" and state.active_player_idx != viewer):
		result.text = "等待对手完成准备" if state.phase == "SETUP" else "等待对手行动"
		result.tone = "waiting"
	elif state.phase == "SETUP":
		result.text = "选择基础宝可梦，点击「放置」设置战斗宝可梦" if state.get_player(viewer).active == null else "可继续放置备战宝可梦，或点击「完成准备」"
		result.tone = "required"
	elif state.phase != "MAIN":
		result.text = "正在抽牌" if state.phase == "DRAW" else "正在结算效果，请稍候"
		result.tone = "waiting"
	return result
