import AppKit
import ServiceManagement
import SwiftUI

/// 主窗口（docs/design/window.html）：左侧分区栏 + 右侧内容
enum DashSection: String, CaseIterable, Identifiable {
    case overview, thermal, cpu, memory, network, ai, info, settings
    var id: String { rawValue }

    /// 侧栏列出的分区；设置在左下角齿轮里
    static let listed: [DashSection] = [.overview, .thermal, .cpu, .memory, .network, .ai, .info]

    var title: String {
        switch self {
        case .overview: return L10n.t("Overview")
        case .thermal: return L10n.t("Temperature")
        case .cpu: return L10n.t("Processor")
        case .memory: return L10n.t("Memory")
        case .network: return L10n.t("Network")
        case .ai: return L10n.t("AI usage")
        case .info: return L10n.t("This Mac")
        case .settings: return L10n.t("Settings")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .thermal: return "thermometer.medium"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "arrow.up.arrow.down"
        case .ai: return "sparkles"
        case .info: return "laptopcomputer"
        case .settings: return "gearshape"
        }
    }
}

@MainActor @Observable
final class DashboardNav {
    var section: DashSection = .overview
}

enum TimeRange: Int, CaseIterable, Identifiable {
    case minute = 60, tenMinutes = 600, hour = 3600
    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var label: String {
        switch self {
        case .minute: return L10n.t("1 min")
        case .tenMinutes: return L10n.t("10 min")
        case .hour: return L10n.t("1 hour")
        }
    }
}

struct DashboardView: View {
    let monitor: Monitor
    @Bindable var nav: DashboardNav
    @AppStorage("dash.range") private var range: TimeRange = .tenMinutes
    @AppStorage(Prefs.nativeGlass) private var nativeGlass = true
    @AppStorage(Prefs.language) private var language = L10n.Language.system.rawValue

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(monitor: monitor, nav: nav)
                .frame(width: 236)
            VStack(alignment: .leading, spacing: 14) {
                header
                // 换分区时新内容淡入上浮（ZStack 让新旧两份叠在一起过渡，不挤布局）
                ZStack(alignment: .topLeading) {
                    content
                        .id(nav.section)
                        .transition(UIMotion.contentSwap)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(EdgeInsets(top: 26, leading: 18, bottom: 24, trailing: 28))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(Theme.text)
        .frame(minWidth: 1080, minHeight: 720)
        .background { GlassSurface(native: nativeGlass, radius: 0, tint: 0.72).ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .environment(\.locale, L10n.locale)
        .id(language)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(nav.section.title)
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.4)
                    .id(nav.section)
                    .transition(UIMotion.contentSwap)
                Text(nav.section == .settings ? L10n.t("Changes apply immediately") : "UPTIME \(Labels.uptime(monitor.machine)) · SAMPLE \(Int(Prefs.sampleInterval))S")
                    .font(Theme.mono(10.5)).tracking(1).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if nav.section == .ai {
                HStack(spacing: 10) {
                    AccountMenu(store: UsageStore.shared)
                    UsageTabPicker()
                }
            } else if nav.section != .info && nav.section != .settings {
                RangePicker(range: $range)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let r = range.seconds
        switch nav.section {
        case .overview:
            VStack(spacing: 14) {
                RatioRow(ratio: 1.37, spacing: 14) {
                    TempPanel(monitor: monitor, range: range)
                    CPUPanel(monitor: monitor)
                }
                HStack(alignment: .top, spacing: 14) {
                    MemoryPanel(monitor: monitor)
                    NetworkPanel(monitor: monitor, range: range)
                    ThisMacPanel(monitor: monitor)
                }
                .frame(maxHeight: .infinity)
            }
        case .thermal:
            VStack(spacing: 14) {
                TempPanel(monitor: monitor, range: range)
                SensorListPanel(monitor: monitor)
            }
        case .cpu:
            VStack(spacing: 14) {
                RatioRow(ratio: 1.37, spacing: 14) {
                    HistoryPanel(title: L10n.t("CPU · History"), values: monitor.cpuHistory.values(last: r, maxPoints: 40), seed: 23,
                                 caption: L10n.t("%@ peak %@", range.label, Fmt.percent(monitor.cpuHistory.peak(last: r) ?? 0)))
                    CPUPanel(monitor: monitor)
                }
                ProcessPanel(title: L10n.t("Highest CPU"), items: monitor.processes.topCPU) { String(format: "%.1f%%", $0.cpu) }
            }
        case .memory:
            VStack(spacing: 14) {
                RatioRow(ratio: 1.37, spacing: 14) {
                    HistoryPanel(title: L10n.t("MEMORY · History"), values: monitor.memHistory.values(last: r, maxPoints: 40), seed: 7,
                                 caption: L10n.t("%@ peak %@", range.label, Fmt.percent(monitor.memHistory.peak(last: r) ?? 0)))
                    MemoryPanel(monitor: monitor)
                }
                ProcessPanel(title: L10n.t("Highest memory"), items: monitor.processes.topMemory) { Fmt.size($0.memory) }
            }
        case .network:
            HStack(alignment: .top, spacing: 14) {
                NetworkPanel(monitor: monitor, range: range, chartHeight: 220)
                NetworkTotalsPanel(monitor: monitor)
                    .frame(width: 320)
            }
        case .ai:
            UsageSection(store: UsageStore.shared)
        case .info:
            HStack(alignment: .top, spacing: 14) {
                ThisMacPanel(monitor: monitor).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
                Spacer(minLength: 0)
            }
        case .settings:
            SettingsPage()
        }
    }
}

// MARK: - 分区栏

private struct Sidebar: View {
    let monitor: Monitor
    @Bindable var nav: DashboardNav
    @Namespace private var ns
    @State private var hovered: DashSection?

    var body: some View {
        let m = monitor.machine
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Labels.shortName(m)).font(.system(size: 15, weight: .semibold))
                Text("\(Labels.chip(m)) · \(Labels.memGB(m)) · MACOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)")
                    .font(Theme.mono(10.5)).tracking(0.6).foregroundStyle(Theme.tertiary)
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 14, trailing: 8))

