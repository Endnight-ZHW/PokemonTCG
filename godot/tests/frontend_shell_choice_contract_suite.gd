extends RefCounted

var context: FrontendContractContext


func configure(contract_context: FrontendContractContext) -> void:
	context = contract_context


func _check_main_shell_contract() -> void:
	var main_scene := load("res://scenes/main/main.tscn") as PackedScene
	context._check(main_scene != null, "Main shell is unavailable for frontend interaction checks")
	if main_scene == null:
		return
	var main := main_scene.instantiate()
	context.tree.root.add_child(main)
	await context._settle_layout(3)
	context._check(not main.modal_scroll.follow_focus,
		"Main modal scroll must not follow disabled keyboard navigation")
	var fill_spec := ModalSpec.frontend(
		Vector2(900, 760), ModalSpec.SizeMode.FILL_SAFE
	)
	context._check(
		main.modal_host_controller._resolved_size(fill_spec, Vector2(1000, 700))
		== Vector2(976, 676),
		"FILL_SAFE modal must fill the available safe area",
	)
	var fit_spec := ModalSpec.battle(
		Vector2(720, 400), false, ModalSpec.SizeMode.FIT_CONTENT
	)
	context._check(
		main.modal_host_controller._resolved_size(fit_spec, Vector2(1000, 700))
		== Vector2(720, 400),
		"FIT_CONTENT modal must preserve its compact target within safe bounds",
	)
	context._check(
		fit_spec.confirm_role == ModalSpec.ButtonRole.PRIMARY
		and fit_spec.cancel_role == ModalSpec.ButtonRole.SECONDARY,
		"ModalSpec semantic button-role defaults changed",
	)
	_check_generic_choice_category_limits(main)
	await _check_trekking_shoes_choice(main)
	await _check_semantic_effect_choices(main)
	await _check_native_energy_distribution_choice(main)
	await _check_retreat_payment_ui(main)
	await _check_pointer_only_input_contract(main)
	await _check_field_choice_inspector_resume(main)
	main.shell_view.show_deck_select("challenge")
	await context._settle_layout(4)
	var routed_deck_page := (
		main.screen_host.get_child(0) as DeckSelectPage
		if main.screen_host.get_child_count() > 0
		else null
	)
	context._check(
		routed_deck_page != null and context.tree.root.gui_get_focus_owner() == null,
		"Entering DeckSelect must not establish automatic GUI focus",
	)
	context._check_pointer_only_controls(routed_deck_page, "main-routed-decks")
	main.shell_view.show_title()
	await context._settle_layout(3)
	context._check(
		context.tree.root.gui_get_focus_owner() == null,
		"Returning to title must not restore automatic GUI focus",
	)
	var scaled_insets: Vector4 = main.shell_view.safe_insets_to_canvas(
		Vector2i(1920, 0),
		Vector2i(2400, 1080),
		Rect2i(1968, 24, 2304, 1032),
		Vector2(2000, 900),
	)
	context._check(
		scaled_insets.is_equal_approx(Vector4(40, 20, 40, 20)),
		"Main safe-area conversion failed for a scaled secondary display",
	)
	context._check(
		main.shell_view.responsive_content_scale_size(Vector2i(640, 360))
		== Vector2i(900, 540)
		and main.shell_view.responsive_content_scale_size(Vector2i(720, 1280))
		== Vector2i(720, 1280)
		and main.shell_view.responsive_content_scale_size(Vector2i(900, 540))
		== Vector2i(900, 540)
		and main.shell_view.responsive_content_scale_size(Vector2i(1024, 600))
		== Vector2i(1024, 600)
		and main.shell_view.responsive_content_scale_size(Vector2i(1280, 720))
		== Vector2i(1280, 720)
		and main.shell_view.responsive_content_scale_size(Vector2i(1600, 900))
		== Vector2i(1600, 900)
		and main.shell_view.responsive_content_scale_size(Vector2i(2560, 1080))
		== Vector2i(1600, 900),
		"Main responsive canvas must prevent UI downsampling on supported compact displays",
	)
	main.shell_view.show_network_setup("relay")
	await context._settle_layout(3)
	var lobby := main.current_network_page as NetworkLobbyPage
	context._check(lobby != null and lobby.is_inside_tree(),
		"Main did not retain a live network-lobby route")
	if lobby:
		lobby.set_connection_state(
			NetworkLobbyPage.ConnectionState.WAITING,
			"等待测试连接",
			"ROOM42",
		)
		main._handle_network_disconnected("timeout")
		await context._settle_layout(2)
		context._check(
			lobby.connection_state == NetworkLobbyPage.ConnectionState.ERROR
			and not lobby.connect_button.disabled,
			"Lobby disconnect must unlock a retryable ERROR state",
		)
	main.shell_view.show_title()
	main._show_help()
	await context._settle_layout(4)
	var first_category := main.modal_body.find_child(
		"QuickStartCategory", true, false
	) as Button
	var last_category := main.modal_body.find_child(
		"NetworkCategory", true, false
	) as Button
	context._check(
		first_category != null
		and last_category != null
		and first_category.focus_mode == Control.FOCUS_NONE
		and last_category.focus_mode == Control.FOCUS_NONE
		and context.tree.root.gui_get_focus_owner() == null,
		"Help modal category controls must remain pointer/touch only",
	)
	context._check_pointer_only_controls(main.modal_layer, "help-modal")
	context._check(main.modal_panel.theme != null,
		"Frontend modal did not apply the isolated frontend theme")
	var previous_reduced_motion := bool(context._settings_node.get("reduced_motion"))
	var previous_animation_mode := str(context._settings_node.get("animation_mode"))
	context._settings_node.set("reduced_motion", false)
	context._settings_node.set("animation_mode", "fast")
	var close_calls := [0]
	main.modal_host_controller.close(func() -> void:
		close_calls[0] = int(close_calls[0]) + 1
	)
	var close_generation := int(main.modal_host_controller.generation)
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	context._check(
		int(main.modal_host_controller.generation) == close_generation
		and bool(main.modal_host_controller.closing),
		"Android back re-entered an in-flight modal close transaction",
	)
	main.modal_host_controller.finish_close(close_generation)
	main.modal_host_controller.finish_close(close_generation)
	context._settings_node.set("reduced_motion", previous_reduced_motion)
	context._settings_node.set("animation_mode", previous_animation_mode)
	context._check(
		int(close_calls[0]) == 1 and not bool(main.modal_host_controller.closing),
		"Modal close completion was lost or invoked more than once",
	)
	context._check(main.modal_panel.theme == null,
		"Closing a frontend modal did not restore inherited shell theme")
	main._show_deck_details("fire")
	await context._settle_layout(4)
	var deck_buttons: Array[Node] = main.modal_body.find_children(
		"*", "Button", true, false
	)
	var history_target := deck_buttons[0] as Button if not deck_buttons.is_empty() else null
	context._check(history_target != null,
		"Deck-detail modal exposes no card action for history checks")
	if history_target:
		main.modal_scroll.scroll_vertical = int(
			main.modal_scroll.get_v_scroll_bar().max_value
		)
		await context._settle_layout(2)
		var saved_scroll: int = int(main.modal_scroll.scroll_vertical)
		history_target.pressed.emit()
		await context._settle_layout(3)
		context._check(
			main.modal_host_controller.active_spec.stack_behavior
			== ModalSpec.StackBehavior.RESTORE_PARENT,
			"Deck card inspector did not declare modal history behavior",
		)
		main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
		await context._settle_layout(5)
		context._check(
			abs(main.modal_scroll.scroll_vertical - saved_scroll) <= 2
			and context.tree.root.gui_get_focus_owner() == null,
			"Deck-detail modal history did not restore scroll without GUI focus",
		)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)
	main._show_pause_overlay()
	await context._settle_layout(3)
	var pause_help := main.modal_body.find_child("HelpButton", true, false) as Button
	context._check(
		main.modal_host_controller.active_spec.size_mode
		== ModalSpec.SizeMode.FIT_CONTENT
		and main.modal_panel.custom_minimum_size == Vector2(720, 400)
		and main.modal_scroll.custom_minimum_size.y == 0.0
		and main.modal_confirm.theme_type_variation == &"BattlePrimaryButton"
		and main.modal_cancel.theme_type_variation == &"BattleDangerButton"
		and pause_help != null
		and pause_help.theme_type_variation == &"BattleSecondaryButton",
		"Pause modal must use 720x400 FIT_CONTENT and Primary/Secondary/Danger roles",
	)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)
	await _check_open_modal_resize(main)
	_check_local_promotion_handoff(main)
	main.queue_free()
	await context._settle_layout(2)


