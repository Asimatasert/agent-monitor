# `/api/live` contract (server → web panel, Agent Bar, widget)

Read-only JSON on `http://127.0.0.1:<port>/api/live` (port: `AGENT_MONITOR_PORT`, default 8777).
This file is the contract the interface work builds on. Everything below is additive: fields that existed before keep
their meaning, except where "changed" is stated.

## Rows: `running[]`

One row per **open** session, per running kanban card, and per subagent (recent). A row is one of three kinds:

| Row | How to recognise it | Notes |
|---|---|---|
| Hermes session | `kind: "hermes"`, no `source` key (legacy) | `origin` = Hermes `sessions.source` (`desktop`, `cli`, `tui`, `kanban`, `telegram`…) |
| Claude Code / Copilot CLI session | `kind: "claude-code"` / `"copilot-cli"`, `source` set | `profile` is still the display name ("Claude Code") for old clients — use `source_name` |
| Running kanban card without a session row | `card_only: true`, `origin: "kanban"` | `id` is the card id (`t_…`), not a session id |

### What "open" means (changed)

* `desktop`, `cli`, `tui` sessions: open exactly while their lease in `<profile>/runtime/active_sessions.json` is live
  (pid alive) — **however long they have been quiet**. A closed window disappears even if it wrote a minute ago.
* Every other Hermes source (kanban worker, telegram, slack, cron…): open while it holds a lease **or** wrote within
  `ACTIVE_WINDOW` (600 s).
* Claude Code: open while its process registry entry (`~/.claude/sessions/<pid>.json`) is live, however quiet.
* Copilot CLI: no process registry could be verified on this machine, so a session is open while it wrote within 15 min
  (not 2 min as before), or — best effort, unverified — while an `inuse.<pid>.lock` file in its session folder names a
  live pid.
