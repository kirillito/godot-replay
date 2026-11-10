# godot-replay

Playtest replay and bug-report bundles for Godot 4.

A tester hits a bug and presses **F12**. The game writes a small folder holding
everything needed to replay the last couple of minutes: a starting snapshot,
the input for every physics tick, RNG seeds, versions, a screenshot, the log
tail and the tester's note. A developer or a coding agent then replays it
headless, inspects the state at any tick, fixes the bug, and keeps the bundle as
a regression test.

```
$ python addons/godot_replay/tools/replay.py bug_reports/bug-2026-11-09T14-03-22
REPLAY DIVERGED at tick 1500 (checkpoint 14 of 24)
  state hash: recorded 79a238bf3592cec3, replay 91d0082f7b86397e
  player.position: recorded (172.76, 45.04), replay (172.61, 45.04)
  first input after previous checkpoint: t=1500 move_left 0.0, move_up 0.0, interact tap
```

- **One key, one bundle.** Debug builds only; plain JSON/JSONL files. The
  example's 12-second bundle is 23 KB; size grows mostly with your
  `state_dump()` and the number of checkpoints.
- **Headless, deterministic replay** with checkpoint hashes. When a replay stops
  matching the recording, you get the tick and a field-level diff.
- **Inspect at a tick:** `--until`, `--dump-state`, `--capture`.
- **Bundle → test:** `--make-test` writes a gdUnit4 test that replays the bundle.
- **Agent-friendly output:** a few lines of text, failures only; images only on request.

Requires Godot 4.5 or newer (developed on 4.7). The example project shows every
piece wired up.

## How it works

The recorder samples your **InputMap actions** (not raw keys) at the start of
every physics tick and stores only the changes. The game provides a
`ReplayAdapter` that can snapshot, restore and hash its state. A replay restores
a keyframe and then injects the recorded actions on the same ticks as
`InputEventAction`s. Polling code (`Input.is_action_pressed`,
`is_action_just_pressed`, `get_vector`) and event code (`_unhandled_input` with
`event.is_action_pressed(...)`) both see them. Every 30 ticks the replay
compares a state hash with the recording and stops at the first mismatch.

Nothing in the addon is game-specific except the adapter you write.

## Install

1. Copy `addons/godot_replay/` into your project. You don't need to enable the
   plugin; the classes are global.
2. Write an adapter (below) and add a `ReplayRecorder` from a debug-only part of
   your game.
3. Exclude the addon and your debug folder from release export presets:
   *Export → Resources → Filters to exclude files*:
   `addons/godot_replay/*, debug/*`. The recorder also frees itself in non-debug
   builds.

## Integrating with a game

### 1. Write a `ReplayAdapter`

```gdscript
class_name MyReplayAdapter
extends ReplayAdapter

var game: MyGame

func _init(target: MyGame) -> void:
	game = target

func adapter_id() -> String:
	return "my-game"

func snapshot() -> Dictionary:            # a keyframe; reuse your save model
	return game.save_state()

func restore(data: Dictionary) -> void:   # load it, ready for the next tick
	game.load_state(data)

func state_dump() -> Dictionary:          # readable state for diffs and tests
	return game.debug_dump()

func get_seeds() -> Dictionary:           # every gameplay RNG
	return {"world": {"seed": str(game.rng.seed), "state": str(game.rng.state)}}

func set_seeds(seeds: Dictionary) -> void:
	game.rng.seed = int(seeds["world"]["seed"])
	game.rng.state = int(seeds["world"]["state"])

func is_keyframe_safe() -> bool:          # e.g. false mid-cutscene
	return not game.in_cutscene
```

- If your game already saves state, reuse that model for `snapshot()`/`restore()`.
  If it has a debug state dump, reuse it for `state_dump()`.
- All dictionaries must be JSON-safe. Numbers come back as floats, and 64-bit
  integers such as RNG seeds and states must be stored as strings.
- `state_hash()` defaults to a hash of `state_dump()`. Override it if dumps are
  expensive; it runs every checkpoint.

### 2. Add the recorder in debug builds

