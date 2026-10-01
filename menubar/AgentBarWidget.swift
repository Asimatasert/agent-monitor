// Agent Bar widgets (WidgetKit extension embedded in Agent Bar.app): quota rings, quota bars, running sessions,
// today's cost / budget and model problems, read from the local Agent Monitor API. Agent Bar reloads the
// timelines when a quota moves or a session starts; otherwise macOS refreshes about every 15 minutes.
// Sandboxed with network-client only, so it reads the API and nothing else (language follows the system).
import SwiftUI
import WidgetKit

private let API = "http://127.0.0.1:8777"

// ---------- data (subset of the API) ----------

struct WQuotaWindow: Decodable { let label: String; let used: Double?; let reset: Double? }
struct WQuotaItem: Decodable { let provider: String; let windows: [WQuotaWindow]? }
struct WQuotas: Decodable { let items: [WQuotaItem]? }
struct WSession: Decodable { let title: String?; let status: String; let subagent: Bool; let source: String?; let profile: String?; let working: Bool?; let state: String? }
struct WLive: Decodable { let running: [WSession]; let quotas: WQuotas?; let cost_60m: Double? }
struct WModel: Decodable { let model: String; let provider: String; let status: String }
struct WHealth: Decodable { let models: [WModel] }
struct WTC: Decodable { let cost: Double? }
struct WUDay: Decodable { let day: String; let by: [String: WTC] }
struct WCliDay: Decodable { let day: String; let cost: [String: Double] }
struct WUsage: Decodable { let daily: [WUDay] }
struct WClis: Decodable { let daily: [WCliDay] }
struct WOverview: Decodable { let usage: WUsage; let clis: WClis }

struct Snapshot {
    struct Quota: Identifiable { let id: String; let provider: String; let window: String; let used: Double; let reset: Double? }
    var quotas: [Quota] = []
    var running = 0
    var working = 0
    var approvals = 0
    var subagents = 0
    var titles: [String] = []
    var today: Double?
    var month: Double?
    var problems: [WModel] = []
    var offline = false

    static let placeholder = Snapshot(
        quotas: [Quota(id: "a|s", provider: "anthropic", window: "Current session", used: 62, reset: nil),
                 Quota(id: "a|w", provider: "anthropic", window: "Current week", used: 38, reset: nil),
                 Quota(id: "c|w", provider: "openai-codex", window: "Current week", used: 21, reset: nil)],
        running: 2, subagents: 1, titles: ["Refactor auth middleware", "Fix flaky checkout test"], today: 42.1, month: 910)
}

private func get<T: Decodable>(_ path: String, _ type: T.Type) async throws -> T {
    var req = URLRequest(url: URL(string: API + path)!)
    req.timeoutInterval = 8
    let (data, _) = try await URLSession.shared.data(for: req)
    return try JSONDecoder().decode(T.self, from: data)
}

private func isoDay(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
}

func loadSnapshot() async -> Snapshot {
    guard let live = try? await get("/api/live", WLive.self) else { return Snapshot(offline: true) }
    var s = Snapshot()
    for item in live.quotas?.items ?? [] {
        for w in item.windows ?? [] {
            if let u = w.used { s.quotas.append(.init(id: item.provider + "|" + w.label, provider: item.provider, window: w.label, used: u, reset: w.reset)) }
        }
    }
    let mains = live.running.filter { $0.status == "running" && !$0.subagent }
    s.running = mains.count
    s.working = mains.filter { $0.working == true }.count
    s.approvals = mains.filter { $0.state == "needs_approval" }.count
    s.subagents = live.running.filter { $0.status == "running" && $0.subagent }.count
    s.titles = mains.compactMap(\.title)
    let today = Date()
    let first = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: today))!
    if let o = try? await get("/api/overview?from=\(isoDay(first))&to=\(isoDay(today))", WOverview.self) {
        func spend(_ day: String?) -> Double {
            o.usage.daily.filter { day == nil || $0.day == day }.reduce(0) { $0 + $1.by.values.reduce(0) { $0 + ($1.cost ?? 0) } }
                + o.clis.daily.filter { day == nil || $0.day == day }.reduce(0) { $0 + $1.cost.values.reduce(0, +) }
        }
        s.today = spend(isoDay(today))
        s.month = spend(nil)
    }
    if let h = try? await get("/api/health", WHealth.self) {
        s.problems = h.models.filter { ["failing", "degraded", "account_exhausted", "cooldown"].contains($0.status) }
    }
    return s
}

