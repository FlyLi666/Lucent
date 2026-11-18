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
    /// 按 UTC 整点键存最长 367 天聚合，避免切换本机时区后丢天或错窗
    var detailHours: [String: [String: [String: DetailBucket]]] = [:]
    /// 版本升级迁移下来的 30 天以前按日汇总（yyyy-MM-dd -> 供应商 -> 模型 -> DetailBucket），只读保留、不随冷扫丢弃
    var archivedDetailDays: [String: [String: [String: DetailBucket]]] = [:]
    var recentRequests: [UsageRequestCodable] = []
    var lastActivity: Date?
    /// 保留满 30 天已入账的 usageEventId，防止分页跨过 6 小时重叠窗或延迟补账时重复计入
    var seen: [String: Int64] = [:]
    var watermarkMS: Int64 = 0
    var hasBaseline: Bool = false
    var version: Int = CursorEventCache.currentVersion
    static let currentVersion = 2

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detailHours = try c.decodeIfPresent([String: [String: [String: DetailBucket]]].self, forKey: .detailHours) ?? [:]
        archivedDetailDays = try c.decodeIfPresent([String: [String: [String: DetailBucket]]].self, forKey: .archivedDetailDays) ?? [:]
        recentRequests = try c.decodeIfPresent([UsageRequestCodable].self, forKey: .recentRequests) ?? []
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        seen = try c.decodeIfPresent([String: Int64].self, forKey: .seen) ?? [:]
        watermarkMS = try c.decodeIfPresent(Int64.self, forKey: .watermarkMS) ?? 0
        hasBaseline = try c.decodeIfPresent(Bool.self, forKey: .hasBaseline) ?? false
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }
}

/// 兼容解码旧版缓存（如 v1 的 days/detailDays/本地小时键）：冷扫重拉成功前既不删原文件（含 seen 去重表），也能提取 30 天前的日汇总只读保留。
private struct LegacyCursorEventCache: Decodable, Sendable {
    var days: [String: DayBucket]
    var detailHours: [String: [String: [String: DetailBucket]]]
    var detailDays: [String: [String: [String: DetailBucket]]]
    var archivedDetailDays: [String: [String: [String: DetailBucket]]]
    var recentRequests: [UsageRequestCodable]
    var lastActivity: Date?
    var version: Int

    private enum CodingKeys: String, CodingKey {
        case days, detailHours, detailDays, archivedDetailDays, recentRequests, lastActivity, version
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decodeIfPresent([String: DayBucket].self, forKey: .days) ?? [:]
        detailHours = try c.decodeIfPresent([String: [String: [String: DetailBucket]]].self, forKey: .detailHours) ?? [:]
        detailDays = try c.decodeIfPresent([String: [String: [String: DetailBucket]]].self, forKey: .detailDays) ?? [:]
        archivedDetailDays = try c.decodeIfPresent([String: [String: [String: DetailBucket]]].self, forKey: .archivedDetailDays) ?? [:]
        recentRequests = try c.decodeIfPresent([UsageRequestCodable].self, forKey: .recentRequests) ?? []
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }

    func allDetailDays(provider: String) -> [String: [String: [String: DetailBucket]]] {
        var merged = archivedDetailDays
        for (dayKey, byProvider) in detailDays where merged[dayKey] == nil || merged[dayKey]?.isEmpty == true {
            merged[dayKey] = byProvider
        }
        for (dayKey, bucket) in days where merged[dayKey] == nil || merged[dayKey]?.isEmpty == true {
            var byModel: [String: DetailBucket] = [:]
            let models = Set(bucket.tokensByModel.keys)
                .union(bucket.costByModel.keys)
                .union(bucket.requestsByModel.keys)
            var assignedSavings = false
            for model in models {
                var cell = DetailBucket()
                cell.tokens = bucket.tokensByModel[model] ?? TokenCountsCodable()
                cell.cost = bucket.costByModel[model] ?? 0
                cell.requests = bucket.requestsByModel[model] ?? 0
                if !assignedSavings {
                    cell.cacheSavings = bucket.cacheSavings
                    cell.cacheWrite1h = bucket.cacheWrite1h
                    assignedSavings = true
                }
                if cell.requests > 0 || cell.tokens.total > 0 {
                    byModel[model] = cell
                }
            }
            if !byModel.isEmpty {
                merged[dayKey] = [provider: byModel]
            }
        }
        if version >= 2 {
            var fromHours: [String: [String: [String: DetailBucket]]] = [:]
            for (uKey, byProvider) in detailHours {
                guard let utcDate = date(forUTCHourKey: uKey) else { continue }
                let dKey = localDayKey(utcDate)
                guard merged[dKey] == nil else { continue }
                var dstProv = fromHours[dKey] ?? [:]
                for (prov, byModel) in byProvider {
                    var dstModel = dstProv[prov] ?? [:]
                    for (model, cell) in byModel {
                        var dst = dstModel[model] ?? DetailBucket()
                        dst.tokens = dst.tokens + cell.tokens
                        dst.cost += cell.cost
                        dst.requests += cell.requests
                        dst.cacheSavings += cell.cacheSavings
                        dst.cacheWrite1h += cell.cacheWrite1h
                        dst.timedOutputTokens += cell.timedOutputTokens
                        dst.timedDurationMs += cell.timedDurationMs
                        dstModel[model] = dst
                    }
                    dstProv[prov] = dstModel
                }
                fromHours[dKey] = dstProv
            }
            for (dKey, byProvider) in fromHours {
                merged[dKey] = byProvider
            }
        }
        return merged
    }
}

