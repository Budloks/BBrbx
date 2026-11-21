"""Scale with children: a weapon under its Handle grows, its animations follow."""
import json
import math
import unittest

import bpy

from ..animation.serialization import serialize
from ..rig import rescale, rest_contract


class TestScaleBranch(unittest.TestCase):
    def setUp(self):
        if bpy.context.object and bpy.context.object.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        bpy.ops.object.select_all(action="SELECT")
        bpy.ops.object.delete(use_global=False)
        for action in list(bpy.data.actions):
            bpy.data.actions.remove(action)
        bpy.ops.object.armature_add(enter_editmode=True)
        rig = bpy.context.object
        rig.name = "ScaleRig"
        bones = rig.data.edit_bones
        root = bones[0]
        root.name = "Root"
        hand = bones.new("Hand")
        hand.head, hand.tail, hand.parent = (1, 0, 1), (1, 0, 1.5), root
        handle = bones.new("Handle")
        handle.head, handle.tail, handle.parent = (0, 0, 1), (0, 0.5, 1), root
        mag = bones.new("Mag")
        mag.head, mag.tail, mag.parent = (0, 0.4, 0.6), (0, 0.4, 0.3), handle
        ctrl = bones.new("CTRL_Mag")  # helper under Root that only moves Mag
        ctrl.head, ctrl.tail, ctrl.parent = (0, 0.4, 0.0), (0, 0.4, 0.3), root
        ctrl.use_deform = False
        bpy.ops.object.mode_set(mode="OBJECT")
        for name in ("Root", "Hand", "Handle", "Mag"):
            rest_contract.stamp_from_blender_rest(rig.data.bones[name], "Motor6D")
        con = rig.pose.bones["Mag"].constraints.new("COPY_LOCATION")
        con.target, con.subtarget = rig, "CTRL_Mag"
        con.use_offset = True
        con.target_space = con.owner_space = "LOCAL"
        # a part mesh riding on the Handle
        bpy.ops.mesh.primitive_cube_add(size=0.2, location=(0, 0.2, 1))
        part = bpy.context.object
        part.name = "HandlePart"
        child = part.constraints.new("CHILD_OF")
        child.target, child.subtarget = rig, "Handle"
        child.inverse_matrix = (rig.matrix_world @ rig.data.bones["Handle"].matrix_local).inverted()
        bpy.context.view_layer.objects.active = rig
        scene = bpy.context.scene
        scene.frame_start, scene.frame_end = 1, 11
        pb = rig.pose.bones
        for frame, z in ((1, 0.0), (11, 0.3)):
            pb["Mag"].location = (0, z, 0)
            pb["Mag"].keyframe_insert("location", frame=frame)
            pb["CTRL_Mag"].location = (0, z, 0)
            pb["CTRL_Mag"].keyframe_insert("location", frame=frame)
            pb["Handle"].location = (z, 0, 0)
            pb["Handle"].keyframe_insert("location", frame=frame)
            pb["Hand"].rotation_mode = pb["Handle"].rotation_mode = "XYZ"
            pb["Handle"].rotation_euler = (0, 0, math.radians(40 * z))
            pb["Handle"].keyframe_insert("rotation_euler", frame=frame)
        self.rig, self.part = rig, part

    def poses(self):
        out = {}
        for row in serialize(self.rig)["kfs"]:
            for name, pose in row["kf"].items():
                out[(round(row["t"], 4), name)] = pose[0]
        return out

    def test_branch_scales_and_root_keeps_its_motion(self):
        before = self.poses()
        self.rig.data.pose_position = "REST"
        bpy.context.view_layer.update()
        part_before = self.part.matrix_world.copy()
        self.rig.data.pose_position = "POSE"
        result = rescale.scale_branch(self.rig, "Handle", 2.0)
        self.assertIn("CTRL_Mag", result["helpers"])
        after = self.poses()
        self.assertEqual(before.keys(), after.keys())
        for (t, name), c0 in before.items():
            c1 = after[(t, name)]
            k = 2.0 if name in ("Mag", "CTRL_Mag") else 1.0
            for i in range(3):
                self.assertAlmostEqual(c1[i], c0[i] * k, places=4, msg=(name, t, i))
            for i in range(3, 12):
                self.assertAlmostEqual(c1[i], c0[i], places=4, msg=(name, t, i))
        self.rig.data.pose_position = "REST"
        bpy.context.view_layer.update()
        self.assertAlmostEqual(self.part.matrix_world.to_scale()[0], part_before.to_scale()[0] * 2, places=4)
        self.rig.data.pose_position = "POSE"

    def test_layout_reports_scale_until_studio_applies_it(self):
        rescale.scale_branch(self.rig, "Handle", 1.5)
        layout = rest_contract.rig_layout(self.rig)
        self.assertEqual([e["root"] for e in layout["rescale"]], ["Handle"])
        self.assertEqual(layout["rescale"][0]["factor"], 1.5)
        self.assertFalse([c["name"] for c in layout["channels"] if c["rest_changed"]])
        # Studio's (old) rest must not overwrite the scaled stamps meanwhile
        mag = self.rig.data.bones["Mag"]
        stamped = [list(row) for row in mag["transform"]]
        self.rig.data.bones["Mag"][rest_contract.ADOPTED_PROP] = True
        adopted = rest_contract.adopt_from_target_rest(
            self.rig, {"root": "Root", "frames": {"Root": {"part": [0] * 3 + [1, 0, 0, 0, 1, 0, 0, 0, 1]},
                                                   "Mag": {"part": [0] * 3 + [1, 0, 0, 0, 1, 0, 0, 0, 1]}}})
        self.assertNotIn("Mag", adopted)
        self.assertEqual([list(row) for row in mag["transform"]], stamped)
        rescale.acknowledge(self.rig, [e["id"] for e in layout["rescale"]])
        self.assertEqual(rescale.pending(self.rig), [])
        self.assertNotIn(rescale.BONE_PENDING_PROP, mag)
        self.assertNotIn(rescale.PENDING_PROP, self.rig)