* Subagents: shown while their parent is open and they are not ended and wrote within 1 h (or within 10 min regardless).
* Every kanban card with `status = running` is a row: paired with its worker session when one is found, otherwise a
  `card_only` row (`state: "working"` while the card's `worker_pid` lives, `"stalled"` when it is gone).

### Fields

| Field | Type | Meaning |
|---|---|---|
| `id` | string | session id (card id when `card_only`) |
| `kind` | `"hermes"` \| `"claude-code"` \| `"copilot-cli"` | **new.** What the row is; use this instead of `source == nil` |
| `source_name` | string | **new.** "Hermes", "Claude Code", "Copilot CLI" |
| `profile` | string | Hermes profile; for CLI rows still the display name (legacy, will become `null`) |
| `origin` | string | where it was started: `desktop`, `cli`, `tui`, `kanban`, `telegram`, `claude-code`, `copilot-cli`… |
| `status` | `"running"` \| `"ended"` | **changed.** Used to carry the end reason (`cli_close`, `agent_close`…) |
| `end_reason` | string \| null | **new.** Why it ended (`status == "ended"` only) |
| `state` | `working` \| `waiting` \| `needs_approval` \| `stalled` \| `ended` | working = turn in progress; waiting = "your turn"; stalled = see below |
| `state_since` | number \| null | since when (waiting / stalled / approval) |
| `waiting_for` | `"approval"` \| `"input"` \| `"review"` \| `null` | `approval` for a session asking to approve a command; kanban cards use `input` / `review` (see `/api/kanban`) |
| `waiting_detail` | string \| null | **new.** Claude Code rows: the CLI's own reason text ("permission prompt"…) when `state` is `needs_approval` (it used to be in `waiting_for`) |
| `long_tool_call` | string \| null | **new.** Name of the tool call that is still running (no result yet) when the session has been quiet > 60 s |
| `kanban` | object \| null | **new.** The paired card: `{id, board, status, title, block_kind}` |
| `kanban_card`, `kanban_status` | string \| null | card title / status; kept for old clients. Set **only** on kanban worker rows |
| `card_only` | bool | **new.** Present (true) on rows built from a card alone |
| `open` | object | **new.** How to open it — see below |
| `working`, `interactive`, `subagent`, `parent`, `parent_title`, `parent_model`, `title`, `model`, `provider`, `started`, `last`, `activity`, `tokens`, `cost`, `tools`, `messages`, `context_tokens`, `context_estimated`, `loop_max` | | unchanged |

Top level: `counts` (**new**) — one counting rule for every surface (main sessions and card-only rows with
`status == "running"`; subagents apart):

```json
"counts": {"open": 8, "working": 3, "needs_approval": 0, "your_turn": 5, "stalled": 0, "subagents": 0}
```

### States

* `needs_approval`: Hermes states a pending command approval only in the activity label (`"…approval…"`); there is no
  structured field, so this is a text match (`APPROVAL_MARK` in `panel.py`). Claude Code reports it itself
  (`waitingFor` in its registry).
* `stalled`: the turn claims to run but wrote nothing for 10 min. **If the last message is an assistant tool call with
  no result yet (a build, a test run), the limit is 30 min and until then the row is `working` with `long_tool_call`
  set** — clients should phrase it "working · long tool call", not "stuck".
* Kanban pairing (worker session → card), in this order of evidence: the session's lease pid equals the card's
  `worker_pid`; the card id in the session's first message ("work kanban task t_…"); same assignee + same title +
  started no earlier than 2 min before the card. A session that is not a kanban worker (a desktop chat of the same
  profile) never gets a card. `tasks.session_id` is not used (it is the session that *created* the card).

## `open` object

```json
{"kind": "hermes-session" | "kanban-card" | "claude-code" | "copilot-cli" | "none",
 "url": "<string>" | null,
 "command": "<string>" | null,
 "label": "<string>"}
```

`url` is set only for a URL scheme that was verified (below); otherwise `command` is the fallback. A client opens `url`
when present (`NSWorkspace.open`), else **copies** `command` to the clipboard and tells the user — a command is never
run automatically. `label` is the session/card title (or its id), language-neutral. `kind: "none"` → the row is not
clickable (no cursor/chevron).

| `open.kind` | Row | `url` | `command` |
|---|---|---|---|
| `hermes-session` | Hermes session (desktop/cli/tui/messaging/…) and subagents (opens the **parent**) | `hermes://open/<session id>` for `origin == "desktop"` when `/Applications/Hermes.app` (or `~/Applications`) exists, else `null` | `hermes -p <profile> --resume <id>` (`-p` omitted for `default`) |
| `kanban-card` | kanban worker row, card-only row, and every card in `/api/kanban` | `hermes://open/kanban` (the board page) when Hermes.app exists | `hermes kanban [--board <slug>] show <card id>` |
| `claude-code` | Claude Code session (subagents → parent session) | `null` | `cd '<project>' && claude --resume '<id>'` |
| `copilot-cli` | Copilot CLI session | `null` | `copilot --resume '<id>'` |
| `none` | anything else | `null` | `null` |

Extra keys on `kanban-card`: `card_id`; and `session_command` (the `hermes -p … --resume …` command of the worker
session) when the row has a worker session.

### What was verified, and what was not

* `hermes --help` lists `--resume SESSION` and `-p/--profile`; `hermes kanban show <id>` prints the card. `--board` is
  an option of `kanban` itself, so it goes **before** the verb (`hermes kanban --board work show t_…`; after the verb
  it is a usage error — checked by running it).
* `claude --help` lists `--resume`; Claude Code finds a session under the current directory's project, hence the `cd`.
* `copilot` is not installed on this machine: `copilot --resume <id>` could not be checked.
* `hermes://open/<id>`: **read in Hermes' source, not run** (Hermes `b4649c449f`): `Info.plist` registers the `hermes`
  scheme; `apps/desktop/src/lib/hermes-open-target.ts` maps `hermes://open/<path>` to the in-app route `/<path>`;
  `apps/desktop/src/app/routes.ts` makes a single-segment route a chat (`/<session id>`). The URL carries no
  profile, so whether the desktop opens another profile's session was not verified. That is why a URL is offered only
  for `origin == "desktop"` and `command` is always present as the fallback. Please try one for real before relying on it.
* Hermes has **no per-card route** (the open card is component state in `board.tsx`): the card's `url` opens the board,
  `command` prints the card. Clients should copy the card id/command and say so.

### Example (real output, trimmed)

```json
{
  "id": "20261016_210916_507e91", "kind": "hermes", "source_name": "Hermes", "profile": "developer",
  "origin": "kanban", "status": "running", "end_reason": null, "state": "working", "waiting_for": null,
  "long_tool_call": "terminal",
  "kanban": {"id": "t_8eef210b", "board": "default", "status": "running", "title": "Aşama 1: İskelet…", "block_kind": null},
  "kanban_card": "Aşama 1: İskelet…", "kanban_status": "running",
  "open": {"kind": "kanban-card", "url": "hermes://open/kanban", "command": "hermes kanban show t_8eef210b",
           "label": "Aşama 1: İskelet…", "card_id": "t_8eef210b",
           "session_command": "hermes -p developer --resume 20261016_210916_507e91"}
}
```

```json
{
  "id": "20261016_202534_610fd2", "kind": "hermes", "profile": "lead", "origin": "desktop", "status": "running",
  "state": "waiting", "kanban": null,
  "open": {"kind": "hermes-session", "url": "hermes://open/20261016_202534_610fd2",
           "command": "hermes -p lead --resume 20261016_202534_610fd2", "label": "safariwelcomepage projesini…"}
}
```

```json
{
  "id": "29517443-…", "kind": "claude-code", "source": "claude-code", "source_name": "Claude Code",
  "profile": "Claude Code", "origin": "claude-code", "state": "waiting",
  "open": {"kind": "claude-code", "url": null, "command": "cd /Users/asimatasert && claude --resume 29517443-…", "label": "hermes"}
}
```

A session asking for approval has `state: "needs_approval"`, `waiting_for: "approval"` and the same `open` object as any
other row of its kind.

## Kanban cards (`/api/kanban`)

Each card in `boards[].cards[]` gains: `board`, `block_kind` (`needs_input` or `null`/other), `waiting_for`
(`"input"` for `blocked` + `needs_input`, `"review"` for status `review`, else `null`), and `open` (`kanban-card`).
Each board gains `blocked_by_kind`, e.g. `{"needs_input": 3, "other": 12}`. Statuses are passed through as Hermes has
them (`triage, todo, scheduled, ready, running, blocked, review, done`).

## Quotas and accounts (`quotas.items[]` in `/api/live`, `/api/accounts`, `/api/overview`)

Credentials in Hermes' pool are grouped by the **account** behind them.

```json
{"provider": "anthropic#8a2047d5", "account_key": "8a2047d5",
 "accounts": [
   {"label": "ANTHROPIC_TOKEN", "source": "env:ANTHROPIC_TOKEN", "verification": "unverified",
    "reason": "usage_unreadable", "http": 429, "account_key": null, "listed_under": "8a2047d5", "priority": 0, "…": "…"},
   {"label": "claude_code", "source": "claude_code", "verification": "verified", "account_key": "8a2047d5", "priority": 1, "…": "…"}],
 "windows": [{"label": "Current session", "used": 16.0, "reset": 1792186800, "detail": null}, "…"],
 "unavailable": null, "unavailable_code": null, "unavailable_http": null}
```

* Account key = first 8 hex digits of sha256 of `account.uuid` from Anthropic's OAuth profile endpoint
  (`GET https://api.anthropic.com/api/oauth/profile`, the call Claude Code itself makes). The raw id is not returned.
* `quotas` id stays `anthropic#<account-key>`. Same account → one item with every credential in `accounts`; two
  different accounts → two items. `verification`: `verified` (identity read), `same_windows` (identity unreadable, but
  the usage windows are identical to the digit), `windows_only` (identity unreadable, windows readable, no match →
  own item keyed `w<hash>`), `unverified` (nothing readable).
* A credential whose identity and usage cannot be read (the setup token in `ANTHROPIC_TOKEN` gets HTTP 403 on the
  profile endpoint, lacking the `user:profile` scope) is **never its own item**: it is listed with
  `verification: "unverified"` under the first item (`listed_under`). If no credential at all is readable there is one
  plain `anthropic` item holding all of them. Whether an unverified credential is the same account is not known; the
  API says so instead of guessing. With two or more verified accounts, an unverified credential is listed under the
  first item only for lack of a better place — `account_key: null` is the authoritative statement.
* `unavailable` (text, English, legacy) is accompanied by `unavailable_code` (`"usage_unreadable"`) and `unavailable_http`;
  clients should render their own text from the code.
* `quota_history` series recorded under the old per-label ids (`anthropic#claude_code`) are returned under the account's
  current id, so charts and `burn` do not restart.
* `/api/health` → `accounts[]`: `credentials[]` gain `account_key`, `verification`; the provider gains
  `accounts_count` (accounts, only where grouped by identity, else `null`), `credentials_count`, `account_keys`.
  "1 account · 2 credentials" = `accounts_count` / `credentials_count`.

## Not changed on purpose (needs the interface work)

`provider: "bilinmiyor"`, `assignee: "atanmamış"` (Turkish data values, S-12), `request_count` (S-13) and `profile` of CLI
rows keep their old values because the current clients match on them.
