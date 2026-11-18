import Foundation

// Grok Build（Grok CLI，~/.grok/{sessions,archived_sessions}/<enc-cwd>/<session-id>/updates.jsonl）本机用量读取器。
// 1. 只统计 method == "_x.ai/session/update" 且 sessionUpdate 缺失或为 "turn_completed" 的事件；
//    显式标为其他类型（如中途快照）的一律跳过，避免与轮末事件双算。
// 2. 每个 turn_completed 都是该轮跨 inference loop 累加后的独立总量，按面值入账，严禁做相邻差分；
//    reasoningTokens 已含在 outputTokens 中，只做展示不重复计入 total 与费用。
// 3. inputTokens 含 cachedReadTokens，必须拆为 freshInput = max(0, inputTokens - cachedReadTokens) 与 cacheRead。
// 4. 沉降窗 60 秒：按文件顺序遇到第一条未沉降事件立即停止并保留待下轮补入，防止写入中途读残。
// 5. 仅读取会话目录内的 updates.jsonl 与 summary.json，跳过一切符号链接，绝不读取任何凭据文件。

struct GrokFileCursor: Codable, Sendable {
    var inode: UInt64
    var size: Int64
    var offset: Int64
    var mtime: Double = 0
    var eventCount: Int = 0
}

struct GrokBuildPriorRecord: Codable, Sendable, Equatable {
    var time: Double
    var tokens: TokenCountsCodable
    var cost: Double
    var savings: Double
    var reportedTicks: Int64
    var costIsPartial: Bool
    var durationMs: Int?
    var model: String
    var project: String?
    var sessionID: String
}

struct GrokBuildUsageCache: Codable, Sendable {
    static let currentVersion = 2
    var version: Int = GrokBuildUsageCache.currentVersion
    var fileCursors: [String: GrokFileCursor] = [:]
    var projectBySession: [String: String] = [:]
    var records: [String: GrokBuildPriorRecord] = [:]
    /// 按 UTC 整点键存最长 367 天（供应商 × 模型）聚合，不绑定写入时的本机时区
    var detailHours: [String: [String: [String: DetailBucket]]] = [:]
    /// 近 32 天按 UTC 整点存项目聚合
    var projectHours: [String: [String: ProjectBucket]] = [:]
    var recentRequests: [UsageRequestCodable] = []
    var lastActivity: Date?
}

struct GrokBuildLocalResult: Sendable {
    var hasBacklog = false
    var status: UsageStatus
    var today: DailyUsage
    var daily: [DailyUsage]
    var models: [ModelShare]
    var history: [DailyUsage]
    var hourly: [HourlyUsage]
    var recentRequests: [UsageRequest]
    var projects: [ProjectShare]
    var hourlyDetail: [UsageBucket]
    var dailyDetail: [UsageBucket]
    var pricing: [PricingEntry]
    var lastActivity: Date?
    var tokensPerMinute: Double
    var currentBlock: UsageBlock? = nil
    var recentBlocks: [UsageBlock] = []
    var peakBlockTokens: Int64 = 0
}

final class GrokBuildUsageReader {
    static let provider = "xAI"
    private static let settleWindowSeconds: TimeInterval = 60
    private static let maxGrokFileBytes: Int64 = 50 * 1024 * 1024
    private static let maxSummaryFileBytes: Int64 = 256 * 1024
    private static let maxCollectDepth = 16
    private static let roundBytesBudget = 64 * 1024 * 1024

    #if DEBUG
    struct DebugSpeedStats: Sendable {
        var totalRequests = 0
        var exactDurationCount = 0
        var speedSampleCount = 0
        var timedOutputTokens: Int64 = 0
        var timedDurationMs: Int64 = 0
    }
    nonisolated(unsafe) static var debugLastSpeedStats = DebugSpeedStats()
    #endif

    private let cacheFile = UsageCacheLocation.url("grokbuild-usage-cache.json")
    private let rebuildCacheFile = UsageCacheLocation.url("grokbuild-usage-cache.rebuild.json")
    private var recent = RecentEventWindow()

    private struct ParsedCounters {
        var input: Int64
        var output: Int64
        var cachedRead: Int64
        var reasoning: Int64
        var apiMs: Int64
        var costTicks: Int64
        var costPartial: Bool

        var isZero: Bool {
            input == 0 && output == 0 && cachedRead == 0
        }
    }

