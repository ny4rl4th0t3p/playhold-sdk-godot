class_name PlayholdClient
extends Node
## Connects a game to a playhold server: the guest's identity, joining a room, sending messages to the room's modules,
## and receiving what the player can see of it.
##
## Add it to the scene tree, usually as an autoload so the connection outlives a change of scene, then call
## [method connect_to_url], and [method join], [method create_room] or [method queue]. It polls its connection in
## [method Node._process], and keeps running while the game is paused.
## [codeblock]
## var client := PlayholdClient.new()
## add_child(client)
## client.room_joined.connect(func(code): print("in room ", code))
## client.views_received.connect(_show)
## client.connect_to_url("wss://game.example.com")
## client.create_room()
## [/codeblock]
## When the connection drops, the client connects again by itself, after a delay that grows with each failed attempt,
## and goes back to its room. It stops for good only when the server says so: see [enum Status]. Messages sent while
## not in a room aren't kept or sent later. A player who comes back receives the whole view.

## Emitted each time [member status] changes.
signal status_changed(status: Status)
## Emitted each time the client enters its room, with the room's code: for [method create_room], the one the server
## made, to share with the other players.
signal room_joined(code: String)
## Emitted with everything the player can see in the room: a Dictionary from each module's name to its view, as that
## module's own message in bytes.
signal views_received(views: Dictionary)
## Emitted when the player's room has closed, with one of [code]Frames.CloseReason[/code]. The client is still
## connected, and can join another room.
signal room_closed(reason: int)
## Emitted when the server reports a problem. [param seq] is the number [method send] returned for the frame it's
## about, [param code] one of [code]Frames.ErrorCode[/code], and [param message] a description for logs and developers.
signal server_error(seq: int, code: int, message: String)

## Where the client is.
enum Status {
	DISCONNECTED, ## Not connected: the connection was lost and the client retries after a delay, or it never started.
	CONNECTING, ## Opening a connection and saying hello.
	CONNECTED, ## The server knows this player, who isn't in a room.
	JOINED, ## In a room: messages can be sent.
	REPLACED, ## The same player connected somewhere newer. Stopped until [method PlayholdClient.connect_to_url].
	CLOSED, ## Stopped by [method PlayholdClient.close].
	UPDATE_REQUIRED, ## This game is too old for the server, and has stopped. The player needs a newer one.
	QUEUED, ## Waiting to be matched with other players. Once matched, the client joins the room by itself.
}

const Frames = preload("frames.gd")
const _Identity = preload("identity.gd")

const _PROTOCOL_VERSION := 1
## The close status of a connection replaced by a newer one from the same player.
const _CLOSE_REPLACED := 4001

## Which version of each module's messages this game was built for, such as [code]{"board": 2}[/code], so the server
## can tell when it's too old.
@export var schema_versions := {}
## Where the guest's identity is saved, read when the client first connects. An empty path keeps it in memory only, so
## each run of the game is a new guest.
@export var identity_path := "user://playhold_identity.cfg"
## The delay before the first retry after a lost connection, in seconds. It doubles with each failed attempt, up to
## [member max_retry_delay], and each delay is a random 50-100% of that, so players dropped together don't all come
## back at once.
@export var min_retry_delay := 0.5
## The longest delay between retries, in seconds.
@export var max_retry_delay := 15.0

## Where the client is: see [signal status_changed].
var status: Status:
	get:
		return _status
## The player's ID, once the server has accepted them; empty before.
var player_id: String:
	get:
		return _player_id

var _url := ""
var _socket: WebSocketPeer
var _identity: _Identity
var _status := Status.DISCONNECTED
var _player_id := ""
var _said_hello := false
var _last_seq := 0
## When to connect again, in [method Time.get_ticks_msec]; -1 for no retry waiting.
var _retry_at := -1
var _failed_attempts := 0
## Whether the player wants to be in a room, with [member _code]; an empty code asks the server for a new room.
var _wants_room := false
var _code := ""
## The seq of the last Join sent, until the room answers; 0 for none.
var _join_seq := 0
## Whether the player wants a match, with [member _queue_properties]. Kept across lost connections, which drop the
## player's place on the server.
var _wants_queue := false
var _queue_properties := {}
## The seq of the last Queue sent, until the server answers; 0 for none.
var _queue_seq := 0
## Whether the client's room is one it was matched to, and with what, to queue again if the match falls through.
var _was_matched := false
var _matched_properties := {}


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	if _retry_at >= 0 and Time.get_ticks_msec() >= _retry_at:
		_retry_at = -1
		if _open() != OK:
			_retry_later()
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
		_socket_closed()


