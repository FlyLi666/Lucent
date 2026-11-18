import Foundation
import SQLite3
import Darwin  // memchr/memmem，给下面手写的字节级行扫描和前过滤用

// 用量后端的公共小工具：缓存目录、增量读文件、极简 SQLite 只读包装、日期分桶。
// 全部跑在 UsageWorker 的后台上下文里，不碰主线程。

enum UsageCacheLocation {
    #if DEBUG
    /// 调试harness（`--usage-dump --cold`）用：指到一个临时目录，别碰真实缓存
    static var debugOverrideDir: URL?
    #endif

    /// `~/Library/Caches/local.lucent.monitor/`，只放用量聚合缓存，绝不放凭据
    static var dir: URL {
        #if DEBUG
        if let override = debugOverrideDir { return override }
        #endif
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("local.lucent.monitor", isDirectory: true)
    }

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 默认账号第一次改用「带 id 哈希」的缓存文件时，把原来的那份拷过去，避免整库重扫。
    /// 源文件留着不动。目标已存在就什么都不做。
    static func copyLegacy(named name: String, to dest: URL) {
        let fm = FileManager.default
        let src = url(name)
        guard !fm.fileExists(atPath: dest.path), fm.fileExists(atPath: src.path) else { return }
        ensureDir()
        try? fm.copyItem(at: src, to: dest)
    }
}

/// 用量读取用的家目录。正式运行就是当前用户的家目录。
enum UsageHome {
    #if DEBUG
    /// `--usage-dump --home <目录>`：整次进程的发现和默认目录都改看这里
    static var debugOverride: URL?
    #endif

    static var url: URL {
        #if DEBUG
        if let debugOverride { return debugOverride }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// 一天的聚合：按模型分的 token/花费/请求数，当天已处理过的去重 key（只在"今天"这一天的桶里保留，
/// 过了这天就冻结成历史，不再需要去重集合，但桶本身要留着——这就是 365 天历史的底子，
/// 哪怕 Claude Code 自己把 30 天前的 jsonl 清理掉了，这里的汇总数字还在）
struct DayBucket: Codable, Sendable {
    var tokensByModel: [String: TokenCountsCodable] = [:]
    var costByModel: [String: Double] = [:]
    var requestsByModel: [String: Int] = [:]
    /// 仅当天需要；过了今天就清空（见 prune 系方法），不随桶一起删
    var dedupeKeys: Set<String> = []
    var requests: Int = 0
    var cacheSavings: Double = 0
    /// 缓存写里按 1 小时档计费的部分
    var cacheWrite1h: Int64 = 0

    var totalTokens: TokenCountsCodable {
        tokensByModel.values.reduce(TokenCountsCodable()) { $0 + $1 }
    }

    var totalCost: Double { costByModel.values.reduce(0, +) }
}

/// 一小时的聚合（本地时区整点），只有有数据的小时才会出现在缓存里
struct HourBucket: Codable, Sendable {
    var tokens: TokenCountsCodable = TokenCountsCodable()
    var cost: Double = 0
    var requests: Int = 0
}

/// 一天里某个项目的聚合
struct ProjectBucket: Codable, Sendable {
    var tokens: TokenCountsCodable = TokenCountsCodable()
    var cost: Double = 0
    var requests: Int = 0
    var lastActive: Date?
}

/// "时间段 × 供应商 × 模型"一格的聚合，给 hourlyDetail / dailyDetail 用
struct DetailBucket: Codable, Sendable {
    var tokens: TokenCountsCodable = TokenCountsCodable()
    var cost: Double = 0
    var requests: Int = 0
    var cacheSavings: Double = 0
    var cacheWrite1h: Int64 = 0
    /// 只有算得出耗时的请求才往这两个字段里加，算速度（tok/s）时拿这俩相除
    var timedOutputTokens: Int64 = 0
    var timedDurationMs: Int64 = 0
}

/// UsageRequest 的可编码版本，只存数字/型号/项目名/时间，绝不存提示词或路径全文
struct UsageRequestCodable: Codable, Sendable {
    var id: String
    var time: Date
    var tool: String
    var model: String
    var project: String?
    var sessionID: String?
    var tokens: TokenCountsCodable
    var cacheWrite1h: Int64 = 0
    var cost: Double = 0
    var provider: String = ""
    var durationMs: Int?
    var durationIsEstimate: Bool = true

    func toContract() -> UsageRequest? {
        guard let aiTool = AITool(rawValue: tool) else { return nil }
        return UsageRequest(id: id, time: time, tool: aiTool, model: model, project: project, sessionID: sessionID,
                             tokens: tokens.asTokenCounts, cacheWrite1h: cacheWrite1h, cost: cost,
                             provider: provider, durationMs: durationMs, durationIsEstimate: durationIsEstimate)
    }
}

/// 按请求时间排序（最新在前）的有限列表，只留时间最新的 cap 条。
/// 冷扫描时文件按任意顺序读，不能按“读到的先后”留，否则今天的请求可能被旧文件挤掉。
enum RequestRing {
    static let cap = 1000

    static func push(_ req: UsageRequestCodable, into list: inout [UsageRequestCodable]) {
        if list.count >= cap, let oldest = list.last, req.time <= oldest.time { return }
        // 二分找插入位置（list 按 time 降序）
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].time > req.time { lo = mid + 1 } else { hi = mid }
        }
        list.insert(req, at: lo)
        if list.count > cap { list.removeLast(list.count - cap) }
    }

