class_name SettingsPanel
extends VBoxContainer

signal save_requested(values: Dictionary)

@onready var master_volume_slider: HSlider = %MasterVolumeSlider
@onready var music_volume_slider: HSlider = %MusicVolumeSlider
@onready var sfx_volume_slider: HSlider = %SFXVolumeSlider
@onready var muted_toggle: CheckButton = %MutedToggle
@onready var reduced_motion_toggle: CheckButton = %ReducedMotionToggle
@onready var animation_mode_option: OptionButton = %AnimationModeOption
@onready var quality_profile_option: OptionButton = %QualityProfileOption
@onready var card_cache_option: OptionButton = %CardCacheOption
@onready var master_volume_value: Label = %MasterVolumeValue
@onready var music_volume_value: Label = %MusicVolumeValue
@onready var sfx_volume_value: Label = %SFXVolumeValue
@onready var reset_defaults_button: Button = %ResetDefaultsButton

var _syncing_motion_controls := false


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()


func configure() -> void:
	_resolve_nodes()
	_ensure_connections()
	_apply_form_values({
		"master_volume": AppSettings.master_volume,
		"music_volume": AppSettings.music_volume,
		"sfx_volume": AppSettings.sfx_volume,
		"muted": AppSettings.muted,
		"reduced_motion": AppSettings.reduced_motion,
		"animation_mode": AppSettings.animation_mode,
		"quality_profile": AppSettings.quality_profile,
		"card_cache_size": AppSettings.card_cache_size,
	})


func reset_form_to_defaults() -> void:
	_apply_form_values({
		"master_volume": AppSettings.DEFAULT_MASTER_VOLUME,
		"music_volume": AppSettings.DEFAULT_MUSIC_VOLUME,
		"sfx_volume": AppSettings.DEFAULT_SFX_VOLUME,
		"muted": AppSettings.DEFAULT_MUTED,
		"reduced_motion": AppSettings.DEFAULT_REDUCED_MOTION,
		"animation_mode": AppSettings.DEFAULT_ANIMATION_MODE,
		"quality_profile": AppSettings.DEFAULT_QUALITY_PROFILE,
		"card_cache_size": AppSettings.DEFAULT_CARD_CACHE_SIZE,
	})


func initial_focus_control() -> Control:
	return master_volume_slider


func values() -> Dictionary:
	var animation_mode := str(
		animation_mode_option.get_item_metadata(animation_mode_option.selected)
	)
	var reduced_motion := animation_mode == "reduced"
	return {
		"master_volume": float(master_volume_slider.value),
		"music_volume": float(music_volume_slider.value),
		"sfx_volume": float(sfx_volume_slider.value),
		"muted": muted_toggle.button_pressed,
		"reduced_motion": reduced_motion,
		"animation_mode": animation_mode,
		"quality_profile": str(
			quality_profile_option.get_item_metadata(quality_profile_option.selected)
		),
		"card_cache_size": int(
			card_cache_option.get_item_metadata(card_cache_option.selected)
		),
	}


func request_save() -> void:
	save_requested.emit(values())


func _resolve_nodes() -> void:
	master_volume_slider = %MasterVolumeSlider
	music_volume_slider = %MusicVolumeSlider
	sfx_volume_slider = %SFXVolumeSlider
	muted_toggle = %MutedToggle
	reduced_motion_toggle = %ReducedMotionToggle
	animation_mode_option = %AnimationModeOption
	quality_profile_option = %QualityProfileOption
	card_cache_option = %CardCacheOption
	master_volume_value = %MasterVolumeValue
	music_volume_value = %MusicVolumeValue
	sfx_volume_value = %SFXVolumeValue
	reset_defaults_button = %ResetDefaultsButton
	master_volume_slider.accessibility_name = "主音量"
	music_volume_slider.accessibility_name = "音乐音量"
	sfx_volume_slider.accessibility_name = "音效音量"
	muted_toggle.accessibility_name = "静音全部声音"
	reduced_motion_toggle.accessibility_name = "减少动画"
	animation_mode_option.accessibility_name = "动画模式"
	quality_profile_option.accessibility_name = "画质方案"
	card_cache_option.accessibility_name = "卡图缓存数量"
	reset_defaults_button.accessibility_name = "恢复设置默认值"


