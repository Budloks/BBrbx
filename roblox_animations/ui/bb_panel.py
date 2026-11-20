# pyright: reportAttributeAccessIssue=false
"""BB fork sidebar panel + per-action Roblox settings."""

import math

import bpy

from ..rig import rest_contract
from ..operators.bb_ops import _armature

PRIORITIES = [
    ("DEFAULT", "Use Studio setting", "Keep whatever priority Studio/bulk import uses"),
    ("Core", "Core", ""),
    ("Idle", "Idle", ""),
    ("Movement", "Movement", ""),
    ("Action", "Action", ""),
    ("Action2", "Action2", ""),
    ("Action3", "Action3", ""),
    ("Action4", "Action4", ""),
]

LOOP_ITEMS = [
    ("DEFAULT", "Use Studio setting", ""),
    ("ON", "Looped", ""),
    ("OFF", "Not looped", ""),
]


def _roblox_euler_degrees(m3):
    """Rotation as Roblox CFrame:ToEulerAnglesXYZ() would report it."""
    e = m3.to_euler("ZYX")
    return tuple(round(math.degrees(v), 2) for v in (e.x, e.y, e.z))


class RBXBB_PT_panel(bpy.types.Panel):
    bl_label = "RBXMonkey BB"
    bl_idname = "RBXBB_PT_panel"
    bl_category = "RBXMonkey"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context):
        layout = self.layout
        ao = _armature(context)
        if ao is None:
            layout.label(text="Select an armature", icon="INFO")
            return
        layout.label(text=ao.name, icon="ARMATURE_DATA")

        # Rig check
        box = layout.box()
        row = box.row()
        row.label(text="Rig Check", icon="CHECKMARK")
        row.operator("rbxbb.rig_check", text="Run", icon="FILE_REFRESH")
        report = context.scene.get("rbx_bb_rig_check")
        if report:
            for line in str(report).split("\n")[:12]:
                kind, _, text = line.partition(":")
                box.label(text=text, icon="ERROR" if kind == "ERROR" else ("CHECKMARK" if kind == "OK" else "INFO"))

        # Deform export
        box = layout.box()
        box.label(text="Skinned meshes → Roblox", icon="MOD_ARMATURE")
        box.operator("rbxbb.export_deform", icon="EXPORT")
        last = context.scene.get("rbx_bb_last_deform_export")
        if last:
            box.label(text=str(last).replace("\\", "/").split("/")[-1], icon="FILE")
        box.label(text="Studio: Import 3D → Rigging tab → Bind Imported Mesh")
        box.label(text="No skinned meshes? Studio: Push Rig from Blender")

        # Active bone
        bone = ao.data.bones.active
        if bone is not None:
            box = layout.box()
            box.label(text=f"Bone: {bone.name}", icon="BONE_DATA")
            box.label(text=f"Roblox channel: {rest_contract.channel_name(bone)}")
            exported = rest_contract.is_exported_bone(ao, bone)
            stamped = rest_contract.is_stamped(bone) and not rest_contract.is_copied_duplicate(bone)
            box.label(
                text=("Exported" if exported else "Not exported (helper)")
                + (" · exact Roblox frame" if stamped else (" · frame comes from Studio on export" if exported else "")),
                icon="CHECKMARK" if exported else "HIDE_ON",
            )
            row = box.row(align=True)
            for mode, label in (("ON", "Always"), ("AUTO", "Auto"), ("OFF", "Never")):
                op = row.operator("rbxbb.toggle_bone_export", text=label)
                op.mode = mode
            pb = ao.pose.bones.get(bone.name)
            if pb is not None:
                basis = pb.matrix_basis
                if stamped:
                    from ..core.utils import to_matrix

                    nice = to_matrix(bone["nicetransform"])
                    basis = nice @ basis @ nice.inverted()
                rx, ry, rz = _roblox_euler_degrees(basis.to_3x3())
                loc = basis.to_translation()
                box.label(text=f"Roblox rot XYZ: {rx}, {ry}, {rz}")
                box.label(text=f"Roblox pos: {loc.x:.3f}, {loc.y:.3f}, {loc.z:.3f}")

        # Action settings
        ad = ao.animation_data
        action = ad.action if ad else None
        if action is not None:
            box = layout.box()
            box.label(text=f"Action: {action.name}", icon="ACTION")
            box.prop(action, "rbx_bb_name", text="Roblox name")
            box.prop(action, "rbx_bb_priority", text="Priority")
            box.prop(action, "rbx_bb_loop", text="Loop")


def register_action_props():
    bpy.types.Action.rbx_bb_priority = bpy.props.EnumProperty(name="Roblox priority", items=PRIORITIES, default="DEFAULT")
    bpy.types.Action.rbx_bb_loop = bpy.props.EnumProperty(name="Roblox loop", items=LOOP_ITEMS, default="DEFAULT")
    bpy.types.Action.rbx_bb_name = bpy.props.StringProperty(
        name="Roblox name", description="KeyframeSequence name in Studio (empty = action name)", default=""
    )


def unregister_action_props():
    for attr in ("rbx_bb_priority", "rbx_bb_loop", "rbx_bb_name"):
        if hasattr(bpy.types.Action, attr):
            delattr(bpy.types.Action, attr)


CLASSES = (RBXBB_PT_panel,)
