import Foundation

// Codex（OpenAI 的 CLI/桌面版）用量：~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl，CLI 和桌面版共用
// 这份目录。也看 $CODEX_HOME（如果设了而且跟 ~/.codex 不是一个目录）和 ~/.codex/archived_sessions。
//
// token_count / rate_limits 的字段按 Codex 的事件格式和 CC Switch（MIT）的解析逻辑实现，
// 并用合成样本做过核对；有的 rollout 一整轮对话都不会出现 token_count 事件，这种文件就没有用量。
//
// 事件结构（从 session_meta/turn_context/event_msg 的真实样本确认，token_count 按给定 schema 实现）：
//   {"timestamp":"...","type":"session_meta","payload":{"id":"...","cwd":"...",...}}
//   {"timestamp":"...","type":"turn_context","payload":{"model":"...","cwd":"...",...}}
//   {"timestamp":"...","type":"event_msg","payload":{"type":"user_message"|"task_started",...}}
//   {"timestamp":"...","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"..."}}}
//   {"timestamp":"...","type":"event_msg","payload":{"type":"token_count",
//       "info":{"total_token_usage":{...},"last_token_usage":{...},"model":"...","model_name":"..."},
//       "rate_limits":{"primary":{...},"secondary":{...}}}}
//
// 去重（参考 CC Switch 的做法）：优先直接拿 last_token_usage 当这一轮的增量；
// 只有它缺的时候才退到"累计 total_token_usage 相对上次高水位的差值"。同一份快照重复出现
// （限速刷新那种心跳式重发）当成重复丢掉。续写的文件（同一个 session_id）继承上一个文件留下的
// 高水位，不从零重新算。
//
// token 映射（OpenAI 的计费口径）：cached_input_tokens 本来就算在 input_tokens 里，所以
// input = input_tokens - cached_input_tokens，cacheRead = cached_input_tokens，
// reasoning_output_tokens 只做展示（可能已经含在 output_tokens 里，没法从这些字段确证，不重复计入 total）。
// OpenAI 没有"缓存写"这个概念（缓存是自动命中折扣，不是像 Anthropic 那样单独计费的写入），cacheWrite 恒 0。

struct TokenSnapshotCodable: Codable, Sendable, Equatable {
    var input: Int64 = 0
    var cachedInput: Int64 = 0
    var output: Int64 = 0
    var reasoningOutput: Int64 = 0
    var total: Int64 = 0
}

struct CodexSessionState: Codable, Sendable {
    /// 累计用量的高水位，给"没有 last_token_usage 时退到算 total_token_usage 差值"这条路用
    var cumulative = TokenSnapshotCodable()
    /// 上一次见到的 last_token_usage 快照，用来判断"这次是不是跟上次一模一样的重复心跳"
    var lastSnapshot: TokenSnapshotCodable?
}

struct RateLimitWindowCodable: Codable, Sendable {
    var usedPercent: Double
    var windowMinutes: Double?
    var resetsAt: Date?
}

struct CodexUsageCache: Codable, Sendable {
    var fileCursors: [String: FileCursor] = [:]
    var days: [String: DayBucket] = [:]
    var hours: [String: HourBucket] = [:]
    var projectDays: [String: [String: ProjectBucket]] = [:]
    var detailHours: [String: [String: [String: DetailBucket]]] = [:]
    var detailDays: [String: [String: [String: DetailBucket]]] = [:]
    var lastTriggerByFile: [String: Double] = [:]
    /// 这个文件里"目前已知"的 model / cwd，跨轮增量续读要接得上（turn_context/thread_settings_applied 更新它们）
    var currentModelByFile: [String: String] = [:]
    var currentCwdByFile: [String: String] = [:]
    /// 文件路径 -> session_id（从 session_meta 读到），续写的文件按 session_id 继承累计高水位
    var sessionIdByFile: [String: String] = [:]
    var sessionState: [String: CodexSessionState] = [:]
    var recentRequests: [UsageRequestCodable] = []
    var lastActivity: Date?
    /// 最新一次 token_count 事件带的额度窗口（本机日志自带的，不联网、不查额度接口）
    var lastRateLimitPrimary: RateLimitWindowCodable?
    var lastRateLimitSecondary: RateLimitWindowCodable?
    /// 已经从 state_5.sqlite 补过账、而且当时磁盘上没有 rollout 的 thread。记下加进去的那一份，文件后来又出现时要整笔扣回。
    var sqliteCredits: [String: CodexSqliteCredit] = [:]
    /// 文件已经不在、但 updated_at 超出历史窗口的 thread。没加过账，只是免得每轮再看一遍。
    var sqliteAppliedThreadIDs: Set<String> = []
    var sqliteSupplementedTokens: Int64 = 0
    var sqliteSupplementedThreads: Int = 0
    var version: Int = CodexUsageCache.currentVersion
    /// 3：sqlite 只补磁盘上已经没有 rollout 的 thread（含 archived_sessions 同名和 .jsonl.zst）；文件再出现就扣回
    static let currentVersion = 3
}

