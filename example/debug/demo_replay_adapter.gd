class_name DemoReplayAdapter
extends ReplayAdapter
## Connects the demo's save model to godot-replay.

var world: DemoWorld


func _init(target: DemoWorld) -> void:
	world = target


func adapter_id() -> String:
	return "godot-replay-demo"


func snapshot() -> Dictionary:
	return world.save_state()


func restore(snapshot_data: Dictionary) -> void:
	world.load_state(snapshot_data)


func state_dump() -> Dictionary:
	# The demo's save state is small and readable, so it doubles as the dump.
	return world.save_state()


func get_seeds() -> Dictionary:
	# 64-bit integers do not survive JSON numbers, so store them as strings.
	return {"world": {"seed": str(world.rng.seed), "state": str(world.rng.state)}}


func set_seeds(seeds: Dictionary) -> void:
	var entry: Dictionary = seeds["world"]
	world.rng.seed = int(entry["seed"])
	world.rng.state = int(entry["state"])
