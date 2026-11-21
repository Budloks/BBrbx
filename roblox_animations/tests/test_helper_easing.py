"""Bones moved by helper bones keep the helper's interpolation on export.

An exported bone often has no keys of its own: it hangs under an animated
control bone, or a constraint copies a helper. Constant helper keys must stay
steps (no one-frame ramp), linear must stay linear and bezier must follow the
curve, while another bone in the same rig plays continuously (so the whole rig
is not simply stepped).
"""
import unittest

import bpy
from mathutils import Matrix

from ..animation.serialization import serialize
from ..core.utils import get_action_fcurves, get_animation_data_action_slot, invalidate_armature_cache


def _stamp(bone):
    bone["is_transformable"] = True
    for prop in ("transform", "transform0", "transform1", "nicetransform"):
        bone[prop] = Matrix.Identity(4)


class TestHelperEasing(unittest.TestCase):
    def setUp(self):
        if bpy.context.object and bpy.context.object.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        bpy.ops.object.select_all(action="SELECT")
        bpy.ops.object.delete(use_global=False)
        bpy.ops.object.armature_add(enter_editmode=True)
        rig = bpy.context.object
        rig.name = "HelperRig"
        bones = rig.data.edit_bones
        root = bones[0]
        root.name = "Root"
        ctrl = bones.new("Ctrl")  # helper: not stamped, does not deform
        ctrl.head, ctrl.tail, ctrl.parent = (0, 0, 1), (0, 0, 2), root
        ctrl.use_deform = False
        arm = bones.new("Arm")
        arm.head, arm.tail, arm.parent = (0, 0, 2), (0, 0, 3), ctrl
        follower = bones.new("Follower")
        follower.head, follower.tail, follower.parent = (1, 0, 1), (1, 0, 2), root
        other = bones.new("Other")
        other.head, other.tail, other.parent = (2, 0, 1), (2, 0, 2), root
        bpy.ops.object.mode_set(mode="OBJECT")
        for name in ("Root", "Arm", "Follower", "Other"):
            _stamp(rig.data.bones[name])
        self.rig = rig
        scene = bpy.context.scene
        scene.frame_start, scene.frame_end = 1, 20
        # A continuously moving exported bone, so the rig is not all-stepped.
        pb = rig.pose.bones["Other"]
        for frame, value in ((1, 0.0), (20, 1.0)):
            pb.location.x = value
            pb.keyframe_insert("location", frame=frame)
        invalidate_armature_cache()

    def key_ctrl(self, interpolation):
        pb = self.rig.pose.bones["Ctrl"]
        for frame, value in ((1, 0.0), (10, 2.0)):
            pb.location.y = value
            pb.keyframe_insert("location", frame=frame, index=1)
        animation = self.rig.animation_data
        for curve in get_action_fcurves(animation.action, slot=get_animation_data_action_slot(animation)):
            if 'pose.bones["Ctrl"]' in curve.data_path:
                for key in curve.keyframe_points:
                    key.interpolation = interpolation
            else:
                for key in curve.keyframe_points:
                    key.interpolation = "LINEAR"

    def poses(self, result, name):
        fps = bpy.context.scene.render.fps / bpy.context.scene.render.fps_base
        out = []
        for key in result["kfs"]:
            pose = key["kf"].get(name)
            if pose is not None:
                out.append((round(1 + key["t"] * fps, 4), pose[0], pose[1]))
        return out

    def moved(self, a, b):
        return max(abs(x - y) for x, y in zip(a[:3], b[:3])) > 1e-4

    def assert_constant_step(self, name):
        result = serialize(self.rig)
        poses = self.poses(result, name)
        self.assertTrue(poses, f"{name} missing from export")
        first = poses[0][1]
        before = [p for p in poses if p[0] < 10 - 1e-4]
        after = [p for p in poses if p[0] >= 10 - 1e-4]
        self.assertTrue(after and self.moved(first, after[0][1]), f"{name} never steps")
        for frame, components, _style in before:
            self.assertFalse(self.moved(first, components), f"{name} ramps before the step (frame {frame})")
        held = [p for p in before if p[0] > 1]
        last_before = before[-1]
        self.assertEqual(last_before[2], "Constant", f"{name} key before the step is not Constant")
        return held

    def test_constant_parent_helper_steps(self):
        self.key_ctrl("CONSTANT")
        self.assert_constant_step("Arm")

    def test_constant_child_of_helper_steps(self):
        constraint = self.rig.pose.bones["Follower"].constraints.new("CHILD_OF")
        constraint.target, constraint.subtarget = self.rig, "Ctrl"
        constraint.inverse_matrix = Matrix.Identity(4)
        self.key_ctrl("CONSTANT")
        self.assert_constant_step("Follower")

    def test_linear_parent_helper_stays_linear(self):
        self.key_ctrl("LINEAR")
        result = serialize(self.rig)
        poses = self.poses(result, "Arm")
        self.assertTrue(poses)
        start = poses[0][1]
        end = [p for p in poses if abs(p[0] - 10) < 1e-4][0][1]
        delta = [b - a for a, b in zip(start[:3], end[:3])]
        for frame, components, style in poses:
            if 1 < frame < 10:
                t = (frame - 1) / 9
                for axis in range(3):
                    self.assertAlmostEqual(components[axis], start[axis] + delta[axis] * t, places=3)
                self.assertNotEqual(style, "Constant")

    def test_bezier_parent_helper_follows_curve(self):
        self.key_ctrl("BEZIER")
        result = serialize(self.rig)
        poses = self.poses(result, "Arm")
        self.assertTrue(poses)
        start = poses[0][1]
        end = [p for p in poses if abs(p[0] - 10) < 1e-4][0][1]
        total = max(abs(b - a) for a, b in zip(start[:3], end[:3]))
        axis = max(range(3), key=lambda i: abs(end[i] - start[i]))
        animation = self.rig.animation_data
        curve = next(c for c in get_action_fcurves(animation.action, slot=get_animation_data_action_slot(animation))
                     if 'pose.bones["Ctrl"]' in c.data_path)
        checked = 0
        for frame, components, _style in poses:
            if 1 < frame < 10:
                expected = curve.evaluate(frame) / 2.0  # 0..1 along the move
                got = (components[axis] - start[axis]) / (end[axis] - start[axis])
                self.assertAlmostEqual(got, expected, places=3)
                checked += 1
        self.assertGreater(total, 1e-3)
        self.assertGreater(checked, 3, "bezier segment was not sampled")