struct CodexSqliteCredit: Codable, Sendable {
    var tokens: Int64
    var model: String
    var project: String?
    var dayKey: String
    var time: Double
    var rolloutPath: String
}

struct CodexLocalResult: Sendable {
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
    var quotas: [QuotaWindow]
    var lastActivity: Date?
    var tokensPerMinute: Double
    var fallbackPricedModels: Set<String>
    var currentBlock: UsageBlock? = nil
    var recentBlocks: [UsageBlock] = []
    var peakBlockTokens: Int64 = 0
}

final class CodexUsageReader {
    private var codexHomes: [URL]
    private let cacheFile: URL
    private var recent = RecentEventWindow()
    private(set) var debugSqliteThreads: Int = 0
    private(set) var debugSqliteTokens: Int64 = 0
    static let provider = "OpenAI"

    /// homes 是各个 CODEX_HOME。cacheToken 是账号 id 的短哈希。
    /// migrateLegacy：默认账号第一次改用新文件名时，把旧的 codex-usage-cache.json 拷过来。
    init(homes: [URL], cacheToken: String, migrateLegacy: Bool) {
        self.codexHomes = homes
        self.cacheFile = UsageCacheLocation.url("codex-usage-\(cacheToken).json")
        if migrateLegacy {
            UsageCacheLocation.copyLegacy(named: "codex-usage-cache.json", to: cacheFile)
        }
    }

    func retarget(homes: [URL]) { self.codexHomes = homes }

    private static let minPlausibleDurationMs = 300
    private static let maxPlausibleDurationMs = 15 * 60 * 1000

    // MARK: 本机日志