            ForEach(DashSection.listed) { s in
                let selected = nav.section == s
                Button { UIMotion.run { nav.section = s } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.icon).font(.system(size: 13)).frame(width: 16)
                            .scaleEffect(selected ? 1.08 : 1)
                        Text(s.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .foregroundStyle(selected ? .white : Theme.dim(hovered == s ? 1 : 0.88))
                    .background {
                        // 选中块只有一个，换分区时从旧位置滑到新位置
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.12))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                                .matchedGeometryEffect(id: "selection", in: ns)
                        } else if hovered == s {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    UIMotion.run(.easeOut(duration: 0.12)) { hovered = inside ? s : (hovered == s ? nil : hovered) }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("SELF", size: 9.5, tracking: 1.2)
                    Text(selfText).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))

                let on = nav.section == .settings
                Button { UIMotion.run { nav.section = .settings } } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? .white : Theme.dim(0.88))
                        .rotationEffect(.degrees(on ? 60 : 0))
                        .frame(width: 50, height: 50)
                        .background(.white.opacity(on ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(on ? 0.2 : 0.08), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .help(L10n.t("Settings (⌘,)"))
            }
        }
        .padding(EdgeInsets(top: 14, leading: 10, bottom: 12, trailing: 10))
        .frame(maxHeight: .infinity)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .padding(10)
    }

    private var selfText: String {
        guard let u = monitor.selfUsage else { return "—" }
        return L10n.t("CPU %.1f%%\nMem %@", u.cpu, Fmt.size(u.memory))
    }
}

