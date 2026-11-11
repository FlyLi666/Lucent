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
        case .overview: return L("概览")
        case .thermal: return L("温度")
        case .cpu: return L("处理器")
        case .memory: return L("内存")
        case .network: return L("网络")
        case .ai: return L("AI 用量")
        case .info: return L("本机信息")
        case .settings: return L("设置")
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
        case .minute: return L("1 分钟")
        case .tenMinutes: return L("10 分钟")
        case .hour: return L("1 小时")
        }
    }
}

struct DashboardView: View {
    let monitor: Monitor
    @Bindable var nav: DashboardNav
    @AppStorage("dash.range") private var range: TimeRange = .tenMinutes
    @AppStorage(Prefs.nativeGlass) private var nativeGlass = true

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
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(nav.section.title)
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.4)
                    .id(nav.section)
                    .transition(UIMotion.contentSwap)
                // 开机时长和采样间隔跟 AI 用量无关：那一页不显示，但占着位置，切分区时标题不跳
                Text(nav.section == .settings ? L("改动立即生效") : L("已开机 \(Labels.uptime(monitor.machine)) · 每 \(Int(Prefs.sampleInterval)) 秒采样"))
                    .font(Theme.mono(10.5)).tracking(1).foregroundStyle(Theme.tertiary)
                    .opacity(nav.section == .ai ? 0 : 1)
                    .accessibilityHidden(nav.section == .ai)
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
                    HistoryPanel(title: L("CPU · 历史"), values: monitor.cpuHistory.values(last: r, maxPoints: 40), seed: 23,
                                 caption: L("\(range.label)峰值 \(Fmt.percent(monitor.cpuHistory.peak(last: r) ?? 0))"))
                    CPUPanel(monitor: monitor)
                }
                ProcessPanel(title: L("CPU 占用最高"), items: monitor.processes.topCPU) { String(format: "%.1f%%", $0.cpu) }
            }
        case .memory:
            VStack(spacing: 14) {
                RatioRow(ratio: 1.37, spacing: 14) {
                    HistoryPanel(title: L("内存 · 历史"), values: monitor.memHistory.values(last: r, maxPoints: 40), seed: 7,
                                 caption: L("\(range.label)峰值 \(Fmt.percent(monitor.memHistory.peak(last: r) ?? 0))"))
                    MemoryPanel(monitor: monitor)
                }
                ProcessPanel(title: L("内存占用最高"), items: monitor.processes.topMemory) { Fmt.size($0.memory) }
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
                Text("\(Labels.chip(m)) · \(Labels.memGB(m)) · macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)")
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
                .accessibilityAddTraits(selected ? .isSelected : [])
                .onHover { inside in
                    UIMotion.run(.easeOut(duration: 0.12)) { hovered = inside ? s : (hovered == s ? nil : hovered) }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(L("Lucent 占用"), size: 9.5, tracking: 1.2)
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
                .help(L("设置（⌘,）"))
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
        return String(format: "CPU %.1f%%", u.cpu) + "\n" + L("内存 \(Fmt.size(u.memory))")
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
    var fill = false              // 占满父级给的高度（下面的内容按自身高度收时，把余下的高度都拿走）

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 900
        let (a, b) = widths(w)
        if let height { return CGSize(width: w, height: height) }
        if fill, let h = proposal.height { return CGSize(width: w, height: h) }
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
                    Eyebrow(L("温度"))
                    DotNumber(value: Fmt.tempValue(s.thermal.cpuAvg), unit: Fmt.tempUnit,
                              size: 64, unitSize: 24, unitColor: Theme.heat)
                }
                Spacer()
                Caption(lines: [
                    L("热状态 \(s.thermal.state.label)"),
                    L("\(range.label)峰值 \(Fmt.temp(peak)) · ") + (monitor.machine.isFanless ? L("无风扇被动散热") : L("风扇主动散热")),
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
            (L("性能核"), avg(.cpuP) ?? t.cpuMax),
            (L("能效核"), avg(.cpuE)),
            ("GPU", avg(.gpu) ?? t.gpu),
            ("SSD", avg(.storage)),
            (L("电池"), avg(.battery) ?? t.battery),
        ]
    }
}

private struct SensorListPanel: View {
    let monitor: Monitor

