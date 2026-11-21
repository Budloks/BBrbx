# pyright: reportAttributeAccessIssue=false, reportOptionalMemberAccess=false
"""
BB fork: the rest contract between Blender bones and Roblox joints.

Every bone that is exported to Roblox needs to know the exact Roblox frame of
the joint it drives. Bones imported from Roblox already carry that as the
``transform`` / ``transform1`` / ``nicetransform`` props stamped by
``rig.creation.load_rigbone``. Bones added in Blender did not, so the exporter
used to *guess* their frame (a fixed 180 degree turn about Y), which breaks as
soon as a mesh is exported with different bone axes.

The invariant every stamped bone satisfies (armature space, Blender axes):

    bone.matrix_local == t2b @ transform @ transform1 @ nicetransform

where ``transform`` is the Roblox world CFrame of the joint's Part1 (or of the
Bone) and ``transform1`` is C1 (identity for Bones). With that in place the
exact Motor6D sampler in ``animation/sampling.py`` handles the bone, so no axis
guessing happens anywhere.

This module stamps bones from two sources:

* ``adopt_from_target_rest``: the rest frames Studio sends with every export
  request (``target_bone_rest["frames"]``, relative to the rig's PrimaryPart).
* ``stamp_from_blender_rest``: the Blender rest itself, for bones that are about
  to be created in Studio by Push Rig (the Roblox frame is defined to be the
  Blender bone frame, so ``nicetransform`` is identity).
"""

from typing import Any, Dict, Iterable, List, Optional, Tuple

import bpy
from mathutils import Matrix

from ..core.constants import get_transform_to_blender
from ..core.utils import cf_to_mat, mat_to_cf, to_matrix
from ..animation.face_controls import is_face_control_bone

STAMP_KEYS = ("transform", "transform1", "nicetransform")

# Bone prop: the Roblox channel this bone drives (defaults to rbx_source_name / name)
ROBLOX_PARENT_PROP = "rbx_roblox_parent"
ADOPTED_PROP = "rbx_bb_adopted"
EXPORT_PROP = "rbx_export"

_TOLERANCE = 1e-4


def _idprop(mat: Matrix):
    return [list(row) for row in mat]


def _close(a: Matrix, b: Matrix, eps: float = 1e-5) -> bool:
    return all(abs(a[r][c] - b[r][c]) <= eps for r in range(4) for c in range(4))


def is_stamped(bone) -> bool:
    data_bone = getattr(bone, "bone", bone)
    return all(key in data_bone for key in STAMP_KEYS)


def is_copied_duplicate(bone) -> bool:
    """True for a bone duplicated in Blender (Shift+D copies the Roblox props).

    Its rbx_source_name points at a DIFFERENT bone that still exists under that
    exact name, so the props describe that other bone, not this one.
    """
    data_bone = getattr(bone, "bone", bone)
    armature = data_bone.id_data
    if armature is None:
        return False
    source = data_bone.get("rbx_source_name")
    if source:
        return source != data_bone.name and source in armature.bones
    # Older imports have no rbx_source_name: "LeftArm.001" with the very same
    # Roblox transform as an existing "LeftArm" is a Blender copy.
    import re

    match = re.match(r"^(.*)\.\d{3}$", data_bone.name)
    if not match or "transform" not in data_bone:
        return False
    original = armature.bones.get(match.group(1))
    if original is None or "transform" not in original:
        return False
    return _close(to_matrix(original["transform"]), to_matrix(data_bone["transform"]))


def channel_name(bone) -> str:
    """Roblox channel name for any bone (shared by sampler, hierarchy and layout)."""
    data_bone = getattr(bone, "bone", bone)
    if data_bone.name.startswith("__RBX_STRUCTURAL__") or is_copied_duplicate(data_bone):
        # Structural duplicates and Blender copies keep their unique Blender name
        return data_bone.name
    return str(data_bone.get("rbx_source_name") or data_bone.name)


def roblox_name(bone) -> str:
    """Name of the Roblox channel a bone drives."""
    return channel_name(bone)


def joint_frame(data_bone) -> Matrix:
    """Roblox-space joint frame (transform @ transform1) of a stamped bone."""
    return to_matrix(data_bone["transform"]) @ to_matrix(data_bone["transform1"])


def blender_rest_in_roblox(data_bone) -> Matrix:
    """The bone's current Blender rest expressed as a Roblox frame (armature space)."""
    return get_transform_to_blender().inverted() @ data_bone.matrix_local