// ---------- helpers ----------

let isTR = (Locale.preferredLanguages.first ?? "en").hasPrefix("tr")
func T(_ en: String, _ tr: String) -> String { isTR ? tr : en }

/// "anthropic#work" = one of several accounts of a provider: shown as "Claude · work".
func providerName(_ p: String) -> String {
    let parts = p.split(separator: "#", maxSplits: 1).map(String.init)
    let base = ["anthropic": "Claude", "openai-codex": "Codex", "copilot": "Copilot", "gemini": "Gemini", "nvidia": "NVIDIA",
                "openrouter": "OpenRouter"][parts[0]] ?? parts[0]
    return parts.count > 1 ? "\(base) · \(parts[1])" : base
}

func windowName(_ w: String) -> String {
    switch w {
    case "Current session": return T("Session", "Oturum")
    case "Current week": return T("Week", "Hafta")
    case "Current month": return T("Month", "Ay")
    case "Current day": return T("Day", "Gün")
    case "Premium requests": return T("Premium", "Premium")
    default: return w
    }
}

func levelTint(_ used: Double) -> Color { used >= 85 ? .red : used >= 60 ? .orange : .green }

func usd(_ v: Double?) -> String { v.map { String(format: "$%.0f", $0) } ?? "—" }

func logo(_ provider: String) -> Image? {
    let name = ["anthropic": "claude", "copilot": "githubcopilot", "openai-codex": "openai", "gemini": "googlegemini",
                "nvidia": "nvidia", "openrouter": "openrouter"][String(provider.split(separator: "#").first ?? "")]
    guard let name, let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "icons"),
          let img = NSImage(contentsOf: url) else { return nil }
    return Image(nsImage: img).renderingMode(.template)
}

// ---------- timeline ----------

struct Entry: TimelineEntry {
    let date: Date
    let snap: Snapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snap: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview { return completion(Entry(date: .now, snap: .placeholder)) }
        Task { completion(Entry(date: .now, snap: await loadSnapshot())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let snap = await loadSnapshot()
            // offline: try again soon; otherwise macOS' normal budget (Agent Bar also reloads on changes)
            let next = Date().addingTimeInterval(snap.offline ? 120 : 900)
            completion(Timeline(entries: [Entry(date: .now, snap: snap)], policy: .after(next)))
        }
    }
}

// ---------- views ----------

struct Ring: View {
    let quota: Snapshot.Quota
    var size: CGFloat = 54
    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle().trim(from: 0, to: min(quota.used, 100) / 100)
                .stroke(levelTint(quota.used), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(quota.used))%").font(.system(size: size * 0.24, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(windowName(quota.window)).font(.system(size: size * 0.15)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct QuotaBar: View {
    let quota: Snapshot.Quota
    var body: some View {
        HStack(spacing: 6) {
            (logo(quota.provider) ?? Image(systemName: "gauge.medium")).resizable().scaledToFit().frame(width: 11, height: 11)
            Text("\(providerName(quota.provider)) · \(windowName(quota.window))").font(.caption).lineLimit(1)
            Spacer(minLength: 4)
            ProgressView(value: min(quota.used, 100), total: 100).tint(levelTint(quota.used)).frame(width: 56)
            Text("\(Int(quota.used))%").font(.caption.weight(.semibold)).monospacedDigit().frame(width: 34, alignment: .trailing)
        }
    }
}

