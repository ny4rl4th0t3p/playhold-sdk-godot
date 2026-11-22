extends GutHookScript
## Fails the run when a test script didn't load, such as on a parse error in it or in a script it preloads. GUT itself
## only warns and skips such a script, so the run would pass without its tests.

const _DIR := "res://test"


func run() -> void:
	var broken: Array[String] = []
	for file in DirAccess.get_files_at(_DIR):
		if file.begins_with("test_") and file.ends_with(".gd"):
			var script := load(_DIR.path_join(file)) as Script
			if script == null or not script.can_instantiate():
				broken.append(file)
	if not broken.is_empty():
		gut.logger.error("These test scripts didn't load, so their tests didn't run: %s" % ", ".join(broken))
		set_exit_code(1) # GUT's command line exits with a post-run hook's code; a pre-run hook's is ignored