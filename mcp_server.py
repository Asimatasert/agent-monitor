#!/usr/bin/env python3
"""Agent Monitor MCP server — lets agents ask where work can safely go before they route it.

Read-only. It queries the local Agent Monitor API (127.0.0.1:8777) and answers with numbers and status codes
only: no session titles and no upstream error text reach the calling agent, so other sessions' content can't
steer it. Start with ./mcp.sh (stdio), which uses the same Python runtime as Hermes.
"""
import json
import plistlib
import sys
import time
import urllib.error
import urllib.request
from datetime import date, datetime
from pathlib import Path

HERMES_AGENT = Path.home() / ".hermes" / "hermes-agent"
sys.path.insert(0, str(HERMES_AGENT))
try:
    import hermes_bootstrap  # noqa: F401  (puts Hermes' venv, which ships the mcp package, on sys.path)
except ImportError:
    pass

from mcp.server.mcpserver import MCPServer  # noqa: E402
from mcp.types import ToolAnnotations  # noqa: E402

API = "http://127.0.0.1:8777"
PREFS = Path.home() / "Library" / "Preferences" / "local.agent.bar.plist"
READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
USABLE_MODEL = ("ok", "degraded")  # statuses a router may still pick (degraded ranks lower)
STATES = ("working", "needs_approval", "waiting", "stalled")  # live states of a running main session
LARGE_CONTEXT = 200_000  # tokens; above this a session should compact or start fresh
LOOP_CALLS = 3  # identical consecutive tool calls (last 30 min) that count as a possible loop

server = MCPServer(
    name="agent-monitor",
    title="Agent Monitor",
    instructions=(
        "Live view of this machine's AI provider quotas, model health, Hermes fallback chains and spend. "
        "Call recommend_model before delegating work to a subagent or choosing a model, and get_quota_status / "
        "get_budget before starting long or expensive jobs. get_agent_attention lists running agent sessions blocked on "
        "the user (approval, finished, stalled, loops, large context). All data is local and read-only."
    ),
)


class MonitorDown(RuntimeError):
    pass


def api(path: str) -> dict:
    try:
        with urllib.request.urlopen(API + path, timeout=15) as r:
            return json.loads(r.read())
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        raise MonitorDown(
            "Agent Monitor is not running on 127.0.0.1:8777 — start ~/agent-monitor/run.sh or open Agent Bar."
        ) from e


def when(ts: float | None) -> dict | None:
    if not ts:
        return None
    return {"at": datetime.fromtimestamp(ts).isoformat(timespec="minutes"), "in_minutes": round((ts - time.time()) / 60)}


def usable_providers(health: dict) -> dict[str, bool]:
    """provider -> has at least one credential that isn't locked (limit reached / quota window full).
    Per-account ids ("anthropic#work") get their own entry from that credential."""
    out = {}
    for a in health["accounts"]:
        out[a["provider"]] = any(not c.get("locked") for c in a["credentials"])
        for c in a["credentials"]:
            out[f"{a['provider']}#{c['label']}"] = not c.get("locked")
    return out


def quota_rows(live: dict, health: dict) -> list[dict]:
    burn = {(b["provider"], b["window"]): b for b in live.get("burn") or []}
    usable = usable_providers(health)
    rows = []
    for item in (live.get("quotas") or {}).get("items") or []:
        windows = []
        for w in item.get("windows") or []:
            if w.get("used") is None:
                continue
            b = burn.get((item["provider"], w["label"]))
            eta = b.get("eta_full") if b else None
            windows.append({
                "window": w["label"], "used_pct": round(w["used"]), "left_pct": max(0, round(100 - w["used"])),
                "resets": when(w.get("reset")),
                "burn_pct_per_hour": round(b["per_hour"], 1) if b else None,
                "full": when(eta),
                "fills_before_reset": bool(eta and w.get("reset") and eta < w["reset"]),
            })
        rows.append({
            "provider": item["provider"], "usable": usable.get(item["provider"], True),
            "min_left_pct": min((w["left_pct"] for w in windows), default=None), "windows": windows,
        })
    return rows


