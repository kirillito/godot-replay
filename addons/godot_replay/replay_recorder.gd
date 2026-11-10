class_name ReplayRecorder
extends Node
## Records what the player does, per physics tick, so a bug becomes a file.
##
## Add it from your game's debug layer (it frees itself in release builds) and
## set [member adapter] before it enters the tree. While recording, the hotkey
## writes a bug-report bundle covering the last [member buffer_seconds]. Started
## with [code]-- --replay=<bundle>[/code] on the command line, it replays the
## bundle instead and quits with 0 (matched), 1 (diverged) or 2 (error).

## A bug-report bundle was written to [param path].
signal bundle_saved(path: String)
## A replay started with [method start_replay] (or the command line) ended.
signal replay_finished(result: ReplayResult)
## Text the player entered, delivered at the end of the tick it was submitted
## in, both live and in replays. See [method submit_text].
signal text_submitted(channel: String, text: String)
## A keyframe was stored at [param tick].
signal keyframe_taken(tick: int)

const GROUP := &"replay_recorder"
## Runs after gameplay nodes: keep gameplay physics priorities below this.
const END_OF_TICK_PRIORITY := 1_000_000
const LOG_PREFIX := "[replay] "

@export_group("Recording")
## Record from the start. Set false to call [method start_recording] yourself.
@export var record_on_ready := true
## Actions to record. Empty: every InputMap action except the built-in ui_*
## ones. List ui_* actions explicitly if gameplay or dialogue uses them.
@export var actions: PackedStringArray = []
## The newest keyframe at least this old starts a bundle (lead-up before the bug).
@export var min_keyframe_age_seconds := 10.0
## Input older than this is dropped once a newer keyframe exists.
@export var buffer_seconds := 120.0
## Take a keyframe by itself when the newest one is older than
## [member buffer_seconds] (only while the adapter says it is safe).
@export var auto_keyframe := true
## Ticks between state-hash checkpoints.
@export var checkpoint_interval := 30
## Checkpoint state dumps kept for divergence diffs; -1 keeps all in the buffer.
@export var dump_history := -1

@export_group("Bug reports")
@export var hotkey: Key = KEY_F12
@export_dir var output_dir := "user://bug_reports"
## After the hotkey, pause and ask the tester what went wrong.
@export var ask_for_note := true
## Write bundles as .zip files instead of folders.
@export var zip_bundles := false
@export var log_lines := 200
## Defaults to the project name.
@export var game_id := ""
## Defaults to `git describe` (editor runs) or the project version setting.
@export var game_version := ""

## The game's adapter. Set it before the recorder enters the tree.
var adapter: ReplayAdapter
## The current physics tick: recording ticks count from 1; during a replay
## this is the bundle's tick numbering.
var tick: int:
	get:
		return _player.tick if _player != null else _tick
## The result of the last replay, also when [method start_replay] failed.
var last_result: ReplayResult

enum Mode { IDLE, RECORDING, REPLAYING, NOTE_PROMPT }

var _mode := Mode.IDLE
var _tick := 0
var _buffer: ReplayBuffer
var _recorded_actions := PackedStringArray()
var _last_sample := {}
var _keyframe_requested := false
var _capture_requested := false
var _capture_note := ""
var _pending_texts: Array = []
var _player: ReplayPlayer
var _cli_options := {}
var _log_tail: ReplayLogTail
var _engine_before := {}
var _paused_before_prompt := false
var _prompt_bundle := ""
var _prompt_layer: CanvasLayer


## The recorder under [param root] (or in [param root]'s tree if none is under it).
static func find_under(root: Node) -> ReplayRecorder:
	if not root.is_inside_tree():
		return null
	var fallback: ReplayRecorder = null
	for node in root.get_tree().get_nodes_in_group(GROUP):
		if node == root or root.is_ancestor_of(node):
			return node
		fallback = node
	return fallback


func _ready() -> void:
	if not OS.is_debug_build():
		queue_free()
		return
	add_to_group(GROUP)
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = END_OF_TICK_PRIORITY
	_cli_options = ReplayCli.parse(OS.get_cmdline_user_args())
	if _cli_options.has("replay"):
		if not start_replay(_cli_options["replay"], _cli_options):
			ReplayCli.complete(self, null, last_result, _cli_options)
	elif record_on_ready:
		start_recording()


func _enter_tree() -> void:
	# Connected on every entry so a recorder moved between parents keeps ticking.
	if OS.is_debug_build() and not get_tree().physics_frame.is_connected(_on_tick_begin):
		get_tree().physics_frame.connect(_on_tick_begin)


