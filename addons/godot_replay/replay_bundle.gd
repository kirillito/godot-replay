class_name ReplayBundle
extends RefCounted
## A bug-report bundle: a folder (or .zip) of plain-text files that replays the
## recorded stretch of play.
##
## [codeblock]
## manifest.json      versions, ticks, seeds, recorded actions, tester note
## keyframe.json      adapter snapshot at the start tick
## input.jsonl        input changes per tick (see ReplayInputTrack)
## checkpoints.jsonl  {"t": tick, "h": state hash} every K ticks
## dumps.jsonl        {"t": tick, "s": state dump} at checkpoints, for diffs
## state_end.json     state dump at the end tick
## screenshot.png     viewport at capture time (absent in headless runs)
## log.txt            tail of the engine log
## [/codeblock]

const FORMAT := "godot-replay"
const FORMAT_VERSION := 1

## The last error from [method open], for callers that get null back.
static var last_error := ""

var manifest: Dictionary = {}
var keyframe: Dictionary = {}
var input := ReplayInputTrack.new()
var checkpoints: Array[Dictionary] = []
var dumps: Array[Dictionary] = []
var state_end: Dictionary = {}
var screenshot_png := PackedByteArray()
var log_text := ""
## Where the bundle was loaded from or last saved to.
var path := ""


func start_tick() -> int:
	return int(manifest.get("start_tick", 0))


func end_tick() -> int:
	return int(manifest.get("end_tick", 0))


func physics_fps() -> int:
	return int(manifest.get("physics_fps", 60))


## The bundle's name: its folder name, or the zip's file name without extension.
func bundle_name() -> String:
	var file := path.trim_suffix("/").get_file()
	return file.get_basename() if file.ends_with(".zip") else file


## The recorded state dump at [param tick], or an empty dictionary.
func dump_at(tick: int) -> Dictionary:
	if tick == end_tick() and not state_end.is_empty():
		return state_end
	for dump in dumps:
		if dump["t"] == tick:
			return dump["s"]
	return {}


func to_files() -> Dictionary:
	var files := {
		"manifest.json": _json(manifest, "  ").to_utf8_buffer(),
		"keyframe.json": _json(keyframe, "  ").to_utf8_buffer(),
		"input.jsonl": input.to_jsonl().to_utf8_buffer(),
		"checkpoints.jsonl": to_jsonl(checkpoints).to_utf8_buffer(),
		"dumps.jsonl": to_jsonl(dumps).to_utf8_buffer(),
		"state_end.json": _json(state_end, "  ").to_utf8_buffer(),
		"log.txt": log_text.to_utf8_buffer(),
	}
	if not screenshot_png.is_empty():
		files["screenshot.png"] = screenshot_png
	return files


## Writes the bundle as a folder.
func save(dir_path: String) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(dir_path)
	if err != OK:
		return err
	var files := to_files()
	for file_name: String in files:
		var file := FileAccess.open(dir_path.path_join(file_name), FileAccess.WRITE)
		if file == null:
			return FileAccess.get_open_error()
		file.store_buffer(files[file_name])
		file.close()
	path = dir_path
	return OK


## Writes the bundle as a .zip holding a folder named after the zip.
func save_zip(zip_path: String) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(zip_path.get_base_dir())
	if err != OK:
		return err
	var packer := ZIPPacker.new()
	err = packer.open(zip_path)
	if err != OK:
		return err
	var folder := zip_path.get_file().get_basename()
	var files := to_files()
	for file_name: String in files:
		packer.start_file(folder + "/" + file_name)
		packer.write_file(files[file_name])
		packer.close_file()
	packer.close()
	path = zip_path
	return OK


## Writes the bundle back where it came from, in the same form.
func save_in_place() -> Error:
	return save_zip(path) if path.ends_with(".zip") else save(path)