def speed_by_model(health: dict) -> dict[str, dict]:
    """model -> 24 h turn-speed entry from /api/health (hermes preferred over other sources)."""
    out = {}
    for e in health.get("speed") or []:
        m = e.get("model")
        if m and (m not in out or e.get("source") == "hermes"):
            out[m] = {k: e.get(k) for k in ("source", "turns", "p50_s", "p90_s", "first_reply_p50_s")}
    return out


def running_main(live: dict) -> list[dict]:
    return [s for s in live.get("running") or [] if s.get("status") == "running" and not s.get("subagent")]


def spend(o: dict, day: str | None) -> float:
    hermes = sum(v.get("cost") or 0 for d in o["usage"]["daily"] if day in (None, d["day"]) for v in d["by"].values())
    cli = sum(sum(d["cost"].values()) for d in o["clis"]["daily"] if day in (None, d["day"]))
    return hermes + cli


@server.tool(annotations=READ_ONLY)
def get_quota_status(provider: str | None = None) -> dict:
    """Remaining quota per provider: % used/left per window (session, week, month, premium requests), reset time,
    burn rate, projected time the window fills, and whether the provider has a usable account right now.
    `provider` filters to one (anthropic, openai-codex, copilot, gemini, openrouter, ...)."""
    rows = quota_rows(api("/api/live"), api("/api/health"))
    if provider:
        rows = [r for r in rows if r["provider"] == provider]
    return {"providers": rows}


@server.tool(annotations=READ_ONLY)
def get_model_health(provider: str | None = None, include_idle: bool = False) -> dict:
    """Per-model health over the last 24 h: status (ok, degraded, failing, cooldown, account_exhausted, idle),
    calls, error rate, error codes, cooldowns and 24 h turn speed (median/p90 seconds per turn; null if no data).
    Upstream error text is omitted on purpose."""
    health = api("/api/health")
    speed = speed_by_model(health)
    models = []
    for m in health["models"]:
        if provider and m["provider"] != provider:
            continue
        if m["status"] == "idle" and not include_idle:
            continue
        err = m.get("last_error") or {}
        models.append({
            "model": m["model"], "provider": m["provider"], "status": m["status"], "recovered": m.get("recovered", False),
            "calls_24h": m["calls_24h"], "errors_24h": m["errors_24h"],
            "error_rate": round(m["error_rate"], 3) if m.get("error_rate") is not None else None,
            "error_types": m.get("error_types") or {},
            "last_error": {"code": err.get("code"), "type": err.get("type"), **(when(err.get("at")) or {})} if err else None,
            "cooldown_until": when(m.get("cooldown_until")),
            "primary_for": m["profiles"], "fallback_for": m["fallback_for"],
            "speed": speed.get(m["model"]),
        })
    return {"models": models}


@server.tool(annotations=READ_ONLY)
def get_fallback_chains(profile: str | None = None) -> dict:
    """For each Hermes profile: primary model and each fallback with its state (ok, risky, skip) and reason code
    (same_backend, no_credentials, locked, cooldown, error_rate) — i.e. which fallbacks would really be tried."""
    chains = api("/api/health")["chains"]
    if profile:
        chains = [c for c in chains if c["profile"] == profile]
    for c in chains:
        for f in c["fallbacks"]:
            f["until"] = when(f.get("until"))
    return {"chains": chains}


