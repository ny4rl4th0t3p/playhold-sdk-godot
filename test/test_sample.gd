extends GutTest
## The sample, sample/main.tscn, without a server: views built here with the tutorial's generated messages, and what the
## scene shows for them. Playing it against chapter 7's server is done by hand.

const Frames = preload("res://addons/playhold/frames.gd")
const TicTacToe = preload("res://sample/tictactoe.gd")
const Score = preload("res://sample/score.gd")
const Main = preload("res://sample/main.tscn")

const _EMPTY := TicTacToe.Mark.UNSPECIFIED
const _X := TicTacToe.Mark.X
const _O := TicTacToe.Mark.O

var _main: Node


func before_each() -> void:
	_main = add_child_autofree(Main.instantiate())


func after_each() -> void:
	Playhold.close() # the sample connects the autoload when it starts; nothing listens, but stop it trying


func _board(cells: Array, status: int, out_of_time := false) -> PackedByteArray:
	var board := TicTacToe.BoardView.new()
	for mark: int in cells:
		board.add_cells(mark)
	board.set_you(TicTacToe.Mark.X)
	board.set_status(status)
	board.set_out_of_time(out_of_time)
	return board.to_bytes()


func _cell(index: int) -> Button:
	return _main.get_node("%Board").get_child(index)


func test_starts_in_the_lobby_with_an_empty_board() -> void:
	assert_true(_main.get_node("%Lobby").visible)
	assert_false(_main.get_node("%Game").visible)
	assert_eq(_main.get_node("%Board").get_child_count(), 9)


func test_shows_the_room_and_its_code() -> void:
	_main._show_room("ABCD")

	assert_false(_main.get_node("%Lobby").visible)
	assert_true(_main.get_node("%Game").visible)
	assert_eq(_main.get_node("%RoomCode").text, "ABCD")
	assert_false(_main.get_node("%RoomCode").editable, "selectable, but not changed by mistake")


## Only the button's answer: headless Godot, which runs the tests, has no clipboard. Copying is checked by hand.
func test_says_when_the_room_code_was_copied() -> void:
	_main._show_room("ABCD")

	_main.get_node("%CopyCode").pressed.emit()

	assert_eq(_main.get_node("%CopyCode").text, "Copied")


func test_goes_back_to_the_lobby_when_the_room_closes() -> void:
	_main._show_room("ABCD")
	_main._show_views({"board": _board([_X, _EMPTY, _EMPTY, _EMPTY, _EMPTY, _EMPTY, _EMPTY, _EMPTY, _EMPTY],
		TicTacToe.Status.THEIR_TURN)})

	Playhold.room_closed.emit(Frames.CloseReason.INACTIVE)

	assert_true(_main.get_node("%Lobby").visible)
	assert_false(_main.get_node("%Game").visible)
	assert_string_contains(_main.get_node("%Message").text, "nobody played for a while")
	assert_eq(_cell(0).text, "", "the old board is cleared")


func test_goes_back_to_the_lobby_when_coming_back_finds_the_room_gone() -> void:
	_main._show_room("ABCD")
	Playhold._status = PlayholdClient.Status.CONNECTED # welcomed again, and its Join refused

	Playhold.server_error.emit(3, Frames.ErrorCode.ROOM_NOT_FOUND, "no room has this code")

	assert_true(_main.get_node("%Lobby").visible)
	assert_string_contains(_main.get_node("%Message").text, "no room has this code")


func test_an_error_in_a_game_only_shows() -> void:
	_main._show_room("ABCD")
	Playhold._status = PlayholdClient.Status.JOINED

	Playhold.server_error.emit(4, Frames.ErrorCode.REJECTED, "it isn't your turn")

	assert_true(_main.get_node("%Game").visible)
	assert_eq(_main.get_node("%Message").text, "it isn't your turn")


func test_on_your_turn_only_empty_cells_can_be_played() -> void:
	_main._show_views({"board": _board([_X, _EMPTY, _EMPTY, _EMPTY, _O, _EMPTY, _EMPTY, _EMPTY, _EMPTY],
		TicTacToe.Status.YOUR_TURN)})

	assert_eq(_cell(0).text, "X")
	assert_eq(_cell(4).text, "O")
	assert_eq(_cell(1).text, "")
	assert_true(_cell(0).disabled, "a marked cell")
	assert_false(_cell(1).disabled, "an empty cell")
	assert_eq(_main.get_node("%Status").text, "Your turn.")
	assert_false(_main.get_node("%Rematch").visible)


func test_on_their_turn_nothing_can_be_played() -> void:
	_main._show_views({"board": _board([_X, _EMPTY, _EMPTY, _EMPTY, _EMPTY, _EMPTY, _EMPTY, _EMPTY, _EMPTY],
		TicTacToe.Status.THEIR_TURN)})

	for cell in 9:
		assert_true(_cell(cell).disabled, "cell %d" % cell)
	assert_eq(_main.get_node("%Status").text, "Their turn.")


func test_a_finished_game_offers_another() -> void:
	_main._show_views({"board": _board([_X, _X, _X, _O, _O, _EMPTY, _EMPTY, _EMPTY, _EMPTY], TicTacToe.Status.WON)})

	assert_eq(_main.get_node("%Status").text, "You won!")
	assert_true(_main.get_node("%Rematch").visible)
	assert_true(_cell(5).disabled, "the game is over")


func test_says_when_the_game_ended_on_time() -> void:
	_main._show_views({"board": _board([], TicTacToe.Status.WON, true)})
	assert_eq(_main.get_node("%Status").text, "They ran out of time. You won!")

	_main._show_views({"board": _board([], TicTacToe.Status.LOST, true)})
	assert_eq(_main.get_node("%Status").text, "You ran out of time.")


func test_shows_the_score() -> void:
	var score := Score.ScoreView.new()
	score.set_wins(2)
	score.set_losses(1)
	score.set_draws(3)

	_main._show_views({"board": _board([], TicTacToe.Status.WAITING), "score": score.to_bytes()})

	assert_eq(_main.get_node("%Score").text, "You 2, them 1, draws 3")
	assert_eq(_main.get_node("%Status").text, "Waiting for the other player…")


func test_reads_the_cells_as_go_encodes_them_packed() -> void:
	# A BoardView as the server's Go code sends it: proto3 packs the repeated cells into one field. X in cell 0, O in
	# cell 4, the player is X, and it's their turn.
	var bytes := "0a0901000000020000000010011802".hex_decode()

	_main._show_views({"board": bytes})

	assert_eq(_cell(0).text, "X")
	assert_eq(_cell(4).text, "O")
	assert_false(_cell(1).disabled)
	assert_eq(_main.get_node("%Status").text, "Your turn.")