/// 一个 Cursor 账号一份缓存。网络失败时不改缓存，界面继续用上次的数字。
final class CursorEventLog {
    static let provider = "Cursor"
    private static let pageSize = 1000
    /// 30 天窗口里每页 1000 条，40 页是 4 万条。再多就停，避免把分页走到全历史。
    private static let maxPages = 40
    private static let overlapMS: Int64 = 6 * 3600 * 1000
    private static let windowMS: Int64 = 30 * 24 * 3600 * 1000
    private static var waitingReason: String { L("等 Cursor 刷新登录") }
    private static var expiredReason: String { L("登录已过期，在 Cursor 里重新登录这个账号即可") }

    private let cacheFile: URL
    private let reader: CursorUsageReader
    private var cache: CursorEventCache
    /// 版本不符时先只读持有旧缓存，等 30 天冷拉成功后再合入 >30 天归档并原子落盘，失败期间磁盘旧文件与去重集合原样保留
    private var pendingLegacy: LegacyCursorEventCache?

    init(cacheToken: String, reader: CursorUsageReader) {
        cacheFile = UsageCacheLocation.url("cursor-usage-\(cacheToken).json")
        self.reader = reader
        if let data = try? Data(contentsOf: cacheFile) {
            if let decoded = try? JSONDecoder().decode(CursorEventCache.self, from: data),
               decoded.version == CursorEventCache.currentVersion {
                cache = decoded
            } else {
                cache = CursorEventCache()
                pendingLegacy = try? JSONDecoder().decode(LegacyCursorEventCache.self, from: data)
            }
        } else {
            cache = CursorEventCache()
        }
    }

    func cachedUsage(now: Date = Date()) -> ToolUsage {
        if let legacy = pendingLegacy {
            return makeLegacyUsage(from: legacy, now: now)
        }
        return makeUsage(from: cache, now: now)
    }

