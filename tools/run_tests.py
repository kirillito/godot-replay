"""Run this repository's gdUnit4 tests headless.

Usage: python tools/run_tests.py [res://tests/path ...]
Set GODOT (or GODOT_BIN) to the Godot 4 executable. Install gdUnit4 first with
tools/install_gdunit4.py.
"""

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    godot = os.environ.get("GODOT") or os.environ.get("GODOT_BIN") or "godot"
    targets = sys.argv[1:] or ["res://tests"]
    # Import once so class_name scripts and resources are registered.
    subprocess.run([godot, "--headless", "--path", str(ROOT), "--import"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    args = [godot, "--headless", "--path", str(ROOT), "-s", "-d",
            "--remote-debug", "tcp://127.0.0.1:0",
            "res://addons/gdUnit4/bin/GdUnitCmdTool.gd", "--ignoreHeadlessMode"]
    for target in targets:
        args += ["-a", target]
    return subprocess.run(args, cwd=ROOT, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
