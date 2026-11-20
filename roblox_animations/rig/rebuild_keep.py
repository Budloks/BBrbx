# pyright: reportAttributeAccessIssue=false, reportOptionalMemberAccess=false
"""
BB fork: rebuild a Roblox rig from its metadata WITHOUT losing your work.

``create_rig`` deletes the armature and rebuilds it purely from the Roblox
metadata, which throws away every bone you added in Blender (limb chains, IK and
control bones), their weights' targets, constraints and the assigned action.
This wrapper keeps all of that:

1. the old armature is set aside (not deleted) so ``create_rig`` builds fresh,
2. bones that are not part of the Roblox metadata are recreated on the new
   armature with the same rest, parent and custom props,
3. constraints of every bone that exists in both are copied over,
4. the action, armature modifiers, object/bone constraint targets and driver
   targets are moved from the old armature to the new one,
5. the old armature is removed.
"""

from typing import Dict, List

import bpy

from . import rest_contract
from .creation import create_rig, find_master_collection_for_object


def _is_user_bone(data_bone) -> bool:
    """Bones that the Roblox metadata will NOT recreate."""
    if not rest_contract.is_stamped(data_bone):
        return True
    if data_bone.get(rest_contract.ADOPTED_PROP):
        return True  # stamped by BB (Push Rig / adoption), not by the importer
    return rest_contract.is_copied_duplicate(data_bone)


def _snapshot_user_bones(arm_obj) -> List[Dict]:
    bones = []
    for b in arm_obj.data.bones:  # parents come before children in this order
        if not _is_user_bone(b):
            continue
        bones.append(
            {
                "name": b.name,
                "parent": b.parent.name if b.parent else None,
                "head": b.head_local.copy(),
                "tail": b.tail_local.copy(),
                "matrix": b.matrix_local.copy(),
                "use_deform": b.use_deform,
                "use_connect": b.use_connect,
                "props": {k: b[k] for k in b.keys() if not k.startswith("_")},
            }
        )
    return bones


def _set_aside(old, master):
    """Hide the old armature from create_rig's candidate search."""
    for coll in list(old.users_collection):
        coll.objects.unlink(old)
    bpy.context.scene.collection.objects.link(old)
    old["_bb_rebuild_source"] = old.get("rbx_rig_meta_name", "")
    if "rbx_rig_meta_name" in old:
        del old["rbx_rig_meta_name"]
    old.name = old.name + "__bb_old"
    old.data.name = old.data.name + "__bb_old"


def _find_new_armature(master, old):
    for obj in master.all_objects:
        if obj.type == "ARMATURE" and obj.name != old.name:
            return obj
    return None


def _recreate_user_bones(new, snapshot):
    if not snapshot:
        return
    bpy.context.view_layer.objects.active = new
    bpy.ops.object.mode_set(mode="EDIT")
    eb = new.data.edit_bones
    try:
        for entry in snapshot:
            if entry["name"] in eb:
                continue
            bone = eb.new(entry["name"])
            bone.head = entry["head"]
            bone.tail = entry["tail"]
            bone.matrix = entry["matrix"]
            bone.use_deform = entry["use_deform"]
        for entry in snapshot:
            bone = eb.get(entry["name"])
            parent = eb.get(entry["parent"]) if entry["parent"] else None
            if bone and parent:
                bone.parent = parent
                bone.use_connect = entry["use_connect"]
    finally:
        bpy.ops.object.mode_set(mode="OBJECT")
    for entry in snapshot:
        data_bone = new.data.bones.get(entry["name"])
        if data_bone is None:
            continue
        for key, value in entry["props"].items():
            try:
                data_bone[key] = value
            except Exception:
                pass


def _retarget(id_ref, old, new):
    return new if id_ref == old else id_ref


