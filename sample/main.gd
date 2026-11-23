extends MarginContainer
## The tutorial's tic-tac-toe as a Godot client of its chapter 7 server: the same game as chapter 7's browser page. The
## rules stay on the server: this shows the board the server sends, and sends a move when a cell is pressed.
##
## Start chapter 7's server first ([code]go run ./server[/code] in playhold-tictactoe/chapter7), then this scene. The
## client is the [code]Playhold[/code] autoload, set in Project Settings. Arguments after [code]--[/code] on the
## command line: [code]--server=URL[/code] for another server, and [code]--player=NAME[/code] for a second copy on the
## same machine, which needs an identity of its own.

const Frames = preload("res://addons/playhold/frames.gd")
const TicTacToe = preload("res://sample/tictactoe.gd")
const Score = preload("res://sample/score.gd")

## Chapter 7's server, run on this machine.
const _DEFAULT_SERVER := "ws://localhost:8080/ws"

#region text
const _CONNECTION_TEXT := {
	PlayholdClient.Status.DISCONNECTED: "Connection lost. Reconnecting…",
	PlayholdClient.Status.CONNECTING: "Connecting…",
	PlayholdClient.Status.REPLACED: "You opened this game somewhere else, so it stopped here.",
	PlayholdClient.Status.CLOSED: "Disconnected.",
	PlayholdClient.Status.UPDATE_REQUIRED: "There's a newer version of this game. Update it to keep playing.",
}

const _STATUS_TEXT := {
	TicTacToe.Status.WAITING: "Waiting for the other player…",
	TicTacToe.Status.YOUR_TURN: "Your turn.",
	TicTacToe.Status.THEIR_TURN: "Their turn.",
	TicTacToe.Status.WON: "You won!",
	TicTacToe.Status.LOST: "You lost.",
	TicTacToe.Status.DRAW: "A draw.",
}

const _MARK_TEXT := {TicTacToe.Mark.X: "X", TicTacToe.Mark.O: "O"}

## Why the room closed, for the player. A server that stops sends nothing: the room comes back with it.
const _CLOSED_TEXT := {
	Frames.CloseReason.REQUESTED: "The game was closed.",
	Frames.CloseReason.INACTIVE: "The game closed, since nobody played for a while.",
	Frames.CloseReason.PANIC: "The game closed after a problem on the server.",
	Frames.CloseReason.STUCK: "The game closed after a problem on the server.",
}


## How the game stands, saying so when it ended on time.
static func status_text(board: TicTacToe.BoardView) -> String:
	if board.get_out_of_time():
		return "They ran out of time. You won!" if board.get_status() == TicTacToe.Status.WON else "You ran out of time."
	return _STATUS_TEXT.get(board.get_status(), "")
#endregion

## When the turn ends, in [method Time.get_ticks_msec]; 0 while no game is on.
var _deadline := 0

@onready var _connection: Label = %Connection
@onready var _message: Label = %Message
@onready var _lobby: Control = %Lobby
@onready var _new_game: Button = %NewGame
@onready var _code: LineEdit = %Code
@onready var _join: Button = %Join
@onready var _game: Control = %Game
@onready var _room_code: LineEdit = %RoomCode
@onready var _copy_code: Button = %CopyCode
@onready var _status: Label = %Status
@onready var _clock: Label = %Clock
@onready var _board: GridContainer = %Board
@onready var _score: Label = %Score
@onready var _rematch: Button = %Rematch


#region client
func _ready() -> void:
	_make_board()
	_new_game.pressed.connect(func() -> void: Playhold.create_room()) # the code arrives in room_joined
	_join.pressed.connect(_join_typed)
	_copy_code.pressed.connect(_copy_room_code)
	_rematch.pressed.connect(_ask_rematch)

	Playhold.status_changed.connect(_show_connection)
	Playhold.room_joined.connect(_show_room)
	Playhold.views_received.connect(_show_views)
	Playhold.room_closed.connect(_room_closed)
	Playhold.server_error.connect(_show_error)

	var arguments := _arguments()
	if arguments.has("player"): # a second copy on this machine, as another player
		Playhold.identity_path = "user://playhold_identity_%s.cfg" % arguments.player.validate_filename()
	Playhold.connect_to_url(arguments.get("server", _DEFAULT_SERVER))


func _show_connection(status: PlayholdClient.Status) -> void:
	_connection.text = _CONNECTION_TEXT.get(status, "")


func _show_error(_seq: int, _error_code: int, message: String) -> void:
	if _game.visible and Playhold.status == PlayholdClient.Status.CONNECTED:
		# Coming back, the room refused the player, such as one a server lost when it restarted without saving games:
		# the client has forgotten it, so the board on screen is gone.
		_back_to_lobby(message)
		return
	_message.text = message # such as "it isn't your turn"


