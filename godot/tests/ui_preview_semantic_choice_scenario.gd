extends RefCounted

var harness: Variant


func configure(preview_harness: Variant) -> void:
	harness = preview_harness


func run(ui: Control) -> void:
	var demo := UIPreviewStateFactory.battle_state()
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await harness._settle_rendered(4)

	var switch_choice := ChoiceView.new(
		"preview-switch-confirm-only", demo.revision, "confirm", 0,
		"是否将这只宝可梦与备战宝可梦互换？",
		[
			{"option_id": "confirm:yes", "label": "进行换位"},
			{"option_id": "confirm:no", "label": "不进行换位"},
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
	ui._show_choice_overlay(switch_choice)
	ui._toggle_choice("confirm:yes")
	await harness._settle_rendered(4)
	if not harness._capture("choice-switch-confirm.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)

	var treasure_options: Array[Dictionary] = []
	for row in [
		{"slot": "active", "card_id": demo.players[0].active.card_id},
		{"slot": "bench_0", "card_id": demo.players[0].bench[0].card_id},
	]:
		treasure_options.append({
			"option_id": "pokemon:0:%s:%s" % [row["slot"], row["card_id"]],
			"label": ui.catalog.card_name(row["card_id"]),
			"ref": EntityRef.new(
				"pokemon", 0, "", row["slot"], -1, "", row["card_id"],
			).to_dict(),
		})
	var treasure_choice := ChoiceView.new(
		"preview-treasure-energy-only", demo.revision,
		"select_prize_energy_target", 0,
		"请选择宝藏能量的附着目标，或不发动效果。",
		treasure_options, 0, 1, false, true,
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
	ui._show_choice_overlay(treasure_choice)
	ui._toggle_choice(str(treasure_options[1]["option_id"]))
	await harness._settle_rendered(4)
	if not harness._capture("choice-treasure-energy.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(4)
	if not harness._capture("choice-treasure-energy-compact.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_rendered(3)
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)

	var bench_slot_options: Array[Dictionary] = []
	for bench_index in [2, 3, 4]:
		var bench_slot := "bench_%d" % bench_index
		bench_slot_options.append({
			"option_id": "slot:%s" % bench_slot,
			"label": "备战席 %d" % (bench_index + 1),
			"ref": EntityRef.new(
				"slot", 0, "", bench_slot,
			).to_dict(),
		})
	var nest_ball_slot_choice := ChoiceView.new(
		"preview-nest-ball-slot-semantic-only",
		demo.revision,
		"select_bench_slot",
		0,
		"请选择「小火焰猴」要放置的备战席。",
		bench_slot_options,
		1,
		1,
		false,
		false,
		{
			"domain": "effect",
			"purpose": "search_bench_slot",
			"source_player": 0,
			"source_card_id": "svi-chim",
			"target_player": 0,
			"target_slots": ["bench_2", "bench_3", "bench_4"],
		},
	)
	if ui.battle_screen == null:
		ui.state = demo
		ui.current_view_player = 0
		ui.game_mode = "local"
		ui.shell_view.build_game_screen()
		ui.battle_screen.set_local_hand_privacy_hidden(false)
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await harness._settle_rendered(4)
	ui._show_choice_overlay(nest_ball_slot_choice)
	await harness._settle_rendered(4)
	if not harness._capture("choice-nest-ball-bench-slot.png"):
		harness._finish(1)
		return

	var exp_share_choice := ChoiceView.new(
		"preview-exp-share-confirm-only", demo.revision,
		"confirm_trigger", 0,
		"是否发动学习装置，将昏厥宝可梦的1张基本能量转附到备战宝可梦？",
		[
			{"option_id": "confirm:yes", "label": "发动学习装置"},
			{"option_id": "confirm:no", "label": "不发动"},
		],
		1, 1, false, false,
		{
			"domain": "trigger",
			"purpose": "confirm_exp_share_trigger",
			"source_player": 0,
			"source_slot": "active",
			"source_card_id": demo.players[0].active.card_id,
			"target_player": 0,
			"target_slot": "bench_0",
			"card_id": "svg2-exps",
			"revealed_card_ids": ["svg2-exps"],
		},
	)
	ui._show_choice_overlay(exp_share_choice)
	ui._toggle_choice("confirm:yes")
	await harness._settle_rendered(4)
	if not harness._capture("choice-exp-share-confirm.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)

	var browse_refs: Array[Dictionary] = []
	var browse_options: Array[Dictionary] = []
	var browse_ids: Array[String] = [
		"svi-chim", "svf-potion", "sv1-ener-2",
	]
	for index in range(24):
		var card_id := browse_ids[index % browse_ids.size()]
		var ref := EntityRef.new(
			"card", 0, "deck", "", index, "", card_id,
		).to_dict()
		browse_refs.append(ref)
		if index % 6 == 0:
			browse_options.append({
				"option_id": "deck:%d" % index,
				"label": ui.catalog.card_name(card_id),
				"ref": ref,
			})
	var deck_search_choice := ChoiceView.new(
		"preview-deck-search",
		demo.revision,
		"search_move",
		0,
		"请选择要加入手牌的基础宝可梦。",
		browse_options,
		0,
		2,
		false,
		false,
		{
			"domain": "search",
			"purpose": "search_move",
			"source_player": 0,
			"source_zone": "deck",
			"browse_card_refs": browse_refs,
		},
	)
	ui._show_choice_overlay(deck_search_choice)
	await harness._settle_rendered(4)
	if not harness._capture("choice-deck-search-valid.png"):
		harness._finish(1)
		return
	ui.active_choice_panel.browse_all_button.pressed.emit()
	await harness._settle_rendered(4)
	if not harness._capture("choice-deck-search-all.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(4)
	if not harness._capture("choice-deck-search-compact.png"):
		harness._finish(1)
		return
	print("SEMANTIC_CHOICE_PREVIEWS_OK")
	harness._finish(0)
