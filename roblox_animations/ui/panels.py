"""
BBrbx sidebar UI (View3D > Sidebar > BBrbx).

One main panel (Studio connection + target armature) with sub-panels in the
order you use them: Import & Rig Setup, Rig, Skinned Meshes, Face, Animation,
UGC Validation, Roblox Account, About.
"""

import math
from pathlib import Path

import bpy

try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None

from ..animation.face_controls import (
    face_control_property_name,
    grouped_face_controls,
    facs_sliders_drive_armature,
    load_facs_payload_from_armature,
)
from ..animation.serialization import is_deform_bone_rig
from ..server.server import get_server_status
from ..core.utils import get_object_by_name

CATEGORY = "BBrbx"


def _load_addon_version_text():
    manifest_path = Path(__file__).resolve().parent.parent / "blender_manifest.toml"
    try:
        with manifest_path.open("rb") as manifest_file:
            if tomllib is not None:
                manifest_data = tomllib.load(manifest_file)
                return str(manifest_data.get("version", "unknown"))
    except Exception:
        pass
    try:
        for line in manifest_path.read_text(encoding="utf-8").splitlines():
            if line.startswith("version ="):
                return line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass
    return "unknown"


ADDON_VERSION_TEXT = _load_addon_version_text()


def _settings(context):
    return getattr(context.scene, "rbx_anim_settings", None)


def _target_armature(context):
    settings = _settings(context)
    if not settings:
        return None
    obj = get_object_by_name(settings.rbx_anim_armature)
    return obj if obj is not None and obj.type == "ARMATURE" else None


def _has_stamped_rig(objects):
    return any(
        obj.type == "ARMATURE"
        and any("transform" in b and "transform1" in b and "nicetransform" in b for b in obj.data.bones)
        for obj in objects
    )


class _BBrbxPanel:
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = CATEGORY


class _NeedsArmature(_BBrbxPanel):
    @classmethod
    def poll(cls, context):
        return _target_armature(context) is not None


# ---------------------------------------------------------------------------
# Main panel: connection + target
# ---------------------------------------------------------------------------


class OBJECT_PT_RbxAnimations(_BBrbxPanel, bpy.types.Panel):
    bl_label = "BBrbx"
    bl_idname = "OBJECT_PT_RbxAnimations"

    def draw_header_preset(self, context):
        self.layout.label(text=f"v{ADDON_VERSION_TEXT}")

    def draw(self, context):
        layout = self.layout
        settings = _settings(context)

        # Studio connection
        box = layout.box()
        row = box.row(align=True)
        running = get_server_status()
        row.label(
            text="Studio link: running" if running else "Studio link: stopped",
            icon="LINKED" if running else "UNLINKED",
        )
        row = box.row(align=True)
        if running:
            row.operator("object.stop_server", text="Stop", icon="PAUSE")
        else:
            row.operator("object.start_server", text="Start", icon="PLAY")
        if settings:
            row.prop(settings, "rbx_server_port", text="Port")

        # Target armature
        armatures_exist = any(obj.type == "ARMATURE" for obj in context.scene.objects)
        if not armatures_exist:
            layout.label(text="No armature yet — import a rig below.", icon="INFO")
        elif settings:
            layout.prop(settings, "rbx_anim_armature", text="Armature", icon="ARMATURE_DATA")
            if _target_armature(context) is None:
                layout.label(text="Pick the armature you animate.", icon="INFO")


# ---------------------------------------------------------------------------
# Import & rig setup
# ---------------------------------------------------------------------------


class BBRBX_PT_import(_BBrbxPanel, bpy.types.Panel):
    bl_label = "Import & Rig Setup"
    bl_idname = "BBRBX_PT_import"
    bl_parent_id = "OBJECT_PT_RbxAnimations"

    def draw_header(self, context):
        self.layout.label(icon="IMPORT")

    def draw(self, context):
        layout = self.layout
        objects = context.scene.objects
        has_rig = _has_stamped_rig(objects) or any(
            "RigMeta" in o and o.name.startswith("__") and "Meta" in o.name for o in objects
        )
        col = layout.column(align=True)
        col.scale_y = 1.3 if not has_rig else 1.0
        col.operator("object.rbxanims_import_rbxm", text="Import Roblox (.rbxm / .rbxl)", icon="IMPORT")
        col.operator("object.rbxanims_importmodel", text="Import Rig (.obj, legacy)", icon="FILE_3D")
        layout.operator("object.rbxanims_genrig", text="Generate / Rebuild Armature", icon="ARMATURE_DATA")
        if not has_rig:
            layout.label(text="In Studio: Rig tab → Export Rig (RBXM).", icon="INFO")


