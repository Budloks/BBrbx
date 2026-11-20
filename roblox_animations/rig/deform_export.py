# pyright: reportAttributeAccessIssue=false, reportOptionalMemberAccess=false
"""
BB fork: export skinned (deforming) meshes as an FBX that imports into Roblox
Studio cleanly, ready for the Studio "Bind Imported Mesh" button.

What it takes care of (each of these broke a manual export at least once):
* the armature object transform is baked out (armature at the origin), so the
  bind pose and the bones end up in the same space in Roblox,
* bones are named after their Roblox channels (renamed Blender bones still
  drive the right channel),
* bone axes are exported so a Roblox Bone frame equals the Blender bone frame
  (secondary axis -X), and Bind/adoption reads the real frames afterwards anyway,
* only the bones the meshes need are included (weighted bones plus the chain
  between them); helper/IK/control bones stay out,
* vertex groups of non-exported bones are removed.
"""

import os
from typing import Dict, List, Optional, Set

import bpy
from mathutils import Matrix

from . import rest_contract


def skinned_meshes(ao, only_selected: bool = False) -> List["bpy.types.Object"]:
    out = []
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        if only_selected and not obj.select_get():
            continue
        if any(m.type == "ARMATURE" and m.object == ao for m in obj.modifiers):
            out.append(obj)
    return out


def _weighted_bones(ao, meshes) -> Set[str]:
    names: Set[str] = set()
    bone_names = set(ao.data.bones.keys())
    for obj in meshes:
        used = set()
        for v in obj.data.vertices:
            for g in v.groups:
                if g.weight > 1e-4:
                    used.add(g.group)
        for g in obj.vertex_groups:
            if g.index in used and g.name in bone_names:
                names.add(g.name)
    return names


def skeleton_for(ao, meshes) -> Set[str]:
    """Weighted bones plus every bone on the chain between weighted bones."""
    weighted = _weighted_bones(ao, meshes)
    skeleton = set(weighted)
    for name in weighted:
        chain = []
        parent = ao.data.bones[name].parent
        while parent is not None:
            chain.append(parent.name)
            if parent.name in weighted:
                skeleton.update(chain)
                break
            parent = parent.parent
    return skeleton


def export_deform_fbx(ao, filepath: str, only_selected: bool = False) -> Dict:
    meshes = skinned_meshes(ao, only_selected)
    if not meshes:
        raise RuntimeError("No meshes with an Armature modifier on this armature")
    skeleton = skeleton_for(ao, meshes)
    if not skeleton:
        raise RuntimeError("The meshes have no weights on this armature's bones")

    channel = {b.name: rest_contract.channel_name(b) for b in ao.data.bones}
    roots = [n for n in skeleton if not (ao.data.bones[n].parent and ao.data.bones[n].parent.name in skeleton)]
    attach = {}
    for n in roots:
        parent = ao.data.bones[n].parent
        while parent is not None and not rest_contract.is_exported_bone(ao, parent):
            parent = parent.parent
        attach[channel[n]] = channel[parent.name] if parent is not None else None

    scene = bpy.context.scene
    prev_active = bpy.context.view_layer.objects.active
    prev_selected = [o for o in bpy.context.selected_objects]
    prev_mode = ao.mode
    created_objects = []
    created_data = []
    try:
        if bpy.context.object and bpy.context.object.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        ainv = ao.matrix_world.inverted()

        arm = ao.copy()
        arm.data = ao.data.copy()
        arm.animation_data_clear()
        arm.name = "__bb_deform_rig"
        arm.data.name = "__bb_deform_rig"
        scene.collection.objects.link(arm)
        created_objects.append(arm)
        created_data.append(arm.data)
        arm.parent = None
        arm.matrix_world = Matrix.Identity(4)
        arm.data.pose_position = "REST"
        for pb in arm.pose.bones:
            for c in list(pb.constraints):
                pb.constraints.remove(c)

        for o in bpy.context.view_layer.objects:
            o.select_set(False)
        bpy.context.view_layer.objects.active = arm
        arm.select_set(True)
        bpy.ops.object.mode_set(mode="EDIT")
        eb = arm.data.edit_bones
        for b in list(eb):
            if b.name not in skeleton:
                eb.remove(b)
        for b in eb:
            b.use_deform = True
        # Rename to Roblox channel names (two passes avoid transient clashes)
        for b in eb:
            b.name = "__bbtmp_" + b.name
        for b in eb:
            original = b.name[len("__bbtmp_"):]
            b.name = channel[original]
        bpy.ops.object.mode_set(mode="OBJECT")

        copies = []
        for src in meshes:
            c = src.copy()
            c.data = src.data.copy()
            scene.collection.objects.link(c)
            created_objects.append(c)
            created_data.append(c.data)
            c.parent = None
            c.constraints.clear()
            c.matrix_world = ainv @ src.matrix_world
            for m in list(c.modifiers):
                c.modifiers.remove(m)
            for g in list(c.vertex_groups):
                if g.name in skeleton:
                    g.name = channel[g.name]
                else:
                    c.vertex_groups.remove(g)
            copies.append(c)

        bpy.ops.object.select_all(action="DESELECT")
        for c in copies:
            c.select_set(True)
        bpy.context.view_layer.objects.active = copies[0]
        if len(copies) > 1:
            bpy.ops.object.join()
        mesh = bpy.context.view_layer.objects.active
        base = ao.name.strip("_").replace("_Armature", "")
        mesh.name = (base or "Rig") + "_Deform"
        mesh.data.name = mesh.name
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
        mod = mesh.modifiers.new("Armature", "ARMATURE")
        mod.object = arm
        mesh.parent = arm
        unweighted = sum(1 for v in mesh.data.vertices if not any(g.weight > 1e-4 for g in v.groups))

        bpy.ops.object.select_all(action="DESELECT")
        arm.select_set(True)
        mesh.select_set(True)
        os.makedirs(os.path.dirname(filepath) or ".", exist_ok=True)
        bpy.ops.export_scene.fbx(
            filepath=filepath,
            use_selection=True,
            object_types={"ARMATURE", "MESH"},
            add_leaf_bones=False,
            bake_anim=False,
            apply_unit_scale=True,
            apply_scale_options="FBX_SCALE_NONE",
            global_scale=1.0,
            mesh_smooth_type="FACE",
            axis_forward="-Z",
            axis_up="Y",
            primary_bone_axis="Y",
            secondary_bone_axis="-X",
        )
        return {
            "file": filepath,
            "mesh": mesh.name,
            "bones": sorted(channel[n] for n in skeleton),
            "roots": attach,
            "unweighted_vertices": unweighted,
        }
    finally:
        for obj in created_objects:
            try:  # objects merged by join() are already gone
                if obj.name in bpy.data.objects:
                    bpy.data.objects.remove(obj, do_unlink=True)
            except ReferenceError:
                pass
        for data in created_data:
            try:
                if data.users == 0:
                    if isinstance(data, bpy.types.Armature):
                        bpy.data.armatures.remove(data)
                    elif isinstance(data, bpy.types.Mesh):
                        bpy.data.meshes.remove(data)
            except ReferenceError:
                pass
        for o in bpy.context.view_layer.objects:
            o.select_set(o in prev_selected)
        bpy.context.view_layer.objects.active = prev_active
        if prev_mode not in ("OBJECT", "EDIT") and ao.name in bpy.data.objects:
            try:
                bpy.context.view_layer.objects.active = ao
                bpy.ops.object.mode_set(mode=prev_mode)
                bpy.context.view_layer.objects.active = prev_active
            except Exception:
                pass


def default_fbx_path(ao) -> str:
    blend = bpy.data.filepath
    folder = os.path.dirname(blend) if blend else bpy.app.tempdir
    base = ao.name.strip("_").replace("_Armature", "") or "Rig"
    return os.path.join(folder, base + "_Deform.fbx")
