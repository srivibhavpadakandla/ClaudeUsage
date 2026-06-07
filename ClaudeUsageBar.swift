// ClaudeUsage — a Claude-themed menu bar usage checker.
// Reads local Claude Code activity from ~/.claude/projects and shows
// tokens + estimated cost. Pixel "Clawd" mascot + Claude serif type.

import SwiftUI
import AppKit
import Foundation

// MARK: - Fonts --------------------------------------------------------------

extension Font {
    // macOS "New York" serif — closest system match to Claude's serif type.
    static func claude(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Color helpers ------------------------------------------------------

extension Color {
    init(_ hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

struct Theme {
    let bg, card, accentSoft, text, subtext, accent, accent2, border, track, green, amber, red: Color
    static func resolve(_ s: ColorScheme) -> Theme {
        if s == .dark {
            return Theme(bg: Color(0x16150F), card: Color(0x201F1C), accentSoft: Color(0x342A22),
                         text: Color(0xF3EFE6), subtext: Color(0x9C968C), accent: Color(0xE08A6A),
                         accent2: Color(0xD9795E), border: Color(0x33322D), track: Color(0x2C2B27),
                         green: Color(0x93A063), amber: Color(0xD9A24E), red: Color(0xD05A4E))
        }
        return Theme(bg: Color(0xF0EEE6), card: Color(0xFAF9F5), accentSoft: Color(0xF3E6DF),
                     text: Color(0x1F1E1D), subtext: Color(0x736F68), accent: Color(0xC96442),
                     accent2: Color(0xD97757), border: Color(0xE6E1D7), track: Color(0xE8E3D9),
                     green: Color(0x7E8A47), amber: Color(0xB07A2E), red: Color(0xC0453B))
    }
}

// Severity color: green < 50% < amber < 80% < red.
func sevColor(_ frac: Double, _ t: Theme) -> Color {
    frac >= 0.8 ? t.red : frac >= 0.5 ? t.amber : t.green
}

func fmtDur(_ s: TimeInterval) -> String {
    let m = max(Int(s) / 60, 0)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

// MARK: - Formatting ---------------------------------------------------------

func fmtCost(_ c: Double) -> String {
    if c >= 1000 { return String(format: "$%.0f", c) }
    if c >= 100 { return String(format: "$%.1f", c) }
    return String(format: "$%.2f", c)
}

func fmtTokens(_ t: Int) -> String {
    if t >= 1_000_000 { return String(format: "%.2fM", Double(t) / 1_000_000) }
    if t >= 1_000 { return String(format: "%.1fK", Double(t) / 1_000) }
    return "\(t)"
}

func fmtPct(_ f: Double) -> String {
    "\(Int((min(max(f, 0), 1) * 100).rounded()))%"
}

// MARK: - Pricing (USD per million tokens) -----------------------------------

struct Pricing {
    let input, output, cacheWrite, cacheRead: Double
    static func forModel(_ model: String) -> Pricing {
        let m = model.lowercased()
        if m.contains("opus") {
            return Pricing(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)
        }
        if m.contains("haiku") {
            if m.contains("haiku-4") || m.contains("4-5") || m.contains("4.5") {
                return Pricing(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1)
            }
            return Pricing(input: 0.8, output: 4, cacheWrite: 1.0, cacheRead: 0.08)
        }
        return Pricing(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3) // sonnet / default
    }
}

func prettyModel(_ m: String) -> String {
    let l = m.lowercased()
    let fam = l.contains("opus") ? "Opus"
            : l.contains("sonnet") ? "Sonnet"
            : l.contains("haiku") ? "Haiku" : "Claude"
    if let r = m.range(of: #"\d+([.-]\d+)?"#, options: .regularExpression) {
        let v = m[r].replacingOccurrences(of: "-", with: ".")
        return "\(fam) \(v)"
    }
    return fam
}

// MARK: - Data model ---------------------------------------------------------

struct Rec {
    let date: Date
    let model: String
    let inT, outT, cacheW, cacheR: Int
    let cost: Double
    var tokens: Int { inT + outT + cacheW + cacheR }
}

struct Bucket {
    var cost = 0.0, inT = 0, outT = 0, cacheW = 0, cacheR = 0, tokens = 0
    mutating func add(_ r: Rec) {
        cost += r.cost; inT += r.inT; outT += r.outT
        cacheW += r.cacheW; cacheR += r.cacheR; tokens += r.tokens
    }
}

struct BlockInfo { var start: Date; var resetAt: Date; var cost: Double; var tokens: Int }

struct Summary {
    var today = Bucket(), week = Bucket(), month = Bucket(), all = Bucket()
    var last7: [(day: Date, cost: Double, tokens: Int)] = []
    var models: [(name: String, cost: Double, tokens: Int)] = []
    var block: BlockInfo?
    var recentEvents: [(date: Date, cost: Double)] = []   // last ~6h, for exact-window cost
    var weekTokens = 0
    var peakDayTokens = 0
    var peakWeekTokens = 0
    var peakMonthTokens = 0
    var peakWindowTokens = 0
    var limitWindow = 0, limitDay = 0, limitWeek = 0, limitMonth = 0
    var generatedAt = Date()
    var recordCount = 0
    var fileCount = 0
}

// MARK: - Loader -------------------------------------------------------------

enum UsageLoader {
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }

    static func computeSummary() -> Summary {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        var recs: [Rec] = []
        var seen = Set<String>()
        var fileCount = 0
        if let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
            while let u = en.nextObject() as? URL {
                guard u.pathExtension == "jsonl" else { continue }
                fileCount += 1
                parseFile(u, into: &recs, seen: &seen)
            }
        }
        var s = aggregate(recs, fileCount: fileCount)
        applyLimits(&s)
        return s
    }

    struct Limits: Codable { var window, day, week, month: Int }

    static func limitsFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ClaudeUsage/limits.json")
    }

    // Percentages run against these caps. Seeded at ~1.25x the user's observed
    // peaks on first run; the user edits limits.json to match their real plan.
    static func applyLimits(_ s: inout Summary) {
        let url = limitsFileURL()
        if let data = try? Data(contentsOf: url),
           let lim = try? JSONDecoder().decode(Limits.self, from: data) {
            s.limitWindow = lim.window; s.limitDay = lim.day
            s.limitWeek = lim.week; s.limitMonth = lim.month
            return
        }
        func seed(_ peak: Int, _ floor: Int) -> Int { max(Int(Double(peak) * 1.25), floor) }
        let lim = Limits(window: seed(s.peakWindowTokens, 2_000_000),
                         day: seed(s.peakDayTokens, 8_000_000),
                         week: seed(s.peakWeekTokens, 40_000_000),
                         month: seed(s.peakMonthTokens, 120_000_000))
        s.limitWindow = lim.window; s.limitDay = lim.day
        s.limitWeek = lim.week; s.limitMonth = lim.month
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(lim) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    static func parseFile(_ url: URL, into recs: inout [Rec], seen: inout Set<String>) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        for sub in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(sub.utf8))) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let date = parseDate(ts) else { continue }

            let mid = msg["id"] as? String ?? ""
            let rid = (obj["requestId"] as? String) ?? (obj["request_id"] as? String) ?? ""
            if !(mid.isEmpty && rid.isEmpty) {
                let key = mid + "|" + rid
                if seen.contains(key) { continue }
                seen.insert(key)
            }

            let inT = usage["input_tokens"] as? Int ?? 0
            let outT = usage["output_tokens"] as? Int ?? 0
            let cacheW = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheR = usage["cache_read_input_tokens"] as? Int ?? 0
            if inT == 0 && outT == 0 && cacheW == 0 && cacheR == 0 { continue }

            let model = msg["model"] as? String ?? "unknown"
            let p = Pricing.forModel(model)
            let cost = (Double(inT) * p.input + Double(outT) * p.output
                        + Double(cacheW) * p.cacheWrite + Double(cacheR) * p.cacheRead) / 1_000_000
            recs.append(Rec(date: date, model: model, inT: inT, outT: outT,
                            cacheW: cacheW, cacheR: cacheR, cost: cost))
        }
    }

    static func aggregate(_ recs: [Rec], fileCount: Int) -> Summary {
        var s = Summary()
        s.fileCount = fileCount
        s.recordCount = recs.count
        guard !recs.isEmpty else { return s }

        let cal = Calendar.current
        let now = Date()
        let startToday = cal.startOfDay(for: now)
        let weekAgo = cal.date(byAdding: .day, value: -6, to: startToday)!
        let startMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let sixHoursAgo = now.addingTimeInterval(-21600)

        var dayBuckets: [Date: Bucket] = [:]
        var modelBuckets: [String: Bucket] = [:]
        var weekTok: [Int: Int] = [:]
        var monthTok: [Int: Int] = [:]
        func weekKey(_ d: Date) -> Int {
            let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
            return (c.yearForWeekOfYear ?? 0) * 100 + (c.weekOfYear ?? 0)
        }
        func monthKey(_ d: Date) -> Int {
            let c = cal.dateComponents([.year, .month], from: d)
            return (c.year ?? 0) * 100 + (c.month ?? 0)
        }

        for r in recs {
            s.all.add(r)
            if r.date >= startToday { s.today.add(r) }
            if r.date >= weekAgo { s.week.add(r) }
            if r.date >= startMonth { s.month.add(r) }
            let day = cal.startOfDay(for: r.date)
            dayBuckets[day, default: Bucket()].add(r)
            modelBuckets[prettyModel(r.model), default: Bucket()].add(r)
            weekTok[weekKey(r.date), default: 0] += r.tokens
            monthTok[monthKey(r.date), default: 0] += r.tokens
            if r.date >= sixHoursAgo { s.recentEvents.append((r.date, r.cost)) }
        }
        s.weekTokens = weekTok[weekKey(now)] ?? 0
        s.peakDayTokens = dayBuckets.values.map { $0.tokens }.max() ?? 0
        s.peakWeekTokens = weekTok.values.max() ?? 0
        s.peakMonthTokens = monthTok.values.max() ?? 0

        s.last7 = (0..<7).map { i -> (day: Date, cost: Double, tokens: Int) in
            let day = cal.date(byAdding: .day, value: i - 6, to: startToday)!
            let b = dayBuckets[day] ?? Bucket()
            return (day, b.cost, b.tokens)
        }

        s.models = modelBuckets
            .map { (name: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }
            .sorted { $0.cost > $1.cost }

        // Current rolling 5-hour window (Claude plan style).
        let sorted = recs.sorted { $0.date < $1.date }
        var blocks: [(start: Date, end: Date, cost: Double, tok: Int, last: Date)] = []
        for r in sorted {
            if var b = blocks.last, r.date < b.end, r.date.timeIntervalSince(b.last) < 18000 {
                b.cost += r.cost; b.tok += r.tokens; b.last = r.date
                blocks[blocks.count - 1] = b
            } else {
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: r.date)
                let start = cal.date(from: comps) ?? r.date
                blocks.append((start, start.addingTimeInterval(18000), r.cost, r.tokens, r.date))
            }
        }
        if let b = blocks.last, now < b.end {
            s.block = BlockInfo(start: b.start, resetAt: b.end, cost: b.cost, tokens: b.tok)
        }
        s.peakWindowTokens = blocks.map { $0.tok }.max() ?? 0
        return s
    }
}

