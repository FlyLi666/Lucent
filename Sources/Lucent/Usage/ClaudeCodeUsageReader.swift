import Foundation

// Claude Code 用量：本机 ~/.claude/projects/**/*.jsonl 增量解析。只读本机日志，不读任何
// Claude 登录凭据、不查额度接口（第三方收集会话令牌违反 Anthropic 条款）。
// 所以这里没有额度（quotas 始终是空的，plan 始终是 nil），status 只看本机日志读得好不好。

struct ClaudeUsageCache: Codable, Sendable {
    var fileCursors: [String: FileCursor] = [:]
    /// 按 UTC 整点键（yyyy-MM-dd'T'HH）存最长 367 天的（供应商 × 模型）聚合：
    /// 不依赖写入时的本机时区，Claude Code 清理 30 天前的 jsonl 后 365 天历史仍在。
    var detailHours: [String: [String: [String: DetailBucket]]] = [:]
    /// 近 32 天按 UTC 整点存的项目聚合，读出时按当前本机时区归入近 30 天窗口
    var projectHours: [String: [String: ProjectBucket]] = [:]
    /// 每个文件里"最近一条非 assistant 行"的时间（用来估算下一条 assistant 行的请求耗时），
    /// 按文件路径存，增量读、跨进程重启都要能接得上
    var lastTriggerByFile: [String: Double] = [:]
    /// 最新在前，最多 1000 条
    var recentRequests: [UsageRequestCodable] = []
    /// 最近一条 assistant 消息的时间，跨进程重启、跨"这轮没有新行"的空转都要保留，不能只在当次扫描里算
    var lastActivity: Date?
    /// 去重前的 output，按 UTC 整点累加（同一条流式补全的每一次出现都算）。只给调试对照用
    var rawOutputByHour: [String: Int64] = [:]
    /// 没有 message.id / requestId 的用量行，没法替换，单独记下来给 5 小时窗口用
    var looseEvents: [ClaudeLooseEvent] = []
    var version: Int = ClaudeUsageCache.currentVersion
    /// 统计口径变了就加一，旧缓存直接丢弃重算
    /// （7：改用 UTC 小时桶消除切时区丢数/错窗，按 stop_reason 与最大输出去重防分叉清零）
    static let currentVersion = 7
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
    private let rebuildCacheFile: URL
    private let rebuildPriorFile: URL
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
        self.rebuildCacheFile = UsageCacheLocation.url("claude-usage-\(cacheToken).rebuild.json")
        self.rebuildPriorFile = UsageCacheLocation.url("claude-priors-\(cacheToken).rebuild.bin")
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
        let hasExistingFiles = fm.fileExists(atPath: cacheFile.path) || fm.fileExists(atPath: priorFile.path)
        var cache: ClaudeUsageCache
        let priors: ClaudePriorStore
        // 缓存或侧车版本不符/损坏时整份重扫，但冷扫彻底成功之前绝不删除或覆盖磁盘上原有的 priorFile / cacheFile；
        // 多轮预算分批冷扫的中间进度暂存在 .rebuild 侧车里，全部追平后再原子替换正式文件。
        let rebuildingExisting: Bool
        if let validCache = loadValidCache(from: cacheFile),
           let loadedPriors = ClaudePriorStore.load(from: priorFile) {
            cache = validCache
            priors = loadedPriors
            rebuildingExisting = false
        } else if let validCache = loadValidCache(from: cacheFile),
                  validCache.detailHours.isEmpty && validCache.fileCursors.isEmpty,
                  !fm.fileExists(atPath: priorFile.path) {
            cache = validCache
            priors = ClaudePriorStore()
            rebuildingExisting = false
        } else if !hasExistingFiles {
            cache = ClaudeUsageCache()
            priors = ClaudePriorStore()
            rebuildingExisting = false
        } else if let stagedCache = loadValidCache(from: rebuildCacheFile),
                  let stagedPriors = ClaudePriorStore.load(from: rebuildPriorFile) {
            cache = stagedCache
            priors = stagedPriors
            rebuildingExisting = true
        } else {
            cache = ClaudeUsageCache()
            priors = ClaudePriorStore()
            rebuildingExisting = true
        }
        let now = Date()
        let historyCutoff = now.addingTimeInterval(-365 * 86400)
        var fallbackModels: Set<String> = []
        var lastActivity: Date? = cache.lastActivity
        // 一轮最多读这么多新字节：冷扫描或一次性几十 MB 的追加会被摊到好几轮 15 秒 tick 里，
        // 不会把 CPU 焊死在一次调用上（2026-10-16 生产事故：107% CPU 几秒、峰值内存 1.6GB）
        var bytesBudget = 64 * 1024 * 1024

        var hitBudgetCap = false // 这轮有没有哪个文件没读完——没读完就不敢清旧天的去重集合（见下面 pruneOld 前的说明）
        var eligibleFiles = 0
        var readFailures = 0

