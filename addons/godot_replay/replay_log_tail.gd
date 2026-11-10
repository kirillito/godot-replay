class_name ReplayLogTail
extends Logger
## Keeps the last lines the engine logged, for bug-report bundles.
## Engine loggers may be called from any thread, hence the mutex.

var max_lines: int
var _lines := PackedStringArray()
var _mutex := Mutex.new()


func _init(keep := 200) -> void:
	max_lines = keep


func _log_message(message: String, error: bool) -> void:
	_append(("[stderr] " if error else "") + message.trim_suffix("\n"))


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	var kind := "WARNING" if error_type == ERROR_TYPE_WARNING else "ERROR"
	var message := rationale if not rationale.is_empty() else code
	_append("%s: %s\n   at: %s (%s:%d)" % [kind, message, function, file, line])


func text() -> String:
	_mutex.lock()
	var joined := "\n".join(_lines)
	_mutex.unlock()
	return joined + "\n" if not joined.is_empty() else ""


func _append(message: String) -> void:
	_mutex.lock()
	for part in message.split("\n"):
		_lines.append(part)
	if _lines.size() > max_lines:
		_lines = _lines.slice(_lines.size() - max_lines)
	_mutex.unlock()
