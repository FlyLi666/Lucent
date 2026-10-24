import Foundation
import Darwin
import IOKit
import SystemConfiguration

// 每个 Reader 只在采样队列上使用，内部缓冲区复用，避免每次采样分配内存。

// MARK: - CPU

final class CPUReader {
    private let host = mach_host_self()          // 只取一次，避免每次调用泄漏端口引用
    private var prev: [UInt32] = []
    private var cores: [Double] = []

    func sample() -> CPUStat {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPUStat() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let n = Int(cpuCount)
        let s = Int(CPU_STATE_MAX)
        let iU = Int(CPU_STATE_USER), iS = Int(CPU_STATE_SYSTEM), iI = Int(CPU_STATE_IDLE), iN = Int(CPU_STATE_NICE)
        if prev.count != n * s { prev = Array(repeating: 0, count: n * s) }
        if cores.count != n { cores = Array(repeating: 0, count: n) }

        var tUser: UInt64 = 0, tSys: UInt64 = 0, tAll: UInt64 = 0
        for c in 0..<n {
            let b = c * s
            let user = UInt32(bitPattern: info[b + iU])
            let sys = UInt32(bitPattern: info[b + iS])
            let idle = UInt32(bitPattern: info[b + iI])
            let nice = UInt32(bitPattern: info[b + iN])
            // &- 处理计数器回绕
            let du = UInt64(user &- prev[b + iU]) + UInt64(nice &- prev[b + iN])
            let ds = UInt64(sys &- prev[b + iS])
            let di = UInt64(idle &- prev[b + iI])
            let all = du + ds + di
            cores[c] = all > 0 ? Double(du + ds) / Double(all) : 0
            tUser += du; tSys += ds; tAll += all
            prev[b + iU] = user; prev[b + iS] = sys; prev[b + iI] = idle; prev[b + iN] = nice
        }

        var stat = CPUStat()
        if tAll > 0 {
            stat.user = Double(tUser) / Double(tAll)
            stat.system = Double(tSys) / Double(tAll)
            stat.total = stat.user + stat.system
        }
        stat.cores = cores
        return stat
    }
}

// MARK: - 内存

final class MemoryReader {
    private let host = mach_host_self()
    private let pageSize: UInt64

    init() {
        var ps: vm_size_t = 0
        host_page_size(host, &ps)
        pageSize = UInt64(ps)
    }

    func sample() -> MemoryStat {
        var m = MemoryStat()
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let p = pageSize
            let internalPages = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            let free = UInt64(vm.free_count), spec = UInt64(vm.speculative_count)
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * p
            m.wired = UInt64(vm.wire_count) * p
            m.compressed = UInt64(vm.compressor_page_count) * p
            m.cached = (UInt64(vm.external_page_count) + purgeable) * p
            m.free = (free > spec ? free - spec : 0) * p
            m.used = min(m.app + m.wired + m.compressed, m.total)
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used
            m.swapTotal = swap.xsu_total
        }

        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            m.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
        return m
    }
}

// MARK: - 网络

/// 用 NET_RT_IFLIST2 读 64 位接口计数器（getifaddrs 是 32 位，4GB 就回绕）。
/// 只统计 en*（Wi‑Fi/有线）和 pdp_ip*（蜂窝），排除 lo、utun(VPN 会重复计算)、awdl 等。
final class NetworkReader {
    private var buffer = [UInt8]()
    private var include: [String: Bool] = [:]
    private var lastIn: UInt64 = 0, lastOut: UInt64 = 0, lastTime: UInt64 = 0
    private var baseIn: UInt64?, baseOut: UInt64 = 0
    private var samples = 0

