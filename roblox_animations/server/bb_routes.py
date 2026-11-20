# pyright: reportAttributeAccessIssue=false
"""
BB fork HTTP routes (all under /bb/). The animation server pumps requests from a
Blender timer on the main thread, so these handlers may use bpy directly.

GET  /bb/ping
GET  /bb/rig_layout?armature=NAME           -> rig the armature wants Roblox to have
POST /bb/rig_applied?armature=NAME          <- {"applied": [{name, blender_name, kind}]}
GET  /bb/list_actions?armature=NAME         -> actions that animate the armature
POST /bb/export_action?armature=&action=    <- {"target_bone_rest": ...} (body optional)
                                            -> zlib(JSON) exactly like /export_animation
GET  /bb/rig_check?armature=NAME            -> problems that would break an export
"""

import json
import math
import re
import time
import traceback
import urllib.parse
import zlib

import bpy

from ..core.utils import get_object_by_name

_BONE_PATH = re.compile(r'^pose\.bones\["((?:[^"\\]|\\.)*)"\]')


def _send(handler, code, body, content_type="application/json"):
    data = body if isinstance(body, (bytes, bytearray)) else json.dumps(body).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def _error(handler, code, message):
    _send(handler, code, {"error": True, "message": message})


def _query(handler):
    parsed = urllib.parse.urlparse(handler.path)
    query = urllib.parse.parse_qs(parsed.query)
    return parsed.path, {k: v[0] for k, v in query.items() if v}


def _body(handler):
    length = int(handler.headers.get("Content-Length", 0) or 0)
    if not length:
        return {}
    raw = handler.rfile.read(length)
    try:
        raw = zlib.decompress(raw)
    except zlib.error:
        pass
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def resolve_armature(name):
    if name:
        obj = get_object_by_name(name) or bpy.data.objects.get(name)
        if obj is None or obj.type != "ARMATURE":
            raise LookupError(f"Armature '{name}' not found in Blender")
        return obj
    settings = getattr(bpy.context.scene, "rbx_anim_settings", None)
    current = getattr(settings, "rbx_anim_armature", None)
    if current:
        obj = bpy.data.objects.get(current)
        if obj is not None and obj.type == "ARMATURE":
            return obj
    active = bpy.context.view_layer.objects.active
    if active is not None and active.type == "ARMATURE":
        return active
    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if len(armatures) == 1:
        return armatures[0]
    raise LookupError("No armature specified and none could be picked automatically")


# ---------------------------------------------------------------------------
# Actions (bulk import)
# ---------------------------------------------------------------------------


def _action_fcurves(action):
    try:
        from ..core.utils import get_action_fcurves

        fcurves = get_action_fcurves(action)
        if fcurves is not None:
            return list(fcurves)
    except Exception:
        pass
    return list(getattr(action, "fcurves", []) or [])


def action_targets_armature(action, armature):
    if getattr(action, "id_root", "OBJECT") not in {"OBJECT", "NONE", ""}:
        return False
    bone_names = set(armature.pose.bones.keys())
    for fcurve in _action_fcurves(action):
        match = _BONE_PATH.match(fcurve.data_path or "")
        if match and match.group(1).replace('\\"', '"') in bone_names:
            return True
    return False


def action_range(action):
    start, end = action.frame_range
    start, end = int(math.floor(start)), int(math.ceil(end))
    return start, max(start, end)


def action_settings(action):
    """Per-action Roblox settings stored as custom props (set in the BB panel)."""
    out = {}
    for key, prop in (("priority", "rbx_priority"), ("loop", "rbx_loop"), ("name", "rbx_target_name")):
        if prop in action:
            value = action[prop]
            out[key] = bool(value) if key == "loop" else str(value)
    return out


def list_actions(armature):
    actions, skipped = [], []
    for action in sorted(bpy.data.actions, key=lambda a: a.name.lower()):
        if action_targets_armature(action, armature):
            start, end = action_range(action)
            entry = {"name": action.name, "frame_start": start, "frame_end": end}
            entry.update({"settings": action_settings(action)})
            actions.append(entry)
        else:
            skipped.append(action.name)
    current = armature.animation_data.action.name if armature.animation_data and armature.animation_data.action else None
    return {"armature": armature.name, "actions": actions, "skipped": skipped, "current": current}


