// Agent Bar — menu bar companion for Agent Monitor (iStat Menus style).
// Reads the panel's JSON API (127.0.0.1:8777): /api/live every few seconds, /api/overview and
// /api/accounts every minute. The bar shows a token sparkline + running sessions + tightest quota;
// the popover has Live / Quotas / Usage / Kanban tabs. Build with ../make-menubar.sh.
import AppKit
import Charts
import ServiceManagement
import SwiftUI
import UserNotifications
import WidgetKit

/// Panel server. Default http://127.0.0.1:8777; to point the app at another instance (a test server) set
/// AGENT_MONITOR_PORT in the environment, or `defaults write local.agent.bar serverPort -int <port>`.
let SERVER_PORT: Int = {
    if let p = ProcessInfo.processInfo.environment["AGENT_MONITOR_PORT"].flatMap(Int.init), p > 0 { return p }
    let d = UserDefaults.standard.integer(forKey: "serverPort")
    return d > 0 ? d : 8777
}()
let BASE = "http://127.0.0.1:\(SERVER_PORT)"
let LAUNCHER = NSHomeDirectory() + "/agent-monitor/launch.sh"
let LIVE_EVERY: TimeInterval = 4
let SLOW_EVERY: TimeInterval = 60

// ---------- data (subsets of the panel API; keys are snake_case on the wire) ----------

struct TC: Decodable { let tokens: Double?; let cost: Double? }

struct LiveData: Decodable {
    let now: Double
    let last1m: Double?
    let last5m: Double?
    let last60m: Double?
    let cost60m: Double?
    let running: [Session]
    let burn: [Burn]?
    let quotas: Quotas?
    let tokens: [TokMin]?
    let activity: [Act]?
    let byProfile: [ProfUse]?
    let counts: LiveCounts?     // the server's one counting rule (open / working / needs approval / your turn / stalled)

    // convertFromSnakeCase turns "last_1m" into "last1M", so these are spelled out
    enum CodingKeys: String, CodingKey {
        case now, running, burn, quotas, tokens, activity, byProfile, counts
        case last1m = "last1M", last5m = "last5M", last60m = "last60M", cost60m = "cost60M"
    }
}

struct LiveCounts: Decodable {
    var open = 0, working = 0, needsApproval = 0, yourTurn = 0, stalled = 0, subagents = 0
}

/// `open` object of /api/live rows and /api/kanban cards (docs/api-live.md): what a click on the row does.
struct OpenAction: Decodable {
    let kind: String            // hermes-session | kanban-card | claude-code | copilot-cli | none
    let url: String?            // set only for a scheme the server verified
    let command: String?        // fallback: run in a new Terminal window (resume/attach) or copied, see Opener.plan
    let label: String?
    let cardId: String?
    let sessionCommand: String? // kanban rows: the worker session's resume command
    var sessionUrl: String? = nil   // kanban rows: hermes://open/<worker session id>
    // process facts of the session behind the row (server: docs/api-live.md, `process_info`)
    var running: Bool? = nil    // a process of this session is alive
    var pid: Int? = nil
    var tty: String? = nil      // e.g. "ttys004" — the terminal tab that holds it
    var app: String? = nil      // .app bundle that hosts the process (Terminal, iTerm, Hermes…)
    var appPid: Int? = nil
    var background: Bool? = nil // lives in Claude Code's background host: no window of its own
    var attach: String? = nil   // `claude attach <id>`: shows a background session in a terminal
    var canOpen: Bool { kind != "none" && (url != nil || command != nil) }
}

struct KanbanRef: Decodable { let id: String; let board: String?; let status: String?; let title: String?; let blockKind: String? }

struct TokMin: Decodable { let t: Double; let by: [String: TC] }
struct Act: Decodable { let t: Double; let assistant: Double?; let tool: Double?; let user: Double? }
struct ProfUse: Decodable { let profile: String; let tokens: Double?; let cost: Double?; let sessions: Double? }

struct Session: Decodable, Identifiable {
    let id: String
    let parent: String?
    let profile: String?
    let source: String?
    let title: String?
    let model: String?
    let status: String
    let subagent: Bool
    let started: Double?
    let last: Double?
    let tokens: Double?
    let cost: Double?
    let tools: Double?
    let activity: String?
    let working: Bool?          // open and producing output right now (vs. open and waiting)
    let state: String?          // working | needs_approval | waiting | stalled | ended
    let stateSince: Double?
    let waitingFor: String?     // approval | input | review | nil
    let contextTokens: Double?
    let contextEstimated: Bool?
    let loopMax: Int?
    let interactive: Bool?      // false for unattended runs (Hermes kanban / cron workers)
    var attended: Bool { interactive ?? true }
    let parentTitle: String?    // the main session this subagent was spawned from
    let parentModel: String?    // its model — shown on a subagent row as "← from <model>"
    let kanbanCard: String?     // the card this agent is on (assignee==profile match; main sessions only)
    let kanbanStatus: String?   // that card's column: running | blocked | ready | todo | triage
    let kind: String?           // hermes | claude-code | copilot-cli
    let origin: String?         // desktop | cli | tui | kanban | telegram | claude-code …
    let endReason: String?
    let waitingDetail: String?  // Claude Code: the CLI's own reason text ("permission prompt")
    let longToolCall: String?   // a tool call that has been running for a while (not "stuck")
    let cardOnly: Bool?         // a running kanban card without a session row
    let kanban: KanbanRef?      // the paired card (kanban worker rows only)
    let open: OpenAction?
    var isRunning: Bool { status == "running" }
    var isWorking: Bool { isRunning && working == true }
    // grouping key/name: who runs the session (Hermes profile / Claude Code / Copilot CLI) — not a provider account
    var groupKey: String { source == "claude-code" ? "claude-code" : source == "copilot-cli" ? "copilot-cli" : "hermes/\(profile ?? "?")" }
    var groupName: String { source == "claude-code" ? "Claude Code" : source == "copilot-cli" ? "Copilot CLI" : "Hermes · \(profile ?? "?")" }
}

struct Burn: Decodable { let provider: String; let window: String; let perHour: Double; let etaFull: Double? }
struct Quotas: Decodable { let items: [QuotaItem]? }
struct QuotaItem: Decodable {
    let provider: String; let accounts: [Account]?; let windows: [QuotaWindow]?
    let accountKey: String?     // set when the account identity was read (one item per real account)
    // windows are the last known reading, not a fresh one (rate limited / unreadable right now)
    let stale: Bool?; let fetchedAt: Double?; let unavailableCode: String?; let unavailableHttp: Double?; let retryAt: Double?
}
/// One credential in Hermes' pool (several credentials can belong to one account).
struct Account: Decodable {
    let label: String?; let status: String?; let requests: Double?
    let source: String?; let verification: String?; let reason: String?; let http: Double?
    var unverified: Bool { verification == "unverified" }
}
struct QuotaWindow: Decodable { let label: String; let used: Double?; let reset: Double?; let detail: String? }

struct AccountsResp: Decodable { let history: [QHist] }
struct QHist: Decodable { let provider: String; let window: String; let points: [[Double]] }

struct Overview: Decodable { let usage: Usage; let clis: CliSummary; let kanban: [Board] }
struct Usage: Decodable { let days: [String]; let daily: [UDay]; let byModel: [ModelUse]; let byProfile: [ProfUse] }
struct UDay: Decodable { let day: String; let by: [String: TC]; let sessions: Double? }
struct ModelUse: Decodable { let model: String?; let provider: String?; let tokens: Double?; let cost: Double?; let calls: Double? }
struct CliSummary: Decodable { let sources: [CliSrc]; let daily: [CliDay] }
struct CliSrc: Decodable { let source: String; let name: String; let tokens: Double?; let cost: Double?; let sessions: Double? }
struct CliDay: Decodable { let day: String; let tokens: [String: Double]; let cost: [String: Double] }
struct Board: Decodable { let board: String; let counts: [String: Double]; let cards: [Card]; let blockedByKind: [String: Double]? }
struct Card: Decodable, Identifiable {
    let id: String
    let title: String?
    let assignee: String?
    let status: String
    let startedAt: Double?
    let completedAt: Double?
    let consecutiveFailures: Double?
    let lastFailureError: String?
    let blockKind: String?      // needs_input = waiting for a human answer
    let waitingFor: String?     // input | review | nil
    let open: OpenAction?
}

// /api/health — decoded without key conversion ("calls_24h" would become "calls24H"), so snake_case names.
struct HealthResp: Decodable {
    let now: Double
    let accounts: [HAccount]
    let models: [HModel]
    let chains: [Chain]
    let speed: [Speed]?
}
struct Speed: Decodable, Identifiable {
    let source: String
    let model: String
    let turns: Int
    let p50_s: Double?
    let p90_s: Double?
    let first_reply_p50_s: Double?
    var id: String { source + "|" + model }
}

let LARGE_CONTEXT = 200_000.0  // past this, a session re-sends a lot every turn: slower and pricier
let HOVER_SESSION_CAP = 6      // above this many sessions the notch hover list shows its scroll indicator

/// Short state label for a session ("your turn · 3m"). Same words on every surface.
func stateText(_ s: Session, now: Double) -> String? {
    let since = s.stateSince.map { " · " + span(now - $0) } ?? ""
    switch s.state {
    case "needs_approval": return L("needs approval", "onay bekliyor") + (s.waitingDetail.map { " (\($0))" } ?? "") + since
    case "waiting": return L("your turn", "sıra sende") + since
    case "stalled": return L("stalled?", "takıldı mı?") + since
    default:
        // a tool call that is still running is work, not a stall
        return s.longToolCall.map { L("long tool call: \($0)", "uzun araç çağrısı: \($0)") }
    }
}

/// "3 working · 1 needs approval · 2 your turn" — one wording for the bar, the notch and the Live tab.
func countLine(_ c: LiveCounts) -> String {
    var p = [L("\(c.working) working", "\(c.working) çalışıyor")]
    if c.needsApproval > 0 { p.append(L("\(c.needsApproval) needs approval", "\(c.needsApproval) onay bekliyor")) }
    if c.yourTurn > 0 { p.append(L("\(c.yourTurn) your turn", "\(c.yourTurn) sıra sende")) }
    if c.stalled > 0 { p.append(L("\(c.stalled) stalled?", "\(c.stalled) takıldı mı?")) }
    return p.joined(separator: " · ")
}
struct Chain: Decodable, Identifiable {
    let profile: String
    let provider: String
    let model: String
    let status: String
    let fallbacks: [ChainEntry]
    let usable: Int
    var id: String { profile }
}
struct ChainEntry: Decodable {
    let provider: String
    let model: String
    let state: String
    let reason: String?   // code: same_backend | no_credentials | locked | cooldown | error_rate
    let until: Double?
    let rate: Double?
}

func chainReason(_ f: ChainEntry) -> String? {
    switch f.reason {
    case "same_backend": return L("same backend as the primary — hits the same limit", "ana modelle aynı arka uç — aynı limite takılır")
    case "no_credentials": return L("no account registered for this provider", "bu sağlayıcı için kayıtlı hesap yok")
    case "locked": return L("account limit reached", "hesap limiti dolu") + (f.until.map { L(" (unlocks \(when($0)))", " (açılış \(when($0)))") } ?? "")
    case "cooldown": return L("model cooling down", "model beklemede") + (f.until.map { " (\(when($0)))" } ?? "")
    case "error_rate": return L(String(format: "%.0f%% errors in the last 24 h", (f.rate ?? 0) * 100),
                                String(format: "son 24 saatte hata oranı %%%.0f", (f.rate ?? 0) * 100))
    case nil: return nil
    default: return f.reason
    }
}
struct TopResp: Decodable { let sessions: [TopSession] }
struct TopSession: Decodable {
    let source: String
    let profile: String
    let id: String
    let title: String?
    let model: String?
    let started: Double?
    let last: Double?
    let tokens: Double?
    let cost: Double
    let subagent: Bool
}
struct HAccount: Decodable {
    let provider: String
    let credentials: [Cred]
    let plan: String?
    let unavailable: String?
    let profiles: [String]
    let fallback_for: [String]
    let windows: [QuotaWindow]
    let accounts_count: Int?    // accounts behind the credentials (nil = identity not readable for this provider)
    let credentials_count: Int?
    let stale: Bool?            // the quota windows are the last known reading (see QuotaItem.stale)
    let fetched_at: Double?
    let unavailable_code: String?
    let unavailable_http: Double?
    let retry_at: Double?
}
struct Cred: Decodable {
    let account_key: String?
    let verification: String?
    let label: String?
    let source: String?
    let auth_type: String?
    let status: String?
    let status_at: Double?
    let error_code: Double?
    let error_reason: String?
    let error_message: String?
    let exhausted_until: Double?
    let requests: Double?
    let expires_at: Double?
    let model_cooldowns: [String: Double]
    let locked: Bool
}
struct HModel: Decodable, Identifiable {
    let provider: String
    let model: String
    let profiles: [String]
    let fallback_for: [String]
    let calls_24h: Double
    let tokens_24h: Double
    let cost_24h: Double
    let calls_7d: Double
    let last_ok: Double?
    let errors_24h: Double
    let error_types: [String: Double]
    let last_error: LastError?
    let cooldown_until: Double?
    let error_rate: Double?
    let recovered: Bool
    let status: String
    var id: String { provider + "|" + model }
}
struct LastError: Decodable { let at: Double; let type: String?; let code: Double?; let summary: String? }

// ---------- language ----------

/// UI language (⚙ → Language): English by default, Turkish optional.
func isTR() -> Bool { UserDefaults.standard.string(forKey: Pref.lang) == "tr" }
func L(_ en: String, _ tr: String) -> String { isTR() ? tr : en }
func appLocale() -> Locale { Locale(identifier: isTR() ? "tr_TR" : "en_US") }

func weekdayShort(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = appLocale()
    f.dateFormat = "EEE"
    return f.string(from: d)
}

// ---------- helpers ----------

let SOURCE_NAME = ["hermes": "Hermes", "claude-code": "Claude Code", "copilot-cli": "Copilot CLI"]
let SOURCE_COLOR: [String: Color] = ["Hermes": .purple, "Claude Code": .orange, "Copilot CLI": .blue]
let PROVIDER_NAME = ["anthropic": "Anthropic (Claude)", "openai-codex": "OpenAI Codex", "nvidia": "NVIDIA",
                     "gemini": "Google Gemini", "copilot": "GitHub Copilot", "openrouter": "OpenRouter"]
let WINDOW_NAME: [String: (String, String)] = [
    "Current session": ("Session", "Oturum"), "Current day": ("Day", "Gün"), "Current week": ("Week", "Hafta"),
    "Current month": ("Month", "Ay"), "Premium requests": ("Premium requests", "Premium istek"),
    "Opus week": ("Opus week", "Opus hafta"), "Sonnet week": ("Sonnet week", "Sonnet hafta"),
]
/// "anthropic#work" = one of several accounts of a provider: shown as "Anthropic (Claude) · work".
func pBase(_ p: String) -> String { String(p.split(separator: "#", maxSplits: 1).first ?? Substring(p)) }
/// Providers that currently have >= 2 account items (set by the store); only these get the "· <account>" suffix.
var multiAccountBases: Set<String> = []
func pName(_ p: String) -> String {
    let parts = p.split(separator: "#", maxSplits: 1).map(String.init)
    let base = parts[0] == "bilinmiyor" ? L("Unknown", "Bilinmiyor") : (PROVIDER_NAME[parts[0]] ?? parts[0])
    return parts.count > 1 && multiAccountBases.contains(parts[0]) ? "\(base) · \(parts[1])" : base
}
func credKind(_ source: String?) -> String {
    guard let s = source else { return "" }
    if s.hasPrefix("env:") { return L("env variable", "ortam değişkeni") }
    if s == "claude_code" { return L("Claude Code login", "Claude Code girişi") }
    if s == "gh_cli" { return "GitHub CLI" }
    return s
}
func plural(_ n: Int, _ one: String, _ many: String, tr: String) -> String { isTR() ? "\(n) \(tr)" : "\(n) \(n == 1 ? one : many)" }
func wName(_ w: String) -> String { WINDOW_NAME[w].map { L($0.0, $0.1) } ?? w }

/// Legend scale limited to the sources actually present (so absent CLIs don't clutter the legend).
func sourceScale(_ present: Set<String>) -> (domain: [String], range: [Color]) {
    let keys = SOURCE_COLOR.keys.filter { present.contains($0) }.sorted()
    return (keys, keys.map { SOURCE_COLOR[$0]! })
}

let KANBAN_ORDER = ["running", "review", "blocked", "ready", "scheduled", "todo", "triage", "done"]
let KANBAN_NAME: [String: (String, String)] = [
    "running": ("Running", "Çalışıyor"), "blocked": ("Blocked", "Bloklu"), "ready": ("Ready", "Hazır"),
    "todo": ("To do", "Yapılacak"), "triage": ("Triage", "Triaj"), "done": ("Done", "Bitti"), "archived": ("Archived", "Arşiv"),
    "review": ("In review", "İncelemede"), "scheduled": ("Scheduled", "Zamanlandı"),
]
func kName(_ k: String) -> String? { KANBAN_NAME[k].map { L($0.0, $0.1) } }

func compact(_ v: Double?) -> String {
    let n = v ?? 0
    switch n {
    case 1_000_000...: return String(format: "%.1fM", n / 1_000_000)
    case 10_000...: return String(format: "%.0fK", n / 1_000)
    case 1_000...: return String(format: "%.1fK", n / 1_000)
    default: return String(format: "%.0f", n)
    }
}

func money(_ v: Double?) -> String { String(format: "$%.2f", v ?? 0) }

/// "claude-opus-5-5" -> "Opus 5.5", "claude-sonnet-5-5" -> "Sonnet", a bare id -> its last path segment.
func modelShort(_ m: String?) -> String? {
    guard let m, !m.isEmpty else { return nil }
    let lower = m.lowercased()
    for (needle, name) in [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"), ("fable", "Fable")] {
        if lower.contains(needle) {
            let ver = m.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .drop { !$0.lowercased().contains(needle) }.dropFirst()
                .prefix { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            return ver.isEmpty ? name : "\(name) \(ver)"
        }
    }
    return m.split(separator: "/").last.map(String.init) ?? m
}

/// Column colour for a kanban chip on a session row.
func kanbanColor(_ status: String?) -> Color {
    switch status {
    case "running": return .green
    case "blocked": return .red
    case "review": return .purple
    case "ready": return .cyan
    case "todo", "triage": return .orange
    default: return .secondary
    }
}

func span(_ sec: Double) -> String {
    let s = max(0, Int(sec))
    if isTR() {
        if s < 60 { return "\(s) sn" }
        if s < 3600 { return "\(s / 60) dk" }
        if s < 86400 { return "\(s / 3600)s \(s % 3600 / 60)dk" }
        return "\(s / 86400)g \(s % 86400 / 3600)s"
    }
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
    return "\(s / 86400)d \(s % 86400 / 3600)h"
}

/// "in 25d 3h · 24 Oct 14:33" / "25g 3s sonra · 24 Eki 14:33" (or "… ago" / "… önce" for past moments).
func when(_ ts: Double, now: Double = Date().timeIntervalSince1970) -> String {
    let f = DateFormatter()
    f.locale = appLocale()
    f.dateFormat = abs(ts - now) > 300 * 86400 ? "d MMM yyyy" : "d MMM HH:mm"
    let rel = ts >= now ? L("in \(span(ts - now))", "\(span(ts - now)) sonra") : L("\(span(now - ts)) ago", "\(span(now - ts)) önce")
    return "\(rel) · \(f.string(from: Date(timeIntervalSince1970: ts)))"
}

func modelStatus(_ s: String) -> (String, Color)? {
    switch s {
    case "failing": return (L("failing", "hata veriyor"), .red)
    case "account_exhausted": return (L("account limit", "hesap limiti"), .red)
    case "cooldown": return (L("cooling down", "beklemede"), .orange)
    case "degraded": return (L("degraded", "sorunlu"), .orange)
    case "ok": return (L("healthy", "sağlıklı"), .green)
    case "idle": return (L("idle", "boşta"), .secondary)
    default: return nil
    }
}

func levelColor(_ used: Double) -> Color { used >= 85 ? .red : used >= 60 ? .orange : .green }

func isoDay(_ offset: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
}

func dayDate(_ s: String) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s) ?? Date()
}