    func sample() -> NetworkStat {
        samples &+= 1
        if samples % 300 == 0 { include.removeAll(keepingCapacity: true) } // 接口热插拔后索引可能变化

        let (inB, outB) = counters()
        let now = DispatchTime.now().uptimeNanoseconds
        var s = NetworkStat()
        s.bootDown = inB
        s.bootUp = outB

        if baseIn == nil { baseIn = inB; baseOut = outB }
        if let base = baseIn {
            s.sessionDown = inB >= base ? inB - base : 0
            s.sessionUp = outB >= baseOut ? outB - baseOut : 0
        }
        if lastTime > 0, now > lastTime {
            let dt = Double(now - lastTime) / 1e9
            s.down = inB >= lastIn ? Double(inB - lastIn) / dt : 0
            s.up = outB >= lastOut ? Double(outB - lastOut) / dt : 0
        }
        lastIn = inB; lastOut = outB; lastTime = now

        updateToday(inB: inB, outB: outB)
        refreshInterfaceIfNeeded()
        s.todayDown = todayDown
        s.todayUp = todayUp
        s.interfaceName = cachedInterfaceName
        s.interfaceKind = cachedInterfaceKind
        return s
    }

    // MARK: 主接口 / 接口类型（慢变化，最多每 10 秒刷新一次）

    private var cachedInterfaceName: String?
    private var cachedInterfaceKind: String?
    private var lastInterfaceRefresh: UInt64 = 0
    private let interfaceRefreshInterval: UInt64 = 10_000_000_000   // 10s
    private let store: SCDynamicStore? = SCDynamicStoreCreate(nil, "Lucent.NetworkReader" as CFString, nil, nil)

    private func refreshInterfaceIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastInterfaceRefresh == 0 || now &- lastInterfaceRefresh >= interfaceRefreshInterval else { return }
        lastInterfaceRefresh = now

        guard let store,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let bsdName = global["PrimaryInterface"] as? String, !bsdName.isEmpty else {
            cachedInterfaceName = nil
            cachedInterfaceKind = nil
            return
        }
        cachedInterfaceName = bsdName
        cachedInterfaceKind = Self.kind(forBSDName: bsdName)
    }

    private static func kind(forBSDName name: String) -> String? {
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in interfaces {
                guard (SCNetworkInterfaceGetBSDName(iface) as String?) == name,
                      let type = SCNetworkInterfaceGetInterfaceType(iface) else { continue }
                if type == kSCNetworkInterfaceTypeIEEE80211 { return "Wi‑Fi" }
                if type == kSCNetworkInterfaceTypeEthernet { return "以太网" }
            }
        }
        if name.hasPrefix("pdp_ip") { return "蜂窝" }   // 蜂窝调制解调器一般不出现在 SCNetworkInterfaceCopyAll 里
        return nil
    }

    // MARK: 本地自然日累计流量（UserDefaults 持久化，跨午夜清零，开机计数回绕/重启安全）

    private let defaults = UserDefaults.standard
    private static let todayDownKey = "net.today.down"
    private static let todayUpKey = "net.today.up"
    private static let todayDateKey = "net.today.date"
    private static let todayBaseInKey = "net.today.baseIn"
    private static let todayBaseOutKey = "net.today.baseOut"

    private var todayLoaded = false
    private var todayDown: UInt64 = 0
    private var todayUp: UInt64 = 0
    private var todayBaseIn: UInt64 = 0
    private var todayBaseOut: UInt64 = 0
    private var todayDirty = 0

    private func updateToday(inB: UInt64, outB: UInt64) {
        if !todayLoaded {
            todayLoaded = true
            todayDown = UInt64(max(0, defaults.double(forKey: Self.todayDownKey)))
            todayUp = UInt64(max(0, defaults.double(forKey: Self.todayUpKey)))
            todayBaseIn = UInt64(max(0, defaults.double(forKey: Self.todayBaseInKey)))
            todayBaseOut = UInt64(max(0, defaults.double(forKey: Self.todayBaseOutKey)))
        }

        let today = Calendar.current.startOfDay(for: Date())
        let storedDate = defaults.object(forKey: Self.todayDateKey) as? Date

        if storedDate == nil || !Calendar.current.isDate(storedDate!, inSameDayAs: today) {
            // 新的一天（或从未记录过）：清零，以当前读数为新基线
            todayDown = 0
            todayUp = 0
            todayBaseIn = inB
            todayBaseOut = outB
            persistToday(date: today)
            return
        }

        // 同一天：累加相对上次基线的增量。计数器回绕/重启会让本次读数变小，
        // 这种情况下跳过本次增量（视为 0），只把基线移到新的（更小的）读数上，
        // 不会出现负数或暴涨。
        let deltaIn = inB >= todayBaseIn ? inB - todayBaseIn : 0
        let deltaOut = outB >= todayBaseOut ? outB - todayBaseOut : 0
        todayDown &+= deltaIn
        todayUp &+= deltaOut
        todayBaseIn = inB
        todayBaseOut = outB

        todayDirty &+= 1
        if todayDirty >= 5 { persistToday(date: today) }   // 节流写盘
    }

    private func persistToday(date: Date) {
        defaults.set(Double(todayDown), forKey: Self.todayDownKey)
        defaults.set(Double(todayUp), forKey: Self.todayUpKey)
        defaults.set(Double(todayBaseIn), forKey: Self.todayBaseInKey)
        defaults.set(Double(todayBaseOut), forKey: Self.todayBaseOutKey)
        defaults.set(date, forKey: Self.todayDateKey)
        todayDirty = 0
    }

    // 移植自 AirStats (MIT, byrencheema/airstats) Collectors/NetworkCollector.swift（readLinks）：
    // 用 net.link.generic.ifalldata（ifmibdata，即 `netstat -ib` 读的那个 MIB）而不是
    // NET_RT_IFLIST2。实测对比过：本机 en0 上两者读到的字节数相差几百字节，
    // ifmibdata 与 netstat -ib 完全一致，是两者里准的那个。
    private func counters() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFALLDATA, 0, IFDATA_GENERAL]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        if buffer.count < len { buffer = [UInt8](repeating: 0, count: len + len / 2) }
        var size = len
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return (0, 0) }

        var inB: UInt64 = 0, outB: UInt64 = 0
        let recordSize = MemoryLayout<ifmibdata>.size
        guard recordSize > 0, size % recordSize == 0 else { return (0, 0) }
        buffer.withUnsafeBytes { raw in
            var off = 0
            while off + recordSize <= size {
                defer { off += recordSize }
                let record = raw.loadUnaligned(fromByteOffset: off, as: ifmibdata.self)
                let name = withUnsafeBytes(of: record.ifmd_name) { nraw in
                    String(decoding: nraw.prefix { $0 != 0 }, as: UTF8.self)
                }
                guard !name.isEmpty, shouldCount(name) else { continue }
                inB &+= record.ifmd_data.ifi_ibytes
                outB &+= record.ifmd_data.ifi_obytes
            }
        }
        return (inB, outB)
    }

    private func shouldCount(_ name: String) -> Bool {
        if let cached = include[name] { return cached }
        let ok = name.hasPrefix("en") || name.hasPrefix("pdp_ip")
        include[name] = ok
        return ok
    }
}

