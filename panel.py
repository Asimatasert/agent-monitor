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
import subprocess
import sys
import threading
import time
from collections import defaultdict
from contextlib import contextmanager
from datetime import date, datetime, timedelta
from email.utils import parsedate_to_datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

HOME = Path.home() / ".hermes"
sys.path.insert(0, str(HOME / "hermes-agent"))
import hermes_bootstrap  # noqa: E402,F401 — sets up Hermes' dependency paths

sys.path.insert(0, str(Path(__file__).parent))
import clis  # noqa: E402
import health  # noqa: E402
import localshare  # noqa: E402

try:
    PORT = int(os.environ.get("AGENT_MONITOR_PORT") or 8777)
except ValueError:
    PORT = 8777
HERE = Path(__file__).parent
PANEL_DB = HERE / "panel.db"
QUOTA_TTL = 120          # provider usage APIs are cached this many seconds
QUOTA_RECORD_EVERY = 300  # background quota snapshot interval (history charts)
ANTHROPIC_USAGE_TTL = 300  # an account's Claude usage is re-read at most this often (the "fetch now" button bypasses it)
ANTHROPIC_BACKOFF = (120, 240, 480, 900)  # seconds to stay silent after the 1st, 2nd, ... consecutive 429 (last = cap)
ANTHROPIC_RETRY_AFTER_MAX = 3600  # a Retry-After longer than this is clamped
IDENTITY_REFUSED_TTL = 1800  # an identity request answered 401/403 is not repeated for this long
IDENTITY_ERROR_TTL = 120     # ... answered with any other failure
STALE_MAX_AGE = 7 * 86400    # quota_history rows older than this are not shown as "last known"
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
    unavailable = None
    windows = ()
    if _anthropic_wait() > 0:
        unavailable = "rate limited"  # backing off after a 429: no request
    else:
        try:
            windows = tuple(_anthropic_windows(token))
            _anthropic_ok()
        except Exception as ex:
            if _http_status(ex) != 429:
                raise  # _usage_snapshot falls back to Hermes' own reader
            _anthropic_rate_limited(ex)
            unavailable = "rate limited"
    return AccountUsageSnapshot(provider="anthropic", source="oauth_usage_api", fetched_at=datetime.now(),
                                windows=windows, unavailable_reason=unavailable)


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


# Claude's OAuth endpoints answer 429 quickly when polled: remember what we learned instead of asking again.
_anthropic_lock = threading.Lock()
_anthropic_gate = {"until": 0.0, "fails": 0}  # shared 429 backoff: no request to Anthropic before `until`
_anthropic_identities = {}  # token fingerprint -> {"key": account key | None, "at": ts, "ttl": seconds | None}
_anthropic_last_good = {}   # quota item provider id -> {"wins": [...], "at": ts}


def _anthropic_reset_state():
    with _anthropic_lock:
        _anthropic_gate.update(until=0.0, fails=0)
        _anthropic_identities.clear()
        _anthropic_last_good.clear()


def _http_status(ex):
    return getattr(getattr(ex, "response", None), "status_code", None)


def _retry_after_s(ex):
    """Seconds the server asked us to wait (Retry-After: seconds or HTTP date), else None."""
    headers = getattr(getattr(ex, "response", None), "headers", None)
    v = headers.get("retry-after") if headers is not None else None
    if not v:
        return None
    try:
        return max(0.0, float(v))
    except ValueError:
        try:
            return max(0.0, parsedate_to_datetime(v).timestamp() - time.time())
        except (TypeError, ValueError):
            return None


def _anthropic_wait(now=None):
    """Seconds left of the 429 backoff (0 = free to ask)."""
    return max(0.0, _anthropic_gate["until"] - (now or time.time()))


def _anthropic_rate_limited(ex, now=None):
    """A 429 came back: honour Retry-After, else back off 2 -> 4 -> 8 -> 15 min. Returns the wait in seconds."""
    now = now or time.time()
    with _anthropic_lock:
        _anthropic_gate["fails"] += 1
        ra = _retry_after_s(ex)
        step = min(_anthropic_gate["fails"], len(ANTHROPIC_BACKOFF)) - 1
        wait = min(ra, ANTHROPIC_RETRY_AFTER_MAX) if ra else ANTHROPIC_BACKOFF[step]
        _anthropic_gate["until"] = max(_anthropic_gate["until"], now + wait)
    return wait