    private struct ParsedTurnEvent {
        var timestamp: Date
        var promptID: String
        var costIsPartial: Bool
        var perModel: [(model: String, counters: ParsedCounters)]
    }

    func scan() -> GrokBuildLocalResult {
        #if DEBUG
        Self.debugLastSpeedStats = DebugSpeedStats()
        #endif

        let fm = FileManager.default
        let grokDir = UsageHome.url.appendingPathComponent(".grok")
        guard fm.fileExists(atPath: grokDir.path) else {
            return Self.emptyResult(.notInstalled)
        }

        UsageCacheLocation.ensureDir()
        let hasExistingFile = fm.fileExists(atPath: cacheFile.path)
        var cache: GrokBuildUsageCache
        // 旧缓存版本不符或损坏时冷扫重建，全部追平前暂存 .rebuild 侧车，绝不提前删改磁盘上的旧缓存
        let rebuildingExisting: Bool
        if let validCache = loadValidCache(from: cacheFile) {
            cache = validCache
            rebuildingExisting = false
        } else if !hasExistingFile {
            cache = GrokBuildUsageCache()
            rebuildingExisting = false
        } else if let stagedCache = loadValidCache(from: rebuildCacheFile) {
            cache = stagedCache
            rebuildingExisting = true
        } else {
            cache = GrokBuildUsageCache()
            rebuildingExisting = true
        }
        repriceCachedRecords(&cache)

        let now = Date()
        let historyCutoff = now.addingTimeInterval(-365 * 86400)
        var lastActivity = cache.lastActivity
        var bytesBudget = Self.roundBytesBudget
        var hitBudgetCap = false
        var eligibleFiles = 0
        var eligibleSuccesses = 0
        var readFailures = 0

        let roots = [
            grokDir.appendingPathComponent("sessions").path,
            grokDir.appendingPathComponent("archived_sessions").path,
        ]
        var files: [String] = []
        for root in roots {
            Self.collectUpdatesFiles(under: root, depth: 0, into: &files)
        }
        files.sort()

        for path in files {
            if bytesBudget <= 0 {
                hitBudgetCap = true
                break
            }

            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let mtime = attrs[.modificationDate] as? Date,
                  let sizeNum = attrs[.size] as? NSNumber,
                  let inodeNum = attrs[.systemFileNumber] as? NSNumber
            else { continue }

            let size = sizeNum.int64Value
            let inode = inodeNum.uint64Value
            let mtimeSec = mtime.timeIntervalSince1970

            // 异常大文件跳过不读，避免单文件耗尽内存。
            if size > Self.maxGrokFileBytes {
                continue
            }

            if let prior = cache.fileCursors[path],
               prior.inode == inode, prior.size == size, prior.mtime == mtimeSec, prior.offset == size {
                if mtime >= historyCutoff {
                    eligibleFiles += 1
                    eligibleSuccesses += 1
                }
                continue
            }

            if mtime < historyCutoff {
                cache.fileCursors[path] = GrokFileCursor(inode: inode, size: size, offset: size, mtime: mtimeSec, eventCount: 0)
                continue
            }

            eligibleFiles += 1

            // 文件被重写或截断时从 0 重扫；rewind 被移除的旧轮次仍保留在 records 里不扣回。
            var startOffset: Int64 = 0
            var turnIndex = 0
            if let prior = cache.fileCursors[path], prior.inode == inode, prior.size <= size {
                startOffset = prior.offset
                turnIndex = prior.eventCount
            }

            let sessionDir = (path as NSString).deletingLastPathComponent
            let rawSessionID = (sessionDir as NSString).lastPathComponent
            let sessionID = rawSessionID.isEmpty ? "unknown" : rawSessionID
            let project = resolveProject(sessionID: sessionID, sessionDir: sessionDir, cache: &cache)

            var fileDeferred = false
            guard let newOffset = IncrementalLineReader.readNewLines(at: path, from: startOffset, maxBytes: bytesBudget, onLine: { buf in
                if fileDeferred { return }
                guard GrokBuildLinePrefilter.isUsageUpdateLine(buf) else { return }
                guard let event = Self.parseTurnEvent(from: buf) else { return }

                // 遇到第一条未过沉降窗的事件即停止：保持已导入前缀单调不漏，也不为未沉降事件触发 backlog 轮询。
                if now.timeIntervalSince(event.timestamp) < Self.settleWindowSeconds {
                    fileDeferred = true
                    return
                }

                let currentIdx = turnIndex
                turnIndex += 1
                guard event.timestamp >= historyCutoff else { return }

                let turnKey = event.promptID.isEmpty ? "idx\(currentIdx)" : event.promptID
                for (model, counters) in event.perModel {
                    if counters.isZero { continue }

                    let dedupID = "grok_session:\(sessionID):\(turnKey):\(model)"
                    let prior = cache.records[dedupID]
                    let freshInput = max(0, counters.input - counters.cachedRead)
                    let cacheRead = counters.cachedRead
                    let output = counters.output
                    let tc = TokenCountsCodable(
                        input: freshInput,
                        output: output,
                        cacheRead: cacheRead,
                        cacheWrite: 0,
                        reasoning: counters.reasoning)
                    let partial = event.costIsPartial || counters.costPartial
                    let (cost, savings) = GrokBuildCost.compute(
                        model: model,
                        freshInput: freshInput,
                        output: output,
                        cacheRead: cacheRead,
                        reportedTicks: counters.costTicks,
                        costIsPartial: partial)
                    // 仅采信事件自带的 apiDurationMs；缺失或为 0 时留 nil，绝不估算。
                    let durationMs: Int? = counters.apiMs > 0 ? Int(min(counters.apiMs, Int64(Int.max))) : nil
                    // 同一 request_id 覆写时保留首插时间戳，避免跨沉降窗或重扫时在日界边界漂移。
                    let recordTime = prior?.time ?? event.timestamp.timeIntervalSince1970

                    let updated = GrokBuildPriorRecord(
                        time: recordTime,
                        tokens: tc,
                        cost: cost,
                        savings: savings,
                        reportedTicks: counters.costTicks,
                        costIsPartial: partial,
                        durationMs: durationMs,
                        model: model,
                        project: project ?? prior?.project,
                        sessionID: sessionID)

                    if prior == updated { continue }
                    if let prior {
                        Self.retract(prior, id: dedupID, cache: &cache)
                    }
                    Self.apply(updated, id: dedupID, into: &cache)

                    if prior == nil {
                        recent.add(event.timestamp, freshInput + output)
                    }
                    if lastActivity == nil || event.timestamp > lastActivity! {
                        lastActivity = event.timestamp
                    }
                }
            }) else {
                readFailures += 1
                continue
            }
            eligibleSuccesses += 1

            bytesBudget -= Int(newOffset - startOffset)
            if fileDeferred {
                // 未沉降事件所在尾段不推进游标：若是首次读文件则不落游标，否则留在 startOffset 等下一轮重扫该尾段。
                if startOffset == 0 {
                    cache.fileCursors.removeValue(forKey: path)
                }
            } else {
                if newOffset < size { hitBudgetCap = true }
                cache.fileCursors[path] = GrokFileCursor(
                    inode: inode, size: size, offset: newOffset, mtime: mtimeSec, eventCount: turnIndex)
            }
        }

        cache.lastActivity = lastActivity
        pruneOld(&cache, now: now)
        let allEligibleFailed = eligibleFiles > 0 && readFailures == eligibleFiles && eligibleSuccesses == 0
        if rebuildingExisting {
            if allEligibleFailed {
                // 日志读取全部失败，冷扫未成功，不动旧缓存
            } else if hitBudgetCap {
                saveCache(cache, to: rebuildCacheFile)
            } else {
                saveCache(cache, to: cacheFile)
                try? fm.removeItem(at: rebuildCacheFile)
            }
        } else {
            saveCache(cache, to: cacheFile)
            try? fm.removeItem(at: rebuildCacheFile)
        }

        #if DEBUG
        var stats = DebugSpeedStats()
        stats.totalRequests = cache.records.count
        for rec in cache.records.values {
            if let ms = rec.durationMs, ms > 0 {
                stats.exactDurationCount += 1
                if rec.tokens.output >= SpeedRule.minOutputTokens {
                    stats.speedSampleCount += 1
                    stats.timedOutputTokens += rec.tokens.output
                    stats.timedDurationMs += Int64(ms)
                }
            }
        }
        Self.debugLastSpeedStats = stats
        #endif

        let snap = UTCHourRollup.build(detailHours: cache.detailHours, projectHours: cache.projectHours,
                                       tool: .grokbuild, now: now)
        let requests = cache.recentRequests.compactMap { $0.toContract() }
        let pricing = snap.models.map { Self.pricingEntry(for: $0.model, totalCost: $0.cost) }
        let blocks = UsageBlocks.summarize(utcDetailHours: cache.detailHours, now: now)

        var result = GrokBuildLocalResult(
            status: .ok,
            today: snap.today,
            daily: snap.daily,
            models: snap.models,
            history: snap.history,
            hourly: snap.hourly,
            recentRequests: requests,
            projects: snap.projects,
            hourlyDetail: snap.hourlyDetail,
            dailyDetail: snap.dailyDetail,
            pricing: pricing,
            lastActivity: lastActivity,
            tokensPerMinute: recent.tokensPerMinute(now: now))
        result.hasBacklog = hitBudgetCap
        result.currentBlock = blocks.current
        result.recentBlocks = blocks.recent
        result.peakBlockTokens = blocks.peak
        return result
    }