func openPanel() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [LAUNCHER]
    var env = ProcessInfo.processInfo.environment
    env["AGENT_MONITOR_PORT"] = String(SERVER_PORT)
    p.environment = env
    try? p.run()
}

/// Start only the panel server in the background (no browser window), the same way launch.sh does.
func startServer() {
    let dir = NSHomeDirectory() + "/agent-monitor"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "nohup '\(dir)/run.sh' >'\(dir)/panel.log' 2>&1 &"]
    try? p.run()
}

/// Provider logo from the bundle (Simple Icons SVGs, drawn as template shapes).
let PROVIDER_ICON = ["anthropic": "claude", "copilot": "githubcopilot", "openai-codex": "openai", "openai": "openai",
                     "gemini": "googlegemini", "nvidia": "nvidia", "openrouter": "openrouter"]
var iconCache: [String: NSImage] = [:]

func providerIcon(_ provider: String) -> NSImage? {
    guard let name = PROVIDER_ICON[pBase(provider)] else { return nil }
    if let hit = iconCache[name] { return hit }
    guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "icons"),
          let img = NSImage(contentsOf: url) else { return nil }
    iconCache[name] = img
    return img
}

/// One segment of the bar: optional icon + text (e.g. Claude logo + "49%"). Quota segments also carry ring
/// gauges (outer ring = first window), how much of the text is revealed (0 = collapsed) and a flash level.
struct BarPiece {
    let icon: NSImage?
    let text: String
    var rings: [Double] = []
    var reveal: CGFloat = 1
    var flash: CGFloat = 0
}

/// The whole menu bar label drawn as one template image, so several icon + value groups sit side by side
/// and follow the bar's light/dark tint (MenuBarExtra labels only render a single image/text reliably).
func barImage(spark: [Double]?, pieces: [BarPiece]) -> NSImage {
    let h: CGFloat = 18, icon: CGFloat = 13, gauge: CGFloat = 18, gap: CGFloat = 3, group: CGFloat = 8, sparkW: CGFloat = 30
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                .foregroundColor: NSColor.black]
    func head(_ p: BarPiece) -> CGFloat { p.rings.isEmpty ? (p.icon == nil ? 0 : icon) : gauge }
    func textW(_ p: BarPiece) -> CGFloat { ceil((p.text as NSString).size(withAttributes: attrs).width) * p.reveal }
    func gapW(_ p: BarPiece) -> CGFloat { head(p) > 0 && !p.text.isEmpty ? gap * p.reveal : 0 }
    var w: CGFloat = 0
    if spark != nil { w += sparkW }
    for p in pieces {
        if w > 0 { w += group }
        w += head(p) + gapW(p) + textW(p)
    }
    let img = NSImage(size: NSSize(width: ceil(max(w, 1)), height: h), flipped: false) { _ in
        var x: CGFloat = 0
        if let values = spark {
            let top = max(values.max() ?? 0, 1)
            let bw = sparkW / CGFloat(max(values.count, 1))
            NSColor.black.setFill()
            for (i, v) in values.enumerated() {
                let bh = max(1, CGFloat(v / top) * (h - 4))
                NSBezierPath(rect: NSRect(x: CGFloat(i) * bw, y: 2, width: max(bw - 0.6, 0.5), height: bh)).fill()
            }
            x += sparkW
        }
        for p in pieces {
            if x > 0 { x += group }
            if !p.rings.isEmpty {
                let c = NSPoint(x: x + gauge / 2, y: h / 2)
                let rings = Array(p.rings.prefix(2))
                for (i, frac) in rings.enumerated() {
                    let r: CGFloat = i == 0 ? 8.1 : 5.7
                    let lw: CGFloat = (i == 0 ? 1.6 : 1.4) + p.flash * 0.9
                    let track = NSBezierPath()
                    track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
                    track.lineWidth = lw
                    NSColor.black.withAlphaComponent(0.22 + 0.3 * p.flash).setStroke()
                    track.stroke()
                    let f = min(max(frac, 0), 1)
                    if f > 0 {
                        let arc = NSBezierPath()
                        arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * CGFloat(f), clockwise: true)
                        arc.lineWidth = lw
                        arc.lineCapStyle = .round
                        NSColor.black.setStroke()
                        arc.stroke()
                    }
                }
                if let ic = p.icon {
                    let s: CGFloat = rings.count > 1 ? 7 : 9.5
                    ic.draw(in: NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
                }
                x += gauge
            } else if let ic = p.icon {
                ic.draw(in: NSRect(x: x, y: (h - icon) / 2, width: icon, height: icon))
                x += icon
            }
            x += gapW(p)
            if p.reveal > 0.01 {
                let size = (p.text as NSString).size(withAttributes: attrs)
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: x, y: 0, width: textW(p), height: h).clip()
                var a = attrs
                a[.foregroundColor] = NSColor.black.withAlphaComponent(p.reveal)
                (p.text as NSString).draw(at: NSPoint(x: x, y: (h - size.height) / 2), withAttributes: a)
                NSGraphicsContext.restoreGraphicsState()
            }
            x += textW(p)
        }
        return true
    }
    img.isTemplate = true
    return img
}

// ---------- motion (menu bar + quota cards) ----------

func motionOn() -> Bool { Pref.on(Pref.barMotion) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

/// Running-session dot: a soft sonar ping while the popover is open.
/// Set in the notch: many rows of forever-pulsing dots there keep the main thread busy (~40 % CPU).
private struct CalmMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var calmMotion: Bool {
        get { self[CalmMotionKey.self] }
        set { self[CalmMotionKey.self] = newValue }
    }
}

struct PulseDot: View {
    let color: Color
    var animated = true   // false in the always-visible notch: a forever-animation there costs ~15 % CPU
    @Environment(\.calmMotion) private var calm
    @State private var ping = false
    var body: some View {
        ZStack {
            if motionOn() && animated && !calm {
                Circle().stroke(color.opacity(ping ? 0 : 0.7), lineWidth: 1.2)
                    .scaleEffect(ping ? 2.4 : 1)
            }
            Circle().fill(color)
        }
        .frame(width: 7, height: 7)
        .onAppear { start() }
        .onChange(of: animated) { _, on in if on { ping = false; start() } }
    }

    private func start() {
        guard motionOn(), animated, !calm else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { ping = true }
    }
}

/// Thin light sweep under the header while a sync is in flight.
struct ScanLine: View {
    let active: Bool
    @State private var phase: CGFloat = -0.3
    var body: some View {
        GeometryReader { geo in
            if active {
                LinearGradient(colors: [.clear, .accentColor.opacity(0.9), .cyan, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.3, height: 1.5)
                    .offset(x: geo.size.width * phase)
                    .onAppear {
                        phase = -0.3
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = 1.0 }
                    }
            }
        }
        .frame(height: 1.5)
        .clipped()
    }
}

/// Quota groups (one per provider) collapse to logo + ring gauge while their % is steady and pop open whenever
/// a window crosses a new 2 % step — with a short digit "decode" and a ring flash — then settle again.
/// They stay open while burning fast (≥ 10 %/h or filling before reset) or when critical (≥ 85 %).
/// Motion runs only during transitions (≈1 s) and honours "Reduce motion".
@MainActor
final class BarAnimator: ObservableObject {
    static var step: Double { max(0.5, Pref.num(Pref.stepPct)) }
    static var hold: TimeInterval { max(3, Pref.num(Pref.holdSec)) }
    static let fastPerHour = 10.0, critical = 85.0
    static let decode: TimeInterval = 0.8, revealTime: TimeInterval = 0.3, flashTime: TimeInterval = 1.0

    struct Win { var step: Int; var from: Double; var to: Double; var changedAt: Date? }
    struct Group { var reveal: Double; var openUntil: Date; var sticky = false; var flashAt: Date? }

    private var wins: [String: Win] = [:]
    private var groups: [String: Group] = [:]
    /// Called when a window crosses into a new 2 % step (not on first sight).
    var onStep: ((_ key: String, _ provider: String, _ window: QuotaWindow) -> Void)?
    @Published private(set) var tick = 0
    private var timer: Timer?
    private var wake: Timer?
    private var lastStep = Date()

    var motion: Bool { Pref.on(Pref.barMotion) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var autoCollapse: Bool { Pref.on(Pref.barAutoCollapse) }

    /// Feed every quota window on each live refresh.
    func ingest(_ options: [(key: String, provider: String, window: QuotaWindow)], burn: [Burn]) {
        let now = Date()
        var sticky: [String: Bool] = [:]
        for o in options {
            let used = o.window.used ?? 0
            let st = Int(used / Self.step)
            if var w = wins[o.key] {
                if st != w.step {
                    w.from = displayed(o.key, at: now)
                    w.to = used
                    w.step = st
                    w.changedAt = now
                    open(o.provider, flash: true, at: now)
                    onStep?(o.key, o.provider, o.window)
                } else {
                    w.to = used  // moves inside the same 2 % step are shown without fanfare
                }
                wins[o.key] = w
            } else {
                wins[o.key] = Win(step: st, from: used, to: used, changedAt: nil)
                open(o.provider, flash: false, at: now)  // first sight: show the values once, then settle
            }
            let b = burn.first { $0.provider == o.provider && $0.window == o.window.label }
            let fillsFirst = b?.etaFull.map { $0 < (o.window.reset ?? .infinity) } ?? false
            let fast = (b?.perHour ?? 0) >= Self.fastPerHour || fillsFirst
            sticky[o.provider] = (sticky[o.provider] ?? false) || (used < 100 && (fast || used >= Self.critical))
        }
        for (p, v) in sticky { groups[p]?.sticky = v }
        kick()
    }

    func isOpen(_ provider: String, at d: Date = Date()) -> Bool {
        guard autoCollapse, let g = groups[provider] else { return true }
        return g.sticky || d < g.openUntil
    }

    func reveal(_ provider: String) -> CGFloat { autoCollapse ? CGFloat(groups[provider]?.reveal ?? 1) : 1 }

    func flash(_ provider: String, at d: Date = Date()) -> CGFloat {
        guard motion, let f = groups[provider]?.flashAt else { return 0 }
        let t = d.timeIntervalSince(f) / Self.flashTime
        return t < 1 ? CGFloat(sin(t * .pi)) : 0
    }

    /// The value on screen: eases from the previous to the new % during a change.
    func displayed(_ key: String, at d: Date = Date()) -> Double {
        guard let w = wins[key] else { return 0 }
        guard motion, let c = w.changedAt else { return w.to }
        let t = min(1, d.timeIntervalSince(c) / Self.decode)
        return w.from + (w.to - w.from) * (1 - pow(1 - t, 3))
    }

    /// "49%" — during a change the digits scramble and lock in left to right.
    func text(_ key: String, value: Int, at d: Date = Date()) -> String {
        let s = "\(value)%"
        guard motion, let c = wins[key]?.changedAt else { return s }
        let t = d.timeIntervalSince(c) / Self.decode
        guard t < 1 else { return s }
        let chars = Array(s)
        return String(chars.enumerated().map { i, ch in
            ch.isNumber && t < 0.3 + 0.6 * Double(i) / Double(max(chars.count - 1, 1))
                ? Character(String(Int.random(in: 0...9))) : ch
        })
    }

    private func open(_ provider: String, flash: Bool, at d: Date) {
        var g = groups[provider] ?? Group(reveal: 0, openUntil: d)
        g.openUntil = d.addingTimeInterval(Self.hold)
        if flash { g.flashAt = d }
        groups[provider] = g
    }

    private func kick() {
        lastStep = Date()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.advance() }
            }
        }
        advance()
    }

    /// One frame; the timer stops as soon as nothing is moving, and a one-shot wake-up is set for the
    /// next hold expiry so a group collapses right on time.
    private func advance() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastStep), 0.1)
        lastStep = now
        var active = false
        for (p, var g) in groups {
            let target: Double = isOpen(p, at: now) ? 1 : 0
            if g.reveal != target {
                if motion {
                    let delta = dt / Self.revealTime
                    g.reveal = target > g.reveal ? min(target, g.reveal + delta) : max(target, g.reveal - delta)
                } else {
                    g.reveal = target
                }
                active = active || g.reveal != target
            }
            if motion, let f = g.flashAt, now.timeIntervalSince(f) < Self.flashTime { active = true }
            groups[p] = g
        }
        if motion { for w in wins.values where w.changedAt.map({ now.timeIntervalSince($0) < Self.decode }) ?? false { active = true } }
        tick &+= 1
        if !active {
            timer?.invalidate()
            timer = nil
            scheduleWake(now)
        }
    }

    private func scheduleWake(_ now: Date) {
        wake?.invalidate()
        wake = nil
        guard autoCollapse, let next = groups.values.filter({ !$0.sticky && $0.openUntil > now }).map(\.openUntil).min() else { return }
        wake = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(now) + 0.05, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.kick() }
        }
    }
}

// ---------- opening things (one rule for every row, notification and island event) ----------

let OPEN_SCHEMES: Set<String> = ["hermes", "http", "https"]

extension OpenAction {
    /// Notification payload (property-list types only).
    var userInfo: [String: String] {
        ["kind": kind, "url": url ?? "", "command": command ?? "", "label": label ?? "", "cardId": cardId ?? "",
         "sessionCommand": sessionCommand ?? "", "sessionUrl": sessionUrl ?? "", "running": running == true ? "1" : "",
         "pid": pid.map(String.init) ?? "", "tty": tty ?? "", "app": app ?? "", "appPid": appPid.map(String.init) ?? "",
         "background": background == true ? "1" : "", "attach": attach ?? ""]
    }
    init?(userInfo i: [AnyHashable: Any]) {
        guard let kind = i["kind"] as? String, !kind.isEmpty else { return nil }
        func opt(_ k: String) -> String? { (i[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        self.init(kind: kind, url: opt("url"), command: opt("command"), label: opt("label"), cardId: opt("cardId"), sessionCommand: opt("sessionCommand"))
        sessionUrl = opt("sessionUrl")
        running = opt("running") == "1" ? true : nil
        pid = opt("pid").flatMap { Int($0) }
        tty = opt("tty")
        app = opt("app")
        appPid = opt("appPid").flatMap { Int($0) }
        background = opt("background") == "1" ? true : nil
        attach = opt("attach")
    }

    /// What a click does (the one decision; see `Opener.plan`).
    var step: OpenStep { Opener.plan(self) }
    /// Row glyph that says what the click does.
    var icon: String {
        switch step {
        case .url, .board: return "arrow.up.forward.square"
        case .focus: return "macwindow"
        case .terminal: return "terminal"
        case .copy, .nothing: return "doc.on.doc"
        }
    }
    var clickHint: String {
        switch step {
        case .url: return L("Click to open", "Tıkla: aç")
        case .board: return L("Click: opens the Hermes board and copies the card command (Hermes has no per-card link)",
                              "Tıkla: Hermes panosunu açar, kart komutunu kopyalar (Hermes'te karta özel bağlantı yok)")
        case .focus: return L("Click to bring its window to the front", "Tıkla: penceresini öne getir")
        case .terminal(_, let attach):
            return attach ? L("Click to show it in a new Terminal window", "Tıkla: yeni Terminal penceresinde göster")
                          : L("Click to resume it in a new Terminal window", "Tıkla: yeni Terminal penceresinde devam ettir")
        case .copy(_, let running):
            return running ? L("Click to copy the command (it is running elsewhere: not resumed twice)", "Tıkla: komutu kopyala (başka yerde çalışıyor: ikinci kez devam ettirilmez)")
                           : L("Click to copy the resume command", "Tıkla: devam komutunu kopyala")
        case .nothing: return ""
        }
    }
}

/// What a click on a session / card does. Decided by `Opener.plan` (pure), carried out by `Opener.open`.
enum OpenStep: Equatable {
    case nothing
    case board(url: URL, copy: String?)                    // kanban card: Hermes has no card route → board + card command
    case url(URL)                                          // hermes://open/<session>, http(s)
    case focus(tty: String, app: String?, appPid: Int?)    // a terminal tab / app window already holds the session
    case terminal(command: String, attach: Bool)           // new Terminal window: `claude attach` or a resume
    case copy(String, running: Bool)                       // fall back: copy the command (running: why it is not run)

    var copies: Bool { if case .copy = self { return true }; return false }
}

@MainActor
enum Opener {
    enum Source { case row, notification }

    // ---- the decision (pure, unit-testable) ----

    nonisolated static func systemHandles(_ url: URL) -> Bool { NSWorkspace.shared.urlForApplication(toOpen: url) != nil }

    nonisolated static func validURL(_ s: String?) -> URL? {
        s.flatMap(URL.init(string:)).flatMap { OPEN_SCHEMES.contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
    }

    nonisolated static func validTTY(_ t: String) -> Bool { t.range(of: #"^ttys\d{1,4}$"#, options: .regularExpression) != nil }

    /// Only these shapes are ever run in a Terminal window (the text comes from session data): a resume or attach of
    /// one session, optionally after `cd <project>`. Anything else is copied, never run.
    nonisolated static func runnable(_ c: String) -> Bool {
        let tok = #"'?[A-Za-z0-9_.:-]+'?"#
        let path = #"(?:'[^'\n]+'|[A-Za-z0-9_./@+-]+)"#
        let shapes = [#"^(?:cd \#(path) && )?claude (?:--resume|attach) \#(tok)$"#,
                      #"^hermes(?: -p \#(tok))? --resume \#(tok)$"#]
        return !c.contains("\n") && shapes.contains { c.range(of: $0, options: .regularExpression) != nil }
    }

    /// Order of preference — and why:
    ///  1. a terminal tab / app window already holds the live session → bring it to the front (never start a second
    ///     process on a session that is running: two writers on one transcript);
    ///  2. a URL the system can handle (hermes://open/<id> opens any Hermes session in Hermes.app, tried for real);
    ///  3. a background Claude Code session (no window): `claude attach` in a new Terminal window (does not start a
    ///     second process — the session keeps running);
    ///  4. running somewhere we cannot reach → copy the command and say why;
    ///  5. not running: resume in a new Terminal window (Hermes / Claude Code); Copilot CLI keeps copying.
    nonisolated static func plan(_ a: OpenAction?, handles: (URL) -> Bool = Opener.systemHandles) -> OpenStep {
        guard let a, a.canOpen else { return .nothing }
        let isCard = a.kind == "kanban-card"
        if isCard && a.sessionCommand == nil {  // a card without a worker session: the board is all Hermes can show
            if let u = validURL(a.url), handles(u) { return .board(url: u, copy: a.command) }
            return a.command.map { .copy($0, running: false) } ?? .nothing
        }
        let resume = isCard ? a.sessionCommand : a.command
        if a.running == true, a.background != true, let tty = a.tty, validTTY(tty) {
            return .focus(tty: tty, app: a.app, appPid: a.appPid)
        }
        if let u = validURL(isCard ? a.sessionUrl : a.url), handles(u) { return .url(u) }
        if a.running == true, let at = a.attach, runnable(at) { return .terminal(command: at, attach: true) }
        guard let cmd = resume ?? a.attach else { return .nothing }
        if a.running == true { return .copy(cmd, running: true) }
        if a.kind != "copilot-cli", runnable(cmd) { return .terminal(command: cmd, attach: false) }
        return .copy(cmd, running: false)
    }

    // ---- carrying it out ----

    static func open(_ a: OpenAction?, source: Source = .row) {
        let name = a?.label ?? a?.cardId ?? ""
        switch plan(a) {
        case .nothing:
            say(L("Nothing to open for this row", "Bu satır için açılacak bir yer yok"), source)
        case .board(let url, let cmd):
            let copied = cmd.map(copy) ?? false
            NSWorkspace.shared.open(url)
            say(L("No per-card link in Hermes: board opened", "Karta özel bağlantı yok: Hermes panosu açıldı")
                + (copied ? L(", card command copied: \(cmd ?? "")", ", kart komutu kopyalandı: \(cmd ?? "")") : ""), source)
        case .url(let url):
            NSWorkspace.shared.open(url)
            if a?.kind == "kanban-card", let id = a?.cardId {
                say(L("Opening the worker session of card \(id)", "\(id) kartının işçi oturumu açılıyor"), source)
            } else {
                say(L("Opening: \(name)", "Açılıyor: \(name)"), source)
            }
        case .focus(let tty, let app, let appPid):
            focus(tty: tty, app: app, appPid: appPid) { result in
                switch result {
                case .tab(let who): say(L("Brought to the front (\(who), \(tty)): \(name)", "Öne getirildi (\(who), \(tty)): \(name)"), source)
                case .appOnly(let who, let why):
                    say(L("\(who) brought forward, but its tab could not be picked (\(why)). Session: \(name)",
                          "\(who) öne getirildi ama sekme seçilemedi (\(why)). Oturum: \(name)"), source)
                case .failed:
                    let cmd = (a?.kind == "kanban-card" ? a?.sessionCommand : a?.command) ?? ""
                    if !cmd.isEmpty { copy(cmd) }
                    say(L("Could not find its window; it is running, so it is not resumed twice. Command copied: \(cmd)",
                          "Penceresi bulunamadı; çalışıyor, bu yüzden ikinci kez devam ettirilmedi. Komut kopyalandı: \(cmd)"), source)
                }
            }
        case .terminal(let cmd, let attach):
            runInTerminal(cmd) { ok in
                if ok {
                    say(attach ? L("Shown in a new Terminal window (the session keeps running): \(name)", "Yeni Terminal penceresinde gösterildi (oturum çalışmaya devam ediyor): \(name)")
                               : L("Resumed in a new Terminal window: \(name)", "Yeni Terminal penceresinde devam ettirildi: \(name)"), source)
                } else {
                    copy(cmd)
                    say(L("Could not open Terminal. Command copied: \(cmd)", "Terminal açılamadı. Komut kopyalandı: \(cmd)"), source)
                }
            }
        case .copy(let cmd, let running):
            copy(cmd)
            say(running ? L("Running in another process that cannot be brought forward — resuming would write to it twice. Command copied: \(cmd)",
                            "Başka bir süreçte çalışıyor, öne getirilemedi — devam ettirmek iki süreci aynı oturuma yazdırır. Komut kopyalandı: \(cmd)")
                        : L("Command copied — run it in Terminal: \(cmd)", "Komut kopyalandı — Terminal'de çalıştır: \(cmd)"), source)
        }
    }

    enum FocusResult { case tab(String), appOnly(String, String), failed }

    /// Terminal / iTerm: select the tab whose tty it is (AppleScript through `osascript`, so a slow permission prompt
    /// never freezes the island). If macOS has not allowed Automation (or the tab is not found) the app is still
    /// brought forward. Any other host app (VS Code, Hermes…): the app is brought forward.
    static func focus(tty: String, app: String?, appPid: Int?, done: @escaping @MainActor (FocusResult) -> Void) {
        let apps = NSWorkspace.shared.runningApplications
        func running(_ id: String) -> NSRunningApplication? { apps.first { $0.bundleIdentifier == id } }
        let path = app ?? ""
        let kind: String? = path.hasSuffix("/Terminal.app") ? "terminal" : path.contains("iTerm") ? "iterm"
            : path.isEmpty ? (running("com.googlecode.iterm2") != nil ? "iterm" : running("com.apple.Terminal") != nil ? "terminal" : nil) : nil
        guard let kind else {
            // some other app hosts the terminal: bring it forward
            if let p = appPid, let r = NSRunningApplication(processIdentifier: pid_t(p)) {
                r.activate()
                if !path.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                done(.appOnly(r.localizedName ?? "App", L("the app has its own tabs", "uygulamanın kendi sekmeleri var")))
            } else { done(.failed) }
            return
        }
        let name = kind == "iterm" ? "iTerm" : "Terminal"
        let bundlePath = kind == "iterm" ? (path.isEmpty ? "/Applications/iTerm.app" : path) : "/System/Applications/Utilities/Terminal.app"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = selectTab(kind: kind, tty: tty)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch r {
                    case .found: done(.tab(name))
                    case .notFound, .denied, .error:
                        NSWorkspace.shared.open(URL(fileURLWithPath: bundlePath))
                        let why: String
                        if case .denied = r { why = L("allow Agent Bar to control \(name): System Settings → Privacy & Security → Automation", "Agent Bar'a \(name) denetimi izni ver: Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon") }
                        else if case .notFound = r { why = L("no tab with that tty", "bu tty'li sekme yok") }
                        else { why = L("script error", "betik hatası") }
                        done(.appOnly(name, why))
                    }
                }
            }
        }
    }

    enum TabResult { case found, notFound, denied, error }

    nonisolated static func selectTab(kind: String, tty: String) -> TabResult {
        let dev = "/dev/" + tty
        let script: String
        if kind == "iterm" {
            script = """
            on run argv
              set dev to item 1 of argv
              tell application "iTerm"
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if tty of s is dev then
                        select w
                        select t
                        select s
                        activate
                        return "ok"
                      end if
                    end repeat
                  end repeat
                end repeat
              end tell
              return "none"
            end run
            """
        } else {
            script = """
            on run argv
              set dev to item 1 of argv
              tell application "Terminal"
                repeat with w in windows
                  repeat with t in tabs of w
                    if tty of t is dev then
                      set selected tab of w to t
                      set index of w to 1
                      activate
                      return "ok"
                    end if
                  end repeat
                end repeat
              end tell
              return "none"
            end run
            """
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script, dev]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .error }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)  // a permission prompt may wait for the user
        p.waitUntilExit()
        killer.cancel()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if e.contains("-1743") { return .denied }
        if p.terminationStatus != 0 { return .error }
        return o.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" ? .found : .notFound
    }

    /// A new Terminal window that runs `command` (a temporary .command file; Terminal runs it, no Automation permission
    /// needed). Only commands accepted by `runnable` get here.
    static func runInTerminal(_ command: String, done: @escaping @MainActor (Bool) -> Void) {
        guard runnable(command) else { done(false); return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-bar-open", isDirectory: true)
        let file = dir.appendingPathComponent("open-\(UUID().uuidString.prefix(8)).command")
        let body = "#!/bin/zsh -il\nrm -f -- \"$0\"\nexport PATH=\"$HOME/.local/bin:$HOME/.hermes/hermes-agent/.hermes/bin:$PATH\"\nclear\n\(command)\n"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch { done(false); return }
        NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration()) { _, err in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(err == nil) } }
        }
    }

