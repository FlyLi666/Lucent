import SwiftUI

// MARK: - 偏好设置

enum Prefs {
    static let barStyle = "bar.style"
    static let interval = "sampleInterval"
    static let nativeGlass = "ui.nativeGlass"
    static let motion = "ui.motion"
    /// AI 用量里不显示的工具（逗号分隔的 AITool.rawValue），隐藏的工具后台也不扫描
    static let usageHidden = "usage.hidden"
    /// 顶部栏图标旁边显示什么（BarText）
    static let barText = "bar.text"
    /// 超过这个温度（摄氏）顶部栏和曲线上色
    static let alertTemp = "ui.alertTemp"
    /// 温度单位："c" / "f"
    static let tempUnit = "ui.tempUnit"
    /// 网速单位："bytes"（KB/s）/ "bits"（Mb/s）
    static let rateUnit = "ui.rateUnit"
    /// 卡片里显示哪些模块
    static let cardTemp = "card.showTemp"
    static let cardCPU = "card.showCPU"
    static let cardMem = "card.showMem"
    static let cardNet = "card.showNet"
    /// 卡片底部默认页签："top" / "ai"（卡片自己也记着上次选的）
    static let cardBottomTab = "card.bottomTab"

    static func register() {
        UserDefaults.standard.register(defaults: [
            barStyle: BarStyle.ring.rawValue, interval: 2.0, nativeGlass: true, motion: true,
            barText: BarText.temp.rawValue, alertTemp: 85.0, tempUnit: "c", rateUnit: "bytes",
            cardTemp: true, cardCPU: true, cardMem: true, cardNet: true,
        ])
    }

    static var fahrenheit: Bool { UserDefaults.standard.string(forKey: tempUnit) == "f" }
    static var bits: Bool { UserDefaults.standard.string(forKey: rateUnit) == "bits" }
    static var text: BarText { BarText(rawValue: UserDefaults.standard.string(forKey: barText) ?? "") ?? .temp }

    static var sampleInterval: Double { UserDefaults.standard.double(forKey: interval) }

    static var style: BarStyle {
        BarStyle(rawValue: UserDefaults.standard.string(forKey: barStyle) ?? "") ?? .ring
    }
}

/// 顶部栏图标样式（docs/design/menu.html）
enum BarStyle: String, CaseIterable, Identifiable {
    case ring, pulse, orbit
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ring: return "刻度环"
        case .pulse: return "能量线"
        case .orbit: return "双轨"
        }
    }

    var subtitle: String {
        switch self {
        case .ring: return "亮起的刻度 = CPU，旁边是温度"
        case .pulse: return "迷你脉冲线随 CPU 起伏"
        case .orbit: return "外圈 CPU，内圈内存，不占字位"
        }
    }
}

/// 顶部栏图标旁边的文字（双轨样式没有字位，不显示）
enum BarText: String, CaseIterable, Identifiable {
    case temp, cpu, mem, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .temp: return "温度"
        case .cpu: return "CPU"
        case .mem: return "内存"
        case .none: return "不显示"
        }
    }
}

// MARK: - 格式化

enum Fmt {
    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    /// 内部一律存摄氏，显示时按设置换算
    static func temp(_ t: Double?) -> String {
        guard let t else { return "--" }
        return "\(tempValue(t))°"
    }

    /// 只要数字："65" / "149"
    static func tempValue(_ t: Double?) -> String {
        guard let t else { return "--" }
        return "\(Int((Prefs.fahrenheit ? t * 9 / 5 + 32 : t).rounded()))"
    }

    static var tempUnit: String { Prefs.fahrenheit ? "°F" : "°C" }

    static func gb(_ bytes: UInt64, digits: Int = 1) -> String {
        String(format: "%.\(digits)f GB", Double(bytes) / 1_073_741_824)
    }

    static func size(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb < 1024 { return String(format: mb < 10 ? "%.1f MB" : "%.0f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    static func total(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    /// 视图里用："1.2 MB/s"
    static func rate(_ bps: Double) -> String {
        let bits = Prefs.bits
        let units = bits ? ["Kbps", "Mbps", "Gbps"] : ["KB/s", "MB/s", "GB/s"]
        var x = (bits ? bps * 8 : bps) / 1000, i = 0
        while x >= 999.5 && i < units.count - 1 { x /= 1000; i += 1 }
        return String(format: x < 10 ? "%.1f " : "%.0f ", x) + units[i]
    }

    /// 菜单栏用，最长 4 个字符："1.2M"、"856K"
    static func compactRate(_ bps: Double) -> String {
        let units = ["K", "M", "G"]
        var x = (Prefs.bits ? bps * 8 : bps) / 1000, i = 0
        while x >= 999.5 && i < units.count - 1 { x /= 1000; i += 1 }
        return String(format: x < 10 ? "%.1f" : "%.0f", x) + units[i]
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = max(Int(t) / 60, 0), h = m / 60, d = h / 24
        if d > 0 { return "\(d) 天 \(h % 24) 小时" }
        if h > 0 { return "\(h) 小时 \(m % 60) 分" }
        return "\(m) 分钟"
    }
}

// MARK: - 配色

enum Palette {
    static let cpu = Color.blue
    static let eCore = Color.teal
    static let mem = Color.purple
    static let down = Color.cyan
    static let up = Color.pink

    static func temp(_ t: Double?) -> Color {
        guard let t else { return .secondary }
        switch t {
        case ..<55: return .mint
        case ..<75: return .green
        case ..<88: return .yellow
        case ..<98: return .orange
        default: return .red
        }
    }

    static func load(_ f: Double) -> Color {
        f < 0.6 ? cpu : (f < 0.85 ? .orange : .red)
    }

    static func pressure(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }

    static func thermal(_ s: ProcessInfo.ThermalState) -> Color {
        switch s {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }
}
