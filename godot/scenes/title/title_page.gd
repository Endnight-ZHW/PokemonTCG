class_name TitlePage
extends Control

signal mode_selected(mode: String)
signal network_selected(kind: String)
signal settings_requested

@export_category("Editable Copy")
@export var game_title := "宝可梦卡牌对战"
@export var subtitle := "真实卡图 · 原生规则 · 离线 AI · 跨平台联机"

@onready var animation_player: AnimationPlayer = %AnimationPlayer


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()
	%TitleLabel.text = game_title
	%HeroSubtitle.text = subtitle
	if not AppSettings.reduced_motion:
		animation_player.play("enter")


func configure(version_text: String) -> void:
	_resolve_nodes()
	_ensure_connections()
	get_node(
		"Layout/RightCenter/TitlePanel/Margin/Content/VersionLabel"
	).text = version_text


func _resolve_nodes() -> void:
	animation_player = get_node("AnimationPlayer") as AnimationPlayer


func _ensure_connections() -> void:
	var bindings := [
		[%LocalTwoPlayerButton, mode_selected.emit.bind("local")],
		[%ChallengeAIButton, mode_selected.emit.bind("challenge")],
		[%DeepAIButton, mode_selected.emit.bind("deep")],
		[%LANButton, network_selected.emit.bind("lan")],
		[%RelayButton, network_selected.emit.bind("relay")],
		[%SettingsButton, settings_requested.emit],
	]
	for row in bindings:
		var button := row[0] as Button
		var callback := row[1] as Callable
		if not button.pressed.is_connected(callback):
			button.pressed.connect(callback)
