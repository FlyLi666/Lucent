import Foundation

// 所有解析/查网络/读 sqlite 的活都在这个 actor 里，绝不占主线程。
// UsageStore（@MainActor）只管调度和把结果搬到界面能读的 ToolUsage 上。

actor UsageWorker {
    private var claudeReaders: [String: ClaudeCodeUsageReader] = [:]
    private let cursorReader = CursorUsageReader()
    private let openCodeReader = OpenCodeUsageReader()
    private var codexReaders: [String: CodexUsageReader] = [:]

    /// 调试harness用：记录哪些型号是按家族回退定价的，供 --usage-dump 打印
    private(set) var fallbackPricedModels: Set<String> = []
    private(set) var codexFallbackPricedModels: Set<String> = []
    private(set) var openCodeZeroCostProviders: Set<String> = []
    private var claudeBacklog = false
    private var opencodeBacklog = false
    private var codexBacklog = false
    private var cursorLogs: [String: CursorEventLog] = [:]
    private(set) var cursorEventRequests = 0
    private(set) var cursorPeakFootprint: UInt64 = 0

    // MARK: Claude Code

    func beginClaudeRound() { claudeBacklog = false }

    func scanClaude(dirs: [String], cacheToken: String, migrateLegacy: Bool) -> ClaudeLocalResult {
        let projects = dirs.map { URL(fileURLWithPath: $0).appendingPathComponent("projects") }
        let reader: ClaudeCodeUsageReader
        if let existing = claudeReaders[cacheToken] {
            existing.retarget(projectDirs: projects)
            reader = existing
        } else {
            reader = ClaudeCodeUsageReader(projectDirs: projects, cacheToken: cacheToken, migrateLegacy: migrateLegacy)
            claudeReaders[cacheToken] = reader
        }
        let result = reader.scan()
        fallbackPricedModels.formUnion(result.fallbackPricedModels)
        claudeBacklog = claudeBacklog || result.hasBacklog
        return result
    }

    // MARK: Codex

    func beginCodexRound() { codexBacklog = false }

    func scanCodex(dirs: [String], cacheToken: String, migrateLegacy: Bool) -> CodexLocalResult {
        let homes = dirs.map { URL(fileURLWithPath: $0) }
        let reader: CodexUsageReader
        if let existing = codexReaders[cacheToken] {
            existing.retarget(homes: homes)
            reader = existing
        } else {
            reader = CodexUsageReader(homes: homes, cacheToken: cacheToken, migrateLegacy: migrateLegacy)
            codexReaders[cacheToken] = reader
        }
        let result = reader.scan()
        codexFallbackPricedModels.formUnion(result.fallbackPricedModels)
        codexBacklog = codexBacklog || result.hasBacklog
        return result
    }

    // MARK: Cursor

    var isCursorInstalled: Bool { cursorReader.isInstalled }

    func readCursorAccount() -> CursorAccount? {
        cursorReader.readAccount()
    }

    func fetchCursorQuota(_ account: CursorAccount, allowRefresh: Bool) async -> CursorFetchOutcome {
        await cursorReader.fetchQuota(account: account, allowRefresh: allowRefresh)
    }

    func resetCursorDebug() {
        cursorEventRequests = 0
        cursorPeakFootprint = 0
    }

    func cachedCursorUsage(cacheToken: String) -> ToolUsage {
        cursorLog(cacheToken).cachedUsage()
    }

    func syncCursorEvents(account: CursorAccount, allowRefresh: Bool, cacheToken: String) async -> CursorSyncOutcome {
        let outcome = await cursorLog(cacheToken).sync(account: account, allowRefresh: allowRefresh)
        cursorEventRequests += outcome.httpRequests
        cursorPeakFootprint = max(cursorPeakFootprint, outcome.peakBytes)
        return outcome
    }

    private func cursorLog(_ cacheToken: String) -> CursorEventLog {
        if let existing = cursorLogs[cacheToken] { return existing }
        let created = CursorEventLog(cacheToken: cacheToken, reader: cursorReader)
        cursorLogs[cacheToken] = created
        return created
    }

    // MARK: OpenCode

    func scanOpenCodeLocal() -> OpenCodeLocalResult {
        let result = openCodeReader.scan()
        openCodeZeroCostProviders.formUnion(result.zeroCostProviders)
        opencodeBacklog = result.hasBacklog
        return result
    }

    func debugClaudeOutputDedupe() -> (before: Int64, after: Int64) {
        var before: Int64 = 0
        var after: Int64 = 0
        for reader in claudeReaders.values {
            before += reader.debugOutputBefore30
            after += reader.debugOutputAfter30
        }
        return (before, after)
    }

    func debugCodexSqliteBackfill() -> (threads: Int, tokens: Int64) {
        var threads = 0
        var tokens: Int64 = 0
        for reader in codexReaders.values {
            threads += reader.debugSqliteThreads
            tokens += reader.debugSqliteTokens
        }
        return (threads, tokens)
    }

    func debugBacklog() -> (claude: Bool, opencode: Bool, codex: Bool) {
        (claudeBacklog, opencodeBacklog, codexBacklog)
    }
}
