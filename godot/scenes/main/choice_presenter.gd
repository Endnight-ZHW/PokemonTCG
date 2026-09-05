class_name ChoicePresenter
extends Node

signal confirm_requested
signal cancel_requested
signal response_ready(request: ChoiceView, response: ChoiceResponse)
signal field_choice_started
signal click_requested
signal retreat_confirmed(action: GameAction)

const CHOICE_PANEL_SCENE := preload("res://ui/dialogs/choice_panel.tscn")
const COIN_SHOWCASE := preload("res://scenes/battle/components/coin_showcase.gd")

var host: ModalHost
var choice_model: ChoiceSelectionModel
var catalog: CardCatalog
var battle_screen: BattleTable
var audio_director: AudioDirector
var active_request: ChoiceView
var active_choice_panel: ChoicePanel
var selected_choice_ids: Array[String]:
	get: return choice_model.selected_ids

func configure(p_host: ModalHost, p_model: ChoiceSelectionModel) -> void:
	host = p_host
	choice_model = p_model

func clear() -> void:
	active_request = null
	active_choice_panel = null
	choice_model.clear()

func _confirm_choice() -> void:
	confirm_requested.emit()

func submit_response(cancelled: bool = false) -> void:
	if active_request == null:
		return
	var request := active_request
	var response := ChoiceResponse.new(request.request_id,
		[] if cancelled else selected_choice_ids.duplicate(), cancelled)
	if is_instance_valid(battle_screen):
		battle_screen.clear_choice_targets()
	host.close(response_ready.emit.bind(request, response))

func show_choice(request: ChoiceView, state: GameState, p_catalog: CardCatalog,
		current_view_player: int, table: BattleTable, audio: AudioDirector) -> void:
	catalog = p_catalog
	battle_screen = table
	audio_director = audio
	active_request = request
	active_choice_panel = null
	choice_model.configure(request, state, catalog, current_view_player)
	if battle_screen:
		battle_screen.clear_choice_targets()
	if request.request_type == "coin_flip":
		_show_coin_flip_choice(request)
		return
	var field_targets := choice_model._choice_field_target_options(request)
	if not field_targets.is_empty() and battle_screen:
		battle_screen.set_choice_targets(field_targets, choice_model._choice_field_prompt(request))
		field_choice_started.emit()
		return
	var energy_cards := choice_model._choice_energy_cards(request)
	var energy_distribution_view := choice_model._choice_energy_distribution_view(
		request,
		energy_cards,
	)
	if not energy_distribution_view.is_empty():
		energy_cards.assign(energy_distribution_view.get("card_ids", energy_cards))
	var energy_target_models: Array[Dictionary] = []
	for target_value in energy_distribution_view.get("targets", []):
		if target_value is Dictionary:
			energy_target_models.append(Dictionary(target_value))
	var revealed_cards := choice_model._choice_revealed_cards(request)
	var deck_browse_rows := choice_model._choice_deck_browse_rows(request)
	var has_card_preview := (
		not energy_cards.is_empty()
		or not revealed_cards.is_empty()
		or not deck_browse_rows.is_empty()
	)
	var pure_empty_choice := (
		request.options.is_empty()
		and energy_cards.is_empty()
		and revealed_cards.is_empty()
		and deck_browse_rows.is_empty()
	)
	for option in request.options:
		if not choice_model._choice_option_display_card_id(option, request).is_empty():
			has_card_preview = true
			break
	var choice_spec := ModalSpec.battle(
		host.choice_size(has_card_preview, pure_empty_choice),
		false,
		(
			ModalSpec.SizeMode.FIT_CONTENT
			if pure_empty_choice
			else ModalSpec.SizeMode.PREFERRED
		),
	)
	var display_prompt := choice_model._choice_prompt_text(request)
	host.open(
		display_prompt,
		choice_model._choice_confirm_cta(request, 0),
		choice_model._choice_cancel_cta(request),
		false,
		choice_spec,
	)
	host.modal_title.text = choice_model._choice_title(request)
	var metadata_text := choice_model._choice_metadata_text(request)
	var panel := CHOICE_PANEL_SCENE.instantiate() as ChoicePanel
	host.modal_body.add_child(panel)
	active_choice_panel = panel
	panel.configure(
		metadata_text,
		not request.options.is_empty() or not deck_browse_rows.is_empty(),
		catalog,
		{
			"prompt": display_prompt,
			"min_select": request.min_select,
			"max_select": request.max_select,
			"request_type": request.request_type,
			"can_cancel": request.can_cancel,
			"allow_duplicates": request.allow_duplicates,
		},
	)
	panel.option_toggled.connect(toggle_choice)
	panel.energy_index_requested.connect(_rewind_energy_distribution)
	panel.undo_requested.connect(_undo_energy_distribution)
	panel.clear_requested.connect(_clear_energy_distribution)
	if not energy_target_models.is_empty():
		panel.configure_energy_distribution(
			energy_cards,
			energy_target_models,
			catalog,
		)
	elif not energy_cards.is_empty():
		panel.add_energy_preview(energy_cards, catalog)
	elif not revealed_cards.is_empty():
		panel.add_revealed_cards(revealed_cards, catalog)
	if not deck_browse_rows.is_empty() and energy_target_models.is_empty():
		panel.configure_deck_browser(deck_browse_rows, catalog)
	else:
		for option in request.options:
			if not energy_target_models.is_empty():
				break
			var option_id := str(option.get("option_id", ""))
			var option_card_id := choice_model._choice_option_display_card_id(option, request)
			if option_id.is_empty():
				continue
			if not option_card_id.is_empty():
				panel.add_card_option(
					option_id,
					option_card_id,
					choice_model._choice_option_caption(option),
					choice_model._choice_option_owner(option, request.player),
				)
			else:
				panel.add_text_option(
					option_id,
					choice_model._choice_text_option_label(option, request),
				)
	host.modal_confirm.pressed.connect(_confirm_choice, CONNECT_ONE_SHOT)
	if request.can_cancel:
		host.modal_cancel.pressed.connect(cancel_requested.emit, CONNECT_ONE_SHOT)
	refresh_selection()

