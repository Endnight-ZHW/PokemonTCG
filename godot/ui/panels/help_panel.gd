class_name HelpPanel
extends VBoxContainer


func _ready() -> void:
	configure()


func configure() -> void:
	_clear_children()
	add_theme_constant_override("separation", 12)
	add_child(_label(
		"对战目标是在规则允许的动作中击倒对手宝可梦、拿完奖品，或让对手场上没有宝可梦。",
		16,
		DesignTokens.TEXT_MUTED,
	))
	var sections := [
		{
			"title": "对局流程",
			"rows": [
				"准备阶段：双方放置战斗宝可梦，可继续放置备战宝可梦。",
				"主要阶段：打出宝可梦、进化、附能、使用训练家、撤退或发动特性。",
				"攻击后会自动结束回合。宝可梦检查会处理特殊状态和击倒。",
			],
		},
		{
			"title": "查看局面",
			"rows": [
				"点击卡牌会选中并显示可用操作。长按卡牌会打开完整检查器。",
				"弃牌区和竞技场可查看公开卡牌。牌库和奖品只显示数量。",
				"能量、道具、进化链和特殊状态会在检查器中集中显示。",
			],
		},
		{
			"title": "触控与联机",
			"rows": [
				"手牌可以点击选择，也可以拖到高亮牌位。",
				"本地双人交接时会遮挡手牌。联网时只显示自己视角可见的信息。",
				"返回键会打开对局菜单，进入后台会安全中止联机或 AI 搜索。",
			],
		},
	]
	for section in sections:
		add_child(_label(str(section["title"]), 20, DesignTokens.GOLD))
		for row in section["rows"]:
			add_child(_label("· " + str(row), 15, DesignTokens.TEXT))


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 0)
	label.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	return label


func _clear_children() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
