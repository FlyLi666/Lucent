#if DEBUG
import Foundation

// `Lucent --usage-dump`：跑一次完整刷新（含额度），打印每个工具的可读摘要，带冷/热扫描耗时，然后退出。
// 不打印任何凭据；邮箱类字段按要求打码。
// `--usage-dump --cold`：额外把缓存目录指到一个全新的临时目录，强制走一次真正的冷扫描，
// 不碰 ~/Library/Caches/local.lucent.monitor/ 里真实的缓存——专门给"测冷扫描内存/CPU"用。

@MainActor
enum UsageDebugDump {
    static func run() async {
        let args = CommandLine.arguments
        if args.contains("--cold") {
            // 固定名字（不随机），方便多次调用接着跑同一个临时缓存，直到真的追完全部历史数据；
            // 想要真正从零开始就手动删掉这个目录
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lucent-usage-cold-test")
            UsageCacheLocation.debugOverrideDir = tmp
            print("[--cold] 缓存目录临时指到 \(tmp.path)，不碰真实缓存")
        }
        if let dbIndex = args.firstIndex(of: "--cursor-db"), args.indices.contains(dbIndex + 1) {
            CursorUsageReader.debugDatabasePath = args[dbIndex + 1]
            print("[--cursor-db] 只读副本 \(args[dbIndex + 1])")
        }
        if let homeIndex = args.firstIndex(of: "--home"), args.indices.contains(homeIndex + 1) {
            let home = URL(fileURLWithPath: args[homeIndex + 1]).standardizedFileURL
            UsageHome.debugOverride = home
            let suite = "local.lucent.monitor.usage-home-override"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            AccountPrefs.debugStore = defaults
            print("[--home] 家目录临时指到 \(home.path)，账号偏好用独立临时域")
        }

        let store = UsageStore.shared
        if args.contains("--accept-suggestions") {
            store.debugAcceptAllSuggestions()
            print("[--accept-suggestions] 已接受当前全部建议")
        }
        if let forgetIndex = args.firstIndex(of: "--forget-account"), args.indices.contains(forgetIndex + 1) {
            let id = args[forgetIndex + 1]
            store.forgetAccount(id)
            print("[--forget-account] \(id)")
        }
        if args.contains("--remember-pending") {
            await store.debugRefreshCursorIdentity()
            let pending = store.pendingLogins
            print("[--remember-pending] count=\(pending.count)")
            for login in pending { store.rememberLogin(login) }
        }
        let (coldMs, warmMs) = await store.debugTimedRefresh()

        print("=== Lucent usage dump ===")
        print(String(format: "cold scan: %.0f ms", coldMs))
        print(String(format: "warm incremental: %.0f ms", warmMs))
        print("")
        print("=== accounts ===")
        if store.accounts.isEmpty { print("(none)") }
        for account in store.accounts {
            let total = store.usage(account.tool, account: account.id).last30Tokens.total
            let email = account.maskedEmail ?? "nil"
            let dir = account.dir ?? "nil"
            print("id=\(account.id) tool=\(account.tool.rawValue) dir=\(dir) name=\(redact(account.displayName)) email=\(email) plan=\(account.plan ?? "nil") default=\(account.isDefault) hidden=\(account.hidden) last30=\(total)")
        }
        print("=== cursor accounts ===")
        let cursorAccounts = store.accounts.filter { $0.tool == .cursor }
        if cursorAccounts.isEmpty { print("(none)") }
        for account in cursorAccounts {
            let quotaText = account.quotas.map { item in
                "\(item.id)=\(String(format: "%.1f%%", item.usedFraction * 100))\(item.detail.map { " (\($0))" } ?? "")"
            }.joined(separator: ", ")
            print("id=\(account.id) email=\(account.maskedEmail ?? "nil") isCurrentLogin=\(account.isCurrentLogin) status=\(describe(account.status)) quotas=\(quotaText.isEmpty ? "none" : quotaText)")
        }
        print("=== pending logins ===")
        if store.pendingLogins.isEmpty { print("(none)") }
        for login in store.pendingLogins {
            print("id=\(login.id) tool=\(login.tool.rawValue) email=\(login.maskedEmail ?? "nil") plan=\(redact(login.plan ?? "nil"))")
        }
        print("cursor keychain ids: \(AccountVault.accountIDs().sorted().joined(separator: ", "))")
        print("=== suggestions ===")
        if store.suggestions.isEmpty { print("(none)") }
        for suggestion in store.suggestions {
            print("id=\(suggestion.id) tool=\(suggestion.tool.rawValue) dir=\(suggestion.dir)")
        }
        print("")

        for tool in AITool.allCases {
            let u = store.usage(tool)
            print("--- \(tool.title) (\(tool.rawValue)) ---")
            print("status: \(describe(u.status))")
            print("plan: \(redact(u.plan ?? "nil"))")
            print("costKind: \(u.costKind)")
            print("today: tokens=\(u.today.tokens.total) cost=$\(String(format: "%.4f", u.today.cost))")
            print("last30Tokens: \(u.last30Tokens.total) last30Cost: $\(String(format: "%.4f", u.last30Cost))")
            let last7 = u.daily.suffix(7)
            let last7Tokens = last7.reduce(Int64(0)) { $0 + $1.tokens.total }
            let last7Cost = last7.reduce(0.0) { $0 + $1.cost }
            print("last7Tokens: \(last7Tokens) last7Cost: $\(String(format: "%.4f", last7Cost))")
            print("daily.count: \(u.daily.count)")
            print("models: \(u.models.prefix(5).map { "\($0.model)=\($0.tokens)tok/$\(String(format: "%.4f", $0.cost))" }.joined(separator: ", "))")
            print("models (all, with request counts): \(u.models.map { "\($0.model)=\($0.tokens)tok/\($0.requests)req" }.joined(separator: ", "))")
            print("quotas: \(u.quotas.map { "\($0.id)=\(String(format: "%.1f%%", $0.usedFraction * 100))\($0.detail.map { " (\($0))" } ?? "")" }.joined(separator: ", "))")
            print("quotaUpdatedAt: \(u.quotaUpdatedAt.map(String.init(describing:)) ?? "nil")")
            print("lastActivity: \(u.lastActivity.map(String.init(describing:)) ?? "nil")")
            print(String(format: "tokensPerMinute: %.2f", u.tokensPerMinute))

            let requests30 = u.daily.reduce(0) { $0 + $1.requests }
            let cacheSavings30 = u.daily.reduce(0.0) { $0 + $1.cacheSavings }
            let cacheWrite1h30 = u.daily.reduce(Int64(0)) { $0 + $1.cacheWrite1h }
            print("30d requests=\(requests30) cacheSavings=$\(String(format: "%.4f", cacheSavings30)) cacheWrite1h=\(cacheWrite1h30)")

            print("top5 projects: \(u.projects.prefix(5).map { "\($0.project)=\($0.tokens.total)tok/\($0.requests)req" }.joined(separator: ", "))")
            print("hourly buckets: \(u.hourly.count)")

            // 今天每小时的 token 总量（从 hourlyDetail 按小时合并），给独立核对脚本按小时对比用
            let cal = Calendar.current
            let todayHourly = u.hourlyDetail.filter { cal.isDateInToday($0.start) }
            var byHour: [Int: Int64] = [:]
            for b in todayHourly { byHour[cal.component(.hour, from: b.start), default: 0] += b.tokens.total }
            print("today hourly (local hour -> tokens): \(byHour.sorted { $0.key < $1.key }.map { String(format: "%02d:00=%lld", $0.key, $0.value) }.joined(separator: ", "))")

            let firstNonZero = u.history.first { $0.tokens.total > 0 }
            print("history.count: \(u.history.count), first non-zero day: \(firstNonZero.map { String(describing: $0.day) } ?? "none")")

            print("newest 5 requests:")
            for r in u.recentRequests.prefix(5) {
                let dur = r.durationMs.map { "\($0)ms\(r.durationIsEstimate ? "~" : "")" } ?? "nil"
                print("  \(r.time) model=\(r.model) provider=\(r.provider) project=\(r.project ?? "nil") tokens=\(r.tokens.total) cost=$\(String(format: "%.4f", r.cost)) duration=\(dur)")
            }

            print("hourlyDetail.count: \(u.hourlyDetail.count), dailyDetail.count: \(u.dailyDetail.count)")

            var byProvider: [String: (tokens: Int64, cost: Double, requests: Int)] = [:]
            for b in u.dailyDetail {
                var e = byProvider[b.provider] ?? (0, 0, 0)
                e.tokens += b.tokens.total; e.cost += b.cost; e.requests += b.requests
                byProvider[b.provider] = e
            }
            print("per-provider totals (all history): \(byProvider.map { "\($0.key)=\($0.value.tokens)tok/$\(String(format: "%.4f", $0.value.cost))/\($0.value.requests)req" }.sorted().joined(separator: ", "))")

            // hourlyDetail 加总应该跟 daily 的近 30 天总量完全一致——内部自检，不是靠猜
            let hourlyDetailTokens30 = u.hourlyDetail.reduce(Int64(0)) { $0 + $1.tokens.total }
            let dailyTokens30 = u.daily.reduce(Int64(0)) { $0 + $1.tokens.total }
            print("hourlyDetail sum vs daily sum (30d): \(hourlyDetailTokens30) vs \(dailyTokens30), match=\(hourlyDetailTokens30 == dailyTokens30)")

            // 每个模型的耗时样本（来自 recentRequests，最多 1000 条，近似）：中位耗时 + 中位 tok/s
            var byModel: [String: [(ms: Int, outTok: Int64)]] = [:]
            for r in u.recentRequests {
                guard let ms = r.durationMs, ms > 0 else { continue }
                byModel[r.model, default: []].append((ms, r.tokens.output))
            }
            print("median duration/tok-s per model (sample from recentRequests):")
            for (model, samples) in byModel.sorted(by: { $0.key < $1.key }) {
                let durations = samples.map(\.ms).sorted()
                let medianMs = durations[durations.count / 2]
                let speeds = samples.compactMap { $0.ms > 0 ? Double($0.outTok) / (Double($0.ms) / 1000) : nil }.sorted()
                let medianSpeed = speeds.isEmpty ? 0 : speeds[speeds.count / 2]
                print(String(format: "  %@: n=%d medianDuration=%dms medianSpeed=%.1ftok/s", model, samples.count, medianMs, medianSpeed))
            }

            var pricingLines: [String] = []
            for p in u.pricing.prefix(3) {
                let inStr = p.input.map { String(format: "%.2f", $0) } ?? "nil"
                let outStr = p.output.map { String(format: "%.2f", $0) } ?? "nil"
                let creadStr = p.cacheRead.map { String(format: "%.2f", $0) } ?? "nil"
                pricingLines.append("\(p.model)[\(p.source)] in/out/cread=\(inStr)/\(outStr)/\(creadStr)")
            }
            print("pricing (first 3): \(pricingLines.joined(separator: "; "))")
            let breakdown = u.last30Tokens
            print("last30 breakdown: input=\(breakdown.input) output=\(breakdown.output) cacheRead=\(breakdown.cacheRead) cacheWrite=\(breakdown.cacheWrite) unsplit=\(breakdown.unsplit)")
            if let b = u.currentBlock {
                print("currentBlock: start=\(b.start.timeIntervalSince1970) end=\(b.end.timeIntervalSince1970) last=\(b.lastActivity.timeIntervalSince1970) input=\(b.tokens.input) output=\(b.tokens.output) cacheRead=\(b.tokens.cacheRead) cacheWrite=\(b.tokens.cacheWrite) unsplit=\(b.tokens.unsplit) total=\(b.tokens.total) requests=\(b.requests) active=\(b.isActive) tokPerMin=\(String(format: "%.4f", b.tokensPerMinute)) costPerHour=\(String(format: "%.6f", b.costPerHour)) projectedTokens=\(b.projectedTokens) projectedCost=\(String(format: "%.6f", b.projectedCost))")
            } else {
                print("currentBlock: none")
            }
            print("recentBlocks: \(u.recentBlocks.count)")
            print("peakBlockTokens: \(u.peakBlockTokens)")
            print("")
        }

        print(String(format: "todayCostTotal: $%.4f", store.todayCostTotal))
        let cursorStats = store.debugCursorColdStats()
        let cursorPeakMB = Double(cursorStats.peakBytes) / 1_048_576
        print("cursorEventRequests: \(cursorStats.requests)")
        print(String(format: "cursorPeakFootprintMB: %.1f", cursorPeakMB))
        print("")
        let fallback = await store.debugFallbackPricedModels()
        let codexFallback = await store.debugCodexFallbackPricedModels()
        let zeroCost = await store.debugOpenCodeZeroCostProviders()
        print("models priced by family fallback (Claude): \(fallback.sorted())")
        print("models priced by family fallback (Codex): \(codexFallback.sorted())")
        print("opencode providers/models with $0 recorded cost: \(zeroCost.sorted())")
        let dedupe = await store.debugClaudeOutputDedupe()
        let sqlite = await store.debugCodexSqliteBackfill()
        let backlog = await store.debugBacklog()
        print("claudeDedupe30 outputBefore=\(dedupe.before) outputAfter=\(dedupe.after)")
        print("codexSqliteBackfill threads=\(sqlite.threads) tokens=\(sqlite.tokens) cost=0 note=sqlite 补的历史只有总数，金额记 0")
        print("backlog claude=\(backlog.claude) opencode=\(backlog.opencode) codex=\(backlog.codex)")
    }

    private static func describe(_ status: UsageStatus) -> String {
        switch status {
        case .loading: return "loading"
        case .ok: return "ok"
        case .notInstalled: return "notInstalled"
        case .partial(let r): return "partial(\(redact(r)))"
        case .failed(let r): return "failed(\(redact(r)))"
        }
    }

    /// 把看起来像邮箱的子串打码，调试输出里不该出现真实邮箱
    private static func redact(_ s: String) -> String {
        guard let range = s.range(of: #"[^\s]+@[^\s]+"#, options: .regularExpression) else { return s }
        var result = s
        result.replaceSubrange(range, with: "[redacted-email]")
        return result
    }
}
#endif