def export_action(armature, action_name, target_bone_rest=None):
    """Export one action through the regular exporter, restoring all state after."""
    from .requests import execute_in_main_thread, pending_responses, _get_timeline_scene_for_armature

    action = bpy.data.actions.get(action_name)
    if action is None:
        raise LookupError(f"Action '{action_name}' not found")

    ad = armature.animation_data or armature.animation_data_create()
    if getattr(ad, "use_tweak_mode", False):
        raise RuntimeError("Exit NLA tweak mode on the armature before importing")

    context = bpy.context
    scene = context.scene
    timeline_scene = _get_timeline_scene_for_armature(scene, armature)
    scenes = [scene] if timeline_scene is scene else [scene, timeline_scene]
    saved = {
        "action": ad.action,
        "slot": getattr(ad, "action_slot", None),
        "use_nla": ad.use_nla,
        "ranges": [(s, s.frame_start, s.frame_end, s.frame_current) for s in scenes],
        "active": context.view_layer.objects.active,
        "mode": armature.mode,
    }
    try:
        ad.use_nla = False
        ad.action = action
        if hasattr(ad, "action_slot") and getattr(ad, "action_slot", None) is None:
            suitable = list(getattr(ad, "action_suitable_slots", []) or [])
            if suitable:
                ad.action_slot = suitable[0]
        start, end = action_range(action)
        for s in scenes:
            s.frame_start = start
            s.frame_end = end

        task_id = f"bb_bulk:{action.name}:{time.time_ns()}"
        execute_in_main_thread(task_id, armature.name, target_bone_rest)
        success, payload = pending_responses.pop(task_id, (False, "No response from exporter"))
        if not success:
            raise RuntimeError(str(payload))
        return payload  # zlib-compressed JSON bytes, same as /export_animation
    finally:
        try:
            ad.action = saved["action"]
            if hasattr(ad, "action_slot") and saved["action"] is not None:
                try:
                    ad.action_slot = saved["slot"]
                except Exception:
                    pass
            ad.use_nla = saved["use_nla"]
        except Exception:
            traceback.print_exc()
        for s, fs, fe, fc in saved["ranges"]:
            s.frame_start, s.frame_end = fs, fe
            s.frame_set(fc)
        try:
            if armature.mode != saved["mode"]:
                bpy.ops.object.mode_set(mode=saved["mode"])
            context.view_layer.objects.active = saved["active"]
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Rig check
# ---------------------------------------------------------------------------


def rig_check(armature):
    from ..rig import rest_contract

    problems = []
    info = []
    names = {}
    for b in armature.data.bones:
        if not rest_contract.is_exported_bone(armature, b):
            continue
        rname = rest_contract.roblox_name(b)
        if rname in names:
            problems.append(f"'{b.name}' and '{names[rname]}' both export as '{rname}'")
        names[rname] = b.name
        if re.search(r"\.\d{3}$", rname):
            problems.append(f"'{rname}' ends in a Blender duplicate suffix; rename it before pushing")
        if rest_contract.rest_drift(b) > 1e-4:
            info.append(f"'{b.name}' rest was edited in Blender; Push Rig will update it in Studio")
    scale = armature.scale
    if max(scale) - min(scale) > 1e-4:
        problems.append("Armature object scale is not uniform; apply scale first")
    if armature.matrix_world != armature.matrix_world.Identity(4):
        info.append("Armature object is not at the origin (handled automatically)")
    return {"armature": armature.name, "problems": problems, "info": info}


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------


def handle(handler, method):
    """Return True when the request was a /bb/ route (handled or errored)."""
    if not handler.path.startswith("/bb/"):
        return False
    path, query = _query(handler)
    try:
        if method == "GET" and path == "/bb/ping":
            from .. import bl_info

            _send(handler, 200, {"ok": True, "fork": "bb", "version": list(bl_info.get("version", ()))})
        elif method == "GET" and path == "/bb/rig_layout":
            from ..rig import rest_contract

            _send(handler, 200, rest_contract.rig_layout(resolve_armature(query.get("armature"))))
        elif method == "POST" and path == "/bb/rig_applied":
            from ..rig import rest_contract

            armature = resolve_armature(query.get("armature"))
            body = _body(handler)
            if armature.mode == "EDIT":
                bpy.ops.object.mode_set(mode="OBJECT")
            stamped = rest_contract.apply_layout_result(armature, body.get("applied") or [])
            if body.get("target_bone_rest"):
                rest_contract.adopt_from_target_rest(armature, body["target_bone_rest"], only_unstamped=True)
            _send(handler, 200, {"ok": True, "stamped": stamped})
        elif method == "GET" and path == "/bb/list_actions":
            _send(handler, 200, list_actions(resolve_armature(query.get("armature"))))
        elif path == "/bb/export_action":
            action = query.get("action")
            if not action:
                _error(handler, 400, "Missing 'action' parameter")
                return True
            body = _body(handler) if method == "POST" else {}
            payload = export_action(resolve_armature(query.get("armature")), action, body.get("target_bone_rest"))
            _send(handler, 200, payload, "application/octet-stream")
        elif method == "GET" and path == "/bb/rig_check":
            _send(handler, 200, rig_check(resolve_armature(query.get("armature"))))
        else:
            _error(handler, 404, "Unknown endpoint")
    except LookupError as exc:
        _error(handler, 404, str(exc))
    except Exception as exc:  # reported back to Studio
        traceback.print_exc()
        _error(handler, 500, str(exc))
    return True
