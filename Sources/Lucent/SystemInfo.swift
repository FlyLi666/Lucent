import Foundation
import IOKit

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func int(_ name: String) -> Int? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
    }
}

/// 静态的机器信息，启动时读一次。
struct MachineInfo: Sendable {
    let productName: String
    let modelID: String
    let chip: String
    let pCores: Int
    let eCores: Int
    let gpuCores: Int?
    let memory: UInt64
    let osVersion: String
    let hostName: String
    let bootTime: Date

    var isFanless: Bool { productName.contains("MacBook Air") }

    /// `CPUStat.cores` 里哪些下标是能效核 / 性能核。
    ///
    /// 核实依据（本机 Mac16,12 / Apple M4，6 能效核 + 4 性能核）：
    /// `ioreg -c IOPlatformDevice -r -d2` 下 `IODeviceTree:/cpus` 的 cpu0...cpu9 节点里，
    /// cpu0‑cpu5 的 "cluster-type"="E"、"logical-cpu-id"=0...5，cpu6‑cpu9 的
    /// "cluster-type"="P"、"logical-cpu-id"=6...9——即 logical-cpu-id 低编号是能效核、
    /// 高编号是性能核，且与 hw.perflevel1(Efficiency)=6、hw.perflevel0(Performance)=4
    /// 的核数分组完全对应。`host_processor_info` 按 logical-cpu-id 顺序返回核心。
    ///
    /// 交叉验证：AirStats (MIT, byrencheema/airstats) 的 Collectors/CPUCollector.swift
    /// 用另一种独立方法核实过同一件事——用后台 QoS 和用户交互 QoS 的线程分别去跑满某几个
    /// 核心，观察 host_processor_info 哪些下标被打满——结论同样是低编号在前、从最后一级
    /// perflevel 往 perflevel0 排列，和这里用 IORegistry 核实的结果一致。两种独立方法
    /// 吻合，这是 Apple Silicon（M1–M4 各代）上的一贯行为，目前没有见到顺序会变的反例，
    /// 项目 README「低编号是能效核」的说法得到确认。
    var eCoreIndices: Range<Int> { 0..<eCores }
    var pCoreIndices: Range<Int> { eCores..<(eCores + pCores) }

    static let current = MachineInfo()

    private init() {
        modelID = Sysctl.string("hw.model") ?? "Mac"
        productName = Self.registryProductName() ?? modelID
        chip = Sysctl.string("machdep.cpu.brand_string") ?? "Apple Silicon"
        let logical = ProcessInfo.processInfo.activeProcessorCount
        pCores = Sysctl.int("hw.perflevel0.logicalcpu") ?? logical
        eCores = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
        gpuCores = Self.gpuCoreCount()
        memory = ProcessInfo.processInfo.physicalMemory

        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = Sysctl.string("kern.osversion").map { " (\($0))" } ?? ""
        osVersion = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "") + build

        let host = Sysctl.string("kern.hostname") ?? ""
        hostName = host.hasSuffix(".local") ? String(host.dropLast(6)) : host

        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 {
            bootTime = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
        } else {
            bootTime = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        }
    }

    /// 例如 "MacBook Air (13-inch, M4, 2025)"
    private static func registryProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let s = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    private static func gpuCoreCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }
}
