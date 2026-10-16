#!/usr/bin/env python3
"""Agent Monitor — multi-page dashboard: overview, accounts & quotas, agents, subagents, kanban.

Reads Hermes data read-only. The only writes go to the panel's own panel.db (quota history).
Start with ./run.sh, which uses the same Python runtime as Hermes itself.
Then open http://127.0.0.1:8777 (AGENT_MONITOR_PORT=<port> ./run.sh to listen elsewhere).
"""
import concurrent.futures
import hashlib
import json
import os
import re
import resource
import shlex
import sqlite3
import sys
import threading
import time
from collections import defaultdict
from contextlib import contextmanager
from datetime import date, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

HOME = Path.home() / ".hermes"
sys.path.insert(0, str(HOME / "hermes-agent"))
import hermes_bootstrap  # noqa: E402,F401 — sets up Hermes' dependency paths

sys.path.insert(0, str(Path(__file__).parent))
import clis  # noqa: E402
import health  # noqa: E402

try:
    PORT = int(os.environ.get("AGENT_MONITOR_PORT") or 8777)
except ValueError:
    PORT = 8777
HERE = Path(__file__).parent
PANEL_DB = HERE / "panel.db"
QUOTA_TTL = 120          # provider usage APIs are cached this many seconds
QUOTA_RECORD_EVERY = 300  # background quota snapshot interval (history charts)
ACTIVE_WINDOW = 600       # a session with activity in the last N seconds counts as running

_quota_cache = {"at": 0.0, "data": None}
_quota_lock = threading.Lock()


# ---------- helpers ----------

@contextmanager
def ro(db: Path):
    """Read-only connection that is always closed (sqlite3's own `with` only commits)."""
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


@contextmanager
def rw(db: Path):
    conn = sqlite3.connect(db, timeout=5)
    try:
        with conn:
            yield conn
    finally:
        conn.close()


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def day_of(ts) -> str:
    return datetime.fromtimestamp(ts).date().isoformat()


def parse_range(q):
    """from/to are local YYYY-MM-DD dates, inclusive. Default: last 30 days."""
    today = date.today()
    try:
        d_to = date.fromisoformat(q.get("to", [""])[0])
    except ValueError:
        d_to = today
    try:
        d_from = date.fromisoformat(q.get("from", [""])[0])
    except ValueError:
        d_from = d_to - timedelta(days=29)
    if d_from > d_to:
        d_from, d_to = d_to, d_from
    start = datetime.combine(d_from, datetime.min.time()).timestamp()
    end = datetime.combine(d_to + timedelta(days=1), datetime.min.time()).timestamp()
    days = [(d_from + timedelta(days=i)).isoformat() for i in range((d_to - d_from).days + 1)]
    return start, end, days


def profile_homes():
    yield "default", HOME
    root = HOME / "profiles"
    if root.is_dir():
        for p in sorted(root.iterdir()):
            if p.is_dir() and not p.name.startswith("."):
                yield p.name, p


def read_model(home: Path):
    try:
        from ruamel.yaml import YAML
        cfg = YAML(typ="safe").load((home / "config.yaml").read_text()) or {}
        m = cfg.get("model") or {}
        return m.get("provider"), m.get("default")
    except Exception:
        return None, None


def cost_expr(prefix=""):
    return f"coalesce({prefix}actual_cost_usd, {prefix}estimated_cost_usd, 0)"


def session_costs(c, ids=None):
    """{session_id: (cost, tokens)} from the sessions table — model usage rows carry no cost,
    so a session's cost is split across its models by token share."""
    sql = f"SELECT id, {cost_expr()} cost, coalesce(input_tokens,0)+coalesce(output_tokens,0) tok FROM sessions"
    if ids is not None:
        ids = list(ids)
        if not ids:
            return {}
        sql += f" WHERE id IN ({','.join('?' * len(ids))})"
    return {r["id"]: (r["cost"], r["tok"]) for r in c.execute(sql, ids or ())}


def row_cost(row_cost_value, row_tok, sess):
    if row_cost_value:
        return row_cost_value
    if not sess or not sess[0]:
        return 0.0
    cost, tok = sess
    return cost * (row_tok / tok) if tok else 0.0


# ---------- accounts & quotas ----------

WINDOW_BY_SECONDS = {18000: "Current session", 86400: "Current day", 604800: "Current week",
                     2592000: "Current month"}


COPILOT_QUOTAS = {"premium_interactions": "Premium requests", "chat": "Chat", "completions": "Completions"}


def _copilot_usage():
    """GitHub Copilot has no Hermes usage fetcher: read the monthly quota snapshot that the Copilot
    clients themselves use (read-only GET with the pooled gh token)."""
    import httpx
    from agent.account_usage import AccountUsageSnapshot, AccountUsageWindow
    from agent.credential_pool import load_pool

    for e in load_pool("copilot").entries():
        try:
            r = httpx.get("https://api.github.com/copilot_internal/user", timeout=15,
                          headers={"Authorization": f"token {e.runtime_api_key}", "Accept": "application/json"})
            r.raise_for_status()
            d = r.json()
        except Exception:
            continue
        reset = None
        try:
            reset = datetime.fromisoformat(d["quota_reset_date_utc"].replace("Z", "+00:00"))
        except (KeyError, TypeError, ValueError, AttributeError):
            pass
        windows = []
        for key, label in COPILOT_QUOTAS.items():
            q = (d.get("quota_snapshots") or {}).get(key)
            if not isinstance(q, dict) or q.get("unlimited"):
                continue
            ent = q.get("entitlement") or 0
            used = q.get("credits_used", ent - (q.get("remaining") or 0))
            windows.append(AccountUsageWindow(
                label=label, used_percent=max(0.0, 100.0 - float(q.get("percent_remaining") or 0)),
                reset_at=reset, detail=f"{used:g} / {ent:g}" if ent else None))
        return AccountUsageSnapshot(provider="copilot", source="copilot_internal", fetched_at=datetime.now(),
                                    plan=(d.get("copilot_plan") or "").title() or None, windows=tuple(windows))
    return None


ANTHROPIC_WINDOWS = (("five_hour", "Current session"), ("seven_day", "Current week"),
                     ("seven_day_opus", "Opus week"), ("seven_day_sonnet", "Sonnet week"))


def _anthropic_usage():
    """Claude OAuth usage, read like Hermes does but without its fraction guess: the API reports utilization in
    percent (0-100), and Hermes scales any value <= 1 by 100, so a fresh window at 1% (or 0.5%) shows as 100% (50%)."""
    from agent.account_usage import AccountUsageSnapshot, AccountUsageWindow, _get_json, _is_oauth_token, _parse_dt
    from agent.anthropic_credentials import resolve_anthropic_token

    token = (resolve_anthropic_token() or "").strip()
    if not token or not _is_oauth_token(token):
        return None  # API-key accounts have no usage windows; let Hermes' helper report that
    return AccountUsageSnapshot(provider="anthropic", source="oauth_usage_api", fetched_at=datetime.now(),
                                windows=tuple(_anthropic_windows(token)))


def _anthropic_windows(token):
    from agent.account_usage import AccountUsageWindow, _get_json, _parse_dt

    payload = _get_json("https://api.anthropic.com/api/oauth/usage",
                        {"Authorization": f"Bearer {token}", "Accept": "application/json",
                         "anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-code/2.1.0"}, timeout=15.0)
    windows = []
    for key, label in ANTHROPIC_WINDOWS:
        w = payload.get(key) or {}
        if w.get("utilization") is None:
            continue
        windows.append(AccountUsageWindow(label=label, used_percent=float(w["utilization"]),
                                          reset_at=_parse_dt(w.get("resets_at"))))
    return windows


ANTHROPIC_PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
_anthropic_aliases = {}  # old quota_history provider id -> current "anthropic#<account-key>" (see quota_history)