    /// 同一条请求后来又出现（流式补全、token 变大）：先拿掉旧的，再按时间插回去
    static func replace(_ req: UsageRequestCodable, into list: inout [UsageRequestCodable]) {
        if let idx = list.firstIndex(where: { $0.id == req.id }) {
            list.remove(at: idx)
        }
        push(req, into: &list)
    }
}

/// TokenCounts 的可编码版本（TokenCounts 本身在 UsageModels.swift 里，界面契约不加 Codable 以免引入耦合）
struct TokenCountsCodable: Codable, Sendable, Equatable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var reasoning: Int64 = 0
    /// 只有总数、分不出输入/输出/缓存。旧缓存没有这个字段，解码时按 0。
    var unsplit: Int64 = 0

    init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, reasoning: Int64 = 0, unsplit: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.unsplit = unsplit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int64.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int64.self, forKey: .output) ?? 0
        cacheRead = try c.decodeIfPresent(Int64.self, forKey: .cacheRead) ?? 0
        cacheWrite = try c.decodeIfPresent(Int64.self, forKey: .cacheWrite) ?? 0
        reasoning = try c.decodeIfPresent(Int64.self, forKey: .reasoning) ?? 0
        unsplit = try c.decodeIfPresent(Int64.self, forKey: .unsplit) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(input, forKey: .input)
        try c.encode(output, forKey: .output)
        try c.encode(cacheRead, forKey: .cacheRead)
        try c.encode(cacheWrite, forKey: .cacheWrite)
        try c.encode(reasoning, forKey: .reasoning)
        try c.encode(unsplit, forKey: .unsplit)
    }

    private enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheWrite, reasoning, unsplit
    }

    static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
             cacheWrite: a.cacheWrite + b.cacheWrite, reasoning: a.reasoning + b.reasoning, unsplit: a.unsplit + b.unsplit)
    }

    static func - (a: Self, b: Self) -> Self {
        Self(input: a.input - b.input, output: a.output - b.output, cacheRead: a.cacheRead - b.cacheRead,
             cacheWrite: a.cacheWrite - b.cacheWrite, reasoning: a.reasoning - b.reasoning, unsplit: a.unsplit - b.unsplit)
    }

    var total: Int64 { input + output + cacheRead + cacheWrite + unsplit }

    var asTokenCounts: TokenCounts {
        TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: reasoning, unsplit: unsplit)
    }
}

/// 最近 5 分钟的 (时间, token 数) 事件窗口，用来算 tokensPerMinute；每次读完都裁掉超过 5 分钟的
struct RecentEventWindow: Sendable {
    private var events: [(Date, Int64)] = []

    mutating func add(_ date: Date, _ tokens: Int64) {
        events.append((date, tokens))
        if events.count > 4096 { events.removeFirst(events.count - 4096) }
    }

    mutating func tokensPerMinute(now: Date = Date()) -> Double {
        let cutoff = now.addingTimeInterval(-300)
        events.removeAll { $0.0 < cutoff }
        let sum = events.reduce(Int64(0)) { $0 + $1.1 }
        return Double(sum) / 5.0
    }
}

/// 一个 jsonl 文件的增量读取状态
struct FileCursor: Codable, Sendable {
    var inode: UInt64
    var size: Int64
    var offset: Int64
    /// 文件的 mtime（秒）。跟 size 一起判断"这个文件自上次扫描后是不是真的没变"，没变就连
    /// FileHandle 都不开——否则每 15 秒的 tick 都要把几百个文件重新摸一遍。
    var mtime: Double = 0
}

/// 按本地日历日分桶的 key，格式 yyyy-MM-dd，用本机时区
func localDayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

func localDayStart(_ date: Date, calendar: Calendar = .current) -> Date {
    calendar.startOfDay(for: date)
}

/// 近 30 天的 key 列表，最早在前，最后一项是今天
func last30DayKeys(now: Date = Date(), calendar: Calendar = .current) -> [String] {
    lastNDayKeys(30, now: now, calendar: calendar)
}

/// 近 365 天的 key 列表，最早在前，最后一项是今天
func last365DayKeys(now: Date = Date(), calendar: Calendar = .current) -> [String] {
    lastNDayKeys(365, now: now, calendar: calendar)
}

func lastNDayKeys(_ n: Int, now: Date = Date(), calendar: Calendar = .current) -> [String] {
    let today = calendar.startOfDay(for: now)
    return (0..<n).reversed().map { offset in
        localDayKey(calendar.date(byAdding: .day, value: -offset, to: today) ?? today, calendar: calendar)
    }
}

