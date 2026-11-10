class_name ReplayCli
extends RefCounted
## Command-line replays (user arguments after `--`):
## [codeblock]
## --replay=<bundle>                  replay; exit 0 matched, 1 diverged, 2 error
## --until=<tick>                     stop after this tick
## --dump-state                       print state_dump() as JSON at the stop tick
## --capture=<png>                    save the viewport at the stop tick (windowed run)
## --make-test=<path.gd>              write a gdUnit4 test that replays the bundle
## --assert=<field,field>             with --make-test: assert these final-state fields
## [/codeblock]
## Output lines start with [constant ReplayRecorder.LOG_PREFIX] so wrappers can
## drop the engine's own output.


static func parse(args: PackedStringArray) -> Dictionary:
	var options := {}
	for arg in args:
		var key := arg.get_slice("=", 0)
		var value := arg.substr(key.length() + 1) if arg.contains("=") else ""
		match key:
			"--replay":
				options["replay"] = value
			"--until":
				options["until"] = int(value)
			"--dump-state":
				options["dump_state"] = true
			"--capture":
				options["capture"] = value
			"--make-test":
				options["make_test"] = value
			"--assert":
				options["assert"] = PackedStringArray(value.split(",", false))
	return options


## Prints the outcome, runs the requested follow-ups and quits the game.
static func complete(recorder: Node, bundle: ReplayBundle, result: ReplayResult, options: Dictionary) -> void:
	var tree := recorder.get_tree()
	var exit_code := result.exit_code()
	_print_lines(result.text())

	if options.has("make_test") and options.has("until"):
		_print_lines("REPLAY ERROR: --make-test replays the whole bundle; drop --until")
		exit_code = 2
	elif result.status != ReplayResult.Status.ERROR:
		if options.get("dump_state", false):
			_print_lines(JSON.stringify(result.final_state, "  ", false))
		if options.has("capture"):
			tree.paused = true
			await RenderingServer.frame_post_draw
			var error := _capture(recorder, options["capture"])
			if not error.is_empty():
				_print_lines("CAPTURE ERROR: " + error)
				exit_code = maxi(exit_code, 2)
			else:
				_print_lines("captured " + str(options["capture"]))
		if options.has("make_test"):
			if result.ok:
				var written := ReplayTestWriter.write(bundle, options["make_test"], result.final_state,
						options.get("assert", PackedStringArray()))
				_print_lines(written)
				if written.begins_with("TEST ERROR"):
					exit_code = 2
			else:
				_print_lines("no test written: the replay must match before it can become a test")
	tree.quit(exit_code)


static func _capture(recorder: Node, png_path: String) -> String:
	if DisplayServer.get_name() == "headless":
		return "--capture needs a windowed run (drop --headless)"
	var image := recorder.get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		return "the viewport returned no image"
	var err := image.save_png(png_path)
	return "" if err == OK else "cannot write %s (%s)" % [png_path, error_string(err)]


static func _print_lines(text: String) -> void:
	for line in text.split("\n"):
		print(ReplayRecorder.LOG_PREFIX + line)
