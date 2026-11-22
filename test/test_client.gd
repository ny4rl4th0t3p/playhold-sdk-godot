extends GutTest
## The client against the test server in testserver/, which make test starts and passes in PLAYHOLD_TEST_URL. The
## server's "counter" module adds to a total shared by the room, and shows each player "<player>:<total>". Rooms have
## two seats, clients may choose their codes, and queued players are matched in pairs, with a matched seat kept 500 ms.

const Frames = preload("res://addons/playhold/frames.gd")
const Identity = preload("res://addons/playhold/identity.gd")
const Counter = preload("res://test/counter.gd")

const _MSG_ADD := 1
const _MSG_CLOSE := 2
## How long to wait for the server, in seconds.
const _WAIT := 5.0
## How long to wait to see that something doesn't happen, such as a retry after the client stopped, in seconds: a few
## times the longest retry delay the tests set.
const _QUIET := 0.6
## A URL with nothing listening, for a client that can't reach its server.
const _NOWHERE := "ws://127.0.0.1:9"


## A client, and what it has seen.
class Player:
	var client: PlayholdClient
	var status: int = PlayholdClient.Status.DISCONNECTED
	var statuses: Array[int] = []
	var code := ""
	var view := ""
	var errors: Array[int] = []
	var closed_reasons: Array[int] = []


## A player who queues and is matched, but never comes to the room, as a closed tab would: a bare socket that says Hello,
## queues once welcomed, and ignores Matched.
class Absent:
	extends Node

	const Frames = preload("res://addons/playhold/frames.gd")

	var queued := false
	var matched := false
	var _socket := WebSocketPeer.new()
	var _said_hello := false

	func start(url: String) -> void:
		_socket.connect_to_url(url)

	func _process(_delta: float) -> void:
		_socket.poll()
		if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN and not _said_hello:
			_said_hello = true
			var frame := Frames.ClientFrame.new()
			frame.set_seq(1)
			var hello := frame.new_hello()
			hello.set_protocol_version(1)
			hello.add_schema_versions("counter", 2)
			_socket.send(frame.to_bytes(), WebSocketPeer.WRITE_MODE_BINARY)
		while _socket.get_available_packet_count() > 0:
			var frame := Frames.ServerFrame.new()
			frame.from_bytes(_socket.get_packet())
			match frame.get_body_case():
				Frames.ServerFrame.BodyCase.WELCOME:
					var request := Frames.ClientFrame.new()
					request.set_seq(2)
					request.new_queue()
					_socket.send(request.to_bytes(), WebSocketPeer.WRITE_MODE_BINARY)
				Frames.ServerFrame.BodyCase.QUEUED:
					queued = true
				Frames.ServerFrame.BodyCase.MATCHED:
					matched = true


var _url := OS.get_environment("PLAYHOLD_TEST_URL")
var _last := 0


func before_all() -> void:
	assert_ne(_url, "", "PLAYHOLD_TEST_URL is set: run the tests with make test, which starts the test server")


## Returns a room code no other test uses; the server is new on each run.
func _new_code() -> String:
	_last += 1
	return "room-%d" % _last


## Returns an identity file no other test uses, emptied, so the player starts as a new guest.
func _new_identity_path() -> String:
	_last += 1
	var path := "user://test_client_identity_%d.cfg" % _last
	Identity.new(path).clear()
	return path


## Returns a player with its client in the tree, not yet connected, retrying within a fraction of a second. Without an
## identity file, it gets one of its own. The server's counter needs schema version 2.
func _player(identity_path := "", counter_schema := 2) -> Player:
	var p := Player.new()
	p.client = PlayholdClient.new()
	p.client.identity_path = identity_path if identity_path != "" else _new_identity_path()
	p.client.schema_versions = {"counter": counter_schema}
	p.client.min_retry_delay = 0.05
	p.client.max_retry_delay = 0.2
	p.client.status_changed.connect(func(status: PlayholdClient.Status) -> void:
		p.status = status
		p.statuses.append(status))
	p.client.room_joined.connect(func(code: String) -> void: p.code = code)
	p.client.views_received.connect(func(views: Dictionary) -> void: p.view = _total(views))
	p.client.room_closed.connect(func(reason: int) -> void: p.closed_reasons.append(reason))
	p.client.server_error.connect(func(_seq: int, code: int, _message: String) -> void: p.errors.append(code))
	add_child_autofree(p.client)
	return p


