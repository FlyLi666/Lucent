import Foundation
import SQLite3

// Antigravity（CLI ~/.gemini/antigravity-cli 与桌面/IDE ~/.gemini/antigravity）本机用量读取器。
// 口径对齐 CC Switch (MIT)：
// 1. 只统计 transcript_full.jsonl 里 type=PLANNER_RESPONSE 且 status=DONE、token 非全零的记录；
//    同一 step_index 多次写出时以最新一条为准，跨轮按 session:step 去重并在重写时原位修正。
// 2. input_tokens 已不含缓存、output_tokens 已含思考，不二次加减。
// 3. 模型归属优先级：行上显式 model > 按 step 顺序继承的 Model Selection > 原生库 conversations/<id>.db
//    (steps.metadata.20.3 -> gen_metadata.data.1.{21,19})；都拿不到记 unknown，绝不猜测。
// 4. 耗时只取原生库真值（gen_metadata.data.1.{11+12} 或 steps.metadata.{7-1}）；
//    相邻 created_at 时间差估算实测约 302 tok/s（真值约 52 tok/s），失真不用；无真值留 nil（不进速度平均，界面显示「—」）。

struct AntigravityModelChange: Codable, Sendable, Equatable {
    var step: Int64
    var model: String
}

struct AntigravityPriorRecord: Codable, Sendable, Equatable {
    var time: Double
    var tokens: TokenCountsCodable
    var cost: Double
    var savings: Double
    var durationMs: Int?
    var model: String
    var project: String?
    var sessionID: String
}

struct AntigravityUsageCache: Codable, Sendable {
    static let currentVersion = 3
    var version: Int = AntigravityUsageCache.currentVersion
    var fileCursors: [String: FileCursor] = [:]
    var modelChangesBySession: [String: [AntigravityModelChange]] = [:]
    /// 原生库暂不可读时留着 unknown 的 step，记下当时原生库 mtime，等库更新后再补读一次模型与精确耗时
    var pendingNativeStepsBySession: [String: [Int64]] = [:]
    var nativeDbMtimeBySession: [String: Double] = [:]
    var records: [String: AntigravityPriorRecord] = [:]
    /// 按 UTC 整点键存最长 367 天（供应商 × 模型）聚合，不绑定写入时的本机时区
    var detailHours: [String: [String: [String: DetailBucket]]] = [:]
    /// 近 32 天按 UTC 整点存项目聚合
    var projectHours: [String: [String: ProjectBucket]] = [:]
    var recentRequests: [UsageRequestCodable] = []
    var lastActivity: Date?
}

struct AntigravityLocalResult: Sendable {
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

final class AntigravityUsageReader {
    static let provider = "Google"

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

    private let cacheFile = UsageCacheLocation.url("antigravity-usage-cache.json")
    private let rebuildCacheFile = UsageCacheLocation.url("antigravity-usage-cache.rebuild.json")
    private var recent = RecentEventWindow()

    private struct SessionSource {
        var sessionID: String
        var transcriptPath: String
        var rootDir: URL
        var project: String?
    }

    private struct ParsedPlannerStep {
        var step: Int64
        var timestamp: Date
        var explicitModel: String?
        var input: Int64
        var output: Int64
        var cacheRead: Int64
        var cacheWrite: Int64
    }