def _anthropic_identity(token):
    """Account key of a Claude OAuth credential, or None when it cannot be read.

    Source: Anthropic's OAuth profile endpoint (GET https://api.anthropic.com/api/oauth/profile, the one Claude Code
    itself calls). Its answer carries `account.uuid` (and `organization.uuid`); the key is the first 8 hex digits of
    sha256(account uuid), so the raw id never leaves this process. Tokens without the `user:profile` scope (e.g. a
    setup token in ANTHROPIC_TOKEN) get HTTP 403 and stay unreadable (None) — never guessed from the label."""
    import httpx

    try:
        r = httpx.get(ANTHROPIC_PROFILE_URL, timeout=15,
                      headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                               "anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-code/2.1.0"})
        r.raise_for_status()
        uid = ((r.json() or {}).get("account") or {}).get("uuid")
    except Exception:
        return None
    return hashlib.sha256(str(uid).encode()).hexdigest()[:8] if uid else None


def _windows_sig(wins):
    """Fingerprint of a credential's usage windows: equal only when every window matches to the digit."""
    return tuple(sorted((w["label"], round(w["used"], 4), round(w["reset"] or 0)) for w in wins))


def _group_anthropic(creds):
    """Group pooled Claude credentials by the account behind them -> list of quota items.

    creds: [{"e": pool entry (label/source/...), "key": account key | None, "wins": [...], "err": str | None,
             "http": int | None}]
    1. identity readable           -> grouped by account key;
    2. identity unreadable but the usage windows are readable -> joins the group whose windows are identical to the
       digit (same account, same moment), else stays its own item (key = hash of the windows);
    3. nothing readable (403/timeout) -> never its own item: listed as "unverified" under the first item, or, when no
       credential at all is readable, all together under one plain "anthropic" item."""
    groups = {}  # key -> {"creds": [...], "wins": [...], "err": ...}
    unreadable = []
    for c in creds:
        if c["key"]:
            g = groups.setdefault(c["key"], {"creds": [], "wins": [], "err": None})
            g["creds"].append(dict(c, status_of="verified"))
            if c["wins"] and not g["wins"]:
                g["wins"] = c["wins"]
            if c["err"] and not c["wins"]:
                g["err"] = g["err"] or c["err"]
    for c in creds:
        if c["key"]:
            continue
        if c["wins"]:
            sig = _windows_sig(c["wins"])
            hit = next((g for g in groups.values() if g["wins"] and _windows_sig(g["wins"]) == sig), None)
            if hit is not None:
                hit["creds"].append(dict(c, status_of="same_windows"))
            else:
                k = "w" + hashlib.sha256(repr(sig).encode()).hexdigest()[:7]
                g = groups.setdefault(k, {"creds": [], "wins": c["wins"], "err": None})
                g["creds"].append(dict(c, status_of="same_windows" if g["creds"] else "windows_only"))
        else:
            unreadable.append(c)
    if unreadable and not groups:
        # nothing is readable: one plain item holds every credential
        return [{"key": None, "creds": [dict(c, status_of="unverified") for c in unreadable], "wins": [],
                 "err": next((c["err"] for c in unreadable if c["err"]), None),
                 "http": next((c["http"] for c in unreadable if c["http"]), None)}]
    if unreadable:
        first = next(iter(groups.values()))
        first["creds"] += [dict(c, status_of="unverified") for c in unreadable]
    return [dict(g, key=k) for k, g in groups.items()]


def _anthropic_account_items():
    """Claude OAuth credentials in Hermes' pool grouped by the ACCOUNT behind them (provider id
    "anthropic#<account-key>"), each read with its own token; None when the pool has fewer than 2 OAuth entries.
    Two credentials of one account (e.g. ANTHROPIC_TOKEN + claude_code) become ONE item with both in `accounts`."""
    from agent.credential_pool import load_pool

    entries = [e for e in load_pool("anthropic").entries() if e.auth_type == "oauth"]
    if len(entries) < 2:
        return None

    def one(e):
        key = _anthropic_identity(e.runtime_api_key)
        try:
            wins = [{"label": w.label, "used": w.used_percent, "reset": w.reset_at.timestamp() if w.reset_at else None,
                     "detail": None} for w in _anthropic_windows(e.runtime_api_key)]
            return {"e": e, "key": key, "wins": wins, "err": None, "http": None}
        except Exception as ex:  # an expired token is refreshed by Hermes on its next use of that account
            code = getattr(getattr(ex, "response", None), "status_code", None)
            return {"e": e, "key": key, "wins": [], "err": "usage not readable right now", "http": code}

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        creds = list(pool.map(one, entries))
    items = []
    for g in _group_anthropic(creds):
        accs = []
        for c in g["creds"]:
            e = c["e"]
            acc = {"label": e.label, "source": e.source, "status": e.last_status, "requests": e.request_count,
                   "priority": e.priority, "account_key": c["key"] or (g["key"] if c["status_of"] != "unverified" else None)}
            if c["status_of"] == "unverified":
                # listed with the item, but nothing says it is the same account: no account_key of its own
                # (reason code; clients translate)
                acc.update(verification="unverified", reason="usage_unreadable", http=c["http"], listed_under=g["key"])
            else:
                acc["verification"] = c["status_of"]
            accs.append(acc)
        accs.sort(key=lambda a: (a["priority"] if a["priority"] is not None else 99, a["label"] or ""))
        err = None if g["wins"] else (g["err"] or None)
        items.append({"provider": f"anthropic#{g['key']}" if g["key"] else "anthropic",
                      "account_key": g["key"], "accounts": accs, "windows": g["wins"], "details": [], "plan": None,
                      "unavailable": (f"{err} (HTTP {g['http']})" if g.get("http") else err) if err else None,
                      "unavailable_code": "usage_unreadable" if err else None,
                      "unavailable_http": g.get("http") if err else None})
        for c in g["creds"]:  # history written under the old per-label ids follows the account
            _anthropic_aliases[f"anthropic#{c['e'].label}"] = items[-1]["provider"]
    if len(items) == 1:  # one account: every older anthropic series belongs to it
        _anthropic_aliases["anthropic"] = items[0]["provider"]
    return items


def _usage_snapshot(prov):
    if prov == "copilot":
        return _copilot_usage()
    if prov == "anthropic":
        try:
            snap = _anthropic_usage()
        except Exception:
            snap = None
        if snap is not None:
            return snap
    """Hermes' own fetch picks a credential via pool.select(), which skips exhausted ones, so a provider
    whose only account hit its limit shows nothing. The usage endpoint still answers for it: retry with
    each pooled credential explicitly (a read-only GET with that account's own token)."""
    from agent.account_usage import _USAGE_FETCHERS, fetch_account_usage
    from agent.credential_pool import load_pool

    snap = fetch_account_usage(prov)
    if snap is None and prov in _USAGE_FETCHERS:
        for e in load_pool(prov).entries():
            try:
                snap = fetch_account_usage(prov, base_url=e.runtime_base_url, api_key=e.runtime_api_key)
            except Exception:
                snap = None
            if snap is not None:
                break
    return snap


def _window_label(w, snap):
    """Hermes labels Codex windows by a fixed duration table and falls back to 'Session' for others
    (a 30-day free-plan limit shows up as 'Session'); relabel from the published window length."""
    rl = ((getattr(snap, "raw", None) or {}).get("rate_limit") or {}) if snap else {}
    for key in ("primary_window", "secondary_window"):
        win = rl.get(key)
        if isinstance(win, dict) and w.reset_at and win.get("reset_at") == int(w.reset_at.timestamp()):
            secs = win.get("limit_window_seconds")
            if isinstance(secs, (int, float)):
                return WINDOW_BY_SECONDS.get(int(secs), f"{round(secs / 86400)}-day window" if secs >= 86400 else w.label)
    return w.label


