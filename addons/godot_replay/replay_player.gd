class_name ReplayPlayer
extends RefCounted
## Replays a bundle into the running game, one physics tick at a time.
##
## Timing contract (shared with the recorder):
## - Input for tick t is injected at the end of tick t-1, as InputEventActions
##   flushed immediately. Godot then reports is_action_just_pressed() on tick t,
##   exactly as for a key pressed between frames.
## - Keyframes, checkpoints and the end state are taken at the end of their tick,
##   after gameplay has run.
##
## The ReplayRecorder drives this object: [method begin_tick] when a physics
## tick starts, [method end_tick] after every gameplay node has processed it.

signal finished(result: ReplayResult)

enum Phase { PRIME_INPUT, RESTORE, RUNNING, DONE }

var bundle: ReplayBundle
var adapter: ReplayAdapter
## The current tick, in the bundle's numbering. Valid once restored.
var tick := -1
var result := ReplayResult.new()

var _phase := Phase.PRIME_INPUT
var _stop_tick: int
var _lines := {}        # tick -> input line
var _checkpoints := {}  # tick -> hash
var _checkpoint_ticks: Array[int] = []
var _actions: PackedStringArray
var _deliver_text: Callable


## [param until]: stop after this tick (-1 = the bundle's end tick).
## [param deliver_text]: called as (channel, text) for recorded text entries.
func _init(source: ReplayBundle, game_adapter: ReplayAdapter, until := -1, deliver_text := Callable()) -> void:
	bundle = source
	adapter = game_adapter
	_deliver_text = deliver_text
	_stop_tick = bundle.end_tick() if until < 0 else mini(until, bundle.end_tick())
	_actions = PackedStringArray(bundle.manifest.get("actions", []))
	for line in bundle.input.lines:
		_lines[int(line["t"])] = line
	for checkpoint in bundle.checkpoints:
		_checkpoints[int(checkpoint["t"])] = checkpoint["h"]
		_checkpoint_ticks.append(int(checkpoint["t"]))
	result.start_tick = bundle.start_tick()
	result.end_tick = bundle.end_tick()
	result.checkpoints_total = bundle.checkpoints.size()


## Problems that make [param source] unreplayable with [param game_adapter]
## (returned as an ERROR result), or warnings worth showing (an OK result).
static func check(source: ReplayBundle, game_adapter: ReplayAdapter, current_game_version: String) -> ReplayResult:
	var manifest := source.manifest
	if manifest.get("format", "") != ReplayBundle.FORMAT:
		return ReplayResult.error("%s is not a godot-replay bundle" % source.path)
	if int(manifest.get("format_version", 0)) > ReplayBundle.FORMAT_VERSION:
		return ReplayResult.error("bundle format v%d is newer than this addon (v%d)" % [
			int(manifest["format_version"]), ReplayBundle.FORMAT_VERSION])
	if game_adapter == null:
		return ReplayResult.error("the ReplayRecorder has no adapter")
	if manifest.get("adapter", "") != game_adapter.adapter_id():
		return ReplayResult.error("bundle was recorded with adapter '%s', this game uses '%s'" % [
			manifest.get("adapter", ""), game_adapter.adapter_id()])
	var checked := ReplayResult.new()
	var engine := Engine.get_version_info().string as String
	if manifest.get("engine", engine) != engine:
		checked.warnings.append("recorded with Godot %s, replaying on %s" % [manifest["engine"], engine])
	var game: Dictionary = manifest.get("game", {})
	if game.get("version", current_game_version) != current_game_version:
		checked.warnings.append("recorded with game version %s, replaying on %s" % [game["version"], current_game_version])
	for action in manifest.get("actions", []):
		if not InputMap.has_action(action):
			checked.warnings.append("recorded action '%s' is not in the InputMap; its input is skipped" % action)
	return checked


func is_running() -> bool:
	return _phase != Phase.DONE


func begin_tick() -> void:
	if _phase == Phase.RUNNING:
		tick += 1


func end_tick() -> void:
	match _phase:
		Phase.PRIME_INPUT:
			# Hold what was held at the keyframe. The just_pressed edge this
			# causes lands on the next tick, whose effects the restore overwrites.
			_release_all()
			_warn_about_held_devices()
			_inject(bundle.input.state_at(bundle.start_tick()), [])
			_phase = Phase.RESTORE
		Phase.RESTORE:
			adapter.restore(bundle.keyframe)
			adapter.set_seeds(bundle.manifest.get("seeds", {}))
			tick = bundle.start_tick()
			_phase = Phase.RUNNING
			_after_tick()
		Phase.RUNNING:
			_after_tick()


## Stops a running replay early and releases every replayed action.
func cancel(reason := "cancelled") -> void:
	if _phase == Phase.DONE:
		return
	result.status = ReplayResult.Status.ERROR
	result.report = PackedStringArray(["REPLAY ERROR: " + reason])
	_finish()


