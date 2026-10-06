class_name AudioUIBinder
extends Node

var owner_control: Control
var director: AudioDirector


func configure(owner_node: Control, audio: AudioDirector) -> void:
	owner_control = owner_node
	director = audio
	_bind_tree(owner_control)
	get_tree().node_added.connect(_on_node_added)


func _bind_tree(node: Node) -> void:
	_on_node_added(node)
	for child in node.get_children():
		_bind_tree(child)


func _on_node_added(node: Node) -> void:
	if not owner_control.is_ancestor_of(node) or node.has_meta("audio_bound"):
		return
	# Real match previews own their own director; the outer workbench must not
	# capture their controls or play a second sound on the same activation.
	var ancestor := node.get_parent()
	while ancestor != null and ancestor != owner_control:
		var nested_audio := ancestor.get_node_or_null("AudioDirector")
		if nested_audio is AudioDirector and nested_audio != director:
			return
		ancestor = ancestor.get_parent()
	if node is OptionButton:
		node.set_meta("audio_bound", true)
		(node as OptionButton).item_selected.connect(func(_index: int) -> void: director.play_ui("select"))
	elif node is BaseButton:
		node.set_meta("audio_bound", true)
		(node as BaseButton).pressed.connect(func() -> void:
			if is_instance_valid(node):
				director.play_ui(_cue_for(node as BaseButton)))
	elif node is Slider:
		node.set_meta("audio_bound", true)
		(node as Slider).drag_ended.connect(func(changed: bool) -> void:
			if changed:
				director.play_ui("select"))


func _cue_for(button: BaseButton) -> String:
	if button.has_meta("audio_cue"):
		return str(button.get_meta("audio_cue"))
	var label := str(button.name).to_lower()
	if button is Button:
		label += " " + (button as Button).text.to_lower()
	for word in ["cancel", "back", "close", "返回", "取消", "关闭"]:
		if word in label:
			return "back"
	for word in ["confirm", "start", "save", "确认", "开始", "保存", "继续"]:
		if word in label:
			return "confirm"
	if button.toggle_mode:
		return "toggle"
	return "select"
