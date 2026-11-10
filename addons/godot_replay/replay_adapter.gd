class_name ReplayAdapter
extends RefCounted
## The only game-specific part of godot-replay: subclass it to let the recorder
## snapshot, restore, hash and dump your game's state.
##
## All dictionaries must be JSON-safe (strings, numbers, bools, arrays,
## dictionaries). Data you hand over is normalized through JSON, so
## [method restore] and [method set_seeds] always receive what a bundle on disk
## would give them: numbers come back as floats, and 64-bit integers such as RNG
## seeds must be stored as strings.


## A short id for the adapter; bundles from another adapter are refused.
func adapter_id() -> String:
	return "default"


## A keyframe: everything needed to put the game back into this exact state.
func snapshot() -> Dictionary:
	push_error("ReplayAdapter.snapshot() is not implemented")
	return {}


## Loads a keyframe so the game is ready to run the next physics tick.
func restore(_snapshot: Dictionary) -> void:
	push_error("ReplayAdapter.restore() is not implemented")


## A cheap fingerprint of the gameplay state, compared at every checkpoint.
## The default hashes [method state_dump]; override it if dumps are expensive.
func state_hash() -> String:
	return hash_state(state_dump())


## Readable gameplay state used for divergence diffs, --dump-state and tests.
func state_dump() -> Dictionary:
	return {}


## Seeds and states of every RNG gameplay draws from.
func get_seeds() -> Dictionary:
	return {}


func set_seeds(_seeds: Dictionary) -> void:
	pass


## False while a keyframe would be incomplete or unsafe to restore, such as
## mid-cutscene. Requested keyframes wait until this returns true.
func is_keyframe_safe() -> bool:
	return true


## A short hex hash of any Variant, exact to the bit.
static func hash_state(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_MD5)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode().left(16)