func _exit_tree() -> void:
	if get_tree().physics_frame.is_connected(_on_tick_begin):
		get_tree().physics_frame.disconnect(_on_tick_begin)
	_remove_log_tail()
	_restore_engine()


# --- recording ---------------------------------------------------------------

## Starts (or restarts) recording with an empty buffer.
func start_recording() -> void:
	_stop_replay()
	_mode = Mode.RECORDING
	_tick = 0
	_buffer = ReplayBuffer.new(_seconds_to_ticks(min_keyframe_age_seconds), dump_history)
	_recorded_actions = _resolve_actions()
	_last_sample = {}
	_pending_texts.clear()
	_keyframe_requested = true
	_install_log_tail()


func is_recording() -> bool:
	return _mode == Mode.RECORDING


func is_replaying() -> bool:
	return _mode == Mode.REPLAYING


## Asks for a keyframe at the end of the current tick (or the first later tick
## where [method ReplayAdapter.is_keyframe_safe] is true). Call it after an
## autosave or a room transition.
func keyframe() -> void:
	_keyframe_requested = true


## Routes text the player typed (a name, a password) through the recorder so
## replays can repeat it. [signal text_submitted] then delivers it to the game,
## live and in replays alike; while replaying, live submissions are ignored.
func submit_text(channel: String, text: String) -> void:
	if _mode == Mode.RECORDING or _mode == Mode.NOTE_PROMPT:
		_pending_texts.append([channel, text])
	elif _mode != Mode.REPLAYING:
		text_submitted.emit(channel, text)


## Writes a bug-report bundle covering the buffer up to now and returns its
## path ("" on failure). Called during a physics tick, it waits for the tick to
## end, returns "" and reports the path through [signal bundle_saved].
func capture(note := "") -> String:
	if _mode != Mode.RECORDING:
		push_warning("ReplayRecorder: capture() needs an active recording")
		return ""
	if Engine.is_in_physics_frame():
		_capture_requested = true
		_capture_note = note
		return ""
	return _write_bundle(note)


func _on_tick_begin() -> void:
	match _mode:
		Mode.RECORDING:
			_tick += 1
			_sample_input()
		Mode.REPLAYING:
			if _player != null:
				_player.begin_tick()


func _physics_process(_delta: float) -> void:
	match _mode:
		Mode.RECORDING:
			_end_recording_tick()
		Mode.REPLAYING:
			if _player != null:
				_player.end_tick()


func _sample_input() -> void:
	var changes := {}
	var taps: Array = []
	for action in _recorded_actions:
		var value := 0.0
		if Input.is_action_pressed(action):
			value = Input.get_action_strength(action)
			if value <= 0.0:
				value = 1.0
		if value != float(_last_sample.get(action, 0.0)):
			changes[action] = value
			_last_sample[action] = value
		elif value == 0.0 and Input.is_action_just_pressed(action):
			taps.append(action)
	_buffer.input.add(_tick, changes, taps)


func _end_recording_tick() -> void:
	if not _pending_texts.is_empty():
		var texts := _pending_texts.duplicate()
		_pending_texts.clear()
		_buffer.input.add(_tick, {}, [], texts)
		for entry: Array in texts:
			text_submitted.emit(entry[0], entry[1])
	if adapter == null:
		return
	_apply_buffer_settings()
	if checkpoint_interval > 0 and _tick % checkpoint_interval == 0:
		var dump: Variant = json_safe(adapter.state_dump()) if dump_history != 0 else null
		_buffer.add_checkpoint(_tick, adapter.state_hash(), dump)
		_buffer.trim(_tick)
	var newest := _buffer.newest_keyframe_tick()
	var overdue := auto_keyframe and newest >= 0 and _tick - newest >= _seconds_to_ticks(buffer_seconds)
	if (_keyframe_requested or overdue) and adapter.is_keyframe_safe():
		_buffer.add_keyframe(_tick, json_safe(adapter.snapshot()), json_safe(adapter.get_seeds()))
		_keyframe_requested = false
		_buffer.trim(_tick)
		keyframe_taken.emit(_tick)
	if _capture_requested:
		_capture_requested = false
		_write_bundle(_capture_note)


