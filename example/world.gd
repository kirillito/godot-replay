class_name DemoWorld
extends Node2D
## A tiny top-down demo: two rooms joined by a doorway, a lamp the player can
## toggle, and a wanderer that walks to random spots picked by a seeded RNG.
##
## Gameplay follows the godot-replay determinism rules: it advances only in
## _physics_process, takes all gameplay randomness from [member rng], and never
## reads the wall clock.

## Emitted when the player enters another room; the demo treats this as an
## autosave, which makes it a natural replay keyframe.
signal autosaved(room: String)

const ROOM_SIZE := Vector2(320, 240)
const WALL := 8.0
const DOOR_TOP := 96.0
const DOOR_BOTTOM := 144.0
const PLAYER_SIZE := 14.0
const PLAYER_SPEED := 120.0
const PLAYER_START := Vector2(80, 120)
const WANDERER_SPEED := 40.0
const WANDERER_START := Vector2(480, 120)
const BUMP_DISTANCE := 14.0
const BUMP_RESPAWN := Vector2(344, 120)
const LAMP_POSITION := Vector2(160, 48)
const LAMP_REACH := 40.0

## Debug switch for the determinism demo and tests. From this world tick on,
## the player drifts by an unseeded randf(): the classic replay-breaking bug.
## -1 disables it.
static var debug_unseeded_drift_from_tick := -1

## Gameplay RNG. Its seed and state are exposed to the replay adapter.
var rng := RandomNumberGenerator.new()

var tick := 0
var room := "left"
var lamp_on := false
var bumps := 0
var sign_text := ""
var wanderer_target := WANDERER_START

var player: CharacterBody2D
var wanderer: Node2D
var _lamp_light: Polygon2D
var _hud: Label


func _ready() -> void:
	_build_rooms()
	_build_actors()
	_build_hud()


## Starts a new game with a fresh random seed.
func new_game() -> void:
	rng.randomize()
	tick = 0
	room = "left"
	lamp_on = false
	bumps = 0
	sign_text = ""
	player.position = PLAYER_START
	player.velocity = Vector2.ZERO
	wanderer.position = WANDERER_START
	wanderer_target = _pick_wanderer_target()
	_update_visuals()


## Called with text the player typed for the signpost.
func set_sign_text(_channel: String, text: String) -> void:
	sign_text = text


func _physics_process(delta: float) -> void:
	tick += 1
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	player.velocity = direction * PLAYER_SPEED
	player.move_and_slide()
	if debug_unseeded_drift_from_tick >= 0 and tick >= debug_unseeded_drift_from_tick:
		player.position.x += randf() - 0.5

	if Input.is_action_just_pressed("interact") and player.position.distance_to(LAMP_POSITION) < LAMP_REACH:
		lamp_on = not lamp_on

	_move_wanderer(delta)
	if room == "right" and player.position.distance_to(wanderer.position) < BUMP_DISTANCE:
		bumps += 1
		player.position = BUMP_RESPAWN

	var current_room := "left" if player.position.x < ROOM_SIZE.x else "right"
	if current_room != room:
		room = current_room
		autosaved.emit(room)
	_update_visuals()


func _move_wanderer(delta: float) -> void:
	var to_target := wanderer_target - wanderer.position
	var step := WANDERER_SPEED * delta
	if to_target.length() <= step:
		wanderer.position = wanderer_target
		wanderer_target = _pick_wanderer_target()
	else:
		wanderer.position += to_target.normalized() * step


func _pick_wanderer_target() -> Vector2:
	return Vector2(
		rng.randf_range(ROOM_SIZE.x + 24.0, 2.0 * ROOM_SIZE.x - 24.0),
		rng.randf_range(24.0, ROOM_SIZE.y - 24.0)
	)