/// yyyy-MM-dd 这种零填充格式按字符串比较就等于按日期比较，省得每次都转 Date 再比
func dayKey(daysAgo n: Int, from now: Date = Date(), calendar: Calendar = .current) -> String {
    let today = calendar.startOfDay(for: now)
    return localDayKey(calendar.date(byAdding: .day, value: -n, to: today) ?? today, calendar: calendar)
}

/// 本地时区整点的 key，格式 yyyy-MM-dd'T'HH
func localHourKey(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day, .hour], from: date)
    return String(format: "%04d-%02d-%02dT%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
}

private let utcCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
}()

/// 落盘缓存统一用 UTC 整点键（yyyy-MM-dd'T'HH），写入不绑定本机时区；
/// 切换系统时区或跨夏令时后无需重扫，读出时按当前 Calendar.current 投射回本地日与本地整点。
func utcHourKey(_ date: Date) -> String {
    let c = utcCalendar.dateComponents([.year, .month, .day, .hour], from: date)
    return String(format: "%04d-%02d-%02dT%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
}

func date(forUTCHourKey key: String) -> Date? {
    let utf8 = Array(key.utf8)
    guard utf8.count == 13,
          utf8[4] == 0x2D, utf8[7] == 0x2D, utf8[10] == 0x54,
          let year = parseKeyDigits(utf8, 0, 4),
          let month = parseKeyDigits(utf8, 5, 2), (1...12).contains(month),
          let day = parseKeyDigits(utf8, 8, 2), (1...31).contains(day),
          let hour = parseKeyDigits(utf8, 11, 2), (0...23).contains(hour)
    else { return nil }
    return utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
}

/// 每次按当前 Calendar.current 解析，避免静态 DateFormatter 把启动时的旧时区焊死在内存里
func date(forDayKey key: String, calendar: Calendar = .current) -> Date? {
    let utf8 = Array(key.utf8)
    guard utf8.count == 10,
          utf8[4] == 0x2D, utf8[7] == 0x2D,
          let year = parseKeyDigits(utf8, 0, 4),
          let month = parseKeyDigits(utf8, 5, 2), (1...12).contains(month),
          let day = parseKeyDigits(utf8, 8, 2), (1...31).contains(day)
    else { return nil }
    return calendar.date(from: DateComponents(year: year, month: month, day: day))
}

func date(forHourKey key: String, calendar: Calendar = .current) -> Date? {
    let utf8 = Array(key.utf8)
    guard utf8.count == 13,
          utf8[4] == 0x2D, utf8[7] == 0x2D, utf8[10] == 0x54,
          let year = parseKeyDigits(utf8, 0, 4),
          let month = parseKeyDigits(utf8, 5, 2), (1...12).contains(month),
          let day = parseKeyDigits(utf8, 8, 2), (1...31).contains(day),
          let hour = parseKeyDigits(utf8, 11, 2), (0...23).contains(hour)
    else { return nil }
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
}

@inline(__always)
private func parseKeyDigits(_ bytes: [UInt8], _ start: Int, _ len: Int) -> Int? {
    var acc = 0
    for i in start..<(start + len) {
        let b = bytes[i]
        guard b >= 0x30 && b <= 0x39 else { return nil }
        acc = acc * 10 + Int(b - 0x30)
    }
    return acc
}

/// 只删严格早于保留下限的桶；绝不删“未来键”，避免切时区或时钟回拨把已扫过的数据抹掉后游标不回扫。
func pruneUTCHourBuckets<V>(_ map: inout [String: V], olderThan cutoff: Date) {
    for key in Array(map.keys) {
        if let bucketDate = date(forUTCHourKey: key), bucketDate < cutoff {
            map.removeValue(forKey: key)
        }
    }
}

/// 由 UTC 小时桶按当前本机时区即时折算出日/小时/模型/项目/明细视图，四个读取器共用同一套口径
enum UTCHourRollup {
    struct ExtraDayEntry {
        var when: Date
        var provider: String
        var model: String
        var tokens: TokenCountsCodable
        var project: String?
    }

    struct Snapshot {
        var today: DailyUsage
        var daily: [DailyUsage]
        var models: [ModelShare]
        var history: [DailyUsage]
        var hourly: [HourlyUsage]
        var projects: [ProjectShare]
        var hourlyDetail: [UsageBucket]
        var dailyDetail: [UsageBucket]
    }

    static func addProject(_ store: inout [String: [String: ProjectBucket]], utcHour: String, project: String,
                           delta: TokenCountsCodable, cost: Double, timestamp: Date) {
        var projects = store[utcHour] ?? [:]
        var pb = projects[project] ?? ProjectBucket()
        pb.tokens = pb.tokens + delta
        pb.cost += cost
        pb.requests += 1
        if pb.lastActive == nil || timestamp > pb.lastActive! { pb.lastActive = timestamp }
        projects[project] = pb
        store[utcHour] = projects
    }

    static func subtractProject(_ store: inout [String: [String: ProjectBucket]], utcHour: String, project: String,
                                delta: TokenCountsCodable, cost: Double) {
        guard var projects = store[utcHour], var pb = projects[project] else { return }
        pb.tokens = pb.tokens - delta
        pb.cost -= cost
        pb.requests -= 1
        if pb.requests <= 0 && pb.tokens.total == 0 {
            projects.removeValue(forKey: project)
        } else {
            projects[project] = pb
        }
        if projects.isEmpty {
            store.removeValue(forKey: utcHour)
        } else {
            store[utcHour] = projects
        }
    }

    static func build(
        detailHours: [String: [String: [String: DetailBucket]]],
        projectHours: [String: [String: ProjectBucket]] = [:],
        extraDayEntries: [ExtraDayEntry] = [],
        tool: AITool,
        now: Date,
        calendar: Calendar = .current
    ) -> Snapshot {
        let keys365 = last365DayKeys(now: now, calendar: calendar)
        let keys30 = Array(keys365.suffix(30))
        let keep365 = Set(keys365)
        let keep30 = Set(keys30)

        var daysByKey: [String: DayBucket] = [:]
        var dailyDetailMap: [String: [String: [String: DetailBucket]]] = [:]
        var hourlyByStart: [Date: HourBucket] = [:]
        var hourlyDetailMap: [Date: [String: [String: DetailBucket]]] = [:]

        for (utcKey, byProvider) in detailHours {
            guard let utcDate = date(forUTCHourKey: utcKey) else { continue }
            let dayKey = localDayKey(utcDate, calendar: calendar)
            guard keep365.contains(dayKey) else { continue }
            let in30 = keep30.contains(dayKey)
            let localHour = calendar.dateInterval(of: .hour, for: utcDate)?.start ?? utcDate

            for (provider, byModel) in byProvider {
                for (model, cell) in byModel where cell.requests > 0 || cell.tokens.total > 0 {
                    var day = daysByKey[dayKey] ?? DayBucket()
                    day.tokensByModel[model] = (day.tokensByModel[model] ?? TokenCountsCodable()) + cell.tokens
                    day.costByModel[model, default: 0] += cell.cost
                    day.requestsByModel[model, default: 0] += cell.requests
                    day.requests += cell.requests
                    day.cacheSavings += cell.cacheSavings
                    day.cacheWrite1h += cell.cacheWrite1h
                    daysByKey[dayKey] = day

                    mergeCell(cell, into: &dailyDetailMap, key: dayKey, provider: provider, model: model)

                    if in30 {
                        var hb = hourlyByStart[localHour] ?? HourBucket()
                        hb.tokens = hb.tokens + cell.tokens
                        hb.cost += cell.cost
                        hb.requests += cell.requests
                        hourlyByStart[localHour] = hb

                        mergeCell(cell, into: &hourlyDetailMap, key: localHour, provider: provider, model: model)
                    }
                }
            }
        }

        var projectTotals: [String: (tokens: TokenCountsCodable, cost: Double, requests: Int, lastActive: Date?)] = [:]
        for (utcKey, projects) in projectHours {
            guard let utcDate = date(forUTCHourKey: utcKey) else { continue }
            let dayKey = localDayKey(utcDate, calendar: calendar)
            guard keep30.contains(dayKey) else { continue }
            for (project, pb) in projects where pb.requests > 0 || pb.tokens.total > 0 {
                var entry = projectTotals[project] ?? (TokenCountsCodable(), 0, 0, nil)
                entry.tokens = entry.tokens + pb.tokens
                entry.cost += pb.cost
                entry.requests += pb.requests
                if let la = pb.lastActive, entry.lastActive == nil || la > entry.lastActive! {
                    entry.lastActive = la
                }
                projectTotals[project] = entry
            }
        }

        for extra in extraDayEntries {
            let dayKey = localDayKey(extra.when, calendar: calendar)
            guard keep365.contains(dayKey) else { continue }
            var day = daysByKey[dayKey] ?? DayBucket()
            day.tokensByModel[extra.model] = (day.tokensByModel[extra.model] ?? TokenCountsCodable()) + extra.tokens
            day.requestsByModel[extra.model, default: 0] += 1
            day.requests += 1
            daysByKey[dayKey] = day

            var extraCell = DetailBucket()
            extraCell.tokens = extra.tokens
            extraCell.requests = 1
            mergeCell(extraCell, into: &dailyDetailMap, key: dayKey, provider: extra.provider, model: extra.model)

            if keep30.contains(dayKey), let project = extra.project {
                var entry = projectTotals[project] ?? (TokenCountsCodable(), 0, 0, nil)
                entry.tokens = entry.tokens + extra.tokens
                entry.requests += 1
                if entry.lastActive == nil || extra.when > entry.lastActive! {
                    entry.lastActive = extra.when
                }
                projectTotals[project] = entry
            }
        }

        var daily: [DailyUsage] = []
        daily.reserveCapacity(keys30.count)
        var modelTotals: [String: (tokens: TokenCountsCodable, cost: Double, requests: Int)] = [:]
        for key in keys30 {
            let bucket = daysByKey[key]
            let totalTokens = bucket?.totalTokens.asTokenCounts ?? TokenCounts()
            let totalCost = bucket?.totalCost ?? 0
            let dayDate = date(forDayKey: key, calendar: calendar) ?? now
            daily.append(DailyUsage(
                day: calendar.startOfDay(for: dayDate),
                tokens: totalTokens,
                cost: totalCost,
                requests: bucket?.requests ?? 0,
                cacheSavings: bucket?.cacheSavings ?? 0,
                cacheWrite1h: bucket?.cacheWrite1h ?? 0))
            if let bucket {
                for (model, tc) in bucket.tokensByModel {
                    var entry = modelTotals[model] ?? (TokenCountsCodable(), 0, 0)
                    entry.tokens = entry.tokens + tc
                    modelTotals[model] = entry
                }
                for (model, cost) in bucket.costByModel {
                    var entry = modelTotals[model] ?? (TokenCountsCodable(), 0, 0)
                    entry.cost += cost
                    modelTotals[model] = entry
                }
                for (model, reqs) in bucket.requestsByModel {
                    var entry = modelTotals[model] ?? (TokenCountsCodable(), 0, 0)
                    entry.requests += reqs
                    modelTotals[model] = entry
                }
            }
        }

        let models = modelTotals.map { (model, v) in
            ModelShare(model: model, tokens: v.tokens.asTokenCounts.total, cost: v.cost, detail: v.tokens.asTokenCounts, requests: v.requests)
        }.sorted { $0.tokens > $1.tokens }
        let today = daily.last ?? DailyUsage(day: calendar.startOfDay(for: now))

        let history = keys365.map { key -> DailyUsage in
            let bucket = daysByKey[key]
            let dayDate = date(forDayKey: key, calendar: calendar) ?? now
            return DailyUsage(
                day: calendar.startOfDay(for: dayDate),
                tokens: bucket?.totalTokens.asTokenCounts ?? TokenCounts(),
                cost: bucket?.totalCost ?? 0,
                requests: bucket?.requests ?? 0,
                cacheSavings: bucket?.cacheSavings ?? 0,
                cacheWrite1h: bucket?.cacheWrite1h ?? 0)
        }

        let hourly = hourlyByStart
            .filter { $0.value.requests > 0 || $0.value.tokens.total > 0 }
            .sorted { $0.key < $1.key }
            .map { HourlyUsage(hour: $0.key, tokens: $0.value.tokens.asTokenCounts, cost: $0.value.cost, requests: $0.value.requests) }

        var hourlyDetail: [UsageBucket] = []
        for (start, byProvider) in hourlyDetailMap {
            for (provider, byModel) in byProvider {
                for (model, cell) in byModel where cell.requests > 0 {
                    hourlyDetail.append(UsageBucket(
                        start: start, tool: tool, provider: provider, model: model,
                        tokens: cell.tokens.asTokenCounts, cost: cell.cost, requests: cell.requests,
                        cacheSavings: cell.cacheSavings, cacheWrite1h: cell.cacheWrite1h,
                        timedOutputTokens: cell.timedOutputTokens, timedDurationMs: cell.timedDurationMs))
                }
            }
        }
        hourlyDetail.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            return $0.model < $1.model
        }

        var dailyDetail: [UsageBucket] = []
        for (dayKey, byProvider) in dailyDetailMap {
            guard let rawDate = date(forDayKey: dayKey, calendar: calendar) else { continue }
            let start = calendar.startOfDay(for: rawDate)
            for (provider, byModel) in byProvider {
                for (model, cell) in byModel where cell.requests > 0 {
                    dailyDetail.append(UsageBucket(
                        start: start, tool: tool, provider: provider, model: model,
                        tokens: cell.tokens.asTokenCounts, cost: cell.cost, requests: cell.requests,
                        cacheSavings: cell.cacheSavings, cacheWrite1h: cell.cacheWrite1h,
                        timedOutputTokens: cell.timedOutputTokens, timedDurationMs: cell.timedDurationMs))
                }
            }
        }
        dailyDetail.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            return $0.model < $1.model
        }

        let projects = projectTotals.map { (project, v) in
            ProjectShare(project: project, tool: tool, tokens: v.tokens.asTokenCounts, cost: v.cost, requests: v.requests, lastActive: v.lastActive)
        }.sorted { $0.tokens.total > $1.tokens.total }.prefix(50).map { $0 }

        return Snapshot(
            today: today, daily: daily, models: models, history: history,
            hourly: hourly, projects: projects, hourlyDetail: hourlyDetail, dailyDetail: dailyDetail)
    }

    private static func mergeCell<K: Hashable>(_ cell: DetailBucket, into map: inout [K: [String: [String: DetailBucket]]],
                                               key: K, provider: String, model: String) {
        var byProvider = map[key] ?? [:]
        var byModel = byProvider[provider] ?? [:]
        var dst = byModel[model] ?? DetailBucket()
        dst.tokens = dst.tokens + cell.tokens
        dst.cost += cell.cost
        dst.requests += cell.requests
        dst.cacheSavings += cell.cacheSavings
        dst.cacheWrite1h += cell.cacheWrite1h
        dst.timedOutputTokens += cell.timedOutputTokens
        dst.timedDurationMs += cell.timedDurationMs
        byModel[model] = dst
        byProvider[provider] = byModel
        map[key] = byProvider
    }
}

enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let noFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        withFraction.date(from: s) ?? noFraction.date(from: s)
    }
}

/// 增量流式读取一个 jsonl 文件的新增字节。Claude Code 的 transcript 里偶尔有几 MB 甚至几十 MB
/// 一行的工具结果（截图之类的 base64），旧版实现对每行做 `Data.removeSubrange(0...)`（整体前移，
/// O(n) 每行，等于整体 O(n²)）、转 String、塞进数组攒着——这些在正常几百字节的行上无所谓，
/// 碰上几 MB 的行就是几十秒的 CPU 尖峰和几百 MB 的峰值内存（早期版本真的出过这个问题）。
///
/// 现在的做法：定长 chunk 读进可复用的 Data，chunk 内用 memchr 找 `\n`，一找到完整行立刻通过
/// onLine 把这一行的字节范围（零拷贝的 UnsafeRawBufferPointer，指向 chunk 自己的内存）交出去，
/// 绝不转 String、绝不攒数组；跨 chunk 只缓冲"还没凑齐的尾巴"那一小段。单行超过 maxLineBytes
/// 就放弃缓冲、直接快进到下一个 `\n`，不管它多长都不会占内存。
/// 一次调用最多读 maxBytes 字节就停（哪怕文件还没读完），返回目前为止确实消费掉的新 offset；
/// 没读完的部分留给调用者下一轮 tick 继续，这样一次冷扫描或一次性几十 MB 的追加会被摊到好几个
/// 15 秒周期里，而不是把 CPU 焊死在一次调用里。
enum IncrementalLineReader {
    static let chunkSize = 1 << 20              // 1 MB
    static let maxLineBytes = 8 * 1024 * 1024    // 单行超过这个就不缓冲，直接跳过

