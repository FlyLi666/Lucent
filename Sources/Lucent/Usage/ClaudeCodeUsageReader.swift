import Foundation

// Claude Code 用量：本机 ~/.claude/projects/**/*.jsonl 增量解析。只读本机日志，不读任何
// Claude 登录凭据、不查额度接口（第三方收集会话令牌违反 Anthropic 条款）。
// 所以这里没有额度（quotas 始终是空的，plan 始终是 nil），status 只看本机日志读得好不好。

struct ClaudeUsageCache: Codable, Sendable {
    var fileCursors: [String: FileCursor] = [:]
    /// 现在兼两个用途：近 30 天的 daily/models 窗口，以及最长 365 天的历史（history）。
    /// 过了 30 天只留天总量（去重集合已清空），过了 365 天才真正删掉——这样 Claude Code 自己清理掉
    /// 旧 jsonl（默认 30 天）之后，这里的汇总数字依然在。
    var days: [String: DayBucket] = [:]
    /// 近 30 天每小时的聚合，只存有数据的小时
    var hours: [String: HourBucket] = [:]
    /// 近 30 天每天每个项目的聚合：dayKey -> project -> 聚合
    var projectDays: [String: [String: ProjectBucket]] = [:]
    /// 近 30 天逐小时 × 供应商 × 模型：hourKey -> provider -> model -> 聚合（Claude 的 provider 恒是 "Anthropic"）
    var detailHours: [String: [String: [String: DetailBucket]]] = [:]
    /// 全部历史（最多 365 天）逐日 × 供应商 × 模型，跟 days 一样"过了 30 天只留总量"不适用——这个本来就是总量粒度
    var detailDays: [String: [String: [String: DetailBucket]]] = [:]
    /// 每个文件里"最近一条非 assistant 行"的时间（用来估算下一条 assistant 行的请求耗时），
    /// 按文件路径存，增量读、跨进程重启都要能接得上
    var lastTriggerByFile: [String: Double] = [:]
    /// 最新在前，最多 1000 条
    var recentRequests: [UsageRequestCodable] = []
    /// 最近一条 assistant 消息的时间，跨进程重启、跨"这轮没有新行"的空转都要保留，不能只在当次扫描里算
    var lastActivity: Date?
    /// 去重前的 output，按天累加（同一条流式补全的每一次出现都算）。只给调试对照用
    var rawOutputByDay: [String: Int64] = [:]
    /// 没有 message.id / requestId 的用量行，没法替换，单独记下来给 5 小时窗口用
    var looseEvents: [ClaudeLooseEvent] = []
    var version: Int = ClaudeUsageCache.currentVersion
    /// 统计口径变了就加一，旧缓存直接丢弃重算
    /// （4：速度只计输出 ≥50 token；5：请求列表按时间留最新；6：同一 id 留最后一条，sidechain 回放丢掉）
    static let currentVersion = 6
}

struct ClaudeLooseEvent: Codable, Sendable {
    var time: Double
    var input: Int64
    var output: Int64
    var cacheRead: Int64
    var cacheWrite: Int64
    var cost: Double
}

struct ClaudeLocalResult: Sendable {
    /// 这轮因为限量没读完，还有积压：调度方应尽快再跑一轮
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
    var fallbackPricedModels: Set<String>
    var currentBlock: UsageBlock? = nil
    var recentBlocks: [UsageBlock] = []
    var peakBlockTokens: Int64 = 0
}

final class ClaudeCodeUsageReader {
    private var projectDirs: [URL]
    private let cacheFile: URL
    private let priorFile: URL
    private var recent = RecentEventWindow()
    private(set) var debugOutputBefore30: Int64 = 0
    private(set) var debugOutputAfter30: Int64 = 0
    static let provider = "Anthropic"

    /// projectDirs 是各个配置目录下的 `projects`。cacheToken 是账号 id 的短哈希。
    /// migrateLegacy：默认账号第一次改用新文件名时，把旧的 claude-usage-cache.json / claude-priors.bin 拷过来。
    init(projectDirs: [URL], cacheToken: String, migrateLegacy: Bool) {
        self.projectDirs = projectDirs
        self.cacheFile = UsageCacheLocation.url("claude-usage-\(cacheToken).json")
        self.priorFile = UsageCacheLocation.url("claude-priors-\(cacheToken).bin")
        if migrateLegacy {
            UsageCacheLocation.copyLegacy(named: "claude-usage-cache.json", to: cacheFile)
            UsageCacheLocation.copyLegacy(named: "claude-priors.bin", to: priorFile)
        }
    }

