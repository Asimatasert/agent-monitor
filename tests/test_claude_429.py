"""Unit tests for the Claude 429 handling: last known values (stale), one usage call per account, identity cache,
Retry-After / growing backoff. No test talks to Anthropic: every HTTP call is replaced by a fake.

Run with Hermes' Python (see test_server_concepts.py).
"""
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import panel  # noqa: E402  (sets up Hermes' dependency paths first)
import httpx  # noqa: E402

NOW = 1_000_000.0


def http_error(code, headers=None):
    req = httpx.Request("GET", "https://api.anthropic.com/api/oauth/usage")
    return httpx.HTTPStatusError(str(code), request=req, response=httpx.Response(code, headers=headers or {}, request=req))


def entry(label, token, priority=0, source="x"):
    return SimpleNamespace(label=label, source=source, last_status="ok", request_count=0, priority=priority,
                           auth_type="oauth", runtime_api_key=token)


def usage_windows(used=24.0):
    return [SimpleNamespace(label="Current session", used_percent=used, reset_at=datetime.fromtimestamp(NOW + 3600)),
            SimpleNamespace(label="Current week", used_percent=17.0, reset_at=datetime.fromtimestamp(NOW + 86400))]


def profile_response(uuid):
    return SimpleNamespace(raise_for_status=lambda: None, json=lambda: {"account": {"uuid": uuid}})


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._db, panel.PANEL_DB = panel.PANEL_DB, Path(self._tmp.name) / "panel.db"
        panel._anthropic_reset_state()
        panel._anthropic_aliases.clear()

    def tearDown(self):
        panel.PANEL_DB = self._db
        panel._anthropic_reset_state()
        panel._anthropic_aliases.clear()
        self._tmp.cleanup()

    def items(self, entries, usage, profile, force=False):
        """_anthropic_account_items with fake pool entries, usage and profile calls -> (items, usage mock, profile mock)."""
        pool = SimpleNamespace(entries=lambda: entries)
        with mock.patch("agent.credential_pool.load_pool", return_value=pool), \
                mock.patch.object(panel, "_anthropic_windows", usage) as u, \
                mock.patch("httpx.get", profile) as p:
            return panel._anthropic_account_items(force), u, p

    def history(self, provider, rows):
        with panel.rw(panel.PANEL_DB) as c:
            c.execute("CREATE TABLE IF NOT EXISTS quota_history (ts REAL, provider TEXT, window TEXT, used REAL, reset REAL)")
            c.executemany("INSERT INTO quota_history VALUES (?,?,?,?,?)", [(ts, provider, w, u, r) for ts, w, u, r in rows])


TWO = lambda: [entry("claude_code", "tok-cc", priority=0), entry("ANTHROPIC_TOKEN", "tok-env", priority=1)]  # noqa: E731


class RateLimitKeepsLastValues(Base):
    def test_429_after_a_good_reading_shows_the_old_windows_as_stale(self):
        usage = mock.Mock(side_effect=[usage_windows(24.0), http_error(429)])
        profile = mock.Mock(return_value=profile_response("acct-1"))
        fresh, _, _ = self.items(TWO(), usage, profile)
        self.assertFalse(fresh[0]["stale"])
        self.assertEqual(fresh[0]["windows"][0]["used"], 24.0)
        read_at = fresh[0]["fetched_at"]

        out, _, _ = self.items(TWO(), usage, profile, force=True)  # force: past the usage TTL
        self.assertEqual(len(out), 1)
        it = out[0]
        self.assertTrue(it["stale"])
        self.assertEqual([w["used"] for w in it["windows"]], [24.0, 17.0])
        self.assertEqual(it["fetched_at"], read_at)
        self.assertEqual((it["unavailable_code"], it["unavailable_http"]), ("rate_limited", 429))
        self.assertEqual(it["unavailable"], "rate limited (HTTP 429)")
        self.assertGreater(it["retry_at"], time.time())

    def test_after_a_restart_the_last_known_windows_come_from_quota_history(self):
        key = panel.hashlib.sha256(b"acct-1").hexdigest()[:8]
        t = time.time()
        self.history(f"anthropic#{key}", [(t - 900, "Current session", 20.0, 5000.0), (t - 600, "Current session", 24.0, 6000.0),
                                          (t - 600, "Current week", 17.0, 9000.0)])
        usage = mock.Mock(side_effect=http_error(429))
        out, _, _ = self.items(TWO(), usage, mock.Mock(return_value=profile_response("acct-1")))
        it = out[0]
        self.assertTrue(it["stale"])
        self.assertEqual({w["label"]: w["used"] for w in it["windows"]}, {"Current session": 24.0, "Current week": 17.0})
        self.assertEqual(it["fetched_at"], t - 600)
        self.assertEqual(it["unavailable_http"], 429)

    def test_nothing_known_stays_empty_but_names_the_reason(self):
        out, _, _ = self.items(TWO(), mock.Mock(side_effect=http_error(429)), mock.Mock(return_value=profile_response("a")))
        self.assertEqual(out[0]["windows"], [])
        self.assertFalse(out[0]["stale"])
        self.assertEqual((out[0]["unavailable_code"], out[0]["unavailable_http"]), ("rate_limited", 429))

    def test_stale_item_is_not_written_to_history_as_a_new_reading(self):
        item = {"provider": "anthropic#k", "windows": [{"label": "Current session", "used": 24.0, "reset": 1.0}], "stale": True}
        fresh = {"provider": "anthropic#j", "windows": [{"label": "Current session", "used": 5.0, "reset": 1.0}], "stale": False}
        panel._record_quotas([item, fresh])
        with panel.rw(panel.PANEL_DB) as c:
            rows = c.execute("SELECT provider, used FROM quota_history").fetchall()
        self.assertEqual(rows, [("anthropic#j", 5.0)])

    def test_other_failures_also_keep_the_last_known_values(self):
        usage = mock.Mock(side_effect=[usage_windows(24.0), http_error(500), http_error(500)])
        profile = mock.Mock(return_value=profile_response("acct-1"))
        self.items(TWO(), usage, profile)
        out, _, _ = self.items(TWO(), usage, profile, force=True)
        self.assertTrue(out[0]["stale"])
        self.assertEqual((out[0]["unavailable_code"], out[0]["unavailable_http"]), ("usage_unreadable", 500))