// MARK: - Real plan usage (Claude Code OAuth) --------------------------------
// Reads the same /api/oauth/usage endpoint Claude Code's `/usage` uses,
// authenticated with the token Claude Code stored in the macOS Keychain.

struct PlanUsage: Codable {
    var fiveHourPct: Double = 0
    var fiveHourReset: Date?
    var weekPct: Double = 0
    var weekReset: Date?
    var extraEnabled = false
    var extraUsed: Double = 0
    var extraLimit: Double = 0
}

struct BurnInfo {
    var ratePerHour: Double          // % of the 5-hour window per hour
    var timeToLimit: TimeInterval?   // seconds to 100% at current pace, nil if flat
    var willHitBeforeReset: Bool
}

func readClaudeOAuthToken() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials",
                   "-a", NSUserName(), "-w"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let o = j["claudeAiOauth"] as? [String: Any],
          let tok = o["accessToken"] as? String, !tok.isEmpty else { return nil }
    return tok
}

func parseResetDate(_ s: String) -> Date? {
    if let d = UsageLoader.parseDate(s) { return d }
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
        var t = s; t.removeSubrange(r); return UsageLoader.parseDate(t)
    }
    return nil
}

func fetchPlanUsage(_ token: String, _ completion: @escaping (PlanUsage?) -> Void) {
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
        completion(nil); return
    }
    var req = URLRequest(url: url, timeoutInterval: 12)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("claude-cli/2.1.156 (external, cli)", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(nil); return
        }
        func blk(_ key: String) -> (Double, Date?) {
            guard let b = j[key] as? [String: Any] else { return (0, nil) }
            let u: Double = (b["utilization"] as? Double) ?? Double(b["utilization"] as? Int ?? 0)
            let d = (b["resets_at"] as? String).flatMap(parseResetDate)
            return (u, d)
        }
        let (f, fr) = blk("five_hour"); let (w, wr) = blk("seven_day")
        var pu = PlanUsage(fiveHourPct: f, fiveHourReset: fr, weekPct: w, weekReset: wr)
        if let e = j["extra_usage"] as? [String: Any] {
            pu.extraEnabled = e["is_enabled"] as? Bool ?? false
            pu.extraUsed = (e["used_credits"] as? Double) ?? Double(e["used_credits"] as? Int ?? 0)
            pu.extraLimit = (e["monthly_limit"] as? Double) ?? Double(e["monthly_limit"] as? Int ?? 0)
        }
        completion(pu)
    }.resume()
}

