"""A bone with Inherit Rotation off survives Blender -> Studio -> Blender.

Roblox joints always inherit their parent's rotation, so the exporter writes a
counter-rotation into the bone's pose. Importing that pose back must give the
same Blender motion, not apply the counter-rotation a second time.
"""
import math
import unittest

import bpy
from mathutils import Matrix

from ..animation.serialization import serialize
from ..rig import rest_contract


class TestInheritRotationRoundTrip(unittest.TestCase):
    def setUp(self):
        if bpy.context.object and bpy.context.object.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        bpy.ops.object.select_all(action="SELECT")
        bpy.ops.object.delete(use_global=False)
        for action in list(bpy.data.actions):
            bpy.data.actions.remove(action)
        bpy.ops.object.armature_add(enter_editmode=True)
        rig = bpy.context.object
        rig.name = "InheritRig"
        eb = rig.data.edit_bones
        eb[0].name = "Root"
        handle = eb.new("Handle")
        handle.head, handle.tail, handle.parent = (0, 0, 1), (0, 0.5, 1), eb["Root"]
        sight = eb.new("Sight")
        sight.head, sight.tail, sight.parent = (0, 0.3, 1.8), (0, 0.3, 2.2), handle
        sight.use_inherit_rotation = False
        normal = eb.new("Mag")
        normal.head, normal.tail, normal.parent = (0, 0.4, 0.6), (0, 0.4, 0.3), handle
        bpy.ops.object.mode_set(mode="OBJECT")
        for b in rig.data.bones:
            rest_contract.stamp_from_blender_rest(b, "Motor6D")
        scene = bpy.context.scene
        scene.frame_start, scene.frame_end = 0, 10
        scene.render.fps, scene.render.fps_base = 30, 1.0
        pb = rig.pose.bones
        for name in ("Handle", "Sight", "Mag"):
            pb[name].rotation_mode = "XYZ"
        for frame, a, s in ((0, 0.0, 0.0), (5, 35.0, -10.0), (10, -20.0, 15.0)):
            pb["Handle"].rotation_euler = (math.radians(a), 0.0, math.radians(a / 2))
            pb["Handle"].keyframe_insert("rotation_euler", frame=frame)
            pb["Sight"].rotation_euler = (0.0, math.radians(s), 0.0)
            pb["Sight"].location = (0.0, s / 100.0, 0.0)
            pb["Sight"].keyframe_insert("rotation_euler", frame=frame)
            pb["Sight"].keyframe_insert("location", frame=frame)
            pb["Mag"].location = (0.0, -s / 100.0, 0.0)
            pb["Mag"].keyframe_insert("location", frame=frame)
        for curve in rig.animation_data.action.fcurves if hasattr(rig.animation_data.action, "fcurves") else []:
            for key in curve.keyframe_points:
                key.interpolation = "LINEAR"
        self.rig = rig

    def world(self, frame):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        return {n: self.rig.pose.bones[n].matrix.copy() for n in ("Handle", "Sight", "Mag")}

    def test_studio_pose_comes_back_unchanged(self):
        from ..server import requests as rq

        rig = self.rig
        before = {f: self.world(f) for f in (0, 3, 5, 8, 10)}
        payload = serialize(rig)
        payload["name"] = "InheritRT"
        payload.setdefault("export_info", {"fps": 30})
        rq.execute_import_animation("inherit-rt", payload, rig.name)
        ok, msg = rq.pending_responses.pop("inherit-rt", (True, None))
        self.assertTrue(ok, msg)
        self.assertEqual(rig.animation_data.action.name, "InheritRT")
        bad = []
        for frame, mats in before.items():
            after = self.world(frame)
            for name, m0 in mats.items():
                m1 = after[name]
                diff = max(abs(m0[r][c] - m1[r][c]) for r in range(4) for c in range(4))
                if diff > 1e-3:
                    rot = math.degrees(m0.to_quaternion().rotation_difference(m1.to_quaternion()).angle)
                    bad.append(f"{name}@{frame}: {diff:.3f} (rot {rot:.1f} deg, pos {(m0.translation - m1.translation).length:.3f})")
        self.assertFalse(bad, "; ".join(bad))

    def test_export_writes_the_counter_rotation_once(self):
        """Exported Sight stays put in world while the Handle turns (Roblox inherits)."""
        rig = self.rig
        payload = serialize(rig)
        frames = {round(row["t"] * 30): row["kf"] for row in payload["kfs"]}
        self.assertIn("Sight", frames[5])
        self.assertIn("Handle", frames[5])