    func retarget(projectDirs: [URL]) { self.projectDirs = projectDirs }

    /// 请求耗时估算的合理范围：太短像是重复行/误判，太长大概率跨了好几轮对话
    private static let minPlausibleDurationMs = 300
    private static let maxPlausibleDurationMs = 15 * 60 * 1000

    // MARK: 本机日志

    /// 增量扫描一次：第一次调用（或缓存不存在）就是"冷扫描"，之后调用只读新追加的字节。
    /// 文件级别按 365 天过滤（给历史用），30 天的 daily/models/hourly/projects 窗口在 buildWindows 里再收窄。
    func scan() -> ClaudeLocalResult {
        let fm = FileManager.default
        guard projectDirs.contains(where: { fm.fileExists(atPath: $0.path) }) else {
            return Self.emptyResult(.notInstalled)
        }

        UsageCacheLocation.ensureDir()
        var cache = loadCache()
        // 侧车丢了或坏了、但 JSON 里已经有游标/聚合：不能接着增量，减不掉旧账。整份重扫。
        let priors: ClaudePriorStore
        if let loaded = ClaudePriorStore.load(from: priorFile) {
            priors = loaded
        } else if cache.days.isEmpty && cache.fileCursors.isEmpty {
            priors = ClaudePriorStore()
        } else {
            cache = ClaudeUsageCache()
            try? FileManager.default.removeItem(at: priorFile)
            priors = ClaudePriorStore()
        }
        let now = Date()
        let historyCutoff = now.addingTimeInterval(-365 * 86400)
        var fallbackModels: Set<String> = []
        var lastActivity: Date? = cache.lastActivity
        // 一轮最多读这么多新字节：冷扫描或一次性几十 MB 的追加会被摊到好几轮 15 秒 tick 里，
        // 不会把 CPU 焊死在一次调用上（2026-10-16 生产事故：107% CPU 几秒、峰值内存 1.6GB）
        var bytesBudget = 64 * 1024 * 1024

        var hitBudgetCap = false // 这轮有没有哪个文件没读完——没读完就不敢清旧天的去重集合（见下面 pruneOld 前的说明）

        let files = enumerateJSONLFiles().sorted { $0.path < $1.path } // 固定顺序，预算不够时下一轮按顺序接着来
        for (path, encodedProjectDir) in files {
            guard bytesBudget > 0 else { hitBudgetCap = true; break }
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= historyCutoff,
                  let size = attrs[.size] as? Int, let inode = attrs[.systemFileNumber] as? Int
            else { continue }

            let prior = cache.fileCursors[path]
            // 大小、mtime、inode 跟上次记的一模一样，而且上次已经读到文件末尾：这个文件自上次扫描后
            // 根本没变过，连 FileHandle 都不用开——装机版反馈过"每 15 秒 tick 把 270 个文件都摸一遍"
            if let prior, prior.inode == UInt64(inode), prior.size == Int64(size),
               prior.mtime == mtime.timeIntervalSince1970, prior.offset == prior.size {
                continue
            }

            var startOffset: Int64 = 0
            if let prior, prior.inode == UInt64(inode), prior.size <= Int64(size) {
                startOffset = prior.offset
            } // 否则文件被截断/轮转/第一次见到：从头读

            // "触发这次请求的那条非 assistant 行"的时间，按文件存、跨轮持续——一个文件里
            // user/tool_result 行在前，assistant 回复在后，耗时 ≈ assistant 行时间 - 这个时间
            var fileTrigger: Date? = cache.lastTriggerByFile[path].map { Date(timeIntervalSince1970: $0) }

            guard let newOffset = IncrementalLineReader.readNewLines(at: path, from: startOffset, maxBytes: bytesBudget, onLine: { buf in
                // 先在原始字节上过滤（不转 String，不做 Unicode 查找），绝大多数行（用户消息、工具结果、
                // 几 MB 的截图 base64）在这一步就被扔掉了，一次 String 分配都不用做
                guard LineBytePrefilter.hasAssistantType(buf) else {
                    // 不是 assistant 行：只取个时间戳当"下一条请求的起点"，不整行转 String/JSON
                    if let ts = LineBytePrefilter.extractTimestamp(buf) { fileTrigger = ts }
                    return
                }
                guard LineBytePrefilter.looksLikeAssistantUsageLine(buf) else { return }
                let line = String(decoding: buf, as: UTF8.self)
                guard let parsed = Self.parseAssistantLine(line) else { return }
                if parsed.timestamp < historyCutoff { return }

                let dayKey = localDayKey(parsed.timestamp)
                cache.rawOutputByDay[dayKey, default: 0] += parsed.output

                // 同一 id 留最后一次。sidechain 且这条 id 已经在主链出现过：整行丢掉，不替换主链那份。
                if let dedupeKey = parsed.dedupeKey, parsed.isSidechain, priors.containsMain(dedupeKey) {
                    return
                }
                let replacing = parsed.dedupeKey.flatMap { priors.rec($0) } != nil
                if let dedupeKey = parsed.dedupeKey, let prior = priors.rec(dedupeKey) {
                    Self.retract(prior, id: dedupeKey, cache: &cache)
                }

                let (cost, cacheSavings, isFallback) = ClaudeCost.compute(
                    model: parsed.model, input: parsed.input, output: parsed.output, cache: parsed.cache)
                if isFallback { fallbackModels.insert(parsed.model) }

                let project = Self.resolveProject(cwd: parsed.cwd, encodedProjectDir: encodedProjectDir)
                let delta = tcDelta(parsed)

                var bucket = cache.days[dayKey] ?? DayBucket()
                bucket.tokensByModel[parsed.model] = (bucket.tokensByModel[parsed.model] ?? TokenCountsCodable()) + delta
                bucket.costByModel[parsed.model, default: 0] += cost
                bucket.requestsByModel[parsed.model, default: 0] += 1
                bucket.requests += 1
                bucket.cacheSavings += cacheSavings
                bucket.cacheWrite1h += parsed.cache.write1h
                if let dedupeKey = parsed.dedupeKey {
                    bucket.dedupeKeys.insert(dedupeKey)
                }
                cache.days[dayKey] = bucket

                var hourBucket = cache.hours[localHourKey(parsed.timestamp)] ?? HourBucket()
                hourBucket.tokens = hourBucket.tokens + delta
                hourBucket.cost += cost
                hourBucket.requests += 1
                cache.hours[localHourKey(parsed.timestamp)] = hourBucket

                if let project {
                    var projectsForDay = cache.projectDays[dayKey] ?? [:]
                    var pb = projectsForDay[project] ?? ProjectBucket()
                    pb.tokens = pb.tokens + delta
                    pb.cost += cost
                    pb.requests += 1
                    if pb.lastActive == nil || parsed.timestamp > pb.lastActive! { pb.lastActive = parsed.timestamp }
                    projectsForDay[project] = pb
                    cache.projectDays[dayKey] = projectsForDay
                }

                // 耗时仍用「这个文件里最近一条非 assistant 行 → 当前这条」。同一 id 多次出现时，
                // 以最后一次的时间重算，并把上一份从明细里减掉。
                var durationMs: Int?
                if let trig = fileTrigger {
                    let gapMs = Int(parsed.timestamp.timeIntervalSince(trig) * 1000)
                    if gapMs >= Self.minPlausibleDurationMs && gapMs <= Self.maxPlausibleDurationMs {
                        durationMs = gapMs
                    }
                }

                Self.addDetail(&cache.detailHours, key: localHourKey(parsed.timestamp), provider: Self.provider,
                                model: parsed.model, delta: delta, cost: cost, cacheSavings: cacheSavings,
                                cacheWrite1h: parsed.cache.write1h, durationMs: durationMs)
                Self.addDetail(&cache.detailDays, key: dayKey, provider: Self.provider,
                                model: parsed.model, delta: delta, cost: cost, cacheSavings: cacheSavings,
                                cacheWrite1h: parsed.cache.write1h, durationMs: durationMs)

                let requestEntry = UsageRequestCodable(
                    id: parsed.dedupeKey ?? UUID().uuidString, time: parsed.timestamp, tool: AITool.claude.rawValue,
                    model: parsed.model, project: project, sessionID: parsed.sessionID,
                    tokens: delta, cacheWrite1h: parsed.cache.write1h, cost: cost,
                    provider: Self.provider, durationMs: durationMs, durationIsEstimate: true)
                if parsed.dedupeKey != nil {
                    RequestRing.replace(requestEntry, into: &cache.recentRequests)
                } else {
                    RequestRing.push(requestEntry, into: &cache.recentRequests)
                    cache.looseEvents.append(ClaudeLooseEvent(
                        time: parsed.timestamp.timeIntervalSince1970, input: parsed.input, output: parsed.output,
                        cacheRead: parsed.cache.read, cacheWrite: parsed.cache.write5m + parsed.cache.write1h, cost: cost))
                }

                if let dedupeKey = parsed.dedupeKey {
                    priors.set(dedupeKey, ClaudePriorStore.Rec(
                        time: parsed.timestamp.timeIntervalSince1970,
                        input: parsed.input, output: parsed.output, cacheRead: parsed.cache.read,
                        write5m: parsed.cache.write5m, write1h: parsed.cache.write1h,
                        cost: cost, savings: cacheSavings,
                        durationMs: Int32(durationMs ?? -1), main: !parsed.isSidechain,
                        model: parsed.model, project: project, sessionID: parsed.sessionID))
                }

                if !replacing {
                    recent.add(parsed.timestamp, parsed.input + parsed.output)
                }
                if lastActivity == nil || parsed.timestamp > lastActivity! { lastActivity = parsed.timestamp }
            }) else { continue }

            cache.lastTriggerByFile[path] = fileTrigger?.timeIntervalSince1970
            bytesBudget -= Int(newOffset - startOffset)
            if newOffset < Int64(size) { hitBudgetCap = true } // 这个文件还没读到底，不是真的"追上了"
            cache.fileCursors[path] = FileCursor(inode: UInt64(inode), size: Int64(size), offset: newOffset,
                                                  mtime: mtime.timeIntervalSince1970)
        }

        cache.lastActivity = lastActivity
        pruneOld(&cache, now: now, safeToClearDedupe: !hitBudgetCap)
        if !hitBudgetCap {
            priors.prune(olderThan: now.addingTimeInterval(-30 * 86400))
        }
        priors.save(to: priorFile)
        let blocks = Self.blocks(from: priors, loose: cache.looseEvents, now: now)
        let keys30 = last30DayKeys(now: now)
        debugOutputBefore30 = keys30.reduce(Int64(0)) { $0 + (cache.rawOutputByDay[$1] ?? 0) }
        debugOutputAfter30 = keys30.reduce(Int64(0)) { $0 + (cache.days[$1]?.totalTokens.output ?? 0) }
        saveCache(cache)

        // 不止看这一轮新解析到的行：缓存里现有数据涉及的型号也都查一遍，
        // 这样重启后（这轮可能一行新数据都没有）仍能准确报出"现在有哪些型号在用家族回退价"
        for bucket in cache.days.values {
            for model in bucket.tokensByModel.keys where ClaudePricingTable.rate(for: model).isFallback {
                fallbackModels.insert(model)
            }
        }

        let (today, daily, models) = Self.buildWindows(from: cache.days, now: now)
        let history = Self.buildHistory(from: cache.days, now: now)
        let hourly = Self.buildHourly(from: cache.hours, now: now)
        let projects = Self.buildProjects(from: cache.projectDays, tool: .claude, now: now)
        let requests = cache.recentRequests.compactMap { $0.toContract() }
        let hourlyDetail = Self.buildDetailBuckets(from: cache.detailHours, tool: .claude) { date(forHourKey: $0) }
        let dailyDetail = Self.buildDetailBuckets(from: cache.detailDays, tool: .claude) { date(forDayKey: $0) }
        let pricing = models.map { Self.pricingEntry(for: $0.model) }

        var result = ClaudeLocalResult(status: .ok, today: today, daily: daily, models: models, history: history,
                                  hourly: hourly, recentRequests: requests, projects: projects,
                                  hourlyDetail: hourlyDetail, dailyDetail: dailyDetail, pricing: pricing,
                                  lastActivity: lastActivity, tokensPerMinute: recent.tokensPerMinute(now: now),
                                  fallbackPricedModels: fallbackModels)
        result.hasBacklog = hitBudgetCap
        result.currentBlock = blocks.current
        result.recentBlocks = blocks.recent
        result.peakBlockTokens = blocks.peak
        return result
    }

