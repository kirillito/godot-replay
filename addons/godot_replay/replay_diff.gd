class_name ReplayDiff
extends RefCounted
## Field-level differences between two state dumps, as short readable lines.


## Lines like "player.position: recorded (212, 188), replay (212, 189)".
static func lines(recorded: Dictionary, replayed: Dictionary, max_lines := 12) -> PackedStringArray:
	var left := flatten(recorded)
	var right := flatten(replayed)
	var keys: Array = left.keys()
	for key: String in right:
		if not left.has(key):
			keys.append(key)
	var out := PackedStringArray()
	var skipped := 0
	for key: String in keys:
		var a: Variant = left.get(key, null)
		var b: Variant = right.get(key, null)
		if a == b:
			continue
		if out.size() >= max_lines:
			skipped += 1
			continue
		var shown_a := format_value(a, b)
		var shown_b := format_value(b, a)
		out.append("%s: recorded %s, replay %s" % [key, shown_a, shown_b])
	if skipped > 0:
		out.append("... and %d more differing fields" % skipped)
	return out


## Flattens nested dictionaries (and non-vector arrays) into "a.b.0" paths.
## Short arrays of numbers are kept whole: they are usually vectors.
static func flatten(value: Variant, prefix := "") -> Dictionary:
	var out := {}
	if value is Dictionary:
		for key: Variant in value:
			out.merge(flatten(value[key], _join(prefix, str(key))))
	elif value is Array and not _is_vector(value):
		for i in (value as Array).size():
			out.merge(flatten(value[i], _join(prefix, str(i))))
	else:
		out[prefix] = value
	return out


## Reads a dotted path ("player.position", "items.0.id") from nested data.
static func field(value: Variant, path: String) -> Variant:
	var current: Variant = value
	for part in path.split(".", false):
		if current is Dictionary and (current as Dictionary).has(part):
			current = current[part]
		elif current is Array and part.is_valid_int() and int(part) < (current as Array).size():
			current = current[int(part)]
		else:
			return null
	return current


## Shows numbers compactly; adds precision when [param other] would print the same.
static func format_value(value: Variant, other: Variant = null) -> String:
	if value == null:
		return "(missing)"
	for decimals in [2, 6, 17]:
		var text := _format(value, decimals)
		if other == null or value == other or text != _format(other, decimals):
			return text
	return _format(value, 17)


static func _format(value: Variant, decimals: int) -> String:
	if value is float:
		var number: float = value
		if is_equal_approx(number, roundf(number)) and decimals < 17:
			return str(int(roundf(number)))
		return String.num(number, decimals)
	if value is Array and _is_vector(value):
		var parts := PackedStringArray()
		for item: Variant in value:
			parts.append(_format(item, decimals))
		return "(" + ", ".join(parts) + ")"
	if value is String:
		return JSON.stringify(value)
	return str(value)


static func _is_vector(value: Array) -> bool:
	if value.size() < 2 or value.size() > 4:
		return false
	for item: Variant in value:
		if not (item is float or item is int):
			return false
	return true


static func _join(prefix: String, key: String) -> String:
	return key if prefix.is_empty() else prefix + "." + key
