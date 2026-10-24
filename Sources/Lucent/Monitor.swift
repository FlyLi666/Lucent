import SwiftUI

/// 带时间戳的定长历史，用于迷你折线图和仪表盘的分时统计。
/// 环形缓冲，append 是 O(1)（不做 removeFirst），容量按 1 秒采样 × 3600 秒 = 3600 个点设计，
/// 但菜单栏常驻时（2 秒采样）也照常按时间戳记录，所以实际覆盖的时长更长。
struct TimedHistory: Sendable {
    let capacity: Int
    private var values: [Double]
    private var times: [Double]   // Date.timeIntervalSinceReferenceDate
    private var head = 0          // 下一次写入的位置
    private var count = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        values = Array(repeating: 0, count: self.capacity)
        times = Array(repeating: 0, count: self.capacity)
    }

    mutating func append(_ value: Double, at date: Date = Date()) {
        values[head] = value
        times[head] = date.timeIntervalSinceReferenceDate
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    var latest: Double? {
        guard count > 0 else { return nil }
        let idx = (head - 1 + capacity) % capacity
        return values[idx]
    }

    /// 最近 seconds 秒内的最大值；完全没有数据返回 nil。
    func peak(last seconds: TimeInterval) -> Double? {
        guard count > 0 else { return nil }
        let cutoff = Date().timeIntervalSinceReferenceDate - seconds
        var result: Double?
        for i in orderedIndices() where times[i] >= cutoff {
            result = max(result ?? -Double.infinity, values[i])
        }
        return result
    }

    /// 取最近 seconds 秒的数据，按时间均匀降采样到不超过 maxPoints 个点（桶内取平均），
    /// 按时间先后排序；窗口内数据不足就返回已有的全部数据。
    func values(last seconds: TimeInterval, maxPoints: Int) -> [Double] {
        guard count > 0, maxPoints > 0 else { return [] }
        let cutoff = Date().timeIntervalSinceReferenceDate - seconds
        let idxs = orderedIndices()

        var windowed: [(t: Double, v: Double)] = []
        windowed.reserveCapacity(idxs.count)
        for i in idxs where times[i] >= cutoff {
            windowed.append((times[i], values[i]))
        }
        if windowed.isEmpty {
            // 窗口内没有点（历史还没攒够那么久）：退回已有的全部数据
            windowed = idxs.map { (times[$0], values[$0]) }
        }
        return Self.downsample(windowed, maxPoints: maxPoints)
    }

    /// 按时间顺序（最旧到最新）排列当前有效的下标。
    private func orderedIndices() -> [Int] {
        guard count > 0 else { return [] }
        if count < capacity { return Array(0..<count) }
        return (0..<capacity).map { (head + $0) % capacity }
    }

    private static func downsample(_ points: [(t: Double, v: Double)], maxPoints: Int) -> [Double] {
        guard points.count > maxPoints else { return points.map(\.v) }
        let tMin = points.first!.t, tMax = points.last!.t
        let span = max(tMax - tMin, .leastNonzeroMagnitude)
        var sums = [Double](repeating: 0, count: maxPoints)
        var counts = [Int](repeating: 0, count: maxPoints)
        for p in points {
            var idx = Int((p.t - tMin) / span * Double(maxPoints))
            idx = min(max(idx, 0), maxPoints - 1)
            sums[idx] += p.v
            counts[idx] += 1
        }
        var out: [Double] = []
        out.reserveCapacity(maxPoints)
        for i in 0..<maxPoints where counts[i] > 0 {
            out.append(sums[i] / Double(counts[i]))
        }
        return out
    }
}

/// 主线程上的唯一数据源。视图通过 Observation 按需订阅；
/// 弹窗和主页面关闭后，SwiftUI 视图被释放，这里只剩几次赋值的开销。
@MainActor @Observable
final class Monitor {
    /// 1 秒采样 × 3600 秒 的上限；菜单栏常驻时采样更慢，实际覆盖时长更长。
    static let historyCapacity = 3600

    let machine = MachineInfo.current
    private(set) var snapshot = Snapshot()
    private(set) var processes = ProcessSnapshot()

    // 只在 dashboard 打开时采集；关闭后保留最近一次读到的值，不清空。
    private(set) var storage: StorageStat?
    private(set) var battery: BatteryHealth?
    private(set) var selfUsage: SelfUsage?

    private(set) var cpuHistory = TimedHistory(capacity: historyCapacity)
    private(set) var memHistory = TimedHistory(capacity: historyCapacity)
    private(set) var tempHistory = TimedHistory(capacity: historyCapacity)
    private(set) var downHistory = TimedHistory(capacity: historyCapacity)
    private(set) var upHistory = TimedHistory(capacity: historyCapacity)

    func ingest(_ s: Snapshot, _ p: ProcessSnapshot?) {
        snapshot = s
        if let p { processes = p }
        if let storage = s.storage { self.storage = storage }
        if let battery = s.battery { self.battery = battery }
        if let selfUsage = s.selfUsage { self.selfUsage = selfUsage }

        cpuHistory.append(s.cpu.total, at: s.date)
        memHistory.append(s.mem.usedFraction, at: s.date)
        if let t = s.thermal.cpuAvg { tempHistory.append(t, at: s.date) }
        downHistory.append(s.net.down, at: s.date)
        upHistory.append(s.net.up, at: s.date)
    }
}