    func scan() -> AntigravityLocalResult {
        #if DEBUG
        Self.debugLastSpeedStats = DebugSpeedStats()
        #endif

        let fm = FileManager.default
        let geminiDir = UsageHome.url.appendingPathComponent(".gemini")
        let cliRoot = geminiDir.appendingPathComponent("antigravity-cli")
        let ideRoot = geminiDir.appendingPathComponent("antigravity")
        let roots = [cliRoot, ideRoot]

        guard roots.contains(where: { fm.fileExists(atPath: $0.path) }) else {
            return Self.emptyResult(.notInstalled)
        }

        UsageCacheLocation.ensureDir()
        let hasExistingFile = fm.fileExists(atPath: cacheFile.path)
        var cache: AntigravityUsageCache
        // 旧缓存版本不符或损坏时冷扫重建，全部追平前暂存 .rebuild 侧车，绝不提前删改磁盘上的旧缓存
        let rebuildingExisting: Bool
        if let validCache = loadValidCache(from: cacheFile) {
            cache = validCache
            rebuildingExisting = false
        } else if !hasExistingFile {
            cache = AntigravityUsageCache()
            rebuildingExisting = false
        } else if let stagedCache = loadValidCache(from: rebuildCacheFile) {
            cache = stagedCache
            rebuildingExisting = true
        } else {
            cache = AntigravityUsageCache()
            rebuildingExisting = true
        }
        // 缓存里的金额是按旧价表乘的；价按请求时间取，扫的时候用同一条记录的时间重算，不能把 $0 留着。
        repriceCachedRecords(&cache)
        let now = Date()
        let historyCutoff = now.addingTimeInterval(-365 * 86400)
        var lastActivity = cache.lastActivity
        var bytesBudget = 64 * 1024 * 1024
        var hitBudgetCap = false
        var eligibleFiles = 0
        var eligibleSuccesses = 0
        var readFailures = 0

        let sessions = Self.discoverSessions(roots: roots)
        // 补模型不占转录字节预算：预算用完就停掉后面的会话时，挂起的 step 也必须先读完。
        for source in sessions {
            backfillPendingNativeIfNeeded(source: source, cache: &cache)
        }
        for source in sessions {
            let path = source.transcriptPath
            let sid = source.sessionID

            if bytesBudget <= 0 {
                hitBudgetCap = true
                break
            }

            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let sizeNum = attrs[.size] as? NSNumber,
                  let inodeNum = attrs[.systemFileNumber] as? NSNumber
            else { continue }

            let size = sizeNum.int64Value
            let inode = inodeNum.uint64Value
            let mtimeSec = mtime.timeIntervalSince1970

            let transcriptUnchanged: Bool = {
                guard let prior = cache.fileCursors[path] else { return false }
                return prior.inode == inode && prior.size == size && prior.mtime == mtimeSec && prior.offset == size
            }()

            if transcriptUnchanged {
                if mtime >= historyCutoff {
                    eligibleFiles += 1
                    eligibleSuccesses += 1
                    backfillPendingNativeIfNeeded(source: source, cache: &cache)
                }
                continue
            }

            if mtime < historyCutoff {
                cache.fileCursors[path] = FileCursor(inode: inode, size: size, offset: size, mtime: mtimeSec)
                continue
            }

            eligibleFiles += 1

            // 文件被整份重写时从 0 重读，保留已落账的 records 由幂等对比原位更新
            var startOffset: Int64 = 0
            if let prior = cache.fileCursors[path], prior.inode == inode, prior.size <= size {
                startOffset = prior.offset
            }

            var modelChanges = cache.modelChangesBySession[sid] ?? []
            var doneByStep: [Int64: ParsedPlannerStep] = [:]

            guard let newOffset = IncrementalLineReader.readNewLines(at: path, from: startOffset, maxBytes: bytesBudget, onLine: { buf in
                if AntigravityLinePrefilter.isModelSelectionLine(buf) {
                    let line = String(decoding: buf, as: UTF8.self)
                    guard let obj = Self.decodeJSON(line),
                          (obj["type"] as? String) == "USER_INPUT",
                          let step = (obj["step_index"] as? NSNumber)?.int64Value, step >= 0
                    else { return }
                    if let content = obj["content"] as? String,
                       let model = Self.modelFromSettingsChange(content) {
                        Self.upsertModelChange(step: step, model: model, into: &modelChanges)
                    }
                    return
                }

                if AntigravityLinePrefilter.isDonePlannerLine(buf) {
                    let line = String(decoding: buf, as: UTF8.self)
                    guard let obj = Self.decodeJSON(line),
                          (obj["type"] as? String) == "PLANNER_RESPONSE",
                          (obj["status"] as? String) == "DONE",
                          let step = (obj["step_index"] as? NSNumber)?.int64Value, step >= 0
                    else { return }

                    let ts = (obj["created_at"] as? String).flatMap(Self.parseTimestamp) ?? mtime
                    let input = Self.nonNegativeInt64(obj["input_tokens"])
                    let output = Self.nonNegativeInt64(obj["output_tokens"])
                    let cacheRead = Self.nonNegativeInt64(obj["cache_read_tokens"])
                    let cacheWrite = Self.nonNegativeInt64(obj["cache_write_tokens"])
                    let explicitModel = Self.knownModel(obj["model"] as? String)

                    doneByStep[step] = ParsedPlannerStep(
                        step: step, timestamp: ts, explicitModel: explicitModel,
                        input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
                }
            }) else {
                readFailures += 1
                continue
            }
            eligibleSuccesses += 1

            if !modelChanges.isEmpty {
                cache.modelChangesBySession[sid] = modelChanges
            }

            let candidateSteps = doneByStep.values
                .filter { $0.timestamp >= historyCutoff && ($0.input > 0 || $0.output > 0 || $0.cacheRead > 0 || $0.cacheWrite > 0) }
                .sorted { $0.step < $1.step }

            if !candidateSteps.isEmpty {
                let stepNumbers = candidateSteps.map(\.step)
                let nativeInfo = Self.readNativeStepInfo(rootDir: source.rootDir, sessionID: sid, steps: stepNumbers)
                cache.nativeDbMtimeBySession[sid] = Self.nativeDbMtime(rootDir: source.rootDir, sessionID: sid)
                var stillPending = Set(cache.pendingNativeStepsBySession[sid] ?? [])

                for item in candidateSteps {
                    let dedupID = "\(sid):\(item.step)"
                    let prior = cache.records[dedupID]
                    let inherited = Self.inheritedModel(for: item.step, changes: modelChanges)
                    let native = nativeInfo[item.step]

                    let display: String
                    if let exp = item.explicitModel {
                        display = exp
                        stillPending.remove(item.step)
                    } else if let inh = inherited {
                        display = inh
                        stillPending.remove(item.step)
                    } else if let natModel = native?.model {
                        display = natModel
                        stillPending.remove(item.step)
                    } else if let prior, prior.model != "unknown" {
                        display = prior.model
                    } else {
                        display = "unknown"
                        stillPending.insert(item.step)
                    }

                    let model = AntigravityPricingTable.modelID(of: display)
                    // 只收原生库真值耗时；拿不到留 nil，不进速度平均、界面显示「—」
                    let durationMs = native?.durationMs ?? prior?.durationMs

                    let tc = TokenCountsCodable(input: item.input, output: item.output, cacheRead: item.cacheRead, cacheWrite: item.cacheWrite)
                    let (cost, savings) = AntigravityCost.compute(
                        model: model, at: item.timestamp, input: item.input, output: item.output,
                        cacheRead: item.cacheRead, cacheWrite: item.cacheWrite)
                    let project = source.project ?? prior?.project

                    let updated = AntigravityPriorRecord(
                        time: item.timestamp.timeIntervalSince1970, tokens: tc, cost: cost, savings: savings,
                        durationMs: durationMs,
                        model: model, project: project, sessionID: sid)

                    if prior == updated { continue }
                    if let prior {
                        Self.retract(prior, id: dedupID, cache: &cache)
                    }
                    Self.apply(updated, id: dedupID, into: &cache)

                    if prior == nil {
                        recent.add(item.timestamp, item.input + item.output)
                    }
                    if lastActivity == nil || item.timestamp > lastActivity! {
                        lastActivity = item.timestamp
                    }
                }

                if stillPending.isEmpty {
                    cache.pendingNativeStepsBySession.removeValue(forKey: sid)
                } else {
                    cache.pendingNativeStepsBySession[sid] = stillPending.sorted()
                }
            }

            bytesBudget -= Int(newOffset - startOffset)
            if newOffset < size { hitBudgetCap = true }
            cache.fileCursors[path] = FileCursor(inode: inode, size: size, offset: newOffset, mtime: mtimeSec)
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
                                       tool: .agy, now: now)
        let requests = cache.recentRequests.compactMap { $0.toContract() }
        let pricing = snap.models.map { Self.pricingEntry(for: $0.model) }
        let blocks = UsageBlocks.summarize(utcDetailHours: cache.detailHours, now: now)

        var result = AntigravityLocalResult(
            status: .ok, today: snap.today, daily: snap.daily, models: snap.models, history: snap.history,
            hourly: snap.hourly, recentRequests: requests, projects: snap.projects,
            hourlyDetail: snap.hourlyDetail, dailyDetail: snap.dailyDetail, pricing: pricing,
            lastActivity: lastActivity, tokensPerMinute: recent.tokensPerMinute(now: now))
        result.hasBacklog = hitBudgetCap
        result.currentBlock = blocks.current
        result.recentBlocks = blocks.recent
        result.peakBlockTokens = blocks.peak
        return result
    }

    static func pricingEntry(for model: String) -> PricingEntry {
        let (rate, source) = AntigravityPricingTable.rateWithSource(for: model)
        return PricingEntry(
            model: model, tool: .agy,
            input: rate.map { $0.input * 1_000_000 },
            output: rate.map { $0.output * 1_000_000 },
            cacheRead: rate.map { $0.cacheRead * 1_000_000 },
            cacheWrite5m: rate.map { $0.cacheWrite * 1_000_000 },
            cacheWrite1h: nil,
            source: source)
    }

    // MARK: - 记账与回撤

    private static func apply(_ rec: AntigravityPriorRecord, id: String, into cache: inout AntigravityUsageCache) {
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
            id: id, time: when, tool: AITool.agy.rawValue, model: rec.model,
            project: rec.project, sessionID: rec.sessionID, tokens: rec.tokens,
            cacheWrite1h: 0, cost: rec.cost, provider: provider,
            durationMs: rec.durationMs, durationIsEstimate: false)
        RequestRing.replace(req, into: &cache.recentRequests)
        cache.records[id] = rec
    }