def _copy_pose_and_constraints(old, new):
    for old_pb in old.pose.bones:
        new_pb = new.pose.bones.get(old_pb.name)
        if new_pb is None:
            continue
        new_pb.rotation_mode = old_pb.rotation_mode
        if old_pb.custom_shape is not None:
            new_pb.custom_shape = old_pb.custom_shape
        existing = {c.name for c in new_pb.constraints}
        for c in old_pb.constraints:
            if c.name in existing:
                continue
            copied = new_pb.constraints.copy(c)
            if hasattr(copied, "target"):
                copied.target = _retarget(copied.target, old, new)
            if hasattr(copied, "pole_target"):
                copied.pole_target = _retarget(copied.pole_target, old, new)
            if hasattr(copied, "targets"):  # armature constraint
                for t in copied.targets:
                    t.target = _retarget(t.target, old, new)


def _move_animation(old, new):
    old_ad = old.animation_data
    if not old_ad:
        return
    new_ad = new.animation_data or new.animation_data_create()
    if old_ad.action:
        new_ad.action = old_ad.action
        slot = getattr(old_ad, "action_slot", None)
        if slot is not None and hasattr(new_ad, "action_slot"):
            try:
                new_ad.action_slot = slot
            except Exception:
                pass
    for drv in old_ad.drivers:
        try:
            new_drv = new_ad.drivers.from_existing(src_driver=drv)
            for var in new_drv.driver.variables:
                for t in var.targets:
                    t.id = _retarget(t.id, old, new)
        except Exception:
            pass


def _retarget_scene(old, new):
    for obj in bpy.data.objects:
        if obj.name in (old.name, new.name):
            continue
        for mod in getattr(obj, "modifiers", []):
            if mod.type == "ARMATURE" and mod.object == old:
                mod.object = new
        if obj.parent == old:
            mw = obj.matrix_world.copy()
            obj.parent = new
            obj.matrix_world = mw
        for c in obj.constraints:
            if hasattr(c, "target") and c.target == old:
                c.target = new
        if obj.type == "ARMATURE":
            for pb in obj.pose.bones:
                for c in pb.constraints:
                    if hasattr(c, "target") and c.target == old:
                        c.target = new
        ad = obj.animation_data
        if ad:
            for drv in ad.drivers:
                for var in drv.driver.variables:
                    for t in var.targets:
                        if t.id == old:
                            t.id = new


def rebuild_keep_user_bones(rigging_type: str, meta_name: str, old_armature=None) -> Dict:
    """Rebuild from metadata, keeping user bones, constraints and animation."""
    meta = bpy.data.objects.get(meta_name)
    if meta is None:
        raise ValueError(f"Rig meta object '{meta_name}' not found.")
    master = find_master_collection_for_object(meta)
    if old_armature is None and master is not None:
        tagged = [
            o for o in master.all_objects
            if o.type == "ARMATURE" and o.get("rbx_rig_meta_name") == meta.name
        ]
        old_armature = tagged[0] if len(tagged) == 1 else None
    if old_armature is None:
        create_rig(rigging_type, meta_name)
        return {"kept_bones": [], "note": "no previous armature"}

    if bpy.context.active_object and bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    snapshot = _snapshot_user_bones(old_armature)
    original_collections = list(old_armature.users_collection)
    _set_aside(old_armature, master)
    try:
        create_rig(rigging_type, meta_name)
    except Exception:
        # Put the old armature back exactly where it was
        bpy.context.scene.collection.objects.unlink(old_armature)
        for coll in original_collections:
            coll.objects.link(old_armature)
        old_armature.name = old_armature.name.replace("__bb_old", "")
        raise
    new = _find_new_armature(master, old_armature) if master else None
    if new is None:
        raise RuntimeError("Rebuild produced no armature")

    # Like a normal rebuild, the new armature sits where the Roblox import put it
    # (bones and part bindings are rebuilt in that space); user bones are stored in
    # armature space, so they line up with it.
    _recreate_user_bones(new, snapshot)
    _copy_pose_and_constraints(old_armature, new)
    _move_animation(old_armature, new)
    _retarget_scene(old_armature, new)

    old_data = old_armature.data
    bpy.data.objects.remove(old_armature, do_unlink=True)
    if old_data.users == 0:
        bpy.data.armatures.remove(old_data)
    return {"kept_bones": [b["name"] for b in snapshot], "armature": new.name}
