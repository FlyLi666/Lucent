import Foundation

// OpenCode 用量：~/.local/share/opencode/opencode.db。
// V1 写在 message，V2 迁移后写在 session_message（两表可能并存历史与新消息，按消息 id 合并去重；V2 表空或不存在时只读 V1）。
// OpenCode 的 message / session_message 均无 time_updated 索引（只有 rowid 主键、message(session_id,time_created,id)、
// session_message(time_created)），按 time_updated 设游标会每次整表扫：因此主增量仍走 rowid 游标，
// 另外只在有索引的最近窗口 / 未完结候选集里补查“rowid 已扫过但后来原地 UPDATE 补齐完成态”的行。

struct OpenCodeTableCursor: Codable, Sendable {
    var lastRowid: Int64 = 0
    /// 已追平的更新水位（毫秒）；存在未完结行时压在最早未完结行之前，供最近窗口补查过滤旧行
    var caughtUpUpdatedMs: Int64 = 0
    /// rowid <= lastRowid 中见到过但当时未完结的行，下轮按主键直查兜底（防并发大量新行挤出尾窗）
    var pendingRowids: [Int64] = []
}

struct OpenCodeUsageCache: Codable, Sendable {
    /// 统计口径变了就加一，旧缓存丢弃重算
    static let currentVersion = 7
    var version: Int? = OpenCodeUsageCache.currentVersion
    var cursorByTable: [String: OpenCodeTableCursor] = [:]
    /// 已入账消息 id -> 创建毫秒时间戳，防原地 UPDATE 重算，也供 V1 + V2 合并按消息 id 去重
    var countedMessages: [String: Int64] = [:]
    /// 按 UTC 整点键存最长 367 天（供应商 × 模型）聚合，不绑定写入时的本机时区
    var detailHours: [String: [String: [String: DetailBucket]]] = [:]
    /// 近 32 天按 UTC 整点存项目聚合
    var projectHours: [String: [String: ProjectBucket]] = [:]
    var recentRequests: [UsageRequestCodable] = []
    /// 同 Claude：跨重启、跨空转都要保留，不能只在当次扫描里算
    var lastActivity: Date?
    /// db + -wal 文件的 size/mtime：俩都没变就说明上次扫完之后数据库压根没被写过，
    /// 这次直接跳过查询（不开连接、不跑 SQL），只从缓存里重建要发给界面的窗口
    var lastDbSize: Int64 = -1
    var lastDbMtime: Double = -1
    var lastWalSize: Int64 = -1
    var lastWalMtime: Double = -1
}

struct OpenCodeLocalResult: Sendable {
    /// 这轮因为限量没读完，还有积压
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
    /// provider/model 组合里花费一直是 0 的（比如走自定义中转的 provider），只做诊断用，不进契约
    var zeroCostProviders: Set<String>
    var currentBlock: UsageBlock? = nil
    var recentBlocks: [UsageBlock] = []
    var peakBlockTokens: Int64 = 0
}

final class OpenCodeUsageReader {
    private var dataDir: URL { UsageHome.url.appendingPathComponent(".local/share/opencode") }
    private let cacheFile = UsageCacheLocation.url("opencode-usage-cache.json")
    private var recent = RecentEventWindow()

    /// message.data 绝大多数是几百字节到几 KB 的 JSON，但偶尔有用户粘贴的几十 MB 大段内容
    /// （实际见过 25MB 的，都是 role=user，从来没见过带 usage 的 assistant 行超过几 KB）
    private let maxRowDataBytes = 256 * 1024
    private var zeroCostProviders: Set<String> = []
    /// 上一轮因为限量没读完（还有积压）
    private var pendingBacklog = false