def _fetch_quotas():
    from agent.credential_pool import load_pool
    from hermes_cli.auth import read_credential_pool

    providers = set(read_credential_pool().keys())
    for _, home in profile_homes():
        prov, _ = read_model(home)
        if prov:
            providers.add(prov)

    out = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {p: pool.submit(_usage_snapshot, p) for p in sorted(providers)}
        for prov, fut in futures.items():
            try:
                snap = fut.result(timeout=20)
            except Exception:
                snap = None
            try:
                entries = [
                    {"label": e.label, "source": e.source, "status": e.last_status,
                     "requests": e.request_count, "priority": e.priority}
                    for e in load_pool(prov).entries()
                ]
            except Exception:
                entries = []
            item = {"provider": prov, "accounts": entries, "windows": [], "details": [],
                    "plan": None, "unavailable": None}
            if snap is not None:
                item["plan"] = snap.plan
                item["details"] = list(snap.details)
                item["unavailable"] = snap.unavailable_reason
                item["windows"] = [
                    {"label": _window_label(w, snap), "used": w.used_percent,
                     "reset": w.reset_at.timestamp() if w.reset_at else None, "detail": w.detail}
                    for w in snap.windows
                ]
            elif not entries:
                continue
            if prov == "anthropic":
                try:
                    split = _anthropic_account_items()
                except Exception:
                    split = None
                if split:
                    out.extend(split)
                    continue
            out.append(item)
    return out


def _record_quotas(items):
    with rw(PANEL_DB) as c:
        c.execute("""CREATE TABLE IF NOT EXISTS quota_history
                     (ts REAL, provider TEXT, window TEXT, used REAL, reset REAL)""")
        now = time.time()
        c.executemany("INSERT INTO quota_history VALUES (?,?,?,?,?)",
                      [(now, it["provider"], w["label"], w["used"], w["reset"])
                       for it in items for w in it["windows"] if w["used"] is not None])


def _refresh_quotas():
    # provider APIs can take up to ~20 s; only one refresh runs at a time
    if not _quota_lock.acquire(blocking=False):
        return
    try:
        try:
            items = _fetch_quotas()
            _quota_cache["data"] = {"items": items, "error": None}
            _record_quotas(items)
        except Exception as e:
            _quota_cache["data"] = {"items": [], "error": str(e)}
        _quota_cache["at"] = time.time()
    finally:
        _quota_lock.release()


FORCE_MIN_INTERVAL = 30  # "fetch now" hits the providers with your credentials: at most this often


def quotas(force=False):
    """Never blocks page loads: returns the last snapshot and refreshes in the background.
    force=True (the "fetch now" button) waits for a fresh snapshot, unless one is younger than FORCE_MIN_INTERVAL."""
    if force and time.time() - _quota_cache["at"] < FORCE_MIN_INTERVAL:
        force = False
    if force:
        _refresh_quotas()
    elif not _quota_cache["data"] or time.time() - _quota_cache["at"] > QUOTA_TTL:
        threading.Thread(target=_refresh_quotas, daemon=True).start()
    data = _quota_cache["data"] or {"items": [], "error": None, "loading": True}
    return {**data, "fetched_at": _quota_cache["at"] or None}


def quota_history(start, end):
    if not PANEL_DB.exists():
        return []
    with rw(PANEL_DB) as c:
        c.execute("""CREATE TABLE IF NOT EXISTS quota_history
                     (ts REAL, provider TEXT, window TEXT, used REAL, reset REAL)""")
        rows = c.execute("""SELECT ts, provider, window, used FROM quota_history
                            WHERE ts >= ? AND ts < ? ORDER BY ts""", (start, end)).fetchall()
    series = defaultdict(list)
    for ts, prov, win, used in rows:
        # an account's key replaced the old per-label id: keep the old series under the current one
        series[(_anthropic_aliases.get(prov, prov), win)].append([ts, used])
    return [{"provider": p, "window": w, "points": sorted(pts)} for (p, w), pts in series.items()]


def _quota_recorder():
    while True:
        try:
            _refresh_quotas()
        except Exception:
            pass
        time.sleep(QUOTA_RECORD_EVERY)


# ---------- usage (overview / accounts) ----------

def usage(start, end, days, profile=None):
    """Per-model usage rows from every profile's state.db, bucketed by local day of last_seen."""
    by_day_provider = defaultdict(lambda: defaultdict(lambda: {"tokens": 0, "cost": 0.0}))
    by_provider = defaultdict(lambda: {"tokens": 0, "input": 0, "output": 0, "cache_read": 0,
                                       "cost": 0.0, "calls": 0, "sessions": set(), "mode": None})
    by_model = defaultdict(lambda: {"tokens": 0, "cost": 0.0, "calls": 0, "provider": None})
    by_profile = defaultdict(lambda: {"tokens": 0, "cost": 0.0, "sessions": 0, "subagents": 0,
                                      "tool_calls": 0})
    totals = {"tokens": 0, "input": 0, "output": 0, "cache_read": 0, "reasoning": 0, "cost": 0.0,
              "calls": 0, "sessions": 0, "subagents": 0, "tool_calls": 0, "messages": 0}
    sessions_by_day = defaultdict(int)

    for name, home in profile_homes():
        if profile and name != profile:
            continue
        db = home / "state.db"
        if not db.exists():
            continue
        try:
            with ro(db) as c:
                costs = session_costs(c)
                for r in c.execute(
                        f"""SELECT session_id, model, coalesce(billing_provider,'') prov, billing_mode,
                                   coalesce(api_call_count,0) calls, coalesce(input_tokens,0) inp,
                                   coalesce(output_tokens,0) outp, coalesce(cache_read_tokens,0) cr,
                                   coalesce(reasoning_tokens,0) rs, {cost_expr()} cost, last_seen
                            FROM session_model_usage WHERE last_seen >= ? AND last_seen < ?""",
                        (start, end)):
                    prov = r["prov"] or "bilinmiyor"
                    tok = r["inp"] + r["outp"]
                    cost = row_cost(r["cost"], tok, costs.get(r["session_id"]))
                    d = day_of(r["last_seen"])
                    by_day_provider[d][prov]["tokens"] += tok
                    by_day_provider[d][prov]["cost"] += cost
                    p = by_provider[prov]
                    p["tokens"] += tok; p["input"] += r["inp"]; p["output"] += r["outp"]
                    p["cache_read"] += r["cr"]; p["cost"] += cost; p["calls"] += r["calls"]
                    p["sessions"].add((name, r["session_id"]))
                    p["mode"] = p["mode"] or r["billing_mode"]
                    m = by_model[r["model"] or "?"]
                    m["tokens"] += tok; m["cost"] += cost; m["calls"] += r["calls"]
                    m["provider"] = m["provider"] or prov
                    by_profile[name]["tokens"] += tok
                    by_profile[name]["cost"] += cost
                    totals["tokens"] += tok; totals["input"] += r["inp"]; totals["output"] += r["outp"]
                    totals["cache_read"] += r["cr"]; totals["reasoning"] += r["rs"]
                    totals["cost"] += cost; totals["calls"] += r["calls"]
                for r in c.execute(
                        """SELECT started_at, parent_session_id IS NOT NULL sub,
                                  coalesce(tool_call_count,0) tools, coalesce(message_count,0) msgs
                           FROM sessions WHERE started_at >= ? AND started_at < ?""", (start, end)):
                    totals["sessions"] += 1
                    totals["subagents"] += r["sub"]
                    totals["tool_calls"] += r["tools"]
                    totals["messages"] += r["msgs"]
                    by_profile[name]["sessions"] += 1
                    by_profile[name]["subagents"] += r["sub"]
                    by_profile[name]["tool_calls"] += r["tools"]
                    sessions_by_day[day_of(r["started_at"])] += 1
        except sqlite3.Error:
            continue

    providers = sorted(by_provider, key=lambda k: -by_provider[k]["tokens"])
    return {
        "days": days,
        "totals": totals,
        "providers": providers,
        "daily": [{"day": d, "by": {p: by_day_provider[d][p] for p in providers if p in by_day_provider[d]},
                   "sessions": sessions_by_day.get(d, 0)} for d in days],
        "by_provider": [{**{k: v for k, v in by_provider[p].items() if k != "sessions"},
                         "provider": p, "sessions": len(by_provider[p]["sessions"])} for p in providers],
        "by_model": sorted(({"model": k, **v} for k, v in by_model.items()), key=lambda x: -x["tokens"]),
        "by_profile": sorted(({"profile": k, **v} for k, v in by_profile.items()), key=lambda x: -x["tokens"]),
    }


# ---------- open sessions (lease registry) ----------