private struct RangePicker: View {
    @Binding var range: TimeRange
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimeRange.allCases) { r in
                let on = r == range
                Button { UIMotion.run { range = r } } label: {
                    Text(r.label)
                        .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? .white : Theme.dim(0.84))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

/// 两列按比例分宽（设计稿 grid-template-columns: 1.37fr 1fr）
struct RatioRow: Layout {
    var ratio: CGFloat
    var spacing: CGFloat
    var height: CGFloat? = nil    // 固定行高；不给就取两侧内容的高

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 900
        let (a, b) = widths(w)
        if let height { return CGSize(width: w, height: height) }
        let h = max(subviews[0].sizeThatFits(.init(width: a, height: nil)).height,
                    subviews[1].sizeThatFits(.init(width: b, height: nil)).height)
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (a, b) = widths(bounds.width)
        subviews[0].place(at: bounds.origin, proposal: .init(width: a, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + a + spacing, y: bounds.minY), proposal: .init(width: b, height: bounds.height))
    }

    private func widths(_ w: CGFloat) -> (CGFloat, CGFloat) {
        let a = (w - spacing) * ratio / (ratio + 1)
        return (a, w - spacing - a)
    }
}

/// 主窗口的卡片：圆角 20，内边距 18/20
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Card(radius: 20, padding: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)) {
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct Caption: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondary)
        .monospacedDigit()
    }
}

// MARK: - 温度

private struct TempPanel: View {
    let monitor: Monitor
    let range: TimeRange

    var body: some View {
        let s = monitor.snapshot
        let peak = monitor.tempHistory.peak(last: range.seconds)
        let data = Norm.padded(Norm.temp(monitor.tempHistory.values(last: range.seconds, maxPoints: 30)))
        let alertFrac = Norm.temp([Theme.alertTemp])[0]
        Panel {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("TEMPERATURE")
                    DotNumber(value: Fmt.tempValue(s.thermal.cpuAvg), unit: Fmt.tempUnit,
                              size: 64, unitSize: 24, unitColor: Theme.heat)
                }
                Spacer()
                Caption(lines: [
                    L10n.t("Thermal %@", s.thermal.state.label),
                    L10n.t("%@ peak %@ · %@", range.label, Fmt.temp(peak), monitor.machine.isFanless ? L10n.t("Fanless passive cooling") : L10n.t("Active fan cooling")),
                ])
            }
            GeometryReader { g in
                let h = g.size.height
                ThreadChart(layers: [
                    ThreadLayer(data: data, base: h - 6, amp: h - 10, spread: 9, seed: 11, energy: Theme.tempEnergy(s.thermal.cpuAvg),
                                strokes: Theme.heatStrokes(s.thermal.cpuAvg, [0.65, 0.55, 0.5, 0.5, 0.45, 0.45])),
                ], alert: (h - 6 - CGFloat(alertFrac) * (h - 10), "\(Fmt.temp(Theme.alertTemp)) ALERT"), glow: 3.6, period: 5.4)
            }
            .frame(minHeight: 126, maxHeight: .infinity)

            HStack(alignment: .top, spacing: 10) {
                ForEach(sensorRow(s.thermal), id: \.0) { name, value in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                        HStack(alignment: .top, spacing: 0) {
                            RollingNumber(text: Fmt.tempValue(value),
                                          font: Theme.dotoNS(20), color: NSColor(Theme.text))
                            BlinkingText(text: "°", font: Theme.dotoNS(20), color: Theme.nsHeat)
                        }
                        .font(Theme.doto(20))
                        DotMeter(fraction: (value ?? 0) / 100, seed: UInt32(name.unicodeScalars.first?.value ?? 1))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 14)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
        }
    }

    /// 性能核 / 能效核 / GPU / SSD / 电池 五个代表值
    private func sensorRow(_ t: ThermalStat) -> [(String, Double?)] {
        func avg(_ g: SensorGroup) -> Double? {
            let v = t.sensors.filter { $0.group == g }.map(\.value)
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        return [
            (L10n.t("P-cores"), avg(.cpuP) ?? t.cpuMax),
            (L10n.t("E-cores"), avg(.cpuE)),
            ("GPU", avg(.gpu) ?? t.gpu),
            ("SSD", avg(.storage)),
            (L10n.t("Battery"), avg(.battery) ?? t.battery),
        ]
    }
}

private struct SensorListPanel: View {
    let monitor: Monitor

