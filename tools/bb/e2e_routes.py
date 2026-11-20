import json, zlib
import bpy
from roblox_animations.server import bb_routes
from roblox_animations.rig import rest_contract

arm = bb_routes.resolve_armature("__VM4_Armature")
before_action = arm.animation_data.action.name if arm.animation_data and arm.animation_data.action else None
before_range = (bpy.context.scene.frame_start, bpy.context.scene.frame_end)
acts = bb_routes.list_actions(arm)
print("ACTIONS", [(a["name"], a["frame_start"], a["frame_end"]) for a in acts["actions"]], "skipped", acts["skipped"])
for a in acts["actions"]:
    data = json.loads(zlib.decompress(bb_routes.export_action(arm, a["name"])).decode())
    print("EXPORT", a["name"], "kfs", len(data["kfs"]), "channels", sorted({k for kf in data["kfs"] for k in kf["kf"]})[:6], "...")
after_action = arm.animation_data.action.name if arm.animation_data and arm.animation_data.action else None
print("STATE RESTORED", before_action == after_action, before_range == (bpy.context.scene.frame_start, bpy.context.scene.frame_end))
layout = rest_contract.rig_layout(arm)
for c in layout["channels"]:
    print("LAYOUT", c["name"], "<-", c["parent"], c["kind"], "skinned" if c["skinned"] else "", "stamped" if c["stamped"] else "NEW", "REST CHANGED" if c["rest_changed"] else "")
print("WARN", layout["warnings"])
print("CHECK", bb_routes.rig_check(arm))
