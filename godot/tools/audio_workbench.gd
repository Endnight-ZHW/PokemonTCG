class_name AudioWorkbench
extends VBoxContainer

signal sequence_requested
signal stop_requested

var director: AudioDirector
var categories: OptionButton
var cues: OptionButton
var variants: OptionButton
var tracks: OptionButton
var status: Label


func configure(audio: AudioDirector) -> void:
	director = audio
	var heading := Label.new()
	heading.text = "声音实验台"
	add_child(heading)
	categories = _option("AudioCategory")
	for pair in [["interface", "界面"], ["cards", "卡牌与硬币"], ["battle", "对战动作"], ["effects", "状态与反馈"], ["charge", "属性蓄力"], ["impact", "属性命中／重击"]]:
		categories.add_item(pair[1])
		categories.set_item_metadata(categories.item_count - 1, pair[0])
	cues = _option("AudioCue")
	variants = _option("AudioVariant")
	variants.add_item("自然变化")
	for index in range(3):
		variants.add_item("变体 %d" % (index + 1))
	categories.item_selected.connect(func(_index: int) -> void: _populate_cues())
	_populate_cues()
	_button("试听音效", _play_selected)
	tracks = _option("AudioMusic")
	for track in director.catalog.tracks:
		tracks.add_item(track.title)
		tracks.set_item_metadata(tracks.item_count - 1, track.id)
	_button("试听音乐／切换", func() -> void:
		director.play_music(str(tracks.get_item_metadata(tracks.selected))))
	_button("连续对战试听", sequence_requested.emit)
	_button("停止全部试听", func() -> void:
		stop_requested.emit()
		director.stop_all_short_sounds()
		director.play_music(""))
	status = Label.new()
	status.text = "选取分类与变体即可试听"
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status)
	director.cue_played.connect(func(_request: AudioCueRequest, definition: AudioCueDefinition, variant: int) -> void:
		status.text = "%s · 变体 %d" % [definition.id, variant + 1])


func _option(node_name: String) -> OptionButton:
	var option := OptionButton.new()
	option.name = node_name
	option.focus_mode = Control.FOCUS_NONE
	option.get_popup().allow_search = false
	option.custom_minimum_size.y = 48
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.clip_text = true
	# Preview controls must not add a click over the sound being auditioned.
	option.set_meta("audio_bound", true)
	add_child(option)
	return option


func _button(label: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = label
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.y = 48
	button.set_meta("audio_bound", true)
	button.pressed.connect(callback)
	add_child(button)


func _populate_cues() -> void:
	cues.clear()
	var category := str(categories.get_item_metadata(categories.selected))
	for definition in director.catalog.cues:
		if definition.category == category:
			cues.add_item(str(definition.id))
			cues.set_item_metadata(cues.item_count - 1, definition.id)


func _play_selected() -> void:
	director.cancel_scope(&"audition")
	var request := AudioCueRequest.make(cues.get_item_metadata(cues.selected), &"audition")
	request.variant = variants.selected - 1
	director.play(request)