def _anthropic_ok():
    with _anthropic_lock:
        _anthropic_gate.update(until=0.0, fails=0)


def _identity_slot_db(slot, key=None):
    """Persisted account key of a credential slot ("source|label"): read when key is None, else written.
    Only a stand-in while Anthropic refuses to answer; a successful profile read always wins."""
    try:
        with rw(PANEL_DB) as c:
            c.execute("CREATE TABLE IF NOT EXISTS anthropic_identity (slot TEXT PRIMARY KEY, key TEXT, ts REAL)")
            if key is None:
                r = c.execute("SELECT key FROM anthropic_identity WHERE slot = ?", (slot,)).fetchone()
                return r[0] if r else None
            c.execute("INSERT OR REPLACE INTO anthropic_identity VALUES (?,?,?)", (slot, key, time.time()))
    except Exception:
        pass
    return None


def _anthropic_identity(token, slot=None):
    """Account key of a Claude OAuth credential, or None when it cannot be read.

    Source: Anthropic's OAuth profile endpoint (GET https://api.anthropic.com/api/oauth/profile, the one Claude Code
    itself calls). Its answer carries `account.uuid` (and `organization.uuid`); the key is the first 8 hex digits of
    sha256(account uuid), so the raw id never leaves this process. Tokens without the `user:profile` scope (e.g. a
    setup token in ANTHROPIC_TOKEN) get HTTP 403 and stay unreadable (None) — never guessed from the label.

    The answer is cached per token fingerprint (only a refreshed token is asked again), and nothing is asked while
    the 429 backoff runs. `slot` ("source|label") lets a key learned earlier stand in while Anthropic rate limits us."""
    import httpx

    fp = hashlib.sha256(str(token).encode()).hexdigest()[:16]
    now = time.time()
    hit = _anthropic_identities.get(fp)
    if hit and (hit["ttl"] is None or now - hit["at"] < hit["ttl"]):
        return hit["key"]
    remembered = _identity_slot_db(slot) if slot else None
    if _anthropic_wait(now) > 0:
        return remembered
    try:
        r = httpx.get(ANTHROPIC_PROFILE_URL, timeout=15,
                      headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                               "anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-code/2.1.0"})
        r.raise_for_status()
        uid = ((r.json() or {}).get("account") or {}).get("uuid")
    except Exception as ex:
        code = _http_status(ex)
        if code == 429:
            _anthropic_rate_limited(ex, now)
            return remembered  # not cached: asked again once the backoff is over
        _anthropic_identities[fp] = {"key": None, "at": now,
                                     "ttl": IDENTITY_REFUSED_TTL if code in (401, 403) else IDENTITY_ERROR_TTL}
        return None if code in (401, 403) else remembered
    key = hashlib.sha256(str(uid).encode()).hexdigest()[:8] if uid else None
    _anthropic_identities[fp] = {"key": key, "at": now, "ttl": None if key else IDENTITY_ERROR_TTL}
    if key and slot:
        _identity_slot_db(slot, key)
    return key


def _stale_windows(provider):
    """Last successfully read windows of a quota item -> (windows, read-at ts) or (None, None).
    Memory first; after a restart quota_history (panel.db) still has them."""
    mem = _anthropic_last_good.get(provider)
    if mem:
        return mem["wins"], mem["at"]
    ids = [provider] + [old for old, new in _anthropic_aliases.items() if new == provider]
    marks = ",".join("?" * len(ids))
    try:
        with rw(PANEL_DB) as c:
            c.execute("""CREATE TABLE IF NOT EXISTS quota_history
                         (ts REAL, provider TEXT, window TEXT, used REAL, reset REAL)""")
            rows = c.execute(f"""SELECT h.window, h.used, h.reset, h.ts FROM quota_history h
                                 JOIN (SELECT window w, MAX(ts) m FROM quota_history
                                       WHERE provider IN ({marks}) AND ts >= ? AND used IS NOT NULL GROUP BY window) x
                                   ON h.window = x.w AND h.ts = x.m
                                 WHERE h.provider IN ({marks}) AND h.used IS NOT NULL
                                 ORDER BY h.rowid""", (*ids, time.time() - STALE_MAX_AGE, *ids)).fetchall()
    except Exception:
        return None, None
    if not rows:
        return None, None
    latest = {w: (u, r, ts) for w, u, r, ts in rows}  # one row per window (aliases can tie on ts)
    return ([{"label": w, "used": u, "reset": r or None, "detail": None} for w, (u, r, _) in latest.items()],
            max(ts for _, _, ts in latest.values()))


