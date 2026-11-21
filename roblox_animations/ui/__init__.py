"""
UI module for the BBrbx Blender add-on.

This module contains all UI panels, properties, and interface components.
"""

from .panels import (
    OBJECT_PT_RbxAnimations,
)
from .properties import (
    RobloxAnimationSettings,
    register_properties,
    unregister_properties,
)

__all__ = [
    # Panels
    "OBJECT_PT_RbxAnimations",
    # Properties
    "RobloxAnimationSettings",
    "register_properties",
    "unregister_properties",
]