    func scan() -> CodexLocalResult {
        let fm = FileManager.default
        guard codexHomes.contains(where: { fm.fileExists(atPath: $0.path) }) else {
            return Self.emptyResult(.notInstalled)
        }

        var cache = loadCache()
        let now = Date()
        let historyCutoff = now.addingTimeInterval(-365 * 86400)
        var fallbackModels: Set<String> = []
        var lastActivity: Date? = cache.lastActivity
        var bytesBudget = 64 * 1024 * 1024
        var hitBudgetCap = false

        let files = Array(Set(codexHomes.flatMap { Self.enumerateRolloutFiles(under: $0) })).sorted()
        for path in files {
            guard bytesBudget > 0 else { hitBudgetCap = true; break }
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= historyCutoff,
                  let size = attrs[.size] as? Int, let inode = attrs[.systemFileNumber] as? Int
            else { continue }

            let prior = cache.fileCursors[path]
            if let prior, prior.inode == UInt64(inode), prior.size == Int64(size),
               prior.mtime == mtime.timeIntervalSince1970, prior.offset == prior.size {
                continue
            }

            var startOffset: Int64 = 0
            if let prior, prior.inode == UInt64(inode), prior.size <= Int64(size) {
                startOffset = prior.offset
            }

            var fileTrigger: Date? = cache.lastTriggerByFile[path].map { Date(timeIntervalSince1970: $0) }
            var currentModel: String? = cache.currentModelByFile[path]
            var currentCwd: String? = cache.currentCwdByFile[path]
            var sessionId: String? = cache.sessionIdByFile[path]

            guard let newOffset = IncrementalLineReader.readNewLines(at: path, from: startOffset, maxBytes: bytesBudget, onLine: { buf in
                if CodexLinePrefilter.isTokenCount(buf) {
                    let line = String(decoding: buf, as: UTF8.self)
                    guard let obj = Self.decodeJSON(line),
                          let timestampStr = obj["timestamp"] as? String,
                          let timestamp = ISO8601.parse(timestampStr),
                          let payload = obj["payload"] as? [String: Any],
                          let info = payload["info"] as? [String: Any]
                    else { return }
                    if timestamp < historyCutoff { return }

                    let sid = sessionId ?? "unknown"
                    var state = cache.sessionState[sid] ?? CodexSessionState()
                    guard let delta = Self.resolveDelta(info: info, state: &state) else {
                        cache.sessionState[sid] = state
                        return
                    }
                    cache.sessionState[sid] = state

                    if let rateLimits = payload["rate_limits"] as? [String: Any] {
                        if let p = rateLimits["primary"] as? [String: Any], let w = Self.parseRateLimitWindow(p, eventTimestamp: timestamp) {
                            cache.lastRateLimitPrimary = w
                        }
                        if let s = rateLimits["secondary"] as? [String: Any], let w = Self.parseRateLimitWindow(s, eventTimestamp: timestamp) {
                            cache.lastRateLimitSecondary = w
                        }
                    }

                    let infoModel = (info["model"] as? String) ?? (info["model_name"] as? String) ?? (payload["model"] as? String)
                    let model = currentModel ?? infoModel.map(Self.normalizeModel) ?? "unknown"

                    // OpenAI 的 cached_input_tokens 本来就算在 input_tokens 里，要减掉才是真正新读的 input
                    let input = max(0, delta.input - delta.cachedInput)
                    let cacheRead = delta.cachedInput
                    let output = delta.output
                    if input == 0 && output == 0 && cacheRead == 0 { return }

                    let (cost, cacheSavings, isFallback) = CodexCost.compute(model: model, input: input, output: output, cacheRead: cacheRead)
                    if isFallback { fallbackModels.insert(model) }

                    let tc = TokenCountsCodable(input: input, output: output, cacheRead: cacheRead, cacheWrite: 0, reasoning: delta.reasoningOutput)
                    let dayKey = localDayKey(timestamp)

                    var bucket = cache.days[dayKey] ?? DayBucket()
                    bucket.tokensByModel[model] = (bucket.tokensByModel[model] ?? TokenCountsCodable()) + tc
                    bucket.costByModel[model, default: 0] += cost
                    bucket.requestsByModel[model, default: 0] += 1
                    bucket.requests += 1
                    bucket.cacheSavings += cacheSavings
                    cache.days[dayKey] = bucket

                    let project = currentCwd.flatMap { cwd -> String? in
                        let last = (cwd as NSString).lastPathComponent
                        return last.isEmpty ? nil : last
                    }

                    var hourBucket = cache.hours[localHourKey(timestamp)] ?? HourBucket()
                    hourBucket.tokens = hourBucket.tokens + tc
                    hourBucket.cost += cost
                    hourBucket.requests += 1
                    cache.hours[localHourKey(timestamp)] = hourBucket

                    if let project {
                        var projectsForDay = cache.projectDays[dayKey] ?? [:]
                        var pb = projectsForDay[project] ?? ProjectBucket()
                        pb.tokens = pb.tokens + tc
                        pb.cost += cost
                        pb.requests += 1
                        if pb.lastActive == nil || timestamp > pb.lastActive! { pb.lastActive = timestamp }
                        projectsForDay[project] = pb
                        cache.projectDays[dayKey] = projectsForDay
                    }

                    var durationMs: Int?
                    if let trig = fileTrigger {
                        let gapMs = Int(timestamp.timeIntervalSince(trig) * 1000)
                        if gapMs >= Self.minPlausibleDurationMs && gapMs <= Self.maxPlausibleDurationMs {
                            durationMs = gapMs
                        }
                    }

                    ClaudeCodeUsageReader.addDetail(&cache.detailHours, key: localHourKey(timestamp), provider: Self.provider,
                                                     model: model, delta: tc, cost: cost, cacheSavings: cacheSavings,
                                                     cacheWrite1h: 0, durationMs: durationMs)
                    ClaudeCodeUsageReader.addDetail(&cache.detailDays, key: dayKey, provider: Self.provider,
                                                     model: model, delta: tc, cost: cost, cacheSavings: cacheSavings,
                                                     cacheWrite1h: 0, durationMs: durationMs)

                    let requestEntry = UsageRequestCodable(id: "\(sid)#\(timestamp.timeIntervalSince1970)", time: timestamp,
                                                            tool: AITool.codex.rawValue, model: model, project: project, sessionID: sid,
                                                            tokens: tc, cacheWrite1h: 0, cost: cost,
                                                            provider: Self.provider, durationMs: durationMs, durationIsEstimate: true)
                    RequestRing.push(requestEntry, into: &cache.recentRequests)

                    recent.add(timestamp, input + output)
                    if lastActivity == nil || timestamp > lastActivity! { lastActivity = timestamp }
                    return
                }

                if CodexLinePrefilter.isSessionMeta(buf) {
                    let line = String(decoding: buf, as: UTF8.self)
                    guard let obj = Self.decodeJSON(line), let payload = obj["payload"] as? [String: Any] else { return }
                    if let id = payload["id"] as? String ?? payload["session_id"] as? String { sessionId = id }
                    if let cwd = payload["cwd"] as? String, !cwd.isEmpty { currentCwd = cwd }
                    return
                }
                if CodexLinePrefilter.isTurnContext(buf) {
                    let line = String(decoding: buf, as: UTF8.self)
                    guard let obj = Self.decodeJSON(line), let payload = obj["payload"] as? [String: Any] else { return }
                    if let model = payload["model"] as? String, !model.isEmpty { currentModel = Self.normalizeModel(model) }
                    if let cwd = payload["cwd"] as? String, !cwd.isEmpty { currentCwd = cwd }
                    return
                }
                if CodexLinePrefilter.isThreadSettingsApplied(buf) {
                    let line = String(decoding: buf, as: UTF8.self)
                    guard let obj = Self.decodeJSON(line), let payload = obj["payload"] as? [String: Any],
                          let settings = payload["thread_settings"] as? [String: Any], let model = settings["model"] as? String, !model.isEmpty
                    else { return }
                    currentModel = Self.normalizeModel(model)
                    return
                }
                if CodexLinePrefilter.isTriggerCandidate(buf) {
                    if let ts = LineBytePrefilter.extractTimestamp(buf) { fileTrigger = ts }
                    return
                }
            }) else { continue }

            cache.lastTriggerByFile[path] = fileTrigger?.timeIntervalSince1970
            if let currentModel { cache.currentModelByFile[path] = currentModel }
            if let currentCwd { cache.currentCwdByFile[path] = currentCwd }
            if let sessionId { cache.sessionIdByFile[path] = sessionId }
            bytesBudget -= Int(newOffset - startOffset)
            if newOffset < Int64(size) { hitBudgetCap = true }
            cache.fileCursors[path] = FileCursor(inode: UInt64(inode), size: Int64(size), offset: newOffset,
                                                  mtime: mtime.timeIntervalSince1970)
        }

        cache.lastActivity = lastActivity
        // 只补磁盘上已经没有 rollout 的 thread。文件还在的一律等 jsonl 里的 token_count，
        // 免得进行中的会话先被 sqlite 记上一笔、稍后 jsonl 再记一笔。补上的只有总数，不进小时桶，所以不进 5 小时窗口。
        backfillSQLite(&cache, historyCutoff: historyCutoff)
        pruneOld(&cache, now: now)
        saveCache(cache)
        debugSqliteThreads = cache.sqliteSupplementedThreads
        debugSqliteTokens = cache.sqliteSupplementedTokens

        for bucket in cache.days.values {
            for model in bucket.tokensByModel.keys where CodexPricingTable.rate(for: model).isFallback {
                fallbackModels.insert(model)
            }
        }

        let (today, daily, models) = ClaudeCodeUsageReader.buildWindows(from: cache.days, now: now)
        let history = ClaudeCodeUsageReader.buildHistory(from: cache.days, now: now)
        let hourly = ClaudeCodeUsageReader.buildHourly(from: cache.hours, now: now)
        let projects = ClaudeCodeUsageReader.buildProjects(from: cache.projectDays, tool: .codex, now: now)
        let requests = cache.recentRequests.compactMap { $0.toContract() }
        let hourlyDetail = ClaudeCodeUsageReader.buildDetailBuckets(from: cache.detailHours, tool: .codex) { date(forHourKey: $0) }
        let dailyDetail = ClaudeCodeUsageReader.buildDetailBuckets(from: cache.detailDays, tool: .codex) { date(forDayKey: $0) }
        var unsplitModels: Set<String> = []
        for bucket in cache.days.values {
            for (model, tc) in bucket.tokensByModel where tc.unsplit > 0 { unsplitModels.insert(model) }
        }
        var pricing = models.map { Self.pricingEntry(for: $0.model, unsplit: unsplitModels.contains($0.model)) }
        let listed = Set(models.map(\.model))
        for model in unsplitModels.subtracting(listed).sorted() {
            pricing.append(Self.pricingEntry(for: model, unsplit: true))
        }
        let quotas = Self.buildQuotas(primary: cache.lastRateLimitPrimary, secondary: cache.lastRateLimitSecondary)
        let blocks = UsageBlocks.summarize(hours: cache.hours, now: now)

        var result = CodexLocalResult(status: .ok, today: today, daily: daily, models: models, history: history,
                                       hourly: hourly, recentRequests: requests, projects: projects,
                                       hourlyDetail: hourlyDetail, dailyDetail: dailyDetail, pricing: pricing, quotas: quotas,
                                       lastActivity: lastActivity, tokensPerMinute: recent.tokensPerMinute(now: now),
                                       fallbackPricedModels: fallbackModels)
        result.hasBacklog = hitBudgetCap
        result.currentBlock = blocks.current
        result.recentBlocks = blocks.recent
        result.peakBlockTokens = blocks.peak
        return result
    }

