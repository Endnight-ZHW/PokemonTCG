extends SceneTree

var failures: Array[String] = []


func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	check_settings()
	# An asynchronously refused connection closes before any control handshake.
	var refused := WebSocketRelayTransport.new()
	refused.socket = WebSocketPeer.new()
	var errors := refused.poll()
	check(errors.size() == 1 and errors[0].type == "connection_failed",
		"Closed-before-handshake connection did not report its failure")
	check(refused.poll().is_empty(), "Connection failure was delivered twice")
	var timed_out := WebSocketRelayTransport.new()
	timed_out.socket = WebSocketPeer.new()
	timed_out._handshake_deadline_msec = 100
	timed_out._check_handshake_timeout(99)
	check(timed_out.events.is_empty(), "Connection timed out before its deadline")
	timed_out._check_handshake_timeout(100)
	errors = timed_out.poll()
	check(errors.size() == 1 and errors[0].get("code") == "connection_timeout"
		and timed_out.socket == null, "Handshake timeout did not clean up and report failure")
	check(timed_out.poll().is_empty(), "Handshake timeout was delivered twice")
	await check_room_handshakes()
	for failure in failures:
		push_error(failure)
	print("RELAY_CONNECTION_CONTRACT_OK" if failures.is_empty() else "RELAY_CONNECTION_CONTRACT_FAILED")
	quit(0 if failures.is_empty() else 1)


func check_settings() -> void:
	var settings: Node = load("res://autoload/app_settings.gd").new()
	var path := "user://relay-connection-contract.cfg"
	var custom_addresses := ["wss://custom.example.test/relay", "ws://custom.example.test:8766", "ws+srv://custom.example.test"]
	for address in ["", "ws://127.0.0.1:8766", "ws://39.190.56.238:50750", "ws://39.190.56.21:65361"] + custom_addresses:
		var config := ConfigFile.new()
		config.set_value("network", "relay_url", address)
		config.set_value("accessibility", "animation_mode", "cinematic")
		config.save(path)
		check(settings.load_settings(path), "Could not load settings fixture")
		var expected: String = address if address in custom_addresses else settings.DEFAULT_RELAY_URL
		check(settings.relay_url == expected, "Default address migration changed a custom address or missed legacy data")
		check(settings.animation_mode == "cinematic", "Address migration changed unrelated settings")
		settings.save_settings(path)
		settings.load_settings(path)
		check(settings.relay_url == expected, "Relay address did not survive settings roundtrip")
	settings.reset_defaults(false)
	check(settings.relay_url == "ws+srv://relay.114600.xyz", "Reset did not select the stable SRV relay")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	settings.free()


func check_room_handshakes() -> void:
	var server := TCPServer.new()
	check(server.listen(0, "127.0.0.1") == OK, "Could not listen for handshake fixture")
	for response_type in ["room_created", "room_joined", "room_resumed", "error"]:
		var relay := WebSocketRelayTransport.new()
		var url := "ws://127.0.0.1:%d" % server.get_local_port()
		var error: Error
		if response_type == "room_created":
			error = relay.start_host(url)
		elif response_type in ["room_joined", "error"]:
			error = relay.start_client(url, "TEST42")
		else:
			error = relay.resume_session(url, "TEST42", "p1", "test-token")
		check(error == OK, "Handshake fixture did not start")
		var peer: WebSocketPeer
		var acknowledged := false
		var deadline := Time.get_ticks_msec() + 3000
		while not acknowledged and Time.get_ticks_msec() < deadline:
			for event in relay.poll():
				if event.type == ("connection_failed" if response_type == "error" else response_type):
					acknowledged = true
			if peer == null and server.is_connection_available():
				peer = WebSocketPeer.new()
				check(peer.accept_stream(server.take_connection()) == OK, "Server rejected fixture stream")
			if peer != null:
				peer.poll()
				if peer.get_available_packet_count() > 0:
					peer.get_packet()
					peer.send_text(JSON.stringify({"type": response_type, "room_id": "TEST42", "resume_token": "test-token"}))
			await process_frame
		check(acknowledged, "Did not receive " + response_type)
		relay._check_handshake_timeout(Time.get_ticks_msec() + 60000)
		if response_type == "error":
			check(relay.poll().is_empty() and relay.socket == null,
				"Rejected room leaked its socket or reported its failure twice")
		else:
			check(relay.poll().is_empty() and relay.socket != null,
				"Waiting for an opponent incorrectly timed out after " + response_type)
		relay.close()
		if peer != null:
			peer.close()
	server.stop()