    var body: some View {
        let groups = Dictionary(grouping: monitor.snapshot.thermal.sensors, by: \.group)
        Panel {
            Eyebrow(L("全部传感器 · \(monitor.snapshot.thermal.sensors.count)"))
            if groups.isEmpty {
                Text(L("没有读到温度传感器")).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
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
                    Eyebrow(L("CPU · \(s.cpu.cores.count) 核"))
                    DotNumber(value: "\(Int((s.cpu.total * 100).rounded()))", unit: "%", size: 64, unitSize: 24)
                }
                Spacer()
                Caption(lines: [
                    L("用户 \(Fmt.percent(s.cpu.user)) · 系统 \(Fmt.percent(s.cpu.system))"),
                    L("负载 ") + s.load.map { String(format: "%.2f", $0) }.joined(separator: " · "),
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
                if !p.isEmpty { Text(L("性能核 P1–P\(p.count) · \(Fmt.percent(split.p))")) }
                Spacer()
                if !e.isEmpty { Text(L("能效核 E1–E\(e.count) · \(Fmt.percent(split.e))")) }
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
                Text(L("采集中…")).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
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
                Eyebrow(L("内存"))
                Spacer()
                Text(L("压力 \(Labels.pressure(mem.pressure)) · 交换 \(Fmt.gb(mem.swapUsed))"))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            // 英文图例（Compressed）比中文长：默认窗口宽度下圆环略收、字号小一号，免得截断
            let en = L10n.isEnglish
            HStack(spacing: en ? 12 : 14) {
                MemoryDial(mem: mem, size: en ? 124 : 132, radius: en ? 41 : 44, thick: 14, valueSize: 30)
                VStack(alignment: .leading, spacing: 8) {
                    LegendRow(swatch: .solid(1, glow: true), name: L("应用"), value: gb(mem.app), swatchWidth: 12, fontSize: en ? 11 : 12)
                    LegendRow(swatch: .solid(0.55, glow: false), name: L("联动"), value: gb(mem.wired), swatchWidth: 12, fontSize: en ? 11 : 12)
                    LegendRow(swatch: .solid(0.28, glow: false), name: L("已压缩"), value: gb(mem.compressed), swatchWidth: 12, fontSize: en ? 11 : 12)
                    LegendRow(swatch: .solid(0.2, glow: false), name: L("缓存"), value: gb(mem.cached), dimmed: true, swatchWidth: 12, fontSize: en ? 11 : 12)
                    LegendRow(swatch: .outline, name: L("可用"), value: gb(mem.free), dimmed: true, swatchWidth: 12, fontSize: en ? 11 : 12)
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
                Eyebrow(L("网络"))
                Spacer()
                Text([net.interfaceKind?.title, net.interfaceName].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? L("未连接"))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 22) {
                bigRate(L("↓ 下载"), d, dim: false)
                bigRate(L("↑ 上传"), u, dim: true)
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
                row(L("今日下载"), Fmt.total(net.todayDown))
                row(L("今日上传"), Fmt.total(net.todayUp))
                row(L("\(range.label)峰值"), Fmt.rate(monitor.downHistory.peak(last: range.seconds) ?? 0))
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
            Eyebrow(L("累计流量"))
            InfoGrid(rows: [
                (L("今日下载"), Fmt.total(n.todayDown)),
                (L("今日上传"), Fmt.total(n.todayUp)),
                (L("本次下载"), Fmt.total(n.sessionDown)),
                (L("本次上传"), Fmt.total(n.sessionUp)),
                (L("开机下载"), Fmt.total(n.bootDown)),
                (L("开机上传"), Fmt.total(n.bootUp)),
            ], keyWidth: 64)
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
                Eyebrow(L("这台 Mac"))
                Spacer()
                Button(copied ? L("已复制") : L("复制")) {
                    let text = rows.map { L("\($0.0)：\($0.1)") }.joined(separator: "\n")
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
            InfoGrid(rows: rows, keyWidth: 52)
        }
    }

    private var rows: [(String, String)] {
        let m = monitor.machine
        let storage = monitor.storage.map {
            L("已用 \(Int((Double($0.used) / 1e9).rounded())) / \(Int((Double($0.total) / 1e9).rounded())) GB")
        } ?? "—"
        let battery: String = {
            guard let b = monitor.battery else { return "—" }
            let parts = [b.healthPercent.map { L("健康 \($0)%") }, b.cycleCount.map { L("循环 \($0)") }].compactMap { $0 }
            return parts.isEmpty ? "—" : parts.joined(separator: " · ")
        }()
        return [
            (L("型号"), m.productName),
            (L("芯片"), "\(m.chip) · \(m.pCores)P + \(m.eCores)E" + (m.gpuCores.map { L(" · \($0) 核 GPU") } ?? "")),
            (L("内存"), L("\(Labels.memGB(m).dropLast(2)) GB 统一内存")),
            (L("系统"), m.osVersion),
            (L("存储"), storage),
            (L("电池"), battery),
            (L("散热"), m.isFanless ? L("无风扇 · 被动散热") : L("风扇 · 主动散热")),
            (L("运行"), Fmt.duration(Date().timeIntervalSince(m.bootTime))),
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
                            Text(L("本机没装")).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        } else if u.isEmptyLocal {
                            Text(L("暂无记录")).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12.5))
            }
            Text(L("没装或还没有记录的工具即使打开也不显示，有了第一条记录会自动出现。关掉的工具后台不再读取它的记录。"))
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }
}
