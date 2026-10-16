"""Unit tests for the server concept fixes (account grouping, open sessions, kanban pairing, open actions).

Run with Hermes' Python (panel.py imports Hermes' bootstrap):
    PY=$(~/.hermes/hermes-agent/.hermes/bin/hermes --print-runtime-command | sed -E 's/^\\["([^"]+)".*/\\1/')
    "$PY" -m unittest discover -s tests -v
"""
import json
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import panel  # noqa: E402


def entry(label, source="x", priority=0, status="ok"):
    return SimpleNamespace(label=label, source=source, last_status=status, request_count=0, priority=priority)


def cred(label, key=None, wins=None, err=None, http=None):
    return {"e": entry(label), "key": key, "wins": wins or [], "err": err, "http": http}


def win(label="Current session", used=15.0, reset=1000.0):
    return {"label": label, "used": used, "reset": reset, "detail": None}


class GroupAnthropic(unittest.TestCase):
    def test_same_account_two_credentials_is_one_item(self):
        out = panel._group_anthropic([cred("a", "k1", [win()]), cred("b", "k1", [win()])])
        self.assertEqual(len(out), 1)
        self.assertEqual(len(out[0]["creds"]), 2)

    def test_two_real_accounts_are_two_items(self):  # acceptance A3
        out = panel._group_anthropic([cred("a", "k1", [win(used=10)]), cred("b", "k2", [win(used=40)])])
        self.assertEqual(sorted(g["key"] for g in out), ["k1", "k2"])

    def test_unreadable_credential_never_gets_its_own_item(self):  # the 403 ANTHROPIC_TOKEN case
        out = panel._group_anthropic([cred("tok", None, [], "usage not readable right now", 403),
                                      cred("claude_code", "k1", [win()])])
        self.assertEqual(len(out), 1)
        by = {c["e"].label: c["status_of"] for c in out[0]["creds"]}
        self.assertEqual(by, {"claude_code": "verified", "tok": "unverified"})

    def test_nothing_readable_gives_one_plain_item(self):
        out = panel._group_anthropic([cred("a", None, [], "x", 403), cred("b", None, [], "x", 403)])
        self.assertEqual(len(out), 1)
        self.assertIsNone(out[0]["key"])
        self.assertEqual(len(out[0]["creds"]), 2)

    def test_identical_windows_merge_without_identity(self):  # the safe fallback
        out = panel._group_anthropic([cred("a", "k1", [win()]), cred("b", None, [win()])])
        self.assertEqual(len(out), 1)
        self.assertEqual({c["status_of"] for c in out[0]["creds"]}, {"verified", "same_windows"})

    def test_different_windows_without_identity_stay_apart(self):
        out = panel._group_anthropic([cred("a", "k1", [win(used=10)]), cred("b", None, [win(used=11)])])
        self.assertEqual(len(out), 2)


class QuotaHistoryAlias(unittest.TestCase):
    def test_old_per_label_series_follow_the_account(self):
        with tempfile.TemporaryDirectory() as d:
            old = panel.PANEL_DB
            panel.PANEL_DB = Path(d) / "panel.db"
            try:
                with panel.rw(panel.PANEL_DB) as c:
                    c.execute("CREATE TABLE quota_history (ts REAL, provider TEXT, window TEXT, used REAL, reset REAL)")
                    c.executemany("INSERT INTO quota_history VALUES (?,?,?,?,?)",
                                  [(10, "anthropic#claude_code", "Current session", 5, 0),
                                   (20, "anthropic#k1", "Current session", 7, 0)])
                panel._anthropic_aliases["anthropic#claude_code"] = "anthropic#k1"
                hist = panel.quota_history(0, 100)
            finally:
                panel.PANEL_DB = old
                panel._anthropic_aliases.pop("anthropic#claude_code", None)
        self.assertEqual(len(hist), 1)
        self.assertEqual(hist[0]["provider"], "anthropic#k1")
        self.assertEqual([p[0] for p in hist[0]["points"]], [10, 20])


class OpenSessions(unittest.TestCase):
    def test_leased_source_is_open_exactly_while_lease_lives(self):
        now = time.time()
        quiet = now - 5000
        self.assertTrue(panel.main_is_open("desktop", "s1", quiet, {"s1"}, now))   # silent but open
        self.assertFalse(panel.main_is_open("desktop", "s1", now, set(), now))     # recent but window closed
        self.assertFalse(panel.main_is_open("cli", "s1", now, set(), now))

    def test_unleased_source_uses_window_or_lease(self):
        now = time.time()
        self.assertTrue(panel.main_is_open("telegram", "s", now - 10, set(), now))
        self.assertFalse(panel.main_is_open("telegram", "s", now - 5000, set(), now))
        self.assertTrue(panel.main_is_open("kanban", "s", now - 5000, {"s"}, now))  # kanban worker with a lease


