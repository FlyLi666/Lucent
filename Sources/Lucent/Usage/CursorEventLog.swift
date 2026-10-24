import Foundation

// Cursor 逐条用量。额度百分比仍走 usage-summary；这里补 token / 金额 / 模型 / 请求。
//
// Adapted from tokscale (MIT) — junhoyeo/tokscale dashboard usage-events
// （https://cursor.com/api/dashboard/ 下的用量导出；CSV 一次拉全历史，大账号会到几十 MB）
// and CodexBar (MIT) — CursorUsageEventsFetcher
// POST https://cursor.com/api/dashboard/get-filtered-usage-events
// 用 startDate/endDate（毫秒字符串）把窗口限制在近 30 天，之后只补最近 6 小时，靠 usageEventId 去重。
// 金额用 chargedCents / 100：这是账单扣的美分。totalCents 是牌价，免费额度会和账单不一致。
// 缓存只留聚合数字和近 6 小时的事件 id，不留令牌。

struct CursorRemoteEvent: Sendable {
    var id: String
    var timeMS: Int64
    var model: String
    var input: Int64
    var output: Int64
    var cacheRead: Int64
    var cacheWrite: Int64
    var costUSD: Double
}

struct CursorEventsPageResult: Sendable {
    var status: Int?
    var total: Int?
    var events: [CursorRemoteEvent]
    var failureReason: String?
}

struct CursorSyncOutcome: Sendable {
    var usage: ToolUsage
    var failureReason: String?
    var httpRequests: Int
    var peakBytes: UInt64
    var account: CursorAccount
}

private struct CursorEventCache: Codable, Sendable {
    var days: [String: DayBucket] = [:]
    var hours: [String: HourBucket] = [:]
    var detailHours: [String: [String: [String: DetailBucket]]] = [:]
    var detailDays: [String: [String: [String: DetailBucket]]] = [:]
    var recentRequests: [UsageRequestCodable] = []
    var lastActivity: Date?
    /// 只留最近 6 小时，给增量重叠去重。过期的已经进了天/小时桶，不需要再留 id。
    var seen: [String: Int64] = [:]
    var watermarkMS: Int64 = 0
    var hasBaseline: Bool = false
    var version: Int = CursorEventCache.currentVersion
    static let currentVersion = 1
}

/// 一个 Cursor 账号一份缓存。网络失败时不改缓存，界面继续用上次的数字。
final class CursorEventLog {
    static let provider = "Cursor"
    private static let pageSize = 1000
    /// 30 天窗口里每页 1000 条，40 页是 4 万条。再多就停，避免把分页走到全历史。
    private static let maxPages = 40
    private static let overlapMS: Int64 = 6 * 3600 * 1000
    private static let windowMS: Int64 = 30 * 24 * 3600 * 1000
    private static let waitingReason = "等 Cursor 刷新登录"
    private static let expiredReason = "登录已过期，在 Cursor 里重新登录这个账号即可"

    private let cacheFile: URL
    private let reader: CursorUsageReader
    private var cache: CursorEventCache

    init(cacheToken: String, reader: CursorUsageReader) {
        cacheFile = UsageCacheLocation.url("cursor-usage-\(cacheToken).json")
        self.reader = reader
        if let data = try? Data(contentsOf: cacheFile),
           let decoded = try? JSONDecoder().decode(CursorEventCache.self, from: data),
           decoded.version == CursorEventCache.currentVersion {
            cache = decoded
        } else {
            cache = CursorEventCache()
        }
    }

    func cachedUsage(now: Date = Date()) -> ToolUsage { makeUsage(from: cache, now: now) }

    /// 首次拉近 30 天；之后从上次成功的结束时间往前重叠 6 小时。401 时只有 allowRefresh 才换令牌。
    func sync(account: CursorAccount, allowRefresh: Bool, now: Date = Date()) async -> CursorSyncOutcome {
        var peak = UsageFootprint.bytes()
        var requests = 0
        var current = account
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        let earliest = nowMS - Self.windowMS
        let startMS = cache.hasBaseline ? max(earliest, cache.watermarkMS - Self.overlapMS) : earliest

        var failure: String?
        for attempt in 0..<2 {
            var working = cache
            var unique = Set<String>()
            var page = 1
            var complete = false
            var unauthorized = false
            failure = nil
            while page <= Self.maxPages {
                requests += 1
                peak = max(peak, UsageFootprint.bytes())
                let result = await reader.fetchEventsPage(account: current, page: page, pageSize: Self.pageSize,
                                                           startMS: startMS, endMS: nowMS)
                peak = max(peak, UsageFootprint.bytes())
                if result.status == 401 {
                    unauthorized = true
                    failure = Self.waitingReason
                    break
                }
                if let reason = result.failureReason {
                    failure = reason
                    break
                }
                var added = 0
                for event in result.events where event.timeMS >= startMS {
                    if unique.insert(event.id).inserted { added += 1 }
                    apply(event, to: &working)
                }
                let pageFull = result.events.count >= Self.pageSize
                let reachedTotal = result.total.map { unique.count >= $0 } ?? false
                if result.events.isEmpty || !pageFull || reachedTotal {
                    complete = true
                    break
                }
                if added == 0 {
                    failure = "用量分页没有前进"
                    break
                }
                page += 1
            }
            if !complete && failure == nil {
                failure = "用量太多，这次没拉完"
            }
            if unauthorized && allowRefresh && attempt == 0, let rotated = await reader.refreshedAccount(current) {
                current = rotated
                continue
            }
            if unauthorized && allowRefresh {
                failure = Self.expiredReason
            }
            if complete && failure == nil {
                working.hasBaseline = true
                working.watermarkMS = max(working.watermarkMS, nowMS)
                prune(&working, now: now)
                cache = working
                save()
            }
            break
        }

        return CursorSyncOutcome(usage: makeUsage(from: cache, now: now), failureReason: failure,
                                  httpRequests: requests, peakBytes: max(peak, UsageFootprint.bytes()), account: current)
    }

