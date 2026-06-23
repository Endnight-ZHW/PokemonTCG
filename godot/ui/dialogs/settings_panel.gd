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


func configure() -> void:
	_resolve_nodes()
	master_volume_slider.value = AppSettings.master_volume
	music_volume_slider.value = AppSettings.music_volume
	sfx_volume_slider.value = AppSettings.sfx_volume
	muted_toggle.button_pressed = AppSettings.muted
	reduced_motion_toggle.button_pressed = AppSettings.reduced_motion
	_fill_option(
		animation_mode_option,
		[
			["电影化", "cinematic"],
			["标准", "standard"],
			["快速", "fast"],
			["减少动画", "reduced"],
		],
		AppSettings.animation_mode,
	)
	_fill_option(
		quality_profile_option,
		[["自动", "auto"], ["高", "high"], ["中", "medium"], ["低", "low"]],
		AppSettings.quality_profile,
	)
	card_cache_option.clear()
	for cache_size in [12, 24, 48]:
		card_cache_option.add_item("%d 张卡图" % cache_size)
		card_cache_option.set_item_metadata(
			card_cache_option.item_count - 1,
			cache_size,
		)
		if cache_size == AppSettings.card_cache_size:
			card_cache_option.select(card_cache_option.item_count - 1)


func _resolve_nodes() -> void:
	master_volume_slider = get_node(
		"MasterVolumeRow/MasterVolumeSlider"
	) as HSlider
	music_volume_slider = get_node("MusicVolumeRow/MusicVolumeSlider") as HSlider
	sfx_volume_slider = get_node("SFXVolumeRow/SFXVolumeSlider") as HSlider
	muted_toggle = get_node("MutedToggle") as CheckButton
	reduced_motion_toggle = get_node("ReducedMotionToggle") as CheckButton
	animation_mode_option = get_node(
		"AnimationModeRow/AnimationModeOption"
	) as OptionButton
	quality_profile_option = get_node(
		"QualityProfileRow/QualityProfileOption"
	) as OptionButton
	card_cache_option = get_node("CardCacheRow/CardCacheOption") as OptionButton


func _fill_option(
	option: OptionButton,
	rows: Array,
	selected_value: Variant,
) -> void:
	option.clear()
	for row in rows:
		option.add_item(str(row[0]))
		option.set_item_metadata(option.item_count - 1, row[1])
		if row[1] == selected_value:
			option.select(option.item_count - 1)


func request_save() -> void:
	var animation_mode := str(
		animation_mode_option.get_item_metadata(animation_mode_option.selected)
	)
	if reduced_motion_toggle.button_pressed:
		animation_mode = "reduced"
	save_requested.emit({
		"master_volume": float(master_volume_slider.value),
		"music_volume": float(music_volume_slider.value),
		"sfx_volume": float(sfx_volume_slider.value),
		"muted": muted_toggle.button_pressed,
		"reduced_motion": reduced_motion_toggle.button_pressed,
		"animation_mode": animation_mode,
		"quality_profile": str(
			quality_profile_option.get_item_metadata(quality_profile_option.selected)
		),
		"card_cache_size": int(
			card_cache_option.get_item_metadata(card_cache_option.selected)
		),
	})