    static func pricingEntry(for model: String, totalCost: Double = 0) -> PricingEntry {
        let (rate, source) = GrokBuildPricingTable.rateWithSource(for: model)
        if let rate {
            return PricingEntry(
                model: model,
                tool: .grokbuild,
                input: rate.input * 1_000_000,
                output: rate.output * 1_000_000,
                cacheRead: rate.cacheRead * 1_000_000,
                cacheWrite5m: nil,
                cacheWrite1h: nil,
                source: source)
        }
        if totalCost > 0 {
            return PricingEntry(
                model: model,
                tool: .grokbuild,
                input: nil,
                output: nil,
                cacheRead: nil,
                cacheWrite5m: nil,
                cacheWrite1h: nil,
                source: L("Grok CLI 自带记录"))
        }
        return PricingEntry(
            model: model,
            tool: .grokbuild,
            input: nil,
            output: nil,
            cacheRead: nil,
            cacheWrite5m: nil,
            cacheWrite1h: nil,
            source: source)
    }

    // MARK: - 记账与回撤

    private static func apply(_ rec: GrokBuildPriorRecord, id: String, into cache: inout GrokBuildUsageCache) {
        let when = Date(timeIntervalSince1970: rec.time)
        let utcHour = utcHourKey(when)

        if let project = rec.project {
            UTCHourRollup.addProject(
                &cache.projectHours, utcHour: utcHour, project: project,
                delta: rec.tokens, cost: rec.cost, timestamp: when)
        }

        ClaudeCodeUsageReader.addDetail(
            &cache.detailHours, key: utcHour, provider: provider, model: rec.model,
            delta: rec.tokens, cost: rec.cost, cacheSavings: rec.savings,
            cacheWrite1h: 0, durationMs: rec.durationMs)

        let req = UsageRequestCodable(
            id: id, time: when, tool: AITool.grokbuild.rawValue, model: rec.model,
            project: rec.project, sessionID: rec.sessionID, tokens: rec.tokens,
            cacheWrite1h: 0, cost: rec.cost, provider: provider,
            durationMs: rec.durationMs, durationIsEstimate: false)
        RequestRing.replace(req, into: &cache.recentRequests)
        cache.records[id] = rec
    }

