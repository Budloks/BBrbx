# pyright: reportAttributeAccessIssue=false, reportOptionalMemberAccess=false
"""BB fork: scale one branch of a rig (a weapon under its Handle) and keep the animations.

Rotations do not depend on size, so only translations change: the rest of
every bone below the branch root is scaled about a pivot, so are the meshes
riding on those bones and the location keys of those bones in every action of
the rig. The branch root keeps its own keys, so the weapon stays where the
animation puts it in the hand.

You do not call it by hand: scale a Roblox joint bone in the animation
(TAC50 x1.2, a second pistol x2) and Synchronise picks the biggest value up
(``apply_pose_scale``), makes the size real here and in Studio, and drops the
scale keys. The Roblox stamps are scaled the same way, so exports stay 1:1;
the armature remembers the change until Studio has applied it
(see ``pending``/``acknowledge``).
"""

import json
import uuid
from typing import Any, Dict, List, Optional, Set

import bpy
from mathutils import Matrix, Vector

from ..core.constants import get_transform_to_blender
from ..core.utils import to_matrix
from . import rest_contract

APPLIED_PROP = "rbx_bb_applied_scale"  # bone: helper scale already sent to Studio
PENDING_PROP = "rbx_bb_rescale"  # armature: JSON list of changes Studio has not applied yet
BONE_PENDING_PROP = "rbx_bb_rescale_pending"  # bone: keep these stamps until Synchronise


def _is_identity(m: Matrix, eps: float = 1e-4) -> bool:
    return all(abs(m[r][c] - (1.0 if r == c else 0.0)) <= eps for r in range(4) for c in range(4))


def _scaled_about(pivot: Vector, k: float) -> Matrix:
    return Matrix.Translation(pivot) @ Matrix.Diagonal((k, k, k, 1.0)) @ Matrix.Translation(-pivot)


def _scale_position(m: Matrix, pivot: Vector, k: float) -> Matrix:
    """Same rotation, translation moved away from pivot by k."""
    out = m.copy()
    out.translation = pivot + (m.translation - pivot) * k
    return out


def _all_fcurves(action) -> List[Any]:
    curves: List[Any] = []
    for layer in getattr(action, "layers", []) or []:
        for strip in getattr(layer, "strips", []) or []:
            for bag in getattr(strip, "channelbags", []) or []:
                curves.extend(bag.fcurves)
    if not curves:
        curves = list(getattr(action, "fcurves", []) or [])
    return curves


def _actions_used_by(obj) -> Set[Any]:
    ad = getattr(obj, "animation_data", None)
    used = set()
    if ad is None:
        return used
    if ad.action is not None:
        used.add(ad.action)
    for track in ad.nla_tracks:
        for strip in track.strips:
            if strip.action is not None:
                used.add(strip.action)
    return used


def rig_actions(ao) -> List[Any]:
    """Actions of this rig: they key its bones and no other armature uses them."""
    from ..server.bb_routes import action_targets_armature

    mine = _actions_used_by(ao)
    others: Set[Any] = set()
    for obj in bpy.data.objects:
        if obj is not ao and obj.type == "ARMATURE":
            others |= _actions_used_by(obj)
    return [
        a for a in bpy.data.actions
        if a in mine or (a not in others and action_targets_armature(a, ao))
    ]


def _attached_objects(ao, names: Set[str]):
    """Meshes that follow branch bones: (constrained/bone-parented, skinned)."""
    rigid, skinned = [], []
    for obj in bpy.data.objects:
        if obj.type not in {"MESH", "EMPTY", "CURVE"}:
            continue
        follows = obj.parent is ao and obj.parent_type == "BONE" and obj.parent_bone in names
        for con in obj.constraints:
            if getattr(con, "target", None) is ao and getattr(con, "subtarget", "") in names:
                follows = True
        if follows:
            rigid.append(obj)
            continue
        if obj.type == "MESH" and any(m.type == "ARMATURE" and m.object is ao for m in obj.modifiers):
            groups = {g.index for g in obj.vertex_groups if g.name in names}
            if groups:
                skinned.append((obj, groups))
    return rigid, skinned


def branch_bones(ao, root_name: str) -> List[str]:
    root = ao.data.bones[root_name]
    return [b.name for b in root.children_recursive]


def _targets(pose_bone, ao) -> Set[str]:
    return {
        c.subtarget for c in pose_bone.constraints
        if getattr(c, "target", None) is ao and getattr(c, "subtarget", "")
    }