class TestConstrainedBonesRoundTrip(unittest.TestCase):
    """Bones still driven by a helper's constraint come back where Studio has them."""

    def setUp(self):
        if bpy.context.object and bpy.context.object.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        bpy.ops.object.select_all(action="SELECT")
        bpy.ops.object.delete(use_global=False)
        for action in list(bpy.data.actions):
            bpy.data.actions.remove(action)
        bpy.ops.object.armature_add(enter_editmode=True)
        rig = bpy.context.object
        rig.name = "ConstraintRig"
        eb = rig.data.edit_bones
        eb[0].name = "Root"

        def bone(name, head, tail, parent, deform=True):
            b = eb.new(name)
            b.head, b.tail, b.parent, b.use_deform = head, tail, eb[parent], deform
            return b

        bone("Handle", (0, 0, 1), (0, 0.5, 1), "Root")
        bone("Mag", (0, 0.4, 0.6), (0, 0.4, 0.3), "Handle")
        bone("Bolt", (0, 0.2, 1.2), (0, 0.6, 1.2), "Handle")
        bone("Arm", (1, 0, 1), (1, 0.6, 1), "Root")
        bone("Hand", (1, 0.6, 1), (1, 1.0, 1), "Arm")
        bone("CTRL_Mag", (0, 0.4, 0.0), (0, 0.4, -0.3), "Root", deform=False)
        bone("CTRL_Bolt", (0.5, 0, 1.6), (0.5, 0, 2.0), "Root", deform=False)
        bone("IK_Hand", (1, 1.0, 1), (1, 1.0, 1.3), "Root", deform=False)
        bpy.ops.object.mode_set(mode="OBJECT")
        for name in ("Root", "Handle", "Mag", "Bolt", "Arm", "Hand"):
            rest_contract.stamp_from_blender_rest(rig.data.bones[name], "Motor6D")
        pb = rig.pose.bones
        con = pb["Mag"].constraints.new("COPY_LOCATION")
        con.target, con.subtarget, con.use_offset = rig, "CTRL_Mag", True
        con.target_space = con.owner_space = "LOCAL"
        child = pb["Bolt"].constraints.new("CHILD_OF")
        child.target, child.subtarget = rig, "CTRL_Bolt"
        child.inverse_matrix = (rig.matrix_world @ rig.data.bones["CTRL_Bolt"].matrix_local).inverted()
        ik = pb["Hand"].constraints.new("IK")
        ik.target, ik.subtarget, ik.chain_count = rig, "IK_Hand", 2
        scene = bpy.context.scene
        scene.frame_start, scene.frame_end = 0, 10
        scene.render.fps, scene.render.fps_base = 30, 1.0
        for name in ("Handle", "CTRL_Bolt"):
            pb[name].rotation_mode = "XYZ"
        for frame, v in ((0, 0.0), (5, 1.0), (10, -0.5)):
            pb["Handle"].rotation_euler = (math.radians(20 * v), 0.0, 0.0)
            pb["Handle"].keyframe_insert("rotation_euler", frame=frame)
            pb["CTRL_Mag"].location = (0.0, 0.3 * v, 0.0)
            pb["CTRL_Mag"].keyframe_insert("location", frame=frame)
            pb["CTRL_Bolt"].rotation_euler = (0.0, 0.0, math.radians(30 * v))
            pb["CTRL_Bolt"].keyframe_insert("rotation_euler", frame=frame)
            pb["IK_Hand"].location = (0.0, 0.0, 0.2 * v)
            pb["IK_Hand"].keyframe_insert("location", frame=frame)
            pb["Mag"].location = (0.0, 0.0, 0.05 * v)
            pb["Mag"].keyframe_insert("location", frame=frame)
        self.rig = rig

    def test_constrained_bones_come_back(self):
        from ..server import requests as rq

        rig = self.rig
        names = ("Handle", "Mag", "Bolt")

        def world(frame):
            bpy.context.scene.frame_set(frame)
            return {n: rig.pose.bones[n].matrix.copy() for n in names}

        before = {f: world(f) for f in (0, 3, 5, 8, 10)}
        payload = serialize(rig)
        payload["name"] = "ConstraintRT"
        payload.setdefault("export_info", {"fps": 30})
        # Studio has no helpers: they stay at rest in the imported action
        rq.execute_import_animation("constraint-rt", payload, rig.name)
        ok, msg = rq.pending_responses.pop("constraint-rt", (True, None))
        self.assertTrue(ok, msg)
        for helper in ("CTRL_Mag", "CTRL_Bolt", "IK_Hand"):
            rig.pose.bones[helper].matrix_basis = Matrix.Identity(4)
        bad = []
        for frame, mats in before.items():
            after = world(frame)
            for name, m0 in mats.items():
                diff = max(abs(m0[r][c] - after[name][r][c]) for r in range(4) for c in range(4))
                if diff > 1e-3:
                    bad.append(f"{name}@{frame}: {diff:.3f}")
        self.assertFalse(bad, "; ".join(bad))