class KanbanPairing(unittest.TestCase):
    def card(self, cid, pid=None, status="running", assignee="developer", title="T", started=1000.0):
        return {"id": cid, "board": "default", "title": title, "assignee": assignee, "status": status,
                "started_at": started, "heartbeat": None, "worker_pid": pid, "block_kind": None}

    def row(self, sid, **kw):
        r = {"id": sid, "origin": "kanban", "subagent": False, "profile": "developer", "title": "T",
             "started": 1010.0, "_pid": None, "_first_user": ""}
        r.update(kw)
        return r

    def test_pairs_by_worker_pid_not_by_profile(self):
        cards = {"t_a": self.card("t_a", pid=11, title="A"), "t_b": self.card("t_b", pid=22, title="B")}
        r1, r2 = self.row("s1", _pid=22, title="x"), self.row("s2", _pid=11, title="y")
        panel.match_kanban_sessions([r1, r2], cards)
        self.assertEqual(r1["kanban"]["id"], "t_b")
        self.assertEqual(r2["kanban"]["id"], "t_a")

    def test_pairs_by_task_id_in_first_message(self):
        cards = {"t_ab12": self.card("t_ab12", title="A")}
        r = self.row("s1", _first_user="work kanban task t_ab12")
        panel.match_kanban_sessions([r], cards)
        self.assertEqual(r["kanban"]["id"], "t_ab12")

    def test_title_fallback_and_no_double_use(self):
        cards = {"t_a": self.card("t_a", title="Same")}
        r1, r2 = self.row("s1", title="Same"), self.row("s2", title="Same")
        taken = panel.match_kanban_sessions([r1, r2], cards)
        self.assertEqual(taken, {"t_a"})
        self.assertEqual([bool(r1.get("kanban")), bool(r2.get("kanban"))].count(True), 1)

    def test_other_profiles_session_gets_no_card(self):
        cards = {"t_a": self.card("t_a", title="Card")}
        r = self.row("desktop1", origin="desktop", title="Card")
        panel.match_kanban_sessions([r], cards)
        self.assertNotIn("kanban", r)

    def test_unpaired_running_card_still_gets_a_row(self):
        row = panel.card_only_row(self.card("t_z", pid=999999999, title="Orphan"), time.time())
        self.assertEqual((row["status"], row["origin"], row["state"], row["kanban"]["id"]),
                         ("running", "kanban", "stalled", "t_z"))


class OpenAction(unittest.TestCase):
    def test_hermes_session_command_has_profile(self):
        o = panel.open_hermes_session("lead", "20260101_000000_abc123", "cli", "Title")
        self.assertEqual(o["command"], "hermes -p lead --resume 20260101_000000_abc123")
        self.assertEqual(o["kind"], "hermes-session")

    def test_every_origin_gets_the_url_when_the_app_is_installed(self):
        # hermes://open/<id> was run for real for a desktop session of another profile, a CLI session and a kanban
        # worker session: the desktop app opened each of them
        old = panel.hermes_desktop_installed
        try:
            panel.hermes_desktop_installed = lambda: True
            for origin in ("desktop", "cli", "tui", "kanban", "telegram"):
                self.assertEqual(panel.open_hermes_session("lead", "s1", origin, "t")["url"], "hermes://open/s1")
        finally:
            panel.hermes_desktop_installed = old

    def test_default_profile_has_no_p_flag(self):
        self.assertEqual(panel.open_hermes_session("default", "s1", "cli", "t")["command"], "hermes --resume s1")

    def test_desktop_url_only_when_app_installed(self):
        old = panel.hermes_desktop_installed
        try:
            panel.hermes_desktop_installed = lambda: True
            self.assertEqual(panel.open_hermes_session("lead", "s1", "desktop", "t")["url"], "hermes://open/s1")
            panel.hermes_desktop_installed = lambda: False
            self.assertIsNone(panel.open_hermes_session("lead", "s1", "desktop", "t")["url"])
        finally:
            panel.hermes_desktop_installed = old

    def test_kanban_board_flag_goes_before_the_verb(self):
        self.assertEqual(panel.open_kanban_card("t_1", "default", "x")["command"], "hermes kanban show t_1")
        self.assertEqual(panel.open_kanban_card("t_1", "work", "x")["command"], "hermes kanban --board work show t_1")

    def test_ids_are_shell_quoted(self):
        self.assertIn("'a b; rm'", panel.open_cli_session("copilot-cli", "a b; rm", None, "t")["command"])

    def test_claude_command_changes_directory(self):
        o = panel.open_cli_session("claude-code", "abc", "/tmp/my proj", "t")
        self.assertEqual(o["command"], "cd '/tmp/my proj' && claude --resume abc")

    def test_waiting_for_card(self):
        self.assertEqual(panel.card_waiting_for("blocked", "needs_input"), "input")
        self.assertIsNone(panel.card_waiting_for("blocked", None))
        self.assertEqual(panel.card_waiting_for("review", None), "review")