## Loads a bundle folder or .zip. Returns null and sets [member last_error] on failure.
static func open(bundle_path: String) -> ReplayBundle:
	last_error = ""
	var files := _read_zip(bundle_path) if bundle_path.ends_with(".zip") else _read_dir(bundle_path)
	if files.is_empty():
		last_error = "cannot read bundle at %s" % bundle_path
		return null
	if not files.has("manifest.json") or not files.has("keyframe.json"):
		last_error = "%s is not a replay bundle (manifest.json or keyframe.json missing)" % bundle_path
		return null
	var bundle := ReplayBundle.new()
	bundle.path = bundle_path
	var manifest_data: Variant = JSON.parse_string(_text(files, "manifest.json"))
	var keyframe_data: Variant = JSON.parse_string(_text(files, "keyframe.json"))
	if not manifest_data is Dictionary or not keyframe_data is Dictionary:
		last_error = "%s has an unreadable manifest.json or keyframe.json" % bundle_path
		return null
	bundle.manifest = manifest_data
	bundle.keyframe = keyframe_data
	bundle.input = ReplayInputTrack.from_jsonl(_text(files, "input.jsonl"))
	bundle.checkpoints = _parse_jsonl(_text(files, "checkpoints.jsonl"))
	bundle.dumps = _parse_jsonl(_text(files, "dumps.jsonl"))
	var end_data: Variant = JSON.parse_string(_text(files, "state_end.json"))
	bundle.state_end = end_data if end_data is Dictionary else {}
	bundle.log_text = _text(files, "log.txt")
	bundle.screenshot_png = files.get("screenshot.png", PackedByteArray())
	return bundle


## Rewrites the tester note of the bundle at [param bundle_path].
static func set_note(bundle_path: String, note: String) -> Error:
	var bundle := open(bundle_path)
	if bundle == null:
		return ERR_FILE_CANT_READ
	bundle.manifest["note"] = note
	return bundle.save_in_place()


static func _read_dir(dir_path: String) -> Dictionary:
	var files := {}
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return files
	for file_name in dir.get_files():
		files[file_name] = FileAccess.get_file_as_bytes(dir_path.path_join(file_name))
	return files


static func _read_zip(zip_path: String) -> Dictionary:
	var files := {}
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return files
	for entry in reader.get_files():
		if not entry.ends_with("/"):
			# Accept files at the root or inside one top-level folder.
			files[entry.get_file()] = reader.read_file(entry)
	reader.close()
	return files


static func _text(files: Dictionary, file_name: String) -> String:
	var bytes: PackedByteArray = files.get(file_name, PackedByteArray())
	return bytes.get_string_from_utf8()


static func _parse_jsonl(text: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw in text.split("\n", false):
		var parsed: Variant = JSON.parse_string(raw)
		if parsed is Dictionary:
			var entry: Dictionary = parsed
			entry["t"] = int(entry["t"])
			result.append(entry)
	return result


## JSON text for bundle files: floats keep full precision, and whole numbers
## are written as integers (JSON parsing turns every number into a float, so
## re-saved bundles would otherwise read "start_tick": 1095.0).
static func to_json(value: Variant, indent := "") -> String:
	return JSON.stringify(_ints_where_whole(value), indent, false, true)


## One JSON object per line.
static func to_jsonl(entries: Array[Dictionary]) -> String:
	var out := PackedStringArray()
	for entry in entries:
		out.append(to_json(entry))
	return "\n".join(out) + ("\n" if not out.is_empty() else "")


static func _ints_where_whole(value: Variant) -> Variant:
	if value is float and value == floorf(value) and absf(value) < 9007199254740992.0:
		return int(value)
	if value is Dictionary:
		var copy := {}
		for key: Variant in value:
			copy[key] = _ints_where_whole(value[key])
		return copy
	if value is Array:
		return (value as Array).map(_ints_where_whole)
	return value


static func _json(value: Variant, indent := "") -> String:
	return to_json(value, indent) + "\n"