    /// onLine 拿到的 UnsafeRawBufferPointer 只在这次调用里有效，不能逃逸保存，要用就当场转成自己的数据。
    /// maxBytes：这次调用最多读这么多字节（跨多个 chunk 累计），用来限制单次调用的 CPU/IO 量。
    @discardableResult
    static func readNewLines(at path: String, from offset: Int64, maxBytes: Int,
                              onLine: (UnsafeRawBufferPointer) -> Void) -> Int64? {
        guard maxBytes > 0 else { return offset }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: UInt64(offset)) } catch { return nil }

        var consumedBytes = 0
        var tail = Data()        // 跨 chunk 边界、还没凑齐 \n 的那一小段
        var skipping = false     // 正在跳过一行过长的内容，等下一个 \n

        while consumedBytes < maxBytes {
            var reachedEOF = false
            autoreleasepool {
                let chunk: Data
                if #available(macOS 10.15.4, *) {
                    chunk = (try? fh.read(upToCount: chunkSize)) ?? Data()
                } else {
                    chunk = fh.readData(ofLength: chunkSize)
                }
                guard !chunk.isEmpty else { reachedEOF = true; return }
                consumedBytes += chunk.count

                chunk.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                    guard let base = buf.baseAddress else { return }
                    var start = 0
                    while start < buf.count {
                        let remaining = buf.count - start
                        let searchBase = base + start
                        guard let nlOffset = memchrNewline(searchBase, remaining) else {
                            // 这个 chunk 读到头了还没碰到 \n：剩下的是不完整的一行（或继续在跳过超长行）
                            if !skipping {
                                tail.append(contentsOf: UnsafeRawBufferPointer(start: searchBase, count: remaining))
                                if tail.count > maxLineBytes {
                                    tail.removeAll(keepingCapacity: false)
                                    skipping = true
                                }
                            }
                            start = buf.count
                            continue
                        }
                        if skipping {
                            skipping = false // 这一行终于遇到了结尾，下一行重新开始正常处理
                        } else if !tail.isEmpty {
                            tail.append(contentsOf: UnsafeRawBufferPointer(start: searchBase, count: nlOffset))
                            if tail.count <= maxLineBytes {
                                tail.withUnsafeBytes(onLine)
                            }
                            tail.removeAll(keepingCapacity: false)
                        } else if nlOffset > 0, nlOffset <= maxLineBytes {
                            onLine(UnsafeRawBufferPointer(start: searchBase, count: nlOffset))
                        } // nlOffset > maxLineBytes 且 tail 为空：整行都在本 chunk 内但超长，直接丢弃
                        start += nlOffset + 1
                    }
                }
            }
            if reachedEOF { break }
        }

        // tail 里剩的是还没凑齐的半行，不计入这次消费的字节数，下次从这里重新读
        return offset + Int64(consumedBytes) - Int64(tail.count)
    }

    @inline(__always)
    private static func memchrNewline(_ base: UnsafeRawPointer, _ count: Int) -> Int? {
        guard count > 0, let found = memchr(base, 0x0A, count) else { return nil }
        return UnsafeRawPointer(found) - base
    }
}

