import sys, bpy
from mathutils import Vector, Matrix
from roblox_animations.rig.creation import create_rig
import roblox_animations.rig.rebuild_keep as rk
import os; mode = os.environ.get("RB_MODE", "plain")
def sample():
    s = bpy.context.scene; s.frame_set(20)
    dg = bpy.context.evaluated_depsgraph_get(); out = {}
    for n in ("Crossbow body", "LeftArm"):
        o = bpy.data.objects[n].evaluated_get(dg)
        vs = [o.matrix_world @ v.co for v in o.data.vertices]; out[n] = sum(vs, Vector())/len(vs)
    return out
arm = bpy.data.objects["__VM4_Armature"]
print("OLD ARM WORLD z", round(arm.matrix_world.translation.z, 3))
before = sample()
if mode == "plain":
    create_rig("LOCAL_YAXIS_EXTEND", "__VM4Meta")
    new = [o for o in bpy.data.objects if o.type == "ARMATURE"][0]
    new.animation_data_create(); new.animation_data.action = bpy.data.actions["reload"]
else:
    src = open(rk.__file__).read()
    rk.rebuild_keep_user_bones("LOCAL_YAXIS_EXTEND", "__VM4Meta")
    new = [o for o in bpy.data.objects if o.type == "ARMATURE"][0]
print("MODE", mode, "NEW ARM WORLD z", round(new.matrix_world.translation.z, 3))
after = sample()
for n in before: print("DELTA", mode, n, round((after[n]-before[n]).length, 4))
