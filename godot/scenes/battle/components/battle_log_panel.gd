class_name BattleLogPanel
extends PanelContainer

@onready var log_label: RichTextLabel = %LogLabel


func _ready() -> void:
	_resolve_nodes()
	_configure_label()
	resized.connect(_on_resized)


func update_entries(action_log: Array) -> void:
	_resolve_nodes()
	_configure_label()
	if action_log.is_empty():
		visible = true
		log_label.text = "尚无行动记录"
		log_label.tooltip_text = "行动记录会按发生顺序显示在这里"
		return
	var lines: Array[String] = []
	for index in range(action_log.size()):
		var entry_text := _localize_entry(_entry_text(action_log[index]))
		# An empty entry used to render as a category-only row, which looked like
		# an extra blank line when the neighbouring message wrapped.
		if entry_text.is_empty():
			continue
		var category := _entry_category(entry_text)
		lines.append("[color=%s][%s][/color] %s" % [
			_category_color(category),
			category,
			_escape_bbcode(entry_text),
		])
	visible = true
	log_label.text = "\n".join(lines) if not lines.is_empty() else "尚无行动记录"
	log_label.tooltip_text = ""
	call_deferred("_scroll_to_latest")


func _resolve_nodes() -> void:
	log_label = get_node("Content/LogLabel") as RichTextLabel


func _configure_label() -> void:
	if log_label == null:
		return
	log_label.bbcode_enabled = true
	# Chinese battle messages read more evenly when they can wrap at any
	# character. Word-smart wrapping can reserve a whole visual line for an
	# internal ASCII token such as `bench_0`.
	log_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	log_label.scroll_active = true
	log_label.scroll_following = true


func _single_line(value: String) -> String:
	var result := value.replace("\r\n", " ").replace("\n", " ").replace("\r", " ").strip_edges()
	while "  " in result:
		result = result.replace("  ", " ")
	return result


func _localize_entry(value: String) -> String:
	var result := value
	# Replace phrases first so the shorter ASCII-token pass cannot leave a
	# half-localized player name. Card-name suffixes such as "ex" are not part
	# of this map and therefore remain untouched.
	result = result.replace("Challenge AI", "挑战电脑")
	result = result.replace("Deep AI", "深度搜索电脑")
	for bench_index in range(10):
		result = _replace_ascii_token(
			result,
			"bench_%d" % bench_index,
			"备战区%d" % (bench_index + 1),
		)
	var labels := {
		"active": "战斗区",
		"Challenge": "挑战",
		"Deep": "深度搜索",
		"AI": "电脑",
		"CPU": "电脑",
		"KO": "气绝",
		"SETUP": "准备阶段",
		"DRAW": "抽牌阶段",
		"MAIN": "主要阶段",
		"ATTACK": "攻击阶段",
		"POKEMON_CHECKUP": "宝可梦检查",
		"GAME_OVER": "对局结束",
		"PLAY_BASIC": "放置基础宝可梦",
		"EVOLVE": "进化",
		"ATTACH_ENERGY": "附着能量",
		"PLAY_TRAINER": "使用训练家卡",
		"USE_ABILITY": "使用特性",
		"USE_STADIUM": "发动竞技场",
		"RETREAT": "撤退",
		"DECLARE_ATTACK": "使用招式",
		"PROMOTE": "晋升",
		"END_TURN": "结束回合",
		"SETUP_DONE": "完成准备",
		"POISONED": "中毒",
		"BURNED": "灼伤",
		"ASLEEP": "睡眠",
		"PARALYZED": "麻痹",
		"CONFUSED": "混乱",
	}
	for token: String in labels:
		result = _replace_ascii_token(result, token, str(labels[token]))
	return result


func _replace_ascii_token(value: String, token: String, replacement: String) -> String:
	var result := value
	var search_from := 0
	while search_from < result.length():
		var token_index := result.findn(token, search_from)
		if token_index < 0:
			break
		var before_index := token_index - 1
		var after_index := token_index + token.length()
		var before_is_identifier := (
			before_index >= 0 and _is_ascii_identifier_character(result.unicode_at(before_index))
		)
		var after_is_identifier := (
			after_index < result.length()
			and _is_ascii_identifier_character(result.unicode_at(after_index))
		)
		if before_is_identifier or after_is_identifier:
			search_from = token_index + token.length()
			continue
		result = result.substr(0, token_index) + replacement + result.substr(after_index)
		search_from = token_index + replacement.length()
	return result


func _is_ascii_identifier_character(codepoint: int) -> bool:
	return (
		(codepoint >= 48 and codepoint <= 57)
		or (codepoint >= 65 and codepoint <= 90)
		or (codepoint >= 97 and codepoint <= 122)
		or codepoint == 95
	)


func _entry_text(entry: Variant) -> String:
	if entry is Dictionary:
		var row := entry as Dictionary
		for key in ["message", "text", "label"]:
			var value := _single_line(str(row.get(key, "")))
			if not value.is_empty():
				return value
	return _single_line(str(entry))


func _escape_bbcode(text: String) -> String:
	# Logs originate in rule data; full-width brackets keep arbitrary card names
	# from being interpreted as presentation markup.
	return text.replace("[", "［").replace("]", "］")


func _entry_category(text: String) -> String:
	if "回合" in text or "准备" in text or "游戏开始" in text:
		return "回合"
	if "奖品" in text:
		return "奖品"
	if "气绝" in text or "KO" in text:
		return "气绝"
	if "伤害" in text or "受到" in text:
		return "伤害"
	if (
		"中毒" in text or "灼伤" in text or "睡眠" in text
		or "麻痹" in text or "混乱" in text
	):
		return "状态"
	if "附着" in text and "能量" in text:
		return "附能"
	if "撤退" in text:
		return "撤退"
	return "行动"


func _category_color(category: String) -> String:
	return {
		"回合": "#f4c84a",
		"奖品": "#c38cff",
		"气绝": "#ff6b7a",
		"伤害": "#ff9a62",
		"状态": "#e88cff",
		"附能": "#62d7ff",
		"撤退": "#84d6b2",
	}.get(category, "#9eb0ca")


func _scroll_to_latest() -> void:
	if log_label == null:
		return
	log_label.scroll_to_line(maxi(0, log_label.get_line_count() - 1))


func _on_resized() -> void:
	if visible and log_label and not log_label.text.is_empty():
		call_deferred("_scroll_to_latest")
