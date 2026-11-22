extends RefCounted
## Keeps a guest's identity, the player ID and secret the server gives on the first visit, across runs of the game.
##
## The identity is saved in a [ConfigFile] at the path given, under [code]user://[/code] by default, which a web export
## keeps in the browser. A copy is also kept in memory, so a file that can't be written still keeps the player for as
## long as the game runs. An empty path keeps it in memory only.

const _SECTION := "identity"

var _path: String
var _memory := {}


func _init(path: String) -> void:
	_path = path


## Returns the identity as [code]{"player_id": ..., "secret": ...}[/code], or an empty Dictionary for a new guest. The
## file comes first, since another copy of the game may have saved a newer identity; then the copy in memory.
func read() -> Dictionary:
	if _path != "" and FileAccess.file_exists(_path):
		var file := ConfigFile.new()
		if file.load(_path) == OK:
			var player_id: Variant = file.get_value(_SECTION, "player_id", "")
			var secret: Variant = file.get_value(_SECTION, "secret", "")
			if player_id is String and secret is String and player_id != "" and secret != "":
				return {"player_id": player_id, "secret": secret}
	return _memory.duplicate()


## Saves an identity, replacing any other.
func write(player_id: String, secret: String) -> void:
	_memory = {"player_id": player_id, "secret": secret}
	if _path != "":
		var file := ConfigFile.new()
		file.set_value(_SECTION, "player_id", player_id)
		file.set_value(_SECTION, "secret", secret)
		file.save(_path)


## Forgets the identity, so the next connection starts as a new guest. The file is left in place, empty.
func clear() -> void:
	_memory = {}
	if _path != "":
		ConfigFile.new().save(_path)