    var body: some View {
        let groups = Dictionary(grouping: monitor.snapshot.thermal.sensors, by: \.group)
        Panel {
            Eyebrow("ALL SENSORS · \(monitor.snapshot.thermal.sensors.count)")
            if groups.isEmpty {
                Text(L10n.t("No temperature sensors")).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups.keys.sorted(), id: \.self) { g in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(g.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], alignment: .leading, spacing: 10) {
                                ForEach(groups[g] ?? []) { s in
                                    HStack(spacing: 10) {
                                        Text(s.id).font(Theme.mono(10.5)).foregroundStyle(Theme.tertiary).frame(width: 40, alignment: .leading)
                                        DotMeter(fraction: s.value / 100)
                                        Text(Fmt.temp(s.value)).font(.system(size: 12)).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - CPU

private struct CPUPanel: View {
    let monitor: Monitor

    var body: some View {
        let s = monitor.snapshot, m = monitor.machine
        let split = Labels.coreSplit(s, m)
        let p = Array(m.pCoreIndices), e = Array(m.eCoreIndices)
        Panel {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("CPU · \(s.cpu.cores.count) CORES")
                    DotNumber(value: "\(Int((s.cpu.total * 100).rounded()))", unit: "%", size: 64, unitSize: 24)
                }
                Spacer()
                Caption(lines: [
                    L10n.t("User %@ · system %@", Fmt.percent(s.cpu.user), Fmt.percent(s.cpu.system)),
                    L10n.t("Load %@", s.load.map { String(format: "%.2f", $0) }.joined(separator: " · ")),
                ])
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(p.enumerated()), id: \.offset) { i, idx in
                    if i > 0 { Spacer(minLength: 4) }
                    CoreColumn(load: load(s, idx), label: "P\(i + 1)", isP: true, index: idx)
                }
                ForEach(Array(e.enumerated()), id: \.offset) { i, idx in
                    Spacer(minLength: 4)
                    CoreColumn(load: load(s, idx), label: "E\(i + 1)", isP: false, index: idx)
                }
            }
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .bottom)
            HStack {
                if !p.isEmpty { Text(L10n.t("P-cores P1–P%d · %@", p.count, Fmt.percent(split.p))) }
                Spacer()
                if !e.isEmpty { Text(L10n.t("E-cores E1–E%d · %@", e.count, Fmt.percent(split.e))) }
            }
            .font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
        }
    }

    private func load(_ s: Snapshot, _ i: Int) -> Double {
        s.cpu.cores.indices.contains(i) ? s.cpu.cores[i] : 0
    }
}

private struct HistoryPanel: View {
    let title: String
    let values: [Double]
    let seed: UInt32
    let caption: String

    var body: some View {
        Panel {
            HStack {
                Eyebrow(title)
                Spacer()
                Caption(lines: [caption])
            }
            GeometryReader { g in
                ThreadChart(layers: [
                    ThreadLayer(data: Norm.padded(values), base: g.size.height - 4, amp: g.size.height - 14, spread: 8, seed: seed,
                                energy: min((values.last ?? 0) * 1.25, 1),
                                strokes: [(Theme.accent, 0.6), (Theme.accent, 0.5), (Theme.accent, 0.5), (Theme.accent, 0.45), (Theme.accent, 0.45), (Theme.accent, 0.4)]),
                ], baseline: g.size.height - 4)
            }
            .frame(minHeight: 160)
        }
    }
}

private struct ProcessPanel: View {
    let title: String
    let items: [ProcessStat]
    let value: (ProcessStat) -> String

    var body: some View {
        Panel {
            Eyebrow(title)
            if items.isEmpty {
                Text(L10n.t("Sampling…")).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            VStack(spacing: 6) {
                ForEach(items.prefix(8)) { p in
                    HStack {
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text(value(p)).monospacedDigit()
                    }
                    .font(.system(size: 12.5))
                }
            }
        }
    }
}

// MARK: - 内存

private struct MemoryPanel: View {
    let monitor: Monitor

    var body: some View {
        let mem = monitor.snapshot.mem
        Panel {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("MEMORY")
                Spacer()
                Text(L10n.t("Pressure %@ · swap %@", Labels.pressure(mem.pressure), Fmt.gb(mem.swapUsed)))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 14) {
                MemoryDial(mem: mem, size: 132, radius: 44, thick: 14, valueSize: 30)
                VStack(alignment: .leading, spacing: 8) {
                    LegendRow(swatch: .solid(1, glow: true), name: "App", value: gb(mem.app), swatchWidth: 12)
                    LegendRow(swatch: .solid(0.55, glow: false), name: L10n.t("Wired"), value: gb(mem.wired), swatchWidth: 12)
                    LegendRow(swatch: .solid(0.28, glow: false), name: L10n.t("Compressed"), value: gb(mem.compressed), swatchWidth: 12)
                    LegendRow(swatch: .solid(0.2, glow: false), name: L10n.t("Cached"), value: gb(mem.cached), dimmed: true, swatchWidth: 12)
                    LegendRow(swatch: .outline, name: L10n.t("Free"), value: gb(mem.free), dimmed: true, swatchWidth: 12)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                ForEach(monitor.processes.topMemory.prefix(3)) { p in
                    HStack { Text(p.name).lineLimit(1); Spacer(); Text(Fmt.size(p.memory)).monospacedDigit() }
                }
            }
            .font(.system(size: 12))
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
        }
    }

    private func gb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1_073_741_824) }
}

// MARK: - 网络

private struct NetworkPanel: View {
    let monitor: Monitor
    let range: TimeRange
    var chartHeight: CGFloat = 96