class OpenForRow(unittest.TestCase):
    def base(self, **kw):
        r = {"id": "s1", "profile": "lead", "origin": "desktop", "kind": "hermes", "subagent": False, "parent": None,
             "title": "T", "state": "needs_approval", "kanban": None, "status": "running"}
        r.update(kw)
        return r

    def test_needs_approval_session_has_an_open_action(self):
        o = panel._open_for(self.base(), {})
        self.assertEqual(o["kind"], "hermes-session")
        self.assertTrue(o["command"])

    def test_kanban_row_opens_the_card_and_keeps_the_session_command(self):
        r = self.base(origin="kanban", profile="developer", kanban={"id": "t_1", "board": "default", "title": "C"})
        o = panel._open_for(r, {})
        self.assertEqual((o["kind"], o["command"], o["session_command"]),
                         ("kanban-card", "hermes kanban show t_1", "hermes -p developer --resume s1"))

    def test_card_only_row_has_no_session_command(self):
        r = self.base(origin="kanban", card_only=True, id="t_1", kanban={"id": "t_1", "board": "default", "title": "C"})
        self.assertNotIn("session_command", panel._open_for(r, {}))

    def test_hermes_subagent_opens_its_parent(self):
        r = self.base(subagent=True, parent="p1", _psource="cli", parent_title="Parent")
        self.assertEqual(panel._open_for(r, {})["command"], "hermes -p lead --resume p1")

    def test_unknown_kind_is_none(self):
        self.assertEqual(panel._open_for(self.base(kind="droid"), {})["kind"], "none")

    def test_kanban_worker_row_carries_its_session_url(self):
        old = panel.hermes_desktop_installed
        try:
            panel.hermes_desktop_installed = lambda: True
            r = self.base(origin="kanban", profile="developer", kanban={"id": "t_1", "board": "default", "title": "C"})
            o = panel._open_for(r, {}, {})
            self.assertEqual((o["url"], o["session_url"]), ("hermes://open/kanban", "hermes://open/s1"))
            only = panel._open_for(self.base(origin="kanban", card_only=True, id="t_1",
                                             kanban={"id": "t_1", "board": "default", "title": "C"}), {}, {})
            self.assertNotIn("session_url", only)
            self.assertFalse(only["running"])
        finally:
            panel.hermes_desktop_installed = old

    def test_process_facts_are_always_present(self):
        o = panel._open_for(self.base(), {}, {})
        for k in ("running", "pid", "tty", "app", "app_pid", "background", "attach"):
            self.assertIn(k, o)
        self.assertFalse(o["running"])  # no pid known

    def test_claude_background_session_gets_an_attach_command(self):
        r = self.base(kind="claude-code", origin="claude-code", id="29517443-aaaa", _bg=True, _job="29517443", _pid=None)
        self.assertEqual(panel._open_for(r, {}, {})["attach"], "claude attach 29517443")
        r = self.base(kind="claude-code", origin="claude-code", id="29517443-aaaa", _bg=False)
        self.assertIsNone(panel._open_for(r, {}, {})["attach"])
        self.assertEqual(panel.claude_attach_command("abcdefgh-1234"), "claude attach abcdefgh")  # no job id: short id

    def test_subagent_open_uses_the_parents_process(self):
        parent = self.base(id="p1", _pid=4242)
        sub = self.base(id="s9", subagent=True, parent="p1", _psource="cli", parent_title="P")
        table = {4242: (1, "ttys009", "/usr/bin/python3 hermes")}
        old = panel.clis.pid_alive
        try:
            panel.clis.pid_alive = lambda p: p in table
            o = panel._open_for(sub, {("lead", "p1"): parent}, table)
        finally:
            panel.clis.pid_alive = old
        self.assertEqual((o["pid"], o["tty"], o["running"]), (4242, "ttys009", True))


