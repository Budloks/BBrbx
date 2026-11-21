# pyright: reportAttributeAccessIssue=false
"""
BB fork: control samples for the automatic import check in Studio.

For a few frames Blender reports, for every exactly-mapped channel, where the
Roblox joint should end up (relative to the rig root) together with the pose
Transform it exported. Studio replays those Transforms on its own rig with
forward kinematics and compares. Nothing is shown when they match; when they
don't, Studio explains why (missing joint, skipped joint, different rest,
flipped axes, ...).
"""

from typing import Any, Dict, List

import bpy

from ..core.constants import get_transform_to_blender
from ..core.utils import mat_to_cf, to_matrix
from ..rig import rest_contract
from .sampling import serialize_animation_state


def _root_bone(ao):
    roots = [
        b for b in ao.data.bones
        if b.parent is None and rest_contract.is_stamped(b)
        and not b.get(rest_contract.ADOPTED_PROP) and not rest_contract.is_copied_duplicate(b)
    ]
    return roots[0] if roots else None


def build_check(ao, max_frames: int = 3) -> Dict[str, Any]:
    root = _root_bone(ao)
    if root is None:
        return {}
    t2b_inv = get_transform_to_blender().inverted()
    root_frame_inv = rest_contract.joint_frame(root).inverted()

    channels = []
    for b in ao.data.bones:
        if b.name == root.name or not rest_contract.is_stamped(b) or rest_contract.is_copied_duplicate(b):
            continue
        if not rest_contract.is_exported_bone(ao, b):
            continue
        channels.append(b.name)
    if not channels:
        return {}

    # Roblox ignores the pose of the root part (no joint drives it), so compare
    # every joint against the root as it is posed now, not against its rest.
    # Otherwise a leftover root offset flags every bone in the rig.
    root_nice_inv = to_matrix(root["nicetransform"]).inverted()
    root_rest_joint = rest_contract.joint_frame(root)

    def root_now_inv():
        posed = t2b_inv @ ao.pose.bones[root.name].matrix @ root_nice_inv
        rest_world = t2b_inv @ root.matrix_local @ root_nice_inv
        # same frame as joint_frame(root) at rest, moved by the root's pose
        return (posed @ rest_world.inverted() @ root_rest_joint).inverted()

    def joint_now(pb, frame_root_inv):
        nice = to_matrix(pb.bone["nicetransform"])
        return frame_root_inv @ (t2b_inv @ pb.matrix @ nice.inverted())

    scene = bpy.context.scene
    original = scene.frame_current
    start, end = int(scene.frame_start), int(scene.frame_end)
    picks: List[int] = sorted({start, (start + end) // 2, end})[:max_frames]

    rest = {}
    for name in channels:
        b = ao.data.bones[name]
        rest[rest_contract.channel_name(b)] = mat_to_cf(root_frame_inv @ rest_contract.joint_frame(b))

    frames = []
    try:
        for frame in picks:
            scene.frame_set(frame)
            poses = serialize_animation_state(ao)
            joints = {}
            frame_root_inv = root_now_inv()
            for name in channels:
                pb = ao.pose.bones[name]
                joints[rest_contract.channel_name(pb.bone)] = mat_to_cf(joint_now(pb, frame_root_inv))
            fps = scene.render.fps / (scene.render.fps_base or 1.0)
            frames.append({"t": (frame - start) / fps, "frame": frame, "joints": joints, "poses": poses})
    finally:
        scene.frame_set(original)

    return {"root": rest_contract.channel_name(root), "rest": rest, "frames": frames}
