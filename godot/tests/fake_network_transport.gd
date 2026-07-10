class_name FakeNetworkTransport
extends NetTransport

var sent_messages: Array[Dictionary] = []
var send_succeeds := true


func send(message: Dictionary) -> bool:
	if not send_succeeds:
		return false
	sent_messages.append(message.duplicate(true))
	return true


func connected_state() -> bool:
	return true