@server.tool(annotations=READ_ONLY)
def recommend_model(prefer_provider: str | None = None, exclude_providers: list[str] | None = None,
                    min_quota_left_pct: int = 10, top: int = 3) -> dict:
    """Rank the models an agent can route work to right now: healthy status, a usable account, quota headroom
    (at least `min_quota_left_pct` left in every window and not projected to fill before reset), and proven recent
    use; faster median turn time over the last 24 h scores higher. Returns the best `top` candidates with the reasons behind each score, plus what was excluded and why."""
    live, health = api("/api/live"), api("/api/health")
    quota = {}
    for r in quota_rows(live, health):
        # several accounts of one provider ("anthropic#a", "anthropic#b"): Hermes fills them in turn, so the
        # headroom that counts is the best usable account's
        base = r["provider"].split("#")[0]
        cur = quota.get(base)
        if r["usable"] and (cur is None or not cur["usable"] or (r["min_left_pct"] or 0) > (cur["min_left_pct"] or 0)):
            quota[base] = r
        elif cur is None:
            quota[base] = r
    usable = usable_providers(health)
    speed = speed_by_model(health)
    exclude = set(exclude_providers or [])
    picks, skipped = [], []
    for m in health["models"]:
        name, prov = m["model"], m["provider"]
        if "safety" in name or prov in exclude or prov == "bilinmiyor":
            continue
        q = quota.get(prov)
        why_not = None
        if m["status"] not in USABLE_MODEL:
            why_not = f"status {m['status']}"
        elif not usable.get(prov, True):
            why_not = "no usable account (limit reached)"
        elif q and q["min_left_pct"] is not None and q["min_left_pct"] < min_quota_left_pct:
            why_not = f"only {q['min_left_pct']}% quota left"
        elif m["calls_7d"] == 0 and not m["profiles"]:
            why_not = "never used here"
        if why_not:
            if m["calls_7d"] or m["profiles"] or m["fallback_for"]:
                skipped.append({"model": name, "provider": prov, "reason": why_not})
            continue
        score, reasons = 50.0, []
        if q and q["min_left_pct"] is not None:
            score += q["min_left_pct"] * 0.3
            reasons.append(f"{q['min_left_pct']}% quota left")
            if any(w["fills_before_reset"] for w in q["windows"]):
                score -= 20
                reasons.append("fills before reset at current burn")
        else:
            reasons.append("no quota window reported")
        rate = m.get("error_rate") or 0
        if m["status"] == "degraded":
            score -= 25
        score -= rate * 100
        reasons.append(f"{m['status']}, {rate:.0%} errors in 24 h" if m["calls_24h"] or m["errors_24h"] else m["status"])
        score += min(m["calls_24h"], 500) / 50  # proven in practice
        sp = speed.get(name)
        if sp and (sp.get("turns") or 0) >= 3 and sp.get("p50_s") is not None:
            score += max(0.0, 10 - sp["p50_s"] / 6)
            reasons.append(f"median turn {sp['p50_s']:.0f} s (24 h, n={sp['turns']})")
        if m["profiles"]:
            reasons.append("primary model of " + ", ".join(m["profiles"]))
        if prefer_provider and prov == prefer_provider:
            score += 15
            reasons.append("preferred provider")
        picks.append({"model": name, "provider": prov, "score": round(score, 1), "reasons": reasons})
    picks.sort(key=lambda p: -p["score"])
    return {"recommended": picks[:max(1, top)], "excluded": skipped}