func _check_local_promotion_handoff(main: Node) -> void:
	var state := GameState.new()
	state.phase = "MAIN"
	state.setup_stage = GameState.SETUP_COMPLETE
	state.active_player_idx = 1
	state.pending_promotions.assign([0])
	main.state = state
	main.game_mode = "local"
	main.current_screen = "game"
	main.current_view_player = 1
	main._after_step(0, "MAIN")
	context._check(
		main.current_view_player == 0
		and main.modal_layer.visible
		and main.modal_title.text == "晋升"
		and main.modal_confirm.text == "显示玩家 1 手牌",
		"Local handoff routed an active-player change before the pending promotion",
	)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)
	main.state = null
	main.current_screen = "title"


func _check_generic_choice_category_limits(main: Control) -> void:
	var options: Array[Dictionary] = [
		{
			"option_id": "energy:0",
			"label": "基本能量 A",
			"ref": EntityRef.new(
				"card", 0, "discard", "", 0, "", "sv1-ener-2"
			).to_dict(),
		},
		{
			"option_id": "energy:1",
			"label": "基本能量 B",
			"ref": EntityRef.new(
				"card", 0, "discard", "", 1, "", "sv1-ener-3"
			).to_dict(),
		},
		{
			"option_id": "pokemon:0",
			"label": "宝可梦",
			"ref": EntityRef.new(
				"card", 0, "discard", "", 2, "", "svi-chim"
			).to_dict(),
		},
	]
	var request := ChoiceView.new(
		"choice:generic-category-limits",
		1,
		"select_cards",
		0,
		"",
		options,
		0,
		3,
		false,
		true,
		{"category_limits": {"energy": 1, "pokemon": 1}},
	)
	main.selected_choice_ids.assign(["energy:0"])
	context._check(
		not str(main.choice_model._choice_addition_blocked_reason(
			request, "energy:1")).is_empty()
		and str(main.choice_model._choice_addition_blocked_reason(
			request, "pokemon:0")).is_empty(),
		"Generic ChoiceView category_limits were ignored by the player UI",
	)
	main.selected_choice_ids.clear()


func _check_trekking_shoes_choice(main: Control) -> void:
	var request := ChoiceView.new(
		"choice:trekking-shoes-ui",
		1,
		"confirm",
		0,
		"请选择。",
		[
			{"option_id": "confirm:yes", "label": "option 1"},
			{"option_id": "confirm:no", "label": "option 2"},
		],
		1,
		1,
		false,
		false,
		{
			"domain": "effect",
			"purpose": "trekking_shoes",
			"top_card_id": "svf-potion",
			"revealed_card_ids": ["svf-potion"],
		},
	)
	main._show_choice_overlay(request)
	await context._settle_layout(3)
	var panel := main.active_choice_panel as ChoicePanel
	var keep_button := (
		panel._option_buttons.get("confirm:yes") as Button
		if panel != null
		else null
	)
	var discard_button := (
		panel._option_buttons.get("confirm:no") as Button
		if panel != null
		else null
	)
	var revealed_card := (
		panel.energy_distribution._energy_preview_cards[0] as CardView
		if panel != null and not panel.energy_distribution._energy_preview_cards.is_empty()
		else null
	)
	context._check(
		panel != null
		and main.modal_title.text == "健行鞋"
		and panel.prompt_label.text == "查看了牌库顶的卡牌。请选择处理方式。"
		and not panel.metadata_label.visible
		and panel.energy_preview.visible
		and revealed_card != null
		and revealed_card.card_id == "svf-potion"
		and keep_button != null
		and keep_button.text == "将这张卡牌加入手牌"
		and discard_button != null
		and discard_button.text == "丢弃这张卡牌，再抽1张卡牌"
		and main.modal_confirm.disabled,
		"Trekking Shoes choice did not show the revealed card and localized actions",
	)
	main._toggle_choice("confirm:no")
	context._check(
		not main.modal_confirm.disabled
		and main.modal_confirm.text == "确认“丢弃这张卡牌，再抽1张卡牌”",
		"Trekking Shoes selected action was not reflected by the confirm CTA",
	)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)
	main.selected_choice_ids.clear()


