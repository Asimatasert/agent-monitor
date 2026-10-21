"""Unit tests for localshare.py (this Mac's share of a Claude account shared with other computers).

Pure module: plain Python is enough (python3 -m unittest tests.test_localshare). Synthetic data only.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import localshare as ls  # noqa: E402

H = 3600
S = "Current session"
W = "Current week"


def readings(reset, points):
    """[(ts, used)] -> [(ts, used, reset)]"""
    return [(t, u, reset) for t, u in points]


class Attribution(unittest.TestCase):
    def setUp(self):
        self.hist = {"a#1": {S: readings(10 * H, [(0, 0), (H, 50), (2 * H, 100)])},
                     "a#2": {S: readings(10 * H, [(0, 0), (2 * H, 10)])}}

    def test_claude_code_goes_to_its_login(self):
        by, lost = ls.attribute(["a#1", "a#2"], "a#2", ["a#1", "a#2"], True, self.hist, [(100, 1.0, "m")], [])
        self.assertEqual(len(by["a#2"]), 1)
        self.assertFalse(lost)

    def test_hermes_moves_on_when_the_first_account_is_full(self):
        evs = [(H + 10, 1.0, "m"), (2 * H + 10, 1.0, "m")]
        by, _ = ls.attribute(["a#1", "a#2"], None, ["a#1", "a#2"], True, self.hist, [], evs)
        self.assertEqual([e[0] for e in by["a#1"]], [H + 10])
        self.assertEqual([e[0] for e in by["a#2"]], [2 * H + 10])

    def test_other_strategies_stay_unattributed(self):
        by, lost = ls.attribute(["a#1", "a#2"], None, ["a#1", "a#2"], False, self.hist, [], [(H, 1.0, "m")])
        self.assertEqual(len(lost), 1)
        self.assertFalse(by["a#1"] or by["a#2"])

    def test_unknown_credential_first_in_order_is_unattributed(self):
        by, lost = ls.attribute(["a#1", "a#2"], None, [None, "a#1"], True, self.hist, [], [(H, 1.0, "m")])
        self.assertEqual(len(lost), 1)

    def test_requests_before_the_account_was_seen_are_not_its(self):
        hist = {"a#1": {S: readings(10 * H, [(5 * H, 0)])}}
        by, lost = ls.attribute(["a#1"], None, ["a#1"], True, hist, [], [(H, 1.0, "m"), (5 * H, 1.0, "m")])
        self.assertEqual(len(by["a#1"]), 1)
        self.assertEqual(lost, [])  # dropped, not "unknown": the pool held other accounts back then


class Share(unittest.TestCase):
    def test_idle_mac_has_no_share(self):
        out = ls.window_share(S, 40.0, 5 * H, readings(5 * H, [(H, 10), (2 * H, 40)]), ls.Costs([]), ls.Costs([]), 2 * H)
        self.assertEqual((out["local"], out["other"], out["basis"]), (0.0, 40.0, "idle"))

    def test_unattributed_cost_makes_it_unknown(self):
        out = ls.window_share(S, 40.0, 5 * H, [], ls.Costs([]), ls.Costs([(H, 1.0, "m")]), 2 * H)
        self.assertEqual(out["basis"], "unknown")
        self.assertIsNone(out["local"])

    def test_rate_from_a_past_window_where_only_this_mac_ran(self):
        # past window [0, 5h]: this Mac spent $10 and the account ended at 20 % -> 2 %/$
        past = readings(5 * H, [(H, 0), (4 * H, 20), (5 * H - 60, 20)])
        # current window [5h, 10h]: 30 % so far, this Mac spent $5 -> 10 % here, 20 % elsewhere
        cur = readings(10 * H, [(6 * H, 0), (7 * H, 10), (8 * H, 30)])
        costs = ls.Costs([(2 * H, 10.0, "m"), (6 * H + 600, 5.0, "m")])
        out = ls.window_share(S, 30.0, 10 * H, past + cur, costs, ls.Costs([]), 8 * H)
        self.assertEqual(out["basis"], "estimate")
        self.assertAlmostEqual(out["rate"], 2.0)
        self.assertEqual((out["local"], out["other"]), (10.0, 20.0))

    def test_rise_while_idle_is_never_local(self):
        # without a past window the rate comes from the current one (used / cost = everything);
        # the rise seen while this Mac was idle still goes to the other computer
        cur = readings(10 * H, [(6 * H, 0), (6 * H + 300, 5), (6 * H + 900, 5), (8 * H, 25)])
        costs = ls.Costs([(6 * H + 100, 1.0, "m")])
        out = ls.window_share(S, 25.0, 10 * H, cur, costs, ls.Costs([]), 8 * H)
        self.assertEqual((out["local"], out["other"]), (5.0, 20.0))

    def test_bound_only_when_too_little_was_spent(self):
        cur = readings(10 * H, [(6 * H, 0), (6 * H + 300, 2)])
        costs = ls.Costs([(6 * H + 100, 0.2, "m")])
        out = ls.window_share(S, 2.0, 10 * H, cur, costs, ls.Costs([]), 7 * H)
        self.assertEqual(out["basis"], "bound")
        self.assertEqual(out["local"], 2.0)

    def test_model_week_counts_only_that_model(self):
        item = {"provider": "a#1", "windows": [{"label": "Sonnet week", "used": 10.0, "reset": 7 * 86400}]}
        hist = {"a#1": {"Sonnet week": readings(7 * 86400, [(H, 0)])}}
        out = ls.shares([item], hist, {"a#1": [(2 * H, 3.0, "claude-opus-x")]}, [], 3 * H)
        self.assertEqual(out["a#1"]["Sonnet week"]["basis"], "idle")


class Helpers(unittest.TestCase):
    def test_intervals_skip_a_reset(self):
        rs = [(0, 10, 100), (60, 12, 100), (120, 0, 5000)]
        self.assertEqual(ls.intervals(rs), [(0, 60, 2)])

    def test_full_at_respects_staleness(self):
        hist = {S: [(0, 100, 10 * H)]}
        self.assertTrue(ls.full_at(hist, 600))
        self.assertFalse(ls.full_at(hist, ls.FULL_STALE + 1))


if __name__ == "__main__":
    unittest.main()