struct Running: View {
    let snap: Snapshot
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(snap.working > 0 ? Color.green : snap.running > 0 ? Color.green.opacity(0.45) : Color.secondary)
                .frame(width: 7, height: 7)
            Text(T("\(snap.working) working", "\(snap.working) çalışıyor")).font(.caption.weight(.medium))
            if snap.approvals > 0 {
                Text(T("· \(snap.approvals) need approval", "· \(snap.approvals) onay bekliyor"))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            }
            if snap.running > snap.working + snap.approvals {
                Text(T("· \(snap.running - snap.working - snap.approvals) waiting", "· \(snap.running - snap.working - snap.approvals) bekliyor"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if snap.subagents > 0 {
                Text(T("+\(snap.subagents) sub", "+\(snap.subagents) alt")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct Offline: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle").font(.title2).foregroundStyle(.secondary)
            Text(T("Agent Monitor is not running", "Agent Monitor çalışmıyor")).font(.caption).multilineTextAlignment(.center)
            Text(T("Open Agent Bar", "Agent Bar'ı aç")).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct SmallView: View {
    let snap: Snapshot
    var body: some View {
        if snap.offline { Offline() } else {
            let claude = snap.quotas.filter { $0.provider == "anthropic" }
            let rings = Array((claude.isEmpty ? snap.quotas : claude).prefix(2))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    (logo(rings.first?.provider ?? "anthropic") ?? Image(systemName: "gauge.medium")).resizable().scaledToFit().frame(width: 11)
                    Text(providerName(rings.first?.provider ?? "anthropic")).font(.caption.weight(.semibold))
                }
                HStack(spacing: 8) { ForEach(rings) { Ring(quota: $0, size: 58) } }
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Running(snap: snap)
            }
        }
    }
}

struct MediumView: View {
    let snap: Snapshot
    var body: some View {
        if snap.offline { Offline() } else {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(T("Quotas", "Kotalar")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(snap.quotas.prefix(4)) { QuotaBar(quota: $0) }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Running(snap: snap)
                    ForEach(snap.titles.prefix(2), id: \.self) {
                        Text($0).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(T("today", "bugün")).font(.caption2).foregroundStyle(.secondary)
                    Text(usd(snap.today)).font(.title3.weight(.semibold)).monospacedDigit()
                }
                .frame(width: 110, alignment: .leading)
            }
        }
    }
}

struct LargeView: View {
    let snap: Snapshot
    var body: some View {
        if snap.offline { Offline() } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Agent Monitor").font(.headline)
                    Spacer()
                    Running(snap: snap)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snap.quotas.prefix(6)) { QuotaBar(quota: $0) }
                }
                Divider()
                HStack(spacing: 18) {
                    VStack(alignment: .leading) {
                        Text(T("Today", "Bugün")).font(.caption2).foregroundStyle(.secondary)
                        Text(usd(snap.today)).font(.title3.weight(.semibold)).monospacedDigit()
                    }
                    VStack(alignment: .leading) {
                        Text(T("This month", "Bu ay")).font(.caption2).foregroundStyle(.secondary)
                        Text(usd(snap.month)).font(.title3.weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                }
                Divider()
                Text(T("Running", "Çalışan")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if snap.titles.isEmpty {
                    Text(T("Nothing running", "Çalışan oturum yok")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snap.titles.prefix(3), id: \.self) { Text("• " + $0).font(.caption).lineLimit(1) }
                if !snap.problems.isEmpty {
                    Divider()
                    Text(T("Needs attention", "Dikkat")).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(Array(problemLines(snap.problems).prefix(3).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

func statusName(_ s: String) -> String {
    switch s {
    case "account_exhausted": return T("account limit", "hesap limiti")
    case "cooldown": return T("cooling down", "beklemede")
    case "failing": return T("failing", "hata veriyor")
    case "degraded": return T("degraded", "sorunlu")
    default: return s
    }
}

/// Account-level problems (limit reached, cooldown) are one line per provider; model-level ones stay per model.
func problemLines(_ models: [WModel]) -> [String] {
    var lines: [String] = []
    var grouped: [String: Int] = [:]
    var order: [String] = []
    for m in models {
        if m.status == "account_exhausted" || m.status == "cooldown" {
            let key = m.provider + "|" + m.status
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: 0] += 1
        } else {
            lines.append("\(m.model) · \(statusName(m.status))")
        }
    }
    for key in order {
        let parts = key.split(separator: "|").map(String.init)
        let n = grouped[key] ?? 0
        lines.append("\(providerName(parts[0])) · \(statusName(parts[1]))" + (n > 1 ? T(" · \(n) models", " · \(n) model") : ""))
    }
    return lines
}

struct AgentMonitorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        Group {
            switch family {
            case .systemSmall: SmallView(snap: entry.snap)
            case .systemLarge: LargeView(snap: entry.snap)
            default: MediumView(snap: entry.snap)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "http://127.0.0.1:8777/#live"))
    }
}

struct AgentMonitorWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AgentMonitor", provider: Provider()) { AgentMonitorWidgetView(entry: $0) }
            .configurationDisplayName("Agent Monitor")
            .description(T("Quotas, running sessions and today's cost.", "Kotalar, çalışan oturumlar ve bugünkü maliyet."))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct AgentBarWidgets: WidgetBundle {
    var body: some Widget { AgentMonitorWidget() }
}
