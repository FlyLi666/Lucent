import Foundation

// OpenCode 用量：~/.local/share/opencode/opencode.db，message 表（目前是现行表；更新的
// session_message 表在多数安装里还是空的，是 opencode 还没切过去的新 schema，两个都查一下，
// 谁有数据用谁）。每行 data 是一段 JSON，assistant 消息带 tokens/cost/modelID/providerID。
// 项目名从 session 表的 directory 字段取最后一级（message 表本身没有目录信息，要 join 一下，
// session 表统共几百行，join 很便宜）。
//
// 数据库是常年开着写 WAL 的 live db（可能有好几 GB），只读打开、带 busy_timeout，绝不写。
//
// 增量游标用 rowid，不用 time_created：message/session_message 表都只按主键建了索引，
// 对 time_created 的全局查询没有可用索引，`WHERE time_created >= ?` 得整表扫完再排序。
// rowid 是 SQLite 隐式维护的主键别名，天然有索引、天然单调，`WHERE rowid > ?` 直接从游标那一页
// 续着扫，一行新数据都没有时几乎是 O(1)（早期版本按 time_created 扫，每 15 秒都要把
// 整个 10GB 的库读一遍——根源就是没有可用索引）。
//
// cacheWrite1h：OpenCode 的 tokens.cache 只有 read/write，没有 5m/1h 的拆分，这里恒为 0。
// cacheSavings：走自定义中转的 provider 常常是 $0 记账，算不出"按原价要多花多少"，
// 所以恒为 0（OpenCode 没有像 Claude 那样的公开价目表可以算"原价"）。