func _show_coin_flip_choice(request: ChoiceView) -> void:
	host.open(
		request.prompt,
		"继续结算",
		"",
		false,
		ModalSpec.battle(Vector2(680, 500)),
	)
	host.modal_title.text = "硬币结算"
	var results: Array = choice_model._choice_presentation(request).get("predetermined_flips", [])
	var showcase := COIN_SHOWCASE.new() as CoinShowcase
	showcase.name = "CoinShowcase"
	showcase.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	showcase.custom_minimum_size = Vector2(540, 300)
	if audio_director:
		showcase.audio_requested.connect(audio_director.play_cue)
	host.modal_body.add_child(showcase)
	var reveal_generation := host.generation
	var playback := showcase.play(results, true, "硬币结果")
	host.modal_confirm.disabled = not playback.is_finished()
	if not playback.is_finished():
		playback.completed.connect(
			_on_coin_choice_playback_completed.bind(
				reveal_generation,
				request.request_id,
			),
			CONNECT_ONE_SHOT,
		)
	host.modal_confirm.text = "继续结算"
	host.modal_confirm.pressed.connect(_confirm_choice, CONNECT_ONE_SHOT)

func _on_coin_choice_playback_completed(
	_handle: MotionHandle,
	generation: int,
	request_id: String,
) -> void:
	_finish_coin_flip_reveal(generation, request_id)

func _finish_coin_flip_reveal(generation: int, request_id: String) -> void:
	if (
		generation != host.generation
		or not host.modal_layer.visible
		or active_request == null
		or active_request.request_id != request_id
	):
		return
	host.modal_confirm.disabled = false

func show_retreat_confirmation(action: GameAction, state: GameState, p_catalog: CardCatalog) -> void:
	click_requested.emit()
	host.open(
		"确认撤退",
		"确认撤退",
		"取消",
		false,
		ModalSpec.battle(
			Vector2(640, 420),
			false,
			ModalSpec.SizeMode.FIT_CONTENT,
		),
	)
	var lines := retreat_confirmation_lines(action, state, p_catalog)
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 18)
	body.add_theme_color_override("font_color", DesignTokens.TEXT)
	body.text = "\n".join(lines)
	host.modal_body.add_child(body)
	host.modal_confirm.pressed.connect(func() -> void:
		click_requested.emit()
		host.close(retreat_confirmed.emit.bind(action))
	, CONNECT_ONE_SHOT)
	host.modal_cancel.pressed.connect(func() -> void:
		click_requested.emit()
		host.close()
	, CONNECT_ONE_SHOT)