# ---------------------------------------------------------------------------
# Rig
# ---------------------------------------------------------------------------


def _roblox_euler_degrees(m3):
    e = m3.to_euler("ZYX")
    return tuple(round(math.degrees(v), 2) for v in (e.x, e.y, e.z))


class BBRBX_PT_rig(_NeedsArmature, bpy.types.Panel):
    bl_label = "Rig"
    bl_idname = "BBRBX_PT_rig"
    bl_parent_id = "OBJECT_PT_RbxAnimations"

    def draw_header(self, context):
        self.layout.label(icon="MOD_ARMATURE")

    def draw(self, context):
        from ..rig import rest_contract

        layout = self.layout
        settings = _settings(context)
        arm = _target_armature(context)

        # Rig check
        box = layout.box()
        row = box.row()
        row.label(text="Rig Check", icon="CHECKMARK")
        row.operator("rbxbb.rig_check", text="Run", icon="FILE_REFRESH")
        report = context.scene.get("rbx_bb_rig_check")
        if report:
            for line in str(report).split("\n")[:10]:
                kind, _, text = line.partition(":")
                box.label(text=text, icon="ERROR" if kind == "ERROR" else ("CHECKMARK" if kind == "OK" else "INFO"))

        # Active bone
        bone = arm.data.bones.active
        if bone is not None:
            box = layout.box()
            box.label(text=f"{bone.name}  →  Roblox: {rest_contract.channel_name(bone)}", icon="BONE_DATA")
            exported = rest_contract.is_exported_bone(arm, bone)
            stamped = rest_contract.is_stamped(bone) and not rest_contract.is_copied_duplicate(bone)
            if exported:
                box.label(
                    text="Exact Roblox frame" if stamped else "Frame comes from Studio on export",
                    icon="CHECKMARK",
                )
            else:
                box.label(text="Helper bone — not sent to Roblox", icon="HIDE_ON")
            row = box.row(align=True)
            row.label(text="Export:")
            for mode, label in (("ON", "Always"), ("AUTO", "Auto"), ("OFF", "Never")):
                row.operator("rbxbb.toggle_bone_export", text=label).mode = mode
            pb = arm.pose.bones.get(bone.name)
            if pb is not None:
                basis = pb.matrix_basis
                if stamped:
                    from ..core.utils import to_matrix

                    nice = to_matrix(bone["nicetransform"])
                    basis = nice @ basis @ nice.inverted()
                rx, ry, rz = _roblox_euler_degrees(basis.to_3x3())
                loc = basis.to_translation()
                col = box.column(align=True)
                col.label(text=f"Roblox rot XYZ  {rx}, {ry}, {rz}")
                col.label(text=f"Roblox pos  {loc.x:.3f}, {loc.y:.3f}, {loc.z:.3f}")

        # Parts & constraints
        col = layout.column(align=True)
        col.operator("object.rbxanims_autoconstraint", text="Constrain Matching Parts to Bones", icon="CONSTRAINT_BONE")
        col.operator("object.rbxanims_manualconstraint", text="Manual Constraint Editor", icon="CONSTRAINT")
        if settings:
            col.operator(
                "object.rbxanims_toggle_weld_bones",
                text="Hide Weld Bones" if settings.rbx_hide_weld_bones else "Show Weld Bones",
                icon="HIDE_ON" if settings.rbx_hide_weld_bones else "HIDE_OFF",
                depress=settings.rbx_hide_weld_bones,
            )

        # IK
        has_ik = False
        selected_ik_target = None
        if arm.mode == "POSE":
            from ..rig.ik import has_ik_constraint
            from ..core.utils import pose_bone_selected

            for b in arm.pose.bones:
                if pose_bone_selected(b):
                    if has_ik_constraint(arm, b):
                        has_ik = True
                    if b.name.endswith("-IKTarget") and "IK_FK" in b:
                        selected_ik_target = b
        box = layout.box()
        box.label(text="IK", icon="CON_KINEMATIC")
        row = box.row(align=True)
        row.operator("object.rbxanims_modifyik" if has_ik else "object.rbxanims_genik", text="Modify IK" if has_ik else "Generate IK")
        row.operator("object.rbxanims_removeik", text="Remove IK")
        if selected_ik_target:
            row = box.row(align=True)
            row.prop(selected_ik_target, '["IK_FK"]', text="IK ↔ FK", slider=True)
            row = box.row(align=True)
            row.operator("object.rbxanims_set_ikfk", text="IK").value = 1.0
            row.operator("object.rbxanims_set_ikfk", text="FK").value = 0.0

        # World space
        box = layout.box()
        box.label(text="World-space bones", icon="UNLINKED")
        row = box.row(align=True)
        row.operator("object.rbxanims_worldspace_unparent", text="Unparent")
        row.operator("object.rbxanims_worldspace_reparent", text="Reparent")
        ws_bones = [b.name for b in arm.data.bones if b.get("worldspace_bone")]
        if ws_bones:
            box.label(text=f"{len(ws_bones)} bone(s) in world space")

        # Center of mass
        try:
            from ..rig.com import is_com_for_armature, is_com_grid_enabled

            obj = context.active_object
            com_enabled = is_com_for_armature(obj) if obj else False
            grid_enabled = is_com_grid_enabled() if com_enabled else False
        except Exception:
            com_enabled = grid_enabled = False
        row = layout.row(align=True)
        row.label(text="Center of Mass", icon="PIVOT_MEDIAN")
        row.operator("object.rbxanims_toggle_com", text="", icon="HIDE_OFF" if com_enabled else "HIDE_ON", depress=com_enabled)
        if com_enabled:
            row.operator("object.rbxanims_toggle_com_grid", text="", icon="MESH_CIRCLE", depress=grid_enabled)
        row.operator("object.rbxanims_edit_com_weights", text="Weights")