func _after_tick() -> void:
	var line: Dictionary = _lines.get(tick, {})
	if tick > bundle.start_tick() and _deliver_text.is_valid():
		for entry: Array in line.get("x", []):
			_deliver_text.call(entry[0], entry[1])

	if tick > bundle.start_tick() and _checkpoints.has(tick):
		var expected: String = _checkpoints[tick]
		var actual := adapter.state_hash()
		if actual != expected:
			_diverged(expected, actual, "checkpoint %d of %d" % [result.checkpoints_matched + 1, result.checkpoints_total])
			return
		result.checkpoints_matched += 1

	if tick >= _stop_tick:
		_reached_stop()
		return

	var next: Dictionary = _lines.get(tick + 1, {})
	if not next.is_empty():
		_inject(next.get("a", {}), next.get("tap", []))


func _reached_stop() -> void:
	result.tick = tick
	if tick >= bundle.end_tick():
		var expected: String = bundle.manifest.get("end_hash", "")
		var actual := adapter.state_hash()
		if not expected.is_empty() and actual != expected:
			_diverged(expected, actual, "end of recording")
			return
		result.report.append("REPLAY OK: ticks %d..%d, %d/%d checkpoints matched, end state matches" % [
			bundle.start_tick(), tick, result.checkpoints_matched, result.checkpoints_total])
	else:
		result.report.append("REPLAY STOPPED at tick %d (--until), %d checkpoints matched so far" % [
			tick, result.checkpoints_matched])
	_finish()


func _diverged(expected: String, actual: String, where: String) -> void:
	result.status = ReplayResult.Status.DIVERGED
	result.tick = tick
	result.report.append("REPLAY DIVERGED at tick %d (%s)" % [tick, where])
	result.report.append("  state hash: recorded %s, replay %s" % [expected, actual])
	var recorded := bundle.dump_at(tick)
	if recorded.is_empty():
		result.report.append("  (no recorded state dump at this tick; raise the recorder's dump_history)")
	else:
		var diff := ReplayDiff.lines(recorded, _normalized_dump())
		if diff.is_empty():
			result.report.append("  (state dumps match; the difference is in state that state_hash() covers but state_dump() omits)")
		for line in diff:
			result.report.append("  " + line)
	result.report.append("  " + _first_input_since_previous_checkpoint())
	_finish()


func _first_input_since_previous_checkpoint() -> String:
	var previous := bundle.start_tick()
	for checkpoint_tick in _checkpoint_ticks:
		if checkpoint_tick < tick:
			previous = maxi(previous, checkpoint_tick)
	var since := "previous checkpoint" if previous > bundle.start_tick() else "keyframe"
	for line in bundle.input.lines_between(previous, tick):
		if line.has("a") or line.has("tap"):
			return "first input after %s: %s" % [since, describe_line(line)]
	return "no input between the %s (t=%d) and this tick" % [since, previous]


## "t=1812 move_down 1.0, interact tap"
static func describe_line(line: Dictionary) -> String:
	var parts := PackedStringArray()
	var changes: Dictionary = line.get("a", {})
	for action: String in changes:
		parts.append("%s %s" % [action, str(float(changes[action]))])
	for action: String in line.get("tap", []):
		parts.append("%s tap" % action)
	return "t=%d %s" % [int(line["t"]), ", ".join(parts)]


func _finish() -> void:
	_phase = Phase.DONE
	_release_all()
	result.final_state = _normalized_dump()
	finished.emit(result)


func _normalized_dump() -> Dictionary:
	var dump: Variant = ReplayRecorder.json_safe(adapter.state_dump())
	return dump if dump is Dictionary else {}


func _release_all() -> void:
	var any := false
	for action in _actions:
		if InputMap.has_action(action) and Input.is_action_pressed(action):
			_send(action, 0.0)
			any = true
	if any:
		Input.flush_buffered_events()


## Input state is tracked per source: an InputEventAction release does not
## release a real key (or button, or stick) that is still held. Such input
## would leak into the replay, so say so.
func _warn_about_held_devices() -> void:
	for action in _actions:
		if InputMap.has_action(action) and Input.is_action_pressed(action):
			result.warnings.append("'%s' is held by a real input device; replayed input may be wrong" % action)


func _inject(changes: Dictionary, taps: Array) -> void:
	if changes.is_empty() and taps.is_empty():
		return
	for action: String in changes:
		_send(action, float(changes[action]))
	for action: String in taps:
		_send(action, 1.0)
		_send(action, 0.0)
	Input.flush_buffered_events()


static func _send(action: String, strength: float) -> void:
	if not InputMap.has_action(action):
		return
	var event := InputEventAction.new()
	event.action = action
	event.pressed = strength > 0.0
	event.strength = strength
	Input.parse_input_event(event)
