import bpy
from mathutils import Vector
from roblox_animations.rig.rebuild_keep import rebuild_keep_user_bones

def sample():
    s = bpy.context.scene
    s.frame_set(20)
    dg = bpy.context.evaluated_depsgraph_get()
    out = {}
    for n in ("Crossbow body", "Crossbow strings", "Crossbow bolt", "LeftArm"):
        o = bpy.data.objects[n].evaluated_get(dg)
        vs = [o.matrix_world @ v.co for v in o.data.vertices]
        out[n] = sum(vs, Vector()) / len(vs)
    return out

arm = bpy.data.objects["__VM4_Armature"]
act = arm.animation_data.action.name
before = sample()
res = rebuild_keep_user_bones("LOCAL_YAXIS_EXTEND", "__VM4Meta")
new = bpy.data.objects[res["armature"]]
print("KEPT", res["kept_bones"])
print("ARMATURE", new.name, "action", new.animation_data.action.name if new.animation_data and new.animation_data.action else None, "(was", act + ")")
print("LIMB CONS", [c.name for c in new.pose.bones["Limb.L.1"].constraints], "LeftArm cons", [(c.type, c.subtarget, c.target.name if c.target else None) for c in new.pose.bones["LeftArm"].constraints])
after = sample()
for n in before:
    print("DELTA", n, round((after[n] - before[n]).length, 5))
print("OLD LEFT", [o.name for o in bpy.data.objects if o.name.endswith("__bb_old")])