def _apply_stale(item):
    """Item that could not be read right now keeps the last known windows, marked stale (stale / fetched_at = when
    those windows were really read). A freshly read item is remembered as the new last good one."""
    if item["windows"]:
        at = item.get("fetched_at") or time.time()  # preset when the windows were reused inside the usage TTL
        _anthropic_last_good[item["provider"]] = {"wins": item["windows"], "at": at}
        item.update(stale=False, fetched_at=at)
        return item
    wins, at = _stale_windows(item["provider"]) if item.get("unavailable_code") else (None, None)
    item.update(stale=bool(wins), fetched_at=at, windows=wins or [])
    return item


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
    groups = {}  # key -> {"creds": [...], "wins": [...], "err": ..., "http": ...}
    unreadable = []
    for c in creds:
        if c["key"]:
            g = groups.setdefault(c["key"], {"creds": [], "wins": [], "err": None, "http": None})
            g["creds"].append(dict(c, status_of="verified"))
            if c["wins"] and not g["wins"]:
                g["wins"] = c["wins"]
            if c["err"] and not c["wins"]:
                g["err"] = g["err"] or c["err"]
                g["http"] = g["http"] or c["http"]  # the HTTP code travels with the error (429, 403, ...)
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
                g = groups.setdefault(k, {"creds": [], "wins": c["wins"], "err": None, "http": None})
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


def _anthropic_read_creds(entries, force=False):
    """Read Claude credentials with as few Anthropic requests as possible -> creds for _group_anthropic.

    - the account behind each credential comes from the identity cache (see _anthropic_identity);
    - usage is read with ONE credential per account (priority order; the next one only when that failed), and not at
      all while the account's last reading is younger than ANTHROPIC_USAGE_TTL (force=True skips this);
    - credentials whose account cannot be read are tried only when no account yielded windows (nothing says they are
      another account; otherwise they stay listed as unverified);
    - after a 429 nothing is asked until the backoff is over (see _anthropic_rate_limited)."""
    rows = [{"e": e, "key": _anthropic_identity(e.runtime_api_key, slot=f"{e.source}|{e.label}"),
             "wins": [], "err": None, "http": None} for e in entries]
    rows.sort(key=lambda r: (r["e"].priority if r["e"].priority is not None else 99, r["e"].label or ""))

    def read(r):
        if _anthropic_wait() > 0:
            return False  # backing off: left without an error here, marked rate limited below
        try:
            r["wins"] = [{"label": w.label, "used": w.used_percent,
                          "reset": w.reset_at.timestamp() if w.reset_at else None, "detail": None}
                         for w in _anthropic_windows(r["e"].runtime_api_key)]
            _anthropic_ok()
            return True
        except Exception as ex:  # an expired token is refreshed by Hermes on its next use of that account
            code = _http_status(ex)
            if code == 429:
                _anthropic_rate_limited(ex)
                r.update(err="rate limited", http=429)
            else:
                r.update(err="usage not readable right now", http=code)
            return False

    got = False
    done = set()
    for r in rows:
        if not r["key"] or r["key"] in done:
            continue
        mine = [x for x in rows if x["key"] == r["key"]]
        recent = _anthropic_last_good.get(f"anthropic#{r['key']}")
        if recent and not force and time.time() - recent["at"] < ANTHROPIC_USAGE_TTL:
            mine[0]["wins"] = recent["wins"]  # the same reading as a moment ago: no request
            mine[0]["read_at"] = recent["at"]
            done.add(r["key"])
            got = True
            continue
        done.add(r["key"])
        for x in mine:
            if read(x):
                got = True
                break
            if _anthropic_wait() > 0:
                break
    if not got:
        for r in rows:
            if not r["key"] and read(r):
                break
            if _anthropic_wait() > 0:
                break
    if _anthropic_wait() > 0:  # whoever was not asked because of the backoff reports it as the reason
        for r in rows:
            if not r["wins"] and not r["err"]:
                r.update(err="rate limited", http=429)
    return rows