    private static func emptyResult(_ status: UsageStatus) -> CodexLocalResult {
        CodexLocalResult(status: status, today: DailyUsage(day: Calendar.current.startOfDay(for: Date())),
                          daily: [], models: [], history: [], hourly: [], recentRequests: [], projects: [],
                          hourlyDetail: [], dailyDetail: [], pricing: [], quotas: [],
                          lastActivity: nil, tokensPerMinute: 0, fallbackPricedModels: [])
    }

    static func pricingEntry(for model: String, unsplit: Bool = false) -> PricingEntry {
        let (rate, _, _) = CodexPricingTable.rateWithSource(for: model)
        var source = CodexPricingTable.source(for: model)
        if unsplit { source += "；sqlite 补的历史只有总数，金额记 0" }
        return PricingEntry(model: model, tool: .codex, input: rate.input * 1_000_000, output: rate.output * 1_000_000,
                             cacheRead: rate.cacheRead * 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, source: source)
    }

    /// `~/.codex/state_5.sqlite` 的 threads.tokens_used。只读。
    /// 只补 rollout 文件已经不在磁盘上的 thread（原路径、archived_sessions 下同名、以及 .jsonl.zst 都算还在）。
    /// 文件还在的一律只走 jsonl。先前补过、文件后来又出现的，先把 sqlite 那笔扣掉。
    private func backfillSQLite(_ cache: inout CodexUsageCache, historyCutoff: Date) {
        let fm = FileManager.default
        var presence = RolloutPresence()
        for home in codexHomes {
            let part = Self.rolloutPresence(under: home)
            presence.paths.formUnion(part.paths)
            presence.names.formUnion(part.names)
        }
        var broughtBack: [String] = []
        for (id, credit) in cache.sqliteCredits where Self.rolloutOnDisk(credit.rolloutPath, presence: presence, fm: fm) {
            Self.retractSqlite(credit, cache: &cache)
            broughtBack.append(id)
        }
        for id in broughtBack { cache.sqliteCredits.removeValue(forKey: id) }
        for home in codexHomes {
        let dbPath = home.appendingPathComponent("state_5.sqlite").path
        guard FileManager.default.fileExists(atPath: dbPath), let db = ReadOnlySQLite(path: dbPath) else { continue }
        db.query("""
            SELECT id, tokens_used, model, cwd, rollout_path, updated_at, updated_at_ms
            FROM threads WHERE tokens_used > 0
            """) { row in
            let id = row.text(0) ?? ""
            let tokens = row.int64(1)
            guard !id.isEmpty, tokens > 0, cache.sqliteCredits[id] == nil,
                  !cache.sqliteAppliedThreadIDs.contains(id) else { return true }
            let rollout = row.text(4) ?? ""
            if Self.rolloutOnDisk(rollout, presence: presence, fm: fm) { return true }
            guard let when = Self.codexStamp(seconds: row.int64(5), millis: row.int64(6)), when >= historyCutoff else {
                cache.sqliteAppliedThreadIDs.insert(id)
                return true
            }
            let rawModel = row.text(2) ?? ""
            let model = rawModel.isEmpty ? "unknown" : Self.normalizeModel(rawModel)
            let cwd = row.text(3) ?? ""
            let project: String? = {
                let last = (cwd as NSString).lastPathComponent
                return last.isEmpty || last == "/" ? nil : last
            }()
            let dayKey = localDayKey(when)
            let tc = TokenCountsCodable(unsplit: tokens)
            var bucket = cache.days[dayKey] ?? DayBucket()
            bucket.tokensByModel[model] = (bucket.tokensByModel[model] ?? TokenCountsCodable()) + tc
            bucket.requestsByModel[model, default: 0] += 1
            bucket.requests += 1
            cache.days[dayKey] = bucket
            if let project {
                var projectsForDay = cache.projectDays[dayKey] ?? [:]
                var pb = projectsForDay[project] ?? ProjectBucket()
                pb.tokens = pb.tokens + tc
                pb.requests += 1
                if pb.lastActive == nil || when > pb.lastActive! { pb.lastActive = when }
                projectsForDay[project] = pb
                cache.projectDays[dayKey] = projectsForDay
            }
            ClaudeCodeUsageReader.addDetail(&cache.detailDays, key: dayKey, provider: Self.provider,
                                             model: model, delta: tc, cost: 0, cacheSavings: 0,
                                             cacheWrite1h: 0, durationMs: nil)
            if cache.lastActivity == nil || when > cache.lastActivity! { cache.lastActivity = when }
            cache.sqliteCredits[id] = CodexSqliteCredit(
                tokens: tokens, model: model, project: project, dayKey: dayKey,
                time: when.timeIntervalSince1970, rolloutPath: rollout)
            cache.sqliteSupplementedTokens += tokens
            cache.sqliteSupplementedThreads += 1
            return true
        }
        }
    }