    private static func retract(_ prior: AntigravityPriorRecord, id: String, cache: inout AntigravityUsageCache) {
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

    /// 已落账的记录按请求时间重算金额。模型名没变时也要做：旧价表把 Carbon / Hydrogen / Orchestrator 记成了 $0。
    private func repriceCachedRecords(_ cache: inout AntigravityUsageCache) {
        let ids = Array(cache.records.keys)
        for id in ids {
            guard let prior = cache.records[id] else { continue }
            let when = Date(timeIntervalSince1970: prior.time)
            let (cost, savings) = AntigravityCost.compute(
                model: prior.model, at: when,
                input: prior.tokens.input, output: prior.tokens.output,
                cacheRead: prior.tokens.cacheRead, cacheWrite: prior.tokens.cacheWrite)
            if cost == prior.cost && savings == prior.savings { continue }
            var updated = prior
            updated.cost = cost
            updated.savings = savings
            Self.retract(prior, id: id, cache: &cache)
            Self.apply(updated, id: id, into: &cache)
        }
    }

    private func backfillPendingNativeIfNeeded(source: SessionSource, cache: inout AntigravityUsageCache) {
        let sid = source.sessionID
        guard let pending = cache.pendingNativeStepsBySession[sid], !pending.isEmpty else { return }
        // 上次没补上时 mtime 往往也没变（库正被占用，或单条生成记录当时没读全）。挂起的 step 每次都再读。
        cache.nativeDbMtimeBySession[sid] = Self.nativeDbMtime(rootDir: source.rootDir, sessionID: sid)

        let nativeInfo = Self.readNativeStepInfo(rootDir: source.rootDir, sessionID: sid, steps: pending)
        guard !nativeInfo.isEmpty else { return }

        var remaining: [Int64] = []
        for step in pending {
            let id = "\(sid):\(step)"
            guard let prior = cache.records[id], let info = nativeInfo[step] else {
                remaining.append(step)
                continue
            }
            var updated = prior
            if let natModel = info.model {
                updated.model = AntigravityPricingTable.modelID(of: natModel)
                let (cost, savings) = AntigravityCost.compute(
                    model: updated.model, at: Date(timeIntervalSince1970: updated.time),
                    input: updated.tokens.input, output: updated.tokens.output,
                    cacheRead: updated.tokens.cacheRead, cacheWrite: updated.tokens.cacheWrite)
                updated.cost = cost
                updated.savings = savings
            } else {
                remaining.append(step)
            }
            if let exactMs = info.durationMs {
                updated.durationMs = exactMs
            }
            if updated != prior {
                Self.retract(prior, id: id, cache: &cache)
                Self.apply(updated, id: id, into: &cache)
            }
        }
        if remaining.isEmpty {
            cache.pendingNativeStepsBySession.removeValue(forKey: sid)
        } else {
            cache.pendingNativeStepsBySession[sid] = remaining
        }
    }

    // MARK: - 会话发现与文本字段解析

    private static func discoverSessions(roots: [URL]) -> [SessionSource] {
        let fm = FileManager.default
        var seenSessions = Set<String>()
        var result: [SessionSource] = []

        for root in roots {
            let brainDir = root.appendingPathComponent("brain")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: brainDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let canonicalBrain = brainDir.resolvingSymlinksInPath().path
            let canonicalPrefix = canonicalBrain.hasSuffix("/") ? canonicalBrain : canonicalBrain + "/"
            let projects = readSummaryProjects(at: root.appendingPathComponent("conversation_summaries.db"))

            guard let entries = try? fm.contentsOfDirectory(atPath: brainDir.path) else { continue }
            for id in entries.sorted() where validSessionID(id) {
                let transcriptURL = brainDir
                    .appendingPathComponent(id, isDirectory: true)
                    .appendingPathComponent(".system_generated/logs/transcript_full.jsonl")
                var fileIsDir: ObjCBool = false
                guard fm.fileExists(atPath: transcriptURL.path, isDirectory: &fileIsDir), !fileIsDir.boolValue else { continue }
                let resolvedPath = transcriptURL.resolvingSymlinksInPath().path
                // 不跟随跳出 brain 根目录的软链（与 agy.rs 一致）
                guard resolvedPath.hasPrefix(canonicalPrefix) else { continue }
                guard seenSessions.insert(id).inserted else { continue }
                result.append(SessionSource(
                    sessionID: id, transcriptPath: transcriptURL.standardizedFileURL.path,
                    rootDir: root, project: projects[id]))
            }
        }
        return result
    }

    private static func validSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D
        }
    }

