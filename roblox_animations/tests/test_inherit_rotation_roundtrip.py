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
