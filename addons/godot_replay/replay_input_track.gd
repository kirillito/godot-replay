class_name ReplayInputTrack
extends RefCounted
## Recorded input indexed by tick, stored as changes only.
##
## One line per tick where something changed:
## [codeblock]
## {"t": 1234, "a": {"move_right": 1.0}, "tap": ["interact"], "x": [["sign", "hello"]]}
## [/codeblock]
## [code]a[/code]: actions whose strength changed (0 = released; absent =
## unchanged). [code]tap[/code]: actions pressed and released within the tick.
## [code]x[/code]: text entries as [channel, text]. Playback starts with every
## action released.

var lines: Array[Dictionary] = []


func add(tick: int, changes: Dictionary, taps: Array = [], texts: Array = []) -> void:
	if changes.is_empty() and taps.is_empty() and texts.is_empty():
		return
	var line: Dictionary
	if not lines.is_empty() and lines[-1]["t"] == tick:
		line = lines[-1]
	else:
		line = {"t": tick}
		lines.append(line)
	if not changes.is_empty():
		(line.get_or_add("a", {}) as Dictionary).merge(changes, true)
	if not taps.is_empty():
		(line.get_or_add("tap", []) as Array).append_array(taps)
	if not texts.is_empty():
		(line.get_or_add("x", []) as Array).append_array(texts)


## Actions held at the end of [param tick], as {action: strength}.
func state_at(tick: int) -> Dictionary:
	var held := {}
	for line in lines:
		if line["t"] > tick:
			break
		var changes: Dictionary = line.get("a", {})
		for action: String in changes:
			if float(changes[action]) > 0.0:
				held[action] = changes[action]
			else:
				held.erase(action)
	return held


## Lines with [param after] < t <= [param until].
func lines_between(after: int, until: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for line in lines:
		var t: int = line["t"]
		if t > until:
			break
		if t > after:
			result.append(line)
	return result


## A copy that starts at [param start]: input held then becomes a single line
## at [param start], earlier lines are dropped, and lines after [param until]
## (when >= 0) are cut.
func sliced(start: int, until := -1) -> ReplayInputTrack:
	var track := ReplayInputTrack.new()
	track.add(start, state_at(start))
	for line in lines:
		var t: int = line["t"]
		if until >= 0 and t > until:
			break
		if t > start:
			track.lines.append(line.duplicate(true))
	return track


func to_jsonl() -> String:
	return ReplayBundle.to_jsonl(lines)


static func from_jsonl(text: String) -> ReplayInputTrack:
	var track := ReplayInputTrack.new()
	for raw in text.split("\n", false):
		var parsed: Variant = JSON.parse_string(raw)
		if parsed is Dictionary:
			var line: Dictionary = parsed
			line["t"] = int(line["t"])
			track.lines.append(line)
	return track
