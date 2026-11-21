"""Dense skinned bakes keep only the poses Roblox would not reproduce."""
import math
import unittest

from mathutils import Matrix

from ..animation.ir import KeyframePayload, PoseEntry
from ..animation.thinning import _expected, drop_redundant_poses

IDENT = [0.0, 0.0, 0.0, 1, 0, 0, 0, 1, 0, 0, 0, 1]


def cf(x=0.0, angle=0.0):
    r = Matrix.Rotation(angle, 3, "Z")
    return [x, 0.0, 0.0, *r[0], *r[1], *r[2]]


def keys(tracks, times):
    out = []
    for i, t in enumerate(times):
        poses = {}
        for name, values in tracks.items():
            if values[i] is not None:
                comps, style = values[i]
                poses[name] = PoseEntry(list(comps), style, "Out")
        out.append(KeyframePayload(t, poses))
    return out


def play(keyframes, name, t):
    """Evaluate one bone like Roblox: a pose's style drives the segment after it."""
    track = [(k.time, k.poses[name]) for k in keyframes if name in k.poses]
    if t <= track[0][0]:
        return track[0][1].components
    for (ta, a), (tb, b) in zip(track, track[1:]):
        if ta <= t < tb:
            return _expected(a, b, (t - ta) / (tb - ta), 1e-5) or a.components
    return track[-1][1].components


class TestThinning(unittest.TestCase):
    def check_same_playback(self, before, after, names):
        end = before[-1].time
        for step in range(0, 121):
            t = end * step / 120
            for name in names:
                a, b = play(before, name, t), play(after, name, t)
                self.assertLess(max(abs(x - y) for x, y in zip(a, b)), 1e-4, (name, t))

    def build(self):
        times = [i / 30 for i in range(31)]
        still = [(IDENT, "Linear")] * 31
        turning = [(cf(0, math.radians(3 * i)), "Linear") for i in range(31)]
        # Constant step at frame 10, then a bezier-ish (Cubic) ease into frame 20
        stepped = [(cf(0 if i < 10 else 1), "Constant") for i in range(31)]
        cubic = [(cf(min(i, 20) / 20 * 2), "Cubic" if i < 20 else "Linear") for i in range(31)]
        return keys({"Still": still, "Turn": turning, "Step": stepped, "Ease": cubic}, times)

    def test_static_and_linear_bones_shrink_to_ends(self):
        import copy

        before = self.build()
        after = drop_redundant_poses(copy.deepcopy(before))
        count = lambda ks, n: sum(1 for k in ks if n in k.poses)
        self.assertEqual(count(after, "Still"), 2)
        self.assertEqual(count(after, "Turn"), 2)
        self.assertLessEqual(count(after, "Step"), 4)
        # cubic samples are not on a straight line: they stay
        self.assertGreaterEqual(count(after, "Ease"), 20)
        self.check_same_playback(before, after, ("Still", "Turn", "Step", "Ease"))

    def test_constant_hold_keeps_step_frame(self):
        import copy

        before = self.build()
        after = drop_redundant_poses(copy.deepcopy(before))
        step_times = [round(k.time * 30) for k in after if "Step" in k.poses]
        self.assertIn(10, step_times)
        self.check_same_playback(before, after, ("Step",))

    def test_linear_pose_before_step_is_kept(self):
        # A Linear hold right before a jump must not be merged into a ramp.
        times = [0, 1 / 30, 2 / 30, 3 / 30]
        track = [(cf(0), "Linear"), (cf(0), "Linear"), (cf(0), "Linear"), (cf(1), "Linear")]
        before = keys({"B": track}, times)
        import copy

        after = drop_redundant_poses(copy.deepcopy(before))
        self.check_same_playback(before, after, ("B",))
        self.assertEqual([round(k.time * 30) for k in after if "B" in k.poses], [0, 2, 3])