func _joined(code: String, identity_path := "") -> Player:
	var p := _player(identity_path)
	p.client.join(code)
	p.client.connect_to_url(_url)
	return p


func _until(condition: Callable) -> bool:
	return await wait_until(condition, _WAIT)


func _until_joined(p: Player) -> bool:
	return await _until(func() -> bool: return p.status == PlayholdClient.Status.JOINED)


func _until_view(p: Player, total: int) -> bool:
	return await _until(func() -> bool: return p.view == "%s:%d" % [p.client.player_id, total])


func _total(views: Dictionary) -> String:
	var total := Counter.Total.new()
	total.from_bytes(views["counter"])
	return total.get_text()


func _amount(value: int) -> PackedByteArray:
	var amount := Counter.Amount.new()
	amount.set_value(value)
	return amount.to_bytes()


## Returns a ServerError frame, for the errors the test server can't be made to send.
func _server_error(seq: int, code: int) -> PackedByteArray:
	var frame := Frames.ServerFrame.new()
	var error := frame.new_error()
	error.set_seq(seq)
	error.set_code(code)
	return frame.to_bytes()


## Returns a player connecting and queueing.
func _queueing() -> Player:
	var p := _player()
	p.client.queue()
	p.client.connect_to_url(_url)
	return p


func _until_queued(p: Player) -> bool:
	return await _until(func() -> bool: return p.status == PlayholdClient.Status.QUEUED)


## Waits until both players are in the same room.
func _until_together(a: Player, b: Player) -> bool:
	return await _until(func() -> bool:
		return a.status == PlayholdClient.Status.JOINED and b.status == PlayholdClient.Status.JOINED and a.code == b.code)


## Waits until the player has lost its connection and is back in its room.
func _until_back(p: Player) -> bool:
	if not await _until(func() -> bool: return p.statuses.has(PlayholdClient.Status.DISCONNECTED)):
		return false
	return await _until(func() -> bool:
		return p.statuses.back() == PlayholdClient.Status.JOINED and p.statuses.count(PlayholdClient.Status.JOINED) >= 2)


func test_joins_plays_and_receives_views() -> void:
	var p := _joined(_new_code())
	assert_true(await _until_joined(p), "joined")
	assert_true(await _until_view(p, 0), "the first view")

	assert_gt(p.client.send("counter", _MSG_ADD, _amount(3)), 0, "sent")

	assert_true(await _until_view(p, 3), "the view after adding")


func test_shows_each_player_their_own_view_of_a_shared_room() -> void:
	var code := _new_code()
	var alice := _joined(code)
	var bob := _joined(code)
	assert_true(await _until_joined(alice), "alice joined")
	assert_true(await _until_joined(bob), "bob joined")

	alice.client.send("counter", _MSG_ADD, _amount(2))

	assert_true(await _until_view(alice, 2), "alice's view")
	assert_true(await _until_view(bob, 2), "bob's view")


func test_creates_a_room_others_join_with_its_code() -> void:
	var alice := _player()
	alice.client.connect_to_url(_url) # connected first, then creating
	assert_true(await _until(func() -> bool: return alice.status == PlayholdClient.Status.CONNECTED), "connected")
	assert_eq(alice.client.create_room(), OK)
	assert_true(await _until_joined(alice), "alice joined")
	assert_ne(alice.code, "", "the server's code")

	var bob := _joined(alice.code)
	assert_true(await _until_joined(bob), "bob joined")
	bob.client.send("counter", _MSG_ADD, _amount(1))

	assert_true(await _until_view(alice, 1), "alice sees bob's add")


