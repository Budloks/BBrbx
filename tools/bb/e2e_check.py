import json, zlib
import bpy
from roblox_animations.server import bb_routes
arm = bb_routes.resolve_armature("__VM4_Armature")
data = json.loads(zlib.decompress(bb_routes.export_action(arm, "shoot")).decode())
chk = data.get("bb_check")
print("CHECK root", chk["root"], "rest", len(chk["rest"]), "frames", [(f["frame"], round(f["t"], 3), len(f["joints"]), len(f["poses"])) for f in chk["frames"]])
print("CHANNELS", sorted(chk["rest"].keys()))
