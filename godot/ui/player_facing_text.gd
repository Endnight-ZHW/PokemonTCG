class_name PlayerFacingText
extends RefCounted

## Localize at display boundaries. Native result keys and protocol error codes
## remain unchanged for journals, networking and diagnostics.
const MESSAGES := {
	"action_applied": "操作已完成。", "choice_applied": "选择已结算。",
	"applied": "操作已完成。", "action applied": "操作已完成。", "choice applied": "选择已结算。",
	"match_created": "对局已开始。", "scenario_loaded": "局面已载入。",
	"action_cancelled": "已取消该操作。", "player_surrendered": "已认输，对局结束。",
	"not_started": "对局尚未开始。", "pending_choice": "请先完成当前选择。",
	"duplicate_action": "该操作已经处理，请勿重复提交。",
	"duplicate_choice": "该选择已经处理，请勿重复提交。",
	"stale_revision": "局面已更新，请重新选择操作。", "stale_choice": "选择内容已更新，请重新选择。",
	"illegal_action": "当前无法执行该操作，请检查使用条件。",
	"invalid_choice": "该选项当前不可用，请重新选择。", "choice_count": "选择数量不符合要求。",
	"invalid_actor": "当前不是该玩家的行动时机。", "game_over": "对局已结束。",
	"invalid_schema": "操作信息无效，请重新选择。", "invalid_setup_stage": "请先完成当前准备步骤。",
	"invalid_deck": "牌组无效，请重新选择牌组。", "invalid_deck_size": "牌组必须包含 60 张卡牌。",
	"card_catalog_missing": "卡牌资料尚未载入，请重试。", "unknown_card": "找不到对应的卡牌资料。",
	"native_rules_unavailable": "规则服务暂不可用，请重新进入对局。",
	"invalid_native_state": "局面数据无效，请重新进入对局。",
	"native_rule_error": "该操作未能完成，请重新选择。",
	"invalid_payload": "收到的数据无效，请重新连接。", "invalid_message": "收到的消息无效，请重新连接。",
	"protocol_mismatch": "双方游戏版本不兼容，请更新后重试。",
	"rules_options_mismatch": "双方规则设置不一致，请重新加入房间。",
	"room_not_found": "房间不存在，请检查房间码。", "room_full": "房间已满。",
	"connection_failed": "连接失败，请检查网络后重试。", "connection_lost": "连接已中断，正在尝试恢复。",
	"connection_timeout": "连接超时，请重试。", "remote_error": "联机操作未能完成，请重试。",
	"invalid_session": "对局会话已失效，请重新加入。", "not_connected": "尚未连接到房间。",
	"not_your_turn": "请等待你的回合。", "invalid_target": "该目标当前不可选择。",
	"bench_full": "备战区已满。", "insufficient_energy": "所需能量不足。",
}

static func message(value: String, is_error: bool = false) -> String:
	var clean := value.strip_edges()
	var key := clean.to_lower().trim_suffix(".")
	if MESSAGES.has(key): return MESSAGES[key]
	# Future machine keys get a readable fallback instead of leaking identifiers.
	# Do not rewrite Chinese sentences, player names, URLs or product acronyms.
	if "_" in key and key == clean and key.to_utf8_buffer().size() == key.length() and key.is_valid_identifier():
		if not is_error and key.ends_with("_applied"): return "操作已完成。"
		return "操作未能完成，请重试。" if is_error else "操作状态已更新。"
	return value
