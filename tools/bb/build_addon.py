"""Build the Blender extension zip (manifest at the zip root, no tests/caches).
Usage: python tools/bb/build_addon.py  ->  build/rbxmonkey_bb_<version>.zip"""
import os
import re
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "roblox_animations")
SKIP_DIRS = {"tests", "__pycache__", ".ruff_cache", ".pytest_cache", ".mypy_cache", "native"}

manifest = open(os.path.join(SRC, "blender_manifest.toml"), encoding="utf-8").read()
version = re.search(r'^version\s*=\s*"([^"]+)"', manifest, re.M).group(1)
os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
out = os.path.join(ROOT, "build", f"rbxmonkey_bb_{version}.zip")
count = 0
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        for name in filenames:
            if name.endswith((".pyc", ".pyo")):
                continue
            full = os.path.join(dirpath, name)
            z.write(full, os.path.relpath(full, SRC))
            count += 1
print(f"{out} ({count} files)")
