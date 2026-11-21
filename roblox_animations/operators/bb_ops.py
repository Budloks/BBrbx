# pyright: reportAttributeAccessIssue=false
"""BB fork operators: Export Deform FBX, Rig Check, per-bone export toggle."""

import bpy

from ..rig import rest_contract
from ..rig.deform_export import default_fbx_path, export_deform_fbx


def _armature(context):
    settings = getattr(context.scene, "rbx_anim_settings", None)
    name = getattr(settings, "rbx_anim_armature", "") if settings else ""
    if name:
        obj = bpy.data.objects.get(name)
        if obj is not None and obj.type == "ARMATURE":
            return obj
    obj = context.active_object
    if obj is not None and obj.type == "ARMATURE":
        return obj
    if obj is not None and obj.type == "MESH":
        for m in obj.modifiers:
            if m.type == "ARMATURE" and m.object is not None:
                return m.object
    armatures = [o for o in context.scene.objects if o.type == "ARMATURE"]
    return armatures[0] if len(armatures) == 1 else None


class RBXBB_OT_export_deform(bpy.types.Operator):
    bl_idname = "rbxbb.export_deform"
    bl_label = "Export Deform FBX"
    bl_description = (
        "Export the skinned meshes of this armature as an FBX ready for Roblox: "
        "armature at origin, Roblox bone names and axes, only the bones the meshes use. "
        "Import it in Studio, then press 'Append deform mesh'"
    )
    bl_options = {"REGISTER"}

    only_selected: bpy.props.BoolProperty(
        name="Only selected meshes", default=False,
        description="Export only the selected skinned meshes instead of all of them",
    )
    filepath: bpy.props.StringProperty(subtype="FILE_PATH")

    @classmethod
    def poll(cls, context):
        return _armature(context) is not None

    def invoke(self, context, event):
        if not self.filepath:
            self.filepath = default_fbx_path(_armature(context))
        context.window_manager.fileselect_add(self)
        return {"RUNNING_MODAL"}

    def execute(self, context):
        ao = _armature(context)
        try:
            result = export_deform_fbx(ao, bpy.path.abspath(self.filepath or default_fbx_path(ao)), self.only_selected)
        except Exception as exc:
            self.report({"ERROR"}, str(exc))
            return {"CANCELLED"}
        msg = f"Exported {len(result['bones'])} bones to {result['file']}"
        if result["unweighted_vertices"]:
            msg += f" ({result['unweighted_vertices']} vertices have no weights!)"
            self.report({"WARNING"}, msg)
        else:
            self.report({"INFO"}, msg + ". In Studio: Import 3D, then 'Append deform mesh'.")
        context.scene["rbx_bb_last_deform_export"] = result["file"]
        return {"FINISHED"}


class RBXBB_OT_rig_check(bpy.types.Operator):
    bl_idname = "rbxbb.rig_check"
    bl_label = "Rig Check"
    bl_description = "Look for things that would break exporting this rig to Roblox"

    @classmethod
    def poll(cls, context):
        return _armature(context) is not None

    def execute(self, context):
        from ..server.bb_routes import rig_check

        result = rig_check(_armature(context))
        lines = [("ERROR", p) for p in result["problems"]] + [("INFO", i) for i in result["info"]]
        context.scene["rbx_bb_rig_check"] = "\n".join(f"{kind}:{text}" for kind, text in lines) or "OK:Rig looks good"
        if result["problems"]:
            self.report({"WARNING"}, f"{len(result['problems'])} problem(s) found, see the BB panel")
        else:
            self.report({"INFO"}, "Rig looks good")
        return {"FINISHED"}


class RBXBB_OT_toggle_bone_export(bpy.types.Operator):
    bl_idname = "rbxbb.toggle_bone_export"
    bl_label = "Export This Bone"
    bl_description = (
        "Choose whether the active bone becomes a Roblox joint. By default bones from "
        "Roblox and bones that deform a mesh are exported; helper/IK/control bones are not"
    )

    mode: bpy.props.EnumProperty(
        items=[("ON", "Always", ""), ("OFF", "Never", ""), ("AUTO", "Automatic", "")],
        default="AUTO",
    )

    @classmethod
    def poll(cls, context):
        ao = _armature(context)
        return ao is not None and ao.data.bones.active is not None

    def execute(self, context):
        bone = _armature(context).data.bones.active
        if self.mode == "AUTO":
            bone.pop(rest_contract.EXPORT_PROP, None)
        else:
            bone[rest_contract.EXPORT_PROP] = self.mode == "ON"
        return {"FINISHED"}


class RBXBB_OT_scale_branch(bpy.types.Operator):
    bl_idname = "rbxbb.scale_branch"
    bl_label = "Scale Bone Children"
    bl_description = (
        "Make everything under the active bone bigger or smaller (e.g. a weapon under its Handle) "
        "and keep the animations: rests, meshes and location keys of the children scale, the bone "
        "itself keeps its keys. Synchronise in Studio afterwards to scale the parts there too"
    )
    bl_options = {"REGISTER", "UNDO"}

    factor: bpy.props.FloatProperty(name="Scale", default=1.25, min=0.01, max=100.0, soft_min=0.1, soft_max=10.0)
    pivot: bpy.props.EnumProperty(
        name="Around",
        items=[
            ("JOINT", "Joint", "Where the bone hangs on its parent (the grip stays put for a Handle at the grip)"),
            ("CURSOR", "3D cursor", "Put the 3D cursor where the weapon should stay put, e.g. on the grip"),
        ],
        default="JOINT",
    )
    scale_actions: bpy.props.BoolProperty(name="Scale animations", default=True)

    @classmethod
    def poll(cls, context):
        ao = _armature(context)
        bone = ao.data.bones.active if ao is not None else None
        return bone is not None and len(bone.children) > 0

    def invoke(self, context, event):
        return context.window_manager.invoke_props_dialog(self)

    def draw(self, context):
        layout = self.layout
        ao = _armature(context)
        bone = ao.data.bones.active
        from ..rig.rescale import branch_bones, rig_actions

        layout.label(text=f"{bone.name} and {len(branch_bones(ao, bone.name))} bones under it")
        layout.prop(self, "factor")
        layout.prop(self, "pivot")
        layout.prop(self, "scale_actions", text=f"Scale {len(rig_actions(ao))} animation(s)")

    def execute(self, context):
        from ..rig.rescale import scale_branch

        ao = _armature(context)
        bone = ao.data.bones.active
        pivot = None
        if self.pivot == "CURSOR":
            pivot = ao.matrix_world.inverted() @ context.scene.cursor.location
        try:
            result = scale_branch(ao, bone.name, self.factor, pivot, self.scale_actions)
        except ValueError as exc:
            self.report({"ERROR"}, str(exc))
            return {"CANCELLED"}
        msg = (
            f"Scaled {result['bones']} bones x{self.factor:g}, {result['meshes']} mesh(es), "
            f"{result['keys']} keys in {len(result['actions'])} action(s). Synchronise in Studio next"
        )
        if result["mixed_vertices"]:
            msg += f" ({result['mixed_vertices']} vertices also weighted outside were left)"
        if result["helpers"]:
            msg += f". Helpers scaled too: {', '.join(result['helpers'][:4])}"
        if result["outside"]:
            msg += f". Check these, they follow bones outside: {', '.join(result['outside'][:3])}"
        self.report({"INFO"}, msg)
        return {"FINISHED"}


CLASSES = (RBXBB_OT_export_deform, RBXBB_OT_rig_check, RBXBB_OT_toggle_bone_export, RBXBB_OT_scale_branch)
