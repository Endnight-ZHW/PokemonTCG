class_name FakeNetworkTransport
extends NetTransport

var sent_messages: Array[Dictionary] = []


func send(message: Dictionary) -> bool:
	sent_messages.append(message.duplicate(true))
	return true


func connected_state() -> bool:
	return true
