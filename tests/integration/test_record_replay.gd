extends GdUnitTestSuite
## Records the demo with scripted input, captures a bundle to disk, and replays
## it in fresh scenes through the public ReplayRecorder / ReplayTestKit API.

const SCENE := "res://example/main.tscn"
const DemoBot := preload("res://tests/support/demo_bot.gd")
## Power-of-two speed-ups keep the physics delta bit-identical.
const SPEED := 8

var _scenes: Array[Node] = []


func after_test() -> void:
	DemoWorld.debug_unseeded_drift_from_tick = -1
	_set_speed(1)
	_free_scenes()


# gdUnit4 measures timeouts in scaled time: SPEED x the real duration.
func test_a_30_second_walk_replays_to_the_same_final_position_10_of_10(timeout := 1_800_000) -> void:
	# Ask for 30 s of lead-up so the bundle covers the whole walk from tick 1.
	var bundle_path := await _record(1800, DemoBot.walk_plan(), func(recorder: ReplayRecorder) -> void:
		recorder.min_keyframe_age_seconds = 30.0)
	var recorded := ReplayBundle.open(bundle_path)
	assert_object(recorded).is_not_null()
	assert_int(recorded.start_tick()).is_equal(1)
	assert_int(recorded.end_tick() - recorded.start_tick()).is_greater_equal(1799)
	var recorded_position: Variant = ReplayTestKit.field(recorded.state_end, "player.position")

	for run in 10:
		var result := await _replay(bundle_path)
		assert_bool(result.ok).override_failure_message("run %d: %s" % [run, result.text()]).is_true()
		assert_that(ReplayTestKit.field(result.final_state, "player.position")).is_equal(recorded_position)
		assert_int(result.checkpoints_matched).is_equal(recorded.checkpoints.size())
	assert_int(recorded.checkpoints.size()).is_greater_equal(59)


func test_a_bundle_starts_at_the_newest_keyframe_with_enough_lead_up() -> void:
	var bundle_path := await _record(1800, DemoBot.walk_plan())
	var recorded := ReplayBundle.open(bundle_path)

	# The walk crosses the doorway (an autosave) several times; the newest
	# crossing at least 10 s before the capture starts the bundle.
	assert_int(recorded.start_tick()).is_greater(1).is_less_equal(1800 - 600)
	var result := await _replay(bundle_path)
	assert_bool(result.ok).override_failure_message(result.text()).is_true()


func test_an_unseeded_randf_in_gameplay_is_reported_at_the_first_checkpoint_after_it() -> void:
	var bundle_path := await _record(900, DemoBot.walk_plan())
	var recorded := ReplayBundle.open(bundle_path)
	# The demo counts its own ticks; map the bug's recorder tick to the world tick.
	var world_tick_offset := recorded.end_tick() - int(recorded.state_end["tick"])
	var bug_tick := recorded.start_tick() + 95
	DemoWorld.debug_unseeded_drift_from_tick = bug_tick - world_tick_offset
	var expected_tick := ceili(bug_tick / 30.0) * 30

	var result := await _replay(bundle_path)

	assert_int(result.status).is_equal(ReplayResult.Status.DIVERGED)
	assert_int(result.tick).is_equal(expected_tick)
	var report := result.text()
	assert_str(report).contains("REPLAY DIVERGED at tick %d (checkpoint" % expected_tick)
	assert_str(report).contains("player.position: recorded (")
	assert_str(report).contains("previous checkpoint")
	assert_int(result.exit_code()).is_equal(1)


func test_text_the_player_typed_is_replayed_on_the_same_tick() -> void:
	var bundle_path := await _record(600, DemoBot.walk_plan(), func(recorder: ReplayRecorder) -> void:
		recorder.get_parent().add_child(TextTyper.new(recorder, 200, "sign", "hello there")))
	var recorded := ReplayBundle.open(bundle_path)
	assert_str(recorded.state_end["sign"]).is_equal("hello there")

	var result := await _replay(bundle_path)

	assert_bool(result.ok).override_failure_message(result.text()).is_true()
	assert_str(result.final_state["sign"]).is_equal("hello there")