    private static func emptyResult(_ status: UsageStatus) -> ClaudeLocalResult {
        ClaudeLocalResult(status: status, today: DailyUsage(day: Calendar.current.startOfDay(for: Date())),
                           daily: [], models: [], history: [], hourly: [], recentRequests: [], projects: [],
                           hourlyDetail: [], dailyDetail: [], pricing: [],
                           lastActivity: nil, tokensPerMinute: 0, fallbackPricedModels: [])
    }

    /// 一个模型按 LiteLLM 表折算的美元/百万 token 单价
    static func pricingEntry(for model: String) -> PricingEntry {
        let (rate, _, _) = ClaudePricingTable.rateWithSource(for: model)
        let source = ClaudePricingTable.source(for: model)
        return PricingEntry(model: model, tool: .claude, input: rate.input * 1_000_000, output: rate.output * 1_000_000,
                             cacheRead: rate.cacheRead * 1_000_000, cacheWrite5m: rate.cacheWrite5m * 1_000_000,
                             cacheWrite1h: rate.cacheWrite1h * 1_000_000, source: source)
    }

    /// 往"时间 key -> 供应商 -> 模型 -> 聚合"这个三层字典里加一条请求的量，Claude/OpenCode 共用
    static func addDetail(_ store: inout [String: [String: [String: DetailBucket]]], key: String, provider: String, model: String,
                           delta: TokenCountsCodable, cost: Double, cacheSavings: Double, cacheWrite1h: Int64, durationMs: Int?) {
        var byProvider = store[key] ?? [:]
        var byModel = byProvider[provider] ?? [:]
        var cell = byModel[model] ?? DetailBucket()
        cell.tokens = cell.tokens + delta
        cell.cost += cost
        cell.requests += 1
        cell.cacheSavings += cacheSavings
        cell.cacheWrite1h += cacheWrite1h
        // 输出太短的请求，耗时几乎全是等待首字，算进去会把速度拉到 1 tok/s 这种假数
        if let durationMs, durationMs > 0, delta.output >= SpeedRule.minOutputTokens {
            cell.timedOutputTokens += delta.output
            cell.timedDurationMs += Int64(durationMs)
        }
        byModel[model] = cell
        byProvider[provider] = byModel
        store[key] = byProvider
    }