// MARK: - 温度

/// 启动时枚举一次 SMC 里所有 T 开头、类型为浮点的键，并按机型缓存到 UserDefaults，
/// 之后每次启动直接读缓存，不再全量扫描。
final class ThermalReader {
    private struct Key {
        let code: UInt32
        let name: String
        let type: UInt32
        let size: UInt32
        let group: SensorGroup
    }

    private let smc = SMC()
    private var keys: [Key] = []
    private static let cacheKey = "smc.temperatureKeys.v1"

    init() {
        guard let smc else { return }
        let model = Sysctl.string("hw.model") ?? "?"
        let defaults = UserDefaults.standard

        if let cached = defaults.dictionary(forKey: Self.cacheKey),
           cached["model"] as? String == model,
           let names = cached["keys"] as? [String] {
            keys = names.compactMap { name in
                let code = fourCC(name)
                guard let info = smc.keyInfo(code) else { return nil }
                return Key(code: code, name: name, type: info.type, size: info.size, group: .from(key: name))
            }
        }
        if keys.isEmpty {
            keys = Self.discover(smc)
            defaults.set(["model": model, "keys": keys.map(\.name)], forKey: Self.cacheKey)
        }
        keys.sort { ($0.group, $0.name) < ($1.group, $1.name) }
    }

    private static func discover(_ smc: SMC) -> [Key] {
        var found: [Key] = []
        let count = smc.keyCount()
        for i in 0..<count {
            guard let code = smc.key(at: i), code >> 24 == 0x54 else { continue }   // 'T'
            guard let info = smc.keyInfo(code),
                  info.type == SMC.typeFLT || info.type == SMC.typeSP78 else { continue }
            guard let v = smc.temperature(code, type: info.type, size: info.size), v > 10, v < 120 else { continue }
            let name = fourCCString(code)
            found.append(Key(code: code, name: name, type: info.type, size: info.size, group: .from(key: name)))
        }
        return found
    }