class OneCallPerAccount(Base):
    def test_two_credentials_of_one_account_cost_one_usage_call(self):
        usage = mock.Mock(return_value=usage_windows())
        out, u, _ = self.items(TWO(), usage, mock.Mock(return_value=profile_response("same")))
        self.assertEqual(len(out), 1)
        self.assertEqual(len(out[0]["accounts"]), 2)
        self.assertEqual(u.call_count, 1)
        self.assertEqual(u.call_args.args[0], "tok-cc")  # the higher-priority credential

    def test_the_next_credential_is_tried_only_when_the_first_failed(self):
        usage = mock.Mock(side_effect=[http_error(401), usage_windows()])
        out, u, _ = self.items(TWO(), usage, mock.Mock(return_value=profile_response("same")))
        self.assertEqual([c.args[0] for c in u.call_args_list], ["tok-cc", "tok-env"])
        self.assertFalse(out[0]["stale"])
        self.assertEqual(out[0]["windows"][0]["used"], 24.0)

    def test_two_different_accounts_cost_one_call_each(self):
        usage = mock.Mock(return_value=usage_windows())
        profile = mock.Mock(side_effect=lambda url, **kw: profile_response("A" if "cc" in kw["headers"]["Authorization"] else "B"))
        out, u, _ = self.items(TWO(), usage, profile)
        self.assertEqual(len(out), 2)
        self.assertEqual(u.call_count, 2)

    def test_a_429_stops_the_round_before_the_other_accounts_are_asked(self):
        usage = mock.Mock(side_effect=http_error(429))
        profile = mock.Mock(side_effect=lambda url, **kw: profile_response("A" if "cc" in kw["headers"]["Authorization"] else "B"))
        out, u, _ = self.items(TWO(), usage, profile)
        self.assertEqual(u.call_count, 1)
        self.assertTrue(all(i["unavailable_http"] == 429 for i in out))

    def test_a_reading_younger_than_the_ttl_is_reused_without_a_request(self):
        usage = mock.Mock(return_value=usage_windows())
        profile = mock.Mock(return_value=profile_response("same"))
        first, _, _ = self.items(TWO(), usage, profile)
        again, u, p = self.items(TWO(), usage, profile)
        self.assertEqual(u.call_count, 1)  # still the one call of the first round
        self.assertEqual(again[0]["windows"], first[0]["windows"])
        self.assertFalse(again[0]["stale"])
        self.assertEqual(again[0]["fetched_at"], first[0]["fetched_at"])
        self.items(TWO(), usage, profile, force=True)
        self.assertEqual(usage.call_count, 2)  # "fetch now" skips the TTL