    private static func retract(_ prior: GrokBuildPriorRecord, id: String, cache: inout GrokBuildUsageCache) {
        let when = Date(timeIntervalSince1970: prior.time)
        let utcHour = utcHourKey(when)

        if let project = prior.project {
            UTCHourRollup.subtractProject(
                &cache.projectHours, utcHour: utcHour, project: project,
                delta: prior.tokens, cost: prior.cost)
        }

        ClaudeCodeUsageReader.subtractDetail(
            &cache.detailHours, key: utcHour, provider: provider, model: prior.model,
            delta: prior.tokens, cost: prior.cost, cacheSavings: prior.savings,
            cacheWrite1h: 0, durationMs: prior.durationMs)
        cache.recentRequests.removeAll { $0.id == id }
        cache.records.removeValue(forKey: id)
    }

    private func repriceCachedRecords(_ cache: inout GrokBuildUsageCache) {
        let ids = Array(cache.records.keys)
        for id in ids {
            guard let prior = cache.records[id] else { continue }
            let (cost, savings) = GrokBuildCost.compute(
                model: prior.model,
                freshInput: prior.tokens.input,
                output: prior.tokens.output,
                cacheRead: prior.tokens.cacheRead,
                reportedTicks: prior.reportedTicks,
                costIsPartial: prior.costIsPartial)
            if cost == prior.cost && savings == prior.savings { continue }
            var updated = prior
            updated.cost = cost
            updated.savings = savings
            Self.retract(prior, id: id, cache: &cache)
            Self.apply(updated, id: id, into: &cache)
        }
    }