```gdscript
# res://debug/replay_debug.gd, loaded by path only in debug builds:
#   if OS.is_debug_build() and ResourceLoader.exists(PATH): add_child(load(PATH).new())
extends Node

func _ready() -> void:
	var recorder := ReplayRecorder.new()
	recorder.adapter = MyReplayAdapter.new(get_parent())
	add_child(recorder)
	Autosave.saved.connect(recorder.keyframe)   # autosaves make good keyframes
```

Load the debug layer **by path**, not by class name, so release builds that
exclude it still compile. See [example/main.gd](example/main.gd) and
[example/debug/](example/debug/).

Recorder settings (exported properties):

| Property | Default | |
|---|---|---|
| `hotkey` | `KEY_F12` | writes a bundle |
| `buffer_seconds` | 120 | input kept once a newer keyframe exists |
| `min_keyframe_age_seconds` | 10 | lead-up kept before the bug: a bundle starts at the newest keyframe at least this old |
| `auto_keyframe` | true | take a keyframe when the newest is older than the buffer (only while `is_keyframe_safe()`) |
| `checkpoint_interval` | 30 | ticks between state hashes |
| `dump_history` | -1 | state dumps kept at checkpoints for divergence diffs (-1 = all in the buffer, 0 = none) |
| `output_dir` | `user://bug_reports` | |
| `ask_for_note` | true | pause and ask the tester what went wrong |
| `zip_bundles` | false | write `.zip` instead of folders |
| `actions` | all non-`ui_*` | actions to record; list `ui_*` ones explicitly if gameplay uses them |
| `log_lines` | 200 | engine log lines kept for `log.txt` (0 = off) |
| `game_id` | project name | recorded in the manifest |
| `game_version` | `git describe` / project version | recorded and compared on replay |

Call `recorder.keyframe()` whenever the game reaches a clean state (an autosave,
a room transition). Keyframes are event-driven, not periodic, so large states
stay cheap.

### 3. Follow the determinism rules

A replay is only as good as the game's determinism. The addon can't enforce it,
but it detects and reports any loss of it. Adopt these rules before writing
gameplay systems; retrofitting determinism is the expensive path.

- **Advance gameplay in `_physics_process`**, never in `_process` with a variable
  delta. Replays run with `--fixed-fps <physics fps>`.
- **Draw all gameplay randomness from seeded RNGs** the adapter exposes.
  Cosmetic RNG (particles, weather) may stay unseeded only if it never touches
  gameplay state. Global `randf()`/`randi()` in gameplay is a replay-breaking bug.
- **Don't read the wall clock in gameplay** (`Time.get_ticks_msec()`,
  `Time.get_unix_time_from_system()`, …). Count ticks instead.
- **Tweens and AnimationPlayers that drive gameplay state use physics process mode.**
- **Text reveal, dialogue timing and input-gating UI are tick-based** (or skipped
  the same way every time).
- **Keep gameplay physics priorities below `ReplayRecorder.END_OF_TICK_PRIORITY`.**
  The recorder runs last in each tick.
- **Read input through InputMap actions.** Replays deliver `InputEventAction`s,
  so `event is InputEventKey` checks and mouse position don't replay.
- **Route typed text through the recorder.** Call
  `recorder.submit_text(channel, text)` and apply text in a handler for
  `recorder.text_submitted`, which fires at the end of the tick both live and in
  replays.

Physics (`CharacterBody2D.move_and_slide` and friends) has replayed exactly on
the same build and machine in every test so far. Cross-machine replays are best
effort: float differences between CPUs are possible and haven't been measured
yet. The divergence report tells you when it happens.

## Replaying bundles

The wrapper runs Godot headless with the right `--fixed-fps` and prints only the
replay summary (plus script errors, if any):

```
python addons/godot_replay/tools/replay.py <bundle> [options]
  --until=<tick>          stop after this tick
  --dump-state            print state_dump() as JSON at the stop tick
  --capture=<png>         save the viewport at the stop tick (runs windowed)
  --make-test=<path.gd>   write a gdUnit4 test that replays the bundle
  --assert=<a.b,c>        with --make-test: assert these final-state fields
  --project=<dir>         default: nearest project.godot above the cwd
  --godot=<exe>           default: $GODOT, then `godot` on PATH
  --timeout=<seconds>     give up after this long (default 600)
  --verbose               show all engine output
```