    /// 原路径、`.jsonl.zst`、以及 sessions/archived_sessions 里的同名文件，有一个在就算 rollout 还在。
    private struct RolloutPresence {
        var paths: Set<String> = []
        var names: Set<String> = []
    }

    private static func rolloutPresence(under codexHome: URL) -> RolloutPresence {
        var presence = RolloutPresence()
        let fm = FileManager.default
        for sub in ["sessions", "archived_sessions"] {
            let dir = codexHome.appendingPathComponent(sub)
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                let ext = url.pathExtension.lowercased()
                guard ext == "jsonl" || ext == "zst" else { continue }
                presence.paths.insert(url.standardizedFileURL.path)
                presence.names.insert(url.lastPathComponent)
                if ext == "zst" { presence.names.insert(url.deletingPathExtension().lastPathComponent) }
            }
        }
        return presence
    }

    private static func rolloutOnDisk(_ rollout: String, presence: RolloutPresence, fm: FileManager) -> Bool {
        guard !rollout.isEmpty else { return false }
        let path = URL(fileURLWithPath: rollout).standardizedFileURL.path
        if presence.paths.contains(path) || fm.fileExists(atPath: path) { return true }
        let zst = path.hasSuffix(".zst") ? path : path + ".zst"
        if presence.paths.contains(zst) || fm.fileExists(atPath: zst) { return true }
        if path.contains("/sessions/") {
            let archived = path.replacingOccurrences(of: "/sessions/", with: "/archived_sessions/")
            if presence.paths.contains(archived) || presence.paths.contains(archived + ".zst")
                || fm.fileExists(atPath: archived) || fm.fileExists(atPath: archived + ".zst") {
                return true
            }
        }
        let name = (path as NSString).lastPathComponent
        if presence.names.contains(name) || presence.names.contains(name + ".zst") { return true }
        return false
    }

    /// 把先前按 sqlite 总数记上的那一笔从天账、项目、按天明细里减掉。小时桶没记过，不用动。
    private static func retractSqlite(_ credit: CodexSqliteCredit, cache: inout CodexUsageCache) {
        let tc = TokenCountsCodable(unsplit: credit.tokens)
        if var bucket = cache.days[credit.dayKey] {
            if let current = bucket.tokensByModel[credit.model] {
                let next = current - tc
                if next.total == 0 { bucket.tokensByModel.removeValue(forKey: credit.model) }
                else { bucket.tokensByModel[credit.model] = next }
            }
            let reqs = (bucket.requestsByModel[credit.model] ?? 0) - 1
            if reqs <= 0 { bucket.requestsByModel.removeValue(forKey: credit.model) }
            else { bucket.requestsByModel[credit.model] = reqs }
            bucket.requests -= 1
            if bucket.requests <= 0 && bucket.tokensByModel.isEmpty {
                cache.days.removeValue(forKey: credit.dayKey)
            } else {
                cache.days[credit.dayKey] = bucket
            }
        }
        if let project = credit.project, var projects = cache.projectDays[credit.dayKey], var pb = projects[project] {
            pb.tokens = pb.tokens - tc
            pb.requests -= 1
            if pb.requests <= 0 && pb.tokens.total == 0 {
                projects.removeValue(forKey: project)
            } else {
                projects[project] = pb
            }
            if projects.isEmpty { cache.projectDays.removeValue(forKey: credit.dayKey) }
            else { cache.projectDays[credit.dayKey] = projects }
        }
        ClaudeCodeUsageReader.subtractDetail(&cache.detailDays, key: credit.dayKey, provider: provider,
                                               model: credit.model, delta: tc, cost: 0, cacheSavings: 0,
                                               cacheWrite1h: 0, durationMs: nil)
        cache.sqliteSupplementedTokens -= credit.tokens
        cache.sqliteSupplementedThreads -= 1
        if cache.sqliteSupplementedTokens < 0 { cache.sqliteSupplementedTokens = 0 }
        if cache.sqliteSupplementedThreads < 0 { cache.sqliteSupplementedThreads = 0 }
    }

    private static func codexStamp(seconds: Int64, millis: Int64) -> Date? {
        var sec = seconds
        if sec > 10_000_000_000 { sec /= 1000 }
        if sec <= 0 {
            if millis <= 0 { return nil }
            sec = millis > 10_000_000_000 ? millis / 1000 : millis
        }
        return Date(timeIntervalSince1970: TimeInterval(sec))
    }

    /// 算这条 token_count 事件的增量：优先 last_token_usage；没有就退到跟累计高水位的差值；
    /// 跟上次一模一样的快照（限速刷新心跳）当重复，返回 nil
    private static func resolveDelta(info: [String: Any], state: inout CodexSessionState) -> TokenSnapshotCodable? {
        if let last = info["last_token_usage"] as? [String: Any] {
            let snap = parseSnapshot(last)
            if state.lastSnapshot == snap { return nil } // 一模一样的重复快照
            state.lastSnapshot = snap
            state.cumulative = TokenSnapshotCodable(
                input: state.cumulative.input + snap.input, cachedInput: state.cumulative.cachedInput + snap.cachedInput,
                output: state.cumulative.output + snap.output, reasoningOutput: state.cumulative.reasoningOutput + snap.reasoningOutput,
                total: state.cumulative.total + snap.total)
            return snap
        }
        if let totalDict = info["total_token_usage"] as? [String: Any] {
            let totalSnap = parseSnapshot(totalDict)
            let prev = state.cumulative
            let delta = TokenSnapshotCodable(
                input: max(0, totalSnap.input - prev.input), cachedInput: max(0, totalSnap.cachedInput - prev.cachedInput),
                output: max(0, totalSnap.output - prev.output), reasoningOutput: max(0, totalSnap.reasoningOutput - prev.reasoningOutput),
                total: max(0, totalSnap.total - prev.total))
            state.cumulative = totalSnap
            if delta.input == 0 && delta.output == 0 && delta.cachedInput == 0 && delta.total == 0 { return nil }
            return delta
        }
        return nil
    }

    private static func parseSnapshot(_ dict: [String: Any]) -> TokenSnapshotCodable {
        let input = (dict["input_tokens"] as? NSNumber)?.int64Value ?? 0
        let cached = (dict["cached_input_tokens"] as? NSNumber)?.int64Value
            ?? (dict["cache_read_input_tokens"] as? NSNumber)?.int64Value ?? 0
        let output = (dict["output_tokens"] as? NSNumber)?.int64Value ?? 0
        let reasoning = (dict["reasoning_output_tokens"] as? NSNumber)?.int64Value ?? 0
        let total = (dict["total_tokens"] as? NSNumber)?.int64Value ?? (input + output)
        return TokenSnapshotCodable(input: input, cachedInput: cached, output: output, reasoningOutput: reasoning, total: total)
    }

    /// 小写 + 去掉供应商前缀（例如 "openai/gpt-5.6" -> "gpt-5.6"）；日期后缀留给算价格那一步去剥
    private static func normalizeModel(_ raw: String) -> String {
        let lower = raw.lowercased()
        if let slash = lower.lastIndex(of: "/") { return String(lower[lower.index(after: slash)...]) }
        return lower
    }

    private static func parseRateLimitWindow(_ dict: [String: Any], eventTimestamp: Date) -> RateLimitWindowCodable? {
        guard let usedPercent = (dict["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let windowMinutes = (dict["window_minutes"] as? NSNumber)?.doubleValue
        var resetsAt: Date?
        if let resetsAtStr = dict["resets_at"] as? String {
            resetsAt = ISO8601.parse(resetsAtStr)
        } else if let resetsIn = (dict["resets_in_seconds"] as? NSNumber)?.doubleValue {
            resetsAt = eventTimestamp.addingTimeInterval(resetsIn)
        }
        return RateLimitWindowCodable(usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resetsAt)
    }

    /// 没联网、没查任何额度接口——这俩窗口完全是从本机日志最新一条 token_count 事件自己带的 rate_limits 读出来的。
    /// 日志里没有 token_count 事件时 quotas 就是空的；
    /// 有的话就按给的窗口分钟数自己拼标题，拼不出来就按 primary/secondary 的常见含义给个默认标题。
    private static func buildQuotas(primary: RateLimitWindowCodable?, secondary: RateLimitWindowCodable?) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        if let p = primary {
            windows.append(QuotaWindow(id: "five_hour", title: windowTitle(p.windowMinutes) ?? "5 小时",
                                        usedFraction: p.usedPercent / 100, resetsAt: p.resetsAt, detail: nil))
        }
        if let s = secondary {
            windows.append(QuotaWindow(id: "seven_day", title: windowTitle(s.windowMinutes) ?? "本周",
                                        usedFraction: s.usedPercent / 100, resetsAt: s.resetsAt, detail: nil))
        }
        return windows
    }

    private static func windowTitle(_ minutes: Double?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes < 24 * 60 { return "\(Int((minutes / 60).rounded())) 小时" }
        return "\(Int((minutes / 1440).rounded())) 天"
    }

    private static func decodeJSON(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// `~/.codex/sessions/**/rollout-*.jsonl` + `~/.codex/archived_sessions/**/*.jsonl`
    /// （CODEX_HOME 不同于 ~/.codex 时，codexHome 已经指过去了，这里只要在 codexHome 下找就对）
    private static func enumerateRolloutFiles(under codexHome: URL) -> [String] {
        var result: [String] = []
        let fm = FileManager.default
        for sub in ["sessions", "archived_sessions"] {
            let dir = codexHome.appendingPathComponent(sub)
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for item in en {
                guard let url = item as? URL, url.pathExtension == "jsonl" else { continue }
                result.append(url.standardizedFileURL.path)
            }
        }
        return result
    }

    private func pruneOld(_ cache: inout CodexUsageCache, now: Date) {
        let keep365 = Set(last365DayKeys(now: now))
        for key in cache.days.keys where !keep365.contains(key) { cache.days.removeValue(forKey: key) }
        for key in cache.detailDays.keys where !keep365.contains(key) { cache.detailDays.removeValue(forKey: key) }

        let keep30 = Set(last30DayKeys(now: now))
        for key in cache.hours.keys where !keep30.contains(String(key.prefix(10))) { cache.hours.removeValue(forKey: key) }
        for key in cache.projectDays.keys where !keep30.contains(key) { cache.projectDays.removeValue(forKey: key) }
        for key in cache.detailHours.keys where !keep30.contains(String(key.prefix(10))) { cache.detailHours.removeValue(forKey: key) }

        let fm = FileManager.default
        for key in cache.fileCursors.keys where !fm.fileExists(atPath: key) {
            cache.fileCursors.removeValue(forKey: key)
            cache.lastTriggerByFile.removeValue(forKey: key)
            cache.currentModelByFile.removeValue(forKey: key)
            cache.currentCwdByFile.removeValue(forKey: key)
            cache.sessionIdByFile.removeValue(forKey: key)
        }
    }

    private func loadCache() -> CodexUsageCache {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode(CodexUsageCache.self, from: data),
              cache.version == CodexUsageCache.currentVersion
        else { return CodexUsageCache() }
        return cache
    }

    private func saveCache(_ cache: CodexUsageCache) {
        UsageCacheLocation.ensureDir()
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}

/// Codex rollout 行按 type 分派要用的便宜字节模式，跟 LineBytePrefilter 同一个底子（memmem，不转 String）
enum CodexLinePrefilter {
    private static let tokenCount = Array("\"type\":\"token_count\"".utf8)
    private static let sessionMeta = Array("\"type\":\"session_meta\"".utf8)
    private static let turnContext = Array("\"type\":\"turn_context\"".utf8)
    private static let threadSettingsApplied = Array("\"type\":\"thread_settings_applied\"".utf8)
    private static let userMessage = Array("\"type\":\"user_message\"".utf8)
    private static let taskStarted = Array("\"type\":\"task_started\"".utf8)

    static func isTokenCount(_ buf: UnsafeRawBufferPointer) -> Bool { LineBytePrefilter.matches(buf, tokenCount) }
    static func isSessionMeta(_ buf: UnsafeRawBufferPointer) -> Bool { LineBytePrefilter.matches(buf, sessionMeta) }
    static func isTurnContext(_ buf: UnsafeRawBufferPointer) -> Bool { LineBytePrefilter.matches(buf, turnContext) }
    static func isThreadSettingsApplied(_ buf: UnsafeRawBufferPointer) -> Bool { LineBytePrefilter.matches(buf, threadSettingsApplied) }
    /// "触发这次请求"的候选行：新一轮用户消息，或者一轮任务开始
    static func isTriggerCandidate(_ buf: UnsafeRawBufferPointer) -> Bool {
        LineBytePrefilter.matches(buf, userMessage) || LineBytePrefilter.matches(buf, taskStarted)
    }
}