func _check_semantic_effect_choices(main: Control) -> void:
	var switch_request := ChoiceView.new(
		"choice:switch-confirm-ui", 1, "confirm", 0, "请选择。",
		[
			{"option_id": "confirm:yes", "label": "option 1"},
			{"option_id": "confirm:no", "label": "option 2"},
		],
		1, 1, false, false,
		{
			"domain": "effect",
			"purpose": "switch_confirm",
			"source_player": 0,
			"source_slot": "active",
			"source_card_id": "sv1-114",
			"target_player": 0,
		},
	)
	main._show_choice_overlay(switch_request)
	await context._settle_layout(3)
	var switch_panel := main.active_choice_panel as ChoicePanel
	var switch_card := (
		switch_panel.energy_distribution._energy_preview_cards[0] as CardView
		if switch_panel != null and not switch_panel.energy_distribution._energy_preview_cards.is_empty()
		else null
	)
	context._check(
		switch_panel != null
		and main.modal_title.text == "确认换位"
		and switch_panel.prompt_label.text
			== "是否将这只宝可梦与备战宝可梦互换？"
		and (switch_panel._option_buttons["confirm:yes"] as Button).text
			== "进行换位"
		and (switch_panel._option_buttons["confirm:no"] as Button).text
			== "不进行换位"
		and switch_card != null
		and switch_card.card_id == "sv1-114",
		"Optional switch UI retained generic labels or hid its source Pokemon",
	)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)

	var preview_state := UIPreviewStateFactory.battle_state()
	main.state = preview_state
	main.current_view_player = 0
	var treasure_options: Array[Dictionary] = []
	for row in [
		{"slot": "active", "card_id": preview_state.players[0].active.card_id},
		{"slot": "bench_0", "card_id": preview_state.players[0].bench[0].card_id},
	]:
		treasure_options.append({
			"option_id": "pokemon:0:%s:%s" % [row["slot"], row["card_id"]],
			"label": main.catalog.card_name(row["card_id"]),
			"ref": EntityRef.new(
				"pokemon", 0, "", row["slot"], -1, "", row["card_id"],
			).to_dict(),
		})
	var treasure_request := ChoiceView.new(
		"choice:treasure-energy-ui", 1, "select_prize_energy_target", 0,
		"请选择。", treasure_options, 0, 1, false, true,
		{
			"domain": "trigger",
			"purpose": "treasure_energy_target",
			"source_player": 0,
			"source_zone": "prizes",
			"source_card_id": "svi-trea",
			"card_id": "svi-trea",
			"revealed_card_ids": ["svi-trea"],
		},
	)
	main._show_choice_overlay(treasure_request)
	await context._settle_layout(3)
	var treasure_panel := main.active_choice_panel as ChoicePanel
	var treasure_card := (
		treasure_panel.energy_distribution._energy_preview_cards[0] as CardView
		if treasure_panel != null and not treasure_panel.energy_distribution._energy_preview_cards.is_empty()
		else null
	)
	context._check(
		treasure_panel != null
		and main.modal_title.text == "宝藏能量"
		and main.choice_model._choice_count_unit(treasure_request) == "个目标"
		and "目标" in treasure_panel.selection_hint_label.text
		and "张卡牌" not in treasure_panel.selection_hint_label.text
		and treasure_card != null
		and treasure_card.card_id == "svi-trea",
		"Treasure Energy UI did not identify its source card and Pokemon targets",
	)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)

	var exp_share_request := ChoiceView.new(
		"choice:exp-share-ui", 1, "confirm_trigger", 0, "请选择。",
		[
			{"option_id": "confirm:yes", "label": "option 1"},
			{"option_id": "confirm:no", "label": "option 2"},
		],
		1, 1, false, false,
		{
			"domain": "trigger",
			"purpose": "confirm_exp_share_trigger",
			"source_player": 0,
			"source_slot": "active",
			"source_card_id": preview_state.players[0].active.card_id,
			"target_player": 0,
			"target_slot": "bench_0",
			"card_id": "svg2-exps",
			"revealed_card_ids": ["svg2-exps"],
		},
	)
	main._show_choice_overlay(exp_share_request)
	main._toggle_choice("confirm:yes")
	await context._settle_layout(3)
	var exp_share_panel := main.active_choice_panel as ChoicePanel
	context._check(
		exp_share_panel != null
		and main.modal_title.text == "学习装置"
		and str((exp_share_panel._option_buttons["confirm:yes"] as Button).text).ends_with(
			"发动学习装置"
		)
		and (exp_share_panel._option_buttons["confirm:no"] as Button).text
			== "不发动"
		and main.modal_confirm.text == "确认“发动学习装置”"
		and not exp_share_panel.energy_distribution._energy_preview_cards.is_empty()
		and (exp_share_panel.energy_distribution._energy_preview_cards[0] as CardView).card_id
			== "svg2-exps",
		"Exp. Share confirmation UI retained placeholders or hid the Tool card: title=%s yes=%s no=%s cta=%s preview=%s" % [
			main.modal_title.text,
			(exp_share_panel._option_buttons["confirm:yes"] as Button).text,
			(exp_share_panel._option_buttons["confirm:no"] as Button).text,
			main.modal_confirm.text,
			(exp_share_panel.energy_distribution._energy_preview_cards[0] as CardView).card_id
				if not exp_share_panel.energy_distribution._energy_preview_cards.is_empty()
				else "<none>",
		],
	)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)
	main.selected_choice_ids.clear()