func _ensure_connections() -> void:
	var slider_rows := [
		[master_volume_slider, master_volume_value],
		[music_volume_slider, music_volume_value],
		[sfx_volume_slider, sfx_volume_value],
	]
	for row in slider_rows:
		var slider := row[0] as HSlider
		var label := row[1] as Label
		var callback := _update_percent_label.bind(label)
		if not slider.value_changed.is_connected(callback):
			slider.value_changed.connect(callback)
	if not reset_defaults_button.pressed.is_connected(reset_form_to_defaults):
		reset_defaults_button.pressed.connect(reset_form_to_defaults)
	if not reduced_motion_toggle.toggled.is_connected(_on_reduced_motion_toggled):
		reduced_motion_toggle.toggled.connect(_on_reduced_motion_toggled)
	if not animation_mode_option.item_selected.is_connected(_on_animation_mode_selected):
		animation_mode_option.item_selected.connect(_on_animation_mode_selected)


func _apply_form_values(source: Dictionary) -> void:
	_syncing_motion_controls = true
	master_volume_slider.value = float(source.get("master_volume", 0.8))
	music_volume_slider.value = float(source.get("music_volume", 0.55))
	sfx_volume_slider.value = float(source.get("sfx_volume", 0.8))
	muted_toggle.button_pressed = bool(source.get("muted", false))
	var requested_animation_mode := str(source.get("animation_mode", "cinematic"))
	var reduced_motion := (
		bool(source.get("reduced_motion", false))
		or requested_animation_mode == "reduced"
	)
	reduced_motion_toggle.set_pressed_no_signal(reduced_motion)
	_fill_option(
		animation_mode_option,
		[
			["电影化", "cinematic"],
			["标准", "standard"],
			["快速", "fast"],
			["减少动画", "reduced"],
		],
		"reduced" if reduced_motion else requested_animation_mode,
	)
	_fill_option(
		quality_profile_option,
		[["自动", "auto"], ["高", "high"], ["中", "medium"], ["低", "low"]],
		str(source.get("quality_profile", "auto")),
	)
	card_cache_option.clear()
	var desired_cache := int(source.get("card_cache_size", 24))
	for cache_size in [12, 24, 48]:
		card_cache_option.add_item("%d 张卡图" % cache_size)
		card_cache_option.set_item_metadata(card_cache_option.item_count - 1, cache_size)
		if cache_size == desired_cache:
			card_cache_option.select(card_cache_option.item_count - 1)
	_update_percent_label(master_volume_slider.value, master_volume_value)
	_update_percent_label(music_volume_slider.value, music_volume_value)
	_update_percent_label(sfx_volume_slider.value, sfx_volume_value)
	_syncing_motion_controls = false


func _fill_option(option: OptionButton, rows: Array, selected_value: Variant) -> void:
	option.clear()
	for row in rows:
		option.add_item(str(row[0]))
		option.set_item_metadata(option.item_count - 1, row[1])
		if row[1] == selected_value:
			option.select(option.item_count - 1)


func _update_percent_label(value: float, label: Label) -> void:
	label.text = "%d%%" % roundi(value * 100.0)


func _on_reduced_motion_toggled(enabled: bool) -> void:
	if _syncing_motion_controls:
		return
	_syncing_motion_controls = true
	if enabled:
		_select_option_metadata(animation_mode_option, "reduced")
	elif str(animation_mode_option.get_item_metadata(animation_mode_option.selected)) == "reduced":
		_select_option_metadata(animation_mode_option, "standard")
	_syncing_motion_controls = false


func _on_animation_mode_selected(_index: int) -> void:
	if _syncing_motion_controls or animation_mode_option.item_count == 0:
		return
	_syncing_motion_controls = true
	reduced_motion_toggle.set_pressed_no_signal(
		str(animation_mode_option.get_item_metadata(animation_mode_option.selected))
		== "reduced"
	)
	_syncing_motion_controls = false


func _select_option_metadata(option: OptionButton, metadata: Variant) -> void:
	for index in range(option.item_count):
		if option.get_item_metadata(index) == metadata:
			option.select(index)
			return