// MARK: - Store --------------------------------------------------------------

final class UsageStore: ObservableObject {
    @Published var summary = Summary()
    @Published var plan: PlanUsage?
    @Published var burn: BurnInfo?
    @Published var samples: [(t: Date, util: Double)] = []   // 5h-window utilization curve
    @Published var loading = true
    var onUpdate: (() -> Void)?
    private let q = DispatchQueue(label: "claudeusage.load", qos: .userInitiated)
    private let planQ = DispatchQueue(label: "claudeusage.plan", qos: .userInitiated)
    private var timer: Timer?
    private var planTimer: Timer?
    private var lastPlanFetch = Date.distantPast
    private var history: [(t: Date, util: Double)] = []   // five-hour utilization samples

    init() {
        loadHistory()                       // survive restarts so pace is known immediately
        loadStoredPlan()                    // show last-known plan instantly on launch
        load()
        loadPlan()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.load()
        }
        // Poll the live plan endpoint gently — it rate-limits (429) if hit too often.
        planTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            self?.loadPlan()
        }
    }

    private func historyURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ClaudeUsage/history.json")
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL()),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Double]] else { return }
        let now = Date()
        history = arr.compactMap { d -> (t: Date, util: Double)? in
            guard let t = d["t"], let u = d["u"] else { return nil }
            return (Date(timeIntervalSince1970: t), u)
        }.filter { now.timeIntervalSince($0.t) <= 21600 }
        samples = history
    }

    private func saveHistory() {
        let arr = history.map { ["t": $0.t.timeIntervalSince1970, "u": $0.util] }
        if let data = try? JSONSerialization.data(withJSONObject: arr) {
            try? FileManager.default.createDirectory(at: historyURL().deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: historyURL())
        }
    }

    func load() {
        DispatchQueue.main.async { self.loading = true; self.onUpdate?() }
        q.async {
            let s = UsageLoader.computeSummary()
            DispatchQueue.main.async { self.summary = s; self.loading = false; self.onUpdate?() }
        }
    }

    func loadPlan() {
        let now = Date()
        if now.timeIntervalSince(lastPlanFetch) < 10 { return }   // throttle bursts → avoid 429
        lastPlanFetch = now
        planQ.async {
            guard let token = readClaudeOAuthToken() else {
                DispatchQueue.main.async { self.plan = nil; self.burn = nil; self.onUpdate?() }; return
            }
            fetchPlanUsage(token) { p in
                DispatchQueue.main.async { self.applyPlan(p) }
            }
        }
    }

    private func planFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ClaudeUsage/plan.json")
    }

    private func loadStoredPlan() {
        guard let data = try? Data(contentsOf: planFileURL()),
              let p = try? JSONDecoder().decode(PlanUsage.self, from: data) else { return }
        // Only trust it if its 5-hour window hasn't already reset.
        if let reset = p.fiveHourReset, reset > Date() { plan = p }
    }

    private func savePlan(_ p: PlanUsage) {
        if let data = try? JSONEncoder().encode(p) {
            try? FileManager.default.createDirectory(at: planFileURL().deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: planFileURL())
        }
    }

    private func applyPlan(_ p: PlanUsage?) {
        guard let p = p else {
            // Transient failure (429 / network). Keep the last good plan so the
            // cards & graph don't blank; only clear burn if we never had data.
            if plan == nil { burn = nil }
            onUpdate?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.loadPlan() }
            return
        }
        plan = p
        savePlan(p)
        let now = Date()
        if let last = history.last, p.fiveHourPct < last.util - 1 {
            history.removeAll()      // window reset — drop stale samples
        }
        history.append((now, p.fiveHourPct))
        history.removeAll { now.timeIntervalSince($0.t) > 21600 }   // keep the whole window (~6h)
        samples = history
        saveHistory()
        burn = computeBurn(p, now)
        onUpdate?()
    }

    private func computeBurn(_ p: PlanUsage, _ now: Date) -> BurnInfo? {
        // Slope from the last ~30 min so an early flat stretch doesn't mask a recent climb.
        let recent = history.filter { now.timeIntervalSince($0.t) <= 1800 }
        guard let first = recent.first, let last = recent.last, recent.count >= 2 else { return nil }
        let dt = last.t.timeIntervalSince(first.t)
        guard dt >= 20 else { return nil }
        let ratePerHour = (last.util - first.util) / dt * 3600
        guard ratePerHour > 0.5 else {
            return BurnInfo(ratePerHour: max(ratePerHour, 0), timeToLimit: nil, willHitBeforeReset: false)
        }
        let secsToLimit = max(100 - p.fiveHourPct, 0) / (ratePerHour / 3600)
        let toReset = p.fiveHourReset.map { $0.timeIntervalSince(now) } ?? .infinity
        return BurnInfo(ratePerHour: ratePerHour, timeToLimit: secsToLimit,
                        willHitBeforeReset: secsToLimit < toReset)
    }
}

