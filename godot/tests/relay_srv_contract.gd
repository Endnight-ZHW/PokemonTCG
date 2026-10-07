extends SceneTree

const SERVICE := "_ptcg._tcp.relay.example.test"
var failures: Array[String] = []

class LocalDnsTransport extends WebSocketRelayTransport:
	var resolver: RelaySrvResolver
	func _new_srv_resolver() -> RelaySrvResolver:
		return resolver


func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	check_parsing()
	await check_resolution_and_handshake()
	for failure in failures:
		push_error(failure)
	print("RELAY_SRV_CONTRACT_OK" if failures.is_empty() else "RELAY_SRV_CONTRACT_FAILED")
	quit(0 if failures.is_empty() else 1)


func encode_name(value: String) -> PackedByteArray:
	var bytes := PackedByteArray()
	for label in value.split(".", false):
		bytes.append(label.length())
		bytes.append_array(label.to_ascii_buffer())
	bytes.append(0)
	return bytes


func response_for(query: PackedByteArray, port: int, target: String = "localhost") -> PackedByteArray:
	var response := query.duplicate()
	response[2] = 0x81
	response[3] = 0x80
	response[7] = 1
	var data := PackedByteArray([0, 0, 0, 0, (port >> 8) & 255, port & 255])
	data.append_array(encode_name(target))
	response.append_array(PackedByteArray([0xc0, 12, 0, 33, 0, 1, 0, 0, 0, 60, 0, data.size()]))
	response.append_array(data)
	return response


func check_parsing() -> void:
	var parsed := RelaySrvResolver.parse_url("ws+srv://Relay.Example.test/game")
	check(parsed.get("question") == SERVICE and parsed.get("path") == "/game", "Service URL parsing failed")
	for invalid in ["ws+srv://", "ws+srv://host:8766", "ws+srv://127.0.0.1", "ws+srv://user@host",
		"ws+srv://bad..host", "ws+srv://bad_host", "ws+srv://host/?x=\r\n", "ws+srv://host/#x"]:
		check(RelaySrvResolver.parse_url(invalid).is_empty(), "Invalid service URL accepted: " + invalid)
	var query := RelaySrvResolver.make_query(12345, SERVICE)
	var response := response_for(query, 65361)
	parsed = RelaySrvResolver.parse_response(response, 12345, SERVICE)
	check(parsed.get("ok", false) and parsed.records.size() == 1, "Compressed SRV owner did not parse")
	check(parsed.get("records", [{}])[0].get("port") == 65361, "SRV port byte order is wrong")
	check(RelaySrvResolver.parse_response(response, 1, SERVICE).is_empty(), "Wrong DNS transaction accepted")
	check(RelaySrvResolver.parse_response(response, 12345, SERVICE + "x").is_empty(), "Wrong DNS question accepted")
	check(RelaySrvResolver.parse_response(query, 12345, SERVICE).is_empty(), "DNS query accepted as response")
	for length in range(response.size()):
		check(RelaySrvResolver.parse_response(response.slice(0, length), 12345, SERVICE).is_empty(),
			"Truncated DNS packet accepted at byte " + str(length))
	var truncated := response.duplicate()
	truncated[2] |= 2
	check(RelaySrvResolver.parse_response(truncated, 12345, SERVICE).is_empty(), "TC response accepted")
	var loop := response.duplicate()
	loop[12] = 0xc0
	loop[13] = 12
	check(RelaySrvResolver.parse_response(loop, 12345, SERVICE).is_empty(), "Compression pointer cycle accepted")
	parsed = RelaySrvResolver.parse_response(response_for(query, 0, ""), 12345, SERVICE)
	check(parsed.get("unavailable", false), "SRV root target did not disable service")
	parsed = RelaySrvResolver.parse_response(response_for(query, 0), 12345, SERVICE)
	check(parsed.get("records", []).is_empty(), "Port zero accepted")
	parsed = RelaySrvResolver.parse_response(response_for(query, 42, "127.0.0.1"), 12345, SERVICE)
	check(parsed.get("records", []).is_empty(), "IP literal accepted as SRV target")
	var first := {"host": "preferred.test", "port": 1, "priority": 0, "weight": 1}
	var backup := {"host": "backup.test", "port": 2, "priority": 1, "weight": 65535}
	check(RelaySrvResolver.choose_target([backup, first]) == first, "SRV priority ignored")
	var zero := {"host": "zero.test", "port": 3, "priority": 0, "weight": 0}
	check(RelaySrvResolver.choose_target([zero, first]) in [zero, first], "Weighted selection returned an unknown target")
	check(RelaySrvResolver.choose_target([zero]) == zero, "All-zero weights not supported")
	check(RelaySrvResolver.choose_target([]).is_empty(), "Empty SRV set accepted")