    @discardableResult
    static func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    /// Visible feedback: a toast in the open panel / notch list; a banner when the click came from a notification
    /// (nothing else is on screen then).
    private static func say(_ text: String, _ source: Source) {
        Store.main.showToast(text)
        if source == .notification { Notifier.local(L("Agent Monitor", "Agent Monitor"), text) }
    }
}

/// Click opens the row's `open` action; rows without one stay inert (no pointer, no button trait).
struct OpenableModifier: ViewModifier {
    let action: OpenAction?
    func body(content: Content) -> some View {
        if let a = action, a.canOpen {
            content
                .contentShape(Rectangle())
                .onTapGesture { Opener.open(a) }
                .modifier(LinkCursor())
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(a.clickHint)
        } else {
            content
        }
    }
}
struct LinkCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.pointerStyle(.link) } else { content }
    }
}
extension View {
    func openable(_ a: OpenAction?) -> some View { modifier(OpenableModifier(action: a)) }
}

// ---------- settings ----------

enum Pref {
    static let barSpark = "barSpark"        // token sparkline
    static let barCount = "barCount"        // running session count
    static let barTokens = "barTokens"      // tokens in the last minute
    static let barLeft = "barLeft"          // show % left instead of % used
    static let barQuotas = "barQuotas"      // comma-joined "provider|window" keys; "auto" = tightest usable
    static let barAutoCollapse = "barAutoCollapse"  // steady quotas collapse to logo + ring
    static let barMotion = "barMotion"      // transition animations (also off with Reduce motion)
    static let notifyQuota = "notifyQuota"
    static let notifyKanban = "notifyKanban"
    static let notifySessions = "notifySessions"
    static let autoStart = "autoStartServer"
    static let notifyHealth = "notifyHealth"
    static let notifyAgents = "notifyAgents"    // finished / needs approval / stalled / loop / big context
    static let budgetDay = "budgetDay"      // USD, 0 = off
    static let budgetMonth = "budgetMonth"  // USD, 0 = off
    static let notifyBudget = "notifyBudget"
    static let lang = "lang"                // en | tr
    static let display = "display"          // both | island | menubar  (notch island and/or menu bar icon)
    static let islandEvents = "islandEvents"  // pop quota steps / alerts out of the notch
    static let islandEars = "islandEars"    // hover (default: notch stays plain until hovered) | always
    static let stepPct = "stepPct"          // a quota "moves" every N % (reopens / peeks)
    static let holdSec = "holdSec"          // how long a moved quota stays open in the menu bar
    static let peekSec = "peekSec"          // how long the notch ears peek after a change
    static let eventSec = "eventSec"        // how long an alert stays popped out of the notch
    static let hoverDelay = "hoverDelay"    // dwell before the notch opens on hover
    static let earWidth = "earWidth"        // width of each ear beside the notch
    static let rightEar = "rightEar"        // sessions | tokens | cost | none
    static let islandClick = "islandClick"  // what the hover panel's window icon opens: panel | web (the notch itself opens nothing)
    static let hoverQuotas = "hoverQuotas"
    static let hoverSessions = "hoverSessions"
    static let hoverCost = "hoverCost"
    static let liveEvery = "liveEvery"      // live refresh interval (s)
    /// One-time copy of the settings from the app's former identity (Hermes Bar, local.hermes.bar).
    static func migrateFromHermesBar() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromHermesBar"), let old = UserDefaults(suiteName: "local.hermes.bar") else { return }
        let keys = [barSpark, barCount, barTokens, barLeft, barQuotas, barAutoCollapse, barMotion, notifyQuota, notifyKanban,
                    notifySessions, autoStart, notifyHealth, budgetDay, budgetMonth, notifyBudget, lang, display, islandEvents,
                    islandEars, stepPct, holdSec, peekSec, eventSec, hoverDelay, earWidth, rightEar, islandClick,
                    hoverQuotas, hoverSessions, hoverCost, liveEvery, "tab", "healthView", "usageMetric", "topRange", "quotaNotified", "budgetNotified", "quotaSoonNotified"]
        for k in keys where d.object(forKey: k) == nil {
            if let v = old.object(forKey: k) { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "migratedFromHermesBar")
    }

    /// Every user-facing setting (language excluded: resetting it would flip the whole UI to English).
    static var resettable: [String] {
        [barSpark, barCount, barTokens, barLeft, barQuotas, barAutoCollapse, barMotion, notifyQuota, notifyKanban,
         notifySessions, autoStart, notifyHealth, budgetDay, budgetMonth, notifyBudget, display, islandEvents, islandEars,
         stepPct, holdSec, peekSec, eventSec, hoverDelay, earWidth, rightEar, islandClick, hoverQuotas, hoverSessions,
         hoverCost, liveEvery]
    }

    /// Back to the registered defaults (the removed keys fall through to them).
    static func restoreDefaults() {
        resettable.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    static func register() {
        migrateFromHermesBar()
        UserDefaults.standard.register(defaults: [barSpark: true, barCount: true, barTokens: false, barLeft: false,
                                                  barQuotas: "auto", barAutoCollapse: true, barMotion: true, notifyQuota: true, notifyKanban: true,
                                                  notifySessions: false, autoStart: true, notifyHealth: true, notifyAgents: true,
                                                  budgetDay: 0.0, budgetMonth: 0.0, notifyBudget: true, lang: "en",
                                                  display: "both", islandEvents: true,
                                                  islandEars: "hover", stepPct: 2.0, holdSec: 20.0, peekSec: 15.0, eventSec: 4.5,
                                                  hoverDelay: 0.22, earWidth: 64.0, rightEar: "sessions", islandClick: "panel",
                                                  hoverQuotas: true, hoverSessions: true, hoverCost: true, liveEvery: LIVE_EVERY])
    }
    static func on(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func num(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
    static func str(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
}

// ---------- notifications ----------

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var cardsSeen: Set<String>?
    private var mainsSeen: [String: String]?

    override init() {
        super.init()
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    /// A click on a notification opens what it is about (the session / card), via the same `open` rule as a row click.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let action = OpenAction(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in Opener.open(action, source: .notification) }
        done()
    }

    /// Plain banner without an open target (feedback such as "command copied").
    nonisolated static func local(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func post(_ title: String, _ body: String, open: OpenAction? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let open, open.canOpen { c.userInfo = open.userInfo }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        Island.shared.push(IslandEvent(provider: nil, symbol: "bell.badge.fill", title: title, detail: body, tint: .orange, gauge: nil, open: open))
    }

    /// Once per quota window period and threshold (80 %, 95 %); remembered across restarts.
    func quotas(_ q: Quotas?) {
        guard Pref.on(Pref.notifyQuota) else { return }
        var sent = UserDefaults.standard.dictionary(forKey: "quotaNotified") as? [String: Int] ?? [:]
        for item in q?.items ?? [] {
            for w in item.windows ?? [] {
                guard let used = w.used else { continue }
                let level = used >= 95 ? 95 : used >= 80 ? 80 : 0
                let key = "\(item.provider)|\(w.label)|\(Int((w.reset ?? 0) / 3600))"
                if level > (sent[key] ?? 0) {
                    sent[key] = level
                    post(L("Quota at \(Int(used))%", "Kota %\(Int(used)) doldu"), "\(pName(item.provider)) · \(wName(w.label))"
                         + (w.reset.map { L(" — resets in \(span($0 - Date().timeIntervalSince1970))", " — sıfırlanma \(span($0 - Date().timeIntervalSince1970)) sonra") } ?? ""))
                }
            }
        }
        UserDefaults.standard.set(sent, forKey: "quotaNotified")
    }

    /// Cards that become blocked or start failing (the first load only seeds the seen set).
    func kanban(_ boards: [Board]) {
        var now = Set<String>()
        var fresh: [(Board, Card, String)] = []
        for b in boards {
            for c in b.cards {
                let fails = Int(c.consecutiveFailures ?? 0)
                let needsInput = c.status == "blocked" && c.blockKind == "needs_input"
                let key: String? = needsInput ? "\(c.id)|input" : c.status == "blocked" ? "\(c.id)|blocked" : c.status == "review" ? "\(c.id)|review" : fails > 0 ? "\(c.id)|fail\(fails)" : nil
                guard let key else { continue }
                now.insert(key)
                let what = needsInput ? L("needs your input", "girdi bekliyor") : c.status == "blocked" ? L("blocked", "bloklandı")
                    : c.status == "review" ? L("is waiting for review", "inceleme bekliyor") : L("failing", "hata verdi")
                if let seen = cardsSeen, !seen.contains(key) { fresh.append((b, c, what)) }
            }
        }
        cardsSeen = now
        guard Pref.on(Pref.notifyKanban) else { return }
        for (b, c, what) in fresh.prefix(5) {
            post(L("Kanban: card \(what)", "Kanban: kart \(what)"), "\(c.title ?? c.id)\n\(b.board) · \(c.assignee ?? L("unassigned", "atanmamış"))", open: c.open)
        }
    }

    /// Budget thresholds (80 %, 100 %) once per day / month; remembered across restarts.
    func budget(today: Double, month: Double) {
        guard Pref.on(Pref.notifyBudget) else { return }
        let d = UserDefaults.standard
        var sent = d.dictionary(forKey: "budgetNotified") as? [String: Int] ?? [:]
        let checks: [(String, Double, Double, String)] = [
            ("day|\(isoDay(0))", today, d.double(forKey: Pref.budgetDay), L("Daily", "Günlük")),
            ("month|\(isoDay(0).prefix(7))", month, d.double(forKey: Pref.budgetMonth), L("Monthly", "Aylık")),
        ]
        for (key, spent, limit, name) in checks where limit > 0 {
            let pct = spent / limit * 100
            let level = pct >= 100 ? 100 : pct >= 80 ? 80 : 0
            if level > (sent[key] ?? 0) {
                sent[key] = level
                post(L("\(name) budget at \(Int(pct))%", "\(name) bütçe %\(Int(pct))"), "\(money(spent)) / \(money(limit))")
            }
        }
        d.set(sent, forKey: "budgetNotified")
    }

    /// Several accounts of one provider ("anthropic#a", "anthropic#b"): when one account's window passes 90 %
    /// and another usable account still has room, say so once per window period.
    func accountHint(_ q: Quotas?) {
        guard Pref.on(Pref.notifyQuota) else { return }
        let items = (q?.items ?? []).filter { $0.provider.contains("#") }
        guard items.count > 1 else { return }
        var sent = UserDefaults.standard.dictionary(forKey: "accountHintNotified") as? [String: Bool] ?? [:]
        func usable(_ i: QuotaItem) -> Bool { (i.accounts ?? []).allSatisfy { $0.status != "exhausted" } }
        func minLeft(_ i: QuotaItem) -> Double { (i.windows ?? []).compactMap(\.used).map { 100 - $0 }.min() ?? 100 }
        for item in items {
            for w in item.windows ?? [] where (w.used ?? 0) >= 90 {
                let others = items.filter { $0.provider != item.provider && pBase($0.provider) == pBase(item.provider) && usable($0) }
                guard let best = others.max(by: { minLeft($0) < minLeft($1) }), minLeft(best) >= 20 else { continue }
                let key = "\(item.provider)|\(w.label)|\(Int((w.reset ?? 0) / 3600))"
                guard sent[key] == nil else { continue }
                sent[key] = true
                let acct = { (p: String) in String(p.split(separator: "#").last ?? "") }
                post(L("\(acct(item.provider)) is at \(Int(w.used ?? 0))% · \(acct(best.provider)) has room",
                       "\(acct(item.provider)) %\(Int(w.used ?? 0)) doldu · \(acct(best.provider)) hesabında yer var"),
                     "\(pName(pBase(item.provider))) · \(wName(w.label)) — "
                     + L("\(Int(minLeft(best)))% left on \(acct(best.provider))", "\(acct(best.provider)) hesabında %\(Int(minLeft(best))) kaldı"))
            }
        }
        UserDefaults.standard.set(sent, forKey: "accountHintNotified")
    }

    /// A quota window that, at the current burn rate, fills up within the hour and before it resets.
    func quotaSoon(_ q: Quotas?, burn: [Burn], now: Double) {
        guard Pref.on(Pref.notifyQuota) else { return }
        var sent = UserDefaults.standard.dictionary(forKey: "quotaSoonNotified") as? [String: Bool] ?? [:]
        for item in q?.items ?? [] {
            for w in item.windows ?? [] {
                guard let b = burn.first(where: { $0.provider == item.provider && $0.window == w.label }),
                      let eta = b.etaFull, eta < (w.reset ?? .infinity), eta - now < 3600, (w.used ?? 0) < 100 else { continue }
                let key = "\(item.provider)|\(w.label)|\(Int((w.reset ?? 0) / 3600))"
                if sent[key] == nil {
                    sent[key] = true
                    post(L("Quota filling up soon", "Kota yakında dolacak"), "\(pName(item.provider)) · \(wName(w.label))"
                         + L(" — at this rate full in ~\(span(eta - now))", " — bu hızla ~\(span(eta - now)) içinde dolar")
                         + (w.reset.map { L(", \(span($0 - eta)) before reset", ", sıfırlanmaya \(span($0 - eta)) kala") } ?? ""))
                }
            }
        }
        UserDefaults.standard.set(sent, forKey: "quotaSoonNotified")
    }

    private var healthSeen: Set<String>?

    /// A model that starts failing / hits its account limit, or a credential that gets locked.
    func health(_ h: HealthResp) {
        var now = Set<String>()
        var fresh: [(String, String)] = []
        for m in h.models where ["failing", "account_exhausted"].contains(m.status) {
            let key = "m|\(m.id)|\(m.status)"
            now.insert(key)
            if let seen = healthSeen, !seen.contains(key) {
                fresh.append(("Model \(modelStatus(m.status)?.0 ?? m.status): \(m.model)",
                              "\(pName(m.provider))" + (m.last_error?.summary.map { " — \($0)" } ?? "")))
            }
        }
        for a in h.accounts {
            for c in a.credentials where c.locked {
                let key = "a|\(a.provider)|\(c.label ?? "")"
                now.insert(key)
                if let seen = healthSeen, !seen.contains(key) {
                    fresh.append((L("Account limit reached: \(pName(a.provider))", "Hesap limiti doldu: \(pName(a.provider))"),
                                  "\(c.label ?? "")" + (c.exhausted_until.map { L(" — unlocks \(when($0))", " — açılış \(when($0))") } ?? "")))
                }
            }
        }
        healthSeen = now
        guard Pref.on(Pref.notifyHealth) else { return }
        for (t, b) in fresh.prefix(5) { post(t, b) }
    }

    private var agentState: [String: String] = [:]
    private var agentFlags: Set<String> = []

    /// Agent attention: a turn finished (island only), approval needed, stalled, a tool loop or a large context
    /// (notification + island). Transitions only; the first refresh just records the current states.
    func agents(_ running: [Session]) {
        let mains = running.filter { $0.isRunning && !$0.subagent }
        let seeded = !agentState.isEmpty || mains.isEmpty
        defer { agentState = Dictionary(mains.map { ($0.id, $0.state ?? "working") }, uniquingKeysWith: { a, _ in a }) }
        guard seeded, Pref.on(Pref.notifyAgents) else {
            agentFlags.formUnion(mains.flatMap { s in flags(s).map { "\(s.id)|\($0)" } })
            return
        }
        for s in mains {
            let title = s.title ?? L("(untitled)", "(başlıksız)")
            let who = s.groupName
            let before = agentState[s.id]
            if before != s.state {
                switch s.state {
                case "waiting" where before == "working" && s.attended:
                    Island.shared.push(IslandEvent(provider: nil, symbol: "checkmark.circle.fill",
                                                   title: L("\(who) finished — your turn", "\(who) bitirdi — sıra sende"),
                                                   detail: title, tint: .green, gauge: nil, open: s.open))
                case "needs_approval":
                    post(L("\(who) needs approval", "\(who) onay bekliyor"), title + (s.waitingDetail.map { " — \($0)" } ?? ""), open: s.open)
                case "stalled":
                    post(L("\(who) may be stuck", "\(who) takılmış olabilir"),
                         title + (s.longToolCall != nil
                              ? L(" — no progress for 30 min", " — 30 dakikadır ilerleme yok")
                              : L(" — no progress for 10 min", " — 10 dakikadır ilerleme yok")), open: s.open)
                default: break
                }
            }
            for f in flags(s) where !agentFlags.contains("\(s.id)|\(f)") {
                agentFlags.insert("\(s.id)|\(f)")
                if f == "loop" {
                    post(L("\(who): possible loop", "\(who): döngü olabilir"),
                         title + L(" — the same tool call \(s.loopMax ?? 0)× in a row", " — aynı araç çağrısı art arda \(s.loopMax ?? 0) kez"))
                } else if f == "context" {
                    post(L("\(who): large context", "\(who): bağlam çok büyük"),
                         title + L(" — \(compact(s.contextTokens)) tokens per turn; /compact or a new session is faster",
                                   " — tur başına \(compact(s.contextTokens)) token; /compact ya da yeni oturum daha hızlı olur"))
                }
            }
        }
    }

    private func flags(_ s: Session) -> [String] {
        var f: [String] = []
        if (s.loopMax ?? 0) >= 3 { f.append("loop") }
        if (s.contextTokens ?? 0) >= LARGE_CONTEXT { f.append("context") }
        return f
    }

    func sessions(_ running: [Session]) {
        // Sources listed while their lease / process is alive: when one disappears it really closed. The others
        // (telegram, slack, cron… and card-only rows) also drop out after 10 quiet minutes, which is not "ended".
        let leased: Set<String> = ["desktop", "cli", "tui", "kanban", "claude-code"]
        let mains = Dictionary(running.filter { $0.isRunning && !$0.subagent && $0.cardOnly != true && leased.contains($0.origin ?? "") }
                                .map { ($0.id, $0.title ?? L("(untitled)", "(başlıksız)")) },
                               uniquingKeysWith: { a, _ in a })
        if let prev = mainsSeen, Pref.on(Pref.notifySessions) {
            for (id, title) in prev where mains[id] == nil { post(L("Session ended", "Oturum bitti"), title) }
        }
        mainsSeen = mains
    }
}

// ---------- store ----------

@MainActor
final class Store: ObservableObject {
    static let main = Store()
    @Published var live: LiveData?
    @Published var overview: Overview?
    @Published var history: [QHist] = []
    @Published var health: HealthResp?
    @Published var month: Overview?
    @Published var topToday: [TopSession] = []
    @Published var topWeek: [TopSession] = []
    @Published var offline = false
    @Published var updated: Date?
    @Published var toast: String?
    private var toastToken = 0
    private let notifier = Notifier()
    let anim = BarAnimator()

    /// A short message shown at the bottom of the panel / notch list (click feedback).
    func showToast(_ text: String) {
        toast = text
        toastToken += 1
        let token = toastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.toastToken == token else { return }
            withAnimation { self.toast = nil }
        }
    }

    private var lastMainCount: Int?
    private var lastWorkingCount: Int?
    private var lastAttendedWorking: Int?
    private var lastSessionPeek = Date.distantPast
    private var lastWidgetReload = Date.distantPast

    /// Desktop widgets refresh on their own only every ~15 min: nudge them when something visible changed
    /// (at most once a minute, so macOS' refresh budget isn't wasted).
    func reloadWidgets() {
        guard Date().timeIntervalSince(lastWidgetReload) > 60 else { return }
        lastWidgetReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A quota picked for the bar crossed a 2 % step: the island shows its ears for a moment (no big pop-down).
    func quotaStepEvent(key: String, provider: String, window: QuotaWindow) {
        let selection = (UserDefaults.standard.string(forKey: Pref.barQuotas) ?? "auto").split(separator: ",").map(String.init)
        guard chosenQuotas(selection).contains(where: { $0.key == key }) else { return }
        Island.shared.peek(provider)
        reloadWidgets()
    }

    private var liveBusy = false
    private var slowBusy = false
    @Published var syncing = false
    private var lastStart: Date?
    private var timers: [Timer] = []
    private var lastLiveAt = Date.distantPast

    init() {
        anim.onStep = { [weak self] key, provider, window in self?.quotaStepEvent(key: key, provider: provider, window: window) }
        refreshLive()
        refreshSlow()
        // ticks every second so a changed refresh interval applies right away
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastLiveAt) >= max(1, Pref.num(Pref.liveEvery)) else { return }
                self.refreshLive()
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: SLOW_EVERY, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSlow() }
        })
    }