func _write_bundle(note: String) -> String:
	if adapter == null:
		push_warning("ReplayRecorder: no adapter set, cannot capture")
		return ""
	_apply_buffer_settings()
	var bundle := _buffer.make_bundle(_tick)
	if bundle == null:
		push_warning("ReplayRecorder: no keyframe yet (is_keyframe_safe() has been false), cannot capture")
		return ""
	bundle.manifest = {
		"format": ReplayBundle.FORMAT,
		"format_version": ReplayBundle.FORMAT_VERSION,
		"game": {"id": _game_id(), "version": current_game_version()},
		"engine": Engine.get_version_info().string,
		"platform": {"os": OS.get_name(), "cpu": OS.get_processor_name(), "renderer": RenderingServer.get_current_rendering_method()},
		"created": Time.get_datetime_string_from_system(false, true),
		"scene": _game_scene_path(),
		"adapter": adapter.adapter_id(),
		"physics_fps": _physics_fps(),
		"start_tick": bundle.manifest["start_tick"],
		"end_tick": _tick,
		"checkpoint_interval": checkpoint_interval,
		"seeds": bundle.manifest["seeds"],
		"actions": Array(_recorded_actions),
		"end_hash": adapter.state_hash(),
		"note": note,
	}
	bundle.state_end = json_safe(adapter.state_dump())
	bundle.screenshot_png = _screenshot()
	bundle.log_text = _log_tail.text() if _log_tail != null else ""
	var base := output_dir.path_join("bug-" + Time.get_datetime_string_from_system().replace(":", "-"))
	var path := base
	var suffix := 2
	while DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(path + ".zip"):
		path = "%s-%d" % [base, suffix]
		suffix += 1
	if zip_bundles:
		path += ".zip"
	var err := bundle.save_zip(path) if zip_bundles else bundle.save(path)
	if err != OK:
		push_error("ReplayRecorder: could not write %s (%s)" % [path, error_string(err)])
		return ""
	print(LOG_PREFIX + "bug report saved: " + ProjectSettings.globalize_path(path))
	bundle_saved.emit(path)
	return path


func _input(event: InputEvent) -> void:
	if _mode != Mode.RECORDING or hotkey == KEY_NONE:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != hotkey:
		return
	get_viewport().set_input_as_handled()
	var path := capture()
	if not path.is_empty() and ask_for_note:
		_open_note_prompt(path)


# --- tester note ---------------------------------------------------------------

## Saves [param note] into the bundle the prompt is open for and resumes play.
## An empty note just closes the prompt.
func submit_note(note: String) -> void:
	if _mode != Mode.NOTE_PROMPT:
		return
	if not note.strip_edges().is_empty():
		var err := ReplayBundle.set_note(_prompt_bundle, note.strip_edges())
		if err != OK:
			push_error("ReplayRecorder: could not save the note (%s)" % error_string(err))
	if is_instance_valid(_prompt_layer):
		_prompt_layer.queue_free()
	_prompt_layer = null
	get_tree().paused = _paused_before_prompt
	_mode = Mode.RECORDING


func is_note_prompt_open() -> bool:
	return _mode == Mode.NOTE_PROMPT


func _open_note_prompt(bundle_path: String) -> void:
	_mode = Mode.NOTE_PROMPT
	_prompt_bundle = bundle_path
	_paused_before_prompt = get_tree().paused
	get_tree().paused = true

	_prompt_layer = CanvasLayer.new()
	_prompt_layer.layer = 128
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	panel.offset_top = 16
	var box := VBoxContainer.new()
	var label := Label.new()
	label.text = "Bug report saved. What went wrong? (Enter saves, Esc skips)"
	var edit := LineEdit.new()
	edit.custom_minimum_size = Vector2(360, 0)
	edit.text_submitted.connect(submit_note)
	edit.gui_input.connect(func(event: InputEvent) -> void:
		if event.is_action_pressed("ui_cancel"):
			submit_note(""))
	box.add_child(label)
	box.add_child(edit)
	panel.add_child(box)
	_prompt_layer.add_child(panel)
	add_child(_prompt_layer)
	edit.grab_focus()


# --- replay ------------------------------------------------------------------