func check_resolution_and_handshake() -> void:
	var dns := PacketPeerUDP.new()
	check(dns.bind(0, "127.0.0.1") == OK, "Could not bind DNS fixture")
	var resolver := RelaySrvResolver.new()
	resolver.nameservers = ["127.0.0.1"]
	resolver.dns_port = dns.get_local_port()
	var transport := LocalDnsTransport.new()
	transport.resolver = resolver
	var service_url := "ws+srv://relay.example.test/game"
	# Reusing the same service name must look up the new port on every connection.
	for role in ["host", "client", "resume"]:
		var server := TCPServer.new()
		check(server.listen(0, "*") == OK, "Could not bind WebSocket fixture")
		var port := server.get_local_port()
		resolver.nameservers.assign(["127.0.0.2", "127.0.0.1"] if role == "host" else ["127.0.0.1"])
		var error: Error
		if role == "host":
			error = transport.start_host(service_url)
		elif role == "client":
			error = transport.start_client(service_url, "1234")
		else:
			error = transport.resume_session(service_url, "1234", "p2", "test-resume-token")
		check(error == OK and transport.socket == null, "SRV setup did not start asynchronously")
		if role == "host":
			resolver._deadline = Time.get_ticks_msec() - 1
		var peer: WebSocketPeer
		var acknowledged := false
		var queries := 0
		var deadline := Time.get_ticks_msec() + 4000
		while not acknowledged and Time.get_ticks_msec() < deadline:
			for event in transport.poll():
				if str(event.type) in ["room_created", "room_joined", "room_resumed"]:
					acknowledged = true
				if event.type == "connection_failed":
					check(false, "SRV connection failed: " + str(event))
			if dns.get_available_packet_count() > 0:
				var request := dns.get_packet()
				dns.set_dest_address(dns.get_packet_ip(), dns.get_packet_port())
				dns.put_packet(response_for(request, port))
				queries += 1
			if peer == null and server.is_connection_available():
				peer = WebSocketPeer.new()
				peer.accept_stream(server.take_connection())
			if peer != null:
				peer.poll()
				if peer.get_available_packet_count() > 0:
					var control: Dictionary = JSON.parse_string(peer.get_packet().get_string_from_utf8())
					var expected := "create_room" if role == "host" else ("join_room" if role == "client" else "resume_room")
					check(control.type == expected, "SRV handshake changed the requested role")
					var reply := "room_created" if role == "host" else ("room_joined" if role == "client" else "room_resumed")
					peer.send_text(JSON.stringify({"type": reply, "room_id": "1234", "resume_token": "test-resume-token"}))
			await process_frame
		check(acknowledged and queries == 1, "SRV lookup/handshake failed for " + role)
		if role == "host":
			check(resolver._server_index == 1, "Unavailable DNS resolver did not fail over")
		check(transport.url == service_url, "Resolved endpoint replaced the stable address")
		transport.close()
		if peer != null:
			peer.close()
		server.stop()
	# Cancel lookup and force an expired resolver attempt without real waiting.
	check(transport.start_host(service_url) == OK, "Cancellation fixture failed")
	transport.close()
	check(transport.poll().is_empty() and resolver._peer == null, "Cancelled lookup leaked resources/events")
	check(transport.start_host(service_url) == OK, "Timeout fixture failed")
	resolver._deadline = Time.get_ticks_msec() - 1
	var failure := transport.poll()
	check(failure.size() == 1 and failure[0].get("code") == "srv_resolution_failed", "DNS timeout was not reported")
	check(transport.poll().is_empty(), "DNS error delivered twice")
	transport.close()
	dns.close()
