class_name ReplayBuffer
extends RefCounted
## The recorder's rolling memory: keyframes, input since the oldest kept
## keyframe, checkpoint hashes and state dumps.
##
## A bundle starts from the newest keyframe that is at least
## [member min_keyframe_age] ticks old, so a bug report always includes some
## lead-up; anything older than that keyframe is dropped by [method trim].

## Minimum lead-up, in ticks, between the bundle's keyframe and the capture.
var min_keyframe_age: int
## How many checkpoint state dumps to keep; -1 keeps one per checkpoint.
var dump_history: int

var keyframes: Array[Dictionary] = []   # {"t", "snapshot", "seeds"}
var input := ReplayInputTrack.new()
var checkpoints: Array[Dictionary] = [] # {"t", "h"}
var dumps: Array[Dictionary] = []       # {"t", "s"}


func _init(min_age_ticks := 600, keep_dumps := -1) -> void:
	min_keyframe_age = min_age_ticks
	dump_history = keep_dumps


func add_keyframe(tick: int, snapshot: Dictionary, seeds: Dictionary) -> void:
	keyframes.append({"t": tick, "snapshot": snapshot, "seeds": seeds})


func add_checkpoint(tick: int, state_hash: String, dump: Variant = null) -> void:
	checkpoints.append({"t": tick, "h": state_hash})
	if dump is Dictionary:
		dumps.append({"t": tick, "s": dump})
		if dump_history >= 0:
			while dumps.size() > dump_history:
				dumps.pop_front()


func newest_keyframe_tick() -> int:
	return keyframes[-1]["t"] if not keyframes.is_empty() else -1


## The keyframe a bundle captured at [param end_tick] starts from: the newest
## one at least [member min_keyframe_age] old, else the oldest. Empty if none.
func select_keyframe(end_tick: int) -> Dictionary:
	if keyframes.is_empty():
		return {}
	var chosen: Dictionary = keyframes[0]
	for keyframe in keyframes:
		if end_tick - int(keyframe["t"]) >= min_keyframe_age:
			chosen = keyframe
	return chosen


## Forgets everything a bundle captured at or after [param now] can no longer use.
func trim(now: int) -> void:
	var keyframe := select_keyframe(now)
	if keyframe.is_empty():
		return
	var start: int = keyframe["t"]
	keyframes = keyframes.filter(func(k: Dictionary) -> bool: return k["t"] >= start)
	input = input.sliced(start)
	checkpoints = checkpoints.filter(func(c: Dictionary) -> bool: return c["t"] > start)
	dumps = dumps.filter(func(d: Dictionary) -> bool: return d["t"] > start)


## A bundle covering the selected keyframe up to [param end_tick]; the caller
## fills in the manifest's descriptive fields. Null if there is no keyframe.
func make_bundle(end_tick: int) -> ReplayBundle:
	var keyframe := select_keyframe(end_tick)
	if keyframe.is_empty():
		return null
	var start: int = keyframe["t"]
	var in_range := func(entry: Dictionary) -> bool: return entry["t"] > start and entry["t"] <= end_tick
	var bundle := ReplayBundle.new()
	bundle.manifest["start_tick"] = start
	bundle.manifest["end_tick"] = end_tick
	bundle.manifest["seeds"] = keyframe["seeds"].duplicate(true)
	bundle.keyframe = keyframe["snapshot"].duplicate(true)
	bundle.input = input.sliced(start, end_tick)
	bundle.checkpoints.assign(checkpoints.filter(in_range).map(func(c: Dictionary) -> Dictionary: return c.duplicate()))
	bundle.dumps.assign(dumps.filter(in_range).map(func(d: Dictionary) -> Dictionary: return d.duplicate(true)))
	return bundle