func _check_native_energy_distribution_choice(main: Control) -> void:
	var preview_state := UIPreviewStateFactory.battle_state()
	main.state = preview_state
	main.current_view_player = 0
	var energy_ids: Array[String] = ["svi-jete", "svi-dtur"]
	var target_rows: Array[Dictionary] = [
		{"slot": "active", "card_id": "svi-hrot", "label": "加热洛托姆"},
		{"slot": "bench_0", "card_id": "svi-chim", "label": "小火焰猴"},
	]
	var options: Array[Dictionary] = []
	for target in target_rows:
		for energy_index in range(energy_ids.size()):
			var energy_id := energy_ids[energy_index]
			options.append({
				"option_id": "energy:%d:%s->pokemon:0:%s:%s" % [
					energy_index,
					energy_id,
					str(target["slot"]),
					str(target["card_id"]),
				],
				"label": str(target["label"]),
				"ref": EntityRef.new(
					"pokemon", 0, "", str(target["slot"]), -1, "",
					str(target["card_id"]),
				).to_dict(),
			})
	var request := ChoiceView.new(
		"choice:native-energy-ui",
		preview_state.revision,
		"distribute_energy",
		0,
		"为每张能量选择附着目标。",
		options,
		0,
		2,
		false,
		false,
		{
			"card_ids": energy_ids,
			"max_per_target": 2,
			"same_target": true,
			"source_player": 0,
			"source_zone": "hand",
		},
	)
	var original_active_ids := preview_state.players[0].active.energy_card_ids.duplicate()
	main._show_choice_overlay(request)
	await context._settle_layout(4)
	var panel := main.active_choice_panel as ChoicePanel
	var active_model := (
		panel.energy_distribution._energy_target_model("0:active")
		if panel
		else {}
	)
	context._check(
		panel != null
		and panel.card_option_count() == 2
		and panel.energy_distribution._energy_option_id_for_target(active_model, 0)
		== str(options[0]["option_id"])
		and panel.energy_distribution._energy_option_id_for_target(active_model, 1)
		== str(options[1]["option_id"]),
		"Native decorated energy options were not grouped or indexed by target",
	)
	main._toggle_choice(str(options[0]["option_id"]))
	await context._settle_layout(2)
	var projected_card := panel.energy_distribution._energy_target_cards.get("0:active") as CardView
	context._check(
		projected_card != null
		and projected_card.pokemon != null
		and projected_card.pokemon.energy_card_ids.size()
		== original_active_ids.size() + 1
		and preview_state.players[0].active.energy_card_ids == original_active_ids,
		"Energy target preview did not remain a read-only projected Pokemon state",
	)
	var fallback_options: Array[Dictionary] = [
		{
			"option_id": "pokemon:0:active:svi-hrot",
			"label": "加热洛托姆",
			"ref": EntityRef.new(
				"pokemon", 0, "", "active", -1, "", "svi-hrot").to_dict(),
		},
		{
			"option_id": "pokemon:0:bench_4:missing",
			"label": "失效目标",
			"ref": EntityRef.new(
				"pokemon", 0, "", "bench_4", -1, "", "missing").to_dict(),
		},
	]
	var fallback_request := ChoiceView.new(
		"choice:legacy-energy-ui", preview_state.revision, "distribute_energy",
		0, "选择目标", fallback_options, 0, 2, true, false, {})
	var no_presentation_cards: Array[String] = []
	var fallback_view: Dictionary = main.choice_model._choice_energy_distribution_view(
		fallback_request, no_presentation_cards)
	var fallback_targets: Array = fallback_view.get("targets", [])
	context._check(
		fallback_targets.size() == 1
		and Array(fallback_view.get("card_ids", [])).size() == 2
		and str(Dictionary(fallback_targets[0]).get("fallback_option_id", ""))
		== "pokemon:0:active:svi-hrot",
		"Legacy optional distribution fallback or stale-target filtering failed",
	)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)


func _check_retreat_payment_ui(main: Control) -> void:
	var preview_state := UIPreviewStateFactory.battle_state()
	preview_state.players[0].active.energy_card_ids.assign([
		"sv1-ener-2", "sv1-ener-2", "svi-dtur",
	])
	main.state = preview_state
	main.current_view_player = 0
	var retreat_action := GameAction.create(
		"RETREAT",
		{},
		0,
		EntityRef.new(
			"pokemon", 0, "field", "active", -1, "",
			preview_state.players[0].active.card_id,
		),
		EntityRef.new(
			"pokemon", 0, "field", "bench_0", -1, "",
			preview_state.players[0].bench[0].card_id,
		),
	)
	var confirmation_text := "\n".join(
		main.choice_model._retreat_confirmation_lines(retreat_action))
	context._check(
		"无需丢弃能量" not in confirmation_text
		and "卡面撤退费用：1 点" in confirmation_text
		and "下一步选择" in confirmation_text
		and "无需丢弃能量" not in main.choice_model._action_label(retreat_action),
		"Retreat action without preselected indices was incorrectly presented as free",
	)

	var options: Array[Dictionary] = []
	var attachment_refs: Array[Dictionary] = []
	for index in range(preview_state.players[0].active.energy_card_ids.size()):
		var card_id := str(preview_state.players[0].active.energy_card_ids[index])
		var option_id := "attachment:0:active:energy:%d:%s" % [index, card_id]
		var ref := EntityRef.new(
			"attachment", 0, "field", "active", index, "energy", card_id,
		).to_dict()
		options.append({
			"option_id": option_id,
			"label": main.catalog.card_name(card_id),
			"ref": ref,
		})
		# Native retreat requests use compact unit descriptors here. ChoiceView
		# may omit them, so the UI must also derive units from the public ref/state.
		attachment_refs.append({
			"option_id": option_id,
			"units": main.catalog.provides_energy(card_id).size(),
		})
	var request := ChoiceView.new(
		"choice:retreat-payment-ui",
		preview_state.revision,
		"select_retreat_payment",
		0,
		"选择撤退支付。",
		options,
		1,
		options.size(),
		false,
		false,
		{
			"domain": "retreat",
			"purpose": "retreat_payment",
			"required_units": 2,
			"attachment_refs": attachment_refs,
		},
	)
	main._show_choice_overlay(request)
	await context._settle_layout(3)
	var first_id := str(options[0]["option_id"])
	var second_id := str(options[1]["option_id"])
	var double_id := str(options[2]["option_id"])
	context._check(
		"需要支付 2 点" in main.choice_model._choice_metadata_text(request)
		and "提供2点" in main.choice_model._choice_option_caption(options[2])
		and main.modal_confirm.disabled,
		"Retreat payment UI did not expose its required/provided energy units",
	)
	main._toggle_choice(first_id)
	context._check(
		main.modal_confirm.disabled
		and main.modal_confirm.text == "确认支付（1/2 点）",
		"One energy unit incorrectly satisfied a two-unit retreat payment",
	)
	main._toggle_choice(second_id)
	context._check(
		not main.modal_confirm.disabled
		and main.modal_confirm.text == "确认支付（2/2 点）",
		"Two basic Energy cards did not satisfy a two-unit retreat payment",
	)
	context._check(
		"多丢弃能量" in main.choice_model._choice_addition_blocked_reason(
			request, double_id
		),
		"Retreat payment allowed a redundant extra Energy card",
	)
	main._toggle_choice(first_id)
	main._toggle_choice(second_id)
	main._toggle_choice(double_id)
	context._check(
		main.selected_choice_ids == [double_id]
		and not main.modal_confirm.disabled
		and main.modal_confirm.text == "确认支付（2/2 点）",
		"A two-unit Special Energy did not independently satisfy retreat payment",
	)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)


