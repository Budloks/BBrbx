"""BB fork: rest contract tests.

A bone added in Blender must export exactly against the Roblox rest frame Studio
reports, whatever its Blender roll/orientation is (no fixed axis guessing).
"""
import math
import unittest

import bpy
from mathutils import Euler, Matrix, Vector

from ..animation.serialization import serialize
from ..core.constants import get_transform_to_blender
from ..core.utils import cf_to_mat, mat_to_cf
from ..rig import rest_contract


def _entry_matrix(entry):
    if isinstance(entry, dict):
        comps = entry.get("components")
    elif isinstance(entry, list) and entry and isinstance(entry[0], list):
        comps = entry[0]
    else:
        comps = entry
    return cf_to_mat(comps)


class TestRestContract(unittest.TestCase):
    def setUp(self):
        for obj in list(bpy.data.objects):
            bpy.data.objects.remove(obj, do_unlink=True)
        for arm in list(bpy.data.armatures):
            bpy.data.armatures.remove(arm)
        for act in list(bpy.data.actions):
            bpy.data.actions.remove(act)

        data = bpy.data.armatures.new("RCArm")
        self.ao = bpy.data.objects.new("RCArm", data)
        bpy.context.scene.collection.objects.link(self.ao)
        # A moved/rotated armature object must not change the export.
        self.ao.location = (3.0, -2.0, 10.0)
        self.ao.rotation_euler = (0.0, 0.0, 0.7)
        bpy.context.view_layer.objects.active = self.ao
        bpy.ops.object.mode_set(mode="EDIT")
        root = data.edit_bones.new("Root")
        root.head, root.tail = (0, 0, 0), (0, 0, 0.5)
        child = data.edit_bones.new("Limb")
        child.head, child.tail = (0.3, 0.2, 0.4), (0.9, 0.5, 0.6)
        child.roll = 1.1
        child.parent = root
        bpy.ops.object.mode_set(mode="OBJECT")

        # The root behaves like an imported PrimaryPart: stamped from its own rest.
        rest_contract.stamp_from_blender_rest(data.bones["Root"], "Root")

    def _studio_payload(self, offset: Matrix):
        t2b = get_transform_to_blender()
        root_t = rest_contract.joint_frame(self.ao.data.bones["Root"])
        limb_j = t2b.inverted() @ self.ao.data.bones["Limb"].matrix_local @ offset
        return {
            "root": "Root",
            "bones": {},
            "frames": {
                "Root": {"kind": "Root", "part": mat_to_cf(Matrix())},
                "Limb": {"kind": "Bone", "parent": "Root", "part": mat_to_cf(root_t.inverted() @ limb_j)},
            },
        }, limb_j

    def _pose_and_export(self, payload):
        bpy.context.view_layer.objects.active = self.ao
        bpy.ops.object.mode_set(mode="POSE")
        pb = self.ao.pose.bones["Limb"]
        pb.rotation_mode = "XYZ"
        pb.rotation_euler = (0.0, 0.0, 0.0)
        pb.location = (0, 0, 0)
        pb.keyframe_insert("rotation_euler", frame=1)
        pb.keyframe_insert("location", frame=1)
        pb.rotation_euler = (0.3, -0.2, 0.5)
        pb.location = (0.05, 0.1, -0.02)
        pb.keyframe_insert("rotation_euler", frame=10)
        pb.keyframe_insert("location", frame=10)
        bpy.context.scene.frame_start, bpy.context.scene.frame_end = 1, 10
        bpy.context.scene.frame_set(10)
        t2b = get_transform_to_blender()
        b_rest = t2b.inverted() @ pb.bone.matrix_local
        b_pose = t2b.inverted() @ pb.matrix
        data = serialize(self.ao, target_bone_rest=payload)
        last = max(data["kfs"], key=lambda k: k["t"])
        return _entry_matrix(last["kf"]["Limb"]), b_rest, b_pose

    def _assert_exact(self, offset: Matrix):
        payload, s_rest = self._studio_payload(offset)
        adopted = rest_contract.adopt_from_target_rest(self.ao, payload)
        self.assertIn("Limb", adopted)
        exported, b_rest, b_pose = self._pose_and_export(payload)
        # Studio posed frame = blender pose delta carried onto the Studio rest frame
        expected = s_rest.inverted() @ b_pose @ b_rest.inverted() @ s_rest
        for r in range(3):
            for c in range(4):
                self.assertAlmostEqual(exported[r][c], expected[r][c], places=3)

    def test_identity_frames(self):
        self._assert_exact(Matrix())

    def test_fbx_default_axes_frame(self):
        # Default Blender FBX bone axes land in Roblox turned 180 deg about Y
        self._assert_exact(Matrix.Rotation(math.pi, 4, "Y"))

    def test_arbitrary_frame_offset(self):
        self._assert_exact(Euler((0.4, -1.2, 2.0)).to_matrix().to_4x4() @ Matrix.Translation(Vector((0.0, 0.0, 0.0))))

    def test_stamped_import_bones_untouched(self):
        payload, _ = self._studio_payload(Matrix())
        root = self.ao.data.bones["Root"]
        root.pop(rest_contract.ADOPTED_PROP, None)  # behave like an imported bone
        before = [list(r) for r in root["nicetransform"]]
        rest_contract.adopt_from_target_rest(self.ao, payload)
        self.assertEqual(before, [list(r) for r in root["nicetransform"]])

    def test_rig_layout_reports_new_bone(self):
        # a bone that carries a mesh moves a part, so it goes to Roblox
        bpy.ops.mesh.primitive_cube_add(size=0.1)
        part = bpy.context.object
        part.parent, part.parent_type, part.parent_bone = self.ao, "BONE", "Limb"
        layout = rest_contract.rig_layout(self.ao)
        names = {c["name"]: c for c in layout["channels"]}
        self.assertIn("Limb", names)
        self.assertEqual(names["Limb"]["parent"], "Root")
        self.assertFalse(names["Limb"]["stamped"])


if __name__ == "__main__":
    unittest.main()