    private func apply(_ event: CursorRemoteEvent, to cache: inout CursorEventCache) {
        if cache.seen[event.id] != nil { return }
        cache.seen[event.id] = event.timeMS
        let date = Date(timeIntervalSince1970: Double(event.timeMS) / 1000)
        let day = localDayKey(date)
        let hour = localHourKey(date)
        let delta = TokenCountsCodable(input: event.input, output: event.output, cacheRead: event.cacheRead, cacheWrite: event.cacheWrite)

        var bucket = cache.days[day] ?? DayBucket()
        var tokens = bucket.tokensByModel[event.model] ?? TokenCountsCodable()
        tokens = tokens + delta
        bucket.tokensByModel[event.model] = tokens
        bucket.costByModel[event.model] = (bucket.costByModel[event.model] ?? 0) + event.costUSD
        bucket.requestsByModel[event.model] = (bucket.requestsByModel[event.model] ?? 0) + 1
        bucket.requests += 1
        cache.days[day] = bucket

        var hourBucket = cache.hours[hour] ?? HourBucket()
        hourBucket.tokens = hourBucket.tokens + delta
        hourBucket.cost += event.costUSD
        hourBucket.requests += 1
        cache.hours[hour] = hourBucket

        ClaudeCodeUsageReader.addDetail(&cache.detailHours, key: hour, provider: Self.provider, model: event.model,
                                         delta: delta, cost: event.costUSD, cacheSavings: 0, cacheWrite1h: 0, durationMs: nil)
        ClaudeCodeUsageReader.addDetail(&cache.detailDays, key: day, provider: Self.provider, model: event.model,
                                         delta: delta, cost: event.costUSD, cacheSavings: 0, cacheWrite1h: 0, durationMs: nil)

        let request = UsageRequestCodable(id: event.id, time: date, tool: AITool.cursor.rawValue, model: event.model,
                                           project: nil, sessionID: nil, tokens: delta, cacheWrite1h: 0, cost: event.costUSD,
                                           provider: Self.provider, durationMs: nil, durationIsEstimate: true)
        RequestRing.push(request, into: &cache.recentRequests)
        if cache.lastActivity == nil || date > cache.lastActivity! { cache.lastActivity = date }
    }

    private func prune(_ cache: inout CursorEventCache, now: Date) {
        let keep365 = Set(last365DayKeys(now: now))
        let keep30 = Set(last30DayKeys(now: now))
        for key in cache.days.keys where !keep365.contains(key) { cache.days.removeValue(forKey: key) }
        for key in cache.detailDays.keys where !keep365.contains(key) { cache.detailDays.removeValue(forKey: key) }
        for key in cache.hours.keys where !keep30.contains(String(key.prefix(10))) { cache.hours.removeValue(forKey: key) }
        for key in cache.detailHours.keys where !keep30.contains(String(key.prefix(10))) { cache.detailHours.removeValue(forKey: key) }
        let keepAfter = cache.watermarkMS - Self.overlapMS
        cache.seen = cache.seen.filter { $0.value >= keepAfter }
        let requestCutoff = now.addingTimeInterval(-30 * 86400)
        cache.recentRequests.removeAll { $0.time < requestCutoff }
    }

    private func makeUsage(from cache: CursorEventCache, now: Date) -> ToolUsage {
        var usage = ToolUsage(tool: .cursor)
        usage.costKind = .billed
        usage.status = .ok
        let (today, daily, models) = ClaudeCodeUsageReader.buildWindows(from: cache.days, now: now)
        usage.today = today
        usage.daily = daily
        usage.models = models
        usage.history = ClaudeCodeUsageReader.buildHistory(from: cache.days, now: now)
        usage.hourly = ClaudeCodeUsageReader.buildHourly(from: cache.hours, now: now)
        let keep = Set(last30DayKeys(now: now))
        usage.recentRequests = cache.recentRequests.compactMap { $0.toContract() }.filter { keep.contains(localDayKey($0.time)) }
        usage.hourlyDetail = ClaudeCodeUsageReader.buildDetailBuckets(from: cache.detailHours, tool: .cursor) { date(forHourKey: $0) }
        usage.dailyDetail = ClaudeCodeUsageReader.buildDetailBuckets(from: cache.detailDays, tool: .cursor) { date(forDayKey: $0) }
        usage.lastActivity = cache.lastActivity
        let recentCut = now.addingTimeInterval(-300)
        let recentTokens = usage.recentRequests.reduce(Int64(0)) { partial, request in
            request.time >= recentCut ? partial + request.tokens.total : partial
        }
        usage.tokensPerMinute = Double(recentTokens) / 5
        let blocks = UsageBlocks.summarize(hours: cache.hours, now: now)
        usage.currentBlock = blocks.current
        usage.recentBlocks = blocks.recent
        usage.peakBlockTokens = blocks.peak
        return usage
    }

    private func save() {
        UsageCacheLocation.ensureDir()
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}