func _show_choice_blocked_reason(reason: String) -> void:
	if reason.is_empty() or active_choice_panel == null:
		return
	active_choice_panel.show_blocked_reason(reason)

func toggle_choice(option_id: String) -> void:
	click_requested.emit()
	if active_request == null:
		return
	var blocked_reason := choice_model._choice_addition_blocked_reason(active_request, option_id)
	var rejection := choice_model.toggle(option_id, blocked_reason)
	if not rejection.is_empty():
		refresh_selection()
		_show_choice_blocked_reason(rejection)
		return
	refresh_selection()

func _rewind_energy_distribution(index: int) -> void:
	if active_request == null or active_request.request_type != "distribute_energy":
		return
	if not choice_model.rewind(index):
		return
	click_requested.emit()
	refresh_selection()

func _undo_energy_distribution() -> void:
	if active_request == null or active_request.request_type != "distribute_energy":
		return
	if not choice_model.undo():
		return
	click_requested.emit()
	refresh_selection()

func _clear_energy_distribution() -> void:
	if active_request == null or active_request.request_type != "distribute_energy":
		return
	if selected_choice_ids.is_empty():
		return
	click_requested.emit()
	selected_choice_ids.clear()
	refresh_selection()

func refresh_selection() -> void:
	if active_request == null:
		return
	var disabled_reasons := choice_model._choice_option_disabled_reasons(active_request)
	if active_choice_panel:
		active_choice_panel.refresh_selection(
			selected_choice_ids,
			active_request.max_select,
			active_request.allow_duplicates,
		)
		active_choice_panel.set_option_disabled_reasons(
			disabled_reasons,
		)
	elif battle_screen:
		battle_screen.set_choice_targets(
			choice_model._choice_field_target_options(active_request),
			choice_model._choice_field_prompt(active_request),
		)
		battle_screen.update_choice_selection(selected_choice_ids, disabled_reasons)
	host.modal_confirm.disabled = not choice_model._choice_selection_is_complete(
		active_request, selected_choice_ids)
	host.modal_confirm.text = choice_model._choice_confirm_cta(active_request, selected_choice_ids.size())
	if active_request.can_cancel:
		host.modal_cancel.text = choice_model._choice_cancel_cta(active_request)

func suspend_field_choice() -> Dictionary:
	if active_request == null or active_choice_panel != null:
		return {}
	if choice_model._choice_field_target_options(active_request).is_empty():
		return {}
	var context := {
		"request": active_request,
		"selected_ids": selected_choice_ids.duplicate(),
	}
	active_request = null
	selected_choice_ids.clear()
	if battle_screen:
		battle_screen.clear_choice_targets()
	return context

func retreat_confirmation_lines(action: GameAction, current_state: GameState, p_catalog: CardCatalog) -> Array[String]:
	var actor: int = action.actor
	if current_state == null or actor not in [0, 1]:
		return []
	var player := current_state.get_player(actor)
	var bench_idx := action.bench_index()
	var target_name := "备战宝可梦"
	if bench_idx >= 0 and bench_idx < player.bench.size() and player.bench[bench_idx]:
		target_name = p_catalog.card_name(player.bench[bench_idx].card_id)
	var energy_names := _retreat_energy_names(action, current_state, p_catalog)
	var active_name := p_catalog.card_name(player.active.card_id) if player.active else "战斗宝可梦"
	var cost_text := ""
	if not energy_names.is_empty():
		cost_text = "将丢弃：%s" % "、".join(energy_names)
	elif _retreat_explicitly_requires_no_energy(action):
		cost_text = "无需丢弃能量"
	else:
		var printed_cost := _retreat_printed_cost(action, current_state, p_catalog)
		cost_text = (
			"卡面撤退费用：%d 点。确认后按当前效果结算；如需支付，下一步选择要丢弃的附着能量。"
			% printed_cost
			if printed_cost > 0
			else "确认后按当前效果结算撤退费用；如需支付，下一步选择要丢弃的附着能量。"
		)
	return [
		"%s 将撤退，%s 将进入战斗区。" % [active_name, target_name],
		cost_text,
	]