def driving_helpers(ao, root_name: str, branch: Set[str]) -> List[str]:
    """Helper bones outside the branch that only drive branch bones (CTRL_Mag -> Mag).

    They scale with the branch (with their helper children), so a weapon's
    control bones keep working. Bones that also drive anything outside, Roblox
    joints and ancestors of the root are left alone.
    """
    bones = ao.data.bones
    ancestors = {b.name for b in bones[root_name].parent_recursive}
    deformed = rest_contract._deformed_bone_names(ao)
    users: Dict[str, Set[str]] = {}
    for pb in ao.pose.bones:
        for target in _targets(pb, ao):
            users.setdefault(target, set()).add(pb.name)
    picked: List[str] = []
    for target, owners in users.items():
        if target in branch or target == root_name or target in ancestors or target not in bones:
            continue
        family = [target] + [c.name for c in bones[target].children_recursive]
        if any(rest_contract.is_exported_bone(ao, bones[n], deformed) for n in family):
            continue
        dependents = set()
        for n in family:
            dependents |= users.get(n, set())
        if dependents and dependents <= (branch | set(family)) and owners & branch:
            picked.extend(n for n in family if n not in picked)
    return picked


def pending(ao) -> List[Dict[str, Any]]:
    try:
        return list(json.loads(ao.get(PENDING_PROP) or "[]"))
    except (TypeError, ValueError):
        return []


def acknowledge(ao, ids) -> None:
    """Studio applied these changes: forget them and let Studio rest win again."""
    ids = set(ids or [])
    left = [entry for entry in pending(ao) if entry.get("id") not in ids]
    if left:
        ao[PENDING_PROP] = json.dumps(left)
    else:
        ao.pop(PENDING_PROP, None)
    keep = {name for entry in left for name in entry.get("bones", [])}
    for bone in ao.data.bones:
        if BONE_PENDING_PROP in bone and bone.name not in keep:
            del bone[BONE_PENDING_PROP]