// MARK: - Mascot --------------------------------------------------------------
// The mascot is now an animated ClaudePix creature; see ClaudeAnims.swift for
// AnimatedMascot (panel) and BarIconAnimator (menu bar).

// MARK: - UI components ------------------------------------------------------

struct PercentCard: View {
    let title: String, frac: Double, theme: Theme
    var big: Bool = false
    var sub: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.claude(10, .semibold)).tracking(0.7)
                .foregroundColor(theme.subtext)
            Text(fmtPct(frac))
                .font(.claude(big ? 34 : 22, .bold))
                .foregroundColor(big ? theme.accent : theme.text)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track).frame(height: 7)
                    Capsule().fill(sevColor(frac, theme))
                        .frame(width: max(7, geo.size.width * min(max(frac, 0), 1)), height: 7)
                }
            }.frame(height: 7)
            if let sub { Text(sub).font(.claude(11)).foregroundColor(theme.subtext) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(big ? theme.accentSoft : theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
    }
}

// Estimated API-equivalent $ value of the tokens used in the current 5-hour window.
struct SpendCard: View {
    let amount: Double, frac: Double, theme: Theme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("5H SPEND").font(.claude(10, .semibold)).tracking(0.7).foregroundColor(theme.subtext)
            Text(fmtCost(amount)).font(.claude(22, .bold)).foregroundColor(theme.text)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track).frame(height: 7)
                    Capsule().fill(sevColor(frac, theme))
                        .frame(width: max(7, geo.size.width * min(max(frac, 0), 1)), height: 7)
                }
            }.frame(height: 7)
            Text("est. · this window").font(.claude(11)).foregroundColor(theme.subtext)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
    }
}

