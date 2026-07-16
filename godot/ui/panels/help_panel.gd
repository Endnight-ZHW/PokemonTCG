class_name HelpPanel
extends VBoxContainer

const CATEGORIES := [
	{
		"title": "快速开始",
		"summary": "先选模式与牌组，再按照高亮提示完成准备阶段。",
		"sections": [
			{
				"title": "获胜目标",
				"rows": [
					"击倒对手宝可梦并拿完自己的奖赏卡。",
					"或让对手回合开始时无法抽牌、场上没有可继续对战的宝可梦。",
				],
			},
			{
				"title": "第一次开局",
				"rows": [
					"在准备阶段先放置一只基础宝可梦到战斗区。",
					"可以继续放置备战宝可梦，完成后确认准备。",
					"进入主要阶段后，点击卡牌即可查看当前可用操作。",
				],
			},
		],
	},
	{
		"title": "回合流程",
		"summary": "界面会用阶段提示和可用动作引导每个回合。",
		"sections": [
			{
				"title": "主要阶段",
				"rows": [
					"可以打出基础宝可梦、进化、附能、使用训练家、撤退或发动特性。",
					"每回合通常只能从手牌附加一次能量，合法目标会被高亮。",
				],
			},
			{
				"title": "攻击与检查",
				"rows": [
					"选择攻击后会结算伤害与效果，并自动结束回合。",
					"宝可梦检查会处理中毒、灼伤、睡眠等状态以及击倒。",
				],
			},
		],
	},
	{
		"title": "卡牌与区域",
		"summary": "公开信息可以查看，隐藏区域只显示规则允许的数量。",
		"sections": [
			{
				"title": "查看卡牌",
				"rows": [
					"点击卡牌会选中并显示可用操作，长按会打开完整检查器。",
					"能量、宝可梦道具、进化链和特殊状态会在检查器中集中显示。",
				],
			},
			{
				"title": "公开与隐藏区域",
				"rows": [
					"弃牌区和竞技场可以查看公开卡牌。",
					"牌库、奖赏卡和对手手牌不会泄露真实卡牌，只显示规则允许的信息。",
				],
			},
		],
	},
	{
		"title": "本地与联机",
		"summary": "不同模式共享同一套规则，只改变玩家输入和信息视角。",
		"sections": [
			{
				"title": "本地双人",
				"rows": [
					"回合交接时会先遮挡手牌，请将设备交给下一位玩家后再确认。",
					"系统返回手势会打开对局菜单，而不会直接丢失当前对局。",
				],
			},
			{
				"title": "LAN 与 Relay",
				"rows": [
					"LAN 适合同一局域网，Relay 使用 URL 与房间码跨网络连接。",
					"房主运行权威规则，挑战者只提交动作和选择。",
					"应用进入后台时会安全断开联机，避免留下失效会话。",
				],
			},
		],
	},
]

@onready var content_body: VBoxContainer = %ContentBody
@onready var category_buttons: Array[Button] = [
	%QuickStartCategory,
	%TurnCategory,
	%BoardCategory,
	%NetworkCategory,
]


func _ready() -> void:
	_resolve_nodes()
	_bind_categories()
	show_category(0)


func configure() -> void:
	_resolve_nodes()
	_bind_categories()
	show_category(0)


func show_category(index: int) -> void:
	if content_body == null or CATEGORIES.is_empty():
		return
	var resolved := clampi(index, 0, CATEGORIES.size() - 1)
	for button_index in range(category_buttons.size()):
		category_buttons[button_index].button_pressed = button_index == resolved
	_clear_content()
	var category: Dictionary = CATEGORIES[resolved]
	content_body.add_child(_label(str(category["title"]), "FrontHeadingLabel"))
	content_body.add_child(_label(str(category["summary"]), "FrontMutedLabel"))
	for section_value in category["sections"]:
		var section: Dictionary = section_value
		content_body.add_child(_label(str(section["title"]), "FrontSectionLabel"))
		for row in section["rows"]:
			content_body.add_child(_label("•  " + str(row), ""))


func _resolve_nodes() -> void:
	content_body = get_node("ContentPanel/Margin/ContentBody") as VBoxContainer
	category_buttons.assign([
		get_node("CategoryBar/QuickStartCategory") as Button,
		get_node("CategoryBar/TurnCategory") as Button,
		get_node("CategoryBar/BoardCategory") as Button,
		get_node("CategoryBar/NetworkCategory") as Button,
	])


func _bind_categories() -> void:
	var group := ButtonGroup.new()
	group.allow_unpress = false
	for index in range(category_buttons.size()):
		var button := category_buttons[index]
		button.button_group = group
		var callback := show_category.bind(index)
		if not button.pressed.is_connected(callback):
			button.pressed.connect(callback)


func _label(text_value: String, variation: String) -> Label:
	var label := Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not variation.is_empty():
		label.theme_type_variation = StringName(variation)
	return label


func _clear_content() -> void:
	for child in content_body.get_children():
		content_body.remove_child(child)
		child.queue_free()