def scale_branch(
    ao,
    root_name: str,
    factor: float,
    pivot: Optional[Vector] = None,
    scale_actions: bool = True,
) -> Dict[str, Any]:
    """Scale everything below ``root_name`` by ``factor``.

    ``pivot`` is in armature space (Blender axes); by default the root's Roblox
    joint (where it hangs on its parent), or its head when it is not stamped.
    """
    if ao is None or ao.type != "ARMATURE":
        raise ValueError("Pick an armature")
    if root_name not in ao.data.bones:
        raise ValueError(f"Bone '{root_name}' not found")
    if factor <= 0 or abs(factor - 1.0) < 1e-6:
        raise ValueError("Scale must be positive and not 1")
    k = round(float(factor), 6)
    root = ao.data.bones[root_name]
    rbx_root = rest_contract.roblox_name(root)
    names = branch_bones(ao, root_name)
    helpers = driving_helpers(ao, root_name, set(names))
    names += helpers
    name_set = set(names)
    t2b = get_transform_to_blender()

    if pivot is None:
        if rest_contract.is_stamped(root):
            pivot = (t2b @ rest_contract.joint_frame(root)).translation.copy()
        else:
            pivot = root.head_local.copy()
    pivot = Vector(pivot)
    pivot_rbx = (t2b.inverted() @ Matrix.Translation(pivot)).translation

    context = bpy.context
    view_layer = context.view_layer
    prev_active = view_layer.objects.active
    prev_mode = ao.mode
    prev_pose_position = ao.data.pose_position
    if prev_mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")

    # 1. where attached meshes sit in the rest pose, before and after
    ao.data.pose_position = "REST"
    view_layer.update()
    arm_world = ao.matrix_world.copy()
    s_world = arm_world @ _scaled_about(pivot, k) @ arm_world.inverted()
    rigid, skinned = _attached_objects(ao, name_set | {root_name})
    # meshes on the root bone scale too (the root bone itself stays put)
    desired = {obj.name: s_world @ obj.matrix_world for obj in rigid}
    # Child Of on bones, set at rest (target @ inverse == I): reset after the change
    child_of = []
    for pb in ao.pose.bones:
        for con in pb.constraints:
            if con.type == "CHILD_OF" and con.target is ao and con.subtarget in name_set:
                target = ao.data.bones[con.subtarget]
                if _is_identity(arm_world @ target.matrix_local @ con.inverse_matrix):
                    child_of.append((pb.name, con.name))
    outside = sorted(
        f"{pb.name} ({', '.join(sorted(_targets(pb, ao) - name_set - {root_name}))})"
        for pb in ao.pose.bones
        if pb.name in name_set and _targets(pb, ao) - name_set - {root_name}
    )

    # 2. stamps (before the rest changes: they are read in the old frame)
    root_joint = rest_contract.joint_frame(root) if rest_contract.is_stamped(root) else None
    for name in [root_name] + names:
        b = ao.data.bones[name]
        if not rest_contract.is_stamped(b):
            continue
        transform = to_matrix(b["transform"])
        joint = rest_contract.joint_frame(b)
        new_transform = _scale_position(transform, pivot_rbx, k)
        new_joint = joint if name == root_name else _scale_position(joint, pivot_rbx, k)
        nice = to_matrix(b["nicetransform"])
        if name != root_name:
            nice = nice.copy()
            nice.translation = nice.translation * k
        b["transform"] = rest_contract._idprop(new_transform)
        b["transform1"] = rest_contract._idprop(new_transform.inverted() @ new_joint)
        b["nicetransform"] = rest_contract._idprop(nice)
        b[BONE_PENDING_PROP] = True

    # 3. rest of the branch (the root keeps its rest: it is the joint)
    view_layer.objects.active = ao
    bpy.ops.object.mode_set(mode="EDIT")
    edit = ao.data.edit_bones
    for name in names:
        eb = edit[name]
        roll = eb.roll
        eb.head = pivot + (eb.head - pivot) * k
        eb.tail = pivot + (eb.tail - pivot) * k
        eb.roll = roll
    bpy.ops.object.mode_set(mode="OBJECT")
    view_layer.update()
    for bone_name, con_name in child_of:
        con = ao.pose.bones[bone_name].constraints[con_name]
        con.inverse_matrix = (arm_world @ ao.data.bones[con.subtarget].matrix_local).inverted()
    view_layer.update()

    # 4. meshes: rigid ones get a new basis, skinned vertices move
    for obj in rigid:
        current = obj.matrix_world.copy()
        try:
            obj.matrix_basis = obj.matrix_basis @ current.inverted() @ desired[obj.name]
        except ValueError:
            continue
    mixed_vertices = 0
    for obj, groups in skinned:
        to_arm = arm_world.inverted() @ obj.matrix_world
        m = obj.matrix_world.inverted() @ arm_world @ _scaled_about(pivot, k) @ to_arm
        for v in obj.data.vertices:
            inside = sum(g.weight for g in v.groups if g.group in groups)
            total = sum(g.weight for g in v.groups)
            if total <= 0 or inside <= 0:
                continue
            if inside < total * 0.999:
                mixed_vertices += 1
                continue
            v.co = m @ v.co
        obj.data.update()

    # 5. poses and keys: translations of the branch scale, rotations stay
    for name in names:
        pb = ao.pose.bones[name]
        pb.location = pb.location * k
    actions = rig_actions(ao) if scale_actions else []
    keys = 0
    for action in actions:
        for curve in _all_fcurves(action):
            path = curve.data_path or ""
            if not path.endswith(".location") or not path.startswith('pose.bones["'):
                continue
            bone = path[len('pose.bones["'):-len('"].location')].replace('\\"', '"')
            if bone not in name_set:
                continue
            for kp in curve.keyframe_points:
                kp.co.y *= k
                kp.handle_left.y *= k
                kp.handle_right.y *= k
                keys += 1
            curve.update()

    # 6. remember it for Studio
    entries = pending(ao)
    joint_local = None
    if root_joint is not None:
        joint_local = list(root_joint.inverted() @ pivot_rbx)
    entries.append(
        {
            "id": uuid.uuid4().hex[:12],
            "root": rbx_root,
            "factor": k,
            "pivot": joint_local,  # in the root joint's frame (studs)
            "bones": [root_name] + names,
        }
    )
    ao[PENDING_PROP] = json.dumps(entries)

    ao.data.pose_position = prev_pose_position
    view_layer.update()
    if prev_active is not None:
        view_layer.objects.active = prev_active
    if prev_mode not in {"OBJECT", "EDIT"} and view_layer.objects.active is ao:
        try:
            bpy.ops.object.mode_set(mode=prev_mode)
        except RuntimeError:
            pass
    return {
        "bones": len(names),
        "meshes": len(rigid) + len(skinned),
        "actions": [a.name for a in actions],
        "keys": keys,
        "mixed_vertices": mixed_vertices,
        "helpers": helpers,
        "outside": outside,
    }


# ---------------------------------------------------------------------------
# Bone scale from the animation (Synchronise)
# ---------------------------------------------------------------------------

_SCALE_EPS = 1e-4


