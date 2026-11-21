"""
BBrbx sidebar UI (View3D > Sidebar > BBrbx).

Layout rules: every field is "label left, value right" (use_property_split),
one emphasised button per section, and only the sections you use every day
(Rig, Animation) start open. Everything else sits closed below, with the rarely
used bits grouped under "More".
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
MAIN_ID = "OBJECT_PT_RbxAnimations"


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


def _split(layout):
    col = layout.column()
    col.use_property_split = True
    col.use_property_decorate = False
    return col


def _value_row(layout, label, value):
    """A read-only 'label | value' row aligned like use_property_split."""
    row = layout.row()
    split = row.split(factor=0.4)
    left = split.row()
    left.alignment = "RIGHT"
    left.label(text=label)
    split.label(text=value)


class _BBrbxPanel:
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = CATEGORY


class _NeedsArmature(_BBrbxPanel):
    @classmethod
    def poll(cls, context):
        return _target_armature(context) is not None


# ---------------------------------------------------------------------------
# Main panel: Studio link + target armature
# ---------------------------------------------------------------------------


class OBJECT_PT_RbxAnimations(_BBrbxPanel, bpy.types.Panel):
    bl_label = "BBrbx"
    bl_idname = MAIN_ID

    def draw_header_preset(self, context):
        self.layout.label(text=f"v{ADDON_VERSION_TEXT}")

    def draw(self, context):
        layout = self.layout
        settings = _settings(context)
        running = get_server_status()

        row = layout.row(align=True)
        row.label(
            text="Studio link running" if running else "Studio link stopped",
            icon="LINKED" if running else "UNLINKED",
        )
        if running:
            row.operator("object.stop_server", text="Stop", icon="PAUSE")
        else:
            row.operator("object.start_server", text="Start", icon="PLAY")

        if not settings:
            return
        col = _split(layout)
        col.prop(settings, "rbx_server_port", text="Port")
        if any(obj.type == "ARMATURE" for obj in context.scene.objects):
            col.prop(settings, "rbx_anim_armature", text="Armature", icon="ARMATURE_DATA")
            if _target_armature(context) is None:
                layout.label(text="Pick the armature you animate.", icon="INFO")
        else:
            layout.label(text="No armature yet. Open Import and setup.", icon="INFO")


# ---------------------------------------------------------------------------
# Rig
# ---------------------------------------------------------------------------


def _roblox_euler_degrees(m3):
    e = m3.to_euler("ZYX")
    return tuple(round(math.degrees(v), 1) for v in (e.x, e.y, e.z))


def _rig_check_lines(context):
    report = context.scene.get("rbx_bb_rig_check")
    if not report:
        return None
    lines = []
    for line in str(report).split("\n"):
        kind, _, text = line.partition(":")
        lines.append((kind, text))
    return lines


class BBRBX_PT_rig(_NeedsArmature, bpy.types.Panel):
    bl_label = "Rig"
    bl_idname = "BBRBX_PT_rig"
    bl_parent_id = MAIN_ID

    def draw_header(self, context):
        self.layout.label(icon="MOD_ARMATURE")

    def draw(self, context):
        from ..rig import rest_contract

        layout = self.layout
        arm = _target_armature(context)

        # Rig check: one status line, details only when something is wrong
        lines = _rig_check_lines(context)
        row = layout.row(align=True)
        if lines is None:
            row.label(text="Rig not checked yet", icon="QUESTION")
        else:
            errors = [t for k, t in lines if k == "ERROR"]
            if errors:
                row.alert = True
                row.label(text=f"{len(errors)} rig problem(s)", icon="ERROR")
            else:
                row.label(text=f"Rig OK, {len(arm.data.bones)} bones", icon="CHECKMARK")
        row.alert = False
        row.operator("rbxbb.rig_check", text="", icon="FILE_REFRESH")
        if lines:
            details = [(k, t) for k, t in lines if k != "OK"]
            if details:
                box = layout.box()
                col = box.column(align=True)
                for kind, text in details[:6]:
                    col.label(text=text, icon="ERROR" if kind == "ERROR" else "INFO")

        # Active bone
        bone = arm.data.bones.active
        if bone is None:
            layout.label(text="Select a bone to see its Roblox settings.", icon="BONE_DATA")
            return
        box = layout.box()
        box.label(text=f"{bone.name}  →  {rest_contract.channel_name(bone)}", icon="BONE_DATA")

        if rest_contract.EXPORT_PROP in bone:
            current = "ON" if bone[rest_contract.EXPORT_PROP] else "OFF"
        else:
            current = "AUTO"
        row = box.row(align=True)
        split = row.split(factor=0.4)
        left = split.row()
        left.alignment = "RIGHT"
        left.label(text="Export")
        buttons = split.row(align=True)
        for mode, label in (("ON", "Always"), ("AUTO", "Auto"), ("OFF", "Never")):
            buttons.operator("rbxbb.toggle_bone_export", text=label, depress=(mode == current)).mode = mode

        exported = rest_contract.is_exported_bone(arm, bone)
        stamped = rest_contract.is_stamped(bone) and not rest_contract.is_copied_duplicate(bone)
        if not exported:
            state = "helper, not sent"
        elif stamped:
            state = "exact Roblox frame"
        else:
            state = "frame from Studio"
        _value_row(box, "Status", state)

        pb = arm.pose.bones.get(bone.name)
        if pb is not None:
            basis = pb.matrix_basis
            if stamped:
                from ..core.utils import to_matrix

                nice = to_matrix(bone["nicetransform"])
                basis = nice @ basis @ nice.inverted()
            rx, ry, rz = _roblox_euler_degrees(basis.to_3x3())
            loc = basis.to_translation()
            _value_row(box, "Roblox rot", f"{rx}, {ry}, {rz}")
            _value_row(box, "Roblox pos", f"{loc.x:.3f}, {loc.y:.3f}, {loc.z:.3f}")


class BBRBX_PT_rig_tools(_NeedsArmature, bpy.types.Panel):
    bl_label = "Rig tools"
    bl_idname = "BBRBX_PT_rig_tools"
    bl_parent_id = "BBRBX_PT_rig"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context):
        layout = self.layout
        settings = _settings(context)
        arm = _target_armature(context)

        layout.label(text="Parts and constraints")
        col = layout.column(align=True)
        col.operator("object.rbxanims_autoconstraint", text="Constrain matching parts", icon="CONSTRAINT_BONE")
        col.operator("object.rbxanims_manualconstraint", text="Manual constraint editor", icon="CONSTRAINT")
        if settings:
            col.operator(
                "object.rbxanims_toggle_weld_bones",
                text="Hide weld bones" if settings.rbx_hide_weld_bones else "Show weld bones",
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
        layout.separator()
        layout.label(text="IK")
        row = layout.row(align=True)
        row.operator("object.rbxanims_modifyik" if has_ik else "object.rbxanims_genik", text="Modify" if has_ik else "Generate")
        row.operator("object.rbxanims_removeik", text="Remove")
        if selected_ik_target:
            layout.prop(selected_ik_target, '["IK_FK"]', text="IK / FK", slider=True)
            row = layout.row(align=True)
            row.operator("object.rbxanims_set_ikfk", text="IK").value = 1.0
            row.operator("object.rbxanims_set_ikfk", text="FK").value = 0.0

        # World space
        layout.separator()
        ws_count = sum(1 for b in arm.data.bones if b.get("worldspace_bone"))
        layout.label(text=f"World-space bones ({ws_count})" if ws_count else "World-space bones")
        row = layout.row(align=True)
        row.operator("object.rbxanims_worldspace_unparent", text="Unparent")
        row.operator("object.rbxanims_worldspace_reparent", text="Reparent")

        # Center of mass
        try:
            from ..rig.com import is_com_for_armature, is_com_grid_enabled

            obj = context.active_object
            com_enabled = is_com_for_armature(obj) if obj else False
            grid_enabled = is_com_grid_enabled() if com_enabled else False
        except Exception:
            com_enabled = grid_enabled = False
        layout.separator()
        layout.label(text="Center of mass")
        row = layout.row(align=True)
        row.operator("object.rbxanims_toggle_com", text="Show" if not com_enabled else "Hide", depress=com_enabled)
        if com_enabled:
            row.operator("object.rbxanims_toggle_com_grid", text="Grid", depress=grid_enabled)
        row.operator("object.rbxanims_edit_com_weights", text="Weights")


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------


class BBRBX_PT_animation(_NeedsArmature, bpy.types.Panel):
    bl_label = "Animation"
    bl_idname = "BBRBX_PT_animation"
    bl_parent_id = MAIN_ID

    def draw_header(self, context):
        self.layout.label(icon="ACTION")

    def draw(self, context):
        layout = self.layout
        settings = _settings(context)
        arm = _target_armature(context)

        ad = arm.animation_data
        action = ad.action if ad else None
        if action is not None:
            layout.label(text=action.name, icon="ACTION")
            col = _split(layout)
            col.prop(action, "rbx_bb_name", text="Roblox name")
            col.prop(action, "rbx_bb_priority", text="Priority")
            col.prop(action, "rbx_bb_loop", text="Loop")
        else:
            layout.label(text="No action on this armature.", icon="INFO")

        has_new_bones = any(
            not ("transform" in b.bone and "transform1" in b.bone and "nicetransform" in b.bone)
            for b in arm.pose.bones
        )
        force_deform = getattr(settings, "force_deform_bone_serialization", False) if settings else False
        if settings and (is_deform_bone_rig(arm) or force_deform or has_new_bones):
            col = _split(layout)
            col.prop(settings, "rbx_auto_deform_scale", text="Auto deform scale")
            if not settings.rbx_auto_deform_scale:
                col.prop(settings, "rbx_deform_rig_scale", text="Unit scale")

        layout.separator()
        layout.label(text="Bake without the Studio link")
        if settings:
            _split(layout).prop(settings, "rbx_full_range_bake", text="Full range")
        row = layout.row(align=True)
        row.operator("object.rbxanims_bake", text="To clipboard", icon="COPYDOWN")
        row.operator("object.rbxanims_bake_file", text="To file", icon="FILE")


class BBRBX_PT_animation_in(_NeedsArmature, bpy.types.Panel):
    bl_label = "Bring animation in"
    bl_idname = "BBRBX_PT_animation_in"
    bl_parent_id = "BBRBX_PT_animation"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context):
        col = self.layout.column(align=True)
        col.operator("object.rbxanims_importfbxanimation", text="Import from .fbx", icon="IMPORT")
        col.operator("object.rbxanims_mapkeyframes", text="Map from active rig", icon="LINKED")
        col.operator("object.rbxanims_applytransform", text="Apply object transform", icon="OBJECT_ORIGIN")


# ---------------------------------------------------------------------------
# Import and setup
# ---------------------------------------------------------------------------


class BBRBX_PT_import(_BBrbxPanel, bpy.types.Panel):
    bl_label = "Import and setup"
    bl_idname = "BBRBX_PT_import"
    bl_parent_id = MAIN_ID
    bl_options = {"DEFAULT_CLOSED"}

    def draw_header(self, context):
        self.layout.label(icon="IMPORT")

    def draw(self, context):
        layout = self.layout
        objects = context.scene.objects
        has_rig = _has_stamped_rig(objects) or any(
            "RigMeta" in o and o.name.startswith("__") and "Meta" in o.name for o in objects
        )
        if not has_rig:
            layout.label(text="In Studio: Rig tab, Send rig to Blender.", icon="INFO")
        col = layout.column(align=True)
        col.scale_y = 1.3 if not has_rig else 1.0
        col.operator("object.rbxanims_import_rbxm", text="Import Roblox (.rbxm / .rbxl)", icon="IMPORT")
        layout.operator("object.rbxanims_genrig", text="Generate / rebuild armature", icon="ARMATURE_DATA")
        layout.operator("object.rbxanims_importmodel", text="Import rig (.obj, legacy)", icon="FILE_3D")


# ---------------------------------------------------------------------------
# Skinned meshes
# ---------------------------------------------------------------------------


class BBRBX_PT_skinned(_NeedsArmature, bpy.types.Panel):
    bl_label = "Skinned meshes → Roblox"
    bl_idname = "BBRBX_PT_skinned"
    bl_parent_id = MAIN_ID
    bl_options = {"DEFAULT_CLOSED"}

    def draw_header(self, context):
        self.layout.label(icon="MOD_SKIN")

    def draw(self, context):
        layout = self.layout
        row = layout.row()
        row.scale_y = 1.3
        row.operator("rbxbb.export_deform", icon="EXPORT")
        last = context.scene.get("rbx_bb_last_deform_export")
        if last:
            _value_row(layout, "Last file", str(last).replace("\\", "/").split("/")[-1])
        col = layout.column(align=True)
        col.label(text="Then in Studio:")
        col.label(text="1. Home, Import 3D (the FBX)")
        col.label(text="2. Rig tab, Bind imported mesh")
        layout.label(text="No skinned meshes? Studio: Push rig.", icon="INFO")


# ---------------------------------------------------------------------------
# More: face, validation, account, about
# ---------------------------------------------------------------------------


class BBRBX_PT_more(_BBrbxPanel, bpy.types.Panel):
    bl_label = "More"
    bl_idname = "BBRBX_PT_more"
    bl_parent_id = MAIN_ID
    bl_options = {"DEFAULT_CLOSED"}

    def draw_header(self, context):
        self.layout.label(icon="THREE_DOTS")

    def draw(self, context):
        pass


class BBRBX_PT_face(_NeedsArmature, bpy.types.Panel):
    bl_label = "Face controls"
    bl_idname = "BBRBX_PT_face"
    bl_parent_id = "BBRBX_PT_more"
    bl_options = {"DEFAULT_CLOSED"}

    @classmethod
    def poll(cls, context):
        arm = _target_armature(context)
        if arm is None:
            return False
        payload = load_facs_payload_from_armature(arm)
        return bool((payload or {}).get("face_control_names"))

    def draw(self, context):
        layout = self.layout
        arm = _target_armature(context)
        payload = load_facs_payload_from_armature(arm)
        groups = grouped_face_controls((payload or {}).get("face_control_names") or [])
        face_props = arm.rbx_face_controls
        _split(layout).prop(face_props, "rbx_facs_eval_mode", text="Mode")
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


class BBRBX_PT_validation(_NeedsArmature, bpy.types.Panel):
    bl_label = "UGC emote validation"
    bl_idname = "BBRBX_PT_validation"
    bl_parent_id = "BBRBX_PT_more"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context):
        layout = self.layout
        settings = _settings(context)
        if settings:
            _split(layout).prop(settings, "rbx_max_studs_per_frame", text="Max studs / frame")
        row = layout.row(align=True)
        row.operator("object.rbxanims_validate_motionpaths", text="Validate motion paths", icon="ANIM_DATA")
        row.operator("object.rbxanims_clear_motionpaths", text="", icon="TRASH")


class BBRBX_PT_account(_BBrbxPanel, bpy.types.Panel):
    bl_label = "Roblox account"
    bl_idname = "BBRBX_PT_account"
    bl_parent_id = "BBRBX_PT_more"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context):
        from ..core import auth  # noqa: PLC0415

        layout = self.layout
        if auth.is_login_in_progress():
            layout.label(text="Logging in…", icon="TIME")
            layout.operator("rbx.oauth_cancel_login", text="Cancel", icon="CANCEL")
        elif auth.has_saved_login():
            layout.label(text="Connected", icon="CHECKMARK")
            layout.operator("rbx.oauth_logout", text="Log out", icon="LOCKED")
        elif not auth.is_online_access_allowed():
            layout.label(text="Online access is off in Blender preferences.", icon="ERROR")
            row = layout.row()
            row.enabled = False
            row.operator("rbx.oauth_login", text="Log in to Roblox", icon="LINKED")
        else:
            layout.label(text="Needed to import models or places from Roblox.", icon="INFO")
            layout.operator("rbx.oauth_login", text="Log in to Roblox", icon="LINKED")


class BBRBX_PT_about(_BBrbxPanel, bpy.types.Panel):
    bl_label = "About BBrbx"
    bl_idname = "BBRBX_PT_about"
    bl_parent_id = "BBRBX_PT_more"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context):
        col = self.layout.column(align=True)
        col.label(text=f"BBrbx {ADDON_VERSION_TEXT}")
        col.label(text="Blender ⇄ Roblox Studio rigs and animations.")
        col.separator()
        col.label(text="Credits")
        col.label(text="Based on RBXMonkey (Blender Animations Plugin)")
        col.label(text="by Cautioned, GPL-3.0.")
        col.label(text="github.com/Cautioned/Blender-Animations-Plugin")


# Registration order = order in the sidebar (parents before children).
CHILD_PANELS = (
    BBRBX_PT_rig,
    BBRBX_PT_rig_tools,
    BBRBX_PT_animation,
    BBRBX_PT_animation_in,
    BBRBX_PT_import,
    BBRBX_PT_skinned,
    BBRBX_PT_more,
    BBRBX_PT_face,
    BBRBX_PT_validation,
    BBRBX_PT_account,
    BBRBX_PT_about,
)