    var body: some View {
        let net = monitor.snapshot.net
        let (down, up) = Norm.rates(monitor.downHistory.values(last: range.seconds, maxPoints: 24),
                                    monitor.upHistory.values(last: range.seconds, maxPoints: 24))
        let d = Labels.rateParts(net.down), u = Labels.rateParts(net.up)
        let mid = chartHeight * 56 / 96
        Panel {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("NETWORK")
                Spacer()
                Text([net.interfaceKind, net.interfaceName].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? L10n.t("Not connected"))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 22) {
                bigRate(L10n.t("↓ Download"), d, dim: false)
                bigRate(L10n.t("↑ Upload"), u, dim: true)
            }
            ThreadChart(layers: [
                ThreadLayer(data: Norm.padded(down), base: mid - 2, amp: mid - 10, spread: 7, seed: 37, energy: Theme.rateEnergy(net.down),
                            strokes: [(Theme.accent, 0.55), (Theme.accent, 0.5), (Theme.accent, 0.45), (Theme.accent, 0.4)]),
                ThreadLayer(data: Norm.padded(up), base: mid + 2, amp: chartHeight - mid - 4, dir: -1, spread: 4, seed: 41, energy: Theme.rateEnergy(net.up),
                            strokes: [(.white, 0.45), (.white, 0.4)], markers: .dot),
            ], baseline: mid, period: 5.6)
            .frame(height: chartHeight)
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                row(L10n.t("Today ↓"), Fmt.total(net.todayDown))
                row(L10n.t("Today ↑"), Fmt.total(net.todayUp))
                row(L10n.t("%@ peak", range.label), Fmt.rate(monitor.downHistory.peak(last: range.seconds) ?? 0))
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
        }
    }

    private func bigRate(_ title: String, _ v: (String, String), dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                RollingNumber(text: v.0, font: Theme.dotoNS(28), color: NSColor(dim ? Theme.dim(0.8) : Theme.text))
                    .baseline(of: Theme.dotoNS(28))
                Text(v.1).font(Theme.mono(10)).foregroundStyle(Theme.tertiary).fixedSize()
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(Theme.secondary); Spacer(); Text(v).monospacedDigit() }
            .font(.system(size: 12))
    }
}

private struct NetworkTotalsPanel: View {
    let monitor: Monitor