def _scale_curves(action, bone_name: str):
    """(container, fcurve) for every scale curve of the bone in an action."""
    path = f'pose.bones["{bone_name}"].scale'
    found = []
    for layer in getattr(action, "layers", []) or []:
        for strip in getattr(layer, "strips", []) or []:
            for bag in getattr(strip, "channelbags", []) or []:
                found.extend((bag, c) for c in bag.fcurves if c.data_path == path)
    if not found and getattr(action, "fcurves", None) is not None:
        found = [(action, c) for c in action.fcurves if c.data_path == path]
    return found


def scale_from_poses(ao) -> Optional[Dict[str, float]]:
    """Bone scale Roblox cannot animate, read from the pose and every action.

    A Roblox joint bone scaled in Blender (static or keyed) means "this part is
    the wrong size": the biggest value wins (or the smallest when it is only
    ever shrunk). A bone that never leaves 1, or one that goes to 0 and back
    (hide tricks), is left alone.
    """
    actions = rig_actions(ao)
    out: Dict[str, float] = {}
    exported = rest_contract.exported_bone_names(ao)
    for pb in ao.pose.bones:
        if pb.name not in exported and not affected_by_scale(ao, pb.name, exported)[0]:
            continue  # a helper whose scale moves nothing in Roblox
        values = list(pb.scale)
        for action in actions:
            for _bag, curve in _scale_curves(action, pb.name):
                values.extend(kp.co.y for kp in curve.keyframe_points)
        hi, lo = max(values), min(values)
        total = 1.0
        if hi > 1 + _SCALE_EPS:
            total = hi
        elif lo < 1 - _SCALE_EPS and lo > 0.01:
            total = lo
        applied = float(pb.bone.get(APPLIED_PROP, 1.0))
        if abs(total / applied - 1.0) > _SCALE_EPS:
            out[pb.name] = total
    return out


def apply_pose_scale(ao) -> List[Dict[str, Any]]:
    """Turn bone scale into real size (rest, meshes, children's moves) for Synchronise.

    Outer bones go first, so a magazine scaled inside a scaled gun ends up at
    both sizes multiplied. The scale keys are removed afterwards (Roblox has no
    scale channel; the size now lives in the rig).
    """
    wanted = scale_from_poses(ao)
    if not wanted:
        return []
    order = sorted(wanted, key=lambda n: len(ao.data.bones[n].parent_recursive))
    done = []
    for name in order:
        factor = wanted[name]
        bone = ao.data.bones[name]
        if rest_contract.is_stamped(bone) and bone.get("rbx_joint_type", "Motor6D") != "Bone":
            # a Roblox part (Handle, gun model): the joint is the hinge; the
            # size moves into the rig and the scale keys go away
            for action in rig_actions(ao):
                for container, curve in _scale_curves(action, name):
                    container.fcurves.remove(curve)
            ao.pose.bones[name].scale = (1.0, 1.0, 1.0)
            result = scale_branch(ao, name, factor)
        else:
            # a helper (CTRL_Whip) or a Roblox Bone: its scale stays in
            # Blender (IK and constraints behave exactly as animated); only
            # the Roblox rest of what it sizes up changes
            result = bake_bone_scale(ao, name, factor)
        done.append({"bone": name, "factor": round(factor, 6), **{k: result[k] for k in ("bones", "meshes", "keys")}})
    return done


# Constraints that carry a target's position and scale onto their owner
_FOLLOW_CONSTRAINTS = {"COPY_TRANSFORMS", "CHILD_OF", "COPY_LOCATION", "COPY_SCALE", "TRANSFORM", "ARMATURE"}


def affected_by_scale(ao, source: str, exported: Optional[Set[str]] = None):
    """(Roblox bones, helper bones) that inherit ``source``'s scale.

    Children inherit it, and so does any bone that follows one of them through
    a constraint (Copy Transforms / Child Of ...), plus that bone's children:
    CTRL_Whip -> MCH chain -> SpineBones (Copy Transforms) -> their children.
    """
    if exported is None:
        exported = rest_contract.exported_bone_names(ao)
    bones = ao.data.bones
    ancestors = {b.name for b in bones[source].parent_recursive}
    followers: Dict[str, Set[str]] = {}
    for pb in ao.pose.bones:
        for con in pb.constraints:
            if (
                con.type in _FOLLOW_CONSTRAINTS
                and getattr(con, "target", None) is ao
                and getattr(con, "subtarget", "")
                and not getattr(con, "mute", False)
            ):
                followers.setdefault(con.subtarget, set()).add(pb.name)
    seen = {source}
    todo = [source]
    while todo:
        name = todo.pop()
        nxt = {c.name for c in bones[name].children} | followers.get(name, set())
        for n in nxt - seen:
            if n in ancestors:
                continue
            seen.add(n)
            todo.append(n)
    seen.discard(source)
    return sorted(n for n in seen if n in exported), sorted(n for n in seen if n not in exported)