class IdentityCache(Base):
    def test_identity_is_asked_once_per_token(self):
        profile = mock.Mock(return_value=profile_response("acct-1"))
        with mock.patch("httpx.get", profile):
            for _ in range(3):
                self.assertEqual(panel._anthropic_identity("t1"), panel.hashlib.sha256(b"acct-1").hexdigest()[:8])
            self.assertEqual(profile.call_count, 1)
            panel._anthropic_identity("t2")  # a refreshed / other token is a new question
        self.assertEqual(profile.call_count, 2)

    def test_identity_survives_rounds_in_the_account_reader(self):
        usage = mock.Mock(return_value=usage_windows())
        profile = mock.Mock(return_value=profile_response("same"))
        self.items(TWO(), usage, profile)
        self.items(TWO(), usage, profile, force=True)
        self.assertEqual(profile.call_count, 2)  # one per credential, in the first round only

    def test_a_refused_identity_403_is_not_asked_again(self):
        profile = mock.Mock(side_effect=http_error(403))
        with mock.patch("httpx.get", profile):
            self.assertIsNone(panel._anthropic_identity("setup-token"))
            self.assertIsNone(panel._anthropic_identity("setup-token"))
        self.assertEqual(profile.call_count, 1)

    def test_nothing_is_asked_during_the_backoff_and_a_remembered_key_stands_in(self):
        with mock.patch("httpx.get", mock.Mock(return_value=profile_response("acct-1"))):
            key = panel._anthropic_identity("t-old", slot="claude_code|claude_code")
        panel._anthropic_reset_state()  # a restart: memory gone, panel.db remembers the slot
        panel._anthropic_rate_limited(http_error(429))
        profile = mock.Mock()
        with mock.patch("httpx.get", profile):
            self.assertEqual(panel._anthropic_identity("t-new", slot="claude_code|claude_code"), key)
            self.assertIsNone(panel._anthropic_identity("t-other", slot="other|other"))
        profile.assert_not_called()

    def test_a_429_on_the_identity_call_starts_the_backoff(self):
        with mock.patch("httpx.get", mock.Mock(side_effect=http_error(429, {"retry-after": "90"}))):
            panel._anthropic_identity("t1")
        self.assertAlmostEqual(panel._anthropic_wait(), 90, delta=2)


class Backoff(Base):
    def test_retry_after_seconds_is_honoured(self):
        self.assertEqual(panel._anthropic_rate_limited(http_error(429, {"retry-after": "37"}), NOW), 37)
        self.assertEqual(panel._anthropic_wait(NOW + 10), 27)

    def test_retry_after_http_date_is_honoured(self):
        date = "Wed, 21 Oct 2026 07:28:00 GMT"
        target = panel.parsedate_to_datetime(date).timestamp()
        with mock.patch("time.time", return_value=target - 600):
            self.assertAlmostEqual(panel._anthropic_rate_limited(http_error(429, {"retry-after": date})), 600, delta=1)

    def test_without_retry_after_the_wait_grows_2_4_8_15_minutes_and_stops_there(self):
        waits = [panel._anthropic_rate_limited(http_error(429), NOW + i * 10_000) for i in range(6)]
        self.assertEqual(waits, [120, 240, 480, 900, 900, 900])

    def test_huge_retry_after_is_clamped(self):
        self.assertEqual(panel._anthropic_rate_limited(http_error(429, {"retry-after": "999999"}), NOW),
                         panel.ANTHROPIC_RETRY_AFTER_MAX)

    def test_success_resets_the_ladder(self):
        panel._anthropic_rate_limited(http_error(429), NOW)
        panel._anthropic_rate_limited(http_error(429), NOW)
        panel._anthropic_ok()
        self.assertEqual(panel._anthropic_wait(), 0)
        self.assertEqual(panel._anthropic_rate_limited(http_error(429), NOW), 120)

    def test_no_request_to_anthropic_while_backing_off(self):
        usage = mock.Mock(side_effect=http_error(429, {"retry-after": "600"}))
        profile = mock.Mock(return_value=profile_response("same"))
        self.items(TWO(), usage, profile)
        calls = (usage.call_count, profile.call_count)
        for force in (False, True, True):
            out, _, _ = self.items(TWO(), usage, profile, force=force)
        self.assertEqual((usage.call_count, profile.call_count), calls)
        self.assertEqual(out[0]["unavailable_code"], "rate_limited")

    def test_single_credential_reader_also_backs_off(self):
        token = "oauth-token"
        import agent.anthropic_credentials as creds
        with mock.patch.object(creds, "resolve_anthropic_token", return_value=token), \
                mock.patch("agent.account_usage._is_oauth_token", return_value=True), \
                mock.patch.object(panel, "_anthropic_windows", mock.Mock(side_effect=http_error(429))) as w:
            snap = panel._anthropic_usage()
            self.assertEqual(snap.unavailable_reason, "rate limited")
            self.assertEqual(panel._anthropic_usage().unavailable_reason, "rate limited")
            self.assertEqual(w.call_count, 1)


class GroupKeepsHttpCode(unittest.TestCase):
    def test_http_code_survives_grouping_of_a_known_account(self):
        a = {"e": entry("a", "t"), "key": "k1", "wins": [], "err": "rate limited", "http": 429}
        b = {"e": entry("b", "t2"), "key": "k1", "wins": [], "err": "rate limited", "http": 429}
        out = panel._group_anthropic([a, b])
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["http"], 429)

    def test_http_code_survives_when_no_account_is_known(self):
        out = panel._group_anthropic([{"e": entry("a", "t"), "key": None, "wins": [], "err": "rate limited", "http": 429}])
        self.assertEqual(out[0]["http"], 429)


if __name__ == "__main__":
    unittest.main()