def account_name(accs):
    """Display name of an account item: the label you gave its first credential in Hermes' pool (priority order),
    skipping the Claude Code login (its label just says "claude_code") and credentials not verified to be this
    account. Runtime data only: it is read from auth.json and never stored."""
    mine = [a for a in accs if a.get("verification") != "unverified"]
    named = [a for a in mine if a.get("source") != "claude_code" and a.get("label")]
    pick = (named or mine or [{}])[0]
    return pick.get("label") or None


def _anthropic_account_items(force=False):
    """Claude OAuth credentials in Hermes' pool grouped by the ACCOUNT behind them (provider id
    "anthropic#<account-key>"), each read with its own token; None when the pool has fewer than 2 OAuth entries.
    Two credentials of one account (e.g. ANTHROPIC_TOKEN + claude_code) become ONE item with both in `accounts`.
    An item that cannot be read now (429, ...) keeps its last known windows: stale=True, fetched_at, and the reason
    in unavailable_code / unavailable_http (see _apply_stale)."""
    from agent.credential_pool import load_pool

    entries = [e for e in load_pool("anthropic").entries() if e.auth_type == "oauth"]
    if len(entries) < 2:
        return None

    creds = _anthropic_read_creds(entries, force)
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
        http = g.get("http") if err else None
        code = None if not err else "rate_limited" if http == 429 else "usage_unreadable"
        item = {"provider": f"anthropic#{g['key']}" if g["key"] else "anthropic",
                "account_key": g["key"], "name": account_name(accs) if g["key"] else None,
                "accounts": accs, "windows": g["wins"], "details": [], "plan": None,
                "unavailable": (f"{err} (HTTP {http})" if http else err) if err else None,
                "unavailable_code": code, "unavailable_http": http,
                "retry_at": time.time() + _anthropic_wait() if code == "rate_limited" and _anthropic_wait() > 0 else None}
        reused = [c["read_at"] for c in g["creds"] if c.get("read_at")]
        if g["wins"] and reused:
            item["fetched_at"] = min(reused)  # windows reused inside the usage TTL: say when they were really read
        items.append(_apply_stale(item))
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
        if _anthropic_wait() > 0:  # backing off: Hermes' own reader below must not ask either
            return None
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


def _anthropic_quota(force=False):
    """-> (per-account items | None, snapshot | None). The per-account reader goes first and its answer is final;
    only a pool without two Claude OAuth credentials falls back to the single-snapshot reader (never both: that
    would double the requests)."""
    try:
        split = _anthropic_account_items(force)
    except Exception:
        split = None
    return (split, None) if split else (None, _usage_snapshot("anthropic"))


def _fetch_quotas(force=False):
    from agent.credential_pool import load_pool
    from hermes_cli.auth import read_credential_pool

    providers = set(read_credential_pool().keys())
    for _, home in profile_homes():
        prov, _ = read_model(home)
        if prov:
            providers.add(prov)

    out = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {p: pool.submit(_anthropic_quota, force) if p == "anthropic" else pool.submit(_usage_snapshot, p)
                   for p in sorted(providers)}
        for prov, fut in futures.items():
            split = None
            try:
                res = fut.result(timeout=60 if prov == "anthropic" else 20)
                split, snap = res if prov == "anthropic" else (None, res)
            except Exception:
                snap = None
            if split:
                out.extend(split)
                continue
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
                if item["unavailable"] == "rate limited":
                    item.update(unavailable="rate limited (HTTP 429)", unavailable_code="rate_limited",
                                unavailable_http=429,
                                retry_at=time.time() + _anthropic_wait() if _anthropic_wait() > 0 else None)
                _apply_stale(item)
            out.append(item)
    return out


def _record_quotas(items):
    with rw(PANEL_DB) as c:
        c.execute("""CREATE TABLE IF NOT EXISTS quota_history
                     (ts REAL, provider TEXT, window TEXT, used REAL, reset REAL)""")
        now = time.time()
        c.executemany("INSERT INTO quota_history VALUES (?,?,?,?,?)",
                      [(now, it["provider"], w["label"], w["used"], w["reset"])
                       for it in items if not it.get("stale")  # a last known value is not a new reading
                       for w in it["windows"] if w["used"] is not None])


def _refresh_quotas(force=False):
    # provider APIs can take up to ~20 s; only one refresh runs at a time
    if not _quota_lock.acquire(blocking=False):
        return
    try:
        try:
            items = _fetch_quotas(force)
            _record_quotas(items)
            try:
                _attach_local(items)
            except Exception as e:  # the account-wide numbers stand on their own
                print(f"local share: {e}", file=sys.stderr)
            _quota_cache["data"] = {"items": items, "error": None}
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
        _refresh_quotas(force=True)
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


