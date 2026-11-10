extends GdUnitTestSuite
## The recorder's rolling buffer and the bundle files it produces.

const MIN_AGE := 600


func _buffer_with_history() -> ReplayBuffer:
	var buffer := ReplayBuffer.new(MIN_AGE)
	buffer.add_keyframe(1, {"at": 1}, {"rng": "1"})
	buffer.input.add(5, {"move_right": 1.0})
	buffer.add_checkpoint(30, "h30", {"x": 30})
	buffer.add_keyframe(100, {"at": 100}, {"rng": "100"})
	buffer.input.add(150, {"move_up": 0.5}, ["interact"])
	buffer.add_checkpoint(150, "h150", {"x": 150})
	buffer.add_keyframe(500, {"at": 500}, {"rng": "500"})
	buffer.input.add(510, {"move_right": 0.0})
	buffer.add_checkpoint(510, "h510", {"x": 510})
	return buffer


func test_a_bundle_starts_at_the_newest_keyframe_old_enough_with_held_input_carried_in() -> void:
	var bundle := _buffer_with_history().make_bundle(800)

	assert_int(bundle.start_tick()).is_equal(100)
	assert_dict(bundle.keyframe).is_equal({"at": 100})
	assert_dict(bundle.manifest["seeds"]).is_equal({"rng": "100"})
	assert_array(bundle.input.lines).is_equal([
		{"t": 100, "a": {"move_right": 1.0}},
		{"t": 150, "a": {"move_up": 0.5}, "tap": ["interact"]},
		{"t": 510, "a": {"move_right": 0.0}},
	])
	assert_array(bundle.checkpoints).is_equal([{"t": 150, "h": "h150"}, {"t": 510, "h": "h510"}])


func test_a_bundle_falls_back_to_the_oldest_keyframe_when_none_is_old_enough() -> void:
	var bundle := _buffer_with_history().make_bundle(400)

	assert_int(bundle.start_tick()).is_equal(1)
	assert_int(bundle.end_tick()).is_equal(400)
	assert_array(bundle.checkpoints).is_equal([{"t": 30, "h": "h30"}, {"t": 150, "h": "h150"}])


func test_trimming_keeps_what_a_later_capture_can_still_use() -> void:
	var buffer := _buffer_with_history()

	buffer.trim(800)

	# Later captures can only start at 100 or newer, so keyframe 1 and its input go.
	assert_int(buffer.keyframes.size()).is_equal(2)
	assert_int(buffer.make_bundle(2000).start_tick()).is_equal(500)
	assert_dict(buffer.make_bundle(900).input.state_at(100)).is_equal({"move_right": 1.0})
	assert_array(buffer.checkpoints.map(func(c: Dictionary) -> int: return c["t"])).is_equal([150, 510])


func test_a_bundle_survives_a_folder_and_zip_round_trip_exactly() -> void:
	var bundle := _buffer_with_history().make_bundle(800)
	# Analog strengths come from float32; they must replay bit-exactly.
	var analog := float(PackedFloat32Array([0.7])[0])
	bundle.input.add(700, {"move_down": analog}, [], [["sign", "héllo"]])
	bundle.manifest.merge({"format": ReplayBundle.FORMAT, "note": "stuck", "physics_fps": 60})
	bundle.state_end = {"player": {"position": [1.5, 2.25]}}
	bundle.log_text = "line one\nline two\n"
	var dir := create_temp_dir("roundtrip")

	for path in [dir.path_join("bug-a"), dir.path_join("bug-b.zip")]:
		var err := bundle.save_zip(path) if path.ends_with(".zip") else bundle.save(path)
		assert_int(err).is_equal(OK)
		var loaded := ReplayBundle.open(path)

		assert_object(loaded).override_failure_message(ReplayBundle.last_error).is_not_null()
		assert_str(loaded.bundle_name()).is_equal(path.get_file().get_basename())
		assert_int(loaded.start_tick()).is_equal(100)
		assert_str(loaded.manifest["note"]).is_equal("stuck")
		assert_dict(loaded.keyframe).is_equal({"at": 100.0})
		assert_array(loaded.input.lines).is_equal(bundle.input.lines)
		assert_bool(loaded.input.state_at(700)["move_down"] == analog).is_true()
		assert_array(loaded.checkpoints).is_equal(bundle.checkpoints)
		assert_dict(loaded.dump_at(150)).is_equal({"x": 150.0})
		assert_dict(loaded.state_end).is_equal(bundle.state_end)
		assert_str(loaded.log_text).is_equal(bundle.log_text)


func test_the_tester_note_can_be_rewritten_inside_a_zipped_bundle() -> void:
	var bundle := _buffer_with_history().make_bundle(800)
	bundle.manifest["format"] = ReplayBundle.FORMAT
	var path := create_temp_dir("note").path_join("bug.zip")
	bundle.save_zip(path)

	assert_int(ReplayBundle.set_note(path, "fell through the floor")).is_equal(OK)

	assert_str(ReplayBundle.open(path).manifest["note"]).is_equal("fell through the floor")


func test_opening_something_that_is_not_a_bundle_explains_why() -> void:
	var dir := create_temp_dir("empty")
	FileAccess.open(dir.path_join("readme.txt"), FileAccess.WRITE).store_string("hi")

	assert_object(ReplayBundle.open(dir)).is_null()
	assert_str(ReplayBundle.last_error).contains("not a replay bundle")