/// 在转 String/JSON 之前先在原始字节上做便宜的前过滤：只有同时包含这两个字节串的行才值得解析。
/// 用 memmem 在字节层面找，不碰 Swift 的 Unicode 感知字符串查找（对几 MB 的行那个慢得离谱）。
enum LineBytePrefilter {
    static let assistantType: [UInt8] = Array("\"type\":\"assistant\"".utf8)
    static let usageKey: [UInt8] = Array("\"usage\"".utf8)
    static let timestampKey: [UInt8] = Array("\"timestamp\":\"".utf8)
    /// 正常的 assistant usage 行就几 KB；超过这个就不值得再解析（截图之类的大结果不会是 assistant usage 行）
    static let maxLineForJSON = 2 * 1024 * 1024

    static func looksLikeAssistantUsageLine(_ buf: UnsafeRawBufferPointer) -> Bool {
        guard buf.count > 0, buf.count <= maxLineForJSON else { return false }
        return contains(buf, usageKey) && contains(buf, assistantType)
    }

    static func hasAssistantType(_ buf: UnsafeRawBufferPointer) -> Bool {
        guard buf.count > 0, buf.count <= maxLineForJSON else { return false }
        return contains(buf, assistantType)
    }

    /// 轻量取出 "timestamp":"..." 这一个字段的值，不整行转 String、不做 JSON 解码——用来给
    /// "触发这次请求的那条非 assistant 行"记时间，不值得为了一个字段把几 MB 的行都转一遍。
    static func extractTimestamp(_ buf: UnsafeRawBufferPointer) -> Date? {
        guard let base = buf.baseAddress, buf.count > 0, buf.count <= maxLineForJSON else { return nil }
        guard let found: UnsafeMutableRawPointer = timestampKey.withUnsafeBufferPointer({ p in
            guard let pBase = p.baseAddress else { return nil }
            return memmem(base, buf.count, pBase, p.count)
        }) else { return nil }

        let afterKey = UnsafeRawPointer(found) + timestampKey.count
        let consumed = afterKey - base
        guard consumed < buf.count else { return nil }
        let remaining = buf.count - consumed
        guard let endQuote = memchr(afterKey, 0x22 /* " */, remaining) else { return nil }
        let len = UnsafeRawPointer(endQuote) - afterKey
        guard len > 0, len < 64 else { return nil }
        let s = String(decoding: UnsafeRawBufferPointer(start: afterKey, count: len), as: UTF8.self)
        return ISO8601.parse(s)
    }