    /// addDetail 的逆操作。请求数减到 0 就把格子拿掉，避免减完还留着一个空桶
    static func subtractDetail(_ store: inout [String: [String: [String: DetailBucket]]], key: String, provider: String, model: String,
                               delta: TokenCountsCodable, cost: Double, cacheSavings: Double, cacheWrite1h: Int64, durationMs: Int?) {
        guard var byProvider = store[key], var byModel = byProvider[provider], var cell = byModel[model] else { return }
        cell.tokens = cell.tokens - delta
        cell.cost -= cost
        cell.requests -= 1
        cell.cacheSavings -= cacheSavings
        cell.cacheWrite1h -= cacheWrite1h
        if let durationMs, durationMs > 0, delta.output >= SpeedRule.minOutputTokens {
            cell.timedOutputTokens -= delta.output
            cell.timedDurationMs -= Int64(durationMs)
        }
        if cell.requests <= 0 && cell.tokens.total == 0 {
            byModel.removeValue(forKey: model)
        } else {
            byModel[model] = cell
        }
        if byModel.isEmpty {
            byProvider.removeValue(forKey: provider)
        } else {
            byProvider[provider] = byModel
        }
        if byProvider.isEmpty {
            store.removeValue(forKey: key)
        } else {
            store[key] = byProvider
        }
    }

