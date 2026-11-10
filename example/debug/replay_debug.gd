extends Node
## Debug-only layer: adds the ReplayRecorder and wires the demo into it.
## Exclude res://example/debug/* and res://addons/godot_replay/* from release
## export presets.

var world: DemoWorld
var recorder: ReplayRecorder


func _ready() -> void:
	recorder = ReplayRecorder.new()
	recorder.adapter = DemoReplayAdapter.new(world)
	add_child(recorder)
	# An autosave is a natural keyframe.
	world.autosaved.connect(func(_room: String) -> void: recorder.keyframe())
	# Typed text reaches the game through the recorder so replays can deliver it.
	recorder.text_submitted.connect(world.set_sign_text)
