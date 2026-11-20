"""E2E: limb bones of the VM4 crossbow export exactly once Studio's rest is adopted,
independent of the Blender bone roll. Run via blender_bootstrap.py on crossbow_rigged.blend."""
import math
import bpy
from mathutils import Matrix
from roblox_animations.core.constants import get_transform_to_blender
from roblox_animations.core.utils import mat_to_cf, cf_to_mat, to_matrix
from roblox_animations.animation.serialization import serialize
from roblox_animations.rig import rest_contract

ao = bpy.data.objects["__VM4_Armature"]
t2b = get_transform_to_blender()
LIMBS = [f"Limb.{s}.{i}" for s in "LR" for i in range(1, 5)]
root = ao.data.bones["HumanoidRootPart"]
rootT = to_matrix(root["transform"])

# What Studio really has: Bone frames equal to the Blender bone frames at FBX
# export time (original roll). Snapshot them before touching anything.
studio_frames = {"HumanoidRootPart": {"kind": "Root", "part": mat_to_cf(Matrix())}}
for name in LIMBS:
    b = ao.data.bones[name]
    J = t2b.inverted() @ b.matrix_local
    if ao.get("limb_roll_fixed"):
        # This file already had its limb roll flipped; Studio keeps the FBX-time frame
        J = J @ Matrix.Rotation(math.pi, 4, "Y")
    studio_frames[name] = {"kind": "Bone", "parent": b.parent.name, "part": mat_to_cf(rootT.inverted() @ J)}
tbr = {"root": "HumanoidRootPart", "frames": studio_frames, "bones": {}}

def limb_rot_at_end():
    ao.animation_data.action = bpy.data.actions["shoot"]
    s = bpy.context.scene
    s.frame_start, s.frame_end = 0, 30
    data = serialize(ao, target_bone_rest=tbr)
    last = max(data["kfs"], key=lambda k: k["t"])
    out = {}
    for n in ("Limb.L.1", "Limb.L.3", "Limb.R.1"):
        entry = last["kf"].get(n)
        comps = entry[0] if isinstance(entry, list) and isinstance(entry[0], list) else (entry.get("components") if isinstance(entry, dict) else entry)
        m = cf_to_mat(comps)
        e = m.to_3x3().to_euler("ZYX")
        out[n] = round(math.degrees(e.z), 2)
    return out

bpy.context.view_layer.objects.active = ao
bpy.ops.object.mode_set(mode="POSE")
print("BEFORE ADOPT (old guess):", limb_rot_at_end())
adopted = rest_contract.adopt_from_target_rest(ao, tbr)
print("ADOPTED:", adopted)
print("AFTER ADOPT:", limb_rot_at_end())

# Now flip the roll like fix_crossbow_limb_roll.py does; the Studio truth is unchanged.
bpy.ops.object.mode_set(mode="EDIT")
for n in LIMBS:
    ao.data.edit_bones[n].roll += math.pi
bpy.ops.object.mode_set(mode="POSE")
for n in LIMBS:
    for c in ao.pose.bones[n].constraints:
        if c.type == "TRANSFORM":
            c.to_min_z_rot, c.to_max_z_rot = -c.to_min_z_rot, -c.to_max_z_rot
rest_contract.adopt_from_target_rest(ao, tbr)
print("AFTER ROLL FLIP + ADOPT:", limb_rot_at_end())