    private static func readSummaryProjects(at dbURL: URL) -> [String: String] {
        guard FileManager.default.fileExists(atPath: dbURL.path),
              let db = ReadOnlySQLite(path: dbURL.path, busyTimeoutMs: 0) else { return [:] }
        var out: [String: String] = [:]
        db.query("SELECT conversation_id, workspace_uris FROM conversation_summaries") { row in
            guard let id = row.text(0, maxBytes: 256), validSessionID(id),
                  let urisRaw = row.text(1, maxBytes: 16_384), !urisRaw.isEmpty,
                  let data = urisRaw.data(using: .utf8),
                  let uris = try? JSONSerialization.jsonObject(with: data) as? [String],
                  let first = uris.first,
                  let url = URL(string: first), url.isFileURL
            else { return }
            let last = url.standardizedFileURL.lastPathComponent
            if !last.isEmpty && last != "/" {
                out[id] = last
            }
        }
        return out
    }

    /// 解析 `changed setting \`Model Selection\` from X to Y`；模型名本身含小数点，只以 `. ` / 换行 / 反引号截断。
    static func modelFromSettingsChange(_ content: String) -> String? {
        guard let marker = content.range(of: "Model Selection") else { return nil }
        let rest = content[marker.lowerBound...]
        guard let toRange = rest.range(of: " to ") else { return nil }
        let tail = rest[toRange.upperBound...]

        var end = tail.endIndex
        for sep in [". ", "\n", "`"] {
            if let r = tail.range(of: sep), r.lowerBound < end {
                end = r.lowerBound
            }
        }
        let raw = tail[..<end]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.caseInsensitiveCompare("none") == .orderedSame {
            return nil
        }
        return raw
    }