func _check_field_choice_inspector_resume(main: Control) -> void:
	var battle_scene := load(
		"res://scenes/battle/components/battle_table.tscn"
	) as PackedScene
	context._check(battle_scene != null,
		"Battle table is unavailable for field-choice inspector regression")
	if battle_scene == null:
		return
	var previous_screen: String = str(main.current_screen)
	var previous_battle: BattleTable = main.battle_screen
	var table := battle_scene.instantiate() as BattleTable
	context.tree.root.add_child(table)
	await context._settle_layout(2)
	main.current_screen = "game"
	main.battle_screen = table
	await _check_card_action_detail_separation(table)
	_check_discard_zone_action_reachability(table)
	_check_same_id_hand_motion_staging(table)
	var slot_state := UIPreviewStateFactory.battle_state()
	main.state = slot_state
	main.current_view_player = 0
	table.update_view(
		slot_state,
		0,
		UIPreviewStateFactory.action_rows(slot_state),
		"",
		false,
		"local",
	)
	await _check_network_attack_variant_menu(table, slot_state)
	_check_opponent_hand_mask_supersession(table)
	await _check_presentation_read_only_inspection(main, table, slot_state)
	var slot_options: Array[Dictionary] = []
	for bench_index in [2, 3, 4]:
		var slot := "bench_%d" % bench_index
		slot_options.append({
			"option_id": "slot:%s" % slot,
			"label": "备战席 %d" % (bench_index + 1),
			"ref": EntityRef.new("slot", 0, "", slot).to_dict(),
		})
	var slot_request := ChoiceView.new(
		"choice:nest-ball-slot",
		slot_state.revision,
		"select_bench_slot",
		0,
		"请选择「基础宝可梦」要放置的备战席。",
		slot_options,
		1,
		1,
		false,
		false,
		{
			"domain": "effect",
			"purpose": "search_bench_slot",
			"source_card_id": "svi-chim",
			"target_player": 0,
			"target_slots": ["bench_2", "bench_3", "bench_4"],
		},
	)
	main._show_choice_overlay(slot_request)
	await context._settle_layout(2)
	context._check(
		main.active_request == slot_request
		and not main.modal_layer.visible
		and table.choice_target_options.get("pokemon:0:bench_2")
			== "slot:bench_2"
		and table.choice_target_options.get("pokemon:0:bench_4")
			== "slot:bench_4"
		and table.get_slot_view(0, "bench_3").empty
		and table.get_slot_view(0, "bench_3").targetable,
		"Nest Ball slot ChoiceView did not expose empty Bench slots on the table",
	)
	main.active_request = null
	table.clear_choice_targets()
	var request := ChoiceView.new(
		"choice:prize-inspector-resume",
		-1,
		"select_prize",
		0,
		"请选择奖励牌。",
		[
			{"option_id": "prize:0", "label": "奖励牌 1"},
			{"option_id": "prize:1", "label": "奖励牌 2"},
		],
		1,
		1,
		false,
		false,
		{"domain": "knockout", "purpose": "select_prize"},
	)
	main._show_choice_overlay(request)
	context._check(
		main.active_request == request
		and table.choice_target_options.get("prize:0:0") == "prize:0",
		"Prize ChoiceView did not enter field-target mode",
	)

	var discard_context := {
		"player": 0,
		"title": "弃牌区",
		"zone": "discard",
		"card_ids": ["sv1-ener-2"],
	}
	main._show_zone_inspector(discard_context)
	await context._settle_layout(2)
	context._check(
		main.active_request == null
		and table.choice_target_options.is_empty()
		and main.modal_layer.visible,
		"Zone inspector did not suspend the underlying field ChoiceView",
	)
	main.modal_confirm.pressed.emit()
	await context._settle_layout(2)
	context._check(
		main.active_request != null
		and main.active_request.request_id == request.request_id
		and table.choice_target_options.get("prize:0:0") == "prize:0"
		and not main.modal_layer.visible,
		"Closing the discard inspector did not restore the Prize ChoiceView",
	)

	main._show_zone_inspector(discard_context)
	await context._settle_layout(2)
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await context._settle_layout(2)
	context._check(
		main.active_request != null
		and main.active_request.request_id == request.request_id
		and table.choice_target_options.get("prize:0:1") == "prize:1"
		and not main.modal_layer.visible,
		"System Back did not restore the Prize ChoiceView after zone inspection",
	)

	main._show_zone_inspector(discard_context)
	await context._settle_layout(2)
	var zone_cards: Array[Node] = main.modal_body.find_children(
		"*", "CardView", true, false
	)
	var zone_card := zone_cards[0] as CardView if not zone_cards.is_empty() else null
	context._check(zone_card != null,
		"Discard inspector exposes no card for nested inspector regression")
	if zone_card:
		zone_card.activated.emit("sv1-ener-2", -1, 0, "")
		await context._settle_layout(2)
		context._check(
			main.active_request == null and main.modal_layer.visible,
			"Nested card inspector prematurely restored the field ChoiceView",
		)
		main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
		await context._settle_layout(2)
		context._check(
			main.active_request == null
			and "弃牌区" in main.modal_title.text,
			"Nested card inspector did not return to its zone inspector",
		)
	main.modal_confirm.pressed.emit()
	await context._settle_layout(2)
	context._check(
		main.active_request != null
		and main.active_request.request_id == request.request_id
		and table.choice_target_options.get("prize:0:0") == "prize:0",
		"Nested discard-card inspection lost the Prize ChoiceView",
	)

	main._show_pause_overlay()
	await context._settle_layout(2)
	context._check(
		main.active_request == null
		and table.choice_target_options.is_empty()
		and main.modal_layer.visible,
		"Pause menu did not suspend the underlying field ChoiceView",
	)
	main.modal_confirm.pressed.emit()
	await context._settle_layout(2)
	context._check(
		main.active_request != null
		and main.active_request.request_id == request.request_id
		and table.choice_target_options.get("prize:0:0") == "prize:0",
		"Continuing from the pause menu lost the Prize ChoiceView",
	)

	main._show_pause_overlay()
	await context._settle_layout(2)
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await context._settle_layout(2)
	context._check(
		main.active_request != null
		and main.active_request.request_id == request.request_id
		and not main.modal_layer.visible,
		"System Back from the pause menu lost the Prize ChoiceView",
	)

	main._show_pause_overlay()
	await context._settle_layout(2)
	var pause_help := main.modal_body.find_child(
		"HelpButton", true, false
	) as Button
	context._check(pause_help != null,
		"Pause menu exposes no Help button for ChoiceView lifecycle regression")
	if pause_help:
		pause_help.pressed.emit()
		await context._settle_layout(2)
		context._check(
			main.active_request == null
			and table.choice_target_options.is_empty()
			and main.modal_layer.visible,
			"Pause-to-Help navigation prematurely restored the Prize ChoiceView",
		)
	main.modal_confirm.pressed.emit()
	await context._settle_layout(2)
	context._check(
		main.active_request != null
		and main.active_request.request_id == request.request_id
		and table.choice_target_options.get("prize:0:1") == "prize:1",
		"Closing Pause Help lost the Prize ChoiceView",
	)

	main._show_help()
	await context._settle_layout(2)
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await context._settle_layout(2)
	context._check(
		main.active_request != null
		and main.active_request.request_id == request.request_id
		and not main.modal_layer.visible,
		"System Back from direct battle Help lost the Prize ChoiceView",
	)

	main._show_settings()
	await context._settle_layout(2)
	context._check(
		main.active_request == null
		and table.choice_target_options.is_empty()
		and main.modal_layer.visible,
		"Battle Settings did not suspend the underlying field ChoiceView",
	)
	main.modal_cancel.pressed.emit()
	await context._settle_layout(2)
	context._check(
		main.active_request != null
		and main.active_request.request_id == request.request_id
		and table.choice_target_options.get("prize:0:0") == "prize:0",
		"Cancelling battle Settings lost the Prize ChoiceView",
	)

	main._show_settings()
	await context._settle_layout(2)
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await context._settle_layout(2)
	context._check(
		main.active_request != null
		and main.active_request.request_id == request.request_id
		and not main.modal_layer.visible,
		"System Back from battle Settings lost the Prize ChoiceView",
	)

	main.active_request = null
	main.selected_choice_ids.clear()
	table.clear_choice_targets()
	main.battle_screen = previous_battle
	main.current_screen = previous_screen
	table.queue_free()
	await context._settle_layout(2)


