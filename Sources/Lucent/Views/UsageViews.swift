import AppKit
import SwiftUI

// AI 编程工具用量的界面：卡片底部的“AI”页签，和主窗口的“AI 用量”分区。
// 风格沿用设计稿：白色 + 不透明度表层级，只有快用完（≥85%）才上热色。

// MARK: - 文案

enum UsageFmt {
    /// 104_000_000 → ("104", "M")；1_230 → ("1.2", "K")
    static func tokenParts(_ n: Int64) -> (String, String) {
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        let v = Double(n)
        for (s, u) in units where v >= s * 0.9995 {
            let x = v / s
            return (x >= 100 ? String(format: "%.0f", x) : String(format: "%.1f", x), u)
        }
        return ("\(n)", "")
    }

    static func tokens(_ n: Int64) -> String { let p = tokenParts(n); return p.0 + p.1 }

    /// $38.58 / $2,234
    static func cost(_ c: Double) -> String {
        if c >= 1000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            return "$" + (f.string(from: NSNumber(value: c)) ?? String(format: "%.0f", c))
        }
        return String(format: "$%.2f", c)
    }

    /// "3 小时 12 分后重置"
    static func reset(_ d: Date?) -> String? {
        guard let d else { return nil }
        let m = max(Int(d.timeIntervalSinceNow / 60), 0), h = m / 60, day = h / 24
        if day > 0 { return h % 24 > 0 ? L("\(day) 天 \(h % 24) 小时后重置") : L("\(day) 天后重置") }
        if h > 0 { return L("\(h) 小时 \(m % 60) 分后重置") }
        return L("\(m) 分钟后重置")
    }

    /// 5 小时窗口还剩多久："2 小时 14 分后结束"
    static func blockEnds(_ d: Date) -> String {
        let m = max(Int(d.timeIntervalSinceNow / 60), 0)
        return m >= 60 ? L("\(m / 60) 小时 \(m % 60) 分后结束") : L("\(m) 分钟后结束")
    }

    /// 卡片上的紧凑倒计时："2:14"
    static func blockRemain(_ d: Date) -> String {
        let m = max(Int(d.timeIntervalSinceNow / 60), 0)
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// "刚刚" / "3 分钟前"
    static func ago(_ d: Date?) -> String {
        guard let d else { return "—" }
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60 { return L("刚刚") }
        if s < 3600 { return L("\(s / 60) 分钟前") }
        if s < 86400 { return L("\(s / 3600) 小时前") }
        return L("\(s / 86400) 天前")
    }

    static func costNote(_ k: CostKind) -> String {
        switch k {
        case .apiEquivalent: return L("按 API 价折算")
        case .recorded: return L("工具记录的金额")
        case .billed: return L("账单计量")
        }
    }

    static func statusNote(_ s: UsageStatus) -> String? {
        switch s {
        case .loading: return L("读取中…")
        case .notInstalled: return L("本机没有记录")
        case let .partial(r), let .failed(r): return r
        case .ok: return nil
        }
    }
}

extension ToolUsage {
    /// 最紧张的那个额度窗口（用得最多的）
    var tightestQuota: QuotaWindow? { quotas.max { $0.usedFraction < $1.usedFraction } }
    /// 有 5 小时订阅窗口的工具（Claude、Codex）才显示窗口；OpenCode 走 API key，没有这个限制
    var hasFiveHourWindow: Bool { tool == .claude || tool == .codex }
    /// 进行中的 5 小时窗口（本地按请求时间估算，不是官方额度）
    var liveBlock: UsageBlock? { hasFiveHourWindow ? currentBlock.flatMap { $0.end > Date() ? $0 : nil } : nil }
    /// 当前窗口占近 30 天最大窗口的比例：只作参考，不代表离官方上限多远
    var blockFraction: Double? {
        guard let b = liveBlock, peakBlockTokens > 0 else { return nil }
        return Double(b.tokens.total) / Double(peakBlockTokens)
    }
    /// 最近 2 分钟有新记录，算“正在用”
    var isActive: Bool { lastActivity.map { -$0.timeIntervalSinceNow < 120 } ?? false }
    /// 有本机逐日记录（Cursor 只有账号额度，daily 全是 0）
    var hasDaily: Bool { daily.contains { $0.tokens.total > 0 } }
    var isProblem: Bool {
        switch status {
        case .partial, .failed: return true
        default: return false
        }
    }
}