    func scan() -> OpenCodeLocalResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dataDir.path) else {
            return Self.emptyResult(.notInstalled)
        }
        let dbPath = dataDir.appendingPathComponent("opencode.db").path
        let walPath = dbPath + "-wal"
        guard fm.fileExists(atPath: dbPath) else {
            return Self.emptyResult(.notInstalled)
        }

        var cache = loadCache()
        let now = Date()

        let dbAttrs = try? fm.attributesOfItem(atPath: dbPath)
        let dbSize = (dbAttrs?[.size] as? Int64) ?? -1
        let dbMtime = (dbAttrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let walAttrs = try? fm.attributesOfItem(atPath: walPath)
        let walSize = (walAttrs?[.size] as? Int64) ?? 0
        let walMtime = (walAttrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        let unchanged = dbSize == cache.lastDbSize && dbMtime == cache.lastDbMtime
            && walSize == cache.lastWalSize && walMtime == cache.lastWalMtime

        if !unchanged {
            guard let db = ReadOnlySQLite(path: dbPath) else {
                return Self.emptyResult(.failed(L("打不开 opencode 的数据库")))
            }
            runIncrementalQuery(db: db, cache: &cache)
            if pendingBacklog {
                // 还没读完：不能记成“没变”，否则数据库不再写入时剩下的永远读不到
                cache.lastDbSize = -2
            } else if db.usedImmutableFallback {
                // immutable=1 会忽略同目录的 -wal：只要 -wal 有字节就不能记成已消费，留 -1 让下轮继续重试
                cache.lastDbSize = dbSize
                cache.lastDbMtime = dbMtime
                cache.lastWalSize = walSize > 0 ? -1 : 0
                cache.lastWalMtime = walSize > 0 ? -1 : walMtime
            } else {
                cache.lastDbSize = dbSize
                cache.lastDbMtime = dbMtime
                cache.lastWalSize = walSize
                cache.lastWalMtime = walMtime
            }
            pruneOld(&cache, now: now)
            saveCache(cache)
        }

        let snap = UTCHourRollup.build(detailHours: cache.detailHours, projectHours: cache.projectHours,
                                       tool: .opencode, now: now)
        let requests = cache.recentRequests.compactMap { $0.toContract() }
        // OpenCode 没有像 Claude 那样可信的公开价目表：有价（非 0 美元）就说明记录里本来有价，没价就留 nil，
        // 只标一句"记录的金额是不是 $0"，不编一个假的单价
        let pricing = snap.models.map { m in
            PricingEntry(model: m.model, tool: .opencode, input: nil, output: nil, cacheRead: nil,
                         cacheWrite5m: nil, cacheWrite1h: nil,
                         source: m.cost == 0 ? L("OpenCode 自带记录（金额 $0）") : L("OpenCode 自带记录"))
        }

        let blocks = UsageBlocks.summarize(utcDetailHours: cache.detailHours, now: now)
        var result = OpenCodeLocalResult(status: .ok, today: snap.today, daily: snap.daily, models: snap.models, history: snap.history,
                                    hourly: snap.hourly, recentRequests: requests, projects: snap.projects,
                                    hourlyDetail: snap.hourlyDetail, dailyDetail: snap.dailyDetail, pricing: pricing,
                                    lastActivity: cache.lastActivity, tokensPerMinute: recent.tokensPerMinute(now: now),
                                    zeroCostProviders: zeroCostProviders)
        result.hasBacklog = pendingBacklog
        result.currentBlock = blocks.current
        result.recentBlocks = blocks.recent
        result.peakBlockTokens = blocks.peak
        return result
    }

    private enum TableKind {
        case v1Message
        case v2SessionMessage
    }

    private struct TableSpec {
        var name: String
        var kind: TableKind
        var sessionJoinSQL: String
        var dirExprSQL: String
    }

    private static let recentUpdateWindowMs: Int64 = 6 * 3600 * 1000
    private static let recentRowidTail: Int64 = 512
    private static let watermarkOverlapMs: Int64 = 60 * 1000
    private static let pendingRetentionMs: Int64 = 24 * 3600 * 1000

    /// V2 表为空或不存在时照旧只读 V1，不能因为预建了空表就切换；
    /// V2 表有数据时，V1 message 与 V2 session_message 一起读并按 countedMessages[id] 合并去重。
    private static func activeTables(db: ReadOnlySQLite) -> [TableSpec] {
        let hasMessage = db.tableExists("message")
        let hasSessionMessage = db.tableExists("session_message") && db.tableHasRows("session_message")
        let hasSession = db.tableExists("session")
        let hasSessionV2 = db.tableExists("session_v2")

        var specs: [TableSpec] = []
        if hasMessage {
            let joinSQL = hasSession ? "LEFT JOIN session s ON s.id = m.session_id" : ""
            let dirSQL = hasSession ? "s.directory" : "NULL"
            specs.append(TableSpec(name: "message", kind: .v1Message, sessionJoinSQL: joinSQL, dirExprSQL: dirSQL))
        }
        if hasSessionMessage {
            let joinSQL: String
            let dirSQL: String
            if hasSessionV2 && hasSession {
                joinSQL = "LEFT JOIN session_v2 s2 ON s2.id = m.session_id LEFT JOIN session s1 ON s1.id = m.session_id"
                dirSQL = "COALESCE(s2.directory, s1.directory)"
            } else if hasSessionV2 {
                joinSQL = "LEFT JOIN session_v2 s ON s.id = m.session_id"
                dirSQL = "s.directory"
            } else if hasSession {
                joinSQL = "LEFT JOIN session s ON s.id = m.session_id"
                dirSQL = "s.directory"
            } else {
                joinSQL = ""
                dirSQL = "NULL"
            }
            specs.append(TableSpec(name: "session_message", kind: .v2SessionMessage, sessionJoinSQL: joinSQL, dirExprSQL: dirSQL))
        }
        return specs
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func runIncrementalQuery(db: ReadOnlySQLite, cache: inout OpenCodeUsageCache) {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let historyCutoffMs = Int64((now.addingTimeInterval(-365 * 86400)).timeIntervalSince1970 * 1000)
        var lastActivity = cache.lastActivity
        var bytesBudget = 32 * 1024 * 1024
        var hitBudget = false
        defer { pendingBacklog = hitBudget }

        let tables = Self.activeTables(db: db)
        for spec in tables {
            guard bytesBudget > 0 else { hitBudget = true; break }
            scanTable(db: db, spec: spec, cache: &cache, bytesBudget: &bytesBudget,
                      hitBudget: &hitBudget, nowMs: nowMs, historyCutoffMs: historyCutoffMs,
                      lastActivity: &lastActivity)
            if hitBudget { break }
        }
        cache.lastActivity = lastActivity
    }

    private struct TableScanState {
        var newRowid: Int64
        var maxUpdatedSeen: Int64
        var incompleteHoldMs: Int64?
        var stillPending = Set<Int64>()
        var resolvedRowids = Set<Int64>()
    }

    private func scanTable(
        db: ReadOnlySQLite,
        spec: TableSpec,
        cache: inout OpenCodeUsageCache,
        bytesBudget: inout Int,
        hitBudget: inout Bool,
        nowMs: Int64,
        historyCutoffMs: Int64,
        lastActivity: inout Date?
    ) {
        let prior = cache.cursorByTable[spec.name] ?? OpenCodeTableCursor()
        var state = TableScanState(newRowid: prior.lastRowid, maxUpdatedSeen: prior.caughtUpUpdatedMs)

        let selectCols: String
        let typeFilter: String
        switch spec.kind {
        case .v1Message:
            selectCols = "m.rowid, m.id, m.time_created, m.time_updated, m.data, \(spec.dirExprSQL), NULL"
            typeFilter = ""
        case .v2SessionMessage:
            selectCols = "m.rowid, m.id, m.time_created, m.time_updated, m.data, \(spec.dirExprSQL), m.type"
            typeFilter = "AND m.type IN ('assistant', 'compaction') "
        }

        // 1) 主增量：rowid 是 SQLite 隐式整数主键，有索引且严格单调，无新行时 O(log N) 即停，绝不整表扫
        let newRowsSQL = "SELECT \(selectCols) FROM \(spec.name) m \(spec.sessionJoinSQL) " +
            "WHERE m.rowid > ? AND m.time_created >= ? \(typeFilter)" +
            "AND length(m.data) <= \(maxRowDataBytes) ORDER BY m.rowid ASC"
        db.query(newRowsSQL, bind: [prior.lastRowid, historyCutoffMs]) { row in
            self.ingestRow(row, spec: spec, advanceRowid: true, nowMs: nowMs, state: &state,
                           cache: &cache, bytesBudget: &bytesBudget, hitBudget: &hitBudget, lastActivity: &lastActivity)
        }

        // 2) 补查“rowid 已读过（<= prior.lastRowid）但之后原地 UPDATE 补齐完成态”的行：
        // 两表都没有 time_updated 索引，不能写 WHERE time_updated > ? 扫全表；
        // V1 message 只有 (session_id, time_created, id) 复合索引而无独立 time_created 索引，故走主键 rowid 最近尾窗；
        // V2 session_message 有 (time_created) 索引，走最近时间窗并用 +m.rowid 禁用 rowid<=? 索引以免从第 1 行扫起。
        if !hitBudget && prior.lastRowid > 0 {
            let windowCreatedCutoffMs = max(historyCutoffMs, nowMs - Self.recentUpdateWindowMs)
            let updatedCutoffMs = prior.caughtUpUpdatedMs > 0
                ? max(windowCreatedCutoffMs, prior.caughtUpUpdatedMs - Self.watermarkOverlapMs)
                : windowCreatedCutoffMs
            switch spec.kind {
            case .v1Message:
                let tailStart = max(0, prior.lastRowid - Self.recentRowidTail)
                let catchupSQL = "SELECT \(selectCols) FROM \(spec.name) m \(spec.sessionJoinSQL) " +
                    "WHERE m.rowid > ? AND m.rowid <= ? AND m.time_created >= ? AND m.time_updated >= ? " +
                    "AND length(m.data) <= \(maxRowDataBytes) ORDER BY m.rowid ASC"
                db.query(catchupSQL, bind: [tailStart, prior.lastRowid, windowCreatedCutoffMs, updatedCutoffMs]) { row in
                    self.ingestRow(row, spec: spec, advanceRowid: false, nowMs: nowMs, state: &state,
                                   cache: &cache, bytesBudget: &bytesBudget, hitBudget: &hitBudget, lastActivity: &lastActivity)
                }
            case .v2SessionMessage:
                let catchupSQL = "SELECT \(selectCols) FROM \(spec.name) m \(spec.sessionJoinSQL) " +
                    "WHERE m.time_created >= ? AND +m.rowid <= ? AND m.time_updated >= ? \(typeFilter)" +
                    "AND length(m.data) <= \(maxRowDataBytes)"
                db.query(catchupSQL, bind: [windowCreatedCutoffMs, prior.lastRowid, updatedCutoffMs]) { row in
                    self.ingestRow(row, spec: spec, advanceRowid: false, nowMs: nowMs, state: &state,
                                   cache: &cache, bytesBudget: &bytesBudget, hitBudget: &hitBudget, lastActivity: &lastActivity)
                }
            }
        }

        // 3) 若曾记下过未完结行且已被挤出上面的尾窗，按主键 rowid 逐个点查兜底
        if !hitBudget && !prior.pendingRowids.isEmpty {
            let pointSQL = "SELECT \(selectCols) FROM \(spec.name) m \(spec.sessionJoinSQL) " +
                "WHERE m.rowid = ? AND length(m.data) <= \(maxRowDataBytes)"
            for pendingRowid in prior.pendingRowids where !state.resolvedRowids.contains(pendingRowid) && !state.stillPending.contains(pendingRowid) {
                guard !hitBudget else {
                    state.stillPending.insert(pendingRowid)
                    continue
                }
                db.query(pointSQL, bind: [pendingRowid]) { row in
                    self.ingestRow(row, spec: spec, advanceRowid: false, nowMs: nowMs, state: &state,
                                   cache: &cache, bytesBudget: &bytesBudget, hitBudget: &hitBudget, lastActivity: &lastActivity)
                }
            }
        }

        let nextWatermark: Int64
        if hitBudget {
            nextWatermark = state.incompleteHoldMs.map { min(prior.caughtUpUpdatedMs, $0) } ?? prior.caughtUpUpdatedMs
            for r in prior.pendingRowids where !state.resolvedRowids.contains(r) {
                state.stillPending.insert(r)
            }
        } else {
            nextWatermark = state.incompleteHoldMs ?? max(state.maxUpdatedSeen, nowMs)
        }
        cache.cursorByTable[spec.name] = OpenCodeTableCursor(
            lastRowid: state.newRowid,
            caughtUpUpdatedMs: nextWatermark,
            pendingRowids: Array(state.stillPending.sorted().suffix(256))
        )
    }

    private func ingestRow(
        _ row: ReadOnlySQLite.Row,
        spec: TableSpec,
        advanceRowid: Bool,
        nowMs: Int64,
        state: inout TableScanState,
        cache: inout OpenCodeUsageCache,
        bytesBudget: inout Int,
        hitBudget: inout Bool,
        lastActivity: inout Date?
    ) -> Bool {
        guard bytesBudget > 0 else { hitBudget = true; return false }
        let rowid = row.int64(0)
        if advanceRowid { state.newRowid = rowid }
        let id = row.text(1) ?? ""
        let timeCreated = row.int64(2)
        let timeUpdated = row.int64(3)
        let rowType = row.text(6)
        if timeUpdated > state.maxUpdatedSeen { state.maxUpdatedSeen = timeUpdated }

        if !id.isEmpty, cache.countedMessages[id] != nil {
            state.resolvedRowids.insert(rowid)
            return true
        }

        let dataBytes = row.byteCount(4)
        guard dataBytes > 0, dataBytes <= maxRowDataBytes else {
            state.resolvedRowids.insert(rowid)
            return true
        }
        bytesBudget -= dataBytes
        guard let dataStr = row.text(4, maxBytes: maxRowDataBytes) else { return true }

        if !dataStr.contains("\"tokens\"") {
            let isAssistantCandidate: Bool
            switch spec.kind {
            case .v1Message: isAssistantCandidate = dataStr.contains("\"assistant\"")
            case .v2SessionMessage: isAssistantCandidate = (rowType == "assistant" || rowType == "compaction")
            }
            if isAssistantCandidate && timeCreated >= nowMs - Self.pendingRetentionMs {
                state.stillPending.insert(rowid)
                let hold = max(0, timeUpdated - 1)
                state.incompleteHoldMs = state.incompleteHoldMs.map { min($0, hold) } ?? hold
            } else {
                state.resolvedRowids.insert(rowid)
            }
            return true
        }

        guard let data = dataStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }

        if case .v1Message = spec.kind, (obj["role"] as? String) != "assistant" {
            state.resolvedRowids.insert(rowid)
            return true
        }

        let timeDict = obj["time"] as? [String: Any]
        let isCompleted: Bool
        if rowType == "compaction" {
            let status = obj["status"] as? String
            isCompleted = status == "completed" || status == "failed"
        } else if let completedVal = timeDict?["completed"], !(completedVal is NSNull) {
            isCompleted = true
        } else {
            isCompleted = false
        }
        // 未完成占位行跳过不入账；记入 pendingRowids 并压住更新水位，等原地 UPDATE 补齐完成态后再补收
        guard isCompleted else {
            if timeCreated >= nowMs - Self.pendingRetentionMs {
                state.stillPending.insert(rowid)
                let hold = max(0, timeUpdated - 1)
                state.incompleteHoldMs = state.incompleteHoldMs.map { min($0, hold) } ?? hold
            } else {
                state.resolvedRowids.insert(rowid)
            }
            return true
        }
        state.resolvedRowids.insert(rowid)

        guard let tokens = obj["tokens"] as? [String: Any] else { return true }
        let modelDict = obj["model"] as? [String: Any]
        let modelID = Self.nonEmpty(obj["modelID"] as? String)
            ?? Self.nonEmpty(obj["model"] as? String)
            ?? Self.nonEmpty(modelDict?["id"] as? String)
            ?? "unknown"
        let providerID = Self.nonEmpty(obj["providerID"] as? String)
            ?? Self.nonEmpty(modelDict?["providerID"] as? String)
            ?? "unknown"
        let cost = (obj["cost"] as? NSNumber)?.doubleValue ?? 0
        let input = (tokens["input"] as? NSNumber)?.int64Value ?? 0
        let rawOutput = (tokens["output"] as? NSNumber)?.int64Value ?? 0
        let reasoning = (tokens["reasoning"] as? NSNumber)?.int64Value ?? 0
        // OpenCode 的 tokens.output 不含思考 token，并入输出才能计入总 token 与输出统计
        let output = rawOutput + reasoning
        let cacheDict = tokens["cache"] as? [String: Any]
        let cacheRead = (cacheDict?["read"] as? NSNumber)?.int64Value ?? 0
        let cacheWrite = (cacheDict?["write"] as? NSNumber)?.int64Value ?? 0
        if input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 { return true }

        let jsonCreatedMs = (timeDict?["created"] as? NSNumber)?.int64Value ?? 0
        let createdMs = timeCreated > 0 ? timeCreated : jsonCreatedMs
        if !id.isEmpty { cache.countedMessages[id] = createdMs }

        let timestamp = Date(timeIntervalSince1970: Double(createdMs) / 1000)
        let utcHour = utcHourKey(timestamp)
        let tcThis = TokenCountsCodable(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: reasoning)

        let project = (row.text(5)).flatMap { dir -> String? in
            let last = (dir as NSString).lastPathComponent
            return last.isEmpty ? nil : last
        }
        if let project {
            UTCHourRollup.addProject(&cache.projectHours, utcHour: utcHour, project: project,
                                     delta: tcThis, cost: cost, timestamp: timestamp)
        }

        var durationMs: Int?
        if let timeDict,
           let created = (timeDict["created"] as? NSNumber)?.int64Value, created > 0 {
            let streamed = (timeDict["streamed"] as? NSNumber)?.int64Value
            let completed = (timeDict["completed"] as? NSNumber)?.int64Value
            let end = (streamed != nil && streamed! > created) ? streamed : completed
            if let end, end > created {
                durationMs = Int(end - created)
            }
        }

        ClaudeCodeUsageReader.addDetail(&cache.detailHours, key: utcHour, provider: providerID,
                                         model: modelID, delta: tcThis, cost: cost, cacheSavings: 0,
                                         cacheWrite1h: 0, durationMs: durationMs)

        let requestEntry = UsageRequestCodable(id: id, time: timestamp, tool: AITool.opencode.rawValue, model: modelID,
                                                project: project, sessionID: nil, tokens: tcThis, cacheWrite1h: 0, cost: cost,
                                                provider: providerID, durationMs: durationMs, durationIsEstimate: false)
        RequestRing.push(requestEntry, into: &cache.recentRequests)

        if cost == 0 { self.zeroCostProviders.insert("\(providerID)/\(modelID)") }

        self.recent.add(timestamp, input + output)
        if lastActivity == nil || timestamp > lastActivity! { lastActivity = timestamp }
        return true
    }

    private static func emptyResult(_ status: UsageStatus) -> OpenCodeLocalResult {
        OpenCodeLocalResult(status: status, today: DailyUsage(day: Calendar.current.startOfDay(for: Date())),
                             daily: [], models: [], history: [], hourly: [], recentRequests: [], projects: [],
                             hourlyDetail: [], dailyDetail: [], pricing: [],
                             lastActivity: nil, tokensPerMinute: 0, zeroCostProviders: [])
    }

    private func pruneOld(_ cache: inout OpenCodeUsageCache, now: Date) {
        pruneUTCHourBuckets(&cache.detailHours, olderThan: now.addingTimeInterval(-367 * 86400))
        pruneUTCHourBuckets(&cache.projectHours, olderThan: now.addingTimeInterval(-32 * 86400))
        let idCutoffMs = Int64(now.addingTimeInterval(-367 * 86400).timeIntervalSince1970 * 1000)
        cache.countedMessages = cache.countedMessages.filter { $0.value >= idCutoffMs }
    }

    private func loadCache() -> OpenCodeUsageCache {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode(OpenCodeUsageCache.self, from: data),
              cache.version == OpenCodeUsageCache.currentVersion
        else { return OpenCodeUsageCache() }
        return cache
    }

    private func saveCache(_ cache: OpenCodeUsageCache) {
        UsageCacheLocation.ensureDir()
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}