LEASED_SOURCES = ("cli", "desktop", "tui")  # surfaces that hold a lease while their window is open
SUBAGENT_OPEN_WINDOW = 3600  # a subagent of an open session, not ended, stays listed while it wrote within this


def open_leases(home: Path):
    """{session id: pid} of the chat surfaces open right now (Hermes' own lease registry, live pid only).
    Kanban workers hold a lease too (its pid is the card's worker_pid)."""
    try:
        entries = json.loads((home / "runtime" / "active_sessions.json").read_text()).get("entries") or []
    except (OSError, ValueError, AttributeError):
        return {}
    return {e.get("session_id"): e.get("pid") for e in entries
            if isinstance(e, dict) and e.get("session_id") and clis.pid_alive(e.get("pid"))}


def open_sessions(home: Path):
    """Session ids whose chat surface is open right now."""
    return set(open_leases(home))


def main_is_open(source, sid, last, opened, now):
    """The one definition of "this main session is open" (Live, Agents page): an unended session of a leased surface
    (desktop/cli/tui) is open exactly while its lease is live, however quiet it is; any other source (kanban worker,
    messaging platforms, cron...) is open while it holds a lease or wrote within ACTIVE_WINDOW."""
    if source in LEASED_SOURCES:
        return sid in opened
    return sid in opened or (last or 0) > now - ACTIVE_WINDOW


# ---------- agents & subagents ----------

def agents(start, end):
    now = time.time()
    out = []
    for name, home in profile_homes():
        prov, model = read_model(home)
        row = {"name": name, "provider": prov, "model": model, "active": 0, "sessions": 0,
               "subagents": 0, "tokens": 0, "cost": 0.0, "tool_calls": 0,
               "last_activity": None, "last_title": None, "daily": {}}
        db = home / "state.db"
        if db.exists():
            try:
                with ro(db) as c:
                    for r in c.execute(
                            f"""SELECT started_at, parent_session_id IS NOT NULL sub,
                                       coalesce(input_tokens,0)+coalesce(output_tokens,0) tok,
                                       {cost_expr()} cost, coalesce(tool_call_count,0) tools
                                FROM sessions WHERE started_at >= ? AND started_at < ?""", (start, end)):
                        row["sessions"] += 1; row["subagents"] += r["sub"]; row["tokens"] += r["tok"]
                        row["cost"] += r["cost"]; row["tool_calls"] += r["tools"]
                        d = day_of(r["started_at"])
                        row["daily"][d] = row["daily"].get(d, 0) + r["tok"]
                    last = c.execute(
                        """SELECT title, coalesce(last_activity_at, started_at) t FROM sessions
                           ORDER BY coalesce(last_activity_at, started_at) DESC LIMIT 1""").fetchone()
                    if last:
                        row["last_activity"], row["last_title"] = num(last["t"]), last["title"]
                    opened = open_sessions(home)
                    row["active"] = sum(1 for r in c.execute(
                        """SELECT id, source, coalesce(last_activity_at, started_at) t FROM sessions
                           WHERE ended_at IS NULL AND parent_session_id IS NULL""")
                        if main_is_open(r["source"], r["id"], num(r["t"]), opened, now))
            except sqlite3.Error as e:
                row["error"] = str(e)
        out.append(row)
    return out


def subagents(start, end):
    now = time.time()
    out = []
    for name, home in profile_homes():
        db = home / "state.db"
        if not db.exists():
            continue
        try:
            opened = open_sessions(home)
            with ro(db) as c:
                for s in c.execute(
                        f"""SELECT s.title, s.model, s.started_at, s.ended_at, s.end_reason,
                                   s.parent_session_id parent_id, p.source psource,
                                   coalesce(s.last_activity_at, s.started_at) t,
                                   coalesce(s.input_tokens,0)+coalesce(s.output_tokens,0) tok,
                                   {cost_expr('s.')} cost, coalesce(s.tool_call_count,0) tools,
                                   s.last_activity_description act, p.title parent
                            FROM sessions s LEFT JOIN sessions p ON p.id = s.parent_session_id
                            WHERE s.parent_session_id IS NOT NULL AND s.started_at >= ? AND s.started_at < ?
                            ORDER BY s.started_at DESC LIMIT 300""", (start, end)):
                    t = num(s["t"]) or 0
                    running = s["ended_at"] is None and t > now - ACTIVE_WINDOW
                    if s["psource"] in LEASED_SOURCES and s["parent_id"] not in opened:
                        running = False  # its parent window is closed (same rule as Live)
                    started = num(s["started_at"])
                    ended = num(s["ended_at"]) or t
                    out.append({"profile": name, "title": s["title"], "model": s["model"],
                                "parent": s["parent"], "started": started, "last": t,
                                "duration": (ended - started) if started else None,
                                "status": "running" if running else "ended",
                                "end_reason": None if running else s["end_reason"],
                                "tokens": s["tok"], "cost": s["cost"], "tools": s["tools"],
                                "activity": s["act"]})
        except sqlite3.Error:
            continue
    out.sort(key=lambda s: s["started"] or 0, reverse=True)
    return out


# ---------- kanban ----------

def kanban_dbs():
    dbs = [("default", HOME / "kanban.db")]
    boards = HOME / "kanban" / "boards"
    if boards.is_dir():
        dbs += [(b.name, b / "kanban.db") for b in sorted(boards.iterdir()) if (b / "kanban.db").exists()]
    return dbs


def _task_cols(c):
    return {r[1] for r in c.execute("PRAGMA table_info(tasks)")}


def card_waiting_for(status, block_kind):
    """What a card waits for: input (blocked + needs_input), review (status review), else None."""
    if status == "blocked" and block_kind == "needs_input":
        return "input"
    return "review" if status == "review" else None


def kanban(start, end, days):
    out = []
    dbs = kanban_dbs()
    for board, db in dbs:
        if not db.exists():
            continue
        try:
            with ro(db) as c:
                counts = {r[0]: r[1] for r in c.execute("SELECT status, count(*) FROM tasks GROUP BY status")}
                if not counts:
                    continue
                done_daily = defaultdict(int)
                by_assignee = defaultdict(lambda: defaultdict(int))
                for r in c.execute("""SELECT completed_at, assignee FROM tasks
                                      WHERE completed_at >= ? AND completed_at < ?""", (start, end)):
                    done_daily[day_of(r[0])] += 1
                    by_assignee[r[1] or "atanmamış"]["done"] += 1
                for r in c.execute("""SELECT assignee, status FROM tasks
                                      WHERE status NOT IN ('done','archived')"""):
                    by_assignee[r[0] or "atanmamış"][r[1]] += 1
                bk = "block_kind" if "block_kind" in _task_cols(c) else "NULL AS block_kind"
                cards = [dict(r) for r in c.execute(
                    f"""SELECT id, title, assignee, status, priority, created_at, started_at, completed_at,
                              last_heartbeat_at, consecutive_failures, last_failure_error, {bk}
                       FROM tasks WHERE status != 'archived'
                         AND (status != 'done' OR (completed_at >= ? AND completed_at < ?))
                       ORDER BY coalesce(completed_at, started_at, created_at) DESC LIMIT 400""",
                    (start, end))]
                # blocked is not one thing: needs_input waits for a person, the rest waits for a dependency / something else
                blocked_by_kind = defaultdict(int)
                for r in c.execute(f"SELECT {bk} FROM tasks WHERE status = 'blocked'"):
                    blocked_by_kind[r[0] or "other"] += 1
            for card in cards:
                card["board"] = board
                card["waiting_for"] = card_waiting_for(card["status"], card["block_kind"])
                card["open"] = open_kanban_card(card["id"], board, card["title"])
            out.append({"board": board, "counts": counts, "blocked_by_kind": dict(blocked_by_kind), "cards": cards,
                        "done_daily": [{"day": d, "done": done_daily.get(d, 0)} for d in days],
                        "by_assignee": [{"assignee": a, **v} for a, v in
                                        sorted(by_assignee.items(), key=lambda kv: -sum(kv[1].values()))]})
        except sqlite3.Error as e:
            out.append({"board": board, "counts": {}, "cards": [], "done_daily": [], "by_assignee": [],
                        "error": str(e)})
    return out