        let files = enumerateJSONLFiles().sorted { $0.path < $1.path } // 固定顺序，预算不够时下一轮按顺序接着来
        for (path, encodedProjectDir) in files {
            guard bytesBudget > 0 else { hitBudgetCap = true; break }
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= historyCutoff,
                  let size = attrs[.size] as? Int, let inode = attrs[.systemFileNumber] as? Int
            else { continue }
            eligibleFiles += 1

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

                let utcHour = utcHourKey(parsed.timestamp)
                cache.rawOutputByHour[utcHour, default: 0] += parsed.output

                if let dedupeKey = parsed.dedupeKey {
                    if parsed.isSidechain && priors.containsMain(dedupeKey) { return }
                    if priors.rec(dedupeKey) == nil && priors.isSettledMain(dedupeKey) { return }
                }

                let delta = tcDelta(parsed)
                var replacing = false
                // 会话分叉重放可能重复写出同一 dedupeKey（含未完结块或残行）：
                // 只在新行首次带上 stop_reason（且不小于旧账）或 output/总 token 严格更大时才覆盖原记录。
                if let dedupeKey = parsed.dedupeKey, let prior = priors.rec(dedupeKey) {
                    let newTotal = delta.total
                    let oldTotal = prior.tokens.total
                    let shouldReplace: Bool
                    if parsed.hasStopReason && !prior.hasStopReason {
                        shouldReplace = parsed.output >= prior.output && newTotal >= oldTotal
                    } else if parsed.hasStopReason == prior.hasStopReason {
                        shouldReplace = parsed.output > prior.output
                            || (parsed.output == prior.output && newTotal > oldTotal)
                    } else {
                        shouldReplace = parsed.output > prior.output && newTotal >= oldTotal
                    }
                    guard shouldReplace else { return }
                    Self.retract(prior, id: dedupeKey, cache: &cache)
                    replacing = true
                }

                let (cost, cacheSavings, isFallback) = ClaudeCost.compute(
                    model: parsed.model, input: parsed.input, output: parsed.output, cache: parsed.cache)
                if isFallback { fallbackModels.insert(parsed.model) }

                let project = Self.resolveProject(cwd: parsed.cwd, encodedProjectDir: encodedProjectDir)
                if let project {
                    UTCHourRollup.addProject(&cache.projectHours, utcHour: utcHour, project: project,
                                             delta: delta, cost: cost, timestamp: parsed.timestamp)
                }

                var durationMs: Int?
                if let trig = fileTrigger {
                    let gapMs = Int(parsed.timestamp.timeIntervalSince(trig) * 1000)
                    if gapMs >= Self.minPlausibleDurationMs && gapMs <= Self.maxPlausibleDurationMs {
                        durationMs = gapMs
                    }
                }

                Self.addDetail(&cache.detailHours, key: utcHour, provider: Self.provider,
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
                        hasStopReason: parsed.hasStopReason,
                        model: parsed.model, project: project, sessionID: parsed.sessionID))
                }

                if !replacing {
                    recent.add(parsed.timestamp, parsed.input + parsed.output)
                }
                if lastActivity == nil || parsed.timestamp > lastActivity! { lastActivity = parsed.timestamp }
            }) else {
                readFailures += 1
                continue
            }

            cache.lastTriggerByFile[path] = fileTrigger?.timeIntervalSince1970
            bytesBudget -= Int(newOffset - startOffset)
            if newOffset < Int64(size) { hitBudgetCap = true } // 这个文件还没读到底，不是真的"追上了"
            cache.fileCursors[path] = FileCursor(inode: UInt64(inode), size: Int64(size), offset: newOffset,
                                                  mtime: mtime.timeIntervalSince1970)
        }

        cache.lastActivity = lastActivity
        pruneOld(&cache, now: now)
        let allEligibleFailed = eligibleFiles > 0 && readFailures == eligibleFiles && cache.fileCursors.isEmpty
        if rebuildingExisting {
            if allEligibleFailed {
                // 日志读取全部失败，冷扫未成功，不动旧缓存与旧 priorFile
            } else if hitBudgetCap {
                priors.save(to: rebuildPriorFile)
                saveCache(cache, to: rebuildCacheFile)
            } else {
                priors.prune(olderThan: now.addingTimeInterval(-30 * 86400))
                priors.save(to: priorFile)
                saveCache(cache, to: cacheFile)
                try? fm.removeItem(at: rebuildCacheFile)
                try? fm.removeItem(at: rebuildPriorFile)
            }
        } else {
            if !hitBudgetCap {
                priors.prune(olderThan: now.addingTimeInterval(-30 * 86400))
            }
            priors.save(to: priorFile)
            saveCache(cache, to: cacheFile)
            try? fm.removeItem(at: rebuildCacheFile)
            try? fm.removeItem(at: rebuildPriorFile)
        }

        let blocks = Self.blocks(from: priors, loose: cache.looseEvents, now: now)
        let snap = UTCHourRollup.build(detailHours: cache.detailHours, projectHours: cache.projectHours,
                                       tool: .claude, now: now)
        let keep30 = Set(last30DayKeys(now: now))
        debugOutputBefore30 = cache.rawOutputByHour.reduce(Int64(0)) { sum, entry in
            guard let d = date(forUTCHourKey: entry.key), keep30.contains(localDayKey(d)) else { return sum }
            return sum + entry.value
        }
        debugOutputAfter30 = snap.daily.reduce(Int64(0)) { $0 + $1.tokens.output }

        for byProvider in cache.detailHours.values {
            for byModel in byProvider.values {
                for model in byModel.keys where ClaudePricingTable.rate(for: model).isFallback {
                    fallbackModels.insert(model)
                }
            }
        }

        let requests = cache.recentRequests.compactMap { $0.toContract() }
        let pricing = snap.models.map { Self.pricingEntry(for: $0.model) }

        var result = ClaudeLocalResult(status: .ok, today: snap.today, daily: snap.daily, models: snap.models, history: snap.history,
                                  hourly: snap.hourly, recentRequests: requests, projects: snap.projects,
                                  hourlyDetail: snap.hourlyDetail, dailyDetail: snap.dailyDetail, pricing: pricing,
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

    /// 把上次记在这个 id 上的那一份从 UTC 小时明细和项目桶里减掉
    private static func retract(_ prior: ClaudePriorStore.Rec, id: String, cache: inout ClaudeUsageCache) {
        let when = Date(timeIntervalSince1970: prior.time)
        let utcHour = utcHourKey(when)
        let delta = prior.tokens
        let duration: Int? = prior.durationMs >= 0 ? Int(prior.durationMs) : nil

        if let project = prior.project {
            UTCHourRollup.subtractProject(&cache.projectHours, utcHour: utcHour, project: project,
                                          delta: delta, cost: prior.cost)
        }
        subtractDetail(&cache.detailHours, key: utcHour, provider: provider, model: prior.model,
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
        var hasStopReason: Bool
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
        let totalWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.int64Value ?? 0
        var write5m: Int64 = 0
        var write1h: Int64 = 0
        if let creation = usage["cache_creation"] as? [String: Any] {
            write5m = (creation["ephemeral_5m_input_tokens"] as? NSNumber)?.int64Value ?? 0
            write1h = (creation["ephemeral_1h_input_tokens"] as? NSNumber)?.int64Value ?? 0
            if write5m + write1h < totalWrite {
                write5m = totalWrite - write1h
            }
        } else if totalWrite > 0 {
            write5m = totalWrite // 没给拆分时，按 5 分钟档（默认 TTL）算
        }

        // 分叉重放里的全零占位行直接丢弃，不进入去重替换路径以免清掉原记录
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
        let hasStopReason: Bool = {
            guard let sr = message["stop_reason"] as? String else { return false }
            return !sr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }()

        return ParsedLine(model: model, input: input, output: output,
                           cache: ClaudeCacheBreakdown(write5m: write5m, write1h: write1h, read: cacheRead),
                           timestamp: timestamp, dedupeKey: dedupeKey, cwd: cwd, sessionID: sessionID,
                           isSidechain: isSidechain, hasStopReason: hasStopReason)
    }

    /// 只删严格早于保留期的旧桶，绝不删未来键
    private func pruneOld(_ cache: inout ClaudeUsageCache, now: Date) {
        pruneUTCHourBuckets(&cache.detailHours, olderThan: now.addingTimeInterval(-367 * 86400))
        pruneUTCHourBuckets(&cache.projectHours, olderThan: now.addingTimeInterval(-32 * 86400))
        pruneUTCHourBuckets(&cache.rawOutputByHour, olderThan: now.addingTimeInterval(-32 * 86400))
        let looseCutoff = now.addingTimeInterval(-30 * 86400).timeIntervalSince1970
        cache.looseEvents.removeAll { $0.time < looseCutoff }

        // 源文件被删掉了（Claude Code 自己清理）就别再占着游标缓存/触发时间缓存
        let fm = FileManager.default
        for key in Array(cache.fileCursors.keys) where !fm.fileExists(atPath: key) {
            cache.fileCursors.removeValue(forKey: key)
        }
        for key in Array(cache.lastTriggerByFile.keys) where !fm.fileExists(atPath: key) {
            cache.lastTriggerByFile.removeValue(forKey: key)
        }
    }

    /// 版本不符或解码失败只返回 nil，绝不在冷扫重建成功前删除旧 priorFile
    private func loadValidCache(from url: URL) -> ClaudeUsageCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(ClaudeUsageCache.self, from: data),
              cache.version == ClaudeUsageCache.currentVersion
        else {
            return nil
        }
        return cache
    }

    private func saveCache(_ cache: ClaudeUsageCache, to url: URL) {
        UsageCacheLocation.ensureDir()
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 速度（tok/s）的统计口径：界面和后端共用
enum SpeedRule {
    static let minOutputTokens: Int64 = 50
}