func test_f12_saves_a_bundle_with_the_testers_note_that_replays() -> void:
	var scene := _start_scene()
	var recorder := _recorder_in(scene)
	recorder.output_dir = create_temp_dir("hotkey")
	var saved: Array[String] = []
	recorder.bundle_saved.connect(func(path: String) -> void: saved.append(path))
	# Real key events, flushed by the engine before the tick like a tester's keyboard.
	scene.add_child(DemoBot.new(recorder, DemoBot.walk_plan(), true))
	_set_speed(SPEED)
	while recorder.tick < 400:
		await get_tree().process_frame
	_set_speed(1)
	print("log line before the bug report")

	_press_key(KEY_F12)

	assert_int(saved.size()).is_equal(1)
	assert_bool(recorder.is_note_prompt_open()).is_true()
	assert_bool(get_tree().paused).is_true()
	recorder.submit_note("walked into the wanderer")
	assert_bool(get_tree().paused).is_false()

	var bundle := ReplayBundle.open(saved[0])
	assert_object(bundle).is_not_null()
	assert_str(bundle.manifest["note"]).is_equal("walked into the wanderer")
	assert_str(bundle.manifest["scene"]).is_equal(SCENE)
	assert_int(bundle.physics_fps()).is_equal(60)
	assert_str(bundle.log_text).contains("log line before the bug report")
	assert_bool(bundle.keyframe.is_empty()).is_false()
	assert_bool(bundle.state_end.is_empty()).is_false()
	assert_bool(bundle.input.lines.is_empty()).is_false()
	assert_bool(bundle.checkpoints.is_empty()).is_false()
	# The lamp tap was a key pressed and released within one frame.
	assert_bool(bundle.input.lines.any(func(line: Dictionary) -> bool: return line.has("tap"))).is_true()
	assert_bool(bundle.state_end["lamp_on"]).is_true()
	_free_scenes()

	var result := await _replay(saved[0])

	assert_bool(result.ok).override_failure_message(result.text()).is_true()


# --- helpers ---------------------------------------------------------------

func _start_scene() -> Node:
	var scene: Node = (load(SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(scene)
	_scenes.append(scene)
	return scene


func _free_scenes() -> void:
	for scene in _scenes:
		if is_instance_valid(scene):
			scene.free()
	_scenes.clear()


func _recorder_in(scene: Node) -> ReplayRecorder:
	return ReplayRecorder.find_under(scene)


## Records [param ticks] ticks of the demo driven by [param plan] and returns
## the captured bundle's path.
func _record(ticks: int, plan: Dictionary, configure := Callable()) -> String:
	var scene := _start_scene()
	var recorder := _recorder_in(scene)
	recorder.output_dir = create_temp_dir("bundles")
	recorder.ask_for_note = false
	if configure.is_valid():
		configure.call(recorder)
	scene.add_child(DemoBot.new(recorder, plan))
	_set_speed(SPEED)
	while recorder.tick < ticks:
		await get_tree().process_frame
	_set_speed(1)
	var path := recorder.capture("scripted test session")
	_free_scenes()
	return path


func _replay(bundle_path: String) -> ReplayResult:
	var scene := _start_scene()
	var result: ReplayResult = await ReplayTestKit.replay(scene, bundle_path, SPEED)
	_free_scenes()
	return result


static func _set_speed(speed: int) -> void:
	var fps: int = ProjectSettings.get_setting("physics/common/physics_ticks_per_second")
	Engine.physics_ticks_per_second = fps * speed
	Engine.time_scale = speed


static func _press_key(key: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.pressed = pressed
		Input.parse_input_event(event)
	Input.flush_buffered_events()


## Submits text through the recorder during a given tick, like a text field would.
class TextTyper extends Node:
	var _recorder: ReplayRecorder
	var _tick: int
	var _channel: String
	var _text: String

	func _init(recorder: ReplayRecorder, at_tick: int, channel: String, text: String) -> void:
		_recorder = recorder
		_tick = at_tick
		_channel = channel
		_text = text

	func _physics_process(_delta: float) -> void:
		if _recorder.tick == _tick:
			_recorder.submit_text(_channel, _text)