extension Theme {
    /// 每分钟 token 数 → 激烈程度：1K 以下平静，1M 满格（按对数）
    static func tokenEnergy(_ perMinute: Double) -> Double { min(max(log10(max(perMinute, 1) / 1000) / 3, 0), 1) }

    /// 额度用量：平时白，≥85% 上热色
    static func quotaColor(_ f: Double) -> Color { f >= 0.85 ? heat : text }
}

// MARK: - Claude 用量页

/// Claude 的额度不由 Lucent 去查：点一下打开 Claude 桌面版自己的“设置 → 用量”页（桌面版托盘图标也跳这里）。
/// 没装桌面版就用浏览器打开 claude.ai 的同一页。
enum ClaudeUsagePage {
    static func open() {
        let app = URL(string: "claude://claude.ai/settings/usage")!
        if NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else {
            NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
        }
    }
}

/// “打开用量页 ↗”按钮
struct ClaudeUsageButton: View {
    var compact = false
    var body: some View {
        Button(action: ClaudeUsagePage.open) {
            HStack(spacing: 4) {
                Text(compact ? L("额度") : L("官方额度"))
                Image(systemName: "arrow.up.right").font(.system(size: compact ? 9 : 10, weight: .semibold))
            }
            .font(.system(size: compact ? 11.5 : 12))
            .foregroundStyle(Theme.dim(0.9))
            .padding(.horizontal, compact ? 8 : 10)
            .frame(height: compact ? 20 : 26)
            .background(.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("在 Claude 里查看官方的 5 小时和每周额度"))
    }
}

// MARK: - 共用小部件

/// 工具名前的小圆点：正在用时亮并发光
struct ActivityDot: View {
    var active: Bool
    var problem = false
    var body: some View {
        let c: Color = problem ? Theme.heat : .white
        Circle().fill(c.opacity(active || problem ? 1 : 0.28))
            .frame(width: 6, height: 6)
            .shadow(color: active ? c.opacity(0.9) : .clear, radius: 4)
    }
}

/// 额度条：点阵，超过 85% 的部分用热色
struct QuotaBar: View {
    var fraction: Double
    var count = 16

    var body: some View {
        let f = min(max(fraction, 0), 1)
        DotMeter(fraction: f, count: count, seed: UInt32(count))
            .colorMultiply(f >= 0.85 ? Theme.heat : .white)
    }
}

// MARK: - 卡片：AI 页签（3 行，和 TOP 进程同高）

struct UsageCardRows: View {
    let store: UsageStore
    @AppStorage(Prefs.usageHidden) private var hiddenRaw = ""

    /// 卡片的一行：一个工具，或多账号时的一个账号
    private struct Entry: Identifiable {
        let usage: ToolUsage
        let title: String
        let id: String
        let order: Int
    }

    /// 同一工具有多个账号时按账号分行（“Claude · 工作号”）；只放 3 行（和 TOP 进程同高），多了取最近在用的 3 行
    private var rows: [Entry] {
        let shown = UsageVisibility.shown(store.tools, hiddenRaw: hiddenRaw)
        let accounts = UsageAccounts.visible(store)
        var entries: [Entry] = []
        for u in shown {
            let base = AITool.allCases.firstIndex(of: u.tool)! * 100
            let mine = accounts.filter { $0.tool == u.tool }
            if mine.count > 1 {
                for (i, a) in mine.enumerated() {
                    var usage = store.usage(u.tool, account: a.id)
                    if u.tool == .cursor && usage.quotas.isEmpty { usage.quotas = a.quotas; usage.status = a.status }
                    entries.append(Entry(usage: usage, title: UsageAccounts.label(a), id: a.id, order: base + i))
                }
            } else {
                entries.append(Entry(usage: u, title: u.tool.title, id: u.tool.rawValue, order: base))
            }
        }
        guard entries.count > 3 else { return entries }
        return Array(entries.sorted { ($0.usage.lastActivity ?? .distantPast) > ($1.usage.lastActivity ?? .distantPast) }.prefix(3))
            .sorted { $0.order < $1.order }
    }

