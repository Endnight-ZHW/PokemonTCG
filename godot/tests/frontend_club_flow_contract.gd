extends RefCounted

## Check the public UI boundaries without writing settings or opening sockets.
func run(context: FrontendContractContext) -> void:
	_check_settings_round_trip(context)
	var saved_cache := int(context._settings_node.get("card_cache_size"))
	context._settings_node.set("card_cache_size", 32)
	var settings := load("res://ui/dialogs/settings_panel.tscn").instantiate() as SettingsPanel
	context.tree.root.add_child(settings)
	settings.configure()
	context._check(int(settings.values().card_cache_size) == 32,
		"Opening settings must preserve an existing non-preset cache size")
	context._check(not settings.advanced_options.visible, "Advanced cache settings must start collapsed")
	settings.advanced_button.button_pressed = true
	context._check(settings.advanced_options.visible, "Advanced cache options did not expand")
	var before := context._capture_settings()
	settings.master_volume_slider.value = 0.35
	settings.animation_mode_option.select(3)
	var submitted: Array[Dictionary] = []
	settings.save_requested.connect(func(values: Dictionary) -> void: submitted.append(values))
	settings.request_save()
	context._check(submitted.size() == 1 and is_equal_approx(submitted[0].master_volume, 0.35)
		and submitted[0].animation_mode == "reduced" and not submitted[0].has("reduced_motion"),
		"Settings save did not emit a coherent animation/volume form")
	settings.reset_form_to_defaults()
	context._check(settings.values().animation_mode == "standard"
		and context._capture_settings() == before,
		"Reset defaults must only change the form until it is saved")
	settings.free()
	context._check(context._capture_settings() == before, "Dismissing settings changed persistent preferences")
	context._settings_node.set("card_cache_size", saved_cache)
	var catalog := CardCatalog.shared()
	for kind in ["lan", "relay"]:
		for role_index in [0, 1]:
			var page := load("res://scenes/network/network_lobby_page.tscn").instantiate() as NetworkLobbyPage
			context.tree.root.add_child(page)
			page.configure(catalog, kind, "wss://relay.example.test")
			page.role_option.select(role_index)
			page.refresh_fields(role_index)
			page.port_input.text = "50751"
			page.address_input.text = "wss://relay.example.test" if kind == "relay" else "192.168.1.20"
			page.room_input.text = "CLUB24" if kind == "relay" and role_index == 1 else ""
			page.matchup_toggle.set_pressed_no_signal(role_index == 0)
			var payloads: Array[Array] = []
			page.connect_requested.connect(func(k: String, r: String, a: String, p: int, room: String, deck: String, matchups: bool) -> void:
				payloads.append([k, r, a, p, room, deck, matchups]))
			page._emit_connect_requested()
			context._check(payloads.size() == 1 and payloads[0] == [kind,
				"host" if role_index == 0 else "client", page.address_input.text,
				50751, page.room_input.text, page.selected_deck_key(), role_index == 0],
				"Lobby changed the connection payload for %s role %d" % [kind, role_index])
			context._check(page.connection_state == NetworkLobbyPage.ConnectionState.VALIDATING,
				"Valid lobby submission did not enter its locked validation state")
			page.set_connection_state(NetworkLobbyPage.ConnectionState.ERROR, "连接失败，请重试。")
			context._check(not page.role_option.disabled and page.port_input.text == "50751",
				"Connection failure lost the form draft or kept it locked")
			page.free()
	var invalid := load("res://scenes/network/network_lobby_page.tscn").instantiate() as NetworkLobbyPage
	context.tree.root.add_child(invalid)
	invalid.configure(catalog, "relay", "https://invalid.example.test")
	invalid.role_option.select(1)
	invalid.refresh_fields(1)
	invalid._emit_connect_requested()
	context._check(invalid.address_error.visible and invalid.room_error.visible
		and invalid.connection_state == NetworkLobbyPage.ConnectionState.ERROR,
		"Invalid internet form must show errors beside both missing/invalid fields")
	invalid.free()
	var victory := load("res://scenes/end/victory_screen.tscn").instantiate() as VictoryScreen
	context.tree.root.add_child(victory)
	for mode in ["local", "challenge", "network", "lan", "relay"]:
		victory.configure(0, 12, "玩家 1", "svi-ente", {"mode": mode})
		context._check(victory.rematch_button.text == ("重新选牌" if mode in ["local", "challenge"] else "返回联机大厅"),
			"Result CTA must describe its actual return destination")
	victory.free()
	await context._settle_layout(2)


func _check_settings_round_trip(context: FrontendContractContext) -> void:
	var settings: Node = load("res://autoload/app_settings.gd").new()
	var path := "user://cleanup-settings-contract.cfg"
	for mode in ["cinematic", "standard", "fast", "reduced"]:
		settings.update(0.37, false, 32, mode, "medium", 0.21, 0.64)
		context._check(settings.save_settings(path), "Cannot save settings fixture")
		var stored := ConfigFile.new()
		stored.load(path)
		context._check(not stored.has_section_key("accessibility", "reduced_motion"),
			"Settings still stores a second animation preference")
		settings.reset_defaults(false)
		context._check(settings.load_settings(path) and settings.animation_mode == mode
			and settings.reduced_motion == (mode == "reduced")
			and is_equal_approx(settings.music_volume, 0.21) and settings.card_cache_size == 32,
			"Current settings failed round-trip: " + mode)
	var obsolete := ConfigFile.new()
	obsolete.set_value("accessibility", "reduced_motion", true)
	obsolete.save(path)
	context._check(settings.load_settings(path) and settings.animation_mode == "standard"
		and not settings.reduced_motion, "Old boolean animation preference was migrated")
	DirAccess.remove_absolute(path)
	settings.free()
