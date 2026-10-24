import Foundation

/// 单一后台定时器驱动所有采样。
/// - 菜单栏常驻：按用户设定间隔（默认 2 秒），只读必要的温度键
/// - 弹出卡片 / 主页面打开：提速到 1 秒；主页面额外采集全部传感器与进程
/// - 屏幕休眠：完全停止
final class Sampler: @unchecked Sendable {
    typealias Sink = @MainActor @Sendable (Snapshot, ProcessSnapshot?) -> Void

    private let queue = DispatchQueue(label: "lucent.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let sink: Sink

    private var baseInterval: Double
    private var popoverOpen = false
    private var dashboardOpen = false
    private var paused = false

    // 全部 lazy：第一次采样时才在后台队列初始化（SMC 枚举不占用主线程）
    private lazy var cpu = CPUReader()
    private lazy var mem = MemoryReader()
    private lazy var net = NetworkReader()
    private lazy var thermal = ThermalReader()
    private lazy var procs = ProcessReader()
    private lazy var storageReader = StorageReader()
    private lazy var batteryReader = BatteryReader()
    private lazy var selfUsageReader = SelfUsageReader()

    // storage / battery 最多每 30 秒读一次，dashboard 刚打开时立即读一次
    private var forceAuxRead = false
    private var lastAuxRead: UInt64 = 0
    private let auxInterval: UInt64 = 30_000_000_000

    init(baseInterval: Double, sink: @escaping Sink) {
        self.baseInterval = baseInterval
        self.sink = sink
    }

    func start() { queue.async { self.reschedule() } }

    func setPopover(open: Bool) {
        queue.async {
            self.popoverOpen = open
            self.updateProcessCollectionState()
            self.reschedule()
        }
    }

    func setDashboard(open: Bool) {
        queue.async {
            self.dashboardOpen = open
            if open { self.forceAuxRead = true }
            self.updateProcessCollectionState()
            self.reschedule()
        }
    }

    /// 进程列表在 popover 或 dashboard 任一打开时采集；两者都关闭时停止并重置。
    private func updateProcessCollectionState() {
        if !(popoverOpen || dashboardOpen) { procs.reset() }
    }

    func setBaseInterval(_ v: Double) {
        queue.async {
            guard v != self.baseInterval else { return }
            self.baseInterval = v
            self.reschedule()
        }
    }

    func pause() {
        queue.async {
            self.paused = true
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func resume() {
        queue.async {
            self.paused = false
            self.reschedule()
        }
    }

    private func reschedule() {
        guard !paused else { return }
        let interval = (popoverOpen || dashboardOpen) ? 1.0 : max(baseInterval, 1)
        // 给 20% 的 leeway，让系统可以把唤醒与其他定时器合并，省电
        let leeway = DispatchTimeInterval.milliseconds(Int(interval * 200))
        if let timer {
            timer.schedule(deadline: .now(), repeating: interval, leeway: leeway)
        } else {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.setEventHandler { [weak self] in self?.sample() }
            t.schedule(deadline: .now(), repeating: interval, leeway: leeway)
            t.resume()
            timer = t
        }
    }

    private func sample() {
        let full = dashboardOpen
        var s = Snapshot()
        s.cpu = cpu.sample()
        s.mem = mem.sample()
        s.net = net.sample()
        s.thermal = thermal.sample(full: full)
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        s.load = load
        s.date = Date()

        if full {
            // storage / battery 慢变化，最多每 30 秒读一次，dashboard 刚打开时立即读一次
            let now = DispatchTime.now().uptimeNanoseconds
            if forceAuxRead || lastAuxRead == 0 || now &- lastAuxRead >= auxInterval {
                s.storage = storageReader.sample()
                s.battery = batteryReader.sample()
                lastAuxRead = now
                forceAuxRead = false
            }
            s.selfUsage = selfUsageReader.sample()
        }

        // 进程列表：popover 或 dashboard 任一打开时都采集
        let p: ProcessSnapshot? = (popoverOpen || dashboardOpen) ? procs.sample() : nil

        let sink = self.sink
        DispatchQueue.main.async {
            MainActor.assumeIsolated { sink(s, p) }
        }
    }
}
