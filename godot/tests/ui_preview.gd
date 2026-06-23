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

	ui._show_deck_select()
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("decks.png"):
		quit(1)
		return

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
	demo.players[0].active.energy_card_ids = ["sv1-ener-2", "sv1-ener-2"]
	demo.players[0].bench[0] = PokemonState.new("svi-chim")
	demo.players[0].bench[1] = PokemonState.new("svi-ente")
	demo.players[1].active = PokemonState.new("sv2-keldeo")
	demo.players[1].active.placed_this_turn = false
	demo.players[1].active.damage_counters = 4
	demo.players[1].bench[0] = PokemonState.new("sv2-starm")
	demo.players[0].hand = [
		"sv1-ener-2", "sv1-189", "svf-potion", "sv1-151", "svi-jete",
	]
	demo.players[0].deck = ["sv1-ener-2", "svi-chim", "sv1-189"]
	demo.players[1].deck = ["sv1-ener-3", "sv2-keldeo", "sv2-starm"]
	demo.players[0].discard = ["sv1-180"]
	demo.players[1].discard = ["sv1-176"]
	demo.players[0].prizes = ["sv1-ener-2", "sv1-151", "sv1-189"]
	demo.players[1].prizes = ["sv1-ener-3", "sv2-catch"]
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
	ui._show_choice_overlay(choice)
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("choice.png"):
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
	await create_timer(0.2).timeout
	if not _capture("end.png"):
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