class ProcessInfo(unittest.TestCase):
    PS = """\
    1     0 ??       /sbin/launchd
 1692     1 ??       /Applications/Hermes.app/Contents/MacOS/Hermes
 1763  1692 ??       /Users/x/python3 -I -c import os
  500     1 ??       /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
  510   500 ??       login -pf asim
  511   510 ttys002  -zsh
  512   511 ttys002  /Users/x/python3 -m hermes_cli.main --cli
15734     1 ??       /Users/x/.local/bin/claude daemon run
15760 15734 ??       claude bg-pty-host --bg-pty-host /tmp/s.sock 200 50 -- /v/claude --bg-spare /tmp/c.sock
15784 15760 ttys004  claude bg-spare --bg-spare /tmp/c.sock
  900     1 ??       /Applications/Agent Bar.app/Contents/MacOS/AgentBar
  901   900 ttys005  /bin/zsh
"""

    def info(self, pid):
        table = panel.parse_ps(self.PS)
        old = panel.clis.pid_alive
        try:
            panel.clis.pid_alive = lambda p: True
            return panel.process_info(pid, table)
        finally:
            panel.clis.pid_alive = old

    def test_parse(self):
        t = panel.parse_ps(self.PS)
        self.assertEqual(t[511], (510, "ttys002", "-zsh"))
        self.assertIsNone(t[1763][1])  # "??" = no tty

    def test_desktop_session_is_hosted_by_the_app(self):
        i = self.info(1763)
        self.assertEqual((i["app"], i["app_pid"], i["tty"], i["background"]), ("/Applications/Hermes.app", 1692, None, False))

    def test_cli_in_terminal_has_tty_and_terminal_app(self):
        i = self.info(512)
        self.assertEqual((i["tty"], i["app"], i["app_pid"]),
                         ("ttys002", "/System/Applications/Utilities/Terminal.app", 500))

    def test_background_claude_session_has_no_window(self):
        i = self.info(15784)
        self.assertEqual((i["app"], i["background"], i["tty"]), (None, True, "ttys004"))

    def test_app_path_with_a_space(self):
        self.assertEqual(self.info(901)["app"], "/Applications/Agent Bar.app")

    def test_dead_or_unknown_pid(self):
        self.assertIsNone(self.info(99999))
        self.assertIsNone(panel.process_info(None, {}))
        table = panel.parse_ps(self.PS)
        old = panel.clis.pid_alive
        try:
            panel.clis.pid_alive = lambda p: False
            self.assertIsNone(panel.process_info(512, table))
        finally:
            panel.clis.pid_alive = old


class HermesState(unittest.TestCase):
    def conn(self, tool_calls, quiet):
        c = sqlite3.connect(":memory:")
        c.row_factory = sqlite3.Row
        c.executescript("""CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
                           api_content TEXT, tool_calls TEXT, reasoning_content TEXT, timestamp REAL, active INT);
                           CREATE TABLE session_turn_leases (conversation_id TEXT, expires_at REAL);""")
        c.execute("INSERT INTO messages (session_id, role, content, tool_calls, timestamp, active) VALUES (?,?,?,?,?,1)",
                  ("s", "assistant", "", tool_calls, time.time() - quiet))
        c.execute("INSERT INTO session_turn_leases VALUES ('s', ?)", (time.time() + 60,))
        return c

    def test_long_tool_call_is_working_not_stalled(self):  # acceptance B4
        calls = json.dumps([{"function": {"name": "terminal", "arguments": "{}"}}])
        st = panel._hermes_state(self.conn(calls, 900), "s", None, time.time())
        self.assertEqual(st["state"], "working")
        self.assertEqual(st["long_tool_call"], "terminal")

    def test_tool_call_past_the_longer_limit_is_stalled(self):
        calls = json.dumps([{"function": {"name": "terminal", "arguments": "{}"}}])
        self.assertEqual(panel._hermes_state(self.conn(calls, 2000), "s", None, time.time())["state"], "stalled")

    def test_no_tool_call_stalls_after_ten_minutes(self):
        self.assertEqual(panel._hermes_state(self.conn(None, 900), "s", None, time.time())["state"], "stalled")


if __name__ == "__main__":
    unittest.main()