    /// 首次拉近 30 天；之后从上次成功的结束时间往前重叠 6 小时。401 时只有 allowRefresh 才换令牌。
    func sync(account: CursorAccount, allowRefresh: Bool, now: Date = Date()) async -> CursorSyncOutcome {
        var peak = UsageFootprint.bytes()
        var requests = 0
        var current = account
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        let earliest = nowMS - Self.windowMS
        let archivedDays: [String: [String: [String: DetailBucket]]]
        let startMS: Int64
        if let legacy = pendingLegacy {
            let allLegacyDays = legacy.allDetailDays(provider: Self.provider)
            let keep365 = Set(last365DayKeys(now: now))
            let earliestDayKey = localDayKey(Date(timeIntervalSince1970: Double(earliest) / 1000))
            if allLegacyDays[earliestDayKey] != nil,
               let first30Key = last30DayKeys(now: now).first,
               let first30Start = date(forDayKey: first30Key) {
                // 旧缓存已含第 -30 天日汇总：以近 30 天首日零点为分界，此前按日只读保留，此后按接口重拉，不重不漏
                archivedDays = allLegacyDays.filter { keep365.contains($0.key) && $0.key < first30Key }
                startMS = Int64(first30Start.timeIntervalSince1970 * 1000)
            } else {
                archivedDays = allLegacyDays.filter { keep365.contains($0.key) && $0.key < earliestDayKey }
                startMS = earliest
            }
        } else {
            archivedDays = cache.archivedDetailDays
            startMS = cache.hasBaseline ? max(earliest, cache.watermarkMS - Self.overlapMS) : earliest
        }

        var failure: String?
        for attempt in 0..<2 {
            var working = pendingLegacy == nil ? cache : CursorEventCache()
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
                    failure = L("用量分页没有前进")
                    break
                }
                page += 1
            }
            if !complete && failure == nil {
                failure = L("用量太多，这次没拉完")
            }
            if unauthorized && allowRefresh && attempt == 0, let rotated = await reader.refreshedAccount(current) {
                current = rotated
                continue
            }
            if unauthorized && allowRefresh {
                failure = Self.expiredReason
            }
            if complete && failure == nil {
                working.archivedDetailDays = archivedDays
                if let legacyLast = pendingLegacy?.lastActivity,
                   working.lastActivity == nil || legacyLast > working.lastActivity! {
                    working.lastActivity = legacyLast
                }
                working.hasBaseline = true
                working.watermarkMS = max(working.watermarkMS, nowMS)
                prune(&working, now: now)
                cache = working
                pendingLegacy = nil
                save()
            }
            break
        }

        return CursorSyncOutcome(usage: cachedUsage(now: now), failureReason: failure,
                                  httpRequests: requests, peakBytes: max(peak, UsageFootprint.bytes()), account: current)
    }

    private func apply(_ event: CursorRemoteEvent, to cache: inout CursorEventCache) {
        if cache.seen[event.id] != nil { return }
        cache.seen[event.id] = event.timeMS
        let date = Date(timeIntervalSince1970: Double(event.timeMS) / 1000)
        let utcHour = utcHourKey(date)
        let delta = TokenCountsCodable(input: event.input, output: event.output, cacheRead: event.cacheRead, cacheWrite: event.cacheWrite)

        ClaudeCodeUsageReader.addDetail(&cache.detailHours, key: utcHour, provider: Self.provider, model: event.model,
                                         delta: delta, cost: event.costUSD, cacheSavings: 0, cacheWrite1h: 0, durationMs: nil)

        let request = UsageRequestCodable(id: event.id, time: date, tool: AITool.cursor.rawValue, model: event.model,
                                           project: nil, sessionID: nil, tokens: delta, cacheWrite1h: 0, cost: event.costUSD,
                                           provider: Self.provider, durationMs: nil, durationIsEstimate: true)
        RequestRing.push(request, into: &cache.recentRequests)
        if cache.lastActivity == nil || date > cache.lastActivity! { cache.lastActivity = date }
    }

    private func prune(_ cache: inout CursorEventCache, now: Date) {
        pruneUTCHourBuckets(&cache.detailHours, olderThan: now.addingTimeInterval(-367 * 86400))
        let oldestArchivedKey = dayKey(daysAgo: 366, from: now)
        for key in Array(cache.archivedDetailDays.keys) where key < oldestArchivedKey {
            cache.archivedDetailDays.removeValue(forKey: key)
        }
        // 保留满 30 天（多留 1 天覆盖本地自然日零点），绝不删未来时间戳
        let keepAfter = Int64(now.timeIntervalSince1970 * 1000) - 31 * 24 * 3600 * 1000
        cache.seen = cache.seen.filter { $0.value >= keepAfter }
        let requestCutoff = now.addingTimeInterval(-32 * 86400)
        cache.recentRequests.removeAll { $0.time < requestCutoff }
    }

    private func makeLegacyUsage(from legacy: LegacyCursorEventCache, now: Date) -> ToolUsage {
        var temp = CursorEventCache()
        var coveredDays = Set<String>()
        for (hourKey, byProvider) in legacy.detailHours {
            let parsed = (legacy.version >= 2 ? date(forUTCHourKey: hourKey) : date(forHourKey: hourKey)) ?? date(forUTCHourKey: hourKey)
            guard let parsed else { continue }
            coveredDays.insert(localDayKey(parsed))
            let uKey = utcHourKey(parsed)
            var dstProv = temp.detailHours[uKey] ?? [:]
            for (prov, byModel) in byProvider {
                var dstModel = dstProv[prov] ?? [:]
                for (model, cell) in byModel {
                    var dst = dstModel[model] ?? DetailBucket()
                    dst.tokens = dst.tokens + cell.tokens
                    dst.cost += cell.cost
                    dst.requests += cell.requests
                    dst.cacheSavings += cell.cacheSavings
                    dst.cacheWrite1h += cell.cacheWrite1h
                    dst.timedOutputTokens += cell.timedOutputTokens
                    dst.timedDurationMs += cell.timedDurationMs
                    dstModel[model] = dst
                }
                dstProv[prov] = dstModel
            }
            temp.detailHours[uKey] = dstProv
        }
        for (dKey, byProvider) in legacy.allDetailDays(provider: Self.provider) where !coveredDays.contains(dKey) {
            temp.archivedDetailDays[dKey] = byProvider
        }
        temp.recentRequests = legacy.recentRequests
        temp.lastActivity = legacy.lastActivity
        return makeUsage(from: temp, now: now, includeArchivedIn30DayWindow: true)
    }

    private func makeUsage(from cache: CursorEventCache, now: Date, includeArchivedIn30DayWindow: Bool = false) -> ToolUsage {
        var usage = ToolUsage(tool: .cursor)
        usage.costKind = .billed
        usage.status = .ok
        let cal = Calendar.current
        let snap = UTCHourRollup.build(detailHours: cache.detailHours, tool: .cursor, now: now, calendar: cal)
        usage.today = snap.today
        usage.daily = snap.daily
        usage.models = snap.models
        usage.history = snap.history
        usage.hourly = snap.hourly
        let keep = Set(last30DayKeys(now: now, calendar: cal))
        usage.recentRequests = cache.recentRequests.compactMap { $0.toContract() }.filter { keep.contains(localDayKey($0.time, calendar: cal)) }
        usage.hourlyDetail = snap.hourlyDetail
        usage.dailyDetail = snap.dailyDetail

        if !cache.archivedDetailDays.isEmpty {
            let keep365 = Set(last365DayKeys(now: now, calendar: cal))
            for idx in usage.history.indices {
                let dKey = localDayKey(usage.history[idx].day, calendar: cal)
                guard !keep.contains(dKey) || includeArchivedIn30DayWindow,
                      let byProvider = cache.archivedDetailDays[dKey] else { continue }
                var addTokens = TokenCountsCodable()
                var addCost = 0.0
                var addReqs = 0
                var addSavings = 0.0
                var addWrite1h: Int64 = 0
                for byModel in byProvider.values {
                    for cell in byModel.values where cell.requests > 0 || cell.tokens.total > 0 {
                        addTokens = addTokens + cell.tokens
                        addCost += cell.cost
                        addReqs += cell.requests
                        addSavings += cell.cacheSavings
                        addWrite1h += cell.cacheWrite1h
                    }
                }
                if addReqs > 0 || addTokens.total > 0 {
                    let prev = usage.history[idx]
                    usage.history[idx] = DailyUsage(
                        day: prev.day,
                        tokens: (TokenCountsCodable(input: prev.tokens.input, output: prev.tokens.output,
                                                    cacheRead: prev.tokens.cacheRead, cacheWrite: prev.tokens.cacheWrite,
                                                    reasoning: prev.tokens.reasoning, unsplit: prev.tokens.unsplit) + addTokens).asTokenCounts,
                        cost: prev.cost + addCost,
                        requests: prev.requests + addReqs,
                        cacheSavings: prev.cacheSavings + addSavings,
                        cacheWrite1h: prev.cacheWrite1h + addWrite1h
                    )
                }
            }
            if includeArchivedIn30DayWindow {
                var modelTotals: [String: (tokens: TokenCountsCodable, cost: Double, requests: Int)] = [:]
                for m in usage.models {
                    modelTotals[m.model] = (
                        TokenCountsCodable(input: m.detail.input, output: m.detail.output, cacheRead: m.detail.cacheRead,
                                           cacheWrite: m.detail.cacheWrite, reasoning: m.detail.reasoning, unsplit: m.detail.unsplit),
                        m.cost, m.requests
                    )
                }
                for idx in usage.daily.indices {
                    let dKey = localDayKey(usage.daily[idx].day, calendar: cal)
                    guard let byProvider = cache.archivedDetailDays[dKey] else { continue }
                    var addTokens = TokenCountsCodable()
                    var addCost = 0.0
                    var addReqs = 0
                    var addSavings = 0.0
                    var addWrite1h: Int64 = 0
                    for byModel in byProvider.values {
                        for (model, cell) in byModel where cell.requests > 0 || cell.tokens.total > 0 {
                            addTokens = addTokens + cell.tokens
                            addCost += cell.cost
                            addReqs += cell.requests
                            addSavings += cell.cacheSavings
                            addWrite1h += cell.cacheWrite1h
                            var entry = modelTotals[model] ?? (TokenCountsCodable(), 0, 0)
                            entry.tokens = entry.tokens + cell.tokens
                            entry.cost += cell.cost
                            entry.requests += cell.requests
                            modelTotals[model] = entry
                        }
                    }
                    if addReqs > 0 || addTokens.total > 0 {
                        let prev = usage.daily[idx]
                        usage.daily[idx] = DailyUsage(
                            day: prev.day,
                            tokens: (TokenCountsCodable(input: prev.tokens.input, output: prev.tokens.output,
                                                        cacheRead: prev.tokens.cacheRead, cacheWrite: prev.tokens.cacheWrite,
                                                        reasoning: prev.tokens.reasoning, unsplit: prev.tokens.unsplit) + addTokens).asTokenCounts,
                            cost: prev.cost + addCost,
                            requests: prev.requests + addReqs,
                            cacheSavings: prev.cacheSavings + addSavings,
                            cacheWrite1h: prev.cacheWrite1h + addWrite1h
                        )
                    }
                }
                usage.today = usage.daily.last ?? usage.today
                usage.models = modelTotals.map { (model, v) in
                    ModelShare(model: model, tokens: v.tokens.asTokenCounts.total, cost: v.cost, detail: v.tokens.asTokenCounts, requests: v.requests)
                }.sorted { $0.tokens > $1.tokens }
            }

            var detailByKey: [String: UsageBucket] = [:]
            for b in usage.dailyDetail {
                detailByKey["\(localDayKey(b.start, calendar: cal))|\(b.provider)|\(b.model)"] = b
            }
            for (dKey, byProvider) in cache.archivedDetailDays where keep365.contains(dKey) && (!keep.contains(dKey) || includeArchivedIn30DayWindow) {
                guard let rawDate = date(forDayKey: dKey, calendar: cal) else { continue }
                let start = cal.startOfDay(for: rawDate)
                for (prov, byModel) in byProvider {
                    for (model, cell) in byModel where cell.requests > 0 {
                        let k = "\(dKey)|\(prov)|\(model)"
                        if let existing = detailByKey[k] {
                            let prevTC = TokenCountsCodable(input: existing.tokens.input, output: existing.tokens.output,
                                                            cacheRead: existing.tokens.cacheRead, cacheWrite: existing.tokens.cacheWrite,
                                                            reasoning: existing.tokens.reasoning, unsplit: existing.tokens.unsplit)
                            detailByKey[k] = UsageBucket(
                                start: start, tool: .cursor, provider: prov, model: model,
                                tokens: (prevTC + cell.tokens).asTokenCounts,
                                cost: existing.cost + cell.cost,
                                requests: existing.requests + cell.requests,
                                cacheSavings: existing.cacheSavings + cell.cacheSavings,
                                cacheWrite1h: existing.cacheWrite1h + cell.cacheWrite1h,
                                timedOutputTokens: existing.timedOutputTokens + cell.timedOutputTokens,
                                timedDurationMs: existing.timedDurationMs + cell.timedDurationMs
                            )
                        } else {
                            detailByKey[k] = UsageBucket(
                                start: start, tool: .cursor, provider: prov, model: model,
                                tokens: cell.tokens.asTokenCounts, cost: cell.cost, requests: cell.requests,
                                cacheSavings: cell.cacheSavings, cacheWrite1h: cell.cacheWrite1h,
                                timedOutputTokens: cell.timedOutputTokens, timedDurationMs: cell.timedDurationMs
                            )
                        }
                    }
                }
            }
            usage.dailyDetail = detailByKey.values.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.provider != $1.provider { return $0.provider < $1.provider }
                return $0.model < $1.model
            }
        }

        usage.lastActivity = cache.lastActivity
        let recentCut = now.addingTimeInterval(-300)
        let recentTokens = usage.recentRequests.reduce(Int64(0)) { partial, request in
            request.time >= recentCut ? partial + request.tokens.total : partial
        }
        usage.tokensPerMinute = Double(recentTokens) / 5
        let blocks = UsageBlocks.summarize(utcDetailHours: cache.detailHours, now: now)
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
