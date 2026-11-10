# godot-replay (addon)

Playtest replay and bug-report bundles for Godot 4.5+.

- `ReplayRecorder`: add from your debug layer; F12 writes a bundle; `--replay=<bundle>` replays it.
- `ReplayAdapter`: subclass it to snapshot, restore, hash and dump your game state.
- `ReplayTestKit`: replay a bundle from a test.
- `tools/replay.py`: headless replay wrapper that prints only the summary.

Full documentation, determinism rules and the example project:
https://github.com/kirillito/godot-replay
