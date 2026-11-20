import bpy, os, tempfile
from roblox_animations.rig.deform_export import export_deform_fbx
from roblox_animations.rig import rest_contract
ao = bpy.data.objects["__VM5_Armature"]
res = export_deform_fbx(ao, os.path.join(tempfile.gettempdir(), "bb_bow.fbx"))
print("BOW FBX", len(res["bones"]), res["roots"], "unweighted", res["unweighted_vertices"])
lay = {c["name"]: c for c in rest_contract.rig_layout(ao)["channels"]}
for n in ("Main", "arrow", "string", "Bone.003", "LeftArm", "HumanoidRootPart"):
    c = lay.get(n); print("LAYOUT", n, c and c["parent"], c and c["kind"], c and ("skinned" if c["skinned"] else ""), c and ("stamped" if c["stamped"] else "NEW"))
print("HELPERS EXPORTED?", [n for n in ("topik", "toplimit", "LeftArm.001") if n in lay])
