extends SceneTree

const OUTPUT_ROOT := "res://../build/ui-preview"


func _initialize() -> void:
	root.size = Vector2i(1600, 900)
	call_deferred("_render_previews")


func _render_previews() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_ROOT))
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	if packed == null:
		push_error("Unable to load main UI scene")
		quit(1)
		return
	var ui := packed.instantiate()
	root.add_child(ui)
	ui.initialize_ui()
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("title.png"):
		quit(1)
		return
	ui._show_help()
	await process_frame
	await create_timer(0.2).timeout
	if not _capture("help.png"):
		quit(1)
		return
	ui._close_modal()

	ui.show_network_setup("relay")
	await process_frame
	await create_timer(0.2).timeout
	if not _capture("network.png"):
		quit(1)
		return

	ui.show_title()
	ui.show_settings()
	await process_frame
	await create_timer(0.2).timeout
	if not _capture("settings.png"):
		quit(1)
		return
	ui._close_modal()

	ui.show_deck_select()
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("decks.png"):
		quit(1)
		return
	ui._show_deck_details("fire")
	await process_frame
	await create_timer(0.2).timeout
	if not _capture("deck-detail.png"):
		quit(1)
		return
	ui._close_modal()

	if not ui.start_local_match_for_test("fire", "water"):
		push_error("Unable to start preview match")
		quit(1)
		return
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("privacy.png"):
		quit(1)
		return

	ui._close_modal()
	ui._refresh_game()
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("game.png"):
		quit(1)
		return
	root.size = Vector2i(2000, 900)
	await process_frame
	await create_timer(0.1).timeout
	if not _capture("game-20x9.png"):
		quit(1)
		return
	root.size = Vector2i(1600, 900)
	await process_frame

	var demo := GameState.new()
	demo.phase = "MAIN"
	demo.turn_number = 4
	demo.first_player_idx = 1
	demo.active_player_idx = 0
	demo.stadium_card_id = "sv1-171"
	demo.players[0].name = "玩家 1"
	demo.players[1].name = "玩家 2"
	demo.players[0].active = PokemonState.new("svi-hrot")
	demo.players[0].active.placed_this_turn = false
	demo.players[0].active.energy_card_ids.assign([
		"sv1-ener-2", "sv1-ener-2", "svi-mirc",
	])
	demo.players[0].active.damage_counters = 2
	demo.players[0].active.attached_tool_id = "sv1-202"
	demo.players[0].active.status_conditions.assign(["BURNED"])
	demo.players[0].bench[0] = PokemonState.new("svi-chim")
	demo.players[0].bench[0].energy_card_ids.assign(["sv1-ener-2"])
	demo.players[0].bench[1] = PokemonState.new("svi-ente")
	demo.players[1].active = PokemonState.new("sv2-keldeo")
	demo.players[1].active.placed_this_turn = false
	demo.players[1].active.damage_counters = 4
	demo.players[1].active.energy_card_ids.assign(["sv1-ener-3"])
	demo.players[1].active.status_conditions.assign(["POISONED"])
	demo.players[1].bench[0] = PokemonState.new("sv2-starm")
	demo.players[0].hand = [
		"sv1-ener-2", "sv1-189", "svf-potion", "sv1-151", "svi-jete",
	]
	for index in range(43):
		demo.players[0].deck.append([
			"sv1-ener-2", "svi-chim", "sv1-189", "svf-potion",
		][index % 4])
	for _index in range(43):
		demo.players[1].deck.append("")
	demo.players[0].discard = ["sv1-180"]
	demo.players[1].discard = ["sv1-176"]
	demo.players[0].prizes = ["sv1-ener-2", "sv1-151", "sv1-189", "svf-potion"]
	demo.players[1].prizes = ["", "", "", "", "", ""]
	demo.players[1].hand = ["", "", "", "", "", ""]
	demo.log_action("玩家1附着了火能量。")
	demo.log_action("玩家2的宝可梦受到40点伤害。")
	ui.state = demo
	ui.current_view_player = 0
	ui._build_game_screen()
	await process_frame
	await create_timer(0.2).timeout
	if not _capture("battle-populated.png"):
		quit(1)
		return
	demo.active_player_idx = 1
	demo.players[1].name = "Challenge AI"
	ui.game_mode = "challenge"
	ui.ai_thinking = true
	ui._refresh_game()
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("ai-thinking.png"):
		quit(1)
		return
	ui.ai_thinking = false
	ui.game_mode = "local"
	demo.active_player_idx = 0
	ui._refresh_game()
	await process_frame
	ui._show_card_inspector({
		"card_id": "svi-hrot",
		"pokemon": demo.players[0].active,
		"location": "玩家 1 战斗区",
	})
	await process_frame
	await create_timer(0.2).timeout
	if not _capture("card-inspector.png"):
		quit(1)
		return
	ui._close_modal()
	ui._show_zone_inspector({
		"title": "弃牌",
		"player": 0,
		"zone": "discard",
		"card_ids": ["sv1-180", "sv1-189", "svf-potion"],
		"count": 3,
		"hidden": false,
	})
	await process_frame
	await create_timer(0.2).timeout
	if not _capture("zone-inspector.png"):
		quit(1)
		return
	ui._close_modal()
	await process_frame
	await create_timer(0.22).timeout
	ui.selected_entity_key = "hand:1"
	ui._refresh_game()
	await process_frame
	await create_timer(0.12).timeout
	if not _capture("card-actions.png"):
		quit(1)
		return
	ui.selected_entity_key = ""
	ui._refresh_game()

	ui.battle_screen.play_presentation([{
		"event_type": "cards_drawn",
		"actor": 0,
		"visibility": "owner",
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "hand"},
		"amount": 3,
		"data": {
			"player": 0,
			"count": 3,
			"card_ids": ["sv1-ener-2", "sv1-151", "svf-potion"],
		},
	}], demo.revision + 10, 0)
	await create_timer(0.24).timeout
	if not _capture("draw.png"):
		quit(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	ui.battle_screen.play_presentation([{
		"event_type": "cards_discarded",
		"actor": 0,
		"source": {"player": 0, "zone": "hand"},
		"target": {"player": 0, "zone": "discard"},
		"amount": 3,
		"data": {
			"player": 0,
			"count": 3,
			"card_ids": ["sv1-ener-2", "sv1-189", "svf-potion"],
		},
	}], demo.revision + 11, 0)
	await create_timer(0.26).timeout
	if not _capture("discard.png"):
		quit(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	ui.battle_screen.play_presentation([{
		"event_type": "deck_shuffled",
		"actor": 0,
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "deck"},
		"data": {"player": 0},
	}], demo.revision + 111, 0)
	await create_timer(0.24).timeout
	if not _capture("shuffle.png"):
		quit(1)
		return
	ui.battle_screen.clear_presentation_for_resync()

	var energy_snapshot: Dictionary = ui.battle_screen.capture_presentation_snapshot()
	if not demo.players[0].hand.is_empty():
		demo.players[0].hand.remove_at(0)
	demo.players[0].active.energy_card_ids.append("sv1-ener-2")
	ui._refresh_game()
	await process_frame
	ui.battle_screen.play_presentation([{
		"event_type": "energy_attached",
		"actor": 0,
		"card_id": "sv1-ener-2",
		"source": {"player": 0, "zone": "hand", "index": 0},
		"target": {"player": 0, "slot": "active"},
		"data": {
			"player": 0,
			"slot": "active",
			"card_id": "sv1-ener-2",
			"source_zone": "hand",
			"source_index": 0,
		},
	}], demo.revision + 12, 0, energy_snapshot)
	await create_timer(0.24).timeout
	if not _capture("energy-attach.png"):
		quit(1)
		return
	ui.battle_screen.clear_presentation_for_resync()

	var evolution_card_id := "svi-infr"
	demo.players[0].hand.append(evolution_card_id)
	ui._refresh_game()
	await process_frame
	var evolve_snapshot: Dictionary = ui.battle_screen.capture_presentation_snapshot()
	var evolve_hand_index := demo.players[0].hand.size() - 1
	var old_active_card_id: String = demo.players[0].active.card_id
	demo.players[0].hand.remove_at(evolve_hand_index)
	demo.players[0].active.evolution_stack_ids.append(old_active_card_id)
	demo.players[0].active.card_id = evolution_card_id
	ui._refresh_game()
	await process_frame
	ui.battle_screen.play_presentation([{
		"event_type": "pokemon_evolved",
		"actor": 0,
		"card_id": evolution_card_id,
		"source": {"player": 0, "zone": "hand", "index": evolve_hand_index},
		"target": {"player": 0, "slot": "active"},
		"data": {
			"player": 0,
			"slot": "active",
			"card_id": evolution_card_id,
			"source_zone": "hand",
			"source_index": evolve_hand_index,
		},
	}], demo.revision + 13, 0, evolve_snapshot)
	await create_timer(0.34).timeout
	if not _capture("evolve.png"):
		quit(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	demo.players[0].active.card_id = old_active_card_id
	demo.players[0].active.evolution_stack_ids.erase(old_active_card_id)
	ui._refresh_game()
	await process_frame

	var choice := ChoiceRequest.new(
		"preview-choice",
		"search",
		0,
		"选择一张要加入手牌的卡牌",
		[
			{
				"option_id": "card:deck:0:sv1-189",
				"label": "博士的研究",
				"value": {"index": 0, "card_id": "sv1-189"},
			},
			{
				"option_id": "card:deck:1:sv1-151",
				"label": "高级球",
				"value": {"index": 1, "card_id": "sv1-151"},
			},
			{
				"option_id": "card:deck:2:svf-potion",
				"label": "伤药",
				"value": {"index": 2, "card_id": "svf-potion"},
			},
		],
		1,
		1,
	)
	ui.show_choice(choice)
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("choice.png"):
		quit(1)
		return
	ui._close_modal()

	var energy_choice := ChoiceRequest.new(
		"preview-energy-choice",
		"distribute_energy",
		0,
		"为每张能量选择附着目标。",
		[
			{
				"option_id": "pokemon:0:active:svi-hrot",
				"label": "加热洛托姆",
				"value": {"slot": "active", "card_id": "svi-hrot"},
			},
			{
				"option_id": "pokemon:0:bench_0:svi-chim",
				"label": "小火焰猴",
				"value": {"slot": "bench_0", "card_id": "svi-chim"},
			},
		],
		2,
		2,
		true,
	)
	var energy_stack := ResolutionStack.new()
	energy_stack.push_continuation("energy_attach_distribution", {
		"player_idx": 0,
		"source_zone": "hand",
		"card_ids": ["sv1-ener-2", "sv1-ener-2"],
	})
	energy_stack.pending_request = energy_choice
	demo.resolution_stack = energy_stack.to_dict()
	ui.show_choice(energy_choice)
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("choice-energy.png"):
		quit(1)
		return
	ui._close_modal()

	ui.battle_screen.play_presentation([
		{
			"event_type": "attack_declared",
			"actor": 0,
			"card_id": "svi-hrot",
			"source": {"player": 0, "slot": "active"},
			"target": {"player": 1, "slot": "active"},
			"data": {"attack_name": "高温冲击"},
		},
		{
			"event_type": "damage_dealt",
			"actor": 0,
			"amount": 90,
			"target": {"player": 1, "slot": "active"},
			"data": {"player": 1, "slot": "active", "amount": 90},
		},
	], demo.revision, 0)
	await create_timer(0.18).timeout
	if not _capture("attack.png"):
		quit(1)
		return
	await create_timer(0.72).timeout
	if not _capture("impact.png"):
		quit(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	ui.battle_screen.play_presentation([{
		"event_type": "pokemon_ko",
		"actor": 0,
		"card_id": "sv2-keldeo",
		"source": {"player": 1, "slot": "active"},
		"target": {"player": 1, "zone": "discard"},
		"data": {"player": 1, "slot": "active", "card_id": "sv2-keldeo"},
	}], demo.revision + 1, 0)
	await create_timer(0.18).timeout
	if not _capture("ko.png"):
		quit(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	demo.winner = 0
	demo.phase = "GAME_OVER"
	ui._show_end_screen()
	await process_frame
	await create_timer(0.5).timeout
	if not _capture("end.png"):
		quit(1)
		return
	ui.queue_free()
	await process_frame

	var workbench_scene := load("res://tools/ui_workbench.tscn") as PackedScene
	var workbench := workbench_scene.instantiate()
	root.add_child(workbench)
	await process_frame
	await create_timer(0.2).timeout
	if not _capture("workbench.png"):
		quit(1)
		return
	print("UI_PREVIEWS_OK")
	quit(0)


func _capture(filename: String) -> bool:
	var texture := root.get_texture()
	if texture == null:
		push_error("Unable to capture preview %s: viewport texture is unavailable" % filename)
		return false
	var image := texture.get_image()
	if image == null:
		push_error("Unable to capture preview %s: viewport image is unavailable" % filename)
		return false
	var result := image.save_png(ProjectSettings.globalize_path(
		"%s/%s" % [OUTPUT_ROOT, filename]))
	if result != OK:
		push_error("Unable to save preview %s" % filename)
		return false
	return true