def _studio_part_name(obj_name: str) -> str:
    """Studio part a Blender mesh stands for ("TAC50.model/Barrel.MeshPart" -> "Barrel")."""
    name = obj_name.split("/")[-1]
    for suffix in (".MeshPart", ".Part", ".UnionOperation", ".WedgePart", ".TrussPart"):
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def bake_bone_scale(ao, source: str, total: float) -> Dict[str, Any]:
    """Send a helper's (or Roblox Bone's) scale to Studio, keeping Blender as is.

    ``source`` (CTRL_Whip at 5x) sizes up every bone that inherits its scale.
    Blender stays untouched: the scale keeps driving IK and constraints exactly
    as animated (baking it into rests would change how IK solves). Only the
    Roblox rest of the Roblox bones it sizes up is moved away from the source's
    head by the change since the last Synchronise, and the exporter drops pose
    scale, so Roblox gets the same positions at the new size. Studio scales
    those Bones and their MeshParts on Synchronise.
    """
    from ..core.utils import mat_to_cf  # noqa: F401  (keeps utils loaded)

    applied = float(ao.data.bones[source].get(APPLIED_PROP, 1.0))
    k = round(float(total) / applied, 6)
    exported = rest_contract.exported_bone_names(ao)
    roblox, helpers = affected_by_scale(ao, source, exported)
    pivot = ao.data.bones[source].head_local.copy()
    t2b = get_transform_to_blender()
    pivot_rbx = (t2b.inverted() @ Matrix.Translation(pivot)).translation
    step = _scaled_about(pivot, k)  # Blender armature space

    # meshes the Roblox bones carry or skin: Studio scales those MeshParts, and
    # a MeshPart that is also a joint (Whip blade on RootPart) moves with them
    rigid, skinned = _attached_objects(ao, set(roblox))
    parts = sorted({_studio_part_name(o.name) for o in rigid} | {_studio_part_name(o.name) for o, _g in skinned})
    part_joints = [
        b.name for b in ao.data.bones
        if b.name in exported and b.name not in roblox
        and rest_contract.is_stamped(b) and rest_contract.channel_name(b) in parts
    ]

    roblox_names = []
    for name in roblox + part_joints:
        b = ao.data.bones[name]
        if not rest_contract.is_stamped(b):
            continue
        transform = to_matrix(b["transform"])
        joint = rest_contract.joint_frame(b)
        new_transform = _scale_position(transform, pivot_rbx, k)
        new_joint = _scale_position(joint, pivot_rbx, k)
        nice = to_matrix(b["nicetransform"]).copy()
        nice.translation = nice.translation * k
        b["transform"] = rest_contract._idprop(new_transform)
        b["transform1"] = rest_contract._idprop(new_transform.inverted() @ new_joint)
        b["nicetransform"] = rest_contract._idprop(nice)
        prev = b.get(rest_contract.REST_SCALE_PROP)
        prev_m = Matrix([list(prev[i * 4:i * 4 + 4]) for i in range(4)]) if prev else Matrix.Identity(4)
        b[rest_contract.REST_SCALE_PROP] = [v for row in (step @ prev_m) for v in row]
        b[BONE_PENDING_PROP] = True
        if name in roblox:
            roblox_names.append(rest_contract.channel_name(b))
    ao.data.bones[source][APPLIED_PROP] = round(float(total), 6)

    exported_bones = {b.name: b for b in ao.data.bones if b.name in exported}
    main = rest_contract._main_root(exported_bones)
    pivot_local = None
    root_name = None
    if main is not None and rest_contract.is_stamped(main):
        pivot_local = list(to_matrix(main["transform"]).inverted() @ pivot_rbx)
        root_name = rest_contract.channel_name(main)
    entries = pending(ao)
    entries.append(
        {
            "id": uuid.uuid4().hex[:12],
            "kind": "set",
            "root": root_name,
            "source": source,
            "factor": k,
            "pivot": pivot_local,  # in the rig root part's frame (studs)
            "channels": roblox_names,
            "parts": parts,
            "bones": roblox + part_joints,
        }
    )
    ao[PENDING_PROP] = json.dumps(entries)
    return {
        "bones": len(roblox),
        "meshes": len(parts),
        "keys": 0,
        "roblox": roblox,
        "helpers": helpers,
        "parts": parts,
    }
