"""This Mac's share of a Claude account's usage windows (session / week), for accounts shared with other computers.

Anthropic only reports an account-wide percentage. What this Mac used is known in API-equivalent dollars
(Claude Code transcripts + Hermes' per-model usage rows), so the share is estimated in two steps:

1. Which account did a local request go to?
   - Claude Code: the account of the pool credential whose source is `claude_code` (the CLI's own login).
   - Hermes: the pool order (fill_first). At time t a request goes to the first credential whose account was not
     full (a window at 100 %) at t. Other pool strategies cannot be replayed: those requests stay unattributed.
   A request from before its account first shows up in the quota history is dropped (the pool may have held
   other accounts back then).
2. How many percent is a local dollar worth on that account (the rate, %/$)?
   Every window instance (a 5 h session, a week) ends at some value U after this Mac spent C there, and
   U / C >= rate (another computer only adds to U). The smallest U / C over the windows this Mac spent enough in
   (the current one included) is the estimate: exact when, in one of them, nothing else ran.

The local part of a window is min(rate * local $, every rise seen while this Mac was busy, the window's value);
without a rate only that upper bound is known (basis "bound"). Everything here is pure; panel.py feeds it.
"""
import bisect

WINDOW_LEN = {"Current session": 5 * 3600, "Current week": 7 * 86400, "Opus week": 7 * 86400,
              "Sonnet week": 7 * 86400}
MODEL_FILTER = {"Opus week": "opus", "Sonnet week": "sonnet"}  # model-specific weekly windows
LAG = 420              # usage is read every few minutes and trails the requests: cost this long before still counts
SAME_RESET = 900       # two readings belong to one window instance when their reset times are this close
FULL_AT = 99.5         # a window at or above this is full: Hermes' pool moves on to the next account
FULL_STALE = 1800      # a "full" reading is trusted this long
KNOWN_SLACK = 900      # requests this long before an account's first reading are still attributed to it
RATE_MIN_COST = 1.0    # a window teaches the rate only when this Mac spent at least this much there ($)
RATE_MIN_USED = 3.0    # ... and it reached at least this many percent (the API reports whole percents)
COMPLETE_GAP = 1200    # a past window counts when its last reading is this close to its reset


class Costs:
    """Local cost events [(ts, cost, model)] with prefix sums: cost in a time range in O(log n)."""

    def __init__(self, events, model_filter=None):
        evs = sorted((t, c) for t, c, m in events
                     if c and (model_filter is None or model_filter in (m or "").lower()))
        self.ts = [t for t, _ in evs]
        self.pre = [0.0]
        for _, c in evs:
            self.pre.append(self.pre[-1] + c)

    def between(self, t0, t1):
        """Cost with t0 < ts <= t1."""
        return self.pre[bisect.bisect_right(self.ts, t1)] - self.pre[bisect.bisect_right(self.ts, t0)]


def _same(r0, r1):
    return bool(r0 and r1 and abs(r0 - r1) <= SAME_RESET)


def intervals(readings):
    """Consecutive readings [(ts, used, reset)] of one window -> [(t0, t1, rise)] inside one window instance."""
    out = []
    rs = sorted(readings)
    for (t0, u0, r0), (t1, u1, r1) in zip(rs, rs[1:]):
        if _same(r0, r1) and u0 is not None and u1 is not None:
            out.append((t0, t1, u1 - u0))
    return out


def instances(readings):
    """Readings grouped by window instance -> [(reset, last ts, final used)]."""
    groups = []
    for t, u, r in sorted(readings):
        if u is None or not r:
            continue
        if groups and _same(groups[-1][0], r):
            g = groups[-1]
            groups[-1] = (g[0], t, max(g[2], u))
        else:
            groups.append((r, t, u))
    return groups


def learn_rate(readings, costs, length, now, current=None):
    """%/$ of a window: the smallest final-value / local-cost over window instances this Mac spent enough in.
    current = (used, reset) of the instance still running (its value so far over its cost so far)."""
    ratios = []
    for reset, last, used in instances(readings):
        if reset > now or reset - last > COMPLETE_GAP:
            continue  # still running (see current) or its end was not seen
        c = costs.between(reset - length, reset)
        if c >= RATE_MIN_COST and used >= RATE_MIN_USED:
            ratios.append(used / c)
    if current and current[0] is not None and current[1]:
        used, reset = current
        c = costs.between(reset - length, now + 60)
        if c >= RATE_MIN_COST and used >= RATE_MIN_USED:
            ratios.append(used / c)
    return min(ratios) if ratios else None