    /// 把上次记在这个 id 上的那一份从天/小时/模型/项目/明细里减掉
    private static func retract(_ prior: ClaudePriorStore.Rec, id: String, cache: inout ClaudeUsageCache) {
        let when = Date(timeIntervalSince1970: prior.time)
        let dayKey = localDayKey(when)
        let hourKey = localHourKey(when)
        let delta = prior.tokens
        let duration: Int? = prior.durationMs >= 0 ? Int(prior.durationMs) : nil

        if var bucket = cache.days[dayKey] {
            if let current = bucket.tokensByModel[prior.model] {
                let next = current - delta
                if next.total == 0 {
                    bucket.tokensByModel.removeValue(forKey: prior.model)
                } else {
                    bucket.tokensByModel[prior.model] = next
                }
            }
            let reqs = (bucket.requestsByModel[prior.model] ?? 0) - 1
            if reqs <= 0 {
                bucket.requestsByModel.removeValue(forKey: prior.model)
                bucket.costByModel.removeValue(forKey: prior.model)
            } else {
                bucket.requestsByModel[prior.model] = reqs
                bucket.costByModel[prior.model] = (bucket.costByModel[prior.model] ?? 0) - prior.cost
            }
            bucket.requests -= 1
            bucket.cacheSavings -= prior.savings
            bucket.cacheWrite1h -= prior.write1h
            bucket.dedupeKeys.remove(id)
            cache.days[dayKey] = bucket
        }

        if var hour = cache.hours[hourKey] {
            hour.tokens = hour.tokens - delta
            hour.cost -= prior.cost
            hour.requests -= 1
            if hour.requests <= 0 && hour.tokens.total == 0 {
                cache.hours.removeValue(forKey: hourKey)
            } else {
                cache.hours[hourKey] = hour
            }
        }

        if let project = prior.project, var projects = cache.projectDays[dayKey], var pb = projects[project] {
            pb.tokens = pb.tokens - delta
            pb.cost -= prior.cost
            pb.requests -= 1
            if pb.requests <= 0 && pb.tokens.total == 0 {
                projects.removeValue(forKey: project)
            } else {
                projects[project] = pb
            }
            if projects.isEmpty {
                cache.projectDays.removeValue(forKey: dayKey)
            } else {
                cache.projectDays[dayKey] = projects
            }
        }

        subtractDetail(&cache.detailHours, key: hourKey, provider: provider, model: prior.model,
                       delta: delta, cost: prior.cost, cacheSavings: prior.savings,
                       cacheWrite1h: prior.write1h, durationMs: duration)
        subtractDetail(&cache.detailDays, key: dayKey, provider: provider, model: prior.model,
                       delta: delta, cost: prior.cost, cacheSavings: prior.savings,
                       cacheWrite1h: prior.write1h, durationMs: duration)
        cache.recentRequests.removeAll { $0.id == id }
    }

