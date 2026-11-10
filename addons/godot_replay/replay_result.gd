class_name ReplayResult
extends RefCounted
## The outcome of a replay, with a short text report meant for people and agents.

enum Status { OK, DIVERGED, ERROR }

var status := Status.OK
## OK, and every checkpoint (and the end state, for a full replay) matched.
var ok: bool:
	get:
		return status == Status.OK
## The tick the replay stopped at: the end tick, --until, or the divergence.
var tick := -1
var start_tick := -1
var end_tick := -1
var checkpoints_matched := 0
var checkpoints_total := 0
## Report lines: a headline first, then details. No trailing summary noise.
var report := PackedStringArray()
var warnings := PackedStringArray()
## The adapter's state_dump() at the stop tick, normalized through JSON.
var final_state: Dictionary = {}


static func error(message: String) -> ReplayResult:
	var result := ReplayResult.new()
	result.status = Status.ERROR
	result.report.append("REPLAY ERROR: " + message)
	return result


## Warnings followed by the report, one line each.
func text() -> String:
	var lines := PackedStringArray()
	for warning in warnings:
		lines.append("WARNING: " + warning)
	lines.append_array(report)
	return "\n".join(lines)


## The process exit code for command-line replays: 0 ok, 1 diverged, 2 error.
func exit_code() -> int:
	match status:
		Status.OK:
			return 0
		Status.DIVERGED:
			return 1
	return 2
