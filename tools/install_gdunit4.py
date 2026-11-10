"""Install gdUnit4 into addons/gdUnit4 for running this repository's tests.

Usage: python tools/install_gdunit4.py [version]
"""

import io
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

VERSION = sys.argv[1] if len(sys.argv) > 1 else "6.2.3"
URL = f"https://github.com/godot-gdunit-labs/gdUnit4/archive/refs/tags/v{VERSION}.zip"
ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "addons" / "gdUnit4"


def main() -> int:
    print(f"Downloading gdUnit4 v{VERSION} ...")
    with urllib.request.urlopen(URL) as response:
        data = response.read()
    prefix = f"gdUnit4-{VERSION}/addons/gdUnit4/"
    if DEST.exists():
        shutil.rmtree(DEST)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for name in archive.namelist():
            if not name.startswith(prefix) or name.endswith("/"):
                continue
            target = DEST / name[len(prefix):]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(name))
    print(f"Installed into {DEST.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
