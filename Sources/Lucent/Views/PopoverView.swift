import SwiftUI

/// 左键弹出卡片（docs/design/popover.html）
struct PopoverView: View {
    let monitor: Monitor
    var openDashboard: () -> Void
    var openSettings: () -> Void

    /// 卡片里的曲线看最近 2 分钟
    private let span: TimeInterval = 120
    /// 底部列表：进程 TOP 3，或 AI 用量
    @AppStorage(Prefs.cardBottomTab) private var bottomTab = "top"
    @Namespace private var tabNS
    @AppStorage(Prefs.cardTemp) private var showTemp = true
    @AppStorage(Prefs.cardCPU) private var showCPU = true
    @AppStorage(Prefs.cardMem) private var showMem = true
    @AppStorage(Prefs.cardNet) private var showNet = true

    var body: some View {
        let s = monitor.snapshot
        let m = monitor.machine
        VStack(spacing: 10) {
            header(s, m)
            if showTemp { tempCard(s) }
            if showCPU { cpuCard(s, m) }
            if showMem { memCard(s) }
            if showNet { netCard(s) }
            topList
            buttons
        }
        .padding(14)
        .frame(width: 360)
        .foregroundStyle(Theme.text)
        .glassShell(radius: 26)
        .environment(\.colorScheme, .dark)
    }

    // MARK: 头部