    private static func upsertModelChange(step: Int64, model: String, into list: inout [AntigravityModelChange]) {
        if let idx = list.firstIndex(where: { $0.step == step }) {
            list[idx].model = model
        } else {
            list.append(AntigravityModelChange(step: step, model: model))
            list.sort { $0.step < $1.step }
        }
    }

    private static func inheritedModel(for step: Int64, changes: [AntigravityModelChange]) -> String? {
        var matched: String?
        for change in changes {
            if change.step <= step { matched = change.model } else { break }
        }
        return matched
    }

    private static func knownModel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare("unknown") != .orderedSame
        else { return nil }
        return trimmed
    }

    private static func nonNegativeInt64(_ raw: Any?) -> Int64 {
        guard let v = (raw as? NSNumber)?.int64Value, v > 0 else { return 0 }
        return v
    }

    /// 兼容无小数、毫秒与 Go time.Time 的微秒/纳秒 RFC3339 时间戳
    static func parseTimestamp(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = ISO8601.parse(s) { return d }
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let afterDot = s.index(after: dot)
        var fracEnd = afterDot
        while fracEnd < s.endIndex, s[fracEnd].isNumber { fracEnd = s.index(after: fracEnd) }
        guard fracEnd > afterDot else { return nil }
        let digits = String(s[afterDot..<fracEnd])
        let milli = String((digits + "000").prefix(3))
        let normalized = String(s[..<dot]) + "." + milli + String(s[fracEnd...])
        return ISO8601.parse(normalized)
    }

    private static func decodeJSON(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - 原生会话库（模型补全 + 精确耗时）

    struct NativeStepInfo {
        var model: String?
        var durationMs: Int?
    }

    private static func nativeDbURL(rootDir: URL, sessionID: String) -> URL? {
        let dbURL = rootDir.appendingPathComponent("conversations").appendingPathComponent("\(sessionID).db")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dbURL.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let resolvedRoot = rootDir.resolvingSymlinksInPath().path
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        let resolvedDB = dbURL.resolvingSymlinksInPath().path
        guard resolvedDB.hasPrefix(prefix) else { return nil }
        return dbURL
    }

    private static func nativeDbMtime(rootDir: URL, sessionID: String) -> Double {
        guard let dbURL = nativeDbURL(rootDir: rootDir, sessionID: sessionID) else { return 0 }
        let fm = FileManager.default
        let dbMtime = ((try? fm.attributesOfItem(atPath: dbURL.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let walMtime = ((try? fm.attributesOfItem(atPath: dbURL.path + "-wal"))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return max(dbMtime, walMtime)
    }

    /// busyTimeoutMs=0：正在写的原生会话库绝不能卡住后台扫描。抢不到锁就改用 immutable，至少读到已检查点的生成记录。
    private static func readNativeStepInfo(rootDir: URL, sessionID: String, steps: [Int64]) -> [Int64: NativeStepInfo] {
        guard !steps.isEmpty, let dbURL = nativeDbURL(rootDir: rootDir, sessionID: sessionID) else { return [:] }
        let uniqueSteps = Array(Set(steps)).sorted()
        if let db = ReadOnlySQLite(path: dbURL.path, busyTimeoutMs: 0) {
            let info = loadNativeStepInfo(db: db, steps: uniqueSteps)
            if !info.isEmpty { return info }
        }
        guard let db = ReadOnlySQLite(path: dbURL.path, busyTimeoutMs: 0, immutable: true) else { return [:] }
        return loadNativeStepInfo(db: db, steps: uniqueSteps)
    }

    private static func loadNativeStepInfo(db: ReadOnlySQLite, steps: [Int64]) -> [Int64: NativeStepInfo] {
        let placeholders = Array(repeating: "?", count: steps.count).joined(separator: ",")

        var stepDecoded: [Int64: DecodedStepMeta] = [:]
        db.query("SELECT idx, metadata FROM steps WHERE step_type = 15 AND idx IN (\(placeholders))", bind: steps) { row in
            let idx = row.int64(0)
            guard let blob = row.antigravityBlob(1, maxBytes: 512 * 1024),
                  let meta = Self.decodeStepMetadata(blob)
            else { return }
            stepDecoded[idx] = meta
        }
        guard !stepDecoded.isEmpty else { return [:] }

        let genIndices = Array(Set(stepDecoded.values.compactMap(\.generationIndex))).sorted()
        var genDecoded: [Int64: DecodedGenMeta] = [:]
        if !genIndices.isEmpty {
            let genPlaceholders = Array(repeating: "?", count: genIndices.count).joined(separator: ",")
            db.query("SELECT idx, data FROM gen_metadata WHERE idx IN (\(genPlaceholders))", bind: genIndices) { row in
                let idx = row.int64(0)
                // 模型名在生成记录末尾；整段对话能到十几 MB，按 1MB 截断就补不出模型。
                guard let blob = row.antigravityBlob(1, maxBytes: 32 * 1024 * 1024),
                      let gen = Self.decodeGenerationMetadata(blob)
                else { return }
                genDecoded[idx] = gen
            }
        }

        var result: [Int64: NativeStepInfo] = [:]
        for (step, meta) in stepDecoded {
            let gen = meta.generationIndex.flatMap { genDecoded[$0] }
            let durationMs = gen?.durationMs ?? meta.durationMs
            let model = gen?.model
            if model != nil || durationMs != nil {
                result[step] = NativeStepInfo(model: model, durationMs: durationMs)
            }
        }
        return result
    }

    private struct DecodedStepMeta {
        var generationIndex: Int64?
        var durationMs: Int?
    }

    private struct DecodedGenMeta {
        var model: String?
        var durationMs: Int?
    }

    /// steps.metadata：field 1 = 创建 Timestamp，field 7 = 完成 Timestamp，field 20.3 = gen_metadata.idx（为 0 时标量省略）
    private static func decodeStepMetadata(_ data: Data) -> DecodedStepMeta? {
        guard let fields = AntigravityProto.parseFields(data) else { return nil }
        var startSec: Double?
        var endSec: Double?
        var genIndex: Int64?

        for f in fields where f.wireType == 2 {
            switch f.number {
            case 1:
                startSec = AntigravityProto.decodeTimestampOrDuration(f.bytes)
            case 7:
                endSec = AntigravityProto.decodeTimestampOrDuration(f.bytes)
            case 20:
                if let refFields = AntigravityProto.parseFields(f.bytes) {
                    var idx: UInt64 = 0
                    for rf in refFields where rf.number == 3 && rf.wireType == 0 {
                        idx = rf.varint
                    }
                    if let valid = Int64(exactly: idx) {
                        genIndex = valid
                    }
                }
            default:
                break
            }
        }

        var stepDurationMs: Int?
        if let s = startSec, let e = endSec, e > s {
            stepDurationMs = max(1, Int(((e - s) * 1000).rounded()))
        }
        return DecodedStepMeta(generationIndex: genIndex, durationMs: stepDurationMs)
    }

    /// gen_metadata.data：field 1 内 field 21 优先于 field 19 取模型；field 11（首字）+ field 12（流式）为精确耗时。
    /// field 1 里夹着整段对话，不能整段拷贝再解析，否则十几 MB 的记录既慢又补不出末尾的模型名。
    private static func decodeGenerationMetadata(_ data: Data) -> DecodedGenMeta? {
        var responseRange: Range<Int>?
        guard AntigravityProto.forEachField(in: data, { number, wire, _, range in
            if number == 1 && wire == 2 { responseRange = range }
        }) else { return nil }
        guard let responseRange else { return nil }

        var picked: [(number: UInt64, range: Range<Int>)] = []
        guard AntigravityProto.forEachField(in: data, range: responseRange, { number, wire, _, range in
            guard wire == 2, range.count > 0, range.count <= 4096,
                  number == 11 || number == 12 || number == 19 || number == 21 else { return }
            picked.append((number, range))
        }) else { return nil }

        var model19: String?
        var model21: String?
        var ttftSec: Double?
        var streamSec: Double?
        for item in picked {
            let slice = data.subdata(in: item.range)
            switch item.number {
            case 11:
                ttftSec = AntigravityProto.decodeTimestampOrDuration(slice)
            case 12:
                streamSec = AntigravityProto.decodeTimestampOrDuration(slice)
            case 19:
                model19 = String(data: slice, encoding: .utf8)
            case 21:
                model21 = String(data: slice, encoding: .utf8)
            default:
                break
            }
        }

        let pickedModel = [model21, model19].compactMap(knownModel).first
        var durationMs: Int?
        if ttftSec != nil || streamSec != nil {
            let total = (ttftSec ?? 0) + (streamSec ?? 0)
            if total > 0 {
                durationMs = max(1, Int((total * 1000).rounded()))
            }
        }
        return DecodedGenMeta(model: pickedModel, durationMs: durationMs)
    }

    // MARK: - 缓存清理与持久化

    private static func emptyResult(_ status: UsageStatus) -> AntigravityLocalResult {
        AntigravityLocalResult(
            status: status, today: DailyUsage(day: Calendar.current.startOfDay(for: Date())),
            daily: [], models: [], history: [], hourly: [], recentRequests: [], projects: [],
            hourlyDetail: [], dailyDetail: [], pricing: [],
            lastActivity: nil, tokensPerMinute: 0)
    }

    private func pruneOld(_ cache: inout AntigravityUsageCache, now: Date) {
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
    }

    private func loadValidCache(from url: URL) -> AntigravityUsageCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(AntigravityUsageCache.self, from: data),
              cache.version == AntigravityUsageCache.currentVersion
        else { return nil }
        return cache
    }

    private func saveCache(_ cache: AntigravityUsageCache, to url: URL) {
        UsageCacheLocation.ensureDir()
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 字节级前过滤与最小 Protobuf 解码

private enum AntigravityLinePrefilter {
    private static let plannerResponse = Array("\"PLANNER_RESPONSE\"".utf8)
    private static let statusDone = Array("\"DONE\"".utf8)
    private static let userInput = Array("\"USER_INPUT\"".utf8)
    private static let modelSelection = Array("Model Selection".utf8)

    static func isDonePlannerLine(_ buf: UnsafeRawBufferPointer) -> Bool {
        guard buf.count > 0, buf.count <= IncrementalLineReader.maxLineBytes else { return false }
        return hasBytes(buf, plannerResponse) && hasBytes(buf, statusDone)
    }

    static func isModelSelectionLine(_ buf: UnsafeRawBufferPointer) -> Bool {
        guard buf.count > 0, buf.count <= IncrementalLineReader.maxLineBytes else { return false }
        return hasBytes(buf, userInput) && hasBytes(buf, modelSelection)
    }

    private static func hasBytes(_ buf: UnsafeRawBufferPointer, _ pattern: [UInt8]) -> Bool {
        guard let base = buf.baseAddress, buf.count >= pattern.count else { return false }
        return pattern.withUnsafeBufferPointer { p in
            guard let pBase = p.baseAddress else { return false }
            return memmem(base, buf.count, pBase, p.count) != nil
        }
    }
}

private enum AntigravityProto {
    struct Field {
        var number: UInt64
        var wireType: Int
        var varint: UInt64 = 0
        var bytes: Data = Data()
    }

    static func parseFields(_ data: Data) -> [Field]? {
        var fields: [Field] = []
        let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return data.isEmpty }
            var pos = 0
            let count = raw.count
            while pos < count {
                guard let (tag, afterTag) = readVarint(base, pos: pos, count: count) else { return false }
                pos = afterTag
                let number = tag >> 3
                let wireType = Int(tag & 0x7)
                guard number > 0 else { return false }
                switch wireType {
                case 0:
                    guard let (val, afterVal) = readVarint(base, pos: pos, count: count) else { return false }
                    pos = afterVal
                    fields.append(Field(number: number, wireType: 0, varint: val))
                case 1:
                    guard pos + 8 <= count else { return false }
                    pos += 8
                case 2:
                    guard let (lenU64, afterLen) = readVarint(base, pos: pos, count: count),
                          lenU64 <= UInt64(count - afterLen) else { return false }
                    let len = Int(lenU64)
                    let sub = Data(bytes: base + afterLen, count: len)
                    pos = afterLen + len
                    fields.append(Field(number: number, wireType: 2, bytes: sub))
                case 5:
                    guard pos + 4 <= count else { return false }
                    pos += 4
                default:
                    return false
                }
            }
            return true
        }
        return ok ? fields : nil
    }

    /// 按字段号往下走，长度字段只给出在 `data` 里的范围，不把正文再拷一份。
    static func forEachField(in data: Data, range: Range<Int>? = nil, _ visit: (UInt64, Int, UInt64, Range<Int>) -> Void) -> Bool {
        let bounds = range ?? 0..<data.count
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return data.isEmpty }
            guard bounds.lowerBound >= 0, bounds.upperBound <= raw.count else { return false }
            var pos = bounds.lowerBound
            let end = bounds.upperBound
            while pos < end {
                guard let (tag, afterTag) = readVarint(base, pos: pos, count: end) else { return false }
                pos = afterTag
                let number = tag >> 3
                let wireType = Int(tag & 0x7)
                guard number > 0 else { return false }
                switch wireType {
                case 0:
                    guard let (val, afterVal) = readVarint(base, pos: pos, count: end) else { return false }
                    visit(number, 0, val, afterVal..<afterVal)
                    pos = afterVal
                case 1:
                    guard pos + 8 <= end else { return false }
                    pos += 8
                case 2:
                    guard let (lenU64, afterLen) = readVarint(base, pos: pos, count: end),
                          lenU64 <= UInt64(end - afterLen) else { return false }
                    let len = Int(lenU64)
                    let field = afterLen..<(afterLen + len)
                    visit(number, 2, 0, field)
                    pos = afterLen + len
                case 5:
                    guard pos + 4 <= end else { return false }
                    pos += 4
                default:
                    return false
                }
            }
            return true
        }
    }

    static func decodeTimestampOrDuration(_ data: Data) -> Double? {
        guard let fields = parseFields(data) else { return nil }
        var seconds: Int64 = 0
        var nanos: Int64 = 0
        for f in fields where f.wireType == 0 {
            if f.number == 1 { seconds = Int64(bitPattern: f.varint) }
            else if f.number == 2 { nanos = Int64(bitPattern: f.varint) }
        }
        return Double(seconds) + Double(nanos) / 1_000_000_000.0
    }

    private static func readVarint(_ base: UnsafePointer<UInt8>, pos: Int, count: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = pos
        while i < count {
            let byte = base[i]
            i += 1
            if shift >= 64 { return nil }
            if shift == 63 && byte > 1 { return nil }
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return (result, i)
            }
            shift += 7
        }
        return nil
    }
}

private extension ReadOnlySQLite.Row {
    func antigravityBlob(_ col: Int32, maxBytes: Int) -> Data? {
        let len = byteCount(col)
        guard len >= 0, len <= maxBytes else { return nil }
        if len == 0 { return Data() }
        guard let ptr = sqlite3_column_blob(stmt, col) else { return nil }
        return Data(bytes: ptr, count: len)
    }
}
