import bpy, os, tempfile
from roblox_animations.rig.deform_export import export_deform_fbx
from roblox_animations.rig import rest_contract
from roblox_animations.server.bb_routes import list_actions
print("OPS", hasattr(bpy.ops.rbxbb, "export_deform"), "PANEL", hasattr(bpy.types, "RBXBB_PT_panel"), "ACTIONPROP", hasattr(bpy.types.Action, "rbx_bb_priority"))
ao = bpy.data.objects["__VM4_Armature"]
out = os.path.join(tempfile.gettempdir(), "bb_test_deform.fbx")
res = export_deform_fbx(ao, out)
print("FBX", os.path.getsize(out) > 1000, res["mesh"], res["bones"], res["roots"], "unweighted", res["unweighted_vertices"])
print("LEFTOVERS", [o.name for o in bpy.data.objects if o.name.startswith("__bb_deform") or o.name.endswith("_Deform")])
lay = {c["name"]: c for c in rest_contract.rig_layout(ao)["channels"]}
print("LAYOUT body parent", lay["Crossbow body"]["parent"], "limb parent", lay["Limb.L.1"]["parent"])
a = bpy.data.actions["shoot"]; a.rbx_bb_priority = "Action2"; a.rbx_bb_loop = "ON"; a.rbx_bb_name = "CrossbowShoot"
print("SETTINGS", [x["settings"] for x in list_actions(ao)["actions"] if x["name"] == "shoot"])