def kanban_cards():
    """{card id: {...}} every non-archived card on every board, read-only from Hermes' kanban DB."""
    out = {}
    for board, db in kanban_dbs():
        if not db.exists():
            continue
        try:
            with ro(db) as c:
                cols = _task_cols(c)
                bk = "block_kind" if "block_kind" in cols else "NULL AS block_kind"
                for r in c.execute(f"""SELECT id, title, assignee, status, started_at, last_heartbeat_at, worker_pid,
                                              {bk} FROM tasks WHERE status != 'archived'"""):
                    out[r["id"]] = {"id": r["id"], "board": board, "title": r["title"], "assignee": r["assignee"],
                                    "status": r["status"], "started_at": num(r["started_at"]),
                                    "heartbeat": num(r["last_heartbeat_at"]), "worker_pid": r["worker_pid"],
                                    "block_kind": r["block_kind"]}
        except sqlite3.Error:
            continue
    return out


# ---------- "open" action (contract: docs/api-live.md) ----------

HERMES_APPS = (Path("/Applications/Hermes.app"), Path.home() / "Applications" / "Hermes.app")
HERMES_KANBAN_URL = "hermes://open/kanban"  # board page; Hermes has no per-card route (read from its source)


def hermes_desktop_installed():
    """The hermes:// scheme is registered by Hermes.app (CFBundleURLSchemes); without it a URL goes nowhere."""
    return any(p.exists() for p in HERMES_APPS)


def _label(text, fallback):
    t = " ".join(str(text or "").split()) or fallback
    return t if len(t) <= 80 else t[:79] + "…"


def open_hermes_session(profile, sid, source, title):
    """Hermes session. `hermes -p <profile> --resume <id>` always works (checked with `hermes --help`).
    `hermes://open/<id>` is only offered for desktop sessions with Hermes.app installed: the desktop app maps it to its
    chat route /<id> (apps/desktop: hermes-open-target.ts, routes.ts, read in source, not run). It carries no profile,
    so for other surfaces and other profiles' CLI sessions the command is the only claim made."""
    cmd = "hermes " + (f"-p {shlex.quote(profile)} " if profile and profile != "default" else "") \
          + f"--resume {shlex.quote(sid)}"
    url = f"hermes://open/{quote(sid, safe='')}" if source == "desktop" and hermes_desktop_installed() else None
    return {"kind": "hermes-session", "url": url, "command": cmd, "label": _label(title, sid)}


def open_kanban_card(card_id, board, title, session_cmd=None):
    """Kanban card: board page + a command that prints the card (`hermes kanban [--board <b>] show <id>`; --board is a
    flag of `kanban`, so it goes before the verb)."""
    cmd = "hermes kanban " + (f"--board {shlex.quote(board)} " if board and board != "default" else "") \
          + f"show {shlex.quote(card_id)}"
    out = {"kind": "kanban-card", "url": HERMES_KANBAN_URL if hermes_desktop_installed() else None,
           "command": cmd, "label": _label(title, card_id), "card_id": card_id}
    if session_cmd:
        out["session_command"] = session_cmd
    return out


def open_cli_session(kind, sid, project, title):
    """Claude Code / Copilot CLI: no URL scheme known, so a command. Claude Code looks a session up under the current
    directory's project, hence the `cd`."""
    binary = "claude" if kind == "claude-code" else "copilot"
    cmd = f"{binary} --resume {shlex.quote(sid)}"
    if kind == "claude-code" and project:
        cmd = f"cd {shlex.quote(project)} && {cmd}"
    return {"kind": kind, "url": None, "command": cmd, "label": _label(title, sid)}


NO_OPEN = {"kind": "none", "url": None, "command": None, "label": ""}


KANBAN_PROMPT = re.compile(r"kanban task (t_[0-9a-f]+)")


def match_kanban_sessions(rows, cards):
    """Pair kanban worker sessions with their card (never by profile alone). Order of evidence:
    1. the session's lease pid == the card's worker_pid (the dispatcher spawns the worker process that holds the lease);
    2. the task id in the session's first user message ("work kanban task <id>", what the dispatcher sends);
    3. same assignee/profile, same title, started no earlier than 2 min before the card.
    `tasks.session_id` is NOT used: it is the session that created the card. A card pairs with at most one session."""
    taken = set()

    def take(r, card):
        r["kanban"] = {"id": card["id"], "board": card["board"], "status": card["status"], "title": card["title"],
                       "block_kind": card["block_kind"]}
        r["kanban_card"], r["kanban_status"] = card["title"], card["status"]
        taken.add(card["id"])

    work = [r for r in rows if r.get("origin") == "kanban" and not r["subagent"]]
    left = []
    for r in work:
        pid = r.get("_pid")
        card = next((c for c in cards.values() if pid and c["worker_pid"] == pid and c["id"] not in taken
                     and c["status"] == "running"), None)
        if card:
            take(r, card)
        else:
            left.append(r)
    rest = []
    for r in left:
        m = KANBAN_PROMPT.search(r.get("_first_user") or "")
        card = cards.get(m.group(1)) if m else None
        if card and card["id"] not in taken:
            take(r, card)
        else:
            rest.append(r)
    for r in rest:
        card = next((c for c in cards.values() if c["id"] not in taken and c["status"] == "running"
                     and c["assignee"] == r["profile"] and c["title"] == r["title"]
                     and (r["started"] or 0) >= (c["started_at"] or 0) - 120), None)
        if card:
            take(r, card)
    return taken


def card_only_row(card, now):
    """Live row for a running card whose worker session could not be paired (or is not listed): a running card is
    always visible. state: working while the worker process lives, stalled when it is gone."""
    alive = bool(card["worker_pid"]) and clis.pid_alive(card["worker_pid"])
    last = max(card["heartbeat"] or 0, card["started_at"] or 0) or None
    return {"id": card["id"], "card_only": True, "parent": None, "parent_title": None, "profile": card["assignee"],
            "title": card["title"], "model": None, "provider": "", "started": card["started_at"], "last": last,
            "subagent": False, "status": "running", "end_reason": None, "working": alive, "activity": None,
            "tokens": 0, "cost": 0.0, "tools": 0, "messages": 0, "parent_model": None, "origin": "kanban",
            "interactive": False, "state": "working" if alive else "stalled", "state_since": None if alive else last,
            "waiting_for": None, "context_tokens": None, "context_estimated": True, "loop_max": 0,
            "kind": "hermes", "source_name": "Hermes",
            "kanban": {"id": card["id"], "board": card["board"], "status": card["status"], "title": card["title"],
                       "block_kind": card["block_kind"]},
            "kanban_card": card["title"], "kanban_status": card["status"]}


# ---------- live ----------

LIVE_SAMPLE_EVERY = 2
LIVE_KEEP = 3600
_samples = []  # [(ts, {(profile, provider): (tokens, cost)})]
_samples_lock = threading.Lock()


def _usage_totals_now():
    """Cumulative tokens/cost per (profile, provider) of sessions touched in the last 2h."""
    since = time.time() - 7200
    totals = {}
    for name, home in profile_homes():
        db = home / "state.db"
        if not db.exists():
            continue
        try:
            with ro(db) as c:
                rows = c.execute(
                    f"""SELECT session_id, model, coalesce(billing_provider,'bilinmiyor') prov,
                               coalesce(input_tokens,0)+coalesce(output_tokens,0) tok, {cost_expr()} cost
                        FROM session_model_usage WHERE last_seen >= ?""", (since,)).fetchall()
                costs = session_costs(c, {r["session_id"] for r in rows})
                for r in rows:
                    totals[(name, r["prov"], r["session_id"], r["model"])] = (
                        r["tok"], row_cost(r["cost"], r["tok"], costs.get(r["session_id"])))
        except sqlite3.Error:
            continue
    return totals


def _live_sampler():
    while True:
        try:
            snap = _usage_totals_now()
            with _samples_lock:
                _samples.append((time.time(), snap))
                cutoff = time.time() - LIVE_KEEP - 120
                while _samples and _samples[0][0] < cutoff:
                    _samples.pop(0)
        except Exception:
            pass
        time.sleep(LIVE_SAMPLE_EVERY)