    /// 给 Codex 这种"按行里 type 字段分派"的读者用：任意字节模式的便宜命中检查，同一个 memmem 底子
    static func matches(_ buf: UnsafeRawBufferPointer, _ pattern: [UInt8]) -> Bool {
        guard buf.count > 0, buf.count <= maxLineForJSON else { return false }
        return contains(buf, pattern)
    }

    private static func contains(_ buf: UnsafeRawBufferPointer, _ pattern: [UInt8]) -> Bool {
        guard let base = buf.baseAddress, buf.count >= pattern.count else { return false }
        return pattern.withUnsafeBufferPointer { p -> Bool in
            guard let pBase = p.baseAddress else { return false }
            return memmem(base, buf.count, pBase, p.count) != nil
        }
    }
}

/// 极简只读 SQLite 包装，只给 Usage 后端用。不写、不建索引、不改 PRAGMA journal_mode。
final class ReadOnlySQLite {
    private static let sqliteMagic: [UInt8] = Array("SQLite format 3\0".utf8)
    private var db: OpaquePointer?
    /// 因 WAL 库头存在但缺 -shm、常规只读打不开而退回 immutable=1（此时同目录未归档的 -wal 不会被读到）
    private(set) var usedImmutableFallback = false

    init?(path: String, busyTimeoutMs: Int32 = 2000, immutable: Bool = false) {
        // 调用方显式要 immutable（Antigravity 原生库：只读快照，不跟 agy 抢锁；看不到未检查点的 WAL，
        // 刚生成的一步可能暂时补不出模型，下轮再补）
        if immutable, let uri = Self.immutableURI(path) {
            guard let handle = Self.openAndProbe(uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, busyTimeoutMs: busyTimeoutMs) else { return nil }
            self.db = handle
            self.usedImmutableFallback = true
            return
        }
        // 先走常规只读：delete 日志模式（如 Cursor 的 state.vscdb）本来就没有 -shm，开着照样写，
        // 按“无 -shm”直接挂 immutable=1 会关掉文件锁读到撕裂页；只有常规打开/预探失败、
        // 且确认库头为 WAL 模式又确实缺 -shm 时，才退回 immutable=1 只读主库。
        if let handle = Self.openAndProbe(path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, busyTimeoutMs: busyTimeoutMs) {
            self.db = handle
            return
        }
        if FileManager.default.fileExists(atPath: path + "-shm"),
           let handle = Self.openAndProbe(path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, busyTimeoutMs: busyTimeoutMs) {
            self.db = handle
            return
        }
        guard Self.hasWalHeaderWithoutShm(at: path) else { return nil }
        let uri = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
        guard let handle = Self.openAndProbe(
            uri,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX,
            busyTimeoutMs: busyTimeoutMs
        ) else {
            return nil
        }
        self.db = handle
        self.usedImmutableFallback = true
    }