    func sample(full: Bool) -> ThermalStat {
        var t = ThermalStat()
        t.state = ProcessInfo.processInfo.thermalState
        guard let smc, !keys.isEmpty else { return t }

        var cpuSum = 0.0, cpuN = 0, cpuMax = -Double.infinity
        var socSum = 0.0, socN = 0
        var gpuSum = 0.0, gpuN = 0
        var batSum = 0.0, batN = 0
        var sensors: [Sensor] = []
        if full { sensors.reserveCapacity(keys.count) }

        for k in keys {
            if !full && !k.group.isPrimary { continue }
            guard let v = smc.temperature(k.code, type: k.type, size: k.size), v > 1, v < 150 else { continue }
            switch k.group {
            case .cpuP, .cpuE: cpuSum += v; cpuN += 1; cpuMax = max(cpuMax, v)
            case .soc: socSum += v; socN += 1
            case .gpu: gpuSum += v; gpuN += 1
            case .battery: batSum += v; batN += 1
            default: break
            }
            if full { sensors.append(Sensor(id: k.name, group: k.group, value: v)) }
        }
        // 没有 Tp/Te 键的芯片（如 M3）退回到 SoC 键
        if cpuN == 0, socN > 0 { cpuSum = socSum; cpuN = socN; cpuMax = socSum / Double(socN) }

        t.available = cpuN > 0 || gpuN > 0
        if cpuN > 0 { t.cpuAvg = cpuSum / Double(cpuN); t.cpuMax = cpuMax }
        if gpuN > 0 { t.gpu = gpuSum / Double(gpuN) }
        if batN > 0 { t.battery = batSum / Double(batN) }
        t.sensors = sensors
        return t
    }
}

// MARK: - 存储（仅 dashboard 打开时，最多每 30 秒读一次）

/// 启动卷（"/"）使用情况。口径参考 AirStats DiskCollector 的实测结论：
/// 移植自 AirStats (MIT, byrencheema/airstats) Collectors/DiskCollector.swift（scanVolumes 注释）：
/// `volumeAvailableCapacity` 与 statfs 的 f_bavail（`df` 显示的那个数）完全一致，不含可回收空间；
/// `volumeAvailableCapacityForImportantUsage` 则把系统可随时回收的缓存/快照空间加回来，
/// 对应"系统设置 > 储存空间"里 总容量 − 可用空间 的口径，与"关于本机"更接近，所以用后者。
final class StorageReader {
    func sample() -> StorageStat? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        let totalU = UInt64(total)
        let availU = UInt64(max(0, available))
        let used = availU < totalU ? totalU - availU : 0
        return StorageStat(used: used, total: totalU)
    }
}

// MARK: - 电池健康（仅 dashboard 打开时，最多每 30 秒读一次）

final class BatteryReader {
    func sample() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }   // 台式机没有电池
        defer { IOObjectRelease(service) }

        func number(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
        }
        // 移植自 AirStats (MIT, byrencheema/airstats) Collectors/PowerCollector.swift（applyHealth 注释）：
        // 本机（macOS 26/27）AppleSmartBattery 顶层已经没有 AppleRawMaxCapacity / DesignCapacity 这两个键了
        // （用 `ioreg -r -c AppleSmartBattery` 核实过），数据搬进了 BatteryData 子字典，改名
        // FullChargeCapacity / DesignCapacity；老系统可能还在顶层，所以顶层读不到再退回子字典。
        let batteryData = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        func batteryDataNumber(_ key: String) -> Int? { (batteryData?[key] as? NSNumber)?.intValue }

        let design = number("DesignCapacity") ?? batteryDataNumber("DesignCapacity")
        let maxCap = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity")
            ?? batteryDataNumber("FullChargeCapacity") ?? batteryDataNumber("NominalChargeCapacity")
        var health: Int?
        if let design, design > 0, let maxCap {
            let pct = Int((Double(maxCap) / Double(design) * 100).rounded())
            health = min(max(pct, 0), 100)
        }
        let cycles = number("CycleCount")
        guard health != nil || cycles != nil else { return nil }
        return BatteryHealth(healthPercent: health, cycleCount: cycles)
    }
}