func test_is_refused_by_a_full_room() -> void:
	var code := _new_code()
	for p in [_joined(code), _joined(code)]:
		assert_true(await _until_joined(p), "a seat taken")

	var third := _joined(code)

	assert_true(await _until(func() -> bool: return third.errors.has(Frames.ErrorCode.ROOM_FULL)), "ROOM_FULL")
	assert_eq(third.status, PlayholdClient.Status.CONNECTED)
	assert_eq(third.client.join(_new_code()), OK, "the refused code is forgotten, so another room can be joined")


func test_reports_a_message_the_room_refuses_and_keeps_playing() -> void:
	var p := _joined(_new_code())
	assert_true(await _until_joined(p), "joined")

	var seq := p.client.send("counter", _MSG_ADD, _amount(-1))

	assert_true(await _until(func() -> bool: return p.errors.has(Frames.ErrorCode.REJECTED)), "REJECTED")
	assert_gt(seq, 0)
	assert_eq(p.status, PlayholdClient.Status.JOINED)


func test_starts_as_a_new_guest_when_the_server_doesnt_know_the_identity() -> void:
	var path := _new_identity_path()
	Identity.new(path).write("nobody", "wrong")

	var p := _joined(_new_code(), path)

	assert_true(await _until_joined(p), "joined")
	assert_has(p.errors, Frames.ErrorCode.UNAUTHORIZED)
	assert_ne(p.client.player_id, "nobody")
	assert_eq(Identity.new(path).read().get("player_id"), p.client.player_id, "the new identity is saved")


func test_comes_back_as_the_same_player_with_the_same_identity_file() -> void:
	var code := _new_code()
	var path := _new_identity_path()
	var first := _joined(code, path)
	assert_true(await _until_joined(first), "joined")
	var player_id := first.client.player_id
	first.client.close()

	var second := _joined(code, path)

	assert_true(await _until_joined(second), "joined again")
	assert_eq(second.client.player_id, player_id)


func test_join_refuses_another_room_and_send_needs_a_room() -> void:
	var p := _player()

	assert_eq(p.client.send("counter", _MSG_ADD, _amount(1)), 0, "nothing sent before joining")
	assert_eq(p.client.join("a"), OK)
	assert_eq(p.client.join("a"), OK, "the same room again")
	assert_eq(p.client.join("b"), ERR_ALREADY_IN_USE)
	assert_eq(p.client.create_room(), ERR_ALREADY_IN_USE)
	assert_eq(p.client.connect_to_url(_url), OK)
	assert_eq(p.client.connect_to_url(_url), ERR_ALREADY_IN_USE)


func test_comes_back_after_a_dropped_connection_as_the_same_player_in_the_same_room() -> void:
	var code := _new_code()
	var p := _joined(code)
	assert_true(await _until_joined(p), "joined")
	var player_id := p.client.player_id
	p.client.send("counter", _MSG_ADD, _amount(5))
	assert_true(await _until_view(p, 5), "the view before the drop")

	p.view = ""
	p.client._socket.close() # the connection drops, as far as the client knows

	assert_true(await _until_back(p), "back in the room")
	assert_eq(p.client.player_id, player_id)
	assert_eq(p.code, code)
	assert_true(await _until_view(p, 5), "the same total after coming back")


func test_keeps_retrying_a_server_it_cant_reach_until_closed() -> void:
	var p := _player()
	p.client.connect_to_url(_NOWHERE)

	assert_true(await _until(func() -> bool: return p.statuses.count(PlayholdClient.Status.CONNECTING) >= 3), "retries")
	assert_eq(p.client.connect_to_url(_url), ERR_ALREADY_IN_USE, "while waiting to retry")

	p.client.close()
	var seen := p.statuses.size()
	await wait_seconds(_QUIET)

	assert_eq(p.status, PlayholdClient.Status.CLOSED)
	assert_eq(p.statuses.size(), seen, "no retry after close")


