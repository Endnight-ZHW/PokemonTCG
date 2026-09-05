class_name AuxiliaryPanelPresenter
extends Node

signal click_requested
signal toast_requested(message: String, is_error: bool)
signal choice_resume_requested(context: Dictionary)
signal ai_resume_requested

var host: ModalHost
var catalog: CardCatalog
var in_battle := false
var player_names: Array[String] = []

func configure_context(p_catalog: CardCatalog, p_in_battle: bool, names: Array[String]) -> void:
	catalog = p_catalog
	in_battle = p_in_battle
	player_names.assign(names)

func _player_name_for_context(player_idx: int) -> String:
	return player_names[player_idx] if player_idx >= 0 and player_idx < player_names.size() else ""

const HELP_PANEL_SCENE := preload("res://ui/panels/help_panel.tscn")
const CARD_INSPECTOR_PANEL_SCENE := preload("res://ui/panels/card_inspector_panel.tscn")
const ZONE_INSPECTOR_PANEL_SCENE := preload("res://ui/panels/zone_inspector_panel.tscn")
const DECK_DETAIL_PANEL_SCENE := preload("res://ui/panels/deck_detail_panel.tscn")
const SETTINGS_PANEL_SCENE := preload("res://ui/dialogs/settings_panel.tscn")

func _show_help(
	resume_ai_on_close: bool = false,
	resume_choice_context: Dictionary = {},
) -> void:
	var field_choice_context := resume_choice_context
	click_requested.emit()
	host.open(
		"规则与操作帮助",
		"关闭",
		"",
		in_battle,
		ModalSpec.frontend(Vector2(900, 700)),
	)
	var panel := HELP_PANEL_SCENE.instantiate() as HelpPanel
	host.modal_body.add_child(panel)
	panel.configure()
	var resume_action := _complete_auxiliary_modal.bind(
		field_choice_context,
		(
			ai_resume_requested.emit
			if resume_ai_on_close
			else Callable()
		),
	)
	if not field_choice_context.is_empty():
		host.back_action = host.close.bind(resume_action)
	host.modal_confirm.pressed.connect(func() -> void:
		host.close(resume_action)
	, CONNECT_ONE_SHOT)

func _show_card_inspector(
	context: Dictionary,
	return_action: Callable = Callable(),
	return_label: String = "",
	resume_choice_context: Dictionary = {},
) -> void:
	var card_id := str(context.get("card_id", ""))
	if card_id.is_empty():
		return
	var field_choice_context := resume_choice_context
	click_requested.emit()
	var card := catalog.get_card(card_id)
	var title := str(card.get("name", card_id))
	var card_spec := (
		ModalSpec.battle(Vector2(860, 700), in_battle)
		if in_battle
		else ModalSpec.frontend(Vector2(860, 700))
	)
	if return_action.is_valid():
		card_spec.stack_behavior = ModalSpec.StackBehavior.RESTORE_PARENT
	host.open(title, "关闭", "", in_battle, card_spec)
	var panel := CARD_INSPECTOR_PANEL_SCENE.instantiate() as CardInspectorPanel
	host.modal_body.add_child(panel)
	panel.configure(catalog, context)
	panel.card_requested.connect(_show_card_inspector.bind(
		return_action,
		return_label,
		field_choice_context,
	))
	host.back_action = return_action
	if return_action.is_valid():
		host.modal_confirm.text = return_label if not return_label.is_empty() else "返回上一界面"
		host.modal_confirm.pressed.connect(return_action, CONNECT_ONE_SHOT)
	elif not field_choice_context.is_empty():
		var resume_action := _complete_auxiliary_modal.bind(
			field_choice_context,
			Callable(),
		)
		host.back_action = host.close.bind(resume_action)
		host.modal_confirm.pressed.connect(
			host.close.bind(resume_action),
			CONNECT_ONE_SHOT,
		)
	else:
		host.modal_confirm.pressed.connect(host.close, CONNECT_ONE_SHOT)

func _show_zone_inspector(
	context: Dictionary,
	resume_choice_context: Dictionary = {},
) -> void:
	var field_choice_context := resume_choice_context
	click_requested.emit()
	var title := "%s · %s" % [
		_player_name_for_context(int(context.get("player", -1))),
		str(context.get("title", context.get("zone", "区域"))),
	]
	var zone_spec := (
		ModalSpec.battle(Vector2(820, 680), in_battle)
		if in_battle
		else ModalSpec.frontend(Vector2(820, 680))
	)
	host.open(
		title.strip_edges(),
		"关闭",
		"",
		in_battle,
		zone_spec,
	)
	var panel := ZONE_INSPECTOR_PANEL_SCENE.instantiate() as ZoneInspectorPanel
	host.modal_body.add_child(panel)
	panel.configure(catalog, context)
	if field_choice_context.is_empty():
		panel.card_requested.connect(_show_card_inspector)
		host.modal_confirm.pressed.connect(host.close, CONNECT_ONE_SHOT)
		return
	panel.card_requested.connect(_show_zone_card_inspector.bind(
		context.duplicate(true),
		field_choice_context,
	))
	var resume_action := _complete_auxiliary_modal.bind(
		field_choice_context,
		Callable(),
	)
	# The system-back path calls host.back_action directly. Close the inspector
	# first so its full-screen shade cannot keep intercepting the restored field
	# choice after the request has been re-established.
	host.back_action = host.close.bind(resume_action)
	host.modal_confirm.pressed.connect(
		host.close.bind(resume_action),
		CONNECT_ONE_SHOT,
	)