# ---------- this Mac's share of a shared Claude account (see localshare.py) ----------

LOCAL_LOOKBACK = 8 * 86400  # a week window plus a day to learn the rate from


def is_anthropic(provider):
    return provider == "anthropic" or str(provider).startswith("anthropic#")


def _quota_readings(providers, since):
    """{provider: {window: sorted [(ts, used, reset)]}} from quota_history (old per-label ids follow the account)."""
    out = defaultdict(lambda: defaultdict(list))
    if not PANEL_DB.exists():
        return out
    with rw(PANEL_DB) as c:
        c.execute("""CREATE TABLE IF NOT EXISTS quota_history
                     (ts REAL, provider TEXT, window TEXT, used REAL, reset REAL)""")
        rows = c.execute("""SELECT ts, provider, window, used, reset FROM quota_history
                            WHERE ts >= ? AND (provider = 'anthropic' OR provider LIKE 'anthropic#%')""",
                         (since,)).fetchall()
    for ts, prov, win, used, reset in rows:
        p = _anthropic_aliases.get(prov, prov)
        if p in providers:
            out[p][win].append((ts, used, reset))
    for wins in out.values():
        for rs in wins.values():
            rs.sort()
    return out


def _local_claude_events(since):
    """Claude Code requests on this Mac (main + subagents): [(ts, API-equivalent $, model)]."""
    return [(e["ts"], e["cost"], e["model"]) for _, _, cf in clis.claude_sessions(since)
            for e in cf.events if e["ts"] >= since]


def _local_hermes_events(since):
    """Hermes requests on this Mac that went to Anthropic, every profile: [(ts, $, model)]. Hermes keeps cost per
    session and model, not per request: each usage row's cost is spread over that session's assistant messages
    inside the row's first/last-seen span (or put at last_seen when there are none)."""
    out = []
    for _, home in profile_homes():
        db = home / "state.db"
        if not db.exists():
            continue
        try:
            with ro(db) as c:
                rows = c.execute("""SELECT session_id, model, estimated_cost_usd est, actual_cost_usd act,
                                           input_tokens i, output_tokens o, cache_read_tokens cr,
                                           cache_write_tokens cw, first_seen, last_seen
                                    FROM session_model_usage
                                    WHERE billing_provider = 'anthropic' AND coalesce(last_seen, 0) >= ?""",
                                 (since,)).fetchall()
                ids = sorted({r["session_id"] for r in rows})
                stamps = defaultdict(list)
                for i in range(0, len(ids), 500):
                    part = ids[i:i + 500]
                    for m in c.execute(f"""SELECT session_id, timestamp FROM messages WHERE role = 'assistant'
                                           AND session_id IN ({','.join('?' * len(part))})""", part):
                        stamps[m[0]].append(m[1])
        except sqlite3.Error:
            continue
        for r in rows:
            cost = r["act"] or r["est"] or 0.0
            if not cost:
                cost = clis._cost({"model": r["model"], "input": r["i"] or 0, "output": r["o"] or 0,
                                   "cache_read": r["cr"] or 0, "cache_write": r["cw"] or 0})
            if not cost:
                continue
            lo, hi = (r["first_seen"] or 0) - 1, (r["last_seen"] or 0) + 1
            ts = [t for t in stamps.get(r["session_id"], []) if lo <= t <= hi] or [r["last_seen"]]
            out += [(t, cost / len(ts), r["model"]) for t in ts if t and t >= since]
    return out


def _anthropic_routing(items):
    """Which account each local client uses -> (claude_code item provider | None, Hermes pool order, fill_first).
    Hermes order: the item provider of every pooled Claude credential in priority order (None = its account is
    not known)."""
    from agent.credential_pool import STRATEGY_FILL_FIRST, get_pool_strategy, load_pool

    def owner(label, source):
        for it in items:
            for a in it.get("accounts") or []:
                if a.get("label") == label and a.get("source") == source and a.get("verification") != "unverified":
                    return it["provider"]
        return items[0]["provider"] if len(items) == 1 else None

    cc = next((it["provider"] for it in items for a in it.get("accounts") or []
               if a.get("source") == "claude_code" and a.get("verification") != "unverified"), None)
    entries = sorted(load_pool("anthropic").entries(), key=lambda e: (e.priority if e.priority is not None else 99))
    order = [owner(e.label, e.source) for e in entries]
    return cc, order, get_pool_strategy("anthropic") == STRATEGY_FILL_FIRST