    // MARK: - 目录发现与事件解析

    private static func collectUpdatesFiles(under dirPath: String, depth: Int, into files: inout [String]) {
        guard depth <= maxCollectDepth else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { return }
        for name in entries.sorted() {
            let childPath = (dirPath as NSString).appendingPathComponent(name)
            // attributesOfItem 对应 lstat，不跟随软链：无条件跳过一切符号链接，防目录循环或越界读取。
            guard let attrs = try? fm.attributesOfItem(atPath: childPath),
                  let fileType = attrs[.type] as? FileAttributeType
            else { continue }
            if fileType == .typeSymbolicLink { continue }
            if fileType == .typeDirectory {
                collectUpdatesFiles(under: childPath, depth: depth + 1, into: &files)
            } else if fileType == .typeRegular && name == "updates.jsonl" {
                files.append(childPath)
            }
        }
    }

    private func resolveProject(sessionID: String, sessionDir: String, cache: inout GrokBuildUsageCache) -> String? {
        if let cached = cache.projectBySession[sessionID] {
            return cached
        }
        let fm = FileManager.default
        let summaryPath = (sessionDir as NSString).appendingPathComponent("summary.json")
        if let attrs = try? fm.attributesOfItem(atPath: summaryPath),
           (attrs[.type] as? FileAttributeType) == .typeRegular,
           let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0, size <= Self.maxSummaryFileBytes,
           let data = try? Data(contentsOf: URL(fileURLWithPath: summaryPath)),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let info = obj["info"] as? [String: Any],
           let cwd = info["cwd"] as? String {
            let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let last = (trimmed as NSString).lastPathComponent
                if !last.isEmpty && last != "/" {
                    cache.projectBySession[sessionID] = last
                    return last
                }
            }
        }