func test_stops_when_the_same_player_connects_somewhere_newer() -> void:
	var code := _new_code()
	var path := _new_identity_path()
	var first := _joined(code, path)
	assert_true(await _until_joined(first), "first joined")

	var second := _joined(code, path)

	assert_true(await _until(func() -> bool: return first.status == PlayholdClient.Status.REPLACED), "replaced")
	assert_true(await _until_joined(second), "second joined")
	await wait_seconds(_QUIET)
	assert_eq(first.status, PlayholdClient.Status.REPLACED, "no retry")


func test_connecting_again_after_being_replaced_takes_the_player_back() -> void:
	var code := _new_code()
	var path := _new_identity_path()
	var first := _joined(code, path)
	assert_true(await _until_joined(first), "first joined")
	var second := _joined(code, path)
	assert_true(await _until(func() -> bool: return first.status == PlayholdClient.Status.REPLACED), "replaced")

	assert_eq(first.client.connect_to_url(_url), OK)

	assert_true(await _until(func() -> bool: return second.status == PlayholdClient.Status.REPLACED), "second replaced")
	assert_true(await _until(func() -> bool: return first.status == PlayholdClient.Status.JOINED), "first back in")
	assert_eq(first.code, code)


func test_stops_when_the_server_says_the_game_is_too_old() -> void:
	var p := _player("", 1) # the server's counter needs 2

	p.client.connect_to_url(_url)

	assert_true(await _until(func() -> bool: return p.status == PlayholdClient.Status.UPDATE_REQUIRED), "stopped")
	assert_has(p.errors, Frames.ErrorCode.UPDATE_REQUIRED)
	await wait_seconds(_QUIET)
	assert_eq(p.status, PlayholdClient.Status.UPDATE_REQUIRED, "no retry")


func test_tells_the_player_when_the_room_closes() -> void:
	var p := _joined(_new_code())
	assert_true(await _until_joined(p), "joined")

	p.client.send("counter", _MSG_CLOSE, PackedByteArray())

	assert_true(await _until(func() -> bool: return not p.closed_reasons.is_empty()), "room_closed")
	assert_eq(p.closed_reasons.size(), 1)
	assert_eq(p.closed_reasons[0], Frames.CloseReason.REQUESTED, "the counter closes its room on request")
	assert_eq(p.status, PlayholdClient.Status.CONNECTED)
	var next := _new_code()
	assert_eq(p.client.join(next), OK, "the closed room is forgotten")
	assert_true(await _until(func() -> bool: return p.status == PlayholdClient.Status.JOINED and p.code == next), "in another room")


func test_comes_back_when_the_server_is_unavailable() -> void:
	var code := _new_code()
	var p := _joined(code)
	assert_true(await _until_joined(p), "joined")

	p.client._receive(_server_error(0, Frames.ErrorCode.UNAVAILABLE))

	assert_true(await _until_back(p), "back in the room")
	assert_eq(p.code, code)


func test_comes_back_when_asked_to_slow_down_before_joining() -> void:
	var p := _player()
	p.client.connect_to_url(_url)
	assert_true(await _until(func() -> bool: return p.status == PlayholdClient.Status.CONNECTED), "connected")
	var code := _new_code()
	p.client.join(code)

	p.client._receive(_server_error(p.client._join_seq, Frames.ErrorCode.RATE_LIMITED))

	assert_true(await _until(func() -> bool: return p.statuses.has(PlayholdClient.Status.DISCONNECTED)), "closed")
	assert_true(await _until(func() -> bool: return p.status == PlayholdClient.Status.JOINED), "joined after the retry")
	assert_eq(p.code, code, "the room was kept")


func test_the_retry_delay_doubles_up_to_the_maximum_and_varies_by_half() -> void:
	var client: PlayholdClient = autofree(PlayholdClient.new())
	client.min_retry_delay = 1.0
	client.max_retry_delay = 8.0

	for _draw in 20: # the delay is random: a few draws each
		var first := client._retry_delay(0)
		assert_between(first, 0.5, 1.0, "the first")
		var third := client._retry_delay(2)
		assert_between(third, 2.0, 4.0, "the third doubled twice")
		var late := client._retry_delay(30)
		assert_between(late, 4.0, 8.0, "capped at the maximum")