_routing = {"cc": None, "order": [], "fill_first": False, "multi": False}


def _attach_local(items, now=None):
    """Adds `local` to every Claude quota item: {window label: {local, other, local_cost, basis, rate}}."""
    now = now or time.time()
    claude = [it for it in items if is_anthropic(it["provider"])]
    if not claude:
        return
    cc, order, fill_first = _anthropic_routing(claude)
    _routing.update(cc=cc, order=order, fill_first=fill_first, multi=len(claude) > 1)
    since = now - LOCAL_LOOKBACK
    provs = [it["provider"] for it in claude]
    history = _quota_readings(set(provs), since)
    by, lost = localshare.attribute(provs, cc, order, fill_first, history,
                                    _local_claude_events(since), _local_hermes_events(since))
    res = localshare.shares(claude, history, by, lost, now)
    for it in claude:
        it["local"] = res.get(it["provider"]) or {}


def session_account(kind, provider, model, items, now=None):
    """(item provider, display name) of the Claude account a running session uses, or (None, None).
    Claude Code: its own login. Hermes on Anthropic: where the fill_first pool sends a request now."""
    claude = {it["provider"]: it for it in items if is_anthropic(it["provider"])}
    if len(claude) < 2:
        return None, None
    if kind == "claude-code":
        p = _routing["cc"]
    elif kind == "hermes" and provider == "anthropic" and _routing["fill_first"]:
        cur = {p: {w["label"]: [(now or time.time(), w.get("used"), w.get("reset"))] for w in it.get("windows") or []}
               for p, it in claude.items()}
        p = localshare.hermes_account(_routing["order"], cur, now or time.time())
    else:
        p = None
    return (p, claude[p].get("name")) if p in claude else (None, None)


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
    `hermes://open/<id>` was run for real against Hermes.app (a desktop session of another profile, a CLI session, a
    kanban worker session): the desktop app opened the chat each time, whatever the origin or profile. So the URL is
    offered for every Hermes session when Hermes.app is installed (`source` is kept for callers and tests)."""
    cmd = "hermes " + (f"-p {shlex.quote(profile)} " if profile and profile != "default" else "") \
          + f"--resume {shlex.quote(sid)}"
    url = f"hermes://open/{quote(sid, safe='')}" if hermes_desktop_installed() else None
    return {"kind": "hermes-session", "url": url, "command": cmd, "label": _label(title, sid)}


# ---------- where does a session live on screen? (process facts for the click) ----------

APP_RE = re.compile(r"^(/.*?\.app)/Contents/")
_PS = {"t": 0.0, "table": {}}


def parse_ps(text):
    """`ps -axo pid=,ppid=,tty=,command=` -> {pid: (ppid, tty or None, command)}."""
    table = {}
    for line in text.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 3 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        tty = None if parts[2] in ("??", "?", "-") else parts[2]
        table[int(parts[0])] = (int(parts[1]), tty, parts[3] if len(parts) > 3 else "")
    return table


def proc_table():
    """Process list, at most one `ps` per 2 s."""
    now = time.time()
    if now - _PS["t"] > 2:
        try:
            out = subprocess.run(["ps", "-axo", "pid=,ppid=,tty=,command="], capture_output=True, text=True,
                                 timeout=5).stdout
            _PS["table"], _PS["t"] = parse_ps(out), now
        except (OSError, subprocess.SubprocessError):
            pass
    return _PS["table"]


def process_info(pid, table=None):
    """Where a live process shows up: its tty, and the app that hosts it (nearest ancestor inside an `.app` bundle:
    Terminal, iTerm, Hermes.app...). `background` = it runs inside Claude Code's background pty host (no window).
    None when the pid is not alive."""
    table = proc_table() if table is None else table
    if not pid or pid not in table or not clis.pid_alive(pid):
        return None
    info = {"pid": pid, "tty": table[pid][1], "app": None, "app_pid": None, "background": False}
    cur, hops = pid, 0
    while cur in table and hops < 25:
        ppid, _, cmd = table[cur]
        if "bg-pty-host" in cmd or "--bg-spare" in cmd:
            info["background"] = True
        m = APP_RE.match(cmd)
        if m and info["app"] is None:
            info["app"], info["app_pid"] = m.group(1), cur
        if ppid <= 1 or ppid == cur:
            break
        cur, hops = ppid, hops + 1
    return info


def with_process(o, pid, attach=None, table=None):
    """Add the process facts to an `open` object (keys are always present; see docs/api-live.md)."""
    info = process_info(pid, table) if pid else None
    o.update({"running": bool(info), "pid": info["pid"] if info else None, "tty": info["tty"] if info else None,
              "app": info["app"] if info else None, "app_pid": info["app_pid"] if info else None,
              "background": bool(info and info["background"]), "attach": attach})
    return o


def open_kanban_card(card_id, board, title, session_cmd=None, session_url=None):
    """Kanban card: board page + a command that prints the card (`hermes kanban [--board <b>] show <id>`; --board is a
    flag of `kanban`, so it goes before the verb). A row with a worker session also carries that session
    (`session_command`, `session_url`): clicking the row opens the session, the card has no route of its own."""
    cmd = "hermes kanban " + (f"--board {shlex.quote(board)} " if board and board != "default" else "") \
          + f"show {shlex.quote(card_id)}"
    out = {"kind": "kanban-card", "url": HERMES_KANBAN_URL if hermes_desktop_installed() else None,
           "command": cmd, "label": _label(title, card_id), "card_id": card_id}
    if session_cmd:
        out["session_command"] = session_cmd
        out["session_url"] = session_url
    return out


def claude_attach_command(sid, job=None):
    """`claude attach <id>` opens a background (daemon-hosted) session in this terminal; the session keeps running."""
    return f"claude attach {shlex.quote(job or sid[:8])}"


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


def _attach_for(row, sid):
    """`claude attach` command for a Claude Code session hosted in the background (no window of its own)."""
    return claude_attach_command(sid, row.get("_job")) if row and row.get("_bg") else None


def _open_for(r, by_id, table=None):
    """The `open` object of one Live row (contract: docs/api-live.md)."""
    if r.get("kanban"):
        k = r["kanban"]
        card_only = r.get("card_only")
        sess = None if card_only else open_hermes_session(r["profile"], r["id"], r["origin"], r["title"])
        o = open_kanban_card(k["id"], k["board"], k["title"], sess and sess["command"], sess and sess["url"])
        return with_process(o, None if card_only else r.get("_pid"), table=table)
    if r["subagent"]:  # a subagent has no window of its own: open its parent
        parent = by_id.get((r["profile"], r["parent"]))
        ppid = parent.get("_pid") if parent else None
        if r["kind"] == "hermes" and r.get("_psource"):
            return with_process(open_hermes_session(r["profile"], r["parent"], r["_psource"], r.get("parent_title")),
                                ppid, table=table)
        if r["kind"] == "claude-code" and r["parent"]:
            o = open_cli_session("claude-code", r["parent"], parent and parent.get("_project") or r.get("_project"),
                                 parent and parent.get("title"))
            return with_process(o, ppid, _attach_for(parent, r["parent"]), table)
        return dict(NO_OPEN)
    if r["kind"] == "hermes":
        return with_process(open_hermes_session(r["profile"], r["id"], r["origin"], r["title"]), r.get("_pid"), table=table)
    if r["kind"] in ("claude-code", "copilot-cli"):
        attach = _attach_for(r, r["id"]) if r["kind"] == "claude-code" else None
        return with_process(open_cli_session(r["kind"], r["id"], r.get("_project"), r["title"]), r.get("_pid"),
                            attach, table)
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
                    row["_pid"] = leases.get(s["id"])  # the process behind the lease (dropped before the response)
                    if s["source"] == "kanban" and s["parent"] is None:
                        # evidence for pairing the worker with its card
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
                        "_pid": s.get("pid"), "_bg": s.get("background"), "_job": s.get("job"),
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
    table = proc_table()
    q = quotas()
    for r in running:
        r["open"] = _open_for(r, by_id, table)
        # the Claude account (its name in Hermes' pool) a session runs on, when there are several
        r["account_provider"], r["account"] = session_account(r.get("kind"), r.get("provider"), r.get("model"),
                                                              q.get("items") or [], now)
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
        "running": running, "counts": live_counts(running), "burn": burn, "quotas": q,
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