    var body: some View {
        let rows = rows
        ForEach(rows) { e in
            let u = e.usage
            HStack(spacing: 8) {
                ActivityDot(active: u.isActive, problem: u.isProblem)
                Text(e.title).lineLimit(1).truncationMode(.middle)
                if u.isProblem, let note = UsageFmt.statusNote(u.status) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.heat)
                        .help(note)
                }
                Spacer(minLength: 6)
                HStack(spacing: 14) {
                    quota(u)
                    Text(today(u)).frame(width: 60, alignment: .trailing)
                }
                .monospacedDigit()
                .foregroundStyle(Theme.dim(0.84))
            }
            .frame(height: 26)
            .padding(.horizontal, 8)
            .opacity(u.status == .notInstalled ? 0.45 : 1)
        }
        // 少于 3 行时占住高度，卡片尺寸不跳
        if rows.count < 3 {
            Text(rows.isEmpty ? L("在设置的「AI 用量」里选择要显示的工具") : "")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, minHeight: CGFloat(3 - rows.count) * 26)
        }
    }

    @ViewBuilder
    private func quota(_ u: ToolUsage) -> some View {
        if let q = u.tightestQuota {
            HStack(spacing: 6) {
                QuotaBar(fraction: q.usedFraction, count: 8)
                Text(Fmt.percent(q.usedFraction))
                    .foregroundStyle(Theme.quotaColor(q.usedFraction))
                    .frame(width: 34, alignment: .trailing)
            }
            .help(L("\(q.title) 已用 \(Fmt.percent(q.usedFraction))") + (UsageFmt.reset(q.resetsAt).map { " · \($0)" } ?? ""))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("\(q.title) 已用 \(Fmt.percent(q.usedFraction))"))
        } else if let b = u.liveBlock {
            BlockCompact(usage: u, block: b)
        } else if u.tool == .claude && u.status != .notInstalled {
            ClaudeUsageButton(compact: true)
        } else {
            Text("—").foregroundStyle(Theme.tertiary)
        }
    }

    /// 今日：有本机记录就显示 token，否则显示金额
    private func today(_ u: ToolUsage) -> String {
        if u.status == .notInstalled { return L("未安装") }
        if u.hasDaily { return UsageFmt.tokens(u.today.tokens.total) }
        return u.today.cost > 0 ? UsageFmt.cost(u.today.cost) : "—"
    }
}

// MARK: - 主窗口：AI 用量 · 概览页签

struct UsageOverviewTab: View {
    let store: UsageStore
    let tools: [ToolUsage]