## Starts connecting to the server at [param url], such as [code]wss://game.example.com[/code], and keeps connecting
## again after a lost connection until [method close]. After [constant REPLACED], [constant CLOSED] or
## [constant UPDATE_REQUIRED], it starts again. Returns [constant ERR_ALREADY_IN_USE] while connecting, connected or
## waiting to retry, or the error that kept the connection from starting.
func connect_to_url(url: String) -> Error:
	if _socket != null or _retry_at >= 0:
		return ERR_ALREADY_IN_USE
	_url = url
	_failed_attempts = 0
	return _open()


## Enters the room with this code, now or as soon as the client is connected; [signal room_joined] follows. A code no
## room has creates one only on a server that allows codes clients choose; otherwise it's refused with
## [code]ROOM_NOT_FOUND[/code] in [signal server_error]. Returns [constant ERR_ALREADY_IN_USE] when the client is in
## another room or joining one.
func join(code: String) -> Error:
	if _wants_room:
		return OK if code == _code else ERR_ALREADY_IN_USE
	_wants_room = true
	_code = code
	_wants_queue = false # joining a room leaves the queue, on the server too
	_queue_seq = 0
	if _status == Status.QUEUED:
		_set_status(Status.CONNECTED)
	if _status == Status.CONNECTED:
		_send_join()
	return OK


## Asks to be matched with other players, now or as soon as the client is connected; [member status] becomes
## [constant QUEUED] once the server has the player waiting. [param properties] are the player's choices, such as a mode,
## for the game's matcher; keys and values are sent as Strings. Once matched, the client joins the room by itself, and
## [signal room_joined] reports its code. It queues again by itself after a lost connection, and when the room closes
## because a matched player never came. Queueing again while queued replaces the properties. Returns
## [constant ERR_ALREADY_IN_USE] when the client is in a room or joining one.
func queue(properties := {}) -> Error:
	if _wants_room:
		return ERR_ALREADY_IN_USE
	_queue_properties = {}
	for key: Variant in properties:
		_queue_properties[str(key)] = str(properties[key])
	_wants_queue = true
	if _status == Status.CONNECTED or _status == Status.QUEUED:
		_send_queue()
	return OK


## Stops waiting for a match, and goes back to [constant CONNECTED]. Does nothing when not queued.
func leave_queue() -> void:
	if not _wants_queue:
		return
	_wants_queue = false
	_queue_seq = 0
	if _status == Status.CONNECTED or _status == Status.QUEUED:
		var frame := _next_frame()
		frame.new_leave_queue()
		_send(frame)
		_set_status(Status.CONNECTED)


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


## Disconnects, stops connecting again, and forgets the room and the queue. The guest's identity is kept for next time.
func close() -> void:
	_wants_room = false
	_code = ""
	_wants_queue = false
	_was_matched = false
	_stop(Status.CLOSED)


func _open() -> Error:
	if _identity == null:
		_identity = _Identity.new(identity_path)
	var socket := WebSocketPeer.new()
	var error := socket.connect_to_url(_url)
	if error != OK:
		return error
	_socket = socket
	_said_hello = false
	_set_status(Status.CONNECTING)
	return OK


## The connection closed, or never opened, without [method close]. The room, or the wish for a match, is kept, so the
## retry goes back to it.
func _socket_closed() -> void:
	var close_code := _socket.get_close_code()
	_socket = null
	_player_id = ""
	_join_seq = 0
	_queue_seq = 0
	if close_code == _CLOSE_REPLACED:
		_set_status(Status.REPLACED)
		return
	_set_status(Status.DISCONNECTED)
	_retry_later()


func _retry_later() -> void:
	_retry_at = Time.get_ticks_msec() + int(_retry_delay(_failed_attempts) * 1000)
	_failed_attempts += 1