// MARK: - 本进程占用（dashboard 打开时，每次采样都读）

final class SelfUsageReader {
    private var prevCPUNs: UInt64 = 0
    private var lastTime: UInt64 = 0
    private let ticksToNs: Double
    private let pid = getpid()

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        ticksToNs = Double(tb.numer) / Double(tb.denom)
    }

    func sample() -> SelfUsage? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        guard ok else { return nil }

        let now = DispatchTime.now().uptimeNanoseconds
        // ri_user_time / ri_system_time 是 mach 时间单位，不是纳秒，要乘 ticksToNs 换算
        // （与下面 ProcessReader 的处理一致；AirStats ProcessCollector 也特别点出了这一点，
        // 在 Apple Silicon 上直接当纳秒用会把 CPU 占用低估到时基比例那么多倍）。
        let cpuNs = UInt64(Double(info.ri_user_time &+ info.ri_system_time) * ticksToNs)
        var cpu = 0.0
        if lastTime > 0, now > lastTime, cpuNs >= prevCPUNs {
            let dt = Double(now - lastTime)
            cpu = Double(cpuNs - prevCPUNs) / dt * 100
        }
        prevCPUNs = cpuNs
        lastTime = now
        return SelfUsage(cpu: cpu, memory: info.ri_phys_footprint)
    }
}

// MARK: - 进程（仅主页面打开时运行）

final class ProcessReader {
    private var pids = [pid_t](repeating: 0, count: 4096)
    private var prev: [pid_t: UInt64] = [:]
    private var names: [pid_t: String] = [:]
    private var lastTime: UInt64 = 0
    private let ticksToNs: Double
    private var samples = 0

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        ticksToNs = Double(tb.numer) / Double(tb.denom)
    }

    func reset() {
        prev.removeAll()
        names.removeAll()
        lastTime = 0
    }

    func sample() -> ProcessSnapshot {
        samples &+= 1
        var n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        if n >= pids.count {
            pids = [pid_t](repeating: 0, count: pids.count * 2)
            n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        }
        guard n > 0 else { return ProcessSnapshot() }

        let now = DispatchTime.now().uptimeNanoseconds
        let dt = lastTime > 0 && now > lastTime ? Double(now - lastTime) : 0
        var next: [pid_t: UInt64] = [:]
        next.reserveCapacity(n)
        var rows: [(pid: pid_t, cpu: Double, mem: UInt64)] = []
        rows.reserveCapacity(n)

        for i in 0..<n {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
                }
            }
            guard ok else { continue }      // 无权限的系统进程会失败，跳过
            // Apple Silicon 上 ri_*_time 是 mach 时间单位，需要换算成纳秒
            let cpuNs = UInt64(Double(info.ri_user_time &+ info.ri_system_time) * ticksToNs)
            next[pid] = cpuNs
            var cpu = 0.0
            if dt > 0, let p = prev[pid], cpuNs >= p { cpu = Double(cpuNs - p) / dt * 100 }
            rows.append((pid, cpu, info.ri_phys_footprint))
        }
        prev = next
        lastTime = now
        if samples % 30 == 0 { names = names.filter { next[$0.key] != nil } }

        var snap = ProcessSnapshot()
        if dt > 0 {
            snap.topCPU = rows.sorted { $0.cpu > $1.cpu }.prefix(6)
                .map { ProcessStat(id: $0.pid, name: name($0.pid), cpu: $0.cpu, memory: $0.mem) }
        }
        snap.topMemory = rows.sorted { $0.mem > $1.mem }.prefix(6)
            .map { ProcessStat(id: $0.pid, name: name($0.pid), cpu: $0.cpu, memory: $0.mem) }
        return snap
    }

    private func name(_ pid: pid_t) -> String {
        if let n = names[pid] { return n }
        var buf = [CChar](repeating: 0, count: 256)
        let len = proc_name(pid, &buf, UInt32(buf.count))
        let n = len > 0 ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : "pid \(pid)"
        names[pid] = n
        return n
    }
}
