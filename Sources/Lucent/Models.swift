import Foundation

// 所有采样结果都是值类型，在后台队列生成，一次性交给主线程。

struct CPUStat: Sendable {
    var total: Double = 0      // 0...1
    var user: Double = 0
    var system: Double = 0
    var cores: [Double] = []   // 每个逻辑核 0...1
}

enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "紧张"
        case .critical: return "严重"
        }
    }
}

struct MemoryStat: Sendable {
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var used: UInt64 = 0        // = App + 联动 + 压缩，与“活动监视器”一致
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: MemoryPressure = .normal

    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct NetworkStat: Sendable {
    var down: Double = 0          // 字节/秒
    var up: Double = 0
    var sessionDown: UInt64 = 0   // 本次运行以来
    var sessionUp: UInt64 = 0
    var bootDown: UInt64 = 0      // 开机以来
    var bootUp: UInt64 = 0

    var interfaceName: String?    // 当前主要活动接口 BSD 名，如 "en0"
    var interfaceKind: String?    // "Wi‑Fi" / "以太网" / "蜂窝"，判断不了为 nil
    var todayDown: UInt64 = 0     // 本地自然日累计字节，跨午夜清零
    var todayUp: UInt64 = 0
}

/// 启动卷使用情况（"/"），口径尽量与"关于本机"一致。
struct StorageStat: Sendable {
    var used: UInt64
    var total: UInt64
}

/// IOKit AppleSmartBattery 的健康度；台式机没有电池则整体为 nil。
struct BatteryHealth: Sendable {
    var healthPercent: Int?   // AppleRawMaxCapacity(或 NominalChargeCapacity) / DesignCapacity，取整百分比，0...100
    var cycleCount: Int?
}

/// 本进程（Lucent 自身）的 CPU 与内存占用。
struct SelfUsage: Sendable {
    var cpu: Double       // 0...100*核数
    var memory: UInt64    // phys_footprint
}

enum SensorGroup: Int, Sendable, CaseIterable, Comparable {
    case cpuP, cpuE, gpu, soc, battery, storage, wireless, other

    var title: String {
        switch self {
        case .cpuP: return "性能核"
        case .cpuE: return "能效核"
        case .gpu: return "GPU"
        case .soc: return "SoC"
        case .battery: return "电池"
        case .storage: return "存储"
        case .wireless: return "无线"
        case .other: return "其他"
        }
    }

    /// 菜单栏常驻时只读这些，节省 SMC 调用
    var isPrimary: Bool {
        switch self {
        case .cpuP, .cpuE, .gpu, .soc, .battery: return true
        default: return false
        }
    }

    static func < (a: SensorGroup, b: SensorGroup) -> Bool { a.rawValue < b.rawValue }

    /// Apple Silicon SMC 键前缀：Tp 性能核、Te 能效核、Tg GPU、Tf SoC(M3)、TB 电池、TH 存储、TW 无线
    static func from(key name: String) -> SensorGroup {
        switch name.prefix(2) {
        case "Tp": return .cpuP
        case "Te": return .cpuE
        case "Tg": return .gpu
        case "Tf": return .soc
        case "TB": return .battery
        case "TH": return .storage
        case "TW": return .wireless
        default: return .other
        }
    }
}

struct Sensor: Sendable, Identifiable {
    let id: String          // SMC 键名
    let group: SensorGroup
    let value: Double
}

struct ThermalStat: Sendable {
    var available = false
    var cpuAvg: Double?
    var cpuMax: Double?
    var gpu: Double?
    var battery: Double?
    var sensors: [Sensor] = []          // 只有主页面打开时才填充
    var state: ProcessInfo.ThermalState = .nominal
}

struct Snapshot: Sendable {
    var cpu = CPUStat()
    var mem = MemoryStat()
    var net = NetworkStat()
    var thermal = ThermalStat()
    var load: [Double] = [0, 0, 0]
    var date = Date()

    // 只在 dashboard 打开时才有值；Monitor.ingest 会保留最近一次非 nil 的值。
    var storage: StorageStat?
    var battery: BatteryHealth?
    var selfUsage: SelfUsage?
}

struct ProcessStat: Sendable, Identifiable {
    let id: pid_t
    let name: String
    let cpu: Double      // %，多线程可超过 100
    let memory: UInt64   // 物理占用（phys_footprint）
}

struct ProcessSnapshot: Sendable {
    var topCPU: [ProcessStat] = []
    var topMemory: [ProcessStat] = []
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "偏高"
        case .serious: return "降频中"
        case .critical: return "危急"
        @unknown default: return "未知"
        }
    }
}