def rest_drift(data_bone) -> float:
    """How far the Blender rest moved since the bone was stamped (0 when unchanged)."""
    if not is_stamped(data_bone):
        return 0.0
    expected = (
        get_transform_to_blender()
        @ joint_frame(data_bone)
        @ to_matrix(data_bone["nicetransform"])
    )
    diff = expected.inverted() @ data_bone.matrix_local
    loc = diff.to_translation().length
    angle = abs(diff.to_quaternion().angle)
    return max(loc, angle)


def stamp_bone(
    data_bone,
    transform: Matrix,
    transform1: Optional[Matrix] = None,
    joint_type: str = "Bone",
    source_name: Optional[str] = None,
) -> None:
    """Stamp a bone so the exact sampler can export it.

    ``transform`` / ``transform1`` are Roblox-space matrices in the armature's
    frame of reference (the same space the importer uses).
    """
    if transform1 is None:
        transform1 = Matrix()
    joint = transform @ transform1
    o_trans = get_transform_to_blender() @ joint
    nice = o_trans.inverted() @ data_bone.matrix_local
    if is_stamped(data_bone) and data_bone.get("rbx_joint_type") == joint_type:
        # Skip no-op writes (live sync calls this on every request)
        same = all(
            _close(to_matrix(data_bone[key]), value)
            for key, value in (("transform", transform), ("transform1", transform1), ("nicetransform", nice))
        )
        if same:
            return
    data_bone["transform"] = _idprop(transform)
    data_bone["transform1"] = _idprop(transform1)
    data_bone["transform0"] = _idprop(Matrix())
    data_bone["nicetransform"] = _idprop(nice)
    data_bone["rbx_joint_type"] = joint_type
    data_bone["rbx_source_name"] = source_name or data_bone.get("rbx_source_name") or data_bone.name
    data_bone["is_transformable"] = True
    data_bone[ADOPTED_PROP] = True


def stamp_from_blender_rest(data_bone, joint_type: str = "Bone") -> None:
    """Define the Roblox joint frame to be the bone's Blender rest frame."""
    stamp_bone(data_bone, blender_rest_in_roblox(data_bone), None, joint_type)


def _set_roblox_parent(ao, data_bone, roblox_parent_name: Optional[str], bones_by_roblox: Dict[str, Any]):
    """Make the sampler measure the bone against its ROBLOX parent.

    When the Blender parent differs from the Roblox parent (helper bones in
    between, re-parenting in Blender), the sampler's worldspace path computes the
    delta against the given original parent instead of the Blender parent.
    """
    if roblox_parent_name:
        data_bone[ROBLOX_PARENT_PROP] = roblox_parent_name
    parent_bone = bones_by_roblox.get(roblox_parent_name) if roblox_parent_name else None
    blender_parent = data_bone.parent
    if parent_bone is not None and (blender_parent is None or blender_parent.name != parent_bone.name):
        data_bone["worldspace_bone"] = True
        data_bone["worldspace_original_parent"] = parent_bone.name
    else:
        for key in ("worldspace_bone", "worldspace_original_parent"):
            if key in data_bone and data_bone.get(ADOPTED_PROP):
                del data_bone[key]


def bones_by_roblox_name(ao) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for data_bone in ao.data.bones:
        if is_face_control_bone(data_bone):
            continue
        result.setdefault(roblox_name(data_bone), data_bone)
    return result


def _frames_from_payload(target_bone_rest: Optional[Dict[str, Any]]) -> Tuple[Optional[str], Dict[str, Dict[str, Any]]]:
    if not isinstance(target_bone_rest, dict):
        return None, {}
    frames = target_bone_rest.get("frames")
    if not isinstance(frames, dict):
        return None, {}
    root = target_bone_rest.get("root")
    return (root if isinstance(root, str) else None), frames


def _root_reference(ao, root_name: Optional[str], bones_by_roblox: Dict[str, Any]) -> Optional[Matrix]:
    """Roblox-space world CFrame of the rig's PrimaryPart as known to Blender."""
    root_bone = bones_by_roblox.get(root_name) if root_name else None
    if root_bone is None:
        roots = [b for b in ao.data.bones if b.parent is None and not is_face_control_bone(b)]
        root_bone = roots[0] if len(roots) == 1 else None
    if root_bone is None:
        return None
    if is_stamped(root_bone):
        # transform is the Part world CFrame (the PrimaryPart itself for the root)
        return to_matrix(root_bone["transform"])
    return blender_rest_in_roblox(root_bone)