    private static func blocks(from priors: ClaudePriorStore, loose: [ClaudeLooseEvent], now: Date) -> (current: UsageBlock?, recent: [UsageBlock], peak: Int64) {
        var events: [UsageBlocks.Event] = []
        events.reserveCapacity(priors.byID.count + loose.count)
        let cutoff = now.addingTimeInterval(-30 * 86400 - UsageBlocks.duration)
        for rec in priors.byID.values where rec.time >= cutoff.timeIntervalSince1970 {
            events.append(UsageBlocks.Event(
                time: Date(timeIntervalSince1970: rec.time),
                tokens: rec.tokens.asTokenCounts,
                cost: rec.cost,
                requests: 1))
        }
        for rec in loose where rec.time >= cutoff.timeIntervalSince1970 {
            events.append(UsageBlocks.Event(
                time: Date(timeIntervalSince1970: rec.time),
                tokens: TokenCounts(input: rec.input, output: rec.output, cacheRead: rec.cacheRead, cacheWrite: rec.cacheWrite),
                cost: rec.cost,
                requests: 1))
        }
        return UsageBlocks.summarize(events, now: now)
    }

    /// 三层字典摊平成契约要的 [UsageBucket]，只要非空格子，时间升序
    static func buildDetailBuckets(from store: [String: [String: [String: DetailBucket]]], tool: AITool,
                                    dateFor: (String) -> Date?) -> [UsageBucket] {
        var result: [UsageBucket] = []
        for (key, byProvider) in store {
            guard let start = dateFor(key) else { continue }
            for (provider, byModel) in byProvider {
                for (model, cell) in byModel {
                    guard cell.requests > 0 else { continue }
                    result.append(UsageBucket(start: start, tool: tool, provider: provider, model: model,
                                               tokens: cell.tokens.asTokenCounts, cost: cell.cost, requests: cell.requests,
                                               cacheSavings: cell.cacheSavings, cacheWrite1h: cell.cacheWrite1h,
                                               timedOutputTokens: cell.timedOutputTokens, timedDurationMs: cell.timedDurationMs))
                }
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// 这一条用量行自己的 TokenCounts（不是桶里累计后的值），给小时桶/项目桶/请求明细用
    private func tcDelta(_ parsed: ParsedLine) -> TokenCountsCodable {
        TokenCountsCodable(input: parsed.input, output: parsed.output, cacheRead: parsed.cache.read,
                            cacheWrite: parsed.cache.write5m + parsed.cache.write1h)
    }

    /// 项目名：优先用这一行自己的 cwd 最后一级；没有 cwd 就把 ~/.claude/projects/<encoded> 的目录名解码
    /// （Claude Code 自己的编码规则是 "/" -> "-"，这是有损的——真实目录名里本来就带 "-" 的话解不精确，
    /// 只在没有 cwd 时才退到这个兜底）
    private static func resolveProject(cwd: String?, encodedProjectDir: String) -> String? {
        if let cwd, !cwd.isEmpty {
            let last = (cwd as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        let decoded = encodedProjectDir.replacingOccurrences(of: "-", with: "/")
        let last = decoded.components(separatedBy: "/").last { !$0.isEmpty }
        return last
    }

    /// 返回 (文件绝对路径, projects 目录下紧跟着的那一级目录名——也就是编码后的项目目录名)
    private func enumerateJSONLFiles() -> [(path: String, encodedProjectDir: String)] {
        var result: [(String, String)] = []
        let fm = FileManager.default
        for projectsDir in projectDirs {
            guard let en = fm.enumerator(at: projectsDir, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { continue }
            let base = projectsDir.standardizedFileURL.path
            for item in en {
                guard let url = item as? URL, url.pathExtension == "jsonl" else { continue }
                let full = url.standardizedFileURL.path
                var relative = full
                if full.hasPrefix(base) {
                    relative = String(full.dropFirst(base.count))
                    if relative.hasPrefix("/") { relative.removeFirst() }
                }
                let encodedDir = relative.components(separatedBy: "/").first ?? ""
                result.append((full, encodedDir))
            }
        }
        return result
    }

    private struct ParsedLine {
        var model: String
        var input: Int64
        var output: Int64
        var cache: ClaudeCacheBreakdown
        var timestamp: Date
        var dedupeKey: String?
        var cwd: String?
        var sessionID: String?
        var isSidechain: Bool
    }

    private static func parseAssistantLine(_ line: String) -> ParsedLine? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let model = message["model"] as? String, model != "<synthetic>",
              let usage = message["usage"] as? [String: Any],
              let timestampStr = obj["timestamp"] as? String,
              let timestamp = ISO8601.parse(timestampStr)
        else { return nil }

        let input = (usage["input_tokens"] as? NSNumber)?.int64Value ?? 0
        let output = (usage["output_tokens"] as? NSNumber)?.int64Value ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.int64Value ?? 0
        var write5m: Int64 = 0
        var write1h: Int64 = 0
        if let creation = usage["cache_creation"] as? [String: Any] {
            write5m = (creation["ephemeral_5m_input_tokens"] as? NSNumber)?.int64Value ?? 0
            write1h = (creation["ephemeral_1h_input_tokens"] as? NSNumber)?.int64Value ?? 0
        } else if let totalWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.int64Value, totalWrite > 0 {
            write5m = totalWrite // 没给拆分时，按 5 分钟档（默认 TTL）算
        }

        if input == 0 && output == 0 && cacheRead == 0 && write5m == 0 && write1h == 0 { return nil }

        let messageId = message["id"] as? String
        let requestId = obj["requestId"] as? String
        let dedupeKey: String?
        if let messageId, !messageId.isEmpty {
            dedupeKey = messageId
        } else if let requestId, !requestId.isEmpty {
            dedupeKey = "req:" + requestId
        } else {
            dedupeKey = nil
        }

        let cwd = obj["cwd"] as? String
        let sessionID = obj["sessionId"] as? String
        let isSidechain = (obj["isSidechain"] as? Bool) ?? ((obj["isSidechain"] as? NSNumber)?.boolValue ?? false)

        return ParsedLine(model: model, input: input, output: output,
                           cache: ClaudeCacheBreakdown(write5m: write5m, write1h: write1h, read: cacheRead),
                           timestamp: timestamp, dedupeKey: dedupeKey, cwd: cwd, sessionID: sessionID,
                           isSidechain: isSidechain)
    }

    /// 把按天的桶拼成契约要的 today / daily(30 项) / models(近 30 天按 token 降序，带分类型明细和请求数)
    static func buildWindows(from days: [String: DayBucket], now: Date) -> (today: DailyUsage, daily: [DailyUsage], models: [ModelShare]) {
        let keys = last30DayKeys(now: now)
        var daily: [DailyUsage] = []
        var modelTotals: [String: (tokens: TokenCountsCodable, cost: Double, requests: Int)] = [:]

        for key in keys {
            let bucket = days[key]
            let totalTokens = bucket?.totalTokens.asTokenCounts ?? TokenCounts()
            let totalCost = bucket?.totalCost ?? 0
            let dayDate = date(forDayKey: key) ?? now
            daily.append(DailyUsage(day: Calendar.current.startOfDay(for: dayDate), tokens: totalTokens, cost: totalCost,
                                     requests: bucket?.requests ?? 0, cacheSavings: bucket?.cacheSavings ?? 0,
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
        let today = daily.last ?? DailyUsage(day: Calendar.current.startOfDay(for: now))
        return (today, daily, models)
    }

    /// 365 天历史：天总量，补 0，最早在前
    static func buildHistory(from days: [String: DayBucket], now: Date) -> [DailyUsage] {
        last365DayKeys(now: now).map { key in
            let bucket = days[key]
            let dayDate = date(forDayKey: key) ?? now
            return DailyUsage(day: Calendar.current.startOfDay(for: dayDate), tokens: bucket?.totalTokens.asTokenCounts ?? TokenCounts(),
                               cost: bucket?.totalCost ?? 0, requests: bucket?.requests ?? 0,
                               cacheSavings: bucket?.cacheSavings ?? 0, cacheWrite1h: bucket?.cacheWrite1h ?? 0)
        }
    }

    /// 近 30 天只有数据的小时，按时间升序
    static func buildHourly(from hours: [String: HourBucket], now: Date) -> [HourlyUsage] {
        let keep = Set(last30DayKeys(now: now))
        return hours.keys
            .filter { keep.contains(String($0.prefix(10))) }
            .sorted()
            .compactMap { key -> HourlyUsage? in
                guard let bucket = hours[key], let hourDate = date(forHourKey: key) else { return nil }
                return HourlyUsage(hour: hourDate, tokens: bucket.tokens.asTokenCounts, cost: bucket.cost, requests: bucket.requests)
            }
    }

    /// 近 30 天按项目汇总，用量大的在前，最多 50 个（界面只展示头几个，缓存里存多少无所谓，发出去的要封顶）
    static func buildProjects(from projectDays: [String: [String: ProjectBucket]], tool: AITool, now: Date) -> [ProjectShare] {
        let keep = Set(last30DayKeys(now: now))
        var totals: [String: (tokens: TokenCountsCodable, cost: Double, requests: Int, lastActive: Date?)] = [:]
        for (day, projects) in projectDays where keep.contains(day) {
            for (project, bucket) in projects {
                var entry = totals[project] ?? (TokenCountsCodable(), 0, 0, nil)
                entry.tokens = entry.tokens + bucket.tokens
                entry.cost += bucket.cost
                entry.requests += bucket.requests
                if let la = bucket.lastActive, entry.lastActive == nil || la > entry.lastActive! { entry.lastActive = la }
                totals[project] = entry
            }
        }
        return totals.map { (project, v) in
            ProjectShare(project: project, tool: tool, tokens: v.tokens.asTokenCounts, cost: v.cost, requests: v.requests, lastActive: v.lastActive)
        }.sorted { $0.tokens.total > $1.tokens.total }.prefix(50).map { $0 }
    }

    /// safeToClearDedupe：这一轮是不是真的把所有文件都读到底了。
    /// 去重集合本该只在"今天"才有用（其它天已经冻结，不会再有新行）——但一轮最多读 64MB，
    /// 一个大文件可能要好几轮才读完；如果在两条"同一个 message.id 重复出现"的行正好被这次预算
    /// 切断的地方停下，提前清掉旧天的去重集合会导致下一轮把后半条重复行当成新数据，重复计数
    /// （这正是 round 3 验证时抓到的一个真实 bug：30 天总量比独立核对脚本多算了几亿 token）。
    /// 所以只有这轮没被预算打断（每个文件都读到了当时的末尾）才清，不然宁可多占点缓存也不能算错。
    private func pruneOld(_ cache: inout ClaudeUsageCache, now: Date, safeToClearDedupe: Bool) {
        let keep365 = Set(last365DayKeys(now: now))
        for key in cache.days.keys where !keep365.contains(key) {
            cache.days.removeValue(forKey: key)
        }
        if safeToClearDedupe {
            let today = localDayKey(now)
            for key in cache.days.keys where key != today {
                cache.days[key]?.dedupeKeys.removeAll(keepingCapacity: false)
            }
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
        for key in cache.rawOutputByDay.keys where !keep365.contains(key) {
            cache.rawOutputByDay.removeValue(forKey: key)
        }
        let looseCutoff = now.addingTimeInterval(-30 * 86400).timeIntervalSince1970
        cache.looseEvents.removeAll { $0.time < looseCutoff }

        // 源文件被删掉了（Claude Code 自己清理）就别再占着游标缓存/触发时间缓存
        let fm = FileManager.default
        for key in cache.fileCursors.keys where !fm.fileExists(atPath: key) {
            cache.fileCursors.removeValue(forKey: key)
        }
        for key in cache.lastTriggerByFile.keys where !fm.fileExists(atPath: key) {
            cache.lastTriggerByFile.removeValue(forKey: key)
        }
    }

    private func loadCache() -> ClaudeUsageCache {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode(ClaudeUsageCache.self, from: data),
              cache.version == ClaudeUsageCache.currentVersion
        else {
            try? FileManager.default.removeItem(at: priorFile)
            return ClaudeUsageCache()
        }
        return cache
    }

    private func saveCache(_ cache: ClaudeUsageCache) {
        UsageCacheLocation.ensureDir()
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}

/// 速度（tok/s）的统计口径：界面和后端共用
enum SpeedRule {
    static let minOutputTokens: Int64 = 50
}