# ---------------------------------------------------------------------------
# Skinned meshes
# ---------------------------------------------------------------------------


class BBRBX_PT_skinned(_NeedsArmature, bpy.types.Panel):
    bl_label = "Skinned Meshes → Roblox"
    bl_idname = "BBRBX_PT_skinned"
    bl_parent_id = "OBJECT_PT_RbxAnimations"
    bl_options = {"DEFAULT_CLOSED"}

    def draw_header(self, context):
        self.layout.label(icon="MOD_SKIN")

    def draw(self, context):
        layout = self.layout
        layout.operator("rbxbb.export_deform", icon="EXPORT")
        last = context.scene.get("rbx_bb_last_deform_export")
        if last:
            layout.label(text=str(last).replace("\\", "/").split("/")[-1], icon="FILE")
        col = layout.column(align=True)
        col.label(text="Then in Studio:")
        col.label(text="1. Home → Import 3D (the FBX)")
        col.label(text="2. Rig tab → Bind Imported Mesh")
        layout.label(text="No skinned meshes? Studio: Push Rig", icon="INFO")


# ---------------------------------------------------------------------------
# Face
# ---------------------------------------------------------------------------


class BBRBX_PT_face(_NeedsArmature, bpy.types.Panel):
    bl_label = "Face Controls"
    bl_idname = "BBRBX_PT_face"
    bl_parent_id = "OBJECT_PT_RbxAnimations"
    bl_options = {"DEFAULT_CLOSED"}

    @classmethod
    def poll(cls, context):
        arm = _target_armature(context)
        if arm is None:
            return False
        payload = load_facs_payload_from_armature(arm)
        return bool((payload or {}).get("face_control_names"))

    def draw_header(self, context):
        self.layout.label(icon="USER")

    def draw(self, context):
        layout = self.layout
        arm = _target_armature(context)
        payload = load_facs_payload_from_armature(arm)
        groups = grouped_face_controls((payload or {}).get("face_control_names") or [])
        face_props = arm.rbx_face_controls
        layout.prop(face_props, "rbx_facs_eval_mode", text="Mode")
        sliders_active = facs_sliders_drive_armature(arm)
        if not sliders_active:
            layout.label(text="Choose Sliders to edit the face.", icon="INFO")
        for group_label, control_names in groups:
            box = layout.box()
            box.label(text=group_label)
            col = box.column(align=True)
            col.enabled = sliders_active
            for control_name in control_names:
                col.prop(face_props, face_control_property_name(control_name), slider=True)


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------