// Live graph of the real 5-hour utilization climbing across the window, with a
// dashed projection (from burn-rate) to where you'll land by reset.
struct WindowGraph: View {
    let samples: [(t: Date, util: Double)]
    let reset: Date?
    let currentUtil: Double
    let burn: BurnInfo?
    let theme: Theme

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in plot(geo.size) }.frame(height: 70)
            HStack {
                Text("window start").font(.claude(9)).foregroundColor(theme.subtext)
                Spacer()
                Text(reset == nil ? "now" : "reset").font(.claude(9)).foregroundColor(theme.subtext)
            }
        }
    }

    private func plot(_ size: CGSize) -> some View {
        let now = Date()
        let end = reset ?? now
        let start = reset.map { $0.addingTimeInterval(-18000) } ?? (samples.first?.t ?? now)
        let span = max(end.timeIntervalSince(start), 1)
        func x(_ d: Date) -> CGFloat { CGFloat(min(max(d.timeIntervalSince(start) / span, 0), 1)) * size.width }
        func y(_ u: Double) -> CGFloat { size.height - 3 - (size.height - 6) * CGFloat(min(max(u / 100, 0), 1)) }

        let pts = samples.filter { $0.t >= start && $0.t <= now }
        let lineColor = sevColor(min(max(currentUtil / 100, 0), 1), theme)
        let last = pts.last ?? (now, currentUtil)

        // Projection endpoint.
        let proj: (CGPoint, Bool) = {
            if let burn, let tt = burn.timeToLimit, burn.willHitBeforeReset {
                return (CGPoint(x: x(now.addingTimeInterval(tt)), y: y(100)), true)
            }
            let hrs = end.timeIntervalSince(now) / 3600
            let pu = min(currentUtil + (burn?.ratePerHour ?? 0) * hrs, 100)
            return (CGPoint(x: x(end), y: y(pu)), false)
        }()

        return ZStack {
            Path { p in p.move(to: CGPoint(x: 0, y: y(100))); p.addLine(to: CGPoint(x: size.width, y: y(100))) }
                .stroke(theme.red.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Path { p in p.move(to: CGPoint(x: x(now), y: 0)); p.addLine(to: CGPoint(x: x(now), y: size.height)) }
                .stroke(theme.border, lineWidth: 1)
            if pts.count >= 2 {
                Path { p in
                    p.move(to: CGPoint(x: x(pts[0].t), y: size.height))
                    for s in pts { p.addLine(to: CGPoint(x: x(s.t), y: y(s.util))) }
                    p.addLine(to: CGPoint(x: x(pts.last!.t), y: size.height)); p.closeSubpath()
                }.fill(LinearGradient(colors: [lineColor.opacity(0.28), lineColor.opacity(0.02)],
                                      startPoint: .top, endPoint: .bottom))
                Path { p in
                    for (i, s) in pts.enumerated() {
                        i == 0 ? p.move(to: CGPoint(x: x(s.t), y: y(s.util)))
                               : p.addLine(to: CGPoint(x: x(s.t), y: y(s.util)))
                    }
                }.stroke(lineColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            Path { p in
                p.move(to: CGPoint(x: x(last.t), y: y(last.util)))
                p.addLine(to: proj.0)
            }.stroke((proj.1 ? theme.red : theme.subtext).opacity(0.8),
                     style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
            Circle().fill(lineColor).frame(width: 6, height: 6)
                .position(x: x(last.t), y: y(last.util))
        }
    }
}

struct BarChart: View {
    let data: [(day: Date, cost: Double, tokens: Int)]
    let theme: Theme
    private func initial(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEEE"; return f.string(from: d)
    }
    var body: some View {
        let maxC = max(data.map { $0.cost }.max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 7) {
            ForEach(Array(data.enumerated()), id: \.offset) { _, d in
                VStack(spacing: 5) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4).fill(theme.track).frame(height: 56)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(colors: [theme.accent2, theme.accent],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(height: max(3, 56 * d.cost / maxC))
                    }
                    Text(initial(d.day))
                        .font(.claude(9, .medium)).foregroundColor(theme.subtext)
                }
            }
        }
    }
}

struct LineChart: View {
    let data: [(day: Date, cost: Double, tokens: Int)]
    let theme: Theme
    private func initial(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEEE"; return f.string(from: d)
    }
    private func point(_ i: Int, _ size: CGSize, _ maxC: Double) -> CGPoint {
        let n = CGFloat(max(data.count - 1, 1))
        return CGPoint(x: size.width * CGFloat(i) / n,
                       y: size.height - 3 - (size.height - 6) * CGFloat(min(data[i].cost / maxC, 1)))
    }
    var body: some View {
        let maxC = max(data.map { $0.cost }.max() ?? 0, 0.0001)
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height))
                        for i in data.indices { p.addLine(to: point(i, geo.size, maxC)) }
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height)); p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [theme.green.opacity(0.38), theme.green.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        for i in data.indices {
                            i == 0 ? p.move(to: point(i, geo.size, maxC))
                                   : p.addLine(to: point(i, geo.size, maxC))
                        }
                    }
                    .stroke(theme.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if let last = data.indices.last {
                        Circle().fill(theme.green).frame(width: 6, height: 6)
                            .position(point(last, geo.size, maxC))
                    }
                }
            }.frame(height: 64)
            HStack(spacing: 0) {
                ForEach(Array(data.enumerated()), id: \.offset) { _, d in
                    Text(initial(d.day)).font(.claude(9, .medium))
                        .foregroundColor(theme.subtext).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct Pill: View {
    let text: String, theme: Theme
    var body: some View {
        Text(text)
            .font(.claude(12, .medium)).foregroundColor(theme.text)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(theme.track))
    }
}

struct RootView: View {
    @EnvironmentObject var store: UsageStore
    @Environment(\.colorScheme) var scheme
    @AppStorage(AlertSettings.key) private var alertThreshold = AlertSettings.defaultPct

    // Click-the-mascot easter egg: temporarily plays a random animation.
    @State private var eggAnim: String?
    @State private var eggToken = 0
    private let eggPool = ["dance_djmix", "dance_bounce_dj", "dance_sway_dj",
                           "dance_bounce", "dance_sway", "expression_wink",
                           "expression_surprise", "idle_look_around", "work_think"]

    private func playEgg() {
        let pick = eggPool.randomElement() ?? "dance_djmix"
        eggAnim = pick
        eggToken += 1
        let token = eggToken
        let dur = CPAnimStore.shared.anim(pick)?.holds.reduce(0, +) ?? 4
        let clamped = min(max(dur, 3), 6)   // play ~one loop, bounded 3–6s
        DispatchQueue.main.asyncAfter(deadline: .now() + clamped) {
            if eggToken == token { eggAnim = nil }
        }
    }

    var body: some View {
        let t = Theme.resolve(scheme)
        let s = store.summary
        VStack(spacing: 0) {
            header(t)
            if store.loading && s.recordCount == 0 {
                centered("Baking…", t, baking: true)
            } else if s.recordCount == 0 {
                centered("No Claude Code usage found yet.", t)
            } else {
                ScrollView { content(t, s).padding(16) }.frame(maxHeight: 520)
            }
            footer(t)
        }
        .frame(width: 380)
        .background(t.bg)
        .onAppear { store.load(); store.loadPlan() }
    }

    func header(_ t: Theme) -> some View {
        HStack(spacing: 10) {
            headerMascot(t).frame(width: 48, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { playEgg() }
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .help("Click me!")
            Spacer(minLength: 0)
            Text("Usage").font(.claude(26, .semibold)).foregroundColor(t.text)
            Spacer(minLength: 0)
            Button { store.load(); store.loadPlan() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundColor(t.subtext)
            .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().fill(t.border).frame(height: 1), alignment: .bottom)
    }

    // Current usage percent shown in the menu bar (0–100).
    private func usagePercent() -> Double {
        let s = store.summary
        if let plan = store.plan { return plan.fiveHourPct }
        if s.recordCount == 0 { return 0 }
        if let b = s.block { return Double(b.tokens) / Double(max(s.limitWindow, 1)) * 100 }
        return Double(s.today.tokens) / Double(max(s.limitDay, 1)) * 100
    }

    // Header creature: the coding-at-the-desk scene for normal usage checks,
    // switching to a surprised look near/over your limit. Click it to play a
    // random animation (the easter egg) before it settles back.
    @ViewBuilder
    func headerMascot(_ t: Theme) -> some View {
        let cell: CGFloat = 2.2
        let nearLimit = Double(alertThreshold > 0 ? alertThreshold : 85)
        if let egg = eggAnim {
            AnimatedMascot(name: egg, cell: cell, fill: t.accent2, eye: t.bg, crop: false)
        } else if !store.loading && usagePercent() >= nearLimit {
            AnimatedMascot(name: "expression_surprise", cell: cell, fill: t.accent2, eye: t.bg, crop: false)
        } else {
            AnimatedMascot(name: "work_coding", cell: cell, fill: t.accent2, eye: t.bg, crop: false)
        }
    }

    func content(_ t: Theme, _ s: Summary) -> some View {
        func pct(_ v: Int, _ peak: Int) -> Double { Double(v) / Double(max(peak, 1)) }
        let weeklyFrac = store.plan.map { min(max($0.weekPct / 100, 0), 1) }
            ?? pct(s.weekTokens, s.limitWeek)
        let weeklySub = store.plan?.weekReset.map { r -> String in
            let rem = max(r.timeIntervalSinceNow, 0)
            return "resets in \(Int(rem) / 86400)d \((Int(rem) % 86400) / 3600)h"
        }
        // Estimated $ value of tokens in the real current 5-hour window.
        let windowSpend: Double = {
            if let reset = store.plan?.fiveHourReset {
                let start = reset.addingTimeInterval(-18000)
                return s.recentEvents.filter { $0.date >= start }.reduce(0) { $0 + $1.cost }
            }
            return s.block?.cost ?? 0
        }()
        let currentFrac = store.plan.map { min(max($0.fiveHourPct / 100, 0), 1) }
            ?? min(Double(s.block?.tokens ?? 0) / Double(max(s.limitWindow, 1)), 1)
        return VStack(spacing: 14) {
            if let plan = store.plan {
                planCard(t, "Current", plan.fiveHourPct, plan.fiveHourReset, weekly: false, burn: store.burn)
            } else if let b = s.block {
                windowCard(t, b, s)
            }
            if store.plan != nil {
                section("CURRENT 5-HOUR WINDOW", t) {
                    WindowGraph(samples: store.samples, reset: store.plan?.fiveHourReset,
                                currentUtil: store.plan?.fiveHourPct ?? 0, burn: store.burn, theme: t)
                }
            } else {
                section("USAGE THIS WEEK", t) { LineChart(data: s.last7, theme: t) }
            }
            HStack(spacing: 10) {
                PercentCard(title: "Weekly", frac: weeklyFrac, theme: t, sub: weeklySub)
                SpendCard(amount: windowSpend, frac: currentFrac, theme: t)
            }
            footnote(t)
        }
    }

    func planCard(_ t: Theme, _ title: String, _ pct: Double, _ reset: Date?, weekly: Bool,
                  burn: BurnInfo? = nil) -> some View {
        let frac = min(max(pct / 100, 0), 1)
        let sub: String = {
            guard let reset else { return "live plan usage" }
            let rem = max(reset.timeIntervalSinceNow, 0)
            if weekly { return "resets in \(Int(rem) / 86400)d \((Int(rem) % 86400) / 3600)h" }
            return "resets in \(Int(rem) / 3600)h \((Int(rem) % 3600) / 60)m"
        }()
        // "How long will this 5-hour window last at the current pace?"
        let burnNote: (String, Color)? = {
            guard weekly == false else { return nil }
            guard let burn else { return ("measuring your pace…", t.subtext) }
            let rate = "+\(Int(burn.ratePerHour.rounded()))%/hr"
            if let tt = burn.timeToLimit {
                return burn.willHitBeforeReset
                    ? ("≈ \(fmtDur(tt)) left at this pace · \(rate)", t.red)
                    : ("\(rate) · lasts the full window", t.subtext)
            }
            return ("steady — lasts the full window", t.green)
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(pct.rounded()))%").font(.claude(30, .bold)).foregroundColor(t.text)
                Spacer()
                Pill(text: title, theme: t)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.track).frame(height: 8)
                    Capsule().fill(sevColor(frac, t)).frame(width: max(8, geo.size.width * frac), height: 8)
                }
            }.frame(height: 8)
            Text(sub).font(.claude(12)).foregroundColor(t.subtext)
            if let (txt, col) = burnNote {
                Text(txt).font(.claude(12, .medium)).foregroundColor(col)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(t.border, lineWidth: 1))
    }

    func section<V: View>(_ title: String, _ t: Theme, @ViewBuilder _ body: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.claude(10, .semibold)).tracking(0.7).foregroundColor(t.subtext)
            body()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func windowCard(_ t: Theme, _ b: BlockInfo, _ s: Summary) -> some View {
        let now = Date()
        let frac = min(max(Double(b.tokens) / Double(max(s.limitWindow, 1)), 0), 1)
        let rem = max(b.resetAt.timeIntervalSince(now), 0)
        let h = Int(rem) / 3600, m = (Int(rem) % 3600) / 60
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(fmtPct(frac)).font(.claude(28, .bold)).foregroundColor(t.text)
                Spacer()
                Pill(text: "Current", theme: t)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.track).frame(height: 8)
                    Capsule().fill(sevColor(frac, t)).frame(width: max(8, geo.size.width * frac), height: 8)
                }
            }.frame(height: 8)
            Text("resets in \(h)h \(m)m")
                .font(.claude(12)).foregroundColor(t.subtext)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(t.border, lineWidth: 1))
    }

    func footnote(_ t: Theme) -> some View {
        Text("Current & Weekly are live plan limits. 5H Spend is an est. of API-rate cost; graph is local.")
            .font(.claude(10)).foregroundColor(t.subtext)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    func centered(_ msg: String, _ t: Theme, baking: Bool = false) -> some View {
        VStack(spacing: 14) {
            // Baking → the creature ponders your usage; idle → it dozes off.
            AnimatedMascot(name: baking ? "work_think" : "expression_sleep",
                           cell: 5, fill: t.accent2, eye: t.bg)
            HStack(spacing: 6) {
                if baking { Text("✳").font(.claude(14)).foregroundColor(t.accent) }
                Text(msg).font(.claude(15)).foregroundColor(baking ? t.accent : t.subtext)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    func footer(_ t: Theme) -> some View {
        let time: String = {
            let f = DateFormatter(); f.timeStyle = .short
            return f.string(from: store.summary.generatedAt)
        }()
        return HStack(spacing: 8) {
            if store.loading {
                Text("✳").font(.claude(11)).foregroundColor(t.accent)
                Text("Baking…").font(.claude(11)).foregroundColor(t.accent)
            } else {
                Text("Updated \(time)").font(.claude(11)).foregroundColor(t.subtext)
            }
            Spacer()
            alertMenu(t)
            Button { NSApplication.shared.terminate(nil) } label: {
                Text("Quit").font(.claude(12, .medium))
            }.buttonStyle(.plain).foregroundColor(t.subtext)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .overlay(Rectangle().fill(t.border).frame(height: 1), alignment: .top)
    }

    // Adjustable usage-alert threshold (fires a macOS notification on crossing).
    func alertMenu(_ t: Theme) -> some View {
        Menu {
            ForEach(AlertSettings.options, id: \.self) { v in
                Button { alertThreshold = v } label: {
                    Label("Alert at \(v)%", systemImage: alertThreshold == v ? "checkmark" : "")
                }
            }
            Divider()
            Button { alertThreshold = 0 } label: {
                Label("Off", systemImage: alertThreshold == 0 ? "checkmark" : "")
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: alertThreshold == 0 ? "bell.slash" : "bell")
                Text(alertThreshold == 0 ? "Off" : "\(alertThreshold)%")
            }
            .font(.claude(11)).foregroundColor(t.subtext)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Notify when usage crosses this percent")
    }
}

// MARK: - App (AppKit status item + popover) ---------------------------------

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - Usage alerts -------------------------------------------------------

enum AlertSettings {
    static let key = "alertThresholdPct"     // Int 0–100; 0 = off
    static let defaultPct = 80
    static let options = [50, 60, 70, 75, 80, 85, 90, 95]
}

// Posts a macOS notification via osascript, so it works for this unsigned,
// locally-built app without notification entitlements or code signing.
func postUsageNotification(title: String, body: String) {
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
    let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let barAnim = BarIconAnimator()
    // Usage-alert state: armed = allowed to fire; disarms after firing so it
    // notifies once per upward crossing and re-arms when usage drops back.
    private var alertArmed = true
    private var lastThreshold = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [AlertSettings.key: AlertSettings.defaultPct])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let clay = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
            let dark = NSColor(srgbRed: 0.09, green: 0.085, blue: 0.08, alpha: 1)
            barAnim.attach(to: button, name: "idle_blink", cell: 1.1, fill: clay, eye: dark)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: RootView().environmentObject(store))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        store.onUpdate = { [weak self] in
            self?.updateTitle()
            self?.checkUsageAlert()
        }
        updateTitle()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.showPopover()
        }
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        button.imagePosition = .imageLeading
        guard let pct = currentUsagePercent() else {
            button.attributedTitle = NSAttributedString(string: ""); return
        }
        let frac = min(max(pct / 100, 0), 1)
        // Glanceable severity: default → amber → red as you near the cap.
        let color: NSColor = frac >= 0.8 ? NSColor(srgbRed: 0.83, green: 0.31, blue: 0.27, alpha: 1)
                           : frac >= 0.6 ? NSColor(srgbRed: 0.80, green: 0.58, blue: 0.22, alpha: 1)
                           : .labelColor
        button.attributedTitle = NSAttributedString(
            string: "  \(Int(pct.rounded()))%",
            attributes: [.foregroundColor: color, .font: NSFont.menuBarFont(ofSize: 0)])
    }

    // The percent currently shown in the menu bar (0–100), or nil if unknown.
    private func currentUsagePercent() -> Double? {
        let s = store.summary
        if let plan = store.plan { return plan.fiveHourPct }
        if s.recordCount == 0 { return nil }
        let frac: Double
        if let b = s.block {
            frac = Double(b.tokens) / Double(max(s.limitWindow, 1))
        } else {
            frac = Double(s.today.tokens) / Double(max(s.limitDay, 1))
        }
        return frac * 100
    }

    private func checkUsageAlert() {
        let threshold = UserDefaults.standard.integer(forKey: AlertSettings.key)
        // Re-arm whenever the user changes the threshold so the new level can fire.
        if threshold != lastThreshold { alertArmed = true; lastThreshold = threshold }
        guard threshold > 0, let pct = currentUsagePercent() else { return }

        if pct >= Double(threshold), alertArmed {
            alertArmed = false
            let p = Int(pct.rounded())
            postUsageNotification(
                title: "Claude usage at \(p)%",
                body: "You've crossed your \(threshold)% alert threshold.")
        } else if pct < Double(threshold) - 3 {
            alertArmed = true   // dropped back (e.g. after a 5-hour reset)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        store.load(); store.loadPlan()
    }
}
