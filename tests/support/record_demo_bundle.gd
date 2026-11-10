extends SceneTree
## Records the demo driven by the scripted walk and writes a bundle.
## godot --headless --fixed-fps 60 --path . -s res://tests/support/record_demo_bundle.gd -- <out_dir> [ticks] [note] [lead_up_seconds]

const DemoBot := preload("res://tests/support/demo_bot.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out_dir := args[0] if args.size() > 0 else "user://bug_reports"
	var ticks := int(args[1]) if args.size() > 1 else 1800
	var note := args[2] if args.size() > 2 else ""
	var lead_up := float(args[3]) if args.size() > 3 else 10.0
	var scene: Node = (load("res://example/main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	var recorder := ReplayRecorder.find_under(scene)
	recorder.output_dir = out_dir
	recorder.ask_for_note = false
	recorder.min_keyframe_age_seconds = lead_up
	scene.add_child(DemoBot.new(recorder, DemoBot.walk_plan()))
	while recorder.tick < ticks:
		await process_frame
	recorder.capture(note)
	quit(0)