@server.tool(annotations=READ_ONLY)
def get_budget() -> dict:
    """Estimated spend (Hermes + agent CLIs, API-price equivalent): today, yesterday, month to date and the
    month-end projection, against the daily/monthly budgets set in Agent Bar (0 = no budget)."""
    today = date.today()
    o = api(f"/api/overview?from={today.replace(day=1).isoformat()}&to={today.isoformat()}")
    t = spend(o, today.isoformat())
    y = spend(o, date.fromordinal(today.toordinal() - 1).isoformat()) if today.day > 1 else None
    mtd = spend(o, None)
    days_in_month = (date(today.year + today.month // 12, today.month % 12 + 1, 1) - today.replace(day=1)).days
    projection = (mtd - t) / (today.day - 1) * (days_in_month - today.day) + mtd if today.day > 1 else mtd * days_in_month
    try:
        prefs = plistlib.loads(PREFS.read_bytes())
    except (OSError, plistlib.InvalidFileException):
        prefs = {}
    day_b, month_b = float(prefs.get("budgetDay") or 0), float(prefs.get("budgetMonth") or 0)
    pct = lambda spent, b: round(spent / b * 100) if b else None
    return {"currency": "USD", "today": round(t, 2), "yesterday": round(y, 2) if y is not None else None,
            "month_to_date": round(mtd, 2), "month_end_projection": round(projection, 2),
            "daily_budget": day_b or None, "daily_used_pct": pct(t, day_b),
            "monthly_budget": month_b or None, "monthly_used_pct": pct(mtd, month_b)}


@server.tool(annotations=READ_ONLY)
def get_running_counts() -> dict:
    """How many sessions and subagents are running right now, per source (hermes, claude-code, copilot-cli) and
    Hermes profile, with main-session states (working, needs_approval, waiting, stalled), the largest context
    size and how many sessions look stuck in a tool loop — counts only, no titles."""
    running = [s for s in api("/api/live").get("running") or [] if s.get("status") == "running"]
    per, totals = {}, dict.fromkeys(STATES, 0)
    for s in running:
        key = (s.get("source") or "hermes", s.get("profile") or "")
        slot = per.setdefault(key, {"source": key[0], "profile": key[1], "sessions": 0, "subagents": 0,
                                    **dict.fromkeys(STATES, 0)})
        slot["subagents" if s.get("subagent") else "sessions"] += 1
        if not s.get("subagent") and s.get("state") in STATES:
            slot[s["state"]] += 1
            totals[s["state"]] += 1
    contexts = [s["context_tokens"] for s in running if not s.get("subagent") and s.get("context_tokens")]
    return {"sessions": sum(p["sessions"] for p in per.values()), "subagents": sum(p["subagents"] for p in per.values()),
            **totals, "largest_context_tokens": max(contexts, default=None),
            "possible_loops": sum(1 for s in running if (s.get("loop_max") or 0) >= LOOP_CALLS),
            "by_source": list(per.values())}


@server.tool(annotations=READ_ONLY)
def get_agent_attention() -> dict:
    """Running main agent sessions that need attention: waiting for approval, finished and waiting for the user,
    stalled, possibly looping on the same tool call, or carrying a very large context. An orchestrator can use it
    to see which agents are blocked on the user. Most urgent first; no titles."""
    order = {"needs_approval": 0, "stalled": 1, "waiting": 2}
    rows = []
    for s in running_main(api("/api/live")):
        state, ctx, loops = s.get("state"), s.get("context_tokens"), s.get("loop_max") or 0
        reasons = []
        if state == "needs_approval":
            reasons.append("needs approval")
        elif state == "waiting":
            reasons.append("finished, waiting for you")
        elif state == "stalled":
            reasons.append("stalled (no progress)")
        if loops >= LOOP_CALLS:
            reasons.append(f"possible loop ({loops} identical tool calls)")
        if ctx and ctx >= LARGE_CONTEXT:
            reasons.append(f"large context ({ctx} tokens) — consider /compact or a new session")
        if not reasons:
            continue
        rows.append((order.get(state, 3), s.get("state_since") or float("inf"), {
            "source": s.get("source") or "hermes", "profile": s.get("profile"), "model": s.get("model"),
            "state": state, "since": when(s.get("state_since")), "waiting_for": s.get("waiting_for"),
            "context_tokens": ctx, "context_estimated": bool(s.get("context_estimated")), "loop_max": loops,
            "reasons": reasons,
        }))
    rows.sort(key=lambda r: r[:2])
    return {"count": len(rows), "sessions": [r[2] for r in rows]}


if __name__ == "__main__":
    server.run("stdio")
