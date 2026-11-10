#!/usr/bin/env python3
"""Replay a godot-replay bundle headless and print only the replay summary.

Usage:
  python replay.py <bundle> [--until N] [--dump-state] [--capture out.png]
                            [--make-test res://tests/replays/test_x.gd [--assert a.b,c]]
                            [--project DIR] [--godot EXE] [--timeout SECONDS] [--verbose]

Exit code: 0 replay matched, 1 diverged, 2 error (as reported by the game).
Godot is found via --godot, then the GODOT environment variable, then `godot` on PATH.
"""

import argparse
import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path

PREFIX = "[replay] "


def find_project(start: Path) -> Path | None:
    for directory in [start, *start.parents]:
        if (directory / "project.godot").is_file():
            return directory
    return None


def read_manifest(bundle: Path) -> dict:
    if bundle.suffix == ".zip":
        with zipfile.ZipFile(bundle) as archive:
            for name in archive.namelist():
                if name.rsplit("/", 1)[-1] == "manifest.json":
                    return json.loads(archive.read(name))
        raise FileNotFoundError(f"{bundle} holds no manifest.json")
    return json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("bundle")
    parser.add_argument("--until", type=int)
    parser.add_argument("--dump-state", action="store_true")
    parser.add_argument("--capture")
    parser.add_argument("--make-test")
    parser.add_argument("--assert", dest="assert_fields")
    parser.add_argument("--project")
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--verbose", action="store_true", help="print all engine output")
    args = parser.parse_args()

    bundle = Path(args.bundle).resolve()
    project = Path(args.project).resolve() if args.project else find_project(Path.cwd())
    if project is None:
        print("REPLAY ERROR: no project.godot here or above; pass --project")
        return 2
    try:
        manifest = read_manifest(bundle)
    except (OSError, ValueError, KeyError) as error:
        print(f"REPLAY ERROR: cannot read the bundle: {error}")
        return 2

    fps = int(manifest.get("physics_fps", 60))
    command = [args.godot]
    if not args.capture:
        command.append("--headless")
    command += ["--path", str(project), "--fixed-fps", str(fps), "--", f"--replay={bundle.as_posix()}"]
    if args.until is not None:
        command.append(f"--until={args.until}")
    if args.dump_state:
        command.append("--dump-state")
    if args.capture:
        command.append(f"--capture={Path(args.capture).resolve().as_posix()}")
    if args.make_test:
        test = args.make_test
        if not test.startswith("res://"):
            test = Path(test).resolve().as_posix()
        command.append(f"--make-test={test}")
    if args.assert_fields:
        command.append(f"--assert={args.assert_fields}")

    try:
        completed = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                                   errors="replace", timeout=args.timeout, check=False)
    except FileNotFoundError:
        print(f"REPLAY ERROR: cannot run Godot at '{args.godot}'; pass --godot or set GODOT")
        return 2
    except subprocess.TimeoutExpired:
        print(f"REPLAY ERROR: no result after {args.timeout:.0f} s. Is a ReplayRecorder added in "
              "debug builds, and does the game reach it with --replay?")
        return 2

    output = completed.stdout + completed.stderr
    if args.verbose:
        print(output, end="")
        return completed.returncode

    lines = output.splitlines()
    summary = [line[len(PREFIX):] for line in lines if line.startswith(PREFIX)]
    # Script errors matter to whoever is debugging; keep them with their location line.
    errors = []
    for i, line in enumerate(lines):
        if line.startswith(("SCRIPT ERROR", "ERROR:")) and "Remote Debugger" not in line:
            errors.append(line)
            if i + 1 < len(lines) and lines[i + 1].strip().startswith("at:"):
                errors.append(lines[i + 1])
    for line in summary:
        print(line)
    if errors:
        print(f"engine errors ({len(errors)} lines, first shown):")
        for line in errors[:10]:
            print("  " + line)
    if not summary:
        print(f"REPLAY ERROR: the game printed no replay result (exit {completed.returncode}); rerun with --verbose")
        return 2
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main())