    private static func get<T: Decodable>(_ path: String, as: T.Type, snake: Bool = true) async throws -> T {
        var req = URLRequest(url: URL(string: BASE + path)!)
        req.timeoutInterval = 10
        let (body, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dec = JSONDecoder()
        if snake { dec.keyDecodingStrategy = .convertFromSnakeCase }
        return try dec.decode(T.self, from: body)
    }

    func refreshLive() {
        guard !liveBusy else { return }
        lastLiveAt = Date()
        liveBusy = true
        Task {
            defer { liveBusy = false }
            do {
                let d = try await Store.get("/api/live", as: LiveData.self)
                var perBase: [String: Int] = [:]
                for it in d.quotas?.items ?? [] { perBase[pBase(it.provider), default: 0] += 1 }
                multiAccountBases = Set(perBase.filter { $0.value > 1 }.keys)
                live = d
                let n = mains.count, w = workingMains.count
                let wa = workingMains.filter(\.attended).count
                // peek when a session you are using starts working (unattended workers flip constantly), max 1/min
                if let prev = lastAttendedWorking, wa > prev, Date().timeIntervalSince(lastSessionPeek) > 60 {
                    lastSessionPeek = Date()
                    Island.shared.peek("sessions")
                }
                lastAttendedWorking = wa
                if (lastMainCount.map { n != $0 } ?? false) || (lastWorkingCount.map { w != $0 } ?? false) { reloadWidgets() }
                lastMainCount = n
                lastWorkingCount = w
                offline = false
                updated = Date()
                anim.ingest(quotaOptions, burn: d.burn ?? [])
                notifier.quotas(d.quotas)
                notifier.quotaSoon(d.quotas, burn: d.burn ?? [], now: d.now)
                notifier.accountHint(d.quotas)
                notifier.sessions(d.running)
                notifier.agents(d.running)
            } catch {
                offline = true
                // the bar is useless without the panel server: bring it up, at most once a minute
                // (only for the default port: a test instance is started by whoever points the app at it)
                if Pref.on(Pref.autoStart), SERVER_PORT == 8777, lastStart.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                    lastStart = Date()
                    startServer()
                }
            }
        }
    }

    func refreshSlow() {
        guard !slowBusy else { return }
        slowBusy = true
        Task {
            let began = Date()
            syncing = true
            defer {
                slowBusy = false
                // keep the sweep visible long enough to read as feedback
                let rest = max(0, 0.8 - Date().timeIntervalSince(began))
                DispatchQueue.main.asyncAfter(deadline: .now() + rest) { self.syncing = false }
            }
            if let o = try? await Store.get("/api/overview?from=\(isoDay(-6))&to=\(isoDay(0))", as: Overview.self) {
                overview = o
                notifier.kanban(o.kanban)
            }
            if let a = try? await Store.get("/api/accounts?from=\(isoDay(-1))&to=\(isoDay(0))", as: AccountsResp.self) {
                history = a.history
            }
            if let h = try? await Store.get("/api/health", as: HealthResp.self, snake: false) {
                health = h
                notifier.health(h)
            }
            let monthStart = String(isoDay(0).prefix(7)) + "-01"
            if let m = try? await Store.get("/api/overview?from=\(monthStart)&to=\(isoDay(0))", as: Overview.self) {
                month = m
                notifier.budget(today: spend(m, day: isoDay(0)), month: spend(m, day: nil))
            }
            if let t = try? await Store.get("/api/top-sessions?from=\(isoDay(0))&to=\(isoDay(0))", as: TopResp.self, snake: false) {
                topToday = t.sessions
            }
            if let t = try? await Store.get("/api/top-sessions?from=\(isoDay(-6))&to=\(isoDay(0))", as: TopResp.self, snake: false) {
                topWeek = t.sessions
            }
        }
    }

    func refreshAll() { refreshLive(); refreshSlow() }

    /// Ask the panel for a fresh provider quota snapshot (normally cached ~2 min), then reload.
    func refreshQuotasNow() {
        Task {
            _ = try? await Store.get("/api/accounts?force=1", as: AccountsResp.self)
            refreshAll()
        }
    }

    /// Cost (Hermes + CLIs) of one day, or of the whole overview range when `day` is nil.
    func spend(_ o: Overview, day: String?) -> Double {
        let hermes = o.usage.daily.filter { day == nil || $0.day == day }
            .reduce(0) { acc, d in acc + d.by.values.reduce(0) { $0 + ($1.cost ?? 0) } }
        let cli = o.clis.daily.filter { day == nil || $0.day == day }
            .reduce(0) { acc, d in acc + d.cost.values.reduce(0, +) }
        return hermes + cli
    }

    var mains: [Session] { (live?.running ?? []).filter { $0.isRunning && !$0.subagent } }
    /// Open sessions that are actually working on something right now (a subagent at work counts for its parent).
    var workingMains: [Session] {
        let busyParents = Set((live?.running ?? []).filter { $0.subagent && $0.isWorking }.compactMap(\.parent))
        return mains.filter { $0.isWorking || busyParents.contains($0.id) }
    }
    var subs: [Session] { (live?.running ?? []).filter { $0.subagent } }
    /// One counting rule for every surface (server `counts`; computed here only for an older server).
    var counts: LiveCounts {
        if let c = live?.counts { return c }
        let m = mains
        return LiveCounts(open: m.count, working: workingMains.count, needsApproval: m.filter { $0.state == "needs_approval" }.count,
                          yourTurn: m.filter { $0.state == "waiting" }.count, stalled: m.filter { $0.state == "stalled" }.count,
                          subagents: subs.filter(\.isRunning).count)
    }
    /// Sessions waiting for an approval, longest first — pinned at the top of every list.
    var approvals: [Session] {
        mains.filter { $0.state == "needs_approval" }.sorted { ($0.stateSince ?? .infinity) < ($1.stateSince ?? .infinity) }
    }

    /// Total tokens per minute for the last 30 minutes (bar sparkline).
    var spark: [Double] {
        (live?.tokens ?? []).suffix(30).map { m in m.by.values.reduce(0) { $0 + ($1.tokens ?? 0) } }
    }

    /// The most-used quota window among providers that still have a usable account
    /// (a provider whose every account is already exhausted would pin the bar at 100 %).
    var tightest: Double? {
        (live?.quotas?.items ?? [])
            .filter { item in (item.accounts ?? []).isEmpty || (item.accounts ?? []).contains { $0.status != "exhausted" } }
            .flatMap { $0.windows ?? [] }.compactMap(\.used).max()
    }

    /// The provider's windows are a last known reading (rate limited ...): rings and rows are drawn dimmed.
    func isStale(_ provider: String) -> Bool {
        (live?.quotas?.items ?? []).first { $0.provider == provider }?.stale == true
    }

    /// Every quota window the bar can show, as (key, provider, window).
    var quotaOptions: [(key: String, provider: String, window: QuotaWindow)] {
        (live?.quotas?.items ?? []).flatMap { item in
            (item.windows ?? []).filter { $0.used != nil }.map { ("\(item.provider)|\($0.label)", item.provider, $0) }
        }
    }

    /// The most-used window among usable providers, as an option (for the "auto" bar mode).
    var tightestOption: (key: String, provider: String, window: QuotaWindow)? {
        let usable = Set((live?.quotas?.items ?? [])
            .filter { item in (item.accounts ?? []).isEmpty || (item.accounts ?? []).contains { $0.status != "exhausted" } }
            .map(\.provider))
        return quotaOptions.filter { usable.contains($0.provider) }.max { ($0.window.used ?? 0) < ($1.window.used ?? 0) }
    }

    /// Quota windows picked in the settings, in selection order ("auto" = tightest usable), de-duplicated.
    func chosenQuotas(_ selection: [String]) -> [(key: String, provider: String, window: QuotaWindow)] {
        var chosen: [(key: String, provider: String, window: QuotaWindow)] = []
        for key in selection {
            if key == "auto" { if let t = tightestOption { chosen.append(t) } }
            else if let o = quotaOptions.first(where: { $0.key == key }) { chosen.append(o) }
            else {
                // a quota picked as "anthropic|Current session" before the provider was split per account
                // ("anthropic#personal|…"): show that window for every account of the provider
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2, !parts[0].contains("#") {
                    chosen += quotaOptions.filter { pBase($0.provider) == parts[0] && $0.provider.contains("#") && $0.window.label == parts[1] }
                }
            }
        }
        var seen = Set<String>()
        return chosen.filter { seen.insert($0.key).inserted }
    }

    /// Bar segments from the settings: session count, token rate, then the chosen quotas grouped per provider
    /// (one logo inside ring gauges, values in selection order: "49% 41%", revealed while the group is open).
    func barPieces(count: Bool, tokens: Bool, left: Bool, selection: [String]) -> [BarPiece] {
        var out: [BarPiece] = []
        if count {
            out.append(BarPiece(icon: NSImage(systemSymbolName: mains.isEmpty ? "bolt.horizontal.circle" : "bolt.horizontal.circle.fill",
                                              accessibilityDescription: nil), text: "\(counts.open)"))
        }
        if tokens {
            out.append(BarPiece(icon: NSImage(systemSymbolName: "waveform", accessibilityDescription: nil),
                                text: compact(live?.last1m)))
        }
        let now = Date()
        var order: [String] = []
        var texts: [String: [String]] = [:]
        var rings: [String: [Double]] = [:]
        for c in chosenQuotas(selection) {
            let used = anim.displayed(c.key, at: now)
            let shown = Int((left ? max(0, 100 - used) : used).rounded())
            if texts[c.provider] == nil { order.append(c.provider) }
            texts[c.provider, default: []].append(anim.text(c.key, value: shown, at: now))
            rings[c.provider, default: []].append(used / 100)  // rings always show usage
        }
        for p in order {
            let icon = providerIcon(p)
            out.append(BarPiece(icon: icon, text: (icon == nil ? "\(pName(p)) " : "") + texts[p]!.joined(separator: " "),
                                rings: rings[p]!, reveal: anim.reveal(p), flash: anim.flash(p, at: now)))
        }
        return out
    }
}

// ---------- shared views ----------

struct BarLabel: View {
    @ObservedObject var store: Store
    @ObservedObject var anim: BarAnimator
    @AppStorage(Pref.barSpark) private var spark = true
    @AppStorage(Pref.barCount) private var count = true
    @AppStorage(Pref.barTokens) private var tokens = false
    @AppStorage(Pref.barLeft) private var left = false
    @AppStorage(Pref.barQuotas) private var quotas = "auto"
    var body: some View {
        if store.offline {
            Image(systemName: "bolt.horizontal.circle")
        } else {
            let pieces = store.barPieces(count: count, tokens: tokens, left: left,
                                         selection: quotas.split(separator: ",").map(String.init))
            if !spark && pieces.isEmpty {
                Image(systemName: "bolt.horizontal.circle")
            } else {
                Image(nsImage: barImage(spark: spark ? store.spark : nil, pieces: pieces))
            }
        }
    }
}

struct Kpi: View {
    let title: String
    let value: String
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(motionOn() ? .snappy : nil, value: value)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.top, 4)
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct MeterRow: View {
    let name: String
    let value: Double
    let top: Double
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(label).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            ProgressView(value: top > 0 ? value / top : 0).tint(.accentColor)
        }
    }
}

// ---------- live tab ----------

struct TokPoint: Identifiable {
    let id = UUID()
    let t: Date
    let source: String
    let tokens: Double
}

struct LiveTab: View {
    @ObservedObject var store: Store
    var body: some View {
        if let d = store.live {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    Kpi(title: L("Open sessions", "Açık oturum"), value: "\(store.counts.open)", note: countLine(store.counts))
                    Kpi(title: L("Subagents", "Alt ajan"), value: "\(store.counts.subagents)", note: L("working", "çalışan"))
                    Kpi(title: L("API-equivalent, 60 min", "60 dk API karşılığı"), value: money(d.cost60m), note: L("estimate", "tahmini"))
                    Kpi(title: L("Last 1 min", "Son 1 dk"), value: compact(d.last1m), note: L("tokens", "token"))
                    Kpi(title: L("Last 5 min", "Son 5 dk"), value: compact(d.last5m), note: L("tokens", "token"))
                    Kpi(title: L("Last 60 min", "Son 60 dk"), value: compact(d.last60m), note: L("tokens", "token"))
                }
                if !store.approvals.isEmpty { ApprovalBanner(items: store.approvals, now: d.now) }
                SectionTitle(text: L("Tokens / minute", "Token / dakika"), trailing: L("last 60 min", "son 60 dk"))
                TokenChart(points: tokenPoints(d))
                SectionTitle(text: L("Messages / minute", "Mesaj / dakika"), trailing: L("Hermes only", "yalnızca Hermes"))
                if (d.activity ?? []).contains(where: { ($0.assistant ?? 0) + ($0.tool ?? 0) + ($0.user ?? 0) > 0 }) {
                    ActivityChart(acts: d.activity ?? [])
                } else {
                    Text(L("No Hermes messages in the last hour", "Son bir saatte Hermes mesajı yok"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                SectionTitle(text: L("Open sessions", "Açık oturumlar"), trailing: L("click a row to open it · incl. subagents finished in the last 15 min", "satıra tıkla: aç · son 15 dk'da biten alt ajanlar dahil"))
                if store.mains.isEmpty {
                    Text(L("No open sessions right now", "Şu an açık oturum yok")).font(.callout).foregroundStyle(.secondary)
                } else {
                    SessionGroups(mains: store.mains, subs: store.subs, now: d.now)
                }
                if let speed = store.health?.speed, !speed.isEmpty {
                    SectionTitle(text: L("Model speed", "Model hızı"), trailing: L("median / p90 turn · 24 h", "tur medyanı / p90 · 24 sa"))
                    ForEach(speed.prefix(6)) { sp in SpeedRow(sp: sp) }
                }
                if let profs = d.byProfile, !profs.isEmpty {
                    SectionTitle(text: L("By profile", "Profil bazında"), trailing: L("last 60 min", "son 60 dk"))
                    let top = profs.map { $0.tokens ?? 0 }.max() ?? 0
                    ForEach(profs.prefix(6), id: \.profile) { p in
                        MeterRow(name: p.profile, value: p.tokens ?? 0, top: top,
                                 label: "\(compact(p.tokens)) · \(money(p.cost))")
                    }
                }
            }
        }
    }

    func tokenPoints(_ d: LiveData) -> [TokPoint] {
        (d.tokens ?? []).flatMap { m in
            m.by.map { TokPoint(t: Date(timeIntervalSince1970: m.t), source: SOURCE_NAME[$0.key] ?? $0.key, tokens: $0.value.tokens ?? 0) }
        }
    }
}

struct TokenChart: View {
    let points: [TokPoint]
    var body: some View {
        let scale = sourceScale(Set(points.map(\.source)))
        Chart(points) { p in
            BarMark(x: .value("Dakika", p.t, unit: .minute), y: .value("Token", p.tokens))
                .foregroundStyle(by: .value("Kaynak", p.source))
        }
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartXAxis { AxisMarks(values: .stride(by: .minute, count: 15)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text(compact(v.as(Double.self))) } } }
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 130)
    }
}