func test_matches_two_queued_players_into_one_room() -> void:
	var alice := _queueing()
	assert_true(await _until_queued(alice), "alice queued")

	var bob := _queueing()

	assert_true(await _until_together(alice, bob), "in the same room")
	assert_has(bob.statuses, PlayholdClient.Status.QUEUED, "bob was queued first")
	alice.client.send("counter", _MSG_ADD, _amount(1))
	assert_true(await _until_view(bob, 1), "bob sees alice's add")


func test_leaving_the_queue_means_not_being_matched() -> void:
	var alice := _queueing()
	assert_true(await _until_queued(alice), "alice queued")

	alice.client.leave_queue()

	assert_eq(alice.status, PlayholdClient.Status.CONNECTED)
	var bob := _queueing()
	assert_true(await _until_queued(bob), "bob queued")
	await wait_seconds(_QUIET)
	assert_eq(bob.status, PlayholdClient.Status.QUEUED, "bob still waiting, not matched with alice")
	assert_eq(alice.status, PlayholdClient.Status.CONNECTED)


func test_queues_again_after_a_lost_connection() -> void:
	var alice := _queueing()
	assert_true(await _until_queued(alice), "alice queued")

	alice.client._socket.close()

	assert_true(await _until(func() -> bool:
		return alice.statuses.has(PlayholdClient.Status.DISCONNECTED) and alice.status == PlayholdClient.Status.QUEUED),
		"queued again")
	var bob := _queueing()
	assert_true(await _until_together(alice, bob), "matched after coming back")


func test_queues_again_when_a_matched_player_never_comes() -> void:
	var absent: Absent = add_child_autofree(Absent.new())
	absent.start(_url)
	assert_true(await _until(func() -> bool: return absent.queued), "the absent player queued")
	var alice := _queueing()
	assert_true(await _until(func() -> bool: return absent.matched), "matched with the absent player")

	assert_true(await _until(func() -> bool: return alice.closed_reasons.has(Frames.CloseReason.MATCH_INCOMPLETE)),
		"the room closed without the absent player")
	assert_true(await _until_queued(alice), "alice queued again")
	var bob := _queueing()

	assert_true(await _until_together(alice, bob), "matched with someone who came")


func test_joining_leaves_the_queue_and_queueing_needs_no_room() -> void:
	var alice := _queueing()
	assert_true(await _until_queued(alice), "alice queued")
	var code := _new_code()

	assert_eq(alice.client.join(code), OK)

	assert_true(await _until(func() -> bool: return alice.status == PlayholdClient.Status.JOINED and alice.code == code),
		"in the room")
	assert_eq(alice.client.queue(), ERR_ALREADY_IN_USE, "already in a room")


func test_queue_properties_are_sent_as_strings() -> void:
	var p := _player()

	p.client.queue({"mode": "fast", "level": 3})

	assert_eq_deep(p.client._queue_properties, {"mode": "fast", "level": "3"})


func test_comes_back_and_queues_again_when_asked_to_slow_down() -> void:
	var p := _player()
	p.client.connect_to_url(_url)
	assert_true(await _until(func() -> bool: return p.status == PlayholdClient.Status.CONNECTED), "connected")
	p.client.queue()

	p.client._receive(_server_error(p.client._queue_seq, Frames.ErrorCode.RATE_LIMITED))

	assert_true(await _until(func() -> bool:
		return p.statuses.has(PlayholdClient.Status.DISCONNECTED) and p.status == PlayholdClient.Status.QUEUED),
		"queued after the retry")


func test_stops_asking_when_the_queue_is_refused() -> void:
	var p := _player()
	p.client.connect_to_url(_url)
	assert_true(await _until(func() -> bool: return p.status == PlayholdClient.Status.CONNECTED), "connected")
	p.client.queue()

	p.client._receive(_server_error(p.client._queue_seq, Frames.ErrorCode.REJECTED))

	await wait_seconds(_QUIET)
	assert_eq(p.status, PlayholdClient.Status.CONNECTED, "the server's Queued is ignored")
	assert_has(p.errors, Frames.ErrorCode.REJECTED)