struct OpenCodeUsageCache: Codable, Sendable {
    /// 统计口径变了就加一，旧缓存丢弃重算（和 ClaudeUsageCache 同步）
    static let currentVersion = 5
    var version: Int? = OpenCodeUsageCache.currentVersion
    /// 每张表自己的 rowid 游标（message / session_message 的 rowid 空间互相独立）
    var lastRowidByTable: [String: Int64] = [:]
    /// 同 Claude：过了 30 天只留天总量，过了 365 天才真正删
    var days: [String: DayBucket] = [:]
    var hours: [String: HourBucket] = [:]
    var projectDays: [String: [String: ProjectBucket]] = [:]
    /// 近 30 天逐小时 / 全部历史逐日 × 供应商（providerID）× 模型
    var detailHours: [String: [String: [String: DetailBucket]]] = [:]
    var detailDays: [String: [String: [String: DetailBucket]]] = [:]
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
    private let dataDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode")
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
                return Self.emptyResult(.failed("打不开 opencode 的数据库"))
            }
            runIncrementalQuery(db: db, cache: &cache)
            if pendingBacklog {
                // 还没读完：不能记成“没变”，否则数据库不再写入时剩下的永远读不到
                cache.lastDbSize = -2
            } else {
                cache.lastDbSize = dbSize
                cache.lastDbMtime = dbMtime
                cache.lastWalSize = walSize
                cache.lastWalMtime = walMtime
            }
            pruneOld(&cache, now: now)
            saveCache(cache)
        }

        let (today, daily, models) = ClaudeCodeUsageReader.buildWindows(from: cache.days, now: now)
        let history = ClaudeCodeUsageReader.buildHistory(from: cache.days, now: now)
        let hourly = ClaudeCodeUsageReader.buildHourly(from: cache.hours, now: now)
        let projects = ClaudeCodeUsageReader.buildProjects(from: cache.projectDays, tool: .opencode, now: now)
        let requests = cache.recentRequests.compactMap { $0.toContract() }
        let hourlyDetail = ClaudeCodeUsageReader.buildDetailBuckets(from: cache.detailHours, tool: .opencode) { date(forHourKey: $0) }
        let dailyDetail = ClaudeCodeUsageReader.buildDetailBuckets(from: cache.detailDays, tool: .opencode) { date(forDayKey: $0) }
        // OpenCode 没有像 Claude 那样可信的公开价目表：有价（非 0 美元）就说明记录里本来有价，没价就留 nil，
        // 只标一句"记录的金额是不是 $0"，不编一个假的单价
        let pricing = models.map { m in
            PricingEntry(model: m.model, tool: .opencode, input: nil, output: nil, cacheRead: nil,
                         cacheWrite5m: nil, cacheWrite1h: nil,
                         source: m.cost == 0 ? "OpenCode 自带记录（金额 $0）" : "OpenCode 自带记录")
        }

        let blocks = UsageBlocks.summarize(hours: cache.hours, now: now)
        var result = OpenCodeLocalResult(status: .ok, today: today, daily: daily, models: models, history: history,
                                    hourly: hourly, recentRequests: requests, projects: projects,
                                    hourlyDetail: hourlyDetail, dailyDetail: dailyDetail, pricing: pricing,
                                    lastActivity: cache.lastActivity, tokensPerMinute: recent.tokensPerMinute(now: now),
                                    zeroCostProviders: zeroCostProviders)
        result.hasBacklog = pendingBacklog
        result.currentBlock = blocks.current
        result.recentBlocks = blocks.recent
        result.peakBlockTokens = blocks.peak
        return result
    }

    /// message 是当前在用的表；session_message 是尚未启用的新 schema，留个后备查询以防以后切过去。
    /// 两张表都按 rowid 增量查，谁有数据就用谁（跟之前一样，第一张查到行就不查第二张）。
    private func runIncrementalQuery(db: ReadOnlySQLite, cache: inout OpenCodeUsageCache) {
        let now = Date()
        let historyCutoffMs = Int64((now.addingTimeInterval(-365 * 86400)).timeIntervalSince1970 * 1000)
        var lastActivity = cache.lastActivity
        // session 表就几百行，join 一下拿 directory（项目路径），只取最后一级，不存整条路径。
        //
        // length(m.data) <= maxRowDataBytes 放在 SQL 里过滤：这张表里有行用户粘贴的内容是几 MB 到
        // 25MB，不在 SQL 里过滤掉，光是判断 length() 就要先把大 BLOB 翻出来；配合 rowid 游标，
        // 正常 tick（没有新行）这整条查询基本不用碰任何大页。
        let tables = ["message", "session_message"]
        var backlog = false
        defer { pendingBacklog = backlog }
        for table in tables {
            var sawAnyRow = false
            var bytesBudget = 32 * 1024 * 1024
            defer { if bytesBudget <= 0 { backlog = true } } // 一轮最多转换这么多字节的 data 列，参见 Claude 侧同款预算
            let lastRowid = cache.lastRowidByTable[table] ?? 0
            var newRowid = lastRowid

            let sql = "SELECT m.rowid, m.id, m.time_created, m.data, s.directory FROM \(table) m " +
                "LEFT JOIN session s ON s.id = m.session_id " +
                "WHERE m.rowid > ? AND m.time_created >= ? AND length(m.data) <= \(maxRowDataBytes) " +
                "ORDER BY m.rowid ASC"
            db.query(sql, bind: [lastRowid, historyCutoffMs]) { row -> Bool in
                sawAnyRow = true
                guard bytesBudget > 0 else { return false }
                let rowid = row.int64(0)
                newRowid = rowid // rowid 严格递增，不用像以前那样记"同一时间戳有哪些 id"了
                let id = row.text(1) ?? ""
                let timeCreated = row.int64(2)

                let dataBytes = row.byteCount(3)
                guard dataBytes > 0, dataBytes <= maxRowDataBytes else { return true }
                bytesBudget -= dataBytes
                guard let dataStr = row.text(3, maxBytes: maxRowDataBytes), dataStr.contains("\"tokens\""),
                      let data = dataStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["role"] as? String) == "assistant",
                      let tokens = obj["tokens"] as? [String: Any]
                else { return true }

                let modelID = (obj["modelID"] as? String) ?? "unknown"
                let providerID = (obj["providerID"] as? String) ?? "unknown"
                let cost = (obj["cost"] as? NSNumber)?.doubleValue ?? 0
                let input = (tokens["input"] as? NSNumber)?.int64Value ?? 0
                let output = (tokens["output"] as? NSNumber)?.int64Value ?? 0
                let reasoning = (tokens["reasoning"] as? NSNumber)?.int64Value ?? 0
                let cacheDict = tokens["cache"] as? [String: Any]
                let cacheRead = (cacheDict?["read"] as? NSNumber)?.int64Value ?? 0
                let cacheWrite = (cacheDict?["write"] as? NSNumber)?.int64Value ?? 0
                if input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 { return true }

                let timestamp = Date(timeIntervalSince1970: Double(timeCreated) / 1000)
                let dayKey = localDayKey(timestamp)
                let tcThis = TokenCountsCodable(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: reasoning)

                var bucket = cache.days[dayKey] ?? DayBucket()
                bucket.tokensByModel[modelID] = (bucket.tokensByModel[modelID] ?? TokenCountsCodable()) + tcThis
                bucket.costByModel[modelID, default: 0] += cost
                bucket.requestsByModel[modelID, default: 0] += 1
                bucket.requests += 1
                cache.days[dayKey] = bucket

                let project = (row.text(4)).flatMap { dir -> String? in
                    let last = (dir as NSString).lastPathComponent
                    return last.isEmpty ? nil : last
                }

                var hourBucket = cache.hours[localHourKey(timestamp)] ?? HourBucket()
                hourBucket.tokens = hourBucket.tokens + tcThis
                hourBucket.cost += cost
                hourBucket.requests += 1
                cache.hours[localHourKey(timestamp)] = hourBucket

                if let project {
                    var projectsForDay = cache.projectDays[dayKey] ?? [:]
                    var pb = projectsForDay[project] ?? ProjectBucket()
                    pb.tokens = pb.tokens + tcThis
                    pb.cost += cost
                    pb.requests += 1
                    if pb.lastActive == nil || timestamp > pb.lastActive! { pb.lastActive = timestamp }
                    projectsForDay[project] = pb
                    cache.projectDays[dayKey] = projectsForDay
                }

                // 耗时：OpenCode 自己在 time.created / time.completed 记了精确的起止时间，不用估
                var durationMs: Int?
                if let timeDict = obj["time"] as? [String: Any],
                   let completed = (timeDict["completed"] as? NSNumber)?.int64Value,
                   let created = (timeDict["created"] as? NSNumber)?.int64Value, completed > created {
                    durationMs = Int(completed - created)
                }

                ClaudeCodeUsageReader.addDetail(&cache.detailHours, key: localHourKey(timestamp), provider: providerID,
                                                 model: modelID, delta: tcThis, cost: cost, cacheSavings: 0,
                                                 cacheWrite1h: 0, durationMs: durationMs)
                ClaudeCodeUsageReader.addDetail(&cache.detailDays, key: dayKey, provider: providerID,
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
            cache.lastRowidByTable[table] = newRowid
            if sawAnyRow { break } // 这张表有数据就不用再查另一张了
        }
        cache.lastActivity = lastActivity
    }

    private static func emptyResult(_ status: UsageStatus) -> OpenCodeLocalResult {
        OpenCodeLocalResult(status: status, today: DailyUsage(day: Calendar.current.startOfDay(for: Date())),
                             daily: [], models: [], history: [], hourly: [], recentRequests: [], projects: [],
                             hourlyDetail: [], dailyDetail: [], pricing: [],
                             lastActivity: nil, tokensPerMinute: 0, zeroCostProviders: [])
    }

    private func pruneOld(_ cache: inout OpenCodeUsageCache, now: Date) {
        let keep365 = Set(last365DayKeys(now: now))
        for key in cache.days.keys where !keep365.contains(key) {
            cache.days.removeValue(forKey: key)
        }
        let keep30 = Set(last30DayKeys(now: now))
        for key in cache.hours.keys where !keep30.contains(String(key.prefix(10))) {
            cache.hours.removeValue(forKey: key)
        }
        for key in cache.projectDays.keys where !keep30.contains(key) {
            cache.projectDays.removeValue(forKey: key)
        }
        for key in cache.detailHours.keys where !keep30.contains(String(key.prefix(10))) {
            cache.detailHours.removeValue(forKey: key)
        }
        for key in cache.detailDays.keys where !keep365.contains(key) {
            cache.detailDays.removeValue(forKey: key)
        }
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