    private func header(_ s: Snapshot, _ m: MachineInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(Labels.shortName(m)).font(.system(size: 15, weight: .semibold))
                Text("\(Labels.chip(m)) · \(Labels.memGB(m)) · UP \(Labels.uptime(m))")
                    .font(Theme.mono(10.5)).tracking(0.6).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            StatusPill(status: Labels.status(s))
        }
        .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 4))
    }

    // MARK: 温度

    private func tempCard(_ s: Snapshot) -> some View {
        let t = s.thermal.cpuAvg
        let peak = monitor.tempHistory.peak(last: 600)
        let data = Norm.padded(Norm.temp(monitor.tempHistory.values(last: span, maxPoints: 24)))
        return Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow("TEMP · CPU")
                        Text("峰值 \(Fmt.temp(peak)) · 热状态 \(s.thermal.state.label)")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    .padding(.bottom, 4)
                    Spacer()
                    DotNumber(value: Fmt.tempValue(t), unit: Fmt.tempUnit,
                              size: 52, unitSize: 20, unitColor: Theme.heat)
                }
                ThreadChart(layers: [
                    ThreadLayer(data: data, base: 70, amp: 62, spread: 7, seed: 11, energy: Theme.tempEnergy(t),
                                strokes: Theme.heatStrokes(t, [0.6, 0.5, 0.45, 0.45, 0.4, 0.4])),
                ], period: 5.2)
                .frame(height: 76)
            }
        }
    }

    // MARK: CPU

    private func cpuCard(_ s: Snapshot, _ m: MachineInfo) -> some View {
        let data = Norm.padded(monitor.cpuHistory.values(last: span, maxPoints: 24))
        let split = Labels.coreSplit(s, m)
        return Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow("CPU")
                        Text("性能核 \(Fmt.percent(split.p)) · 能效核 \(Fmt.percent(split.e))")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    .padding(.bottom, 2)
                    Spacer()
                    DotNumber(value: "\(Int((s.cpu.total * 100).rounded()))", unit: "%", size: 38, unitSize: 18, glow: 0.3)
                }
                ThreadChart(layers: [
                    ThreadLayer(data: data, base: 54, amp: 48, spread: 6, seed: 23, energy: min(s.cpu.total * 1.25, 1),
                                strokes: Theme.heatStrokes(s.thermal.cpuAvg, [0.55, 0.5, 0.45, 0.45, 0.4, 0.4])),
                ], period: 4.6)
                .frame(height: 58)
            }
        }
    }

    // MARK: 内存

    private func memCard(_ s: Snapshot) -> some View {
        let mem = s.mem
        return Card(padding: EdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 16)) {
            HStack(spacing: 16) {
                MemoryDial(mem: mem, size: 120, radius: 40, thick: 12, valueSize: 26)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Eyebrow("MEMORY")
                        Spacer()
                        Text("压力 \(Labels.pressure(mem.pressure))")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    }
                    LegendRow(swatch: .solid(1, glow: true), name: "App", value: Fmt.gb(mem.app))
                    LegendRow(swatch: .solid(0.55, glow: false), name: "联动", value: Fmt.gb(mem.wired))
                    LegendRow(swatch: .solid(0.28, glow: false), name: "已压缩", value: Fmt.gb(mem.compressed))
                    LegendRow(swatch: .solid(0.12, glow: false), name: "交换", value: Fmt.gb(mem.swapUsed), dimmed: true)
                }
            }
        }
    }

    // MARK: 网络

    private func netCard(_ s: Snapshot) -> some View {
        let (down, up) = Norm.rates(monitor.downHistory.values(last: span, maxPoints: 24),
                                    monitor.upHistory.values(last: span, maxPoints: 24))
        let d = Labels.rateParts(s.net.down), u = Labels.rateParts(s.net.up)
        return Card(padding: EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Eyebrow("NET · " + (s.net.interfaceKind?.uppercased() ?? "—"))
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        RateLabel(arrow: "↓", value: d.0, unit: d.1, size: 20, dim: false)
                        RateLabel(arrow: "↑", value: u.0, unit: u.1, size: 20, dim: true)
                    }
                }
                ThreadChart(layers: [
                    ThreadLayer(data: Norm.padded(down), base: 38, amp: 34, spread: 6, seed: 37, energy: Theme.rateEnergy(s.net.down),
                                strokes: [(Theme.accent, 0.55), (Theme.accent, 0.5), (Theme.accent, 0.45), (Theme.accent, 0.4)],
                                markers: .ring),
                    ThreadLayer(data: Norm.padded(up), base: 42, amp: 30, dir: -1, spread: 4, seed: 41, energy: Theme.rateEnergy(s.net.up),
                                strokes: [(.white, 0.45), (.white, 0.4)], markers: .dot),
                ], baseline: 40, period: 5.6)
                .frame(height: 72)
            }
        }
    }

    // MARK: 进程

    private var topList: some View {
        let procs = Array(monitor.processes.topCPU.prefix(3))
        let ai = bottomTab == "ai"
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                tab("TOP", on: !ai) { UIMotion.run { bottomTab = "top" } }
                tab("AI", on: ai) { UIMotion.run { bottomTab = "ai" } }
                Spacer()
                Text(ai ? "额度 · 今日" : "CPU · MEM")
                    .id(ai)
                    .transition(.opacity)
            }
            .font(Theme.mono(10)).tracking(1.2).foregroundStyle(Theme.dim(0.58))
            .padding(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))

            ZStack(alignment: .top) {
                if ai {
                    VStack(spacing: 0) { UsageCardRows(store: UsageStore.shared) }
                        .transition(UIMotion.contentSwap)
                } else {
                    VStack(spacing: 0) { processRows(procs) }
                        .transition(UIMotion.contentSwap)
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(EdgeInsets(top: 4, leading: 6, bottom: 0, trailing: 6))
    }

    private func tab(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(on ? Theme.text : Theme.dim(0.45))
                .overlay(alignment: .bottom) {
                    // 下划线只有一条，切换时滑过去
                    if on {
                        Capsule().fill(Theme.accent).frame(height: 1.5).offset(y: 4)
                            .shadow(color: Theme.accent, radius: 3)
                            .matchedGeometryEffect(id: "underline", in: tabNS)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func processRows(_ procs: [ProcessStat]) -> some View {
            ForEach(procs) { p in
                HStack {
                    Text(p.name).lineLimit(1)
                    Spacer()
                    HStack(spacing: 14) {
                        Text(String(format: "%.1f%%", p.cpu))
                        Text(Fmt.size(p.memory)).frame(width: 60, alignment: .trailing)
                    }
                    .monospacedDigit()
                    .foregroundStyle(Theme.dim(0.84))
                }
                .frame(height: 26)
                .padding(.horizontal, 8)
            }
            // 首次打开进程数据还没到：占住 3 行高度，卡片尺寸不跳
            if procs.count < 3 {
                Text(procs.isEmpty ? "采集中…" : "")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: CGFloat(3 - procs.count) * 26)
            }
    }

    // MARK: 按钮

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(action: openDashboard) {
                HStack {
                    Text("打开主窗口").fontWeight(.semibold)
                    Spacer()
                    Text("⌘O").foregroundStyle(Theme.dim(0.7))
                }
                .font(.system(size: 13))
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(.white.opacity(0.1), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .contentShape(Capsule())
            }
            .keyboardShortcut("o", modifiers: .command)

            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.06), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .contentShape(Circle())
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("设置")
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

// MARK: - 共用小部件

struct StatusPill: View {
    let status: Labels.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.alert ? Theme.heat : .white)
                .frame(width: 6, height: 6)
                .shadow(color: (status.alert ? Theme.heat : .white).opacity(0.9), radius: 4)
            Text(status.text)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.dim(0.86))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

struct RateLabel: View {
    let arrow: String
    let value: String
    let unit: String
    var size: CGFloat
    var dim: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(arrow).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            RollingNumber(text: value, font: Theme.dotoNS(size), color: NSColor(dim ? Theme.dim(0.78) : Theme.text))
                .baseline(of: Theme.dotoNS(size))
            Text(unit).font(Theme.mono(10)).foregroundStyle(Theme.tertiary).fixedSize()
        }
        .fixedSize()
    }
}