func _check_card_action_detail_separation(table: BattleTable) -> void:
	var state := UIPreviewStateFactory.battle_state()
	var rows := UIPreviewStateFactory.action_rows(state)
	var source_key := "hand:1"
	table.update_view(state, 0, rows, source_key, false, "local")
	var card_id := str(state.players[0].hand[1])
	table.show_card_detail(card_id)
	await context._settle_layout(2)
	var detail := table.detail_panel as BattleDetailPanel
	context._check(
		detail != null
		and detail.visible
		and detail.get_node_or_null("Content/ActionSection") == null
		and table.action_popover != null
		and table.action_popover.visible
		and table.action_popover.action_buttons.get_child_count() > 0,
		"Card actions must remain in CardActionPopover and outside the detail panel",
	)
	table.hide_card_detail()
	if table.action_popover:
		table.action_popover.dismiss(false)


func _check_network_attack_variant_menu(
	table: BattleTable,
	base_state: GameState,
) -> void:
	var state := base_state.clone_state()
	state.players[0].active = PokemonState.new("svg-tatsu")
	state.players[0].active.energy_card_ids.assign([
		"sv1-ener-3", "svi-mirc",
	])
	var rows: Array[Dictionary] = []
	for attack_index in [0, 1]:
		var action := GameAction.create(
			"DECLARE_ATTACK",
			{"attack_index": attack_index},
			0,
			EntityRef.new(
				"pokemon", 0, "", "active", -1, "", "svg-tatsu",
			),
			null,
			"attack:%d" % attack_index,
			state.revision,
		).to_dict()
		var wire_value: Variant = JSON.parse_string(JSON.stringify(action))
		if wire_value is Dictionary:
			rows.append({
				"action": GameAction.from_dict(Dictionary(wire_value)),
				"label": "攻击",
			})
	table.hide_card_detail()
	table.update_view(
		state,
		0,
		rows,
		"pokemon:0:active",
		false,
		"network",
	)
	await context._settle_layout(2)
	var groups := table.interaction_router.action_groups_for_source(
		"pokemon:0:active",
	)
	var labels: Array[String] = []
	if table.action_popover != null:
		for row in table.action_popover._rows:
			labels.append(str(Dictionary(row).get("label", "")))
	var has_second_attack := false
	for label in labels:
		if "生存战略" in label:
			has_second_attack = true
			break
	context._check(
		groups.size() == 2
		and table.action_popover != null
		and table.action_popover.button_count() == 2
		and has_second_attack,
		"Network numeric conversion collapsed Tatsugiri's second attack in the action menu",
	)
	table.update_view(
		base_state,
		0,
		UIPreviewStateFactory.action_rows(base_state),
		"",
		false,
		"local",
	)


func _check_opponent_hand_mask_supersession(table: BattleTable) -> void:
	context._check(
		not table.opponent_hand_views.is_empty(),
		"Opponent-hand mask fixture has no CardView",
	)
	if table.opponent_hand_views.is_empty():
		return
	var card := table.opponent_hand_views[0] as CardView
	card.set_presentation_hidden(true)
	table.hand_presentation._presentation_opponent_hand_nodes.assign([card])
	table.presentation_runtime.mask_counts[card.get_instance_id()] = 1
	table.hand_presentation._clear_opponent_hand_transaction(false)
	context._check(
		not card.is_presentation_hidden()
		and is_equal_approx(card.content_root.modulate.a, 1.0)
		and not table.presentation_runtime.mask_counts.has(card.get_instance_id()),
		"Superseded opponent-hand transaction left card backs masked",
	)


func _check_presentation_read_only_inspection(
	main: Control,
	table: BattleTable,
	base_state: GameState,
) -> void:
	var previous_state: GameState = main.state
	var previous_mode: String = str(main.game_mode)
	var previous_ai_thinking: bool = bool(main.ai_thinking)
	var previous_selected_key: String = str(main.selected_entity_key)
	var previous_selected_identity: String = str(main.selected_entity_identity)
	var inspection_state := base_state.clone_state()
	inspection_state.active_player_idx = 1
	main.state = inspection_state
	main.game_mode = "challenge"
	main.ai_thinking = true
	main.selected_entity_key = ""
	main.selected_entity_identity = ""
	table.update_view(inspection_state, 0, [], "", true, "challenge")
	var opponent := inspection_state.get_player(1).active
	context._check(opponent != null,
		"Read-only presentation inspection fixture has no opponent Active Pokemon")
	if opponent == null:
		return
	main._on_battle_pokemon_selected(1, "active", opponent.card_id)
	await context._settle_layout(2)
	var detail := table.detail_panel as BattleDetailPanel
	context._check(
		detail != null
		and detail.visible
		and detail.current_card_id == opponent.card_id
		and table._read_only_detail_key == "pokemon:1:active"
		and table.selected_entity_key.is_empty()
		and main.selected_entity_key.is_empty(),
		"Opponent-turn inspection mutated selection or failed to open lightweight detail",
	)
	# A stale source selection may survive from the outgoing local turn. The
	# read-only opponent inspection must remain authoritative until the player
	# explicitly closes it instead of snapping back to that old source.
	table.update_view(
		inspection_state,
		0,
		[],
		"pokemon:0:active",
		true,
		"challenge",
	)
	context._check(
		detail != null
		and detail.visible
		and detail.current_card_id == opponent.card_id
		and table._read_only_detail_key == "pokemon:1:active",
		"Read-only detail was replaced by stale selection during presentation refresh",
	)
	context._check(
		table.action_popover == null or not table.action_popover.visible,
		"Stale interactive action popover covered read-only opponent inspection",
	)
	table.update_view(inspection_state, 0, [], "", true, "challenge")
	table.hide_card_detail()
	var blocker := table.input_blocker
	context._check(
		blocker != null
		and blocker.gui_input.is_connected(
			Callable(table, "_on_presentation_input_blocker_gui_input")
		),
		"Presentation blocker does not expose the read-only inspection route",
	)
	context._check(
		detail != null
		and not detail.z_as_relative
		and detail.z_index > blocker.z_index,
		"Read-only detail must remain interactive above the presentation blocker",
	)
	table.set_transition_blocked(true)
	var opponent_view := table.get_slot_view(1, "active")
	if blocker != null and opponent_view != null:
		var local_point := (
			blocker.get_global_transform_with_canvas().affine_inverse()
			* opponent_view.global_center()
		)
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = local_point
		blocker.gui_input.emit(press)
		context._check(
			detail != null
			and detail.visible
			and detail.current_card_id == opponent.card_id,
			"Presentation inspection did not respond on pointer press",
		)
		blocker.gui_input.emit(press)
		context._check(
			detail != null
			and detail.visible
			and detail.current_card_id == opponent.card_id,
			"Rapid repeated inspection closed the detail it had just opened",
		)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = local_point
		blocker.gui_input.emit(release)
	await context._settle_layout(2)
	context._check(
		detail != null
		and detail.visible
		and detail.current_card_id == opponent.card_id
		and table._read_only_detail_key == "pokemon:1:active",
		"Blocked opponent animation did not allow public card inspection",
	)
	table.set_transition_blocked(false)
	if detail != null and detail.close_button != null:
		detail.close_button.pressed.emit()
	context._check(
		table._read_only_detail_key.is_empty()
		and (detail == null or not detail.visible),
		"Closing read-only detail leaked its presentation inspection context",
	)
	main.state = previous_state
	main.game_mode = previous_mode
	main.ai_thinking = previous_ai_thinking
	main.selected_entity_key = previous_selected_key
	main.selected_entity_identity = previous_selected_identity
	table.update_view(
		base_state,
		0,
		UIPreviewStateFactory.action_rows(base_state),
		"",
		false,
		"local",
	)


