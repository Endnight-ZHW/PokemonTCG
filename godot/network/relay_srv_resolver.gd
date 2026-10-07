class_name RelaySrvResolver
extends RefCounted

## Explicit ws+srv:// URLs discover _ptcg._tcp.<domain> before connecting.
## Polled DNS keeps Windows/Android setup nonblocking; reconnects query afresh.
const PREFIX := "ws+srv://"
const SERVICE := "_ptcg._tcp."
const ATTEMPT_TIMEOUT_MSEC := 2000
const MAX_PACKET_BYTES := 4096

var nameservers: Array[String] = ["223.5.5.5", "119.29.29.29", "1.1.1.1"]
var dns_port := 53
var _peer: PacketPeerUDP
var _question := ""
var _path := ""
var _query_id := 0
var _server_index := -1
var _deadline := 0
var _result: Dictionary = {}


static func parse_url(value: String) -> Dictionary:
	if not value.begins_with(PREFIX):
		return {}
	var rest := value.substr(PREFIX.length())
	var slash := rest.find("/")
	var domain := (rest if slash < 0 else rest.left(slash)).to_lower().trim_suffix(".")
	if not valid_hostname(domain) or domain.is_valid_ip_address() or domain.length() + SERVICE.length() > 253:
		return {}
	var path := "/" if slash < 0 else rest.substr(slash)
	if path.contains("\r") or path.contains("\n") or path.contains("#"):
		return {}
	return {"domain": domain, "question": SERVICE + domain, "path": path}


static func valid_hostname(value: String) -> bool:
	if value.is_empty() or value.length() > 253:
		return false
	for label in value.split("."):
		if label.is_empty() or label.length() > 63 or label.begins_with("-") or label.ends_with("-"):
			return false
		for character in label.to_lower():
			if not character in "abcdefghijklmnopqrstuvwxyz0123456789-":
				return false
	return true


func start(value: String) -> Error:
	close()
	var parsed := parse_url(value)
	if parsed.is_empty():
		return ERR_INVALID_PARAMETER
	_question = parsed.question
	_path = parsed.path
	_server_index = -1
	_next_server()
	return OK


func poll() -> Dictionary:
	if _peer != null:
		for _packet_index in range(8):
			if _peer.get_available_packet_count() == 0:
				break
			var packet := _peer.get_packet()
			if packet.size() < 12 or _u16(packet, 0) != _query_id:
				continue
			var response := parse_response(packet, _query_id, _question)
			if not response.get("ok", false):
				_next_server()
				break
			if response.get("unavailable", false):
				_finish({"ok": false, "message": "SRV 记录表明服务器暂未开放。"})
				break
			var target := choose_target(response.records)
			if target.is_empty():
				_next_server()
				break
			IP.clear_cache(target.host)
			_finish({"ok": true, "url": "ws://%s:%d%s" % [target.host, target.port, _path]})
			break
		if _peer != null and Time.get_ticks_msec() >= _deadline:
			_next_server()
	var result := _result
	_result = {}
	return result


func close() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	_result = {}
	_deadline = 0


func _finish(result: Dictionary) -> void:
	close()
	_result = result


func _next_server() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	while _server_index + 1 < nameservers.size():
		_server_index += 1
		var server := nameservers[_server_index]
		if not server.is_valid_ip_address():
			continue
		_peer = PacketPeerUDP.new()
		var random := Crypto.new().generate_random_bytes(2)
		_query_id = (int(random[0]) << 8) | int(random[1])
		if _peer.connect_to_host(server, dns_port) == OK:
			if _peer.put_packet(make_query(_query_id, _question)) == OK:
				_deadline = Time.get_ticks_msec() + ATTEMPT_TIMEOUT_MSEC
				return
		_peer.close()
		_peer = null
	_finish({"ok": false, "message": "无法查询服务器 SRV 记录，请检查域名或网络后重试。"})


static func make_query(query_id: int, question: String) -> PackedByteArray:
	var packet := PackedByteArray([
		(query_id >> 8) & 255, query_id & 255, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
	])
	for label in question.split("."):
		packet.append(label.length())
		packet.append_array(label.to_ascii_buffer())
	packet.append_array(PackedByteArray([0, 0, 33, 0, 1]))
	return packet