    private static func openAndProbe(_ target: String, flags: Int32, busyTimeoutMs: Int32) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(target, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, busyTimeoutMs)
        // 这是只读、偶尔跑一下的统计查询，不该替一个几 GB 的 live db 占着大页缓存：
        // cache_size 封顶 ~2MB，不许 mmap 整个库，query_only 顶一层"绝不写"的保险
        sqlite3_exec(handle, "PRAGMA query_only=1;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA cache_size=-2000;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA mmap_size=0;", nil, nil, nil)
        // sqlite3_open_v2 延迟读页头，预探并 step 一次 sqlite_master，打不开当场返回 nil 而非静默查出空集
        var probe: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT 1 FROM sqlite_master LIMIT 1;", -1, &probe, nil) == SQLITE_OK else {
            if let probe { sqlite3_finalize(probe) }
            sqlite3_close(handle)
            return nil
        }
        let stepRc = sqlite3_step(probe)
        sqlite3_finalize(probe)
        guard stepRc == SQLITE_ROW || stepRc == SQLITE_DONE else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    /// SQLite 页头偏移 18/19 为写/读版本，值为 2 代表 WAL 模式（1 为回滚日志模式）
    private static func hasWalHeaderWithoutShm(at path: String) -> Bool {
        guard !FileManager.default.fileExists(atPath: path + "-shm"),
              let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let header: Data
        if #available(macOS 10.15.4, *) {
            guard let d = try? fh.read(upToCount: 20) else { return false }
            header = d
        } else {
            header = fh.readData(ofLength: 20)
        }
        guard header.count >= 20, header.starts(with: sqliteMagic) else { return false }
        return header[18] == 2 || header[19] == 2
    }

    func tableExists(_ name: String) -> Bool {
        var found = false
        query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1", bind: [name]) { _ in
            found = true
        }
        return found
    }

    func tableHasRows(_ name: String) -> Bool {
        var nonEmpty = false
        query("SELECT 1 FROM \(name) LIMIT 1") { _ in
            nonEmpty = true
        }
        return nonEmpty
    }

    private static func immutableURI(_ path: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-_.")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "file:\(encoded)?immutable=1"
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// 查询，每行把列值用闭包交出去（只支持 TEXT/BLOB/INTEGER，够用就行）。
    /// row 闭包返回 false 就提前收手（给"这一轮字节预算用完了"用），不是异常，只是正常停止。
    @discardableResult
    func query(_ sql: String, bind: [Any] = [], row: (Row) -> Bool) -> Bool {
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt else { return true }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            default: break
            }
        }

        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            if !row(Row(stmt: stmt)) { return false }
            step = sqlite3_step(stmt)
        }
        return true
    }

    /// 旧签名的便利重载：不需要提前收手的调用点不用改
    func query(_ sql: String, bind: [Any] = [], row: (Row) -> Void) {
        query(sql, bind: bind) { row($0); return true }
    }

    struct Row {
        let stmt: OpaquePointer?

        /// 列的原始字节数，不做任何转换——用来在转 String 之前先判断这一列是不是大得不正常
        func byteCount(_ col: Int32) -> Int { Int(sqlite3_column_bytes(stmt, col)) }

        /// maxBytes 给大列设个上限：超过就不转 String/Data 了，直接当 nil（opencode 的 message.data
        /// 列里偶尔有几十 MB 的用户粘贴内容，真正带 usage 的 assistant 行从没见过超过几 KB 的）
        func text(_ col: Int32, maxBytes: Int = .max) -> String? {
            let len = byteCount(col)
            guard len > 0, len <= maxBytes, let c = sqlite3_column_text(stmt, col) else { return len == 0 ? "" : nil }
            // 列可能是 BLOB 类型存的文本（VS Code/Cursor 的 ItemTable），先按字节长度取出来再判断编码
            let data = Data(bytes: c, count: len)
            if let s = String(data: data, encoding: .utf8) { return s }
            if let s = String(data: data, encoding: .utf16LittleEndian) { return s }
            return nil
        }

        func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
    }
}

/// 查额度用的网络会话：带着登录令牌，所以不落任何缓存、不存 cookie。
/// URLSession.shared 会把请求（含 Cookie 头）写进 ~/Library/Caches/<bundle>/Cache.db，违反“令牌不落盘”。
enum UsageHTTP {
    static var session: URLSession {
        #if DEBUG
        if let debugSession { return debugSession }
        #endif
        return standard
    }

    #if DEBUG
    /// `--cursor-refresh-test` 把 URLProtocol 桩塞进会话，请求不出网
    private static var debugSession: URLSession?
    static func installDebugProtocols(_ types: [AnyClass]) {
        debugSession = make(protocols: types)
    }
    static func clearDebugSession() { debugSession = nil }
    #endif

    private static let standard: URLSession = make(protocols: [])

    private static func make(protocols: [AnyClass]) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        if !protocols.isEmpty {
            c.protocolClasses = protocols + (c.protocolClasses ?? [])
        }
        return URLSession(configuration: c)
    }
}

/// 冷拉用量时看本进程物理占用。只读计数，不分配大块内存。
enum UsageFootprint {
    static func bytes() -> UInt64 {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : 0
    }
}