def upper_bound(readings, costs, start, used, now):
    """Most of the window this Mac can have caused: every rise seen while it was busy (+ what was there before
    the first reading, when it was busy before that)."""
    rs = sorted(r for r in readings if r[0] >= start and r[1] is not None)
    if not rs:
        return used if costs.between(start - 1, now) > 0 else 0.0
    bound = rs[0][1] if costs.between(start - 1, rs[0][0]) > 0 else 0.0
    for t0, t1, d in intervals(rs):
        if d > 0 and costs.between(t0 - LAG, t1) > 0:
            bound += d
    if used > rs[-1][1] and costs.between(rs[-1][0] - LAG, now + 60) > 0:
        bound += used - rs[-1][1]
    return min(bound, used)


def window_share(label, used, reset, readings, costs, unattributed, now):
    """One window of one account -> {"local", "other", "local_cost", "basis", "rate"}.
    basis: idle (nothing ran here) | estimate (rate known) | bound (only an upper limit) | unknown."""
    length = WINDOW_LEN.get(label)
    if used is None or not length or not reset:
        return None
    start = reset - length
    cost = costs.between(start, now + 60)
    out = {"local_cost": round(cost, 2)}
    if cost <= 0:
        if unattributed.between(start, now + 60) > 0:
            return dict(out, local=None, other=None, basis="unknown", rate=None)
        return dict(out, local=0.0, other=round(used, 1), basis="idle", rate=None)
    rate = learn_rate(readings, costs, length, now, current=(used, reset))
    bound = upper_bound(readings, costs, start, used, now)
    if rate:
        local = min(used, rate * cost, bound)
        return dict(out, local=round(local, 1), other=round(used - local, 1), basis="estimate", rate=round(rate, 5))
    return dict(out, local=round(bound, 1), other=round(used - bound, 1), basis="bound", rate=None)


def full_at(readings_by_window, t):
    """True when the account's latest reading at or before t (not older than FULL_STALE) had a window full."""
    for rs in readings_by_window.values():
        i = bisect.bisect_right(rs, (t, float("inf"), float("inf")))
        if i and t - rs[i - 1][0] <= FULL_STALE and (rs[i - 1][1] or 0) >= FULL_AT:
            return True
    return False


def first_seen(readings_by_window):
    return min((rs[0][0] for rs in readings_by_window.values() if rs), default=None)


def hermes_account(order, history, t):
    """Account (quota item provider) Hermes' fill_first pool sends a request to at time t, or None (unknown).
    order: item provider per pool credential in priority order (None = credential of an unknown account)."""
    for p in order:
        if p is None:
            return None
        if not full_at(history.get(p, {}), t):
            return p
    return None


def attribute(items_providers, claude_code_item, hermes_order, fill_first, history, claude_events, hermes_events):
    """Split local cost events between accounts -> ({provider: [(ts, cost, model)]}, unattributed events).
    Unattributed = the account cannot be told (unknown credential first in line, another pool strategy); they make a
    window "unknown". A request routed to an account before that account shows up in the history is dropped: the
    pool held other credentials back then, so it says nothing about today's accounts."""
    by = {p: [] for p in items_providers}
    lost = []
    single = items_providers[0] if len(items_providers) == 1 else None
    known = {p: first_seen(history.get(p, {})) for p in items_providers}

    def put(p, ev):
        if p not in by:
            lost.append(ev)
            return
        k = known.get(p)
        if k is not None and ev[0] >= k - KNOWN_SLACK:
            by[p].append(ev)

    for ev in claude_events:
        put(claude_code_item or single, ev)
    for ev in hermes_events:
        put(single or (hermes_account(hermes_order, history, ev[0]) if fill_first else None), ev)
    return by, lost


def shares(items, history, events_by, lost, now):
    """Per item provider -> {window label: window_share}. history: {provider: {window: sorted readings}}."""
    out = {}
    for it in items:
        p = it["provider"]
        hist = history.get(p, {})
        evs = events_by.get(p, [])
        seen = first_seen(hist)
        # unattributed requests from before this account showed up cannot make its numbers unknown
        mine_lost = [e for e in lost if seen is not None and e[0] >= seen - KNOWN_SLACK]
        wins = {}
        for w in it.get("windows") or []:
            label = w["label"]
            if label not in WINDOW_LEN:
                continue
            mf = MODEL_FILTER.get(label)
            ws = window_share(label, w.get("used"), w.get("reset"), hist.get(label, []), Costs(evs, mf),
                              Costs(mine_lost, mf), now)
            if ws:
                wins[label] = ws
        out[p] = wins
    return out