## The whole gameplay state as JSON-safe data (used for saves and replays).
func save_state() -> Dictionary:
	return {
		"tick": tick,
		"room": room,
		"lamp_on": lamp_on,
		"bumps": bumps,
		"sign": sign_text,
		"player": {
			"position": [player.position.x, player.position.y],
			"velocity": [player.velocity.x, player.velocity.y],
		},
		"wanderer": {
			"position": [wanderer.position.x, wanderer.position.y],
			"target": [wanderer_target.x, wanderer_target.y],
		},
	}


func load_state(state: Dictionary) -> void:
	tick = int(state["tick"])
	room = state["room"]
	lamp_on = state["lamp_on"]
	bumps = int(state["bumps"])
	sign_text = state["sign"]
	player.position = _vec(state["player"]["position"])
	player.velocity = _vec(state["player"]["velocity"])
	wanderer.position = _vec(state["wanderer"]["position"])
	wanderer_target = _vec(state["wanderer"]["target"])
	_update_visuals()


static func _vec(pair: Array) -> Vector2:
	return Vector2(pair[0], pair[1])


func _update_visuals() -> void:
	_lamp_light.color = Color(1.0, 0.85, 0.3) if lamp_on else Color(0.3, 0.3, 0.35)
	_hud.text = "Room: %s   Lamp: %s   Bumps: %d   [WASD] move  [E] lamp  [F12] bug report" % [
		room, "on" if lamp_on else "off", bumps
	]


func _build_rooms() -> void:
	var floors := [
		[Rect2(Vector2.ZERO, ROOM_SIZE), Color(0.16, 0.18, 0.22)],
		[Rect2(Vector2(ROOM_SIZE.x, 0), ROOM_SIZE), Color(0.14, 0.2, 0.17)],
	]
	for entry: Array in floors:
		_add_rect_visual(entry[0], entry[1])

	var width := 2.0 * ROOM_SIZE.x
	var height := ROOM_SIZE.y
	var mid := ROOM_SIZE.x
	var walls: Array[Rect2] = [
		Rect2(0, 0, width, WALL),
		Rect2(0, height - WALL, width, WALL),
		Rect2(0, 0, WALL, height),
		Rect2(width - WALL, 0, WALL, height),
		Rect2(mid - WALL / 2.0, 0, WALL, DOOR_TOP),
		Rect2(mid - WALL / 2.0, DOOR_BOTTOM, WALL, height - DOOR_BOTTOM),
	]
	for rect in walls:
		var body := StaticBody2D.new()
		var shape := CollisionShape2D.new()
		var box := RectangleShape2D.new()
		box.size = rect.size
		shape.shape = box
		shape.position = rect.get_center()
		body.add_child(shape)
		add_child(body)
		_add_rect_visual(rect, Color(0.45, 0.42, 0.4))


func _build_actors() -> void:
	_lamp_light = _add_rect_visual(Rect2(LAMP_POSITION - Vector2(8, 8), Vector2(16, 16)), Color.GRAY)

	player = CharacterBody2D.new()
	player.name = "Player"
	player.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	var shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = Vector2(PLAYER_SIZE, PLAYER_SIZE)
	shape.shape = box
	player.add_child(shape)
	player.add_child(_square(PLAYER_SIZE, Color(0.35, 0.6, 1.0)))
	add_child(player)

	wanderer = Node2D.new()
	wanderer.name = "Wanderer"
	wanderer.add_child(_square(12.0, Color(0.95, 0.4, 0.35)))
	add_child(wanderer)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	_hud = Label.new()
	_hud.position = Vector2(10, 10)
	_hud.add_theme_font_size_override("font_size", 10)
	layer.add_child(_hud)
	add_child(layer)


func _add_rect_visual(rect: Rect2, color: Color) -> Polygon2D:
	var polygon := Polygon2D.new()
	polygon.polygon = PackedVector2Array([
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	])
	polygon.color = color
	add_child(polygon)
	return polygon


func _square(size: float, color: Color) -> Polygon2D:
	var half := size / 2.0
	var polygon := Polygon2D.new()
	polygon.polygon = PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)
	])
	polygon.color = color
	return polygon