static func parse_response(packet: PackedByteArray, query_id: int, question: String) -> Dictionary:
	if packet.size() < 12 or packet.size() > MAX_PACKET_BYTES or _u16(packet, 0) != query_id:
		return {}
	var flags := _u16(packet, 2)
	# Response, ordinary query, untruncated, NOERROR, exactly one question.
	if (flags & 0xfa0f) != 0x8000 or _u16(packet, 4) != 1 or _u16(packet, 6) > 64:
		return {}
	var name := _read_name(packet, 12)
	if name.is_empty() or name.name != question.to_lower():
		return {}
	var cursor: int = name.next
	if cursor + 4 > packet.size() or _u16(packet, cursor) != 33 or _u16(packet, cursor + 2) != 1:
		return {}
	cursor += 4
	var records: Array[Dictionary] = []
	var unavailable := false
	for _record_index in range(_u16(packet, 6)):
		name = _read_name(packet, cursor)
		if name.is_empty():
			return {}
		cursor = name.next
		if cursor + 10 > packet.size():
			return {}
		var record_type := _u16(packet, cursor)
		var record_class := _u16(packet, cursor + 2)
		var data_length := _u16(packet, cursor + 8)
		cursor += 10
		var end := cursor + data_length
		if end > packet.size():
			return {}
		if record_type == 33 and record_class == 1 and name.name == question.to_lower():
			if data_length < 7:
				return {}
			var target := _read_name(packet, cursor + 6)
			if target.is_empty() or int(target.next) != end:
				return {}
			if target.name == "":
				unavailable = true
			elif valid_hostname(target.name) and not str(target.name).is_valid_ip_address():
				var port := _u16(packet, cursor + 4)
				if port > 0:
					records.append({"host": target.name, "port": port,
						"priority": _u16(packet, cursor), "weight": _u16(packet, cursor + 2)})
		cursor = end
	return {"ok": true, "records": records, "unavailable": unavailable}


static func choose_target(records: Array) -> Dictionary:
	if records.is_empty():
		return {}
	var candidates: Array[Dictionary] = []
	var priority := 65536
	for record in records:
		if int(record.priority) < priority:
			priority = int(record.priority)
			candidates.clear()
		if int(record.priority) == priority:
			candidates.append(record)
	var random := RandomNumberGenerator.new()
	var total := 0
	for record in candidates:
		total += int(record.weight)
	if total == 0:
		return candidates[random.randi_range(0, candidates.size() - 1)]
	# RFC 2782 gives zero-weight records a small chance when weights are mixed.
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.weight) < int(right.weight))
	var choice := random.randi_range(0, total)
	for record in candidates:
		choice -= int(record.weight)
		if choice <= 0:
			return record
	return candidates.back()


static func _u16(packet: PackedByteArray, offset: int) -> int:
	return (int(packet[offset]) << 8) | int(packet[offset + 1])


static func _read_name(packet: PackedByteArray, offset: int) -> Dictionary:
	var labels: Array[String] = []
	var next := -1
	var length := 0
	var visited := {}
	for _step in range(128):
		if offset >= packet.size() or visited.has(offset):
			return {}
		visited[offset] = true
		var size := int(packet[offset])
		if size == 0:
			return {"name": ".".join(labels).to_lower(), "next": offset + 1 if next < 0 else next}
		if (size & 0xc0) == 0xc0:
			if offset + 1 >= packet.size():
				return {}
			if next < 0:
				next = offset + 2
			offset = ((size & 0x3f) << 8) | int(packet[offset + 1])
			continue
		if size > 63 or offset + 1 + size > packet.size():
			return {}
		length += size + 1
		if length > 254:
			return {}
		for index in range(offset + 1, offset + 1 + size):
			if packet[index] < 33 or packet[index] > 126 or packet[index] == 46:
				return {}
		labels.append(packet.slice(offset + 1, offset + 1 + size).get_string_from_ascii())
		offset += size + 1
	return {}
