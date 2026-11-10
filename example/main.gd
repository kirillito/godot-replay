extends Node2D
## Demo entry point. The replay tooling is attached from a debug-only folder
## that release export presets exclude, so nothing here refers to it by class.

const DEBUG_LAYER := "res://example/debug/replay_debug.gd"

@onready var world: DemoWorld = $World


func _ready() -> void:
	# `-- --demo-drift-from=<tick>` switches on the demo's deliberate
	# nondeterminism bug, to show what a replay divergence report looks like.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--demo-drift-from="):
			DemoWorld.debug_unseeded_drift_from_tick = int(arg.get_slice("=", 1))
	world.new_game()
	if OS.is_debug_build() and ResourceLoader.exists(DEBUG_LAYER):
		var debug_layer: Node = load(DEBUG_LAYER).new()
		debug_layer.set("world", world)
		add_child(debug_layer)