/// 内存环 + 中间的已用 GB
struct MemoryDial: View {
    let mem: MemoryStat
    var size: CGFloat
    var radius: CGFloat
    var thick: CGFloat
    var valueSize: CGFloat

    var body: some View {
        let total = Double(max(mem.total, 1))
        let a = Double(mem.app) / total, w = Double(mem.wired) / total, c = Double(mem.compressed) / total
        ZStack {
            MemoryRing(segments: [
                .init(from: 0, to: a, weight: 1),
                .init(from: a + 0.01, to: a + w, weight: 0.65),
                .init(from: a + w + 0.01, to: a + w + c, weight: 0.35),
            ], radius: radius, thick: thick)
            RingSweep(used: mem.usedFraction, radius: radius, thick: thick)
            VStack(spacing: 2) {
                RollingNumber(text: String(format: "%.1f", Double(mem.used) / 1_073_741_824),
                              font: Theme.dotoNS(valueSize), color: NSColor(Theme.text), glow: 0.3, glowRadius: 6)
                Text("/ \(Int((Double(mem.total) / 1_073_741_824).rounded())) GB")
                    .font(Theme.mono(9.5)).tracking(0.8).foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 文案

enum Labels {
    struct Status { var text: String; var alert: Bool }

    /// "MacBook Air (13-inch, M4, 2025)" → "MacBook Air"
    static func shortName(_ m: MachineInfo) -> String {
        m.productName.components(separatedBy: " (").first ?? m.productName
    }

    /// "Apple M4" → "M4"
    static func chip(_ m: MachineInfo) -> String {
        m.chip.replacingOccurrences(of: "Apple ", with: "")
    }

    static func memGB(_ m: MachineInfo) -> String { "\(Int((Double(m.memory) / 1_073_741_824).rounded()))GB" }

    /// "3D 04H"、"5H 12M"
    static func uptime(_ m: MachineInfo) -> String {
        let t = Int(Date().timeIntervalSince(m.bootTime)) / 60
        let d = t / 1440, h = (t / 60) % 24, mm = t % 60
        return d > 0 ? String(format: "%dD %02dH", d, h) : String(format: "%dH %02dM", h, mm)
    }

    static func status(_ s: Snapshot) -> Status {
        if s.thermal.state == .serious || s.thermal.state == .critical || (s.thermal.cpuAvg ?? 0) >= Theme.alertTemp {
            return Status(text: "温度偏高", alert: true)
        }
        if s.mem.pressure != .normal { return Status(text: "内存紧张", alert: true) }
        if s.cpu.total >= 0.85 { return Status(text: "负载较高", alert: true) }
        return Status(text: "运行平稳", alert: false)
    }

    static func pressure(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: return "低"
        case .warning: return "中"
        case .critical: return "高"
        }
    }

    /// 性能核 / 能效核各自的平均占用
    static func coreSplit(_ s: Snapshot, _ m: MachineInfo) -> (p: Double, e: Double) {
        func avg(_ r: Range<Int>) -> Double {
            let v = r.compactMap { s.cpu.cores.indices.contains($0) ? s.cpu.cores[$0] : nil }
            return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
        }
        return (avg(m.pCoreIndices), avg(m.eCoreIndices))
    }

    /// "2.4 MB/s" → ("2.4", "MB/s")
    static func rateParts(_ bps: Double) -> (String, String) {
        let parts = Fmt.rate(bps).split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? "0", parts.count > 1 ? parts[1] : "")
    }
}