## The delay before retry number [param attempt], from 0, in seconds.
func _retry_delay(attempt: int) -> float:
	var delay := minf(max_retry_delay, min_retry_delay * pow(2, attempt))
	return delay * (0.5 + 0.5 * randf())


## Closes the connection and stops at [param new_status], with no retry.
func _stop(new_status: Status) -> void:
	_retry_at = -1
	if _socket != null:
		_socket.close()
	_socket = null
	_player_id = ""
	_join_seq = 0
	_queue_seq = 0
	_set_status(new_status)


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
		Frames.ServerFrame.BodyCase.CLOSED:
			_room_closed(frame.get_closed())
		Frames.ServerFrame.BodyCase.ERROR:
			_failed(frame.get_error())
		Frames.ServerFrame.BodyCase.QUEUED:
			_queued(frame.get_queued())
		Frames.ServerFrame.BodyCase.MATCHED:
			_matched(frame.get_matched())


func _welcomed(welcome: Frames.Welcome) -> void:
	_failed_attempts = 0
	_player_id = welcome.get_player_id()
	if welcome.get_secret() != "": # only a new guest gets one
		_identity.write(_player_id, welcome.get_secret())
	_set_status(Status.CONNECTED)
	if _wants_room:
		_send_join()
	elif _wants_queue:
		_send_queue() # the server dropped the player's place when the connection was lost


func _queued(queued: Frames.Queued) -> void:
	if _wants_queue and queued.get_seq() == _queue_seq: # not an answer to a Queue the player has since left
		_queue_seq = 0
		_set_status(Status.QUEUED)


## Joins the room the server matched this player to, at once, since its seat is kept only for a while.
func _matched(matched: Frames.Matched) -> void:
	if not _wants_queue or _wants_room:
		return # the player stopped waiting meanwhile
	_was_matched = true
	_matched_properties = _queue_properties
	_wants_queue = false
	_queue_seq = 0
	_wants_room = true
	_code = matched.get_code()
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


func _room_closed(closed: Frames.RoomClosed) -> void:
	var reason: int = closed.get_reason()
	var requeue := _was_matched and reason == Frames.CloseReason.MATCH_INCOMPLETE
	var properties := _matched_properties
	_was_matched = false
	_matched_properties = {}
	_wants_room = false
	_code = ""
	_join_seq = 0
	_set_status(Status.CONNECTED)
	room_closed.emit(reason)
	if requeue and not _wants_room and not _wants_queue:
		queue(properties) # a matched player never came, so keep looking, unless the game chose something else


func _failed(error: Frames.ServerError) -> void:
	var seq: int = error.get_seq()
	var code: int = error.get_code()
	if code == Frames.ErrorCode.UNAUTHORIZED:
		# The server doesn't know this guest, for example after it lost its data. Start again as a new one.
		_identity.clear()
		_send_hello()
	elif code == Frames.ErrorCode.UNSUPPORTED_PROTOCOL or code == Frames.ErrorCode.UPDATE_REQUIRED:
		_stop(Status.UPDATE_REQUIRED)
	elif code == Frames.ErrorCode.UNAVAILABLE or (
		code == Frames.ErrorCode.RATE_LIMITED
		and (_player_id == "" or (seq != 0 and (seq == _join_seq or seq == _queue_seq)))
	):
		# The server couldn't check this player, or asked it to slow down before it got into its room or the queue.
		# Closing leads to the usual retry, with its growing delay, and keeps the room, or the wish for a match, to try
		# again.
		if _socket != null:
			_socket.close()
	elif seq != 0 and seq == _join_seq:
		# The room refused this player: forget its code, so connecting again doesn't try it again.
		_wants_room = false
		_code = ""
		_join_seq = 0
		_was_matched = false
		if _status == Status.QUEUED:
			_set_status(Status.CONNECTED) # a matched room that refused the player
	elif seq != 0 and seq == _queue_seq:
		# The server refused the queue, so stop asking.
		_wants_queue = false
		_queue_seq = 0
		if _status == Status.QUEUED:
			_set_status(Status.CONNECTED)
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


func _send_queue() -> void:
	var frame := _next_frame()
	var request := frame.new_queue()
	for key: String in _queue_properties:
		request.add_properties(key, _queue_properties[key])
	_queue_seq = _send(frame)


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