class_name PlayholdClient
extends Node
## Connects a game to a playhold server: the guest's identity, joining a room, sending messages to the room's modules,
## and receiving what the player can see of it.
##
## Add it to the scene tree, usually as an autoload so the connection outlives a change of scene, then call
## [method connect_to_url], and [method join] or [method create_room]. It polls its connection in
## [method Node._process], and keeps running while the game is paused.
## [codeblock]
## var client := PlayholdClient.new()
## add_child(client)
## client.room_joined.connect(func(code): print("in room ", code))
## client.views_received.connect(_show)
## client.connect_to_url("wss://game.example.com")
## client.create_room()
## [/codeblock]
## Messages sent while not in a room aren't kept or sent later. A player who comes back receives the whole view.

## Emitted each time [member status] changes.
signal status_changed(status: Status)
## Emitted each time the client enters its room, with the room's code: for [method create_room], the one the server
## made, to share with the other players.
signal room_joined(code: String)
## Emitted with everything the player can see in the room: a Dictionary from each module's name to its view, as that
## module's own message in bytes.
signal views_received(views: Dictionary)
## Emitted when the server reports a problem. [param seq] is the number [method send] returned for the frame it's
## about, [param code] one of [code]Frames.ErrorCode[/code], and [param message] a description for logs and developers.
signal server_error(seq: int, code: int, message: String)

## Where the client is.
enum Status {
	DISCONNECTED, ## Not connected.
	CONNECTING, ## Opening a connection and saying hello.
	CONNECTED, ## The server knows this player, who isn't in a room.
	JOINED, ## In a room: messages can be sent.
}

const Frames = preload("frames.gd")
const _Identity = preload("identity.gd")

const _PROTOCOL_VERSION := 1

## Which version of each module's messages this game was built for, such as [code]{"board": 2}[/code], so the server
## can tell when it's too old.
@export var schema_versions := {}
## Where the guest's identity is saved, read when the client first connects. An empty path keeps it in memory only, so
## each run of the game is a new guest.
@export var identity_path := "user://playhold_identity.cfg"

## Where the client is: see [signal status_changed].
var status: Status:
	get:
		return _status
## The player's ID, once the server has accepted them; empty before.
var player_id: String:
	get:
		return _player_id

var _socket: WebSocketPeer
var _identity: _Identity
var _status := Status.DISCONNECTED
var _player_id := ""
var _said_hello := false
var _last_seq := 0
## Whether the player wants to be in a room, with [member _code]; an empty code asks the server for a new room.
var _wants_room := false
var _code := ""
## The seq of the last Join sent, until the room answers; 0 for none.
var _join_seq := 0


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	if _socket == null:
		return
	_socket.poll()
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN and not _said_hello:
		_said_hello = true
		_send_hello()
	while _socket != null and _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		if not _socket.was_string_packet(): # the server only sends binary frames
			_receive(packet)
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_dropped()


## Starts connecting to the server at [param url], such as [code]wss://game.example.com[/code]. Returns
## [constant ERR_ALREADY_IN_USE] while already connecting or connected, or the error that kept the connection from
## starting.
func connect_to_url(url: String) -> Error:
	if _socket != null:
		return ERR_ALREADY_IN_USE
	if _identity == null:
		_identity = _Identity.new(identity_path)
	var socket := WebSocketPeer.new()
	var error := socket.connect_to_url(url)
	if error != OK:
		return error
	_socket = socket
	_said_hello = false
	_set_status(Status.CONNECTING)
	return OK


## Enters the room with this code, now or as soon as the client is connected; [signal room_joined] follows. A code no
## room has creates one only on a server that allows codes clients choose; otherwise it's refused with
## [code]ROOM_NOT_FOUND[/code] in [signal server_error]. Returns [constant ERR_ALREADY_IN_USE] when the client is in
## another room or joining one.
func join(code: String) -> Error:
	if _wants_room:
		return OK if code == _code else ERR_ALREADY_IN_USE
	_wants_room = true
	_code = code
	if _status == Status.CONNECTED:
		_send_join()
	return OK


## Creates a room, with a code the server makes, and enters it, now or as soon as the client is connected. The code
## arrives in [signal room_joined]. Returns [constant ERR_ALREADY_IN_USE] when the client is in a room or joining one.
func create_room() -> Error:
	return join("") # an empty code asks the server for a new room