struct ActivityChart: View {
    let acts: [Act]
    var body: some View {
        Chart(acts, id: \.t) { a in
            AreaMark(x: .value("Dakika", Date(timeIntervalSince1970: a.t), unit: .minute),
                     y: .value("Mesaj", (a.assistant ?? 0) + (a.tool ?? 0) + (a.user ?? 0)))
                .foregroundStyle(.purple.opacity(0.35))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 2)) }
        .frame(height: 50)
    }
}

/// Sessions waiting for approval, pinned above the lists: orange, one click opens the session.
struct ApprovalBanner: View {
    let items: [Session]
    let now: Double
    var dense = false
    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 3 : 5) {
            Label(L("\(items.count) waiting for your approval", "\(items.count) iş onay bekliyor"), systemImage: "hand.raised.fill")
                .font((dense ? Font.caption : .callout).weight(.semibold)).foregroundStyle(.orange)
            ForEach(items) { s in
                HStack(spacing: 6) {
                    Text(s.title ?? L("(untitled)", "(başlıksız)")).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(s.groupName + (s.stateSince.map { " · " + span(now - $0) } ?? "")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let o = s.open, o.canOpen { Image(systemName: o.icon).font(.caption2).foregroundStyle(.orange) }
                }
                .font(dense ? .caption : .callout)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                .openable(s.open)
                .help([s.title, s.open.flatMap { $0.canOpen ? $0.clickHint : nil }].compactMap { $0 }.joined(separator: "\n"))
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.6), lineWidth: 1))
    }
}

struct SessionTree: View {
    let mains: [Session]
    let subs: [Session]
    let now: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(mains) { s in
                let children = subs.filter { $0.parent == s.id }
                if children.isEmpty {
                    SessionRow(s: s, now: now)
                } else {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(children) { c in SessionRow(s: c, now: now) }
                        }
                        .padding(.top, 4)
                    } label: {
                        SessionRow(s: s, now: now, runningSubs: children.filter(\.isRunning).count)
                    }
                }
            }
        }
    }
}