## Replays a bundle (a path or a loaded [ReplayBundle]) into the running game.
## Options: "until" (stop tick), "speed" (power of two; physics runs that many
## times faster with an identical delta). Returns false if it cannot start;
## [member last_result] then holds the error. Otherwise
## [signal replay_finished] reports the outcome.
func start_replay(source: Variant, options := {}) -> bool:
	var bundle: ReplayBundle = source if source is ReplayBundle else ReplayBundle.open(str(source))
	if bundle == null:
		last_result = ReplayResult.error(ReplayBundle.last_error)
		return false
	last_result = ReplayPlayer.check(bundle, adapter, current_game_version())
	if not last_result.ok:
		return false
	_stop_replay()
	_mode = Mode.REPLAYING
	_apply_engine(bundle.physics_fps(), int(options.get("speed", 1)))
	_player = ReplayPlayer.new(bundle, adapter, int(options.get("until", -1)), text_submitted.emit)
	_player.result.warnings = last_result.warnings
	_player.finished.connect(_on_replay_finished, CONNECT_ONE_SHOT)
	return true


func _on_replay_finished(result: ReplayResult) -> void:
	var bundle := _player.bundle
	_player = null
	_mode = Mode.IDLE
	_restore_engine()
	last_result = result
	if _cli_options.has("replay"):
		ReplayCli.complete(self, bundle, result, _cli_options)
	# Deferred so listeners run outside the physics callback and may free the scene.
	replay_finished.emit.call_deferred(result)


func _stop_replay() -> void:
	if _player != null:
		var player := _player
		_player = null
		player.finished.disconnect(_on_replay_finished)
		player.cancel()
		_restore_engine()


func _apply_engine(fps: int, speed: int) -> void:
	# Only powers of two scale the physics delta without rounding differences.
	var factor := 1
	while factor * 2 <= maxi(speed, 1):
		factor *= 2
	if _engine_before.is_empty():
		_engine_before = {"fps": Engine.physics_ticks_per_second, "time_scale": Engine.time_scale}
	Engine.physics_ticks_per_second = fps * factor
	Engine.time_scale = factor


func _restore_engine() -> void:
	if _engine_before.is_empty():
		return
	Engine.physics_ticks_per_second = _engine_before["fps"]
	Engine.time_scale = _engine_before["time_scale"]
	_engine_before = {}


# --- helpers -----------------------------------------------------------------

## The game version recorded in bundles and compared on replay.
func current_game_version() -> String:
	if not game_version.is_empty():
		return game_version
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	var described := _git_describe()
	if described.is_empty():
		return version
	return described if version.is_empty() else "%s (%s)" % [version, described]


## The scene file of the top-level node this recorder lives under.
func _game_scene_path() -> String:
	var node: Node = self
	while node.get_parent() != null and node.get_parent() != get_tree().root:
		node = node.get_parent()
	return node.scene_file_path


func _game_id() -> String:
	return game_id if not game_id.is_empty() else str(ProjectSettings.get_setting("application/config/name", ""))


static var _git_cache: Variant = null

static func _git_describe() -> String:
	if _git_cache == null:
		_git_cache = ""
		if OS.has_feature("editor"):
			var output: Array = []
			var dir := ProjectSettings.globalize_path("res://")
			if OS.execute("git", ["-C", dir, "describe", "--always", "--dirty", "--tags"], output) == 0 and not output.is_empty():
				_git_cache = str(output[0]).strip_edges()
	return _git_cache


func _resolve_actions() -> PackedStringArray:
	if not actions.is_empty():
		return actions
	var names := PackedStringArray()
	for action in InputMap.get_actions():
		if not str(action).begins_with("ui_"):
			names.append(str(action))
	return names


## Exported settings may change at any time; the buffer follows them.
func _apply_buffer_settings() -> void:
	_buffer.min_keyframe_age = _seconds_to_ticks(min_keyframe_age_seconds)
	_buffer.dump_history = dump_history


func _physics_fps() -> int:
	# The delta is invariant under power-of-two speed-ups, unlike the tick rate.
	return roundi(1.0 / get_physics_process_delta_time())


func _seconds_to_ticks(seconds: float) -> int:
	return roundi(seconds * float(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)))


func _screenshot() -> PackedByteArray:
	if DisplayServer.get_name() == "headless":
		return PackedByteArray()
	var texture := get_viewport().get_texture()
	var image := texture.get_image() if texture != null else null
	return image.save_png_to_buffer() if image != null and not image.is_empty() else PackedByteArray()


func _install_log_tail() -> void:
	if _log_tail == null and log_lines > 0:
		_log_tail = ReplayLogTail.new(log_lines)
		OS.add_logger(_log_tail)


func _remove_log_tail() -> void:
	if _log_tail != null:
		OS.remove_logger(_log_tail)
		_log_tail = null


## A deep copy of [param value] exactly as a bundle on disk would give it back.
static func json_safe(value: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(value, "", false, true))