    var body: some View {
        VStack(spacing: 14) {
            RatioRow(ratio: 1.37, spacing: 14, fill: true) {
                UsageTrendPanel(store: store, tools: tools)
                QuotaPanel(store: store, tools: tools)
            }
            .frame(minHeight: 268)
            // 下排按内容收高，多出来的高度让给上面的趋势图，不留半截空面板
            HStack(alignment: .top, spacing: 14) {
                if tools.count == 1, let only = tools.first {
                    ToolUsagePanel(usage: only, solo: true)
                } else {
                    ForEach(tools) { ToolUsagePanel(usage: $0) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 左上：今日 token 大数字 + 近 30 天每天的丝线
private struct UsageTrendPanel: View {
    let store: UsageStore
    let tools: [ToolUsage]

    var body: some View {
        let withDaily = tools.filter(\.hasDaily)
        let todayTokens = withDaily.reduce(Int64(0)) { $0 + $1.today.tokens.total }
        let parts = UsageFmt.tokenParts(todayTokens)
        let top = Double(max(withDaily.flatMap { $0.daily.map(\.tokens.total) }.max() ?? 1, 1)) * 1.1
        let rate = tools.reduce(0) { $0 + $1.tokensPerMinute }
        let last30 = tools.reduce(0) { $0 + $1.last30Cost }
        Panel {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(L("今日 Token"))
                    DotNumber(value: parts.0, unit: parts.1, size: 56, unitSize: 22)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(L("今日 \(UsageFmt.cost(tools.reduce(0) { $0 + $1.today.cost })) · 近 30 天 \(UsageFmt.cost(last30))"))
                    Text(rate >= 1 ? L("当前 \(UsageFmt.tokens(Int64(rate)))/分钟") : L("当前空闲"))
                }
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
            }
            GeometryReader { g in
                let h = g.size.height
                ThreadChart(layers: withDaily.enumerated().map { i, u in
                    ThreadLayer(data: Norm.padded(u.daily.map { Double($0.tokens.total) / top }),
                                base: h - 4, amp: h - 12, spread: i == 0 ? 8 : 5, seed: UInt32(51 + i * 16),
                                energy: Theme.tokenEnergy(u.tokensPerMinute),
                                strokes: i == 0
                                    ? [(Theme.accent, 0.6), (Theme.accent, 0.5), (Theme.accent, 0.45), (Theme.accent, 0.45), (Theme.accent, 0.4)]
                                    : [(Theme.dim(0.55), 0.5), (Theme.dim(0.45), 0.45), (Theme.dim(0.4), 0.4)],
                                markers: i == 0 ? .ring : .dot)
                }, baseline: h - 4, period: 5.4)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 16) {
                ForEach(Array(withDaily.enumerated()), id: \.element.id) { i, u in
                    HStack(spacing: 6) {
                        Capsule().fill(i == 0 ? Theme.accent : Theme.dim(0.5)).frame(width: 12, height: 2)
                            .shadow(color: i == 0 ? Theme.accent : .clear, radius: 3)
                        Text(u.tool.title)
                        Text(UsageFmt.tokens(u.last30Tokens.total)).foregroundStyle(Theme.secondary).monospacedDigit()
                    }
                }
                Spacer()
                Text(L("30 天前 → 今天")).font(Theme.mono(9.5)).tracking(0.8).foregroundStyle(Theme.tertiary)
            }
            .font(.system(size: 11.5))
        }
    }
}

/// 右上：订阅额度。一个工具只出现一块（Cursor 多账号时一个账号一块）
private struct QuotaPanel: View {
    let store: UsageStore
    let tools: [ToolUsage]

    private struct Entry: Identifiable {
        let id: String
        let title: String
        var plan: String?
        var isCurrent = false
        var updated: Date?
        var quotas: [QuotaWindow] = []
        /// 厂商没给额度时，退而显示本机估算的 5 小时窗口
        var estimate: ToolUsage?
        var note: String?
        var noteIsError = true
        /// Claude 的额度只能去它自己的用量页看
        var official = false
    }

    private var entries: [Entry] {
        let cursorAccounts = UsageAccounts.visible(store).filter { $0.tool == .cursor }
        var out: [Entry] = []
        for tool in AITool.allCases {
            if tool == .cursor && cursorAccounts.count > 1 {
                out += cursorAccounts.map { a in
                    Entry(id: a.id, title: "Cursor · \(a.displayName)", plan: a.plan, isCurrent: a.isCurrentLogin,
                          updated: a.quotaUpdatedAt, quotas: a.quotas,
                          note: a.status == .ok ? nil : UsageFmt.statusNote(a.status), noteIsError: a.status != .loading)
                }
                continue
            }
            guard let u = tools.first(where: { $0.tool == tool }), u.status != .notInstalled else { continue }
            var e = Entry(id: tool.rawValue, title: tool.title, plan: u.plan, updated: u.quotaUpdatedAt, quotas: u.quotas,
                          note: tool.hasQuota && u.isProblem ? UsageFmt.statusNote(u.status) : nil,
                          official: tool == .claude)
            // 有真额度就不再放估算窗口：同一个工具两套数字并排，分不清该信哪个
            if u.quotas.isEmpty, u.hasFiveHourWindow, tool == .claude || u.liveBlock != nil || !u.recentBlocks.isEmpty {
                e.estimate = u
            }
            if e.quotas.isEmpty && e.estimate == nil && e.note == nil { continue }
            out.append(e)
        }
        return out
    }

    var body: some View {
        let entries = entries
        Panel {
            HStack {
                Eyebrow(L("订阅额度"))
                Spacer()
                Button { store.refreshNow() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L("立即刷新"))
                .accessibilityLabel(L("刷新额度"))
            }
            if entries.isEmpty {
                Text(L("用过 Codex 或 Cursor 后，订阅额度会显示在这里"))
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(entries) { e in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(e.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                if e.isCurrent { Text(L("当前")).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary) }
                                if let plan = e.plan { Text(plan).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                                Spacer()
                                if e.official {
                                    ClaudeUsageButton()
                                } else if !e.quotas.isEmpty {
                                    Text(UsageFmt.ago(e.updated)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                }
                            }
                            ForEach(e.quotas) { QuotaRow(quota: $0) }
                            if let u = e.estimate { EstimateRow(usage: u) }
                            if let note = e.note {
                                Text(note).font(.system(size: 11.5))
                                    .foregroundStyle(e.noteIsError ? Theme.heat : Theme.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            // 内容多时底部淡出，不留被切一半的字
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.85),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// 卡片上的 5 小时窗口：只给剩余时间。点阵和百分比只留给厂商给的真额度，估算值不用同一套画法
private struct BlockCompact: View {
    let usage: ToolUsage
    let block: UsageBlock

    var body: some View {
        let content = HStack(spacing: 4) {
            Image(systemName: "clock").font(.system(size: 9.5))
            Text(UsageFmt.blockRemain(block.end))
        }
        .foregroundStyle(Theme.dim(0.84))
        .contentShape(Rectangle())
        .help(BlockText.tooltip(usage, opensOfficialPage: usage.tool == .claude))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("5 小时窗口约 \(UsageFmt.blockEnds(block.end))"))
        if usage.tool == .claude {
            Button(action: ClaudeUsagePage.open) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// 主窗口里本机估算的 5 小时窗口：一行字，细节收进说明图标。
/// 故意不画点阵、不给百分比，免得和上下的真额度混在一起被读成“额度用了多少”
private struct EstimateRow: View {
    let usage: ToolUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(L("5 小时窗口")).foregroundStyle(Theme.text).frame(width: 78, alignment: .leading)
                if let b = usage.liveBlock {
                    Text(L("已用 \(UsageFmt.tokens(b.tokens.total))"))
                    Spacer(minLength: 4)
                    Text(L("约 \(UsageFmt.blockEnds(b.end))"))
                } else {
                    Text(L("空闲"))
                    Spacer(minLength: 4)
                }
                InfoTip(BlockText.tooltip(usage))
            }
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            if let b = usage.liveBlock, let pace = BlockText.pace(b) {
                Text(pace).font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.leading, 88)
            }
        }
        .monospacedDigit().lineLimit(1)
    }
}

enum BlockText {
    /// "已用 251M · 1.2M/分钟 · 照此速度到 14:00 约 380M · 2 小时 14 分后结束"
    static func detail(_ b: UsageBlock) -> String {
        ([L("已用 \(UsageFmt.tokens(b.tokens.total))")] + [pace(b)].compactMap { $0 } + [UsageFmt.blockEnds(b.end)])
            .joined(separator: " · ")
    }

    /// 速度和照此速度的预计："1.2M/分钟 · 照此速度到 14:00 约 380M"
    static func pace(_ b: UsageBlock) -> String? {
        var parts: [String] = []
        if b.tokensPerMinute >= 1 { parts.append(L("\(UsageFmt.tokens(Int64(b.tokensPerMinute)))/分钟")) }
        if b.projectedTokens > b.tokens.total {
            parts.append(L("照此速度到 \(UsageFmt.clock(b.end)) 约 \(UsageFmt.tokens(b.projectedTokens))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func idle(_ u: ToolUsage) -> String {
        guard let last = u.recentBlocks.first(where: { $0.end <= Date() }) ?? u.recentBlocks.first else {
            return L("近 7 天没有用量窗口")
        }
        return L("当前没有进行中的窗口 · 上一个 \(UsageFmt.clock(last.start))–\(UsageFmt.clock(last.end)) 用了 \(UsageFmt.tokens(last.tokens.total))")
    }

    /// 悬停说明：第一句先讲清楚这不是官方额度，再给细节
    static func tooltip(_ u: ToolUsage, opensOfficialPage: Bool = false) -> String {
        var lines = [L("5 小时窗口按本机记录估算，不是官方额度")]
        if let b = u.liveBlock {
            lines.append(detail(b))
            if let f = u.blockFraction {
                lines.append(L("相当于近 30 天最大窗口（\(UsageFmt.tokens(u.peakBlockTokens))）的 \(Fmt.percent(f))"))
            }
        } else {
            lines.append(idle(u))
        }
        if opensOfficialPage { lines.append(L("点击查看 Claude 的官方额度")) }
        return lines.joined(separator: "\n")
    }
}

/// 一行额度：名称 + 点阵条 + 百分比，下面一行重置时间
struct QuotaRow: View {
    let quota: QuotaWindow

    var body: some View {
        let q = quota
        let sub = [q.detail, UsageFmt.reset(q.resetsAt)].compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(q.title).frame(width: 78, alignment: .leading).lineLimit(1)
                QuotaBar(fraction: q.usedFraction, count: 16)
                Spacer(minLength: 4)
                Text(Fmt.percent(q.usedFraction)).foregroundStyle(Theme.quotaColor(q.usedFraction)).monospacedDigit()
            }
            .font(.system(size: 12))
            if !sub.isEmpty {
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.leading, 88).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("\(q.title)，已用 \(Fmt.percent(q.usedFraction))") + (sub.isEmpty ? "" : L("，\(sub)")))
    }
}

/// 补充说明收在这个图标里，悬停才出现，不常驻占地方
struct InfoTip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .help(text)
            .accessibilityLabel(text)
    }
}

/// 下排：每个工具一块
private struct ToolUsagePanel: View {
    let usage: ToolUsage
    /// 页面上只有这一个工具：今日和近 30 天上面的趋势面板已经给过，这里不重复，改成构成和模型并排
    var solo = false

    var body: some View {
        let u = usage
        let t30 = u.last30Tokens
        let hasNumbers = u.hasDaily || u.last30Cost > 0 || u.today.cost > 0
        Panel {
            HStack(spacing: 8) {
                ActivityDot(active: u.isActive, problem: u.isProblem)
                Eyebrow(u.tool.title.uppercased())
                Spacer()
                if let plan = u.plan { Text(plan).font(.system(size: 11.5)).foregroundStyle(Theme.secondary) }
                InfoTip(L("\(u.tool.sourceNote) · 金额\(UsageFmt.costNote(u.costKind))"))
            }
            if u.status == .notInstalled {
                Text(L("本机没有找到 \(u.tool.title) 的记录")).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            } else if !hasNumbers && u.models.isEmpty {
                Text(L("还没有用量记录")).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            } else if solo {
                HStack(alignment: .top, spacing: 40) {
                    if u.hasDaily { column(L("近 30 天构成")) { breakdown(t30) } }
                    if !u.models.isEmpty { column(L("模型")) { models(u, limit: 6) } }
                }
            } else {
                if hasNumbers {
                    HStack(alignment: .top) {
                        stat(L("今日"), u.hasDaily ? UsageFmt.tokenParts(u.today.tokens.total) : nil, cost: u.today.cost)
                        Spacer()
                        stat(L("近 30 天"), u.hasDaily ? UsageFmt.tokenParts(t30.total) : nil, cost: u.last30Cost)
                    }
                }
                if u.hasDaily { breakdown(t30) }
                if !u.models.isEmpty {
                    models(u, limit: 3)
                        .padding(.top, 10)
                        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
                }
            }
            if u.status != .notInstalled {
                Spacer(minLength: 0)
                if u.isProblem, let note = UsageFmt.statusNote(u.status) {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.heat).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func column<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdown(_ t: TokenCounts) -> some View {
        VStack(spacing: 6) {
            LegendRow(swatch: .solid(1, glow: true), name: L("输出"), value: UsageFmt.tokens(t.output), swatchWidth: 12)
            LegendRow(swatch: .solid(0.6, glow: false), name: L("输入"), value: UsageFmt.tokens(t.input), swatchWidth: 12)
            LegendRow(swatch: .solid(0.3, glow: false), name: L("缓存读"), value: UsageFmt.tokens(t.cacheRead), swatchWidth: 12)
            LegendRow(swatch: .solid(0.15, glow: false), name: L("缓存写"), value: UsageFmt.tokens(t.cacheWrite), dimmed: true, swatchWidth: 12)
        }
    }

    private func models(_ u: ToolUsage, limit: Int) -> some View {
        VStack(spacing: 5) {
            ForEach(u.models.prefix(limit)) { m in
                HStack {
                    Text(m.model).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(UsageFmt.tokens(m.tokens)).foregroundStyle(Theme.secondary)
                    if m.cost > 0 { Text(UsageFmt.cost(m.cost)).frame(minWidth: 56, alignment: .trailing) }
                }
            }
        }
        .font(.system(size: 11.5)).monospacedDigit()
    }

    private func stat(_ title: String, _ tokens: (String, String)?, cost: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            if let tokens {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    RollingNumber(text: tokens.0, font: Theme.dotoNS(26), color: NSColor(Theme.text))
                        .baseline(of: Theme.dotoNS(26))
                    Text(tokens.1 + " tok").font(Theme.mono(10)).foregroundStyle(Theme.tertiary).fixedSize()
                }
            }
            Text(cost > 0 ? UsageFmt.cost(cost) : "—")
                .font(.system(size: tokens == nil ? 20 : 12, weight: tokens == nil ? .semibold : .regular))
                .foregroundStyle(tokens == nil ? Theme.text : Theme.secondary)
                .monospacedDigit()
        }
    }
}