func _room_closed(reason: int) -> void:
	_back_to_lobby(_CLOSED_TEXT.get(reason, "The game closed."))


## Goes back to where a game starts, with [param text] saying why, since the room is gone.
func _back_to_lobby(text: String) -> void:
	_render(null)
	_render_score(null)
	_room_code.text = ""
	_copy_code.text = "Copy"
	_game.visible = false
	_lobby.visible = true
	_message.text = text + " Start a new one, or join another."
#endregion


## The arguments after [code]--[/code] on the command line, such as [code]--server=ws://192.168.1.20:8080/ws[/code].
func _arguments() -> Dictionary:
	var found := {}
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and argument.contains("="):
			var parts := argument.trim_prefix("--").split("=", true, 1)
			found[parts[0]] = parts[1]
	return found


#region views
func _show_views(views: Dictionary) -> void:
	_render(_board_of(views))
	_render_score(_score_of(views))


## The board's view, out of everything the player can see in the room: one view per module.
func _board_of(views: Dictionary) -> TicTacToe.BoardView:
	if not views.has("board"):
		return null
	var board := TicTacToe.BoardView.new()
	board.from_bytes(views["board"])
	return board


func _render(board: TicTacToe.BoardView) -> void:
	_status.text = status_text(board) if board != null else ""
	_show_clock(board.get_turn_millis_left() if board != null else 0)
	var status: int = board.get_status() if board != null else TicTacToe.Status.UNSPECIFIED
	_rematch.visible = status in [TicTacToe.Status.WON, TicTacToe.Status.LOST, TicTacToe.Status.DRAW]
	var cells: Array = board.get_cells() if board != null else []
	for cell in _board.get_child_count():
		var button: Button = _board.get_child(cell)
		var mark: int = cells[cell] if cell < cells.size() else TicTacToe.Mark.UNSPECIFIED
		button.text = _MARK_TEXT.get(mark, "")
		button.disabled = status != TicTacToe.Status.YOUR_TURN or mark != TicTacToe.Mark.UNSPECIFIED
#endregion


#region score
## The score's view: another module, in the same state as the board's.
func _score_of(views: Dictionary) -> Score.ScoreView:
	if not views.has("score"):
		return null
	var score := Score.ScoreView.new()
	score.from_bytes(views["score"])
	return score


func _render_score(score: Score.ScoreView) -> void:
	if score == null:
		_score.text = ""
		return
	_score.text = "You %d, them %d, draws %d" % [score.get_wins(), score.get_losses(), score.get_draws()]


## Asks the score module for another game; it asks the board, through the board's keeper.
func _ask_rematch() -> void:
	_message.text = ""
	Playhold.send("score", Score.ScoreMessage.REMATCH, Score.Rematch.new().to_bytes())
#endregion


#region clock
## Counts the turn's time down. The server only sends the time left with each view, so this counts on from there until
## the next one. The server's timer decides: this is only what the player sees.
func _show_clock(millis_left: int) -> void:
	_deadline = Time.get_ticks_msec() + millis_left if millis_left > 0 else 0
	_tick()


func _process(_delta: float) -> void:
	if _deadline > 0:
		_tick()


func _tick() -> void:
	if _deadline == 0:
		_clock.text = "" # no game on
		return
	var seconds := ceili(maxf(0, _deadline - Time.get_ticks_msec()) / 1000.0)
	_clock.text = "%d s left" % seconds
#endregion


#region moves
func _make_board() -> void:
	for cell in 9:
		var button := Button.new()
		button.custom_minimum_size = Vector2(80, 80)
		button.add_theme_font_size_override("font_size", 32)
		button.disabled = true
		button.pressed.connect(_play.bind(cell))
		_board.add_child(button)


func _play(cell: int) -> void:
	_message.text = ""
	var play := TicTacToe.Play.new()
	play.set_cell(cell)
	Playhold.send("board", TicTacToe.Message.PLAY, play.to_bytes())


## Joins the room whose code the player pasted or typed: the code the other player's game shows.
func _join_typed() -> void:
	var code := _code.text.strip_edges()
	if code != "":
		_message.text = ""
		Playhold.join(code)


## Shows the room's code, for the other player to paste into their game. It's long, being the server's, so it's in a
## field that can be selected, with a button that copies it.
func _show_room(code: String) -> void:
	_room_code.text = code
	_copy_code.text = "Copy"
	_lobby.visible = false
	_game.visible = true


func _copy_room_code() -> void:
	DisplayServer.clipboard_set(_room_code.text)
	_message.text = ""
	_copy_code.text = "Copied"
#endregion