    var body: some View {
        let n = monitor.snapshot.net
        Panel {
            Eyebrow("TOTALS")
            InfoGrid(rows: [
                (L10n.t("Today ↓"), Fmt.total(n.todayDown)),
                (L10n.t("Today ↑"), Fmt.total(n.todayUp)),
                (L10n.t("Session ↓"), Fmt.total(n.sessionDown)),
                (L10n.t("Session ↑"), Fmt.total(n.sessionUp)),
                (L10n.t("Since boot ↓"), Fmt.total(n.bootDown)),
                (L10n.t("Since boot ↑"), Fmt.total(n.bootUp)),
            ], keyWidth: 92)
        }
    }
}

// MARK: - 本机信息

private struct ThisMacPanel: View {
    let monitor: Monitor
    @State private var copied = false

    var body: some View {
        Panel {
            HStack {
                Eyebrow("THIS MAC")
                Spacer()
                Button(copied ? L10n.t("Copied") : L10n.t("Copy")) {
                    let text = rows.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
            InfoGrid(rows: rows, keyWidth: 72)
        }
    }

    private var rows: [(String, String)] {
        let m = monitor.machine
        let storage = monitor.storage.map {
            L10n.t("Used %d / %d GB", Int((Double($0.used) / 1e9).rounded()), Int((Double($0.total) / 1e9).rounded()))
        } ?? "—"
        let battery: String = {
            guard let b = monitor.battery else { return "—" }
            let parts = [b.healthPercent.map { L10n.t("Health %d%%", $0) }, b.cycleCount.map { L10n.t("%d cycles", $0) }].compactMap { $0 }
            return parts.isEmpty ? "—" : parts.joined(separator: " · ")
        }()
        return [
            (L10n.t("Mac model"), m.productName),
            (L10n.t("Chip"), "\(m.chip) · \(m.pCores)P + \(m.eCores)E" + (m.gpuCores.map { L10n.t(" · %@", L10n.cores($0)) } ?? "")),
            (L10n.t("Memory"), L10n.t("%@ GB unified memory", String(Labels.memGB(m).dropLast(2)))),
            (L10n.t("System"), m.osVersion),
            (L10n.t("Storage"), storage),
            (L10n.t("Battery"), battery),
            (L10n.t("Cooling"), m.isFanless ? L10n.t("Fanless · passive") : L10n.t("Fan · active")),
            (L10n.t("Uptime"), Fmt.duration(Date().timeIntervalSince(m.bootTime))),
        ]
    }
}

private struct InfoGrid: View {
    let rows: [(String, String)]
    let keyWidth: CGFloat

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 11) {
            ForEach(rows, id: \.0) { k, v in
                GridRow {
                    Text(k).foregroundStyle(Theme.dim(0.7)).frame(width: keyWidth, alignment: .leading)
                    Text(v).textSelection(.enabled).monospacedDigit()
                }
            }
        }
        .font(.system(size: 12.5))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// 设置：AI 用量里显示哪些工具。关掉的工具不出现在看板、卡片和筛选按钮里，后台也不再扫描它的记录
struct UsageToolToggles: View {
    @AppStorage(Prefs.usageHidden) private var hiddenRaw = ""

    var body: some View {
        let hidden = UsageVisibility.hidden(hiddenRaw)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AITool.allCases) { tool in
                let u = UsageStore.shared.usage(tool)
                let installed = u.status != .notInstalled
                Toggle(isOn: Binding(
                    get: { !hidden.contains(tool) },
                    set: { on in
                        var h = UsageVisibility.hidden(hiddenRaw)
                        if on { h.remove(tool) } else { h.insert(tool) }
                        hiddenRaw = UsageVisibility.raw(h)
                        UsageStore.shared.setEnabled(UsageVisibility.enabled)
                    }
                )) {
                    HStack(spacing: 6) {
                        Text(tool.title)
                        if !installed {
                            Text(L10n.t("Not on this Mac")).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        } else if u.isEmptyLocal {
                            Text(L10n.t("No records yet")).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12.5))
            }
            Text(L10n.t("Tools that aren't installed or have no records stay hidden until the first event. Turned-off tools are not scanned."))
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }
}
