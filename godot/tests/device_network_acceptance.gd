extends Node

## Two independent graphical clients; configuration and output stay in the test package.
const Policy = preload("res://tests/network_regression.gd")
var main: Control
var config: Dictionary
var report: Dictionary = {"actions": 0, "choices": 0, "revisions": [], "errors": []}
var last_submission := -1
var last_revision := -1
var room_saved := false


func run(options: Dictionary) -> void:
	preload("res://tests/graphics_test_driver.gd").attach(get_tree())
	config = options
	var settings: Node = get_node("/root/AppSettings")
	settings.animation_mode = "fast"
	settings.quality_profile = "auto"
	settings.muted = true
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	main.shell_view.show_network_setup("relay")
	await get_tree().process_frame
	var page: NetworkLobbyPage = main.current_network_page
	page.role_option.select(0 if config.role == "host" else 1)
	page.refresh_fields(-1)
	page.address_input.text = str(config.url)
	page.room_input.text = str(config.get("room", ""))
	page.select_deck(str(config.get("deck", "happy4_koraidon")))
	page.connect_button.pressed.emit()
	report.merge({"platform": OS.get_name(), "role": config.role, "url": config.url,
		"deck": config.get("deck", "happy4_koraidon")})
	var deadline := Time.get_ticks_msec() + 360000
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if not room_saved and not main.network_controller.room_id.is_empty():
			room_saved = true
			report["room"] = main.network_controller.room_id
			write_report("room")
		if main.current_screen == "network":
			if page.connection_state == NetworkLobbyPage.ConnectionState.ERROR:
				report.errors.append(page.status_label.text)
				break
			continue
		if main.state == null:
			report.errors.append("Match disappeared before completion")
			break
		if main.state.revision != last_revision:
			last_revision = main.state.revision
			report.revisions.append(last_revision)
			if last_revision % 10 == 0:
				report["revision"] = last_revision
				write_report("playing")
		if main.current_screen == "end":
			report["winner"] = main.state.winner
			report["result_status"] = main.state.result_status
			report["revision"] = main.state.revision
			report["turns"] = main.state.turn_number
			await RenderingServer.frame_post_draw
			get_window().get_texture().get_image().save_png("user://device-network-result.png")
			# Let the terminal acknowledgement finish before either process exits.
			await get_tree().create_timer(3).timeout
			report["terminal_closed"] = main.network_controller.connection_phase == NetworkMatchController.ConnectionPhase.CLOSED
			write_report("complete")
			get_tree().quit(0)
			return
		if main._battle_submission_locked() or main._startup_choreography_running:
			continue
		if last_submission == main.state.revision:
			continue
		if main.network_choice_view != null and main.active_request != null:
			var request: ChoiceView = main.network_choice_view
			last_submission = main.state.revision
			main.choice_presenter.clear()
			main.modal_host_controller.close()
			main._submit_choice_response(request, Policy._automatic_choice(request))
			report.choices += 1
		elif not main.network_legal_actions.is_empty():
			last_submission = main.state.revision
			var result: StepResult = main._execute_action_now(Policy._automatic_action(main.network_legal_actions))
			if not result.success:
				report.errors.append(result.message)
				break
			report.actions += 1
	if report.errors.is_empty():
		report.errors.append("Graphical device match timed out")
	write_report("failed")
	get_tree().quit(1)


func write_report(phase: String) -> void:
	report["phase"] = phase
	var output := FileAccess.open("user://device-network-report.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("DEVICE_NETWORK_REPORT ", JSON.stringify(report))
