"""Drop poses Roblox would reproduce anyway.

Skinned rigs are baked densely: every bone is written on every evaluated
frame, including bones that stand still. A pose is only kept when removing
it would change playback in Roblox, where a pose's EasingStyle drives the
segment towards that bone's next pose:

- a run of equal poses between two equal neighbours is a hold in any style,
- a pose equal to a Constant predecessor (and Constant itself) is a hold,
- a Linear pose on the straight lerp/slerp between its Linear neighbours.

Each bone keeps its first and last pose. Keyframes left with no poses (and no
face controls) are removed, except the first and the last one.
"""

from typing import List, Optional, Sequence

from mathutils import Matrix, Quaternion, Vector

from .ir import KeyframePayload, PoseEntry

TOL = 1e-5


def _same(a: Sequence[float], b: Sequence[float], tol: float) -> bool:
    return len(a) == len(b) and all(abs(x - y) <= tol for x, y in zip(a, b))


def _rotation(c: Sequence[float]) -> Quaternion:
    return Matrix(((c[3], c[4], c[5]), (c[6], c[7], c[8]), (c[9], c[10], c[11]))).to_quaternion()


def _lerp(a: Sequence[float], b: Sequence[float], alpha: float) -> List[float]:
    pos = Vector(a[:3]).lerp(Vector(b[:3]), alpha)
    rot = _rotation(a).slerp(_rotation(b), alpha).to_matrix()
    return [pos.x, pos.y, pos.z, *rot[0], *rot[1], *rot[2]]


def _expected(a: PoseEntry, b: PoseEntry, alpha: float, tol: float) -> Optional[List[float]]:
    """What Roblox plays between a and b at alpha, or None if not cheap to tell."""
    if _same(a.components, b.components, tol) or a.style == "Constant":
        return list(a.components)
    if a.style == "Linear":
        return _lerp(a.components, b.components, alpha)
    return None


def _removable(a, run, b, tol: float) -> bool:
    """Can every (time, entry) in run go, leaving only a -> b?"""
    (ta, ea), (tb, eb) = a, b
    if tb <= ta:
        return False
    last = run[-1][1]
    equal_ends = _same(ea.components, eb.components, tol)
    if not equal_ends:
        # the last dropped pose drives the segment into b: it must match a's style
        if ea.style == "Constant" and last.style != "Constant":
            return False
        if ea.style == "Linear" and last.style != "Linear":
            return False
    for t, entry in run:
        expected = _expected(ea, eb, (t - ta) / (tb - ta), tol)
        if expected is None or not _same(entry.components, expected, tol * 10):
            return False
    return True


def drop_redundant_poses(collected: List[KeyframePayload], tol: float = TOL) -> List[KeyframePayload]:
    if len(collected) < 3:
        return collected
    names = {name for key in collected for name in key.poses}
    for name in names:
        track = [(key.time, key.poses[name], key) for key in collected if name in key.poses]
        if len(track) < 3:
            continue
        # Greedy: grow a run of dropped poses after an anchor while a -> next
        # still reproduces all of them; the pose that breaks it is the next anchor.
        dropped = set()
        anchor = (track[0][0], track[0][1])
        run: list = []
        for i in range(1, len(track) - 1):
            current = (track[i][0], track[i][1])
            following = (track[i + 1][0], track[i + 1][1])
            if _removable(anchor, run + [current], following, tol):
                run.append(current)
                dropped.add(i)
            else:
                run = []
                anchor = current
        for i in dropped:
            del track[i][2].poses[name]
    last = len(collected) - 1
    return [key for i, key in enumerate(collected) if key.poses or key.face or i in (0, last)]
