# pyright: reportAttributeAccessIssue=false
"""Per-action Roblox settings; the BBrbx sub-panels live in ui/panels.py."""

import bpy

from .panels import CHILD_PANELS

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


# Registered after OBJECT_PT_RbxAnimations; order here = order in the sidebar.
CLASSES = CHILD_PANELS