func _check_discard_zone_action_reachability(table: BattleTable) -> void:
	var state := GameState.new()
	state.setup_stage = GameState.SETUP_COMPLETE
	state.phase = "MAIN"
	state.turn_number = 3
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.players[0].active = PokemonState.new("svg2-pipl")
	state.players[0].active.placed_this_turn = false
	state.players[0].hand = []
	state.players[0].discard = ["sv1-151", "svg2-empo"]
	state.players[0].deck = ["sv1-150", "sv1-153", "sv1-176"]
	var ability := GameAction.create(
		"USE_ABILITY",
		{"ability_name": "紧急上浮"},
		0,
		EntityRef.new("card", 0, "discard", "", 1, "", "svg2-empo"),
		null,
		"ui:discard-ability",
		state.revision,
	)
	var source_key := BattleInteractionController.zone_key(0, "discard")
	table.update_view(
		state,
		0,
		[{"action": ability, "label": "特性 · 紧急上浮"}],
		"",
		false,
		"local",
	)
	var discard_zone := table.zones.get("own_discard") as ZoneView
	context._check(
		BattleInteractionController.source_key_for_action(ability) == source_key
		and table.interaction_router.has_source(source_key)
		and source_key in table.visible_card_source_keys()
		and table.all_card_actions_reachable_from_visible_cards()
		and discard_zone != null
		and discard_zone.is_actionable()
		and discard_zone.action_button.visible
		and discard_zone.action_button.text == "可用操作"
		and table.board_view._source_control_for_key(source_key) == discard_zone,
		"Empty-hand discard-zone Ability was not reachable from its public zone",
	)
	if discard_zone:
		var inspected_contexts: Array[Dictionary] = []
		var capture_inspection := func(context: Dictionary) -> void:
			inspected_contexts.append(context.duplicate(true))
		table.inspect_zone_requested.connect(capture_inspection)
		table.board_view._on_zone_inspected(discard_zone.inspect_context)
		context._check(
			inspected_contexts.size() == 1
			and str(inspected_contexts[0].get("zone", "")) == "discard"
			and (table.action_popover == null or not table.action_popover.visible),
			"Tapping an actionable discard zone did not preserve pile inspection",
		)
		table.inspect_zone_requested.disconnect(capture_inspection)
		discard_zone.action_button.pressed.emit()
		context._check(
			table.action_popover != null
			and table.action_popover.visible
			and table._popover_source_key == source_key,
			"Discard zone's independent action button did not expose Empoleon's Ability",
		)
		if table.action_popover:
			table.action_popover.dismiss(false)


func _check_same_id_hand_motion_staging(table: BattleTable) -> void:
	var before := GameState.new()
	before.setup_stage = GameState.SETUP_COMPLETE
	before.phase = "MAIN"
	before.turn_number = 3
	before.first_player_idx = 1
	before.active_player_idx = 0
	before.players[0].active = PokemonState.new("svi-chim")
	before.players[0].active.placed_this_turn = false
	before.players[0].hand = ["sv1-189", "sv1-ener-2", "svi-chim"]
	before.players[0].deck = [
		"sv1-150", "sv1-189", "sv1-153", "sv1-176",
		"sv1-151", "sv1-ener-2", "svf-potion",
	]
	table.update_view(before, 0, [], "", false, "local")
	var snapshot := table.capture_presentation_snapshot()
	var old_visual_ids: Dictionary = {}
	for row_value in snapshot.get("hand", []):
		var row: Dictionary = row_value
		old_visual_ids[str(row.get("card_id", ""))] = str(
			row.get("visual_id", ""),
		)
	var raw_events: Array = [
		{
			"event_id": "same-id:trainer",
			"event_type": "trainer_played",
			"actor": 0,
			"card_id": "sv1-189",
			"amount": 1,
			"source": {"player": 0, "zone": "hand", "index": 0},
			"target": {"player": 0, "zone": "discard"},
			"data": {"player": 0, "card_ids": ["sv1-189"], "count": 1},
		},
		{
			"event_id": "same-id:discard",
			"event_type": "cards_discarded",
			"actor": 0,
			"amount": 2,
			"source": {"player": 0, "zone": "hand"},
			"target": {"player": 0, "zone": "discard"},
			"data": {
				"player": 0,
				"card_ids": ["sv1-ener-2", "svi-chim"],
				"count": 2,
				"source_zone": "hand",
				"target_zone": "discard",
			},
		},
		{
			"event_id": "same-id:draw",
			"event_type": "cards_drawn",
			"actor": 0,
			"amount": 7,
			"source": {"player": 0, "zone": "deck"},
			"target": {"player": 0, "zone": "hand"},
			"data": {
				"player": 0,
				"card_ids": [
					"svf-potion", "sv1-ener-2", "sv1-151", "sv1-176",
					"sv1-153", "sv1-189", "sv1-150",
				],
				"count": 7,
				"source_zone": "deck",
				"target_zone": "hand",
			},
		},
	]
	table.prepare_hand_identity_transition(raw_events, snapshot)
	context._check(
		table._pending_removed_hand_visual_ids.size() == 3,
		"Same-id replacement did not retire every physical pre-resolution hand card",
	)
	var after := before.clone_state()
	after.revision += 1
	after.players[0].hand = [
		"svf-potion", "sv1-ener-2", "sv1-151", "sv1-176",
		"sv1-153", "sv1-189", "sv1-150",
	]
	after.players[0].deck = []
	after.players[0].discard = ["sv1-ener-2", "svi-chim", "sv1-189"]
	table.update_view(after, 0, [], "", false, "local")
	var replacement_ids: Dictionary = {}
	for view in table.hand_views:
		if view and view.visible and view.card_id in ["sv1-189", "sv1-ener-2"]:
			replacement_ids[view.card_id] = view.local_visual_id
	context._check(
		str(replacement_ids.get("sv1-189", ""))
			!= str(old_visual_ids.get("sv1-189", ""))
		and str(replacement_ids.get("sv1-ener-2", ""))
			!= str(old_visual_ids.get("sv1-ener-2", "")),
		"Drawn same-id cards reused discarded hand visual identities",
	)
	var events := PresentationEvent.normalize_all(raw_events, after.revision, 0)
	table.presentation_runtime._stage_presentation_targets(events, snapshot)
	context._check(
		Array(table.presentation_runtime.event_hand_sources.get(
			"same-id:trainer", [],
		)).size() == 1
		and Array(table.presentation_runtime.event_hand_sources.get(
			"same-id:discard", [],
		)).size() == 2
		and Array(table.presentation_runtime.event_hand_targets.get(
			"same-id:draw", [],
		)).size() == 7,
		"Same-id discard/draw batch did not stage every source and landing animation",
	)
	table.clear_presentation_for_resync()


