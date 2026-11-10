extends Node
## Plays a scripted input plan into the demo.
##
## Action mode injects InputEventActions at the end of the tick before the
## planned one, landing exactly on the planned tick (analog strengths work).
## Keyboard mode sends the actions' InputEventKeys from _process and lets the
## engine flush them before the next physics tick, exactly like a tester's
## keyboard; with several ticks per frame they land a few ticks late.

## Tick -> {action: strength}; strength 0 releases, the string "tap" presses
## and releases within the tick.
var plan: Dictionary = {}
var recorder: ReplayRecorder
var use_keyboard := false
var _next_key_tick := 1


func _init(target: ReplayRecorder, input_plan: Dictionary, keyboard := false) -> void:
	recorder = target
	plan = input_plan
	use_keyboard = keyboard
	process_mode = Node.PROCESS_MODE_ALWAYS
	# After gameplay, before the recorder's end-of-tick work.
	process_physics_priority = ReplayRecorder.END_OF_TICK_PRIORITY - 1


func _exit_tree() -> void:
	# Leave no key held for whatever runs next.
	if use_keyboard:
		for action: String in ["move_left", "move_right", "move_up", "move_down", "interact"]:
			_send_key(action, false)
		Input.flush_buffered_events()


func _process(_delta: float) -> void:
	if not use_keyboard:
		return
	while _next_key_tick <= recorder.tick + 1:
		var changes: Dictionary = plan.get(_next_key_tick, {})
		_next_key_tick += 1
		for action: String in changes:
			var value: Variant = changes[action]
			if value is String and value == "tap":
				_send_key(action, true)
				_send_key(action, false)
			else:
				_send_key(action, float(value) > 0.0)


func _physics_process(_delta: float) -> void:
	if use_keyboard:
		return
	var next_tick := recorder.tick + 1
	if not plan.has(next_tick):
		return
	var changes: Dictionary = plan[next_tick]
	for action: String in changes:
		var value: Variant = changes[action]
		if value is String and value == "tap":
			_send(action, true, 1.0)
			_send(action, false, 0.0)
		else:
			_send(action, float(value) > 0.0, float(value))
	Input.flush_buffered_events()


static func _send_key(action: String, pressed: bool) -> void:
	for mapped in InputMap.action_get_events(action):
		if mapped is InputEventKey:
			var event := InputEventKey.new()
			event.physical_keycode = (mapped as InputEventKey).physical_keycode
			event.pressed = pressed
			Input.parse_input_event(event)
			return


static func _send(action: String, pressed: bool, strength: float) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	event.strength = strength
	Input.parse_input_event(event)


## A 30 s walk: to the lamp, toggle it, through the doorway, around the
## wanderer's room with analog input, and back.
static func walk_plan() -> Dictionary:
	return {
		2: {"move_right": 1.0},
		37: {"move_right": 0.0, "move_up": 1.0},
		67: {"move_up": 0.0},
		70: {"interact": "tap"},
		80: {"move_down": 1.0},
		110: {"move_down": 0.0, "move_right": 1.0},
		250: {"move_down": 0.5},
		330: {"move_down": 0.0, "move_right": 0.0, "move_up": 0.7, "move_left": 0.4},
		500: {"move_up": 0.0, "move_left": 0.0},
		520: {"move_right": 1.0},
		600: {"move_right": 0.0, "move_down": 1.0},
		680: {"move_down": 0.0, "move_left": 1.0},
		760: {"move_left": 0.0, "move_up": 1.0},
		820: {"move_up": 0.0},
		900: {"move_down": 0.8, "move_right": 0.8},
		1000: {"move_down": 0.0, "move_right": 0.0, "move_left": 1.0, "move_up": 0.3},
		1150: {"move_up": 0.0},
		1260: {"move_left": 0.0, "move_down": 1.0},
		1300: {"move_down": 0.0, "move_right": 1.0},
		1420: {"move_right": 0.0, "move_up": 1.0, "move_left": 0.6},
		1500: {"move_up": 0.0, "move_left": 0.0, "interact": "tap"},
		1560: {"move_right": 1.0},
		1700: {"move_right": 0.0, "move_down": 1.0},
		1760: {"move_down": 0.0},
	}