def token_rate():
    """Per-minute token/cost deltas by provider, from consecutive samples."""
    with _samples_lock:
        samples = list(_samples)
    minutes = defaultdict(lambda: defaultdict(lambda: {"tokens": 0, "cost": 0.0}))
    by_profile = defaultdict(lambda: {"tokens": 0, "cost": 0.0})
    for (t0, a), (t1, b) in zip(samples, samples[1:]):
        m = int(t1 // 60) * 60
        for key, (tok, cost) in b.items():
            # a row missing from the previous sample is new usage (a new session or model)
            ptok, pcost = a.get(key, (0, 0.0))
            dt, dc = max(0, tok - ptok), max(0.0, cost - pcost)
            if dt or dc:
                minutes[m][key[1]]["tokens"] += dt
                minutes[m][key[1]]["cost"] += dc
                if t1 >= time.time() - 3600:
                    by_profile[key[0]]["tokens"] += dt
                    by_profile[key[0]]["cost"] += dc
    return {"since": samples[0][0] if samples else None, "minutes": minutes, "by_profile": by_profile}


INTERACTIVE_SOURCES = ("desktop", "cli", "tui", "telegram", "slack", "discord")
STALL_AFTER = 600  # a turn that claims to be running but wrote nothing for this long is "stalled"
STALL_AFTER_TOOL = 1800  # ... but a tool call still in flight (a build, a test run) gets this long
# Hermes states a pending command approval only through its activity label ("waiting for user approval (32s
# elapsed)"); there is no structured field, so this text match is the one fragile spot (S-08).
APPROVAL_MARK = "approval"


def _hermes_state(c, sid, act, now):
    """state / since / context estimate / loop for one open Hermes session.
    working: a live turn lease or an activity label (Hermes clears it when a turn ends);
    waiting: last message is a final assistant reply (no tool calls) and no turn is running;
    stalled: a turn claims to run (or was cut mid-turn) but nothing was written for STALL_AFTER."""
    last = c.execute("""SELECT role, tool_calls IS NULL final, timestamp, tool_calls FROM messages
                        WHERE session_id = ? AND active = 1 ORDER BY id DESC LIMIT 1""", (sid,)).fetchone()
    # last message is an assistant turn with tool calls and no result yet: a tool call is running, not stuck
    pending_tool = None
    if last and last["role"] == "assistant" and last["tool_calls"]:
        try:
            names = [(t.get("function") or {}).get("name") for t in json.loads(last["tool_calls"])]
            pending_tool = ", ".join(n for n in names if n) or "tool"
        except (ValueError, AttributeError, TypeError):
            pending_tool = "tool"
    stall_after = STALL_AFTER_TOOL if pending_tool else STALL_AFTER
    lease = c.execute("SELECT 1 FROM session_turn_leases WHERE conversation_id = ? AND expires_at > ?",
                      (sid, now)).fetchone() is not None
    last_ts = num(last["timestamp"]) if last else None
    quiet = now - (last_ts or now)
    if act and APPROVAL_MARK in act.lower():
        state, since = "needs_approval", None  # e.g. "waiting for user approval (32s elapsed)"
    elif lease or act:
        state, since = ("stalled", last_ts) if quiet > stall_after else ("working", None)
    elif last and last["role"] == "assistant" and last["final"]:
        state, since = "waiting", last_ts
    elif last and quiet > stall_after:
        state, since = "stalled", last_ts  # cut off mid-turn
    else:
        state, since = "working", None
    size = c.execute("""SELECT SUM(LENGTH(COALESCE(api_content, content, '')) + COALESCE(LENGTH(tool_calls), 0)
                                + COALESCE(LENGTH(reasoning_content), 0))
                        FROM messages WHERE session_id = ? AND active = 1""", (sid,)).fetchone()[0] or 0
    loop = c.execute("""WITH calls AS (
                          SELECT a.id msg, CAST(tc.key AS INT) idx, json_extract(tc.value, '$.function.name') name,
                                 json_extract(tc.value, '$.function.arguments') args
                          FROM messages a, json_each(a.tool_calls) tc
                          WHERE a.session_id = ? AND a.role = 'assistant' AND a.tool_calls IS NOT NULL
                            AND a.timestamp > ?),
                        seq AS (SELECT *, ROW_NUMBER() OVER (ORDER BY msg, idx) rn,
                                ROW_NUMBER() OVER (PARTITION BY name, args ORDER BY msg, idx) rk FROM calls)
                        SELECT MAX(n) FROM (SELECT COUNT(*) n FROM seq GROUP BY name, args, rn - rk)""",
                     (sid, now - 1800)).fetchone()[0] or 0
    return {"state": state, "state_since": since, "context_tokens": int(size / 4) if size else None,
            "context_estimated": True, "loop_max": loop,
            "waiting_for": "approval" if state == "needs_approval" else None,
            # name(s) of the tool call in flight, when the session is working/stalled on one (clients phrase it)
            "long_tool_call": pending_tool if state in ("working", "stalled") and quiet > 60 else None}


_speed_cache = {"at": 0.0, "data": []}
SPEED_TTL = 300  # turn statistics change slowly; the SQL walks a day of messages


def model_speed_cached():
    return _speed_cache["data"]


def _speed_refresher():
    """Keeps the turn statistics fresh in the background so no request waits for the day-long scan."""
    while True:
        try:
            _speed_cache["data"] = model_speed(time.time() - 86400)
            _speed_cache["at"] = time.time()
        except Exception:
            pass
        time.sleep(SPEED_TTL)


def model_speed(since):
    """Turn durations per model (Hermes from message timestamps, Claude Code from its turn_duration lines):
    turns, p50 / p90 turn seconds and p50 seconds to the first reply."""
    rows = defaultdict(lambda: {"dur": [], "first": []})
    for _, home in profile_homes():
        db = home / "state.db"
        if not db.exists():
            continue
        try:
            with ro(db) as c:
                # one pass: every row gets the id of the user row that opened its turn (running max); any user row
                # ends a turn, but only turns opened by a real prompt count (not "process complete", "steer", ...)
                for r in c.execute("""
                    WITH m AS (SELECT session_id, id, role, timestamp, tool_calls IS NULL final,
                                      role = 'user' AND display_kind IS NULL prompt,
                                      MAX(CASE WHEN role = 'user' THEN id END)
                                        OVER (PARTITION BY session_id ORDER BY id ROWS UNBOUNDED PRECEDING) turn
                               FROM messages
                               WHERE timestamp > ? AND _compressed_summary = 0 AND (active = 1 OR compacted = 1)),
                    t AS (SELECT session_id, turn,
                                 MAX(CASE WHEN id = turn THEN timestamp END) t0,
                                 MAX(CASE WHEN id = turn THEN prompt END) is_prompt,
                                 MIN(CASE WHEN role = 'assistant' THEN timestamp END) t_first,
                                 MAX(CASE WHEN role = 'assistant' AND final THEN timestamp END) t_final
                          FROM m WHERE turn IS NOT NULL GROUP BY session_id, turn)
                    SELECT s.model, t_final - t0 dur, t_first - t0 first FROM t JOIN sessions s ON s.id = t.session_id
                    WHERE t0 > ? AND is_prompt AND t_final IS NOT NULL AND s.model IS NOT NULL""", (since - 3600, since)):
                    rows[("hermes", r["model"])]["dur"].append(r["dur"])
                    if r["first"] is not None:
                        rows[("hermes", r["model"])]["first"].append(r["first"])
        except sqlite3.Error:
            continue
    for model, sec in clis.claude_turns(since):
        rows[("claude-code", model)]["dur"].append(sec)

    def pct(xs, q):
        xs = sorted(xs)
        return round(xs[min(len(xs) - 1, max(0, int(round(q * (len(xs) - 1)))))], 1) if xs else None

    return sorted(({"source": src, "model": m, "turns": len(v["dur"]), "p50_s": pct(v["dur"], 0.5),
                    "p90_s": pct(v["dur"], 0.9), "first_reply_p50_s": pct(v["first"], 0.5)}
                   for (src, m), v in rows.items() if v["dur"]), key=lambda x: -x["turns"])


def _open_for(r, by_id):
    """The `open` object of one Live row (contract: docs/api-live.md)."""
    if r.get("kanban"):
        k = r["kanban"]
        sess = None if r.get("card_only") else open_hermes_session(r["profile"], r["id"], r["origin"], r["title"])
        return open_kanban_card(k["id"], k["board"], k["title"], sess["command"] if sess else None)
    if r["subagent"]:  # a subagent has no window of its own: open its parent
        parent = by_id.get((r["profile"], r["parent"]))
        if r["kind"] == "hermes" and r.get("_psource"):
            return open_hermes_session(r["profile"], r["parent"], r["_psource"], r.get("parent_title"))
        if r["kind"] == "claude-code" and r["parent"]:
            return open_cli_session("claude-code", r["parent"], parent and parent.get("_project") or r.get("_project"),
                                    parent and parent.get("title"))
        return dict(NO_OPEN)
    if r["kind"] == "hermes":
        return open_hermes_session(r["profile"], r["id"], r["origin"], r["title"])
    if r["kind"] in ("claude-code", "copilot-cli"):
        return open_cli_session(r["kind"], r["id"], r.get("_project"), r["title"])
    return dict(NO_OPEN)


def live_counts(rows):
    """One counting rule for every surface: open main sessions (+ card-only kanban rows) by state; subagents apart."""
    main = [r for r in rows if r["status"] == "running" and not r["subagent"]]
    n = lambda st: sum(1 for r in main if r["state"] == st)
    return {"open": len(main), "working": n("working"), "needs_approval": n("needs_approval"),
            "your_turn": n("waiting"), "stalled": n("stalled"),
            "subagents": sum(1 for r in rows if r["status"] == "running" and r["subagent"])}


def live():
    now = time.time()
    cur = int(now // 60) * 60
    mins = [cur - 60 * i for i in range(59, -1, -1)]
    activity = {m: {"assistant": 0, "tool": 0, "user": 0} for m in mins}
    running = []
    for name, home in profile_homes():
        db = home / "state.db"
        if not db.exists():
            continue
        try:
            leases = open_leases(home)
            opened = set(leases)
            with ro(db) as c:
                recent = [r[0] for r in c.execute(
                    "SELECT id FROM sessions WHERE coalesce(last_activity_at, started_at) >= ?", (mins[0],))]
                for sid in recent:
                    for r in c.execute("""SELECT timestamp, role FROM messages
                                          WHERE session_id = ? AND timestamp >= ?""", (sid, mins[0])):
                        m = int(r[0] // 60) * 60
                        if m in activity and r[1] in activity[m]:
                            activity[m][r[1]] += 1
                # Open sessions come from Hermes' lease registry, not from recent activity: an unended session whose
                # lease is live is listed however quiet it is. The ACTIVE_WINDOW rule stays for sources without a
                # lease (messaging platforms, cron...). Subagents that finished in the last 15 min stay for context.
                held = list(opened)
                hold = ",".join("?" * len(held))
                in_open = f"id IN ({hold})" if held else "0"
                sub_open = f"parent_session_id IN ({hold})" if held else "0"
                for s in c.execute(
                        f"""SELECT id, parent_session_id parent, title, model, started_at, ended_at, end_reason,
                                   (SELECT p.title FROM sessions p WHERE p.id = sessions.parent_session_id) ptitle,
                                   coalesce(last_activity_at, started_at) t, last_activity_description act,
                                   coalesce(input_tokens,0)+coalesce(output_tokens,0) tok, {cost_expr()} cost,
                                   coalesce(tool_call_count,0) tools, coalesce(message_count,0) msgs,
                                   coalesce(billing_provider,'') prov, source,
                                   (SELECT p.source FROM sessions p WHERE p.id = sessions.parent_session_id) psource,
                                   (SELECT p.model FROM sessions p WHERE p.id = sessions.parent_session_id) pmodel
                            FROM sessions
                            WHERE (ended_at IS NULL AND (coalesce(last_activity_at, started_at) > ? OR {in_open}))
                               OR (ended_at IS NULL AND {sub_open} AND coalesce(last_activity_at, started_at) > ?)
                               OR (parent_session_id IS NOT NULL AND coalesce(ended_at, last_activity_at) > ?)""",
                        (now - ACTIVE_WINDOW, *held, *held, now - SUBAGENT_OPEN_WINDOW, now - 900)):
                    t = num(s["t"]) or 0
                    if s["parent"] is None:
                        if s["source"] in LEASED_SOURCES and s["id"] not in opened:
                            continue  # a closed window leaves ended_at unset until Hermes reaps it: trust the leases
                        is_running = s["ended_at"] is None and main_is_open(s["source"], s["id"], t, opened, now)
                    else:
                        is_running = s["ended_at"] is None and (
                            t > now - ACTIVE_WINDOW or (s["parent"] in opened and t > now - SUBAGENT_OPEN_WINDOW))
                        if s["psource"] in LEASED_SOURCES and s["parent"] not in opened:
                            is_running = False
                    extra = (_hermes_state(c, s["id"], s["act"], now) if is_running and s["parent"] is None else
                             {"state": "working" if is_running else "ended", "state_since": None, "context_tokens": None,
                              "context_estimated": True, "loop_max": 0, "waiting_for": None, "long_tool_call": None})
                    # origin: chat surfaces (desktop, cli, tui, messaging platforms) have a person at the keyboard; kanban, cron, oneshot run unattended
                    extra["origin"] = s["source"]
                    extra["interactive"] = s["source"] in INTERACTIVE_SOURCES
                    row = {**extra, "id": s["id"], "parent": s["parent"], "parent_title": s["ptitle"], "profile": name,
                           "title": s["title"],
                           "model": s["model"], "provider": s["prov"], "started": num(s["started_at"]),
                           "last": t, "subagent": s["parent"] is not None,
                           # status is running | ended; why it ended is end_reason (S-07)
                           "status": "running" if is_running else "ended",
                           "end_reason": None if is_running else (s["end_reason"] or None),
                           # open and running vs. actually producing output right now
                           "working": extra["state"] == "working" if s["parent"] is None
                           else is_running and t > now - clis.WORKING_WINDOW,
                           "activity": s["act"], "tokens": s["tok"], "cost": s["cost"],
                           "tools": s["tools"], "messages": s["msgs"],
                           "parent_model": s["pmodel"], "kanban_card": None, "kanban_status": None, "kanban": None,
                           "kind": "hermes", "source_name": "Hermes"}
                    if s["source"] == "kanban" and s["parent"] is None:
                        # evidence for pairing the worker with its card (dropped before the response)
                        row["_pid"] = leases.get(s["id"])
                        fu = c.execute("""SELECT content FROM messages WHERE session_id = ? AND role = 'user'
                                          ORDER BY id LIMIT 1""", (s["id"],)).fetchone()
                        row["_first_user"] = (fu[0] or "")[:400] if fu else ""
                    row["_psource"] = s["psource"]
                    running.append(row)
        except sqlite3.Error:
            continue

    rate = token_rate()
    cli_minutes, cli_active = clis.live(mins)
    # one series per source: Hermes (all its providers) + each agent CLI
    merged = {}
    for m in mins:
        by = {}
        hm = rate["minutes"].get(m, {})
        if hm:
            by["hermes"] = {"tokens": sum(v["tokens"] for v in hm.values()), "cost": sum(v["cost"] for v in hm.values())}
        for src, v in cli_minutes.get(m, {}).items():
            if v["tokens"] or v["cost"]:
                by[src] = dict(v)
        merged[m] = by
    providers = [k for k in ("hermes", "claude-code", "copilot-cli") if any(k in by for by in merged.values())]
    tok_minutes = [{"t": m, "by": merged[m]} for m in mins]

    def window_sum(sec, src=None):
        return sum(v["tokens"] for m, by in merged.items() if m >= cur - sec + 60
                   for k, v in by.items() if src is None or k == src)

    def window_cost(sec, src=None):
        return sum(v["cost"] for m, by in merged.items() if m >= cur - sec + 60
                   for k, v in by.items() if src is None or k == src)

    for s in cli_active:
        # profile stays the CLI's display name for existing clients; `kind` / `source_name` are the unambiguous fields (S-06)
        running.append({"id": s["id"], "parent": s["parent"], "parent_title": None, "profile": clis.SOURCES[s["source"]],
                        "source": s["source"], "kind": s["source"], "source_name": clis.SOURCES[s["source"]],
                        "title": s["title"], "model": s["model"], "provider": "",
                        "started": s["started"], "last": s["last"], "subagent": s["subagent"],
                        "status": "running" if s["running"] else "ended",
                        "end_reason": None if s["running"] else "agent_close", "_project": s["project"],
                        "long_tool_call": None, "kanban": None, "activity": s["project"],
                        "working": bool(s.get("working")),
                        "origin": s["source"], "interactive": True,
                        "state": s.get("state") if s["running"] else "ended", "state_since": s.get("state_since"),
                        # enum like Hermes rows; the CLI's own reason text (e.g. "permission prompt") goes to waiting_detail
                        "waiting_for": "approval" if s.get("state") == "needs_approval" else None,
                        "waiting_detail": s.get("waiting_for"), "context_tokens": s.get("context_tokens"),
                        "context_estimated": s.get("context_estimated", False), "loop_max": s.get("loop_max", 0),
                        "tokens": s["total_tokens"], "cost": s["total_cost"], "tools": s["calls"], "messages": 0,
                        "parent_model": None, "kanban_card": None, "kanban_status": None})

    # quota burn: slope of used% over the last 2h per window
    burn = []
    for s in quota_history(now - 7200, now + 60):
        pts = s["points"]
        if len(pts) >= 2 and pts[-1][0] - pts[0][0] >= 600:
            (t0, u0), (t1, u1) = pts[0], pts[-1]
            per_hour = (u1 - u0) / ((t1 - t0) / 3600)
            eta = (100 - u1) / per_hour * 3600 if per_hour > 0.01 else None
            burn.append({"provider": s["provider"], "window": s["window"], "used": u1,
                         "per_hour": per_hour, "eta_full": now + eta if eta else None})

    # kanban: pair worker sessions with their card, then make sure EVERY running card is a row
    cards = kanban_cards()
    taken = match_kanban_sessions([r for r in running if r["status"] == "running"], cards)
    for card in cards.values():
        if card["status"] == "running" and card["id"] not in taken:
            running.append(card_only_row(card, now))
    by_id = {(r["profile"], r["id"]): r for r in running}
    for r in running:
        r["open"] = _open_for(r, by_id)
        for k in [k for k in r if k.startswith("_")]:
            del r[k]

    running.sort(key=lambda r: -(r["last"] or 0))
    return {
        "now": now, "sampling_since": rate["since"], "sample_every": LIVE_SAMPLE_EVERY,
        "activity": [{"t": m, **activity[m]} for m in mins],
        "tokens": tok_minutes, "providers": providers,
        "by_profile": sorted([{"profile": k, **v} for k, v in rate["by_profile"].items()] +
                             [{"profile": clis.SOURCES[k], "tokens": window_sum(3600, k), "cost": window_cost(3600, k)}
                              for k in ("claude-code", "copilot-cli") if window_sum(3600, k)],
                             key=lambda x: -x["tokens"]),
        "last_1m": window_sum(60), "last_5m": window_sum(300), "last_60m": window_sum(3600),
        "by_source_60m": {k: window_sum(3600, k) for k in providers},
        "cost_60m": window_cost(3600),
        "running": running, "counts": live_counts(running), "burn": burn, "quotas": quotas(),
    }


# ---------- http ----------

def top_sessions(start, end, limit=10):
    """Most expensive sessions (Hermes, all profiles, + agent CLIs) active in [start, end)."""
    rows = []
    for name, home in profile_homes():
        db = home / "state.db"
        if not db.exists():
            continue
        try:
            with ro(db) as c:
                for s in c.execute(
                        f"""SELECT id, title, model, started_at, coalesce(last_activity_at, ended_at, started_at) last,
                                   coalesce(input_tokens,0)+coalesce(output_tokens,0) tok, {cost_expr()} cost,
                                   parent_session_id parent, coalesce(tool_call_count,0) tools
                            FROM sessions WHERE coalesce(last_activity_at, started_at) >= ? AND started_at < ?
                            ORDER BY cost DESC LIMIT ?""", (start, end, limit)):
                    rows.append({"source": "hermes", "profile": name, "id": s["id"], "title": s["title"],
                                 "model": s["model"], "started": num(s["started_at"]), "last": num(s["last"]),
                                 "tokens": s["tok"], "cost": s["cost"] or 0.0, "subagent": s["parent"] is not None,
                                 "tools": s["tools"]})
        except sqlite3.Error:
            continue
    for s in clis.collect(start, end)[0]:
        rows.append({"source": s["source"], "profile": clis.SOURCES[s["source"]], "id": s["id"], "title": s["title"],
                     "model": s["model"], "started": s["started"], "last": s["last"], "tokens": s["tokens"],
                     "cost": s["cost"] or 0.0, "subagent": s["subagent"], "tools": s["calls"]})
    rows.sort(key=lambda r: -r["cost"])
    return rows[:limit]


def route(path, q):
    start, end, days = parse_range(q)
    profile = (q.get("profile") or [None])[0] or None
    if path == "/api/overview":
        return {"usage": usage(start, end, days, profile), "quotas": quotas(),
                "agents": agents(start, end), "kanban": kanban(start, end, days),
                "clis": clis.summary(start, end, days)}
    if path == "/api/accounts":
        return {"usage": usage(start, end, days, profile),
                "quotas": quotas(force=q.get("force") == ["1"]),
                "history": quota_history(start, end)}
    if path == "/api/agents":
        return {"agents": agents(start, end), "usage": usage(start, end, days, profile)}
    if path == "/api/subagents":
        return {"subagents": subagents(start, end), "days": days}
    if path == "/api/kanban":
        return {"boards": kanban(start, end, days)}
    if path == "/api/live":
        return live()
    if path == "/api/top-sessions":
        return {"sessions": top_sessions(start, end)}
    if path == "/api/health":
        h = health.health(profile_homes(), (quotas() or {}).get("items"))
        h["speed"] = model_speed_cached()
        return h
    if path == "/api/clis":
        return clis.summary(start, end, days)
    return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body: bytes, ctype: str, status=200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # DNS-rebinding guard: a web page can point its own hostname at 127.0.0.1, but it cannot fake the
        # Host header, so only answer requests addressed to this machine by name or loopback IP.
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]").lower()
        if host not in ("127.0.0.1", "localhost", "::1"):
            return self.send_error(403)
        # Cross-site guard: browsers label requests a web page makes (Sec-Fetch-Site: cross-site / same-site).
        # The dashboard itself is same-origin or typed in (none); Agent Bar and curl send no such header.
        site = self.headers.get("Sec-Fetch-Site")
        if site and site not in ("same-origin", "none"):
            return self.send_error(403)
        u = urlparse(self.path)
        if u.path.startswith("/api/"):
            t0 = time.time()
            try:
                data = route(u.path, parse_qs(u.query))
                if time.time() - t0 > 1:
                    print(f"slow {u.path} {time.time() - t0:.1f}s", file=sys.stderr, flush=True)
            except Exception as e:
                return self._send(json.dumps({"error": str(e)}).encode(), "application/json", 500)
            if data is None:
                return self.send_error(404)
            return self._send(json.dumps(data, default=str).encode(), "application/json")
        if u.path in ("/", "/index.html"):
            return self._send((HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        self.send_error(404)


if __name__ == "__main__":
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(4096, hard), hard))
    except (ValueError, OSError):
        pass
    threading.Thread(target=_quota_recorder, daemon=True).start()
    threading.Thread(target=_live_sampler, daemon=True).start()
    threading.Thread(target=_speed_refresher, daemon=True).start()
    threading.Thread(target=lambda: clis.claude_sessions(time.time() - 91 * 86400), daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Agent Monitor: http://127.0.0.1:{PORT}")
    srv.serve_forever()