func _check_pointer_only_input_contract(main: Control) -> void:
	context._check(
		context.tree.root.get_node_or_null("FrontendFocus") == null,
		"Legacy keyboard/controller focus autoload must not be present",
	)
	for action in context.DISABLED_UI_ACTIONS:
		context._check(
			InputMap.has_action(action)
			and InputMap.action_get_events(action).is_empty(),
			"Built-in navigation action must have no bindings: %s" % action,
		)
	context._check_pointer_only_controls(main, "main-startup")
	var initial_screen: int = int(main.get("current_screen"))
	var keyboard_event := InputEventKey.new()
	keyboard_event.keycode = KEY_ENTER
	keyboard_event.pressed = true
	Input.parse_input_event(keyboard_event)
	var joypad_event := InputEventJoypadButton.new()
	joypad_event.button_index = JOY_BUTTON_A
	joypad_event.pressed = true
	Input.parse_input_event(joypad_event)
	await context._settle_layout(2)
	context._check(
		int(main.get("current_screen")) == initial_screen
		and context.tree.root.gui_get_focus_owner() == null
		and not main.modal_layer.visible,
		"Keyboard/controller input must not focus, activate, or reroute the UI",
	)


func _check_open_modal_resize(main: Control) -> void:
	var resize_host := Control.new()
	resize_host.name = "OpenModalResizeHost"
	resize_host.size = Vector2(1600, 900)
	context.tree.root.add_child(resize_host)
	main.reparent(resize_host)
	main.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await context._settle_layout(3)
	main.shell_view.apply_safe_area()
	main._show_settings()
	await context._settle_layout(4)
	var wide_scroll_floor: float = main.modal_scroll.custom_minimum_size.y
	resize_host.size = Vector2(1024, 600)
	await context._settle_layout(2)
	main.shell_view.apply_safe_area()
	await context._settle_layout(5)
	var modal_center := main.get_node("ModalLayer/Center") as Control
	context._check(
		context._rect_inside(main.modal_panel.get_global_rect(), modal_center.get_global_rect())
		and main.modal_panel.size.x <= modal_center.size.x + context.EPSILON
		and main.modal_panel.size.y <= modal_center.size.y + context.EPSILON
		and main.modal_scroll.custom_minimum_size.y < wide_scroll_floor
		and main.modal_scroll.get_global_rect().size.y
		<= main.modal_panel.get_global_rect().size.y,
		"Open PREFERRED modal retained its wide scroll floor or escaped the resized safe center: panel=%s min=%s center=%s scroll_min=%.1f/%.1f scroll=%s" % [
			main.modal_panel.get_global_rect(), main.modal_panel.custom_minimum_size,
			modal_center.get_global_rect(), main.modal_scroll.custom_minimum_size.y,
			wide_scroll_floor, main.modal_scroll.get_global_rect(),
		],
	)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)

	resize_host.size = Vector2(1600, 900)
	await context._settle_layout(2)
	main.shell_view.apply_safe_area()
	var fill_spec := ModalSpec.frontend(
		Vector2(900, 760), ModalSpec.SizeMode.FILL_SAFE
	)
	main.modal_host_controller.open("安全区填充测试", "确认", "取消", false, fill_spec)
	var tall_body := Control.new()
	tall_body.custom_minimum_size = Vector2(0, 900)
	main.modal_body.add_child(tall_body)
	await context._settle_layout(4)
	var fill_wide_scroll_floor: float = main.modal_scroll.custom_minimum_size.y
	resize_host.size = Vector2(1024, 600)
	await context._settle_layout(2)
	main.shell_view.apply_safe_area()
	await context._settle_layout(5)
	context._check(
		context._rect_inside(main.modal_panel.get_global_rect(), modal_center.get_global_rect())
		and main.modal_panel.size.x <= modal_center.size.x + context.EPSILON
		and main.modal_panel.size.y <= modal_center.size.y + context.EPSILON
		and main.modal_scroll.custom_minimum_size.y < fill_wide_scroll_floor
		and main.modal_scroll.get_v_scroll_bar().visible,
		"Open FILL_SAFE modal did not rebudget its scroll body inside the resized safe center: panel=%s min=%s center=%s scroll_min=%.1f/%.1f vbar=%s" % [
			main.modal_panel.get_global_rect(), main.modal_panel.custom_minimum_size,
			modal_center.get_global_rect(), main.modal_scroll.custom_minimum_size.y,
			fill_wide_scroll_floor, main.modal_scroll.get_v_scroll_bar().visible,
		],
	)
	main.modal_host_controller.close()
	main.modal_host_controller.finish_close(main.modal_host_controller.generation)
	main.reparent(context.tree.root)
	main.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resize_host.queue_free()
	await context._settle_layout(3)
