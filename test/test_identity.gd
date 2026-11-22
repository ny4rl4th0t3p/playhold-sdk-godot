extends GutTest
## The identity store on its own, on files under user:// that each test empties first.

const Identity = preload("res://addons/playhold/identity.gd")

var _last_file := 0


## Returns a path of its own for each test, emptied, so a file left by an earlier run doesn't count.
func _new_path() -> String:
	_last_file += 1
	var path := "user://test_identity_store_%d.cfg" % _last_file
	Identity.new(path).clear()
	return path


func test_a_new_guest_has_no_identity() -> void:
	assert_eq(Identity.new(_new_path()).read(), {})


func test_an_identity_is_read_back_from_its_file() -> void:
	var path := _new_path()
	Identity.new(path).write("p1", "s1")

	assert_eq(Identity.new(path).read(), {"player_id": "p1", "secret": "s1"})


func test_the_file_comes_before_the_copy_in_memory() -> void:
	var path := _new_path()
	var first := Identity.new(path)
	first.write("p1", "s1")

	Identity.new(path).write("p2", "s2") # another copy of the game, given a newer identity

	assert_eq(first.read(), {"player_id": "p2", "secret": "s2"})


func test_clear_forgets_the_file_and_the_copy_in_memory() -> void:
	var path := _new_path()
	var identity := Identity.new(path)
	identity.write("p1", "s1")

	identity.clear()

	assert_eq(identity.read(), {})
	assert_eq(Identity.new(path).read(), {})


func test_a_file_that_cant_be_written_keeps_the_identity_in_memory() -> void:
	var path := "user://no-such-folder/identity.cfg"
	var identity := Identity.new(path)

	identity.write("p1", "s1")

	assert_eq(identity.read(), {"player_id": "p1", "secret": "s1"})
	assert_eq(Identity.new(path).read(), {}, "nothing was saved")
	_handle_engine_errors()


func test_a_broken_file_falls_back_to_the_copy_in_memory() -> void:
	var path := _new_path()
	var identity := Identity.new(path)
	identity.write("p1", "s1")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("not [a config file")
	file.close()

	assert_eq(identity.read(), {"player_id": "p1", "secret": "s1"})
	assert_eq(Identity.new(path).read(), {})
	_handle_engine_errors()


func test_an_empty_path_keeps_the_identity_in_memory_only() -> void:
	var identity := Identity.new("")

	identity.write("p1", "s1")

	assert_eq(identity.read(), {"player_id": "p1", "secret": "s1"})
	assert_eq(Identity.new("").read(), {})


## Marks the errors Godot logs about a file it couldn't write or parse as expected, so they don't fail the test: the
## store's answer is what's checked.
func _handle_engine_errors() -> void:
	for error in get_errors():
		error.handled = true