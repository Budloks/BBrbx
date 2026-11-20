"""Register the fork's add-on straight from this repo inside a background Blender.

Usage (from the repo root):
  blender -b --factory-startup [file.blend] --python tools/bb/blender_bootstrap.py -- <script.py|unittest:module> ...

--factory-startup keeps the user's installed RBXMonkey out of the way.
"""
import os
import sys
import importlib
import runpy
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if REPO not in sys.path:
    sys.path.insert(0, REPO)

import roblox_animations  # noqa: E402

roblox_animations.register()

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
exit_code = 0
for arg in args:
    if arg.startswith("unittest:"):
        module = importlib.import_module("roblox_animations.tests." + arg.split(":", 1)[1])
        suite = unittest.defaultTestLoader.loadTestsFromModule(module)
        result = unittest.TextTestRunner(verbosity=1).run(suite)
        if not result.wasSuccessful():
            exit_code = 1
    else:
        runpy.run_path(arg, run_name="__main__")
sys.stdout.flush()
if exit_code:
    os._exit(exit_code)
