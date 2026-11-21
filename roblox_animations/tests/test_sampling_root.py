"""Imported roots store their rest transforms in Roblox coordinates."""
import unittest

import bpy
from mathutils import Matrix

from ..animation.sampling import serialize_animation_state
from ..core.constants import get_transform_to_blender
from ..core.utils import cf_to_mat, mat_to_cf


class TestImportedRootSampling(unittest.TestCase):
    def test_scene_placement_is_not_exported_as_root_motion(self):
        if bpy.context.object and bpy.context.object.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        bpy.ops.object.add(type='ARMATURE', enter_editmode=True)
        rig = bpy.context.object
        data = rig.data
        rest = Matrix.Translation((-25, 3, 12)) @ Matrix.Rotation(0.4, 4, 'Y')
        bone = data.edit_bones.new('Root')
        bone.matrix = get_transform_to_blender() @ rest
        bone.length = 0.25
        for key, matrix in [('transform', rest), ('transform1', Matrix.Identity(4)),
                            ('nicetransform', Matrix.Identity(4))]:
            bone[key] = [list(row) for row in matrix]
        bone['rbx_source_name'] = 'Root'
        bpy.ops.object.mode_set(mode='OBJECT')
        try:
            bpy.context.view_layer.update()
            state = serialize_animation_state(rig)
            actual = cf_to_mat(state.get('Root', mat_to_cf(Matrix.Identity(4))))
            self.assertLess(max(abs(x-y) for ra,rb in zip(actual,Matrix.Identity(4))
                                for x,y in zip(ra,rb)), 1e-5)
            rig.pose.bones['Root'].location = (0.2, -0.1, 0.3)
            bpy.context.view_layer.update()
            actual = cf_to_mat(serialize_animation_state(rig)['Root'])
            expected = rest.inverted() @ get_transform_to_blender().inverted() @ rig.pose.bones['Root'].matrix
            self.assertLess(max(abs(x-y) for ra,rb in zip(actual,expected)
                                for x,y in zip(ra,rb)), 1e-5)
        finally:
            bpy.data.objects.remove(rig, do_unlink=True)
            bpy.data.armatures.remove(data)

    def test_identity_pose_from_studio_keeps_root_on_its_rest(self):
        """Studio -> Blender -> Studio must not move an offset root (TAC50: -3.6 studs)."""
        from ..server import requests as rq

        if bpy.context.object and bpy.context.object.mode != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        bpy.ops.object.add(type='ARMATURE', enter_editmode=True)
        rig = bpy.context.object
        rig.name = 'RootOffsetRig'
        data = rig.data
        rest = Matrix.Translation((0, 3.6, 0))
        bone = data.edit_bones.new('Root')
        bone.matrix = get_transform_to_blender() @ rest
        bone.length = 0.25
        for key, matrix in [('transform', rest), ('transform1', Matrix.Identity(4)),
                            ('nicetransform', Matrix.Identity(4))]:
            bone[key] = [list(row) for row in matrix]
        bone['rbx_source_name'] = 'Root'
        bone['is_transformable'] = True
        bpy.ops.object.mode_set(mode='OBJECT')
        try:
            identity = mat_to_cf(Matrix.Identity(4))
            payload = {
                'name': 'RootTest',
                't': 1 / 30,
                'kfs': [{'t': 0, 'kf': {'Root': identity}}, {'t': 1 / 30, 'kf': {'Root': identity}}],
                'export_info': {'fps': 30},
            }
            rq.execute_import_animation('root-test', payload, rig.name)
            ok, _ = rq.pending_responses.pop('root-test', (True, None))
            self.assertTrue(ok)
            self.assertEqual(rig.animation_data.action.name, 'RootTest')
            bpy.context.scene.frame_set(0)
            bpy.context.view_layer.update()
            pb = rig.pose.bones['Root']
            self.assertLess((pb.matrix.to_translation() - pb.bone.matrix_local.to_translation()).length, 1e-4)
            state = serialize_animation_state(rig)
            self.assertNotIn('Root', state)
        finally:
            bpy.data.objects.remove(rig, do_unlink=True)
            bpy.data.armatures.remove(data)