        let parentDir = (sessionDir as NSString).deletingLastPathComponent
        let encCwd = (parentDir as NSString).lastPathComponent
        if !encCwd.isEmpty && encCwd != "sessions" && encCwd != "archived_sessions" && encCwd != "/" {
            let decoded = encCwd.removingPercentEncoding ?? encCwd
            let last = (decoded as NSString).lastPathComponent
            if !last.isEmpty && last != "/" {
                cache.projectBySession[sessionID] = last
                return last
            }
        }
        return nil
    }

    private static func parseTurnEvent(from buf: UnsafeRawBufferPointer) -> ParsedTurnEvent? {
        guard let base = buf.baseAddress, buf.count > 0 else { return nil }
        let data = Data(bytes: base, count: buf.count)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["method"] as? String) == "_x.ai/session/update",
              let params = obj["params"] as? [String: Any],
              let update = params["update"] as? [String: Any]
        else { return nil }

        // 只认 turn_completed（字段缺失时向后兼容放行，显式标为其它类型一律跳过以防快照双算）。
        if let kind = update["sessionUpdate"] as? String, kind != "turn_completed" {
            return nil
        }
        guard let usage = update["usage"] as? [String: Any],
              let timestamp = parseEventTimestamp(obj["timestamp"])
        else { return nil }

        let promptID = (update["prompt_id"] as? String) ?? ""
        let costIsPartial = boolValue(usage["costIsPartial"])

        var perModel: [(model: String, counters: ParsedCounters)] = []
        if let modelUsage = usage["modelUsage"] as? [String: Any], !modelUsage.isEmpty {
            for model in modelUsage.keys.sorted() {
                if let countersDict = modelUsage[model] as? [String: Any] {
                    perModel.append((model, parseCounters(countersDict)))
                }
            }
        }
        if perModel.isEmpty {
            perModel.append(("unknown", parseCounters(usage)))
        }

        return ParsedTurnEvent(
            timestamp: timestamp,
            promptID: promptID,
            costIsPartial: costIsPartial,
            perModel: perModel)
    }

    private static func parseCounters(_ dict: [String: Any]) -> ParsedCounters {
        ParsedCounters(
            input: nonNegativeInt64(dict["inputTokens"]),
            output: nonNegativeInt64(dict["outputTokens"]),
            cachedRead: nonNegativeInt64(dict["cachedReadTokens"]),
            reasoning: nonNegativeInt64(dict["reasoningTokens"]),
            apiMs: nonNegativeInt64(dict["apiDurationMs"]),
            costTicks: nonNegativeInt64(dict["costUsdTicks"]),
            costPartial: boolValue(dict["costIsPartial"]))
    }

    /// updates.jsonl 顶层 timestamp 实测为数字 epoch 秒；超过 1e11 视作毫秒，字符串作 RFC3339 兜底。
    static func parseEventTimestamp(_ raw: Any?) -> Date? {
        if let num = raw as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            let val = num.doubleValue
            guard val.isFinite, val >= 0 else { return nil }
            let sec = val > 100_000_000_000 ? val / 1000.0 : val
            return Date(timeIntervalSince1970: sec)
        }
        if let str = raw as? String {
            return AntigravityUsageReader.parseTimestamp(str)
        }
        return nil
    }

    private static func nonNegativeInt64(_ raw: Any?) -> Int64 {
        guard let num = raw as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() else { return 0 }
        let v = num.int64Value
        return v > 0 ? v : 0
    }

    private static func boolValue(_ raw: Any?) -> Bool {
        guard let num = raw as? NSNumber else { return (raw as? Bool) ?? false }
        return CFGetTypeID(num) == CFBooleanGetTypeID() ? num.boolValue : false
    }

    // MARK: - 缓存清理与持久化

    private static func emptyResult(_ status: UsageStatus) -> GrokBuildLocalResult {
        GrokBuildLocalResult(
            status: status,
            today: DailyUsage(day: Calendar.current.startOfDay(for: Date())),
            daily: [],
            models: [],
            history: [],
            hourly: [],
            recentRequests: [],
            projects: [],
            hourlyDetail: [],
            dailyDetail: [],
            pricing: [],
            lastActivity: nil,
            tokensPerMinute: 0)
    }

    private func pruneOld(_ cache: inout GrokBuildUsageCache, now: Date) {
        let cutoff367 = now.addingTimeInterval(-367 * 86400)
        pruneUTCHourBuckets(&cache.detailHours, olderThan: cutoff367)
        pruneUTCHourBuckets(&cache.projectHours, olderThan: now.addingTimeInterval(-32 * 86400))

        let cutoffSec = cutoff367.timeIntervalSince1970
        for (id, rec) in Array(cache.records) where rec.time < cutoffSec {
            cache.records.removeValue(forKey: id)
        }

        let fm = FileManager.default
        for path in Array(cache.fileCursors.keys) where !fm.fileExists(atPath: path) {
            cache.fileCursors.removeValue(forKey: path)
        }
        let activeSessions = Set(cache.records.values.map(\.sessionID))
        for sid in Array(cache.projectBySession.keys) where !activeSessions.contains(sid) {
            cache.projectBySession.removeValue(forKey: sid)
        }
    }

    private func loadValidCache(from url: URL) -> GrokBuildUsageCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(GrokBuildUsageCache.self, from: data),
              cache.version == GrokBuildUsageCache.currentVersion
        else { return nil }
        return cache
    }

    private func saveCache(_ cache: GrokBuildUsageCache, to url: URL) {
        UsageCacheLocation.ensureDir()
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private enum GrokBuildLinePrefilter {
    private static let methodValue = Array("\"_x.ai/session/update\"".utf8)
    private static let usageKey = Array("\"usage\"".utf8)

    static func isUsageUpdateLine(_ buf: UnsafeRawBufferPointer) -> Bool {
        guard buf.count > 0, buf.count <= IncrementalLineReader.maxLineBytes else { return false }
        return hasBytes(buf, methodValue) && hasBytes(buf, usageKey)
    }

    private static func hasBytes(_ buf: UnsafeRawBufferPointer, _ pattern: [UInt8]) -> Bool {
        guard let base = buf.baseAddress, buf.count >= pattern.count else { return false }
        return pattern.withUnsafeBufferPointer { p in
            guard let pBase = p.baseAddress else { return false }
            return memmem(base, buf.count, pBase, p.count) != nil
        }
    }
}