func _show_zone_card_inspector(
	card_context: Dictionary,
	zone_context: Dictionary,
	field_choice_context: Dictionary,
) -> void:
	_show_card_inspector(
		card_context,
		_show_zone_inspector.bind(zone_context, field_choice_context),
		"返回区域查看",
		field_choice_context,
	)

func _complete_auxiliary_modal(
	context: Dictionary,
	completion: Callable = Callable(),
) -> void:
	choice_resume_requested.emit(context)
	if completion.is_valid():
		completion.call()

func _show_deck_details(
	deck_key: String,
	restore_scroll: int = -1,
) -> void:
	click_requested.emit()
	var deck := catalog.get_deck(deck_key)
	if deck.is_empty():
		toast_requested.emit("找不到牌组：%s" % deck_key, true)
		return
	host.open(
		"牌组详情",
		"关闭",
		"",
		false,
		ModalSpec.frontend(Vector2(980, 720)),
	)
	var panel := DECK_DETAIL_PANEL_SCENE.instantiate() as DeckDetailPanel
	host.modal_body.add_child(panel)
	panel.configure(catalog, deck_key)
	panel.card_requested.connect(_show_deck_card_inspector.bind(deck_key))
	host.modal_confirm.pressed.connect(host.close, CONNECT_ONE_SHOT)
	if restore_scroll >= 0:
		_restore_deck_detail_modal_state(
			host.generation,
			restore_scroll,
		)

func _show_deck_card_inspector(context: Dictionary, deck_key: String) -> void:
	var scroll_position := host.modal_scroll.scroll_vertical if host.modal_scroll else 0
	_show_card_inspector(
		context,
		_show_deck_details.bind(deck_key, scroll_position),
		"返回牌组详情",
	)

func _restore_deck_detail_modal_state(
	generation: int,
	scroll_position: int,
) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if generation != host.generation or not host.modal_layer.visible:
		return
	if host.modal_scroll and scroll_position >= 0:
		host.modal_scroll.scroll_vertical = scroll_position

func _show_settings(resume_choice_context: Dictionary = {}) -> void:
	var field_choice_context := resume_choice_context
	click_requested.emit()
	host.open(
		"设置",
		"保存设置",
		"取消",
		in_battle,
		ModalSpec.frontend(Vector2(900, 760)),
	)
	var panel := SETTINGS_PANEL_SCENE.instantiate() as SettingsPanel
	host.modal_body.add_child(panel)
	panel.configure()
	panel.save_requested.connect(_save_settings_values.bind(field_choice_context))
	# Keep the save action connected while the modal remains open so a transient
	# filesystem failure can be corrected and retried without reopening Settings.
	host.modal_confirm.pressed.connect(panel.request_save)
	var resume_action := _complete_auxiliary_modal.bind(
		field_choice_context,
		Callable(),
	)
	if not field_choice_context.is_empty():
		host.back_action = host.close.bind(resume_action)
	host.modal_cancel.pressed.connect(
		host.close.bind(resume_action),
		CONNECT_ONE_SHOT,
	)

func _save_settings_values(
	values: Dictionary,
	resume_choice_context: Dictionary = {},
) -> void:
	AppSettings.update(
		float(values.get("master_volume", AppSettings.master_volume)),
		bool(values.get("muted", AppSettings.muted)),
		bool(values.get("reduced_motion", AppSettings.reduced_motion)),
		int(values.get("card_cache_size", AppSettings.card_cache_size)),
		str(values.get("animation_mode", AppSettings.animation_mode)),
		str(values.get("quality_profile", AppSettings.quality_profile)),
		float(values.get("music_volume", AppSettings.music_volume)),
		float(values.get("sfx_volume", AppSettings.sfx_volume)),
	)
	if not AppSettings.save_settings():
		toast_requested.emit("设置保存失败。", true)
		return
	host.close(_complete_auxiliary_modal.bind(
		resume_choice_context,
		Callable(),
	))
	Engine.max_fps = AppSettings.target_fps()
	toast_requested.emit("设置已保存。", false)
