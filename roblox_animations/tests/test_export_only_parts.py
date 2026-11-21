"""Only bones that move a part reach Roblox: no toggle, helpers never go."""
import unittest

import bpy

from ..animation.serialization import serialize
from ..rig import rest_contract


class TestExportOnlyParts(unittest.TestCase):
    def setUp(self):
        if bpy.context.object and bpy.context.object.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        bpy.ops.object.select_all(action="SELECT")
        bpy.ops.object.delete(use_global=False)
        for action in list(bpy.data.actions):
            bpy.data.actions.remove(action)
        bpy.ops.object.armature_add(enter_editmode=True)
        rig = bpy.context.object
        rig.name = "PartsRig"
        eb = rig.data.edit_bones
        eb[0].name = "Root"

        def bone(name, head, tail, parent, deform):
            b = eb.new(name)
            b.head, b.tail, b.parent, b.use_deform = head, tail, eb[parent], deform
            return b

        bone("Gun", (0, 0, 1), (0, 0.5, 1), "Root", True)           # from Roblox (stamped)
        bone("CTRL", (0, 0, 2), (0, 0.5, 2), "Root", False)           # helper, moves nothing
        bone("Strap", (0, 0.2, 0.8), (0, 0.2, 0.3), "CTRL", True)    # skinned, under the helper
        bone("Laser", (0, 0.6, 1.1), (0, 0.9, 1.1), "Gun", True)      # new, carries a mesh
        bone("Muzzle", (0, 1.0, 1.0), (0, 1.2, 1.0), "Gun", True)     # new, carries nothing
        bpy.ops.object.mode_set(mode="OBJECT")
        for name in ("Root", "Gun"):
            rest_contract.stamp_from_blender_rest(rig.data.bones[name], "Motor6D")
        # skinned strap
        bpy.ops.mesh.primitive_cylinder_add(radius=0.05, depth=0.5, location=(0, 0.2, 0.55))
        strap = bpy.context.object
        group = strap.vertex_groups.new(name="Strap")
        group.add(list(range(len(strap.data.vertices))), 1.0, "REPLACE")
        strap.modifiers.new("Armature", "ARMATURE").object = rig
        # a part riding on the laser bone, like an imported Roblox part
        bpy.ops.mesh.primitive_cube_add(size=0.1, location=(0, 0.7, 1.1))
        laser_part = bpy.context.object
        con = laser_part.constraints.new("CHILD_OF")
        con.target, con.subtarget = rig, "Laser"
        bpy.context.view_layer.objects.active = rig
        pb = rig.pose.bones
        scene = bpy.context.scene
        scene.frame_start, scene.frame_end = 0, 10
        for frame, v in ((0, 0.0), (10, 0.3)):
            for name in ("Gun", "CTRL", "Strap", "Laser", "Muzzle"):
                pb[name].location = (0.0, v, 0.0)
                pb[name].keyframe_insert("location", frame=frame)
        self.rig = rig

    def test_only_part_movers_are_sent(self):
        exported = rest_contract.exported_bone_names(self.rig)
        self.assertEqual(exported, {"Root", "Gun", "Strap", "Laser"})
        # without Studio every bone stays, as upstream (an FBX turns helpers into Bones)
        sent = {name for row in serialize(self.rig)["kfs"] for name in row["kf"]}
        self.assertIn("Strap", sent)
        self.assertIn("Laser", sent)
        # with Studio connected: a bone that moves no Studio part does not go either
        studio = {"root": "Root", "frames": {"Root": {}, "Gun": {}, "Strap": {}, "Laser": {}}}
        sent = {name for row in serialize(self.rig, studio)["kfs"] for name in row["kf"]}
        self.assertNotIn("CTRL", sent)
        self.assertNotIn("Muzzle", sent)
        self.assertIn("Strap", sent)
        self.assertIn("Laser", sent)
        # the strap hangs under the helper in Blender; in Studio it hangs under Root,
        # so its pose must not carry the helper's offset as if it were a parent
        layout = {c["name"] for c in rest_contract.rig_layout(self.rig)["channels"]}
        self.assertNotIn("CTRL", layout)
        self.assertNotIn("Muzzle", layout)
        self.assertIn("Laser", layout)

    def test_old_toggle_is_ignored(self):
        self.rig.data.bones["CTRL"]["rbx_export"] = True
        self.rig.data.bones["Laser"]["rbx_export"] = False
        self.assertEqual(rest_contract.exported_bone_names(self.rig), {"Root", "Gun", "Strap", "Laser"})