/// Open sessions grouped by who runs them (Hermes · <profile> / Claude Code / Copilot CLI — NOT a provider account),
/// each group headed by its session count, tokens and total cost. Subagents nest under their main session.
struct SessionGroups: View {
    let mains: [Session]
    let subs: [Session]
    let now: Double
    var dense = false
    private var groups: [(key: String, name: String, items: [Session])] {
        var order: [String] = []
        var byKey: [String: [Session]] = [:]
        for s in mains {
            if byKey[s.groupKey] == nil { order.append(s.groupKey) }
            byKey[s.groupKey, default: []].append(s)
        }
        return order.map { (key: $0, name: byKey[$0]!.first!.groupName, items: byKey[$0]!) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 9 : 12) {
            ForEach(groups, id: \.key) { g in
                let kids = subs.filter { c in g.items.contains { $0.id == c.parent } }
                let tok = g.items.reduce(0) { $0 + ($1.tokens ?? 0) } + kids.reduce(0) { $0 + ($1.tokens ?? 0) }
                let cost = g.items.reduce(0) { $0 + ($1.cost ?? 0) } + kids.reduce(0) { $0 + ($1.cost ?? 0) }
                VStack(alignment: .leading, spacing: dense ? 4 : 6) {
                    HStack(spacing: 6) {
                        Text(g.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(g.items.count) · \(compact(tok)) · \(money(cost))")
                            .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    SessionTree(mains: g.items, subs: subs, now: now)
                }
            }
        }
    }
}

struct SessionRow: View {
    let s: Session
    let now: Double
    var runningSubs = 0
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // pulsing = working right now; steady = open, waiting for input; grey = ended
            Group {
                if s.isWorking { PulseDot(color: .green) }
                else if s.isRunning { Circle().fill(Color.green.opacity(0.45)) }
                else { Circle().fill(Color.secondary.opacity(0.5)) }
            }
            .help(s.isWorking ? L("working", "işlem yapıyor") : s.isRunning ? L("open, waiting", "açık, bekliyor") : L("ended", "bitti"))
                .frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(s.title ?? L("(untitled)", "(başlıksız)")).lineLimit(1).truncationMode(.tail)
                    // kanban worker rows only: the card it works on (server pairs by worker pid / task id, not by profile)
                    if let k = s.kanban, let ks = k.status {
                        Text((kName(ks) ?? ks) + " · " + k.id).font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(kanbanColor(ks).opacity(0.22)))
                            .foregroundStyle(kanbanColor(ks))
                            .fixedSize()
                    }
                    if s.cardOnly == true {
                        Text(L("no session found", "oturum bulunamadı")).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
                    }
                }
                // a subagent names the session it was spawned from; the model comes on the next line
                if s.subagent, let parent = s.parentTitle ?? modelShort(s.parentModel) {
                    Text(L("↳ subagent of “\(parent)”", "↳ “\(parent)” oturumunun alt ajanı")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Text([modelShort(s.model), runningSubs > 0 ? (runningSubs == 1 ? L("1 subagent", "1 alt ajan") : L("\(runningSubs) subagents", "\(runningSubs) alt ajan")) : nil,
                      s.isRunning ? idle : L("ended", "bitti")].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if s.isRunning, let st = stateText(s, now: now) {
                    Text(st).font(.caption2.weight(s.state == "needs_approval" ? .bold : .medium))
                        .foregroundStyle(s.state == "waiting" ? Color.green : s.state == "needs_approval" ? .orange : (s.state == nil || s.state == "working") ? Color.secondary : .orange)
                }
                if let a = s.activity, !a.isEmpty {
                    Text(a).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(compact(s.tokens)).monospacedDigit()
                if let c = s.cost, c > 0 {
                    Text(money(c)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if let ctx = s.contextTokens, s.isRunning {
                    Text((s.contextEstimated == true ? "≈" : "") + compact(ctx) + L(" ctx", " bağlam"))
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(ctx >= LARGE_CONTEXT ? Color.orange : .secondary)
                        .help(L("Context sent with every turn", "Her turda gönderilen bağlam"))
                }
                if let st = s.started {
                    Text(span((s.isRunning ? now : (s.last ?? now)) - st)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, s.state == "needs_approval" && s.isRunning ? 6 : 0)
        .padding(.vertical, s.state == "needs_approval" && s.isRunning ? 3 : 0)
        .background(s.state == "needs_approval" && s.isRunning ? Color.orange.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .openable(s.open)
        .help([s.title, s.kanban?.title.map { L("card: ", "kart: ") + $0 },
               s.open.flatMap { $0.canOpen ? $0.clickHint : nil },
               s.activity].compactMap { $0 }.joined(separator: "\n"))
        .contextMenu { SessionActions(id: s.id, source: s.source, profile: s.profile, open: s.open) }
    }

    /// "son hareket 3 dk önce" once a running session has been quiet for more than a minute.
    var idle: String? {
        guard let l = s.last, now - l > 60 else { return nil }
        return L("idle for \(span(now - l))", "son hareket \(span(now - l)) önce")
    }
}

struct SpeedRow: View {
    let sp: Speed
    var body: some View {
        HStack(spacing: 8) {
            Text(sp.model).lineLimit(1).truncationMode(.middle)
            Text(sp.source == "claude-code" ? "Claude Code" : "Hermes").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text((sp.p50_s.map { span($0) } ?? "—") + " / " + (sp.p90_s.map { span($0) } ?? "—"))
                .monospacedDigit()
                .foregroundStyle((sp.p50_s ?? 0) > 120 ? Color.orange : .primary)
            Text("n=\(sp.turns)").font(.caption2).foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
        }
        .font(.callout)
        .help(sp.first_reply_p50_s.map { L("first reply after \(span($0)) (median)", "ilk yanıt \(span($0)) sonra (medyan)") } ?? "")
    }
}

// ---------- quotas tab ----------

struct QuotasTab: View {
    @ObservedObject var store: Store
    @State private var override: [String: Bool] = [:]  // provider -> expanded (user click wins over auto)
    var body: some View {
        if let d = store.live {
            let items = d.quotas?.items ?? []
            let metered = items.filter { ($0.windows ?? []).contains { $0.used != nil } }
            let others = items.filter { item in !metered.contains { $0.provider == item.provider } }
            VStack(alignment: .leading, spacing: 14) {
                if items.isEmpty { Text(L("No quota data", "Kota bilgisi yok")).foregroundStyle(.secondary) }
                ForEach(metered, id: \.provider) { item in
                    let open = override[item.provider] ?? store.anim.isOpen(item.provider)
                    QuotaCard(item: item, burn: d.burn ?? [], history: store.history.filter { $0.provider == item.provider },
                              now: d.now, collapsed: !open) {
                        withAnimation(motionOn() ? .snappy : nil) { override[item.provider] = !open }
                    }
                }
                if !others.isEmpty { OtherAccounts(items: others) }
            }
        }
    }
}

func accountStatus(_ s: String?) -> (String, Color) {
    switch s {
    case "ok": return (L("active", "aktif"), .green)
    case "exhausted": return (L("limit reached", "limit doldu"), .red)
    case nil: return (L("unknown", "bilinmiyor"), .secondary)
    default: return (s!, .orange)
    }
}

/// Providers that report no usage window: one compact list with each account's state.
struct OtherAccounts: View {
    let items: [QuotaItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: L("Other providers", "Diğer sağlayıcılar"), trailing: L("details: Health tab", "ayrıntı: Sağlık sekmesi"))
            ForEach(items, id: \.provider) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(pName(item.provider)).font(.callout)
                    Spacer()
                    ForEach(Array((item.accounts ?? []).enumerated()), id: \.offset) { _, a in
                        let st = accountStatus(a.status)
                        Chip(text: st.0, color: st.1).help(a.label ?? "")
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct HistPoint: Identifiable {
    let id = UUID()
    let t: Date
    let window: String
    let used: Double
}

struct QuotaCard: View {
    let item: QuotaItem
    let burn: [Burn]
    let history: [QHist]
    let now: Double
    var collapsed = false
    var toggle: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text(pName(item.provider)).font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? L("Expand", "Genişlet")
                      : L("Collapse — reopens by itself on every 2% step or when burning fast", "Daralt — yüzde %2 değişince ya da hızlı tüketimde kendiliğinden açılır"))
                Spacer()
                // a credential is not an account: one account can hold several credentials
                let creds = item.accounts ?? []
                Chip(text: (item.accountKey != nil ? L("1 account · ", "1 hesap · ") : "") + plural(creds.count, "credential", "credentials", tr: "kimlik bilgisi"),
                     color: creds.contains(where: \.unverified) ? .orange : .secondary)
            }
            let windows = (item.windows ?? []).filter { $0.used != nil }
            if item.stale == true {
                Text(staleLine(fetchedAt: item.fetchedAt, code: item.unavailableCode, retryAt: item.retryAt, now: now))
                    .font(.caption).foregroundStyle(.orange)
                    .help(item.unavailableHttp.map { L("HTTP \(Int($0)) from the provider", "Sağlayıcıdan HTTP \(Int($0))") } ?? "")
            }
            if collapsed {
                ForEach(windows, id: \.label) { w in CompactQuotaRow(window: w, now: now) }.opacity(item.stale == true ? 0.6 : 1)
            } else {
            ForEach(windows, id: \.label) { w in
                QuotaRow(window: w, burn: item.stale == true ? nil : burn.first { $0.provider == item.provider && $0.window == w.label }, now: now)
                    .opacity(item.stale == true ? 0.6 : 1)
            }
            let pts = history.flatMap { h in
                h.points.filter { $0.count >= 2 }.map { HistPoint(t: Date(timeIntervalSince1970: $0[0]), window: wName(h.window), used: $0[1]) }
            }
            // a flat line (e.g. an exhausted account pinned at 100 %) carries no information
            if pts.count >= 2, Set(pts.map(\.used)).count > 1 {
                Chart(pts) { p in
                    LineMark(x: .value("Zaman", p.t), y: .value("%", p.used))
                        .foregroundStyle(by: .value("Pencere", p.window))
                        .interpolationMethod(.stepEnd)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 110)
            }
            ForEach(Array((item.accounts ?? []).enumerated()), id: \.offset) { _, a in
                let st = accountStatus(a.status)
                HStack(spacing: 6) {
                    Text(a.label ?? L("credential", "kimlik bilgisi")).font(.caption.weight(.medium))
                    Text(credKind(a.source)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if a.unverified {
                        Chip(text: L("account unverified", "hesabı doğrulanamadı"), color: .orange)
                            .help(L("Which account this credential belongs to could not be read\(a.http.map { " (HTTP \(Int($0)))" } ?? ""); it is not counted as a separate account.",
                                    "Bu kimlik bilgisinin hangi hesaba ait olduğu okunamadı\(a.http.map { " (HTTP \(Int($0)))" } ?? ""); ayrı hesap sayılmadı."))
                    }
                    Chip(text: st.0, color: st.1)
                }
            }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One-line quota for a collapsed card: name, slim bar, %, reset.
struct CompactQuotaRow: View {
    let window: QuotaWindow
    let now: Double
    var body: some View {
        let used = window.used ?? 0
        HStack(spacing: 8) {
            Text(wName(window.label)).font(.caption).frame(width: 78, alignment: .leading).lineLimit(1)
            ProgressView(value: min(used, 100), total: 100).tint(levelColor(used)).frame(maxWidth: .infinity)
            Text(L("\(Int(used))%", "%\(Int(used))")).font(.caption.weight(.semibold)).monospacedDigit().frame(width: 38, alignment: .trailing)
            if let r = window.reset {
                Text(span(r - now)).font(.caption2).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
        }
    }
}

struct QuotaRow: View {
    let window: QuotaWindow
    let burn: Burn?
    let now: Double
    var body: some View {
        let used = window.used ?? 0
        // at the current burn rate the window fills up before it resets
        let fillsFirst = burn?.etaFull.map { $0 < (window.reset ?? .infinity) } ?? false
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(wName(window.label)).font(.callout)
                if let d = window.detail { Text(d).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                if fillsFirst {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .symbolEffect(.pulse, isActive: motionOn())
                        .help(L("Fills up before reset at this rate", "Bu hızla sıfırlanmadan önce dolar"))
                }
                Spacer()
                Text(L("\(Int(used))% used · \(max(0, 100 - Int(used)))% left", "%\(Int(used)) kullanıldı · %\(max(0, 100 - Int(used))) kaldı"))
                    .contentTransition(.numericText(value: used))
                    .animation(motionOn() ? .snappy : nil, value: used)
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: min(used, 100), total: 100).tint(levelColor(used))
                .animation(motionOn() ? .easeOut(duration: 0.6) : nil, value: used)
            HStack {
                if let r = window.reset { Text(L("resets \(when(r, now: now))", "sıfırlanma \(when(r, now: now))")) }
                Spacer()
                if let b = burn, b.perHour > 0.01 {
                    Text(L(String(format: "+%.1f%%/h", b.perHour), String(format: "+%%%.1f/saat", b.perHour))
                         + (b.etaFull.map { L(" · full in \(span($0 - now))", " · dolma \(span($0 - now))") } ?? ""))
                        .foregroundStyle(fillsFirst ? .orange : .secondary)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            if let b = burn, b.perHour > 0.01, used < 100 {
                Text(forecast(b))
                    .font(.caption2).foregroundStyle(fillsFirst ? .orange : .secondary)
            }
        }
    }

    func forecast(_ b: Burn) -> String {
        guard let eta = b.etaFull else { return "" }
        let f = DateFormatter()
        f.dateFormat = eta - now > 86400 ? "d MMM HH:mm" : "HH:mm"
        f.locale = appLocale()
        let at = f.string(from: Date(timeIntervalSince1970: eta))
        if let r = window.reset, eta < r {
            return L("⚠ At this rate full around \(at) — \(span(r - eta)) before reset", "⚠ Bu hızla ~\(at) civarı dolar — sıfırlanmaya \(span(r - eta)) kala")
        }
        return L("At this rate it won't fill up before reset", "Bu hızla sıfırlanmadan önce dolmaz")
    }
}

// ---------- usage tab ----------

struct DayPoint: Identifiable {
    let id = UUID()
    let day: Date
    let source: String
    let value: Double
}

struct UsageTab: View {
    @ObservedObject var store: Store
    @AppStorage("usageMetric") private var metric = "cost"
    var body: some View {
        if let o = store.overview {
            let pts = dayPoints(o)
            let today = Calendar.current.startOfDay(for: Date())
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
            let todaySum = pts.filter { $0.day == today }.reduce(0) { $0 + $1.value }
            let yesterdaySum = pts.filter { $0.day == yesterday }.reduce(0) { $0 + $1.value }
            let weekSum = pts.reduce(0) { $0 + $1.value }
            let fmt: (Double) -> String = metric == "cost" ? { money($0) } : { compact($0) }
            VStack(alignment: .leading, spacing: 10) {
                BudgetCard(store: store)
                Picker("", selection: $metric) {
                    Text(L("API cost", "API karşılığı")).tag("cost")
                    Text(L("Tokens", "Token")).tag("tokens")
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack(spacing: 8) {
                    Kpi(title: L("Today", "Bugün"), value: fmt(todaySum), note: L("yesterday \(fmt(yesterdaySum))", "dün \(fmt(yesterdaySum))"))
                    Kpi(title: L("Last 7 days", "Son 7 gün"), value: fmt(weekSum), note: "Hermes + CLI")
                    Kpi(title: L("Daily avg.", "Günlük ort."), value: fmt(weekSum / 7), note: L("7 days", "7 gün"))
                }
                SectionTitle(text: L("Daily", "Günlük"), trailing: L("Hermes + CLIs", "Hermes + CLI'lar"))
                let scale = sourceScale(Set(pts.map(\.source)))
                Chart(pts) { p in
                    BarMark(x: .value("Gün", p.day, unit: .day), y: .value("Değer", p.value))
                        .foregroundStyle(by: .value("Kaynak", p.source))
                }
                .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
                .chartXAxis {
                    // Charts formats with the system locale; use the app language instead
                    AxisMarks(values: .stride(by: .day)) { v in
                        AxisValueLabel { if let d = v.as(Date.self) { Text(weekdayShort(d)) } }
                    }
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text(fmt(v.as(Double.self) ?? 0)) } } }
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 140)

                let models = o.usage.byModel.sorted { val($0.cost, $0.tokens) > val($1.cost, $1.tokens) }.prefix(6)
                SectionTitle(text: L("Hermes models", "Hermes modelleri"), trailing: L("7 days", "7 gün"))
                let mTop = models.map { val($0.cost, $0.tokens) }.max() ?? 0
                ForEach(Array(models.enumerated()), id: \.offset) { _, m in
                    MeterRow(name: m.model ?? "?", value: val(m.cost, m.tokens), top: mTop,
                             label: "\(compact(m.tokens)) · \(money(m.cost))")
                }
                let profs = o.usage.byProfile.sorted { val($0.cost, $0.tokens) > val($1.cost, $1.tokens) }.prefix(6)
                SectionTitle(text: L("Hermes profiles", "Hermes profilleri"), trailing: L("7 days", "7 gün"))
                let pTop = profs.map { val($0.cost, $0.tokens) }.max() ?? 0
                ForEach(Array(profs.enumerated()), id: \.offset) { _, p in
                    MeterRow(name: p.profile, value: val(p.cost, p.tokens), top: pTop,
                             label: "\(compact(p.tokens)) · \(money(p.cost)) · " + L("\(Int(p.sessions ?? 0)) sessions", "\(Int(p.sessions ?? 0)) oturum"))
                }
                TopSessionsView(store: store)
                if !o.clis.sources.isEmpty {
                    SectionTitle(text: L("Agent CLIs", "Ajan CLI'ları"), trailing: L("7 days", "7 gün"))
                    let cTop = o.clis.sources.map { val($0.cost, $0.tokens) }.max() ?? 0
                    ForEach(o.clis.sources, id: \.source) { c in
                        MeterRow(name: c.name, value: val(c.cost, c.tokens), top: cTop,
                                 label: "\(compact(c.tokens)) · \(money(c.cost)) · " + L("\(Int(c.sessions ?? 0)) sessions", "\(Int(c.sessions ?? 0)) oturum"))
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    func val(_ cost: Double?, _ tokens: Double?) -> Double { metric == "cost" ? (cost ?? 0) : (tokens ?? 0) }

    func dayPoints(_ o: Overview) -> [DayPoint] {
        var out: [DayPoint] = []
        for d in o.usage.daily {
            let v = d.by.values.reduce(0) { $0 + val($1.cost, $1.tokens) }
            if v > 0 { out.append(DayPoint(day: dayDate(d.day), source: "Hermes", value: v)) }
        }
        for d in o.clis.daily {
            for (src, tok) in d.tokens {
                let v = metric == "cost" ? (d.cost[src] ?? 0) : tok
                if v > 0 { out.append(DayPoint(day: dayDate(d.day), source: SOURCE_NAME[src] ?? src, value: v)) }
            }
        }
        return out
    }
}

struct BudgetCard: View {
    @ObservedObject var store: Store
    @AppStorage(Pref.budgetDay) private var day = 0.0
    @AppStorage(Pref.budgetMonth) private var month = 0.0
    var body: some View {
        if let m = store.month {
            let today = store.spend(m, day: isoDay(0))
            let mtd = store.spend(m, day: nil)
            let cal = Calendar.current
            let dayOfMonth = Double(cal.component(.day, from: Date()))
            let daysInMonth = Double(cal.range(of: .day, in: .month, for: Date())?.count ?? 30)
            // pace of the full days so far + today's spend so far
            let projection = dayOfMonth > 1 ? (mtd - today) / (dayOfMonth - 1) * (daysInMonth - dayOfMonth) + mtd : mtd * daysInMonth
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: L("Budget", "Bütçe"), trailing: L("Hermes + CLI · estimated API cost", "Hermes + CLI · tahmini API karşılığı"))
                BudgetRow(title: L("Today", "Bugün"), spent: today, limit: day)
                BudgetRow(title: L("This month", "Bu ay"), spent: mtd, limit: month)
                HStack {
                    Text(L("Month-end projection", "Ay sonu tahmini")).font(.callout)
                    Spacer()
                    Text(money(projection)).font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(month > 0 && projection > month ? .orange : .primary)
                }
                if day == 0 && month == 0 {
                    Text(L("No budget set — pick one under ⚙ → Budget", "Bütçe tanımlı değil — ⚙ → Bütçe menüsünden belirleyebilirsin"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct BudgetRow: View {
    let title: String
    let spent: Double
    let limit: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(limit > 0 ? "\(money(spent)) / \(money(limit))" : money(spent))
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
            if limit > 0 {
                let pct = spent / limit * 100
                ProgressView(value: min(pct, 100), total: 100).tint(levelColor(pct))
            }
        }
    }
}

struct TopSessionsView: View {
    @ObservedObject var store: Store
    @AppStorage("topRange") private var range = "today"
    var body: some View {
        let rows = range == "today" ? store.topToday : store.topWeek
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: L("Most expensive sessions", "En pahalı oturumlar"), trailing: nil)
                Spacer()
                Picker("", selection: $range) {
                    Text(L("Today", "Bugün")).tag("today")
                    Text(L("7 days", "7 gün")).tag("week")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            }
            if rows.isEmpty { Text(L("No sessions", "Oturum yok")).font(.callout).foregroundStyle(.secondary) }
            let top = rows.map(\.cost).max() ?? 0
            ForEach(Array(rows.prefix(8).enumerated()), id: \.offset) { _, r in
                MeterRow(name: r.title ?? L("(untitled)", "(başlıksız)"), value: r.cost, top: top,
                         label: "\(money(r.cost)) · \(compact(r.tokens))")
                    .help("\(r.profile) · \(r.model ?? "")" + L(" — session total", " — oturum toplamı"))
                    .contextMenu { SessionActions(id: r.id, source: r.source, profile: r.profile) }
            }
            Text(L("Total API-equivalent per session, estimate (sessions active in range)", "Oturumun toplam API karşılığı, tahmini (aralıkta aktif olanlar)")).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// Copy helpers for a session (read-only: nothing is changed in Hermes).
struct SessionActions: View {
    let id: String
    let source: String?
    var profile: String? = nil
    var open: OpenAction? = nil

    /// Resume command: the server's (profile-aware) one when the row has it, else built here with the profile.
    var resumeCommand: String {
        if let o = open {
            if o.kind == "kanban-card" { if let c = o.sessionCommand { return c } } else if let c = o.command { return c }
        }
        // single-quoted so an odd session id can't turn into extra shell commands when pasted
        let arg = "'" + id.replacingOccurrences(of: "'", with: "'\\''") + "'"
        if source == "claude-code" { return "claude --resume \(arg)" }
        if source == "copilot-cli" { return "copilot --resume \(arg)" }
        let p = (profile ?? "").isEmpty || profile == "default" ? "" : "-p '\(profile!.replacingOccurrences(of: "'", with: "'\\''"))' "
        return "hermes \(p)--resume \(arg)"
    }

    var body: some View {
        if let o = open, o.canOpen {
            Button(o.step.copies ? L("Copy the command to open it", "Açmak için komutu kopyala") : L("Open", "Aç")) { Opener.open(o) }
        }
        Button(L("Copy session ID", "Oturum ID'sini kopyala")) { copy(id) }
        Button(L("Copy resume command", "Devam komutunu kopyala")) { copy(resumeCommand) }
        Button(L("Open dashboard", "Paneli aç")) { openPanel() }
    }

    func copy(_ text: String) { Opener.copy(text) }
}

// ---------- kanban tab ----------

struct KanbanTab: View {
    @ObservedObject var store: Store
    var body: some View {
        if let o = store.overview {
            VStack(alignment: .leading, spacing: 14) {
                if o.kanban.isEmpty { Text(L("No kanban boards", "Kanban panosu yok")).foregroundStyle(.secondary) }
                ForEach(o.kanban, id: \.board) { b in BoardView(board: b) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

struct BoardView: View {
    let board: Board
    var body: some View {
        let now = Date().timeIntervalSince1970
        let active = board.cards.filter { ["running", "blocked", "review"].contains($0.status) || ($0.consecutiveFailures ?? 0) > 0 }
            .sorted { rank($0) < rank($1) }
        let recentDone = board.cards.filter { $0.status == "done" }.sorted { ($0.completedAt ?? 0) > ($1.completedAt ?? 0) }.prefix(5)
        VStack(alignment: .leading, spacing: 8) {
            Text(board.board).font(.headline)
            FlowChips(counts: board.counts)
            if let k = board.blockedByKind, (board.counts["blocked"] ?? 0) > 0 {
                Text(L("Blocked: \(Int(k["needs_input"] ?? 0)) need your input · \(Int(k["other"] ?? 0)) other", "Bloklu: \(Int(k["needs_input"] ?? 0)) girdi bekliyor · \(Int(k["other"] ?? 0)) diğer"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionTitle(text: L("Running / waiting / problems", "Çalışan / bekleyen / sorunlu"), trailing: L("click a card to open it", "karta tıkla: aç"))
            if active.isEmpty {
                Text(L("No running, waiting or failing cards right now", "Şu an çalışan, bekleyen ya da sorunlu kart yok")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(active) { c in CardRow(card: c, now: now) }
            if !recentDone.isEmpty {
                SectionTitle(text: L("Recently done", "Son bitenler"), trailing: L("7 days", "7 gün"))
                ForEach(Array(recentDone)) { c in CardRow(card: c, now: now) }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    func rank(_ c: Card) -> Int {
        c.blockKind == "needs_input" ? 0 : c.status == "blocked" ? 1 : c.status == "review" ? 2 : (c.consecutiveFailures ?? 0) > 0 ? 3 : 4
    }
}

struct FlowChips: View {
    let counts: [String: Double]
    var body: some View {
        let keys = KANBAN_ORDER.filter { counts[$0] != nil } + counts.keys.filter { !KANBAN_ORDER.contains($0) }.sorted()
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { k in
                Chip(text: "\(kName(k) ?? k) \(Int(counts[k] ?? 0))", color: color(k))
            }
        }
    }

    func color(_ k: String) -> Color {
        switch k {
        case "running": return .green
        case "blocked": return .red
        case "review": return .purple
        case "ready": return .blue
        case "done", "archived": return .secondary
        default: return .orange
        }
    }
}

struct CardRow: View {
    let card: Card
    let now: Double
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title ?? card.id).lineLimit(2)
                Text([card.assignee, meta].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if card.blockKind == "needs_input" {
                    Text(L("waiting for your input", "girdi bekliyor")).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                } else if card.status == "review" {
                    Text(L("waiting for review", "inceleme bekliyor")).font(.caption2.weight(.semibold)).foregroundStyle(.purple)
                }
                if let e = card.lastFailureError, !e.isEmpty {
                    Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .openable(card.open)
        .help(card.open?.canOpen == true ? (card.open?.clickHint ?? "") : "")
    }

    var dot: Color {
        card.blockKind == "needs_input" ? .orange : card.status == "review" ? .purple : card.status == "blocked" ? .red : (card.consecutiveFailures ?? 0) > 0 ? .orange : card.status == "running" ? .green : .secondary
    }

    var meta: String? {
        if card.status == "done", let c = card.completedAt { return L("done \(span(now - c)) ago", "\(span(now - c)) önce bitti") }
        if let s = card.startedAt { return L("running for \(span(now - s))", "\(span(now - s)) sürüyor")
            + ((card.consecutiveFailures ?? 0) > 0 ? L(" · \(Int(card.consecutiveFailures!)) failures", " · \(Int(card.consecutiveFailures!)) hata") : "") }
        return kName(card.status)
    }
}

// ---------- health tab (accounts + models) ----------

struct HealthTab: View {
    @ObservedObject var store: Store
    @AppStorage("healthView") private var view = "accounts"
    var body: some View {
        if let h = store.health {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $view) {
                    Text(L("Providers (\(h.accounts.count))", "Sağlayıcılar (\(h.accounts.count))")).tag("accounts")
                    Text(L("Models", "Modeller") + " (\(h.models.filter { $0.status != "idle" }.count))").tag("models")
                    Text(L("Fallbacks", "Yedekler") + " (\(h.chains.filter { $0.usable == 0 }.count) ⚠)").tag("chains")
                }
                .pickerStyle(.segmented).labelsHidden()
                if view == "models" {
                    ModelsView(models: h.models, now: h.now)
                } else if view == "chains" {
                    ChainsView(health: h)
                } else {
                    ForEach(h.accounts, id: \.provider) { a in AccountCard(acc: a, now: h.now) }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

/// "last value, 5 min ago · rate limited": shown wherever quota windows are the last known reading.
func staleLine(fetchedAt: Double?, code: String?, retryAt: Double?, now: Double) -> String {
    let age = fetchedAt.map { L("last value, \(span(now - $0)) ago", "son değer, \(span(now - $0)) önce") } ?? L("last value", "son değer")
    let why = code == "rate_limited" ? L("rate limited", "hız sınırı") : L("usage not readable right now", "kullanım şu an okunamıyor")
    let retry = (code == "rate_limited" ? retryAt : nil).flatMap { $0 > now ? L("retry in \(span($0 - now))", "\(span($0 - now)) sonra yeniden denenecek") : nil }
    return ([age, why] + (retry.map { [$0] } ?? [])).joined(separator: " · ")
}

/// /api/health still carries the English reason text (no code field there): render it in the app language.
func unavailableText(_ u: String) -> String {
    if u.hasPrefix("rate limited") {
        let http = u.range(of: #"HTTP \d+"#, options: .regularExpression).map { " (" + u[$0] + ")" } ?? ""
        return L("Rate limited\(http) — the provider refused the request; showing the last known values",
                 "Hız sınırı\(http) — sağlayıcı isteği geri çevirdi; son bilinen değerler gösteriliyor")
    }
    guard u.hasPrefix("usage not readable") else { return u }
    let http = u.range(of: #"HTTP \d+"#, options: .regularExpression).map { " (" + u[$0] + ")" } ?? ""
    return L("Usage not readable\(http) — the credential lacks permission or the provider did not answer",
             "Kullanım okunamıyor\(http) — kimlik bilgisinin izni yetmiyor ya da sağlayıcı yanıt vermedi")
}

func credState(_ c: Cred, now: Double) -> (String, Color) {
    if c.locked { return (L("limit reached", "limit doldu"), .red) }
    if c.status == "exhausted" { return (L("will retry", "tekrar denenecek"), .orange) }
    return accountStatus(c.status)
}

struct AccountCard: View {
    let acc: HAccount
    let now: Double
    var body: some View {
        let states = acc.credentials.map { credState($0, now: now) }
        let usable = acc.credentials.filter { !$0.locked }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pName(acc.provider)).font(.headline)
                Spacer()
                // "1 account · 2 credentials · 2 usable": a credential is not an account
                Chip(text: acc.credentials.isEmpty ? L("no credentials", "kimlik bilgisi yok")
                        : (acc.accounts_count.map { plural($0, "account", "accounts", tr: "hesap") + " · " } ?? "")
                            + plural(acc.credentials.count, "credential", "credentials", tr: "kimlik bilgisi") + " · "
                            + L("\(usable) usable", "\(usable) kullanılabilir"),
                     color: usable == 0 ? .red : states.contains { $0.1 != .green } ? .orange : .green)
            }
            if !acc.profiles.isEmpty || !acc.fallback_for.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !acc.profiles.isEmpty {
                        Text(L("Primary: \(acc.profiles.count) profiles", "Birincil: \(acc.profiles.count) profil")).help(acc.profiles.joined(separator: ", "))
                    }
                    if !acc.fallback_for.isEmpty {
                        Text(L("Fallback for: ", "Yedek olarak: ") + acc.fallback_for.joined(separator: ", ")).lineLimit(2)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("No profile uses this provider", "Hiçbir profil bu sağlayıcıyı kullanmıyor")).font(.caption).foregroundStyle(.secondary)
            }
            if let p = acc.plan { Text("Plan: \(p)").font(.caption) }
            if acc.stale == true {
                Text(staleLine(fetchedAt: acc.fetched_at, code: acc.unavailable_code, retryAt: acc.retry_at, now: now))
                    .font(.caption).foregroundStyle(.orange)
            } else if let u = acc.unavailable { Text(unavailableText(u)).font(.caption).foregroundStyle(.secondary) }
            ForEach(acc.windows.filter { $0.used != nil }, id: \.label) { w in
                QuotaRow(window: w, burn: nil, now: now)
            }
            ForEach(Array(acc.credentials.enumerated()), id: \.offset) { _, c in
                Divider()
                CredRow(c: c, now: now)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CredRow: View {
    let c: Cred
    let now: Double
    var body: some View {
        let st = credState(c, now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(c.label ?? L("credential", "kimlik bilgisi")).font(.callout.weight(.medium))
                Text([c.auth_type, credKind(c.source)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if c.verification == "unverified" { Chip(text: L("account unverified", "hesabı doğrulanamadı"), color: .orange) }
                Chip(text: st.0, color: st.1)
            }
            if c.status == "exhausted" || c.error_code != nil {
                Text(errorLine).font(.caption).foregroundStyle(c.locked ? .red : .orange).lineLimit(2)
            }
            if let u = c.exhausted_until, c.status == "exhausted" {
                Text(u > now ? L("Unlocks \(when(u, now: now))", "Açılış: \(when(u, now: now))")
                     : L("Lock lifted \(span(now - u)) ago; retried on the next request", "Kilit \(span(now - u)) önce kalktı; sonraki istekte yeniden denenecek"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let s = c.status_at, c.status == "exhausted" {
                Text(L("Limit hit \(when(s, now: now))", "Limit \(when(s, now: now)) doldu")).font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(c.model_cooldowns.sorted { $0.key < $1.key }, id: \.key) { m, until in
                Text(L("⏳ \(m) cooling down — \(when(until, now: now))", "⏳ \(m) beklemede — \(when(until, now: now))")).font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                // (the pool's request counter is not shown: it does not reflect real usage)
                if let e = c.expires_at {
                    Text(e > now ? L("token valid for \(span(e - now))", "token \(span(e - now)) geçerli") : L("token expired (refreshes)", "token süresi doldu (yenilenir)"))
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    var errorLine: String {
        var parts: [String] = []
        if let code = c.error_code { parts.append("HTTP \(Int(code))") }
        if let r = c.error_reason { parts.append(r) }
        let head = parts.joined(separator: " · ")
        if let m = c.error_message, !m.isEmpty { return head.isEmpty ? m : "\(head) — \(m)" }
        return head.isEmpty ? L("exhausted", "tükendi") : head
    }
}

struct ModelsView: View {
    let models: [HModel]
    let now: Double
    var body: some View {
        let problems = models.filter { ["failing", "account_exhausted", "cooldown", "degraded"].contains($0.status) }
        let healthy = models.filter { $0.status == "ok" }
        let idle = models.filter { $0.status == "idle" }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(["failing", "account_exhausted", "cooldown", "degraded", "ok", "idle"], id: \.self) { s in
                    let n = models.filter { $0.status == s }.count
                    if n > 0, let st = modelStatus(s) { Chip(text: "\(st.0) \(n)", color: st.1) }
                }
            }
            if !problems.isEmpty {
                SectionTitle(text: L("Needs attention", "Dikkat gerekenler"), trailing: L("last 24 h", "son 24 saat"))
                ForEach(problems) { m in ModelRow(m: m, now: now) }
            }
            if !healthy.isEmpty {
                SectionTitle(text: L("Healthy", "Sağlıklı"), trailing: L("last 24 h", "son 24 saat"))
                ForEach(healthy) { m in ModelRow(m: m, now: now) }
            }
            if !idle.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(idle) { m in ModelRow(m: m, now: now) }
                    }
                    .padding(.top, 4)
                } label: {
                    SectionTitle(text: L("Idle (\(idle.count))", "Boşta (\(idle.count))"), trailing: L("no calls in 24 h", "24 saattir çağrı yok"))
                }
            }
        }
    }
}

struct ModelRow: View {
    let m: HModel
    let now: Double
    var body: some View {
        let st = modelStatus(m.status) ?? (m.status, .secondary)
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(st.1).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(m.model).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if m.recovered { Chip(text: L("recovered", "toparlandı"), color: .teal) }
                    Chip(text: st.0, color: st.1)
                }
                Text([pName(m.provider), roles].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help((m.profiles + m.fallback_for.map { L("fallback: \($0)", "yedek: \($0)") }).joined(separator: "\n"))
                HStack(spacing: 10) {
                    Text(L("\(Int(m.calls_24h)) calls", "\(Int(m.calls_24h)) çağrı"))
                    if m.tokens_24h > 0 { Text(compact(m.tokens_24h) + L(" tokens", " token")) }
                    if m.cost_24h > 0 { Text(money(m.cost_24h)) }
                    if m.errors_24h > 0 {
                        Text(L("\(Int(m.errors_24h)) errors", "\(Int(m.errors_24h)) hata")
                             + (m.error_rate.map { L(String(format: " (%.0f%%)", $0 * 100), String(format: " (%%%.0f)", $0 * 100)) } ?? ""))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if !m.error_types.isEmpty {
                    Text(m.error_types.sorted { $0.value > $1.value }.map { "\($0.key) ×\(Int($0.value))" }.joined(separator: "  "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let e = m.last_error, e.at >= now - 86400 {
                    Text(L("Last error \(span(now - e.at)) ago: ", "Son hata \(span(now - e.at)) önce: ") + (e.summary ?? e.type ?? ""))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
                if let c = m.cooldown_until {
                    Text(L("⏳ Cooldown ends: \(when(c, now: now))", "⏳ Bekleme bitişi: \(when(c, now: now))")).font(.caption2).foregroundStyle(.orange)
                }
                if let ok = m.last_ok {
                    Text(L("Last successful call \(span(now - ok)) ago", "Son başarılı çağrı \(span(now - ok)) önce")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .font(.callout)
    }

    var roles: String? {
        var r: [String] = []
        if !m.profiles.isEmpty { r.append(m.profiles.count == 1 ? L("primary: \(m.profiles[0])", "birincil: \(m.profiles[0])") : L("primary: \(m.profiles.count) profiles", "birincil: \(m.profiles.count) profil")) }
        if !m.fallback_for.isEmpty { r.append(L("fallback: \(m.fallback_for.count)", "yedek: \(m.fallback_for.count)")) }
        return r.isEmpty ? nil : r.joined(separator: " · ")
    }
}

struct ChainsView: View {
    let health: HealthResp
    var body: some View {
        let broken = health.chains.filter { $0.usable == 0 }
        let fine = health.chains.filter { $0.usable > 0 }
        VStack(alignment: .leading, spacing: 10) {
            Text(L("When the primary model fails, Hermes tries the fallbacks in order; fallbacks on the same backend or with a full limit are skipped.",
                   "Ana model hata verdiğinde Hermes sırayla yedeklere geçer; aynı arka uca giden ya da limiti dolu yedekler atlanır."))
                .font(.caption).foregroundStyle(.secondary)
            if !broken.isEmpty {
                SectionTitle(text: L("Profiles without a working fallback", "Çalışan yedeği olmayan profiller"), trailing: "\(broken.count)")
                ForEach(broken) { c in ChainCard(chain: c, suggestions: suggestions(for: c), others: otherProviders(for: c)) }
            }
            if !fine.isEmpty {
                SectionTitle(text: L("Profiles with a fallback", "Yedeği olan profiller"), trailing: "\(fine.count)")
                ForEach(fine) { c in ChainCard(chain: c, suggestions: [], others: "") }
            }
        }
    }

    /// Healthy, recently used models on a different provider whose account is usable.
    func suggestions(for c: Chain) -> [HModel] {
        let usable = Set(health.accounts.filter { $0.credentials.contains { !$0.locked } }.map(\.provider))
        return health.models.filter {
            $0.provider != c.provider && usable.contains($0.provider) && $0.status == "ok" && $0.calls_24h > 0
                && !$0.model.contains("safety")
        }
        .sorted { $0.calls_24h > $1.calls_24h }
        .prefix(3).map { $0 }
    }

    /// When no proven model exists: other providers with a usable account, and how their models look.
    func otherProviders(for c: Chain) -> String {
        health.accounts.filter { $0.provider != c.provider && $0.credentials.contains { !$0.locked } }.map { a in
            let ms = health.models.filter { $0.provider == a.provider && !$0.model.contains("safety") }
            let note = ms.isEmpty ? L("never used yet", "henüz hiç kullanılmamış")
                : ms.contains { $0.status == "degraded" || $0.status == "failing" } ? L("degraded", "sorunlu") : L("idle", "boşta")
            return "\(pName(a.provider)) (\(note))"
        }.joined(separator: ", ")
    }
}

struct ChainCard: View {
    let chain: Chain
    let suggestions: [HModel]
    let others: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(chain.profile).font(.callout.weight(.semibold))
                Spacer()
                Chip(text: chain.usable == 0 ? L("no fallback", "yedek yok") : L("\(chain.usable) fallback", "\(chain.usable) yedek"), color: chain.usable == 0 ? .red : .green)
            }
            Text(L("Primary: ", "Ana: ") + "\(chain.model) · \(pName(chain.provider))").font(.caption).foregroundStyle(.secondary)
            if chain.fallbacks.isEmpty {
                Text(L("No fallback configured", "Yedek tanımlı değil")).font(.caption).foregroundStyle(.orange)
            }
            ForEach(Array(chain.fallbacks.enumerated()), id: \.offset) { i, f in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(i + 1).").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(f.model) · \(pName(f.provider))").font(.caption)
                        if let r = chainReason(f) {
                            Text(r).font(.caption2).foregroundStyle(f.state == "skip" ? .red : .orange)
                        }
                    }
                    Spacer()
                    Chip(text: f.state == "skip" ? L("skipped", "atlanır") : f.state == "risky" ? L("risky", "riskli") : L("ready", "hazır"),
                         color: f.state == "skip" ? .red : f.state == "risky" ? .orange : .green)
                }
            }
            if chain.usable == 0 && suggestions.isEmpty && !others.isEmpty {
                Text(L("No proven healthy alternative. Providers with a usable account: ", "Sağlıklı, denenmiş alternatif yok. Hesabı kullanılabilir sağlayıcılar: ") + others)
                    .font(.caption2).foregroundStyle(.teal)
            }
            if !suggestions.isEmpty {
                Text(L("Suggestion: ", "Öneri: ") + suggestions.map { "\($0.model) (\(pName($0.provider)))" }.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.teal)
                Text("config.yaml → fallback_providers").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

// ---------- notch island (MacBooks with a notch) ----------
//
// The notch splits the menu bar and swallows status items, so on those Macs Hermes can live *in* the notch:
// small "ears" beside the camera (quota rings left, running sessions right), events that pop down for a few
// seconds, a mini dashboard on hover and the full popover on click. Mouse events are only taken while the
// pointer is over the island, so menus underneath stay clickable.

func notchScreen() -> NSScreen? {
    NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
}

func displayMode() -> String { UserDefaults.standard.string(forKey: Pref.display) ?? "both" }

/// The island runs only on a Mac with a notch and unless "menu bar only" is chosen.
func islandEnabled() -> Bool { displayMode() != "menubar" && notchScreen() != nil }

/// The menu bar icon hides only for "notch only" on a Mac that really has a notch (never leave no UI at all).
func menuIconVisible() -> Bool { !(displayMode() == "island" && notchScreen() != nil) }

var islandSpring: Animation { motionOn() ? .spring(response: 0.38, dampingFraction: 0.72) : .easeInOut(duration: 0.15) }

struct IslandEvent: Identifiable {
    let id = UUID()
    let provider: String?   // logo inside a ring, else `symbol`
    let symbol: String
    let title: String
    let detail: String
    let tint: Color
    let gauge: Double?
    var open: OpenAction? = nil   // a click on the event opens this (session / card)
}

@MainActor
final class Island: ObservableObject {
    static let shared = Island()
    enum Mode { case compact, peek, event, hover }
    static var peekTime: TimeInterval { max(3, Pref.num(Pref.peekSec)) }
    @Published private(set) var event: IslandEvent?
    @Published var hover = false
    @Published private(set) var peeking = false
    @Published private(set) var highlight: String?   // provider or "sessions": pops once when it changed
    private var queue: [IslandEvent] = []
    private var timer: Timer?
    private var peekTimer: Timer?

    var mode: Mode { hover ? .hover : event != nil ? .event : peeking ? .peek : .compact }

    /// Small heads-up: show the ears (rings + session count) for 15 s and pop the part that changed.
    func peek(_ what: String) {
        guard islandEnabled(), Pref.on(Pref.islandEvents) else { return }
        withAnimation(islandSpring) {
            peeking = true
            highlight = what
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            withAnimation(islandSpring) { self?.highlight = nil }
        }
        peekTimer?.invalidate()
        peekTimer = Timer.scheduledTimer(withTimeInterval: Self.peekTime, repeats: false) { [weak self] _ in
            Task { @MainActor in withAnimation(islandSpring) { self?.peeking = false } }
        }
    }

    func push(_ e: IslandEvent) {
        guard islandEnabled(), Pref.on(Pref.islandEvents) else { return }
        if queue.count < 5 { queue.append(e) }
        if event == nil { advance() }
    }

    private func advance() {
        timer?.invalidate()
        guard !queue.isEmpty else {
            withAnimation(islandSpring) { event = nil }
            return
        }
        let e = queue.removeFirst()
        withAnimation(islandSpring) { event = e }
        timer = Timer.scheduledTimer(withTimeInterval: max(1.5, Pref.num(Pref.eventSec)), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }
}

enum IslandSize {
    static var earsAlways: Bool { UserDefaults.standard.string(forKey: Pref.islandEars) == "always" }
    static var ear: CGFloat { CGFloat(max(32, Pref.num(Pref.earWidth))) }
    static func of(_ mode: Island.Mode, notchW: CGFloat, notchH: CGFloat) -> CGSize {
        switch mode {
        // ears only while always-on; otherwise the island is exactly the notch (black on black: invisible)
        case .compact: return CGSize(width: earsAlways ? notchW + 2 * ear : notchW, height: notchH)
        case .peek: return CGSize(width: notchW + 2 * ear, height: notchH)
        case .event: return CGSize(width: max(notchW + 2 * ear, 390), height: notchH + 62)
        // width is used for layout; the height here only sizes the hover-detection rect (track()) — the visible
        // panel grows to its grouped session tree. Keep it generous so the mouse stays "inside" over tall content.
        case .hover: return CGSize(width: 460, height: notchH + 520)
        }
    }
}

/// Borderless panels can't become key by default, which leaves pickers, menus and scroll views inert.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Test builds only (both unset in the installed app): a second Agent Bar copy can run next to the installed one with its
/// own hook names (`local.agent.bar.island<suffix>`) and its windows one level above.
let TEST_HOOK_SUFFIX = ProcessInfo.processInfo.environment["AGENT_BAR_HOOK_SUFFIX"] ?? ""
let TEST_LEVEL_BOOST = ProcessInfo.processInfo.environment["AGENT_BAR_HOOK_SUFFIX"] == nil ? 0 : 1

@MainActor
final class IslandController {
    static let shared = IslandController()
    private var island: NSPanel?
    private var drop: NSPanel?          // full popover dropped from the notch
    private var monitors: [Any] = []
    private var dropMonitor: Any?
    private var dropKeyMonitor: Any?
    private var notch = (w: CGFloat(0), h: CGFloat(0), screen: NSRect.zero)
    private var pending: DispatchWorkItem?
    private var store: Store?
    private var started = false

    func start(store: Store) {
        guard !started else { return }
        started = true
        self.store = store
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in IslandController.shared.rebuild() }
        }
        // test hook: `object` = event | hover | compact | drop (used for screenshots)
        DistributedNotificationCenter.default().addObserver(forName: .init("local.agent.bar.island" + TEST_HOOK_SUFFIX), object: nil, queue: .main) { n in
            let what = n.object as? String
            Task { @MainActor in IslandController.shared.debug(what) }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("local.agent.bar.click" + TEST_HOOK_SUFFIX), object: nil, queue: .main) { n in
            let what = n.object as? String
            Task { @MainActor in IslandController.shared.debugClick(what) }
        }
        rebuild()
    }

    /// test hook, object = a Live row's session id (runs that row's click action, the same
    /// `Opener.open` a mouse click calls) | "icon" (the hover panel's window icon)
    private func debugClick(_ what: String?) {
        if what == "icon" { openWindow(); return }
        guard let what, let row = store?.live?.running.first(where: { $0.id == what }) else { return }
        Opener.open(row.open)
    }

    func rebuild() {
        island?.orderOut(nil)
        island = nil
        closeDrop()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        guard islandEnabled(), let s = notchScreen(), let store else { return }
        let w = s.frame.width - (s.auxiliaryTopLeftArea?.width ?? 0) - (s.auxiliaryTopRightArea?.width ?? 0)
        notch = (w, s.safeAreaInsets.top, s.frame)
        let size = CGSize(width: 500, height: notch.h + 680)  // tall enough for the hover's grouped session tree
        let p = NSPanel(contentRect: NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3 + TEST_LEVEL_BOOST)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.acceptsMouseMovedEvents = true
        p.contentView = NSHostingView(rootView: IslandView(store: store, island: .shared, notchW: notch.w, notchH: notch.h,
                                                           onOpenWindow: {
            IslandController.shared.openWindow()
        }))
        p.orderFrontRegardless()
        island = p
        let handler: (NSEvent) -> Void = { _ in Task { @MainActor in IslandController.shared.track() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { e in handler(e); return e }) { monitors.append(m) }
    }

    private func rect(_ mode: Island.Mode) -> NSRect {
        let sz = IslandSize.of(mode, notchW: notch.w, notchH: notch.h)
        return NSRect(x: notch.screen.midX - sz.width / 2, y: notch.screen.maxY - sz.height, width: sz.width, height: sz.height)
    }

    /// Hover in after a short dwell (so passing over the ears on the way to a menu doesn't pop it), out after a grace.
    private func track() {
        guard island != nil, drop == nil else { return }
        let isl = Island.shared
        let inside = rect(isl.mode).insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        guard inside != isl.hover else {
            pending?.cancel()
            pending = nil
            return
        }
        guard pending == nil else { return }
        let task = DispatchWorkItem {
            Task { @MainActor in
                IslandController.shared.pending = nil
                withAnimation(islandSpring) { isl.hover = inside }
                IslandController.shared.island?.ignoresMouseEvents = !inside
            }
        }
        pending = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? max(0.05, Pref.num(Pref.hoverDelay)) : 0.4), execute: task)
    }

    func toggleDrop() { drop == nil ? openDrop() : closeDrop() }

    /// The hover panel's "open window" icon (the notch itself opens nothing): the full panel dropped from the notch,
    /// or the web dashboard — the "Window icon opens" setting.
    func openWindow() {
        if Pref.str(Pref.islandClick) == "web" {
            withAnimation(islandSpring) { Island.shared.hover = false }
            island?.ignoresMouseEvents = true
            openPanel()
        } else {
            toggleDrop()
        }
    }

    private func openDrop() {
        guard let store, drop == nil else { return }
        let size = CGSize(width: 430, height: 660)
        let p = KeyPanel(contentRect: NSRect(x: notch.screen.midX - size.width / 2, y: notch.screen.maxY - notch.h - size.height - 6,
                                             width: size.width, height: size.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2 + TEST_LEVEL_BOOST)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.becomesKeyOnlyIfNeeded = false
        let root = Popover(store: store)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        p.contentView = NSHostingView(rootView: root)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)  // key (without activating the app) so pickers, menus and scrolling respond
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = motionOn() ? 0.18 : 0
            p.animator().alphaValue = 1
        }
        drop = p
        withAnimation(islandSpring) { Island.shared.hover = false }
        // The island window sits above the top of the panel (header, tabs, ⚙): let clicks fall through to it.
        // A click on the notch then lands in another app, so the global monitor below closes the panel.
        island?.ignoresMouseEvents = true
        // click anywhere else closes it
        dropMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in IslandController.shared.closeDrop() }
        }
        dropKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            guard e.keyCode == 53 else { return e }  // Esc
            Task { @MainActor in IslandController.shared.closeDrop() }
            return nil
        }
    }

    func closeDrop() {
        if let m = dropMonitor { NSEvent.removeMonitor(m) }
        if let m = dropKeyMonitor { NSEvent.removeMonitor(m) }
        dropMonitor = nil
        dropKeyMonitor = nil
        drop?.orderOut(nil)
        drop = nil
        island?.ignoresMouseEvents = !Island.shared.hover
    }

    private func debug(_ what: String?) {
        switch what {
        case "event":
            Island.shared.push(IslandEvent(provider: "anthropic", symbol: "gauge.with.dots.needle.67percent",
                                           title: "Anthropic (Claude) · \(wName("Current session"))  58%",
                                           detail: L("+10.1%/h · full in 4h 9m · resets in 1h 53m", "+%10.1/saat · dolma 4s 9dk · sıfırlanma 1s 53dk"),
                                           tint: .green, gauge: 0.58))
        case "peek": Island.shared.peek("anthropic")
        case "peek-sessions": Island.shared.peek("sessions")
        case "hover": withAnimation(islandSpring) { Island.shared.hover = true }
        case "compact": withAnimation(islandSpring) { Island.shared.hover = false }
        case "drop": toggleDrop()
        default: break
        }
    }
}

/// Provider logo inside one or two usage rings (outer = first window), coloured by level.
struct RingGauge: View {
    let provider: String
    let fractions: [Double]
    var size: CGFloat = 20
    var body: some View {
        ZStack {
            ForEach(Array(fractions.prefix(2).enumerated()), id: \.offset) { i, f in
                let inset = CGFloat(i) * size * 0.2
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 2).padding(inset)
                Circle().trim(from: 0, to: min(max(f, 0), 1))
                    .stroke(levelColor(f * 100), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(inset)
                    .animation(motionOn() ? .easeOut(duration: 0.6) : nil, value: f)
            }
            if let ic = providerIcon(provider) {
                Image(nsImage: ic).renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: size * (fractions.count > 1 ? 0.34 : 0.48))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The "open window" icon in the hover panel's top-right corner: the only way (besides a session row) to open
/// something from the notch.
struct OpenWindowButton: View {
    let web: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.8))
                .frame(width: 24, height: 22)
                .background(Color.white.opacity(hovered ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(web ? L("Open the web dashboard", "Web panelini aç") : L("Open the full panel", "Tam paneli aç"))
        .accessibilityLabel(web ? L("Open the web dashboard", "Web panelini aç") : L("Open the full panel", "Tam paneli aç"))
    }
}

struct IslandView: View {
    @ObservedObject var store: Store
    @ObservedObject var island: Island
    let notchW: CGFloat
    let notchH: CGFloat
    let onOpenWindow: () -> Void
    @AppStorage(Pref.islandClick) private var iconOpens = "panel"
    @AppStorage(Pref.barQuotas) private var quotas = "auto"
    @AppStorage(Pref.lang) private var lang = "en"
    @AppStorage(Pref.islandEars) private var earsSetting = "hover"
    @AppStorage(Pref.earWidth) private var earWidth = 64.0
    @AppStorage(Pref.rightEar) private var rightEar = "sessions"
    @AppStorage(Pref.hoverQuotas) private var hoverQuotas = true
    @AppStorage(Pref.hoverSessions) private var hoverSessions = true
    @AppStorage(Pref.hoverCost) private var hoverCost = true

    var groups: [(provider: String, fractions: [Double], stale: Bool)] {
        var order: [String] = []
        var fr: [String: [Double]] = [:]
        for c in store.chosenQuotas(quotas.split(separator: ",").map(String.init)) {
            if fr[c.provider] == nil { order.append(c.provider) }
            fr[c.provider, default: []].append((c.window.used ?? 0) / 100)
        }
        return order.prefix(2).map { ($0, fr[$0]!, store.isStale($0)) }
    }

    var body: some View {
        let sz = IslandSize.of(island.mode, notchW: notchW, notchH: notchH)
        let r: CGFloat = island.mode == .compact ? 10 : 24
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, style: .continuous)
                    .fill(.black)
                VStack(spacing: 0) {
                    if island.mode != .compact || IslandSize.earsAlways {
                        ears.frame(height: notchH).transition(.opacity)
                    }
                    switch island.mode {
                    case .event: if let e = island.event { eventView(e).transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top))) }
                    case .hover: hoverView.transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                    case .compact, .peek: EmptyView()
                    }
                }
            }
            // hover grows with its grouped session tree (capped); other modes keep their fixed height
            .frame(width: sz.width, height: island.mode == .hover ? nil : sz.height)
            .contentShape(Rectangle())
            .onTapGesture {
                // Clicking the notch opens no panel. Only an alert about a session / card is clickable: it opens that.
                // (The full panel opens from the icon in the hover panel's corner.)
                if let o = island.event?.open, o.canOpen { Opener.open(o) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.locale, appLocale())
        .environment(\.colorScheme, .dark)
        .id(lang)
    }

    /// Left: quota rings; right: running sessions — both sit beside the camera, never under it.
    var ears: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(groups, id: \.provider) { g in
                    RingGauge(provider: g.provider, fractions: g.fractions, size: 20)
                        .opacity(g.stale ? 0.55 : 1)
                        .help(g.stale ? L("Last known value (rate limited)", "Son değer (hız sınırı)") : "")
                        .scaleEffect(island.highlight == g.provider ? 1.3 : 1)
                        .shadow(color: island.highlight == g.provider ? levelColor((g.fractions.first ?? 0) * 100) : .clear, radius: 6)
                }
            }
            .frame(width: IslandSize.ear, alignment: .center)
            Spacer(minLength: notchW)
            HStack(spacing: 5) {
                if store.offline {
                    Image(systemName: "bolt.horizontal.circle").foregroundStyle(.red)
                } else if rightEar == "tokens" {
                    Image(systemName: "waveform").font(.system(size: 10, weight: .semibold)).foregroundStyle(.cyan)
                    Text(compact(store.live?.last1m)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                } else if rightEar == "cost" {
                    Text(store.month.map { money(store.spend($0, day: isoDay(0))) } ?? "—")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                        .minimumScaleFactor(0.7).lineLimit(1)
                } else if rightEar == "sessions" {
                    // sessions waiting for your approval first (orange), then working (pulsing), then a dim "+n"
                    let c = store.counts
                    let approvals = c.needsApproval
                    if approvals > 0 {
                        Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                        Text("\(approvals)").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.orange)
                    }
                    let working = c.working, idle = max(0, c.open - c.working - approvals)
                    if working > 0 { PulseDot(color: .green, animated: island.mode != .compact).frame(width: 6, height: 6) }
                    else { Circle().fill(idle > 0 ? Color.green.opacity(0.45) : .gray).frame(width: 6, height: 6) }
                    Text("\(working)").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(working > 0 ? .white : .white.opacity(0.5))
                        .contentTransition(.numericText())
                        .animation(motionOn() ? .snappy : nil, value: working)
                    if idle > 0 {
                        Text("+\(idle)").font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .scaleEffect(island.highlight == "sessions" ? 1.3 : 1)
            .shadow(color: island.highlight == "sessions" ? .green : .clear, radius: 6)
            .frame(width: IslandSize.ear, alignment: .center)
        }
        .padding(.horizontal, island.mode == .compact || island.mode == .peek ? 0 : 14)
    }

    func eventView(_ e: IslandEvent) -> some View {
        HStack(spacing: 12) {
            if let p = e.provider, let g = e.gauge {
                RingGauge(provider: p, fractions: [g], size: 34)
            } else {
                Image(systemName: e.symbol).font(.system(size: 20)).foregroundStyle(e.tint).frame(width: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(e.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    var hoverView: some View {
        let options = store.quotaOptions
        return VStack(alignment: .leading, spacing: 7) {
            // top row: what a click does, and the "open window" icon in the right corner
            HStack(spacing: 6) {
                Text(L("click a row to open it", "satıra tıkla: aç")).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 4)
                OpenWindowButton(web: iconOpens == "web", action: onOpenWindow)
            }
            .padding(.top, -2)
            ForEach(Array((hoverQuotas ? options : []).prefix(4).enumerated()), id: \.offset) { _, o in
                let used = o.window.used ?? 0
                HStack(spacing: 8) {
                    if let ic = providerIcon(o.provider) {
                        Image(nsImage: ic).renderingMode(.template).resizable().scaledToFit().frame(width: 12).foregroundStyle(.white)
                    }
                    Text("\(pName(o.provider)) · \(wName(o.window.label))").font(.system(size: 11.5)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 4)
                    Capsule().fill(Color.white.opacity(0.14)).frame(width: 70, height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(levelColor(used)).frame(width: 70 * min(used, 100) / 100, height: 4) }
                    Text("\(Int(used))%").font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            if hoverQuotas && !options.isEmpty {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
            }
            HStack(spacing: 10) {
                if hoverSessions {
                    let c = store.counts
                    Label(L("\(c.working) working", "\(c.working) çalışıyor"), systemImage: "bolt.horizontal.circle.fill")
                        .foregroundStyle(c.working == 0 ? .gray : .green)
                    if c.needsApproval > 0 {
                        Text(L("\(c.needsApproval) needs approval", "\(c.needsApproval) onay bekliyor")).foregroundStyle(.orange).fontWeight(.semibold)
                    }
                    if c.yourTurn > 0 {
                        Text(L("\(c.yourTurn) your turn", "\(c.yourTurn) sıra sende")).foregroundStyle(.white.opacity(0.6))
                    }
                    if c.stalled > 0 {
                        Text(L("\(c.stalled) stalled?", "\(c.stalled) takıldı mı?")).foregroundStyle(.yellow.opacity(0.8))
                    }
                }
                if hoverCost, let m = store.month {
                    Text(L("API-equiv. today ", "bugün API karşılığı ") + money(store.spend(m, day: isoDay(0))) + L(" (est.)", " (tahmini)")).foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
            }
            .font(.system(size: 11))
            // an alert that is still on (it takes over the hover): click opens its session / card
            if let e = island.event, let o = e.open, o.canOpen {
                HStack(spacing: 8) {
                    Image(systemName: e.symbol).foregroundStyle(e.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(e.detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: o.icon).foregroundStyle(.white.opacity(0.6))
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .openable(o)
            }
            if hoverSessions && !store.approvals.isEmpty {
                ApprovalBanner(items: store.approvals, now: store.live?.now ?? Date().timeIntervalSince1970, dense: true)
            }
            if let t = store.toast {
                Text(t).font(.system(size: 10.5)).foregroundStyle(.white).lineLimit(3)
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            }
            if hoverSessions && !store.mains.isEmpty {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 1)
                // all sessions, scrollable (the island takes mouse events while hovered)
                ScrollView(.vertical, showsIndicators: store.mains.count > HOVER_SESSION_CAP) {
                    SessionGroups(mains: store.mains, subs: store.subs, now: store.live?.now ?? Date().timeIntervalSince1970, dense: true)
                        .padding(.trailing, 6)
                        .environment(\.calmMotion, true)
                }
                .frame(maxHeight: .infinity)
            } else if hoverSessions {
                Text(L("No open sessions", "Açık oturum yok")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }
}

// ---------- popover shell ----------

struct LoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    var body: some View {
        Toggle(L("Launch at login", "Girişte başlat"), isOn: Binding(get: { on }, set: { v in
            do {
                if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {}
            on = SMAppService.mainApp.status == .enabled
        }))
    }
}

// ---------- settings tab ----------

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    var note: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon).font(.callout.weight(.semibold))
                Spacer()
                if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Settings rows: label on the left, switch on the right (the stock switch style hugs the label).
struct TrailingSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label.font(.callout)
            Spacer(minLength: 8)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// Label + current value on one line, slider below.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: range, step: step).controlSize(.small)
        }
    }
}

/// Segmented picker with its label on the left, or above it when the options don't fit on one line
/// (long English labels would otherwise squeeze the label to nothing).
struct SegmentRow<Content: View>: View {
    let title: String
    @ViewBuilder var picker: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(title).font(.callout).fixedSize()
                Spacer(minLength: 6)
                picker.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout)
                picker.pickerStyle(.segmented).labelsHidden()
            }
        }
    }
}

func seconds(_ v: Double) -> String { v < 1 ? String(format: L("%.2f s", "%.2f sn"), v) : L("\(Int(v)) s", "\(Int(v)) sn") }

struct SettingsTab: View {
    @ObservedObject var store: Store
    // appearance
    @AppStorage(Pref.display) private var display = "both"
    @AppStorage(Pref.lang) private var lang = "en"
    @AppStorage(Pref.barMotion) private var motion = true
    // menu bar
    @AppStorage(Pref.barSpark) private var spark = true
    @AppStorage(Pref.barCount) private var count = true
    @AppStorage(Pref.barTokens) private var tokens = false
    @AppStorage(Pref.barLeft) private var left = false
    @AppStorage(Pref.barQuotas) private var quotas = "auto"
    @AppStorage(Pref.barAutoCollapse) private var autoCollapse = true
    @AppStorage(Pref.stepPct) private var stepPct = 2.0
    @AppStorage(Pref.holdSec) private var holdSec = 20.0
    // island
    @AppStorage(Pref.islandEars) private var islandEars = "hover"
    @AppStorage(Pref.rightEar) private var rightEar = "sessions"
    @AppStorage(Pref.earWidth) private var earWidth = 64.0
    @AppStorage(Pref.islandEvents) private var islandEvents = true
    @AppStorage(Pref.peekSec) private var peekSec = 15.0
    @AppStorage(Pref.eventSec) private var eventSec = 4.5
    @AppStorage(Pref.hoverDelay) private var hoverDelay = 0.22
    @AppStorage(Pref.hoverQuotas) private var hoverQuotas = true
    @AppStorage(Pref.hoverSessions) private var hoverSessions = true
    @AppStorage(Pref.hoverCost) private var hoverCost = true
    @AppStorage(Pref.islandClick) private var islandClick = "panel"
    // notifications & budget
    @AppStorage(Pref.notifyQuota) private var nQuota = true
    @AppStorage(Pref.notifyKanban) private var nKanban = true
    @AppStorage(Pref.notifyHealth) private var nHealth = true
    @AppStorage(Pref.notifyAgents) private var nAgents = true
    @AppStorage(Pref.notifySessions) private var nSessions = false
    @AppStorage(Pref.notifyBudget) private var nBudget = true
    @AppStorage(Pref.budgetDay) private var budgetDay = 0.0
    @AppStorage(Pref.budgetMonth) private var budgetMonth = 0.0
    // general
    @AppStorage(Pref.liveEvery) private var liveEvery = LIVE_EVERY
    @AppStorage(Pref.autoStart) private var autoStart = true
    @State private var armed = false

    var hasNotch: Bool { notchScreen() != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            appearance
            if display != "island" || !hasNotch { menuBar }
            if hasNotch && display != "menubar" { island }
            notifications
            general
        }
        .toggleStyle(TrailingSwitch())
        .controlSize(.small)
    }

    var appearance: some View {
        SettingsSection(title: L("Appearance", "Görünüm"), icon: "paintbrush") {
            if hasNotch {
                SegmentRow(title: L("Show in", "Nerede")) {
                    Picker("", selection: Binding(get: { display }, set: { v in
                        display = v
                        IslandController.shared.rebuild()
                    })) {
                        Text(L("Notch + menu bar", "Çentik + menü")).tag("both")
                        Text(L("Notch", "Çentik")).tag("island")
                        Text(L("Menu bar", "Menü")).tag("menubar")
                    }
                }
            }
            SegmentRow(title: L("Language", "Dil")) {
                Picker("", selection: $lang) {
                    Text("English").tag("en")
                    Text("Türkçe").tag("tr")
                }
            }
            Toggle(L("Animations", "Animasyonlar"), isOn: $motion)
        }
    }

    var menuBar: some View {
        SettingsSection(title: L("Menu bar", "Menü çubuğu"), icon: "menubar.rectangle") {
            Toggle(L("Token sparkline", "Token grafiği"), isOn: $spark)
            Toggle(L("Running session count", "Çalışan oturum sayısı"), isOn: $count)
            Toggle(L("Tokens in the last minute", "Son 1 dk token"), isOn: $tokens)
            SegmentRow(title: L("Percentage", "Yüzde")) {
                Picker("", selection: $left) {
                    Text(L("Used", "Kullanılan")).tag(false)
                    Text(L("Left", "Kalan")).tag(true)
                }
            }
            Divider()
            Text(L("Quotas to show", "Gösterilecek kotalar")).font(.caption).foregroundStyle(.secondary)
            Toggle(L("Auto: fullest usable quota", "Otomatik: en dolu kullanılabilir kota"), isOn: quotaBinding("auto"))
            ForEach(store.quotaOptions, id: \.key) { o in
                Toggle(isOn: quotaBinding(o.key)) {
                    HStack(spacing: 6) {
                        if let ic = providerIcon(o.provider) {
                            Image(nsImage: ic).renderingMode(.template).resizable().scaledToFit().frame(width: 12)
                        }
                        Text("\(pName(o.provider)) · \(wName(o.window.label))")
                        Text(L("\(Int(o.window.used ?? 0))%", "%\(Int(o.window.used ?? 0))")).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Divider()
            Toggle(L("Collapse steady quotas to rings", "Sabit kotaları halkaya daralt"), isOn: $autoCollapse)
            SegmentRow(title: L("Reopen every", "Şu kadar değişince aç")) {
                Picker("", selection: $stepPct) {
                    Text("1%").tag(1.0)
                    Text("2%").tag(2.0)
                    Text("5%").tag(5.0)
                    Text("10%").tag(10.0)
                }
            }
            .disabled(!autoCollapse)
            SliderRow(title: L("Stay open for", "Açık kalma süresi"), value: $holdSec, range: 5...60, step: 5, format: seconds)
                .disabled(!autoCollapse)
        }
    }

    var island: some View {
        SettingsSection(title: L("Notch island", "Çentik adası"), icon: "rectangle.topthird.inset.filled") {
            SegmentRow(title: L("Rings & count", "Halkalar")) {
                Picker("", selection: $islandEars) {
                    Text(L("On hover", "Üzerine gelince")).tag("hover")
                    Text(L("Always", "Her zaman")).tag("always")
                }
            }
            SegmentRow(title: L("Right side", "Sağ taraf")) {
                Picker("", selection: $rightEar) {
                    Text(L("Sessions", "Oturum")).tag("sessions")
                    Text(L("Tokens/min", "Token/dk")).tag("tokens")
                    Text(L("API cost", "API karşılığı")).tag("cost")
                    Text(L("None", "Yok")).tag("none")
                }
            }
            SliderRow(title: L("Side width", "Yan genişlik"), value: $earWidth, range: 40...96, step: 4,
                      format: { "\(Int($0)) pt" })
            Divider()
            Toggle(L("Pop alerts out of the notch", "Uyarıları çentikten göster"), isOn: $islandEvents)
            SliderRow(title: L("Peek on change for", "Değişince görünme süresi"), value: $peekSec, range: 5...30, step: 1, format: seconds)
                .disabled(!islandEvents)
            SliderRow(title: L("Alerts stay for", "Uyarı görünme süresi"), value: $eventSec, range: 2...10, step: 0.5, format: seconds)
                .disabled(!islandEvents)
            SliderRow(title: L("Hover delay", "Üzerine gelme gecikmesi"), value: $hoverDelay, range: 0...1, step: 0.05, format: seconds)
            Divider()
            Text(L("Hover panel shows", "Üzerine gelince görünenler")).font(.caption).foregroundStyle(.secondary)
            Toggle(L("Quotas", "Kotalar"), isOn: $hoverQuotas)
            Toggle(L("Running sessions", "Çalışan oturumlar"), isOn: $hoverSessions)
            Toggle(L("Today's API-equivalent (estimate)", "Bugünkü API karşılığı (tahmini)"), isOn: $hoverCost)
            SegmentRow(title: L("Window icon opens", "Pencere ikonu açar")) {
                Picker("", selection: $islandClick) {
                    Text(L("Full panel", "Tam panel")).tag("panel")
                    Text(L("Web dashboard", "Web paneli")).tag("web")
                }
            }
            Text(L("Clicking the notch itself opens nothing; the icon in the hover panel's corner does.", "Çentiğe tıklamak bir şey açmaz; üzerine gelince köşede çıkan ikon açar."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    var notifications: some View {
        SettingsSection(title: L("Notifications & budget", "Bildirimler ve bütçe"), icon: "bell.badge") {
            Toggle(L("Quota 80% / 95% and filling soon", "Kota %80 / %95 ve yakında dolacak"), isOn: $nQuota)
            Toggle(L("Model failing / account limit", "Model hatası / hesap limiti"), isOn: $nHealth)
            Toggle(L("Agents: finished, approval, stuck, loop, big context", "Ajanlar: bitti, onay, takıldı, döngü, büyük bağlam"), isOn: $nAgents)
            Toggle(L("Kanban card blocked / failing", "Kanban kartı bloklandı / hata"), isOn: $nKanban)
            Toggle(L("Session ended", "Oturum bitti"), isOn: $nSessions)
            Toggle(L("Budget 80% / 100%", "Bütçe %80 / %100"), isOn: $nBudget)
            Divider()
            budgetField(L("Daily budget", "Günlük bütçe"), $budgetDay)
            budgetField(L("Monthly budget", "Aylık bütçe"), $budgetMonth)
            Text(L("0 = off · Hermes + CLI estimated API cost", "0 = kapalı · Hermes + CLI tahmini API karşılığı"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    func budgetField(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Text("$").foregroundStyle(.secondary)
            TextField("0", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 90)
        }
    }

    var general: some View {
        SettingsSection(title: L("General", "Genel"), icon: "gearshape") {
            SliderRow(title: L("Live refresh every", "Canlı yenileme sıklığı"), value: $liveEvery, range: 2...30, step: 1, format: seconds)
            Toggle(L("Start the dashboard server if it is down", "Panel sunucusu kapalıysa başlat"), isOn: $autoStart)
            LoginToggle()
            HStack {
                Button(L("Refresh quotas now", "Kotaları şimdi yenile")) { store.refreshQuotasNow() }
                Button(L("Open web dashboard", "Web panelini aç")) { openPanel() }
                Spacer()
                Button(L("Quit", "Çık"), role: .destructive) { NSApp.terminate(nil) }
            }
            .controlSize(.regular)
            Divider()
            HStack {
                Button(armed ? L("Sure? Click again to reset", "Emin misin? Sıfırlamak için tekrar tıkla")
                             : L("Restore defaults", "Varsayılanlara dön")) {
                    if armed {
                        Pref.restoreDefaults()
                        IslandController.shared.rebuild()
                        armed = false
                    } else {
                        armed = true
                        // disarm on its own so a stray second click much later can't reset
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { armed = false }
                    }
                }
                .tint(armed ? .red : nil)
                .controlSize(.regular)
                Spacer()
            }
            Text(L("Resets every setting on this page except the language.", "Dil hariç bu sayfadaki tüm ayarları sıfırlar."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Toggle one quota key in the comma-joined selection (order of selection = order in the bar).
    func quotaBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { quotas.split(separator: ",").map(String.init).contains(key) }, set: { on in
            var keys = quotas.split(separator: ",").map(String.init).filter { $0 != key }
            if on { keys.append(key) }
            quotas = keys.joined(separator: ",")
        })
    }
}

struct Popover: View {
    @ObservedObject var store: Store
    @AppStorage("tab") private var tab = "live"
    @AppStorage("lastTab") private var lastTab = "live"
    @AppStorage(Pref.lang) private var lang = "en"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(store.offline ? Color.red : Color.green).frame(width: 8, height: 8)
                Text("Agent Monitor").font(.headline)
                Spacer()
                if let u = store.updated {
                    Text(u, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                Button {
                    if tab == "settings" {
                        tab = lastTab == "settings" ? "live" : lastTab
                    } else {
                        lastTab = tab
                        tab = "settings"
                    }
                } label: {
                    Image(systemName: tab == "settings" ? "gearshape.fill" : "gearshape")
                        .foregroundStyle(tab == "settings" ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.borderless)
                .help(tab == "settings" ? L("Back", "Geri") : L("Settings", "Ayarlar"))
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            ScanLine(active: store.syncing && motionOn())

            Picker("", selection: $tab) {
                Text(L("Live", "Canlı")).tag("live")
                Text(L("Quotas", "Kotalar")).tag("quota")
                Text(L("Health", "Sağlık")).tag("health")
                Text(L("Usage", "Kullanım")).tag("usage")
                Text("Kanban").tag("kanban")
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 14).padding(.bottom, 10)

            Divider()
            ScrollView {
                Group {
                    if tab == "settings" {
                        SettingsTab(store: store)
                    } else if store.offline {
                        VStack(spacing: 10) {
                            Label(L("Cannot reach the dashboard server", "Panel sunucusuna ulaşılamıyor"), systemImage: "exclamationmark.triangle")
                            Button(L("Start dashboard", "Paneli başlat")) { openPanel() }
                        }
                        .frame(maxWidth: .infinity).padding(.top, 40)
                    } else if store.live == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        switch tab {
                        case "quota": QuotasTab(store: store)
                        case "health": HealthTab(store: store)
                        case "usage": UsageTab(store: store)
                        case "kanban": KanbanTab(store: store)
                        default: LiveTab(store: store)
                        }
                    }
                }
                .padding(14)
            }
            .frame(height: 540)

            Divider()
            HStack {
                Button(L("Open dashboard", "Paneli aç")) { openPanel() }
                Spacer()
                Text(L("live \(Int(Pref.num(Pref.liveEvery)))s · summary \(Int(SLOW_EVERY))s", "canlı \(Int(Pref.num(Pref.liveEvery))) sn · özet \(Int(SLOW_EVERY)) sn")).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 430)
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                Text(t).font(.caption).foregroundStyle(.white).lineLimit(4).multilineTextAlignment(.leading)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 52).padding(.horizontal, 14)
                    .transition(.opacity)
                    .accessibilityLabel(t)
            }
        }
        .environment(\.locale, appLocale())
        .id(lang)  // rebuild every view when the language changes
        .onAppear { store.refreshAll() }
    }
}

@main
struct AgentBarApp: App {
    @StateObject private var store: Store
    @AppStorage(Pref.display) private var display = "both"  // observed so the icon follows the setting

    init() {
        Pref.register()
        // SwiftUI may call App.init more than once: share one Store so the island and the menu use the same one
        let s = Store.main
        _store = StateObject(wrappedValue: s)
        DispatchQueue.main.async { IslandController.shared.start(store: s) }
    }

    /// Follows ⚙ → Show Hermes in (see menuIconVisible()).
    var showIcon: Binding<Bool> {
        Binding(get: { _ = display; return menuIconVisible() }, set: { _ in })
    }

    var body: some Scene {
        MenuBarExtra(isInserted: showIcon) {
            Popover(store: store)
        } label: {
            BarLabel(store: store, anim: store.anim)
        }
        .menuBarExtraStyle(.window)
    }
}