func _retreat_energy_names(action: GameAction, current_state: GameState, p_catalog: CardCatalog) -> Array[String]:
	var result: Array[String] = []
	var actor: int = action.actor
	if current_state == null or actor not in [0, 1]:
		return result
	var active := current_state.get_player(actor).active
	if active == null:
		return result
	for raw_index in action.payload.get("energy_indices", []):
		var index := int(raw_index)
		if index >= 0 and index < active.energy_card_ids.size():
			result.append(p_catalog.card_name(str(active.energy_card_ids[index])))
	return result

func _retreat_explicitly_requires_no_energy(action: GameAction) -> bool:
	if action == null or not action.payload.has("energy_indices"):
		return false
	var indices: Variant = action.payload.get("energy_indices")
	return indices is Array and Array(indices).is_empty()

func _retreat_printed_cost(action: GameAction, current_state: GameState, p_catalog: CardCatalog) -> int:
	var actor: int = action.actor
	if current_state == null or actor not in [0, 1]:
		return -1
	var active := current_state.get_player(actor).active
	if active == null:
		return -1
	return maxi(0, int(p_catalog.get_card(active.card_id).get("retreat_cost", 0)))

func _retreat_energy_suffix(action: GameAction, current_state: GameState, p_catalog: CardCatalog) -> String:
	var names := _retreat_energy_names(action, current_state, p_catalog)
	if not names.is_empty():
		return "（丢弃：%s）" % "、".join(names)
	if _retreat_explicitly_requires_no_energy(action):
		return "（无需丢弃能量）"
	var printed_cost := _retreat_printed_cost(action, current_state, p_catalog)
	return (
		"（撤退费 %d，确认后结算）" % printed_cost
		if printed_cost > 0
		else "（确认后结算撤退费用）"
	)

func action_label(action: GameAction, current_state: GameState, p_catalog: CardCatalog) -> String:
	match action.kind:
		"PLAY_BASIC":
			return "上场 · %s → %s" % [
				_source_card_name(action, current_state, p_catalog), choice_model._slot_name(str(action.target_slot()))]
		"EVOLVE":
			return "进化 · %s → %s" % [
				_source_card_name(action, current_state, p_catalog), choice_model._slot_name(str(action.primary_slot()))]
		"ATTACH_ENERGY":
			return "附能 · %s → %s" % [
				_source_card_name(action, current_state, p_catalog), choice_model._slot_name(str(action.target_slot()))]
		"PLAY_TRAINER":
			var target := str(action.target_slot())
			return "使用 · %s%s" % [
				_source_card_name(action, current_state, p_catalog),
				" → %s" % choice_model._slot_name(target) if not target.is_empty() else "",
			]
		"USE_ABILITY":
			return "特性 · %s · %s" % [
				action.ability_name(),
				choice_model._slot_name(str(action.primary_slot())),
			]
		"USE_STADIUM":
			return "发动竞技场"
		"RETREAT":
			return "撤退 → 备战区 %d%s" % [
				action.bench_index(0) + 1,
				_retreat_energy_suffix(action, current_state, p_catalog),
			]
		"DECLARE_ATTACK":
			var active := current_state.get_player(action.actor).active if current_state else null
			var attacks: Array = p_catalog.get_card(active.card_id).get("attacks", []) if active else []
			var attack_idx := action.attack_index(0)
			var attack_name := "招式 %d" % (attack_idx + 1)
			if attack_idx >= 0 and attack_idx < attacks.size():
				attack_name = str(attacks[attack_idx].get("name", attack_name))
			return "攻击 · %s" % attack_name
		"END_TURN":
			return "结束回合"
		"SETUP_DONE":
			return "完成准备"
		"PROMOTE":
			return "晋升 · 备战区 %d" % (action.bench_index(0) + 1)
		_:
			return action.kind

func _source_card_name(action: GameAction, current_state: GameState, p_catalog: CardCatalog) -> String:
	if action.source:
		return p_catalog.card_name(action.source.card_id)
	var hand_idx := action.hand_index()
	if current_state == null or action.actor not in [0, 1]:
		return "卡牌"
	var player := current_state.get_player(action.actor)
	if hand_idx >= 0 and hand_idx < player.hand.size():
		return p_catalog.card_name(player.hand[hand_idx])
	return "卡牌"