class BBRBX_PT_animation(_NeedsArmature, bpy.types.Panel):
    bl_label = "Animation"
    bl_idname = "BBRBX_PT_animation"
    bl_parent_id = "OBJECT_PT_RbxAnimations"

    def draw_header(self, context):
        self.layout.label(icon="ACTION")

    def draw(self, context):
        layout = self.layout
        settings = _settings(context)
        arm = _target_armature(context)

        ad = arm.animation_data
        action = ad.action if ad else None
        if action is not None:
            box = layout.box()
            box.label(text=f"Roblox settings for '{action.name}'", icon="ACTION")
            col = box.column(align=True)
            col.prop(action, "rbx_bb_name", text="Name")
            col.prop(action, "rbx_bb_priority", text="Priority")
            col.prop(action, "rbx_bb_loop", text="Loop")
        else:
            layout.label(text="Assign an action to set its Roblox name/priority/loop.", icon="INFO")

        has_new_bones = any(
            not ("transform" in b.bone and "transform1" in b.bone and "nicetransform" in b.bone)
            for b in arm.pose.bones
        )
        force_deform = getattr(settings, "force_deform_bone_serialization", False) if settings else False
        if settings and (is_deform_bone_rig(arm) or force_deform or has_new_bones):
            box = layout.box()
            box.prop(settings, "rbx_auto_deform_scale", text="Auto deform scale")
            if not settings.rbx_auto_deform_scale:
                box.prop(settings, "rbx_deform_rig_scale", text="Manual unit scale")

        col = layout.column(align=True)
        col.label(text="Bring animation in")
        col.operator("object.rbxanims_importfbxanimation", text="Import from .fbx", icon="IMPORT")
        col.operator("object.rbxanims_mapkeyframes", text="Map from Active Rig", icon="LINKED")
        col.operator("object.rbxanims_applytransform", text="Apply Object Transform", icon="OBJECT_ORIGIN")

        col = layout.column(align=True)
        col.label(text="Bake (without Studio link)")
        if settings:
            col.prop(settings, "rbx_full_range_bake", text="Full range bake")
        row = col.row(align=True)
        row.operator("object.rbxanims_bake", text="Clipboard", icon="COPYDOWN")
        row.operator("object.rbxanims_bake_file", text="File", icon="FILE")


class BBRBX_PT_validation(_NeedsArmature, bpy.types.Panel):
    bl_label = "UGC Emote Validation"
    bl_idname = "BBRBX_PT_validation"
    bl_parent_id = "OBJECT_PT_RbxAnimations"
    bl_options = {"DEFAULT_CLOSED"}

    def draw_header(self, context):
        self.layout.label(icon="CHECKMARK")

    def draw(self, context):
        layout = self.layout
        settings = _settings(context)
        if settings:
            layout.prop(settings, "rbx_max_studs_per_frame", text="Motion warning @30fps")
        row = layout.row(align=True)
        row.operator("object.rbxanims_validate_motionpaths", text="Validate Motion Paths", icon="ANIM_DATA")
        row.operator("object.rbxanims_clear_motionpaths", text="", icon="TRASH")


# ---------------------------------------------------------------------------
# Account & about
# ---------------------------------------------------------------------------


class BBRBX_PT_account(_BBrbxPanel, bpy.types.Panel):
    bl_label = "Roblox Account"
    bl_idname = "BBRBX_PT_account"
    bl_parent_id = "OBJECT_PT_RbxAnimations"
    bl_options = {"DEFAULT_CLOSED"}

    def draw_header(self, context):
        self.layout.label(icon="USER")

    def draw(self, context):
        from ..core import auth  # noqa: PLC0415

        layout = self.layout
        if auth.is_login_in_progress():
            layout.label(text="Logging in…", icon="TIME")
            layout.operator("rbx.oauth_cancel_login", text="Cancel", icon="CANCEL")
        elif auth.has_saved_login():
            layout.label(text="Connected", icon="CHECKMARK")
            layout.operator("rbx.oauth_logout", text="Log Out", icon="LOCKED")
        elif not auth.is_online_access_allowed():
            layout.label(text="Online access is disabled in Blender preferences.", icon="ERROR")
            row = layout.row()
            row.enabled = False
            row.operator("rbx.oauth_login", text="Log In to Roblox", icon="LINKED")
        else:
            layout.label(text="Needed to import Roblox models or places.", icon="INFO")
            layout.operator("rbx.oauth_login", text="Log In to Roblox", icon="LINKED")


class BBRBX_PT_about(_BBrbxPanel, bpy.types.Panel):
    bl_label = "About"
    bl_idname = "BBRBX_PT_about"
    bl_parent_id = "OBJECT_PT_RbxAnimations"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context):
        col = self.layout.column(align=True)
        col.label(text=f"BBrbx {ADDON_VERSION_TEXT}")
        col.label(text="Blender ⇄ Roblox Studio rigs and animations.")
        col.separator()
        col.label(text="Credits:")
        col.label(text="Based on RBXMonkey (Blender Animations Plugin)")
        col.label(text="by Cautioned — GPL-3.0.")
        col.label(text="github.com/Cautioned/Blender-Animations-Plugin")


CHILD_PANELS = (
    BBRBX_PT_import,
    BBRBX_PT_rig,
    BBRBX_PT_skinned,
    BBRBX_PT_face,
    BBRBX_PT_animation,
    BBRBX_PT_validation,
    BBRBX_PT_account,
    BBRBX_PT_about,
)