Exit codes: **0** every checkpoint and the end state matched, **1** diverged,
**2** error (unreadable bundle, wrong adapter, newer format).

Without the wrapper, pass the same options after `--`:

```
godot --headless --path . --fixed-fps 60 -- --replay=/abs/path/to/bundle --until=1500 --dump-state
```

The bundle records the game version, engine version and platform. Replaying
under a different version prints a warning but still runs. A bundle from a
different adapter is refused.

## Bundles as regression tests

```
python addons/godot_replay/tools/replay.py bug_reports/bug-… \
    --make-test=res://tests/replays/test_door_softlock.gd --assert=player.position,room
```

This replays the bundle and checks that it matches. It then copies the bundle
next to the test (`res://tests/replays/bug-…/`) and writes a gdUnit4 suite that
replays it in the scene it was recorded in. The suite fails on divergence and
asserts the named fields of the final `state_dump()`. Without `--assert`, it
lists the final state in a TODO comment so you can pick the fields that prove
the fix.

The generated test uses `ReplayTestKit.replay(scene, bundle_path, speed := 4)`.
It runs physics 4× faster with a bit-identical delta (only powers of two are
exact) by raising `Engine.physics_ticks_per_second` and `Engine.time_scale`
together, since a test can't pass `--fixed-fps`. gdUnit4 measures test
timeouts in that scaled time, so a long replay may need a `timeout` argument on
its test. You can call `ReplayTestKit` from any test framework.

See [tests/replays/test_demo_walk.gd](tests/replays/test_demo_walk.gd) for a
generated example.

## Bundle format (v1)

```
bug-2026-11-09T14-03-22/
  manifest.json      format version, game id + version, engine, platform, scene, adapter id,
                     physics fps, start/end tick, checkpoint interval, seeds, actions, end hash, note
  keyframe.json      adapter snapshot at the start tick
  input.jsonl        one line per tick where input changed
  checkpoints.jsonl  {"t": 1230, "h": "9f1c…"} every K ticks
  dumps.jsonl        {"t": 1230, "s": {…}} state dumps at checkpoints, for diffs
  state_end.json     state dump at the end tick
  screenshot.png     viewport when the bundle was saved (absent in headless runs)
  log.txt            the last ~200 lines of the engine log
```

Input lines record changes only. Playback starts with every action released.

```json
{"t": 1234, "a": {"move_right": 1, "move_up": 0}, "tap": ["interact"], "x": [["name", "Ada"]]}
```

`a` holds strengths (0 = released), `tap` holds actions pressed and released
within one tick, and `x` holds text entries as `[channel, text]`. Ticks are
physics frames counted by the recorder. The keyframe, checkpoints and end state
are all taken at the *end* of their tick.

## Limitations

- Debug and development builds only; no release, network or cross-version replays.
- Mouse position and raw key/joypad events are not recorded. Text entry is
  recorded only through `submit_text()`.
- Controls that react to raw key events rather than actions won't respond during
  a replay.
- Real input still held when a replay starts (a key pressed during a windowed
  or in-process replay) mixes with the replayed input; the replay report warns
  about it.
- Cross-machine determinism is unmeasured (see above).

Prior art: [SReplay](https://dresswithpockets.github.io/2025/09/27/godot-replay.html)
replaces `Input` with a recording shim the game must call. godot-replay works
with the stock `Input` API and adds bundles, divergence detection and test
generation.

## Developing godot-replay

This repository is the example project. The addon lives in
`addons/godot_replay/`; `example/` is a two-room top-down demo, and `tests/`
holds the gdUnit4 suites.

```
python tools/install_gdunit4.py          # gdUnit4 6.2.3 into addons/gdUnit4 (not vendored)
GODOT=/path/to/godot python tools/run_tests.py
```

Run the demo (F12 saves a bundle, E toggles the lamp). Start it with
`-- --demo-drift-from=<tick>` to turn on a deliberate nondeterminism bug and see
a divergence report. `tests/support/record_demo_bundle.gd` records a scripted walk
without a keyboard.

## License

MIT, see [LICENSE](LICENSE).
