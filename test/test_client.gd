extends GutTest
## The client against the test server in testserver/, which make test starts and passes in PLAYHOLD_TEST_URL. The
## server's "counter" module adds to a total shared by the room, and shows each player "<player>:<total>". Rooms have
## two seats, and clients may choose their codes.

const Frames = preload("res://addons/playhold/frames.gd")
const Identity = preload("res://addons/playhold/identity.gd")
const Counter = preload("res://test/counter.gd")

const _MSG_ADD := 1
## How long to wait for the server, in seconds.
const _WAIT := 5.0


## A client, and what it has seen.
class Player:
	var client: PlayholdClient
	var status: int = PlayholdClient.Status.DISCONNECTED
	var code := ""
	var view := ""
	var errors: Array[int] = []


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


## Returns a player with its client in the tree, not yet connected. Without an identity file, it gets one of its own.
func _player(identity_path := "") -> Player:
	var p := Player.new()
	p.client = PlayholdClient.new()
	p.client.identity_path = identity_path if identity_path != "" else _new_identity_path()
	p.client.schema_versions = {"counter": 2}
	p.client.status_changed.connect(func(status: PlayholdClient.Status) -> void: p.status = status)
	p.client.room_joined.connect(func(code: String) -> void: p.code = code)
	p.client.views_received.connect(func(views: Dictionary) -> void: p.view = _total(views))
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