## Sends a message to one of the room's modules: [param id] is the message's number in that module, and [param payload]
## the message in bytes. Returns the frame's number, which [signal server_error] carries if the server refuses it, or 0
## when the client isn't in a room, in which case nothing was sent.
func send(module: String, id: int, payload: PackedByteArray) -> int:
	if _status != Status.JOINED:
		return 0
	var frame := _next_frame()
	var message := frame.new_module_message()
	message.set_module(module)
	message.set_id(id)
	message.set_payload(payload)
	return _send(frame)


## Disconnects and forgets the room. The guest's identity is kept for next time.
func close() -> void:
	if _socket != null:
		_socket.close()
	_socket = null
	_player_id = ""
	_wants_room = false
	_code = ""
	_join_seq = 0
	_set_status(Status.DISCONNECTED)


## The connection closed without [method close]. The room is kept, so connecting again goes back to it.
func _dropped() -> void:
	_socket = null
	_player_id = ""
	_join_seq = 0
	_set_status(Status.DISCONNECTED)


func _receive(bytes: PackedByteArray) -> void:
	var frame := Frames.ServerFrame.new()
	if frame.from_bytes(bytes) != Frames.PB_ERR.NO_ERRORS:
		server_error.emit(0, Frames.ErrorCode.UNSPECIFIED, "frame could not be decoded")
		return
	match frame.get_body_case():
		Frames.ServerFrame.BodyCase.WELCOME:
			_welcomed(frame.get_welcome())
		Frames.ServerFrame.BodyCase.JOINED:
			_joined(frame.get_joined())
		Frames.ServerFrame.BodyCase.STATE:
			_views(frame.get_state())
		Frames.ServerFrame.BodyCase.ERROR:
			_failed(frame.get_error())


func _welcomed(welcome: Frames.Welcome) -> void:
	_player_id = welcome.get_player_id()
	if welcome.get_secret() != "": # only a new guest gets one
		_identity.write(_player_id, welcome.get_secret())
	_set_status(Status.CONNECTED)
	if _wants_room:
		_send_join()


func _joined(joined: Frames.Joined) -> void:
	_join_seq = 0
	_code = joined.get_code() # the server's, for a room it made, so connecting again comes back to this room
	_set_status(Status.JOINED)
	room_joined.emit(_code)


func _views(state: Frames.RoomState) -> void:
	var views := {}
	for view: Frames.ModuleView in state.get_views():
		views[view.get_module()] = view.get_view()
	views_received.emit(views)


func _failed(error: Frames.ServerError) -> void:
	var seq: int = error.get_seq()
	var code: int = error.get_code()
	if code == Frames.ErrorCode.UNAUTHORIZED:
		# The server doesn't know this guest, for example after it lost its data. Start again as a new one.
		_identity.clear()
		_send_hello()
	elif seq != 0 and seq == _join_seq:
		# The room refused this player: forget its code, so connecting again doesn't try it again.
		_wants_room = false
		_code = ""
		_join_seq = 0
	server_error.emit(seq, code, error.get_text())


func _send_hello() -> void:
	var frame := _next_frame()
	var hello := frame.new_hello()
	hello.set_protocol_version(_PROTOCOL_VERSION)
	var identity := _identity.read()
	if not identity.is_empty():
		hello.set_player_id(identity.player_id)
		hello.set_secret(identity.secret)
	for module: String in schema_versions:
		hello.add_schema_versions(module, schema_versions[module])
	_send(frame)


func _send_join() -> void:
	var frame := _next_frame()
	frame.new_join().set_code(_code) # sent even when empty: that's how a new room is asked for
	_join_seq = _send(frame)


func _next_frame() -> Frames.ClientFrame:
	_last_seq += 1
	var frame := Frames.ClientFrame.new()
	frame.set_seq(_last_seq)
	return frame


func _send(frame: Frames.ClientFrame) -> int:
	if _socket != null:
		_socket.send(frame.to_bytes(), WebSocketPeer.WRITE_MODE_BINARY)
	return frame.get_seq()


func _set_status(new_status: Status) -> void:
	if new_status != _status:
		_status = new_status
		status_changed.emit(new_status)