def adopt_from_target_rest(
    ao,
    target_bone_rest: Optional[Dict[str, Any]],
    only_unstamped: bool = True,
    names: Optional[Iterable[str]] = None,
) -> List[str]:
    """Stamp Blender bones from the Roblox rest frames Studio sent.

    Only bones that have a same-named Roblox channel are touched. By default
    bones that are already stamped (imported from Roblox) are left alone, so this
    is safe to run on every export.
    """
    root_name, frames = _frames_from_payload(target_bone_rest)
    if not frames or not ao or ao.type != "ARMATURE":
        return []

    by_roblox = bones_by_roblox_name(ao)
    root_ref = _root_reference(ao, root_name, by_roblox)
    if root_ref is None:
        return []

    wanted = set(names) if names is not None else None
    adopted: List[str] = []
    for channel, entry in frames.items():
        if wanted is not None and channel not in wanted:
            continue
        data_bone = by_roblox.get(channel)
        if data_bone is None or not isinstance(entry, dict):
            continue
        if only_unstamped and is_stamped(data_bone) and not data_bone.get(ADOPTED_PROP):
            continue
        if data_bone.get("rbx_bb_rescale_pending"):
            continue  # scaled in Blender, Studio catches up on Synchronise
        if channel == root_name:
            continue
        try:
            part_rel = cf_to_mat(entry["part"])
            c1 = cf_to_mat(entry["c1"]) if entry.get("c1") else Matrix()
        except (KeyError, TypeError, ValueError, IndexError):
            continue
        kind = str(entry.get("kind") or "Bone")
        stamp_bone(data_bone, root_ref @ part_rel, c1, kind, channel)
        _set_roblox_parent(ao, data_bone, entry.get("parent"), by_roblox)
        adopted.append(data_bone.name)
    return adopted


# ---------------------------------------------------------------------------
# Rig layout (Push Rig)
# ---------------------------------------------------------------------------


def _deformed_bone_names(ao) -> set:
    """Bones that actually carry weights on a mesh skinned by this armature."""
    names = set()
    group_names = set()
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        if not any(m.type == "ARMATURE" and m.object == ao for m in obj.modifiers):
            continue
        used = set()
        for v in obj.data.vertices:
            for g in v.groups:
                if g.weight > 1e-4:
                    used.add(g.group)
        for g in obj.vertex_groups:
            if g.index in used:
                group_names.add(g.name)
    for b in ao.data.bones:
        if b.name in group_names and b.use_deform:
            names.add(b.name)
    return names


def _attached_bone_names(ao) -> set:
    """Bones that carry an object: a mesh parented to the bone or following it
    through a constraint (Child Of, Copy Transforms...), like imported parts."""
    names = set()
    for obj in bpy.data.objects:
        if obj.parent is ao and obj.parent_type == "BONE" and obj.parent_bone:
            names.add(obj.parent_bone)
        for con in getattr(obj, "constraints", []):
            if getattr(con, "target", None) is ao and getattr(con, "subtarget", ""):
                names.add(con.subtarget)
    return names


def is_exported_bone(ao, data_bone, deformed: Optional[set] = None, attached: Optional[set] = None) -> bool:
    """Whether a bone becomes a Roblox channel: only bones that move a part.

    That is a bone that came from Roblox (stamped), one that deforms a skinned
    mesh, or one that carries a mesh/object. Helper, IK and control bones move
    nothing in Roblox, so they are never sent; there is nothing to toggle.
    """
    if is_face_control_bone(data_bone):
        return False
    if is_stamped(data_bone) and not is_copied_duplicate(data_bone):
        return True
    if deformed is None:
        deformed = _deformed_bone_names(ao)
    if data_bone.name in deformed:
        return True
    if attached is None:
        attached = _attached_bone_names(ao)
    return data_bone.name in attached


def exported_bone_names(ao) -> set:
    deformed = _deformed_bone_names(ao)
    attached = _attached_bone_names(ao)
    return {b.name for b in ao.data.bones if is_exported_bone(ao, b, deformed, attached)}


def _roblox_parent_of(data_bone, exported: Dict[str, Any]):
    explicit = data_bone.get(ROBLOX_PARENT_PROP)
    if explicit:
        for b in exported.values():
            if roblox_name(b) == explicit:
                return b
    parent = data_bone.parent
    while parent is not None and parent.name not in exported:
        parent = parent.parent
    if parent is None:
        # A Blender root bone that is not the rig root hangs off the rig's
        # PrimaryPart in Roblox (e.g. a weapon bone chain with no parent, or
        # loose parts like TAC50's MagBetter that are stamped but parentless).
        # The rig root is the stamped parentless bone with the biggest
        # subtree (HumanoidRootPart); only that one stays a root.
        main = _main_root(exported)
        if main is not None and main.name != data_bone.name:
            return main
    return parent


def _main_root(exported: Dict[str, Any]):
    roots = [
        b for b in exported.values()
        if b.parent is None and is_stamped(b) and not b.get(ADOPTED_PROP)
    ]
    if not roots:
        return None
    return max(roots, key=lambda b: len(b.children_recursive))


def rig_layout(ao) -> Dict[str, Any]:
    """Describe the rig Blender wants Roblox to have.

    Each channel carries its rest relative to its Roblox parent's frame, i.e.
    exactly the value for ``Bone.CFrame`` or a Motor6D ``C0`` (with C1 = I).
    """
    deformed = _deformed_bone_names(ao)
    attached = _attached_bone_names(ao)
    exported = {
        b.name: b for b in ao.data.bones if is_exported_bone(ao, b, deformed, attached)
    }

    channels: List[Dict[str, Any]] = []
    warnings: List[str] = []
    seen_names: Dict[str, str] = {}

    def desired_frame(b) -> Tuple[Matrix, Matrix]:
        """(part/bone world, joint frame) in Roblox space for the bone's CURRENT rest."""
        if is_stamped(b):
            nice = to_matrix(b["nicetransform"])
            t1 = to_matrix(b["transform1"])
            joint = get_transform_to_blender().inverted() @ b.matrix_local @ nice.inverted()
            return joint @ t1.inverted(), joint
        frame = blender_rest_in_roblox(b)
        return frame, frame

    for name in [b.name for b in ao.data.bones if b.name in exported]:
        b = exported[name]
        rname = roblox_name(b)
        if rname in seen_names:
            warnings.append(f"Bones '{seen_names[rname]}' and '{b.name}' both map to Roblox name '{rname}'")
            continue
        seen_names[rname] = b.name

        parent = _roblox_parent_of(b, exported)
        part_world, joint = desired_frame(b)
        if parent is not None:
            parent_part_world, _ = desired_frame(parent)
            rel = parent_part_world.inverted() @ joint
        else:
            rel = joint

        stamped = is_stamped(b)
        joint_type = str(b.get("rbx_joint_type") or ("Bone" if b.name in deformed else "Motor6D"))
        if b.name in deformed and not stamped:
            joint_type = "Bone"
        channels.append(
            {
                "name": rname,
                "blender_name": b.name,
                "parent": roblox_name(parent) if parent is not None else None,
                "kind": joint_type,
                "rel": mat_to_cf(rel),
                "skinned": b.name in deformed,
                "existing": stamped and not b.get(ADOPTED_PROP),
                "stamped": stamped,
                "rest_changed": stamped and rest_drift(b) > _TOLERANCE,
            }
        )

    from .rescale import pending

    rescale = [
        {"id": e.get("id"), "root": e.get("root"), "factor": e.get("factor"), "pivot": e.get("pivot")}
        for e in pending(ao)
    ]
    return {"armature": ao.name, "channels": channels, "warnings": warnings, "rescale": rescale}


def apply_layout_result(ao, applied: Iterable[Dict[str, Any]]) -> List[str]:
    """After Studio created/updated channels, stamp the matching Blender bones.

    ``applied`` entries: {"name", "blender_name", "kind"}. The Roblox frame is the
    Blender rest the layout was computed from, so stamping uses the current rest
    (keeping an existing nicetransform for bones that were already stamped).
    """
    stamped: List[str] = []
    by_name = {b.name: b for b in ao.data.bones}
    exported = {b.name: b for b in ao.data.bones if is_exported_bone(ao, b)}
    by_roblox = bones_by_roblox_name(ao)
    for entry in applied or []:
        b = by_name.get(entry.get("blender_name") or "") or by_roblox.get(entry.get("name") or "")
        if b is None:
            continue
        kind = str(entry.get("kind") or "Bone")
        if is_stamped(b):
            nice = to_matrix(b["nicetransform"])
            t1 = to_matrix(b["transform1"])
            joint = get_transform_to_blender().inverted() @ b.matrix_local @ nice.inverted()
            stamp_bone(b, joint @ t1.inverted(), t1, kind, entry.get("name"))
            # keep the original nice offset (stamp_bone recomputes it from the same rest)
        else:
            stamp_bone(b, blender_rest_in_roblox(b), None, kind, entry.get("name"))
        parent = _roblox_parent_of(b, exported)
        _set_roblox_parent(ao, b, roblox_name(parent) if parent is not None else None, by_roblox)
        stamped.append(b.name)
    return stamped