class TestScaleFromAnimation(unittest.TestCase):
    """Akimbo: one pistol keyed to 1.2x, the other held at 2x; Synchronise makes both real."""

    def setUp(self):
        if bpy.context.object and bpy.context.object.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        bpy.ops.object.select_all(action="SELECT")
        bpy.ops.object.delete(use_global=False)
        for action in list(bpy.data.actions):
            bpy.data.actions.remove(action)
        bpy.ops.object.armature_add(enter_editmode=True)
        rig = bpy.context.object
        rig.name = "AkimboRig"
        eb = rig.data.edit_bones
        eb[0].name = "Root"
        for gun, x in (("GunA", 1.0), ("GunB", -1.0)):
            g = eb.new(gun)
            g.head, g.tail, g.parent = (x, 0, 1), (x, 0.5, 1), eb["Root"]
            s = eb.new(gun + "_Slide")
            s.head, s.tail, s.parent = (x, 0.3, 1.2), (x, 0.6, 1.2), g
        bpy.ops.object.mode_set(mode="OBJECT")
        for b in rig.data.bones:
            rest_contract.stamp_from_blender_rest(b, "Motor6D")
        scene = bpy.context.scene
        scene.frame_start, scene.frame_end = 1, 11
        pb = rig.pose.bones
        for frame, y in ((1, 0.0), (11, -0.2)):
            for gun in ("GunA", "GunB"):
                pb[gun + "_Slide"].location = (0, y, 0)
                pb[gun + "_Slide"].keyframe_insert("location", frame=frame)
        # GunA: the scale was keyed (someone animated it up to 1.2)
        for frame, s in ((1, 1.0), (6, 1.2), (11, 1.1)):
            pb["GunA"].scale = (s, s, s)
            pb["GunA"].keyframe_insert("scale", frame=frame)
        # GunB: just set to 2x, not keyed
        pb["GunB"].scale = (2.0, 2.0, 2.0)
        self.rig = rig

    def slide(self):
        out = {}
        for row in serialize(self.rig)["kfs"]:
            for name in ("GunA_Slide", "GunB_Slide", "GunA", "GunB"):
                if name in row["kf"]:
                    out[(round(row["t"], 4), name)] = row["kf"][name][0][:3]
        return out

    def test_each_gun_gets_its_biggest_scale(self):
        self.assertEqual(
            {k: round(v, 4) for k, v in rescale.scale_from_poses(self.rig).items()},
            {"GunA": 1.2, "GunB": 2.0},
        )
        before = self.slide()
        done = rescale.apply_pose_scale(self.rig)
        self.assertEqual({d["bone"]: d["factor"] for d in done}, {"GunA": 1.2, "GunB": 2.0})
        after = self.slide()
        for (t, name), pos in before.items():
            k = {"GunA_Slide": 1.2, "GunB_Slide": 2.0}.get(name, 1.0)
            if (t, name) not in after:
                self.assertNotIn("Slide", name)  # a gun keyed only by scale has no moves left
                continue
            for a, b in zip(pos, after[(t, name)]):
                self.assertAlmostEqual(b, a * k, places=4, msg=(name, t))
        # the scale is now in the rig: no scale keys or pose scale left, nothing more to do
        self.assertEqual(tuple(self.rig.pose.bones["GunB"].scale), (1.0, 1.0, 1.0))
        action = self.rig.animation_data.action
        self.assertFalse([c for c in rescale._all_fcurves(action) if c.data_path.endswith(".scale")])
        self.assertEqual(rescale.scale_from_poses(self.rig), {})
        layout = rest_contract.rig_layout(self.rig)
        self.assertEqual(sorted(e["root"] for e in layout["rescale"]), ["GunA", "GunB"])

    def test_hide_trick_is_left_alone(self):
        pb = self.rig.pose.bones["GunB"]
        pb.scale = (1.0, 1.0, 1.0)
        for frame, s in ((1, 1.0), (5, 0.0), (9, 1.0)):
            pb.scale = (s, s, s)
            pb.keyframe_insert("scale", frame=frame)
        self.assertNotIn("GunB", rescale.scale_from_poses(self.rig))
