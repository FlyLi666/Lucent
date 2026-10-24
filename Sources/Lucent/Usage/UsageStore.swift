import Foundation

// AI 编程工具用量：对外的唯一入口。界面只认 UsageModels.swift 里的类型和这个类暴露的 API，
// 具体怎么读日志、查接口、算价格都在同目录其它文件里，对界面不可见。
//
// 刷新节奏：
//   可见时：本机日志 15 秒一次，额度接口最多 5 分钟一次（刚变可见且额度超过 2 分钟没刷新就立即补一次）
//   不可见：本机日志 10 分钟一次，不查网络
//   额度接口失败/429：保留上次好值，状态标 partial，退避间隔翻倍，封顶 30 分钟
//
// Claude Code 没有额度这一项：Lucent 不读 Claude 的任何登录凭据，也不查它的额度接口（第三方收集会话令牌违反 Anthropic 条款）。
// 只读本机 jsonl 统计 token/花费，quotas 永远是空数组、plan 永远是 nil，status 只看本机日志读得好不好。
// 下面"额度刷新"那一节现在只服务 Cursor 一家。

@MainActor @Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var tools: [ToolUsage]
    private(set) var accounts: [AIAccount] = []
    private(set) var suggestions: [AccountSuggestion] = []
    private(set) var pendingLogins: [PendingLogin] = []

    private let worker = UsageWorker()
    private var groups: [AccountDirectory.Group] = []
    /// 每个账号自己的用量。合计视图在 tools 里，按账号取用这个字典。
    private var accountUsages: [String: ToolUsage] = [:]
    private var visible = false
    private var loopTask: Task<Void, Never>?

    private var lastLocalRefresh: [AITool: Date] = [:]
    private var lastQuotaRefresh: [AITool: Date] = [:]
    private var quotaBackoff: [AITool: TimeInterval] = [:]
    private var localStatus: [AITool: UsageStatus] = [:]
    private var quotaFailureReason: [AITool: String] = [:]
    /// 设置里勾掉的工具不扫、不查网络；默认全开，UI 没调过 setEnabled 之前就是这样
    private var enabledTools: Set<AITool> = Set(AITool.allCases)
    /// 当前 Cursor 登录，令牌只在内存。点了记住才进钥匙串
    private var cursorSession: CursorAccount?
    private var vaultRecords: [String: AccountVault.Secret] = [:]
    private var cursorLive: [String: CursorLive] = [:]
    private var accountQuotaLast: [String: Date] = [:]
    private var accountQuotaBackoff: [String: TimeInterval] = [:]
    private var lastCursorEvents: [String: Date] = [:]

    private struct CursorLive {
        var quotas: [QuotaWindow] = []
        var quotaUpdatedAt: Date?
        var status: UsageStatus = .loading
        var plan: String?
    }

    private static let baseQuotaInterval: TimeInterval = 300
    private static let maxQuotaInterval: TimeInterval = 1800

    private init() {
        tools = AITool.allCases.map { tool in
            var u = ToolUsage(tool: tool)
            switch tool {
            case .claude: u.costKind = .apiEquivalent
            case .cursor: u.costKind = .billed
            case .opencode: u.costKind = .recorded
            case .codex: u.costKind = .apiEquivalent
            }
            return u
        }
        reloadAccounts()
        startLoop()
    }

    // MARK: 对外 API

    func usage(_ tool: AITool) -> ToolUsage {
        tools.first { $0.tool == tool } ?? ToolUsage(tool: tool)
    }

    /// account == nil 时是该工具全部未隐藏账号的合计，等于 tools 里那一份。
    func usage(_ tool: AITool, account: String?) -> ToolUsage {
        guard let account else { return usage(tool) }
        return accountUsages[account] ?? ToolUsage(tool: tool)
    }

    func addAccount(tool: AITool, dir: String) {
        guard tool == .claude || tool == .codex else { return }
        let path = AccountDirectory.standardize(dir)
        guard path != AccountDirectory.defaultDir(for: tool) else { return }
        AccountPrefs.undismiss(AccountSuggestion(tool: tool, dir: path).id)
        AccountPrefs.add(tool: tool, dir: path)
        reloadAccounts()
        scheduleRefresh(tool)
    }

    func acceptSuggestion(_ suggestion: AccountSuggestion) {
        AccountPrefs.undismiss(suggestion.id)
        AccountPrefs.add(tool: suggestion.tool, dir: suggestion.dir)
        reloadAccounts()
        scheduleRefresh(suggestion.tool)
    }

    func dismissSuggestion(_ suggestion: AccountSuggestion) {
        AccountPrefs.dismiss(suggestion.id)
        reloadAccounts()
    }

    /// 默认目录永远留着。去掉的是用户另外加入的目录；去掉之后不再当作新建议弹出来。
    func removeAccount(_ id: String) {
        guard let group = groups.first(where: { $0.account.id == id }) else { return }
        let fallback = AccountDirectory.defaultDir(for: group.account.tool)
        var removed = false
        for dir in group.dirs where dir != fallback {
            AccountPrefs.remove(tool: group.account.tool, dir: dir)
            AccountPrefs.dismiss(AccountSuggestion(tool: group.account.tool, dir: dir).id)
            removed = true
        }
        guard removed else { return }
        accountUsages[id] = nil
        reloadAccounts()
        scheduleRefresh(group.account.tool)
    }

    func setAlias(_ id: String, _ alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        AccountPrefs.setAlias(id, trimmed.isEmpty ? nil : trimmed)
        reloadAccounts()
    }

    /// 用户点了才把当前这份登录写进钥匙串。没对上当前登录就什么都不做
    func rememberLogin(_ login: PendingLogin) {
        guard login.tool == .cursor, let session = cursorSession, session.accountID == login.id else { return }
        let secret = AccountVault.Secret(accessToken: session.accessToken, refreshToken: session.refreshToken,
                                         userID: session.userID, email: session.email, membershipType: session.membershipType)
        guard AccountVault.save(id: login.id, secret: secret) else { return }
        vaultRecords[login.id] = secret
        AccountPrefs.clearCursorLoginSuppression(login.id)
        syncCursorAccounts()
        Task { [weak self] in
            guard let self, self.visible else { return }
            await self.refreshQuota(.cursor, force: true)
        }
    }

    /// 这次关掉提示；同一个账号 7 天内不再出现在 pendingLogins
    func dismissLogin(_ login: PendingLogin) {
        AccountPrefs.suppressCursorLogin(login.id)
        pendingLogins.removeAll { $0.id == login.id }
    }

    /// 删掉钥匙串里这一条。不是当前登录的，从账号列表拿掉；当前登录仍留在列表里（令牌只在内存）
    func forgetAccount(_ id: String) {
        AccountVault.delete(id: id)
        vaultRecords.removeValue(forKey: id)
        cursorLive.removeValue(forKey: id)
        accountQuotaLast.removeValue(forKey: id)
        accountQuotaBackoff.removeValue(forKey: id)
        lastCursorEvents.removeValue(forKey: id)
        accountUsages[id] = nil
        syncCursorAccounts()
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        guard let tool = (accounts.first { $0.id == id }?.tool) ?? groups.first(where: { $0.account.id == id })?.account.tool else {
            AccountPrefs.setHidden(id, hidden)
            reloadAccounts()
            return
        }
        AccountPrefs.setHidden(id, hidden)
        reloadAccounts()
        scheduleRefresh(tool)
    }

    var todayCostTotal: Double { tools.reduce(0) { $0 + $1.today.cost } }

    /// 卡片或主窗口开/关时调用一次
    func setVisible(_ v: Bool) {
        guard visible != v else { return }
        visible = v
        guard v else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.refreshLocalAll()
            await self.maybeRefreshQuotas(force: false, staleAfter: 120)
        }
    }

    func refreshNow() {
        Task { [weak self] in
            guard let self else { return }
            await self.refreshLocalAll()
            await self.maybeRefreshQuotas(force: true, staleAfter: 0)
        }
    }

    /// 设置页调用：只扫/只查勾选了的工具。没被勾的那些 ToolUsage 还留在 tools 里（下标不变），
    /// 就是不再刷新，状态停在上次的样子。重新勾上的尽快补刷一次，不等下一个自然周期。
    func setEnabled(_ enabled: Set<AITool>) {
        let newlyEnabled = enabled.subtracting(enabledTools)
        enabledTools = enabled
        guard !newlyEnabled.isEmpty else { return }
        for tool in newlyEnabled {
            lastLocalRefresh.removeValue(forKey: tool)
            lastQuotaRefresh.removeValue(forKey: tool)
        }
        Task { [weak self] in
            guard let self else { return }
            for tool in newlyEnabled where self.enabledTools.contains(tool) {
                await self.refreshLocal(tool)
            }
            await self.maybeRefreshQuotas(force: false, staleAfter: 0)
        }
    }

    // MARK: 调度循环

    private func startLoop() {
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func tick() async {
        let now = Date()
        let localInterval: TimeInterval = visible ? 15 : 600
        for tool in AITool.allCases where enabledTools.contains(tool) {
            let last = lastLocalRefresh[tool] ?? .distantPast
            if now.timeIntervalSince(last) >= localInterval {
                await refreshLocal(tool)
            }
        }
        guard visible else { return }
        for tool in [AITool.cursor] where enabledTools.contains(tool) {
            let interval = quotaBackoff[tool] ?? Self.baseQuotaInterval
            let last = lastQuotaRefresh[tool] ?? .distantPast
            if now.timeIntervalSince(last) >= interval {
                await refreshQuota(tool, force: false)
            }
        }
    }

    private func refreshLocalAll() async {
        for tool in AITool.allCases where enabledTools.contains(tool) { await refreshLocal(tool) }
    }

    private func maybeRefreshQuotas(force: Bool, staleAfter: TimeInterval) async {
        let now = Date()
        for tool in [AITool.cursor] where enabledTools.contains(tool) {
            let last = lastQuotaRefresh[tool] ?? .distantPast
            if force || now.timeIntervalSince(last) > staleAfter {
                await refreshQuota(tool, force: force)
            }
        }
    }

    // MARK: 本机日志刷新

    private func refreshLocal(_ tool: AITool) async {
        lastLocalRefresh[tool] = Date()
        switch tool {
        case .claude:
            // .utility：读 jsonl/sqlite 是磁盘+CPU 活，不该和 UI 抢前台优先级
            await refreshAccounts(.claude)
        case .cursor:
            await refreshCursorLocal()
        case .codex:
            await refreshAccounts(.codex)
        case .opencode:
            let result = await Task(priority: .utility) { await self.worker.scanOpenCodeLocal() }.value
            applyOpenCodeLocal(result)
            if result.hasBacklog { catchUpSoon(.opencode) }
        }
    }

    /// 还有积压（升级后重建缓存、一次写入大量日志）：5 秒后再读下一批，不管窗口开没开，
    /// 否则窗口关着时每 10 分钟才读 64 MB，重建要一个多小时
    private func catchUpSoon(_ tool: AITool) {
        let interval: TimeInterval = visible ? 15 : 600
        lastLocalRefresh[tool] = Date().addingTimeInterval(-interval + 5)
    }

    /// 默认目录按原来的 15 秒 / 10 分钟扫。另外加入的目录只在卡片或主窗口可见时扫，限量和增量跟默认目录一样。
    private func refreshAccounts(_ tool: AITool) async {
        reloadAccounts()
        let mine = groups.filter { $0.account.tool == tool }
        let toScan = mine.filter { !$0.account.hidden && (visible || $0.account.isDefault) }
        if tool == .claude { await worker.beginClaudeRound() }
        if tool == .codex { await worker.beginCodexRound() }
        var anyBacklog = false
        for group in toScan {
            let token = AccountCacheKey.token(for: group.account.id)
            switch tool {
            case .claude:
                let dirs = group.dirs
                let migrate = group.migrateLegacy
                let result = await Task(priority: .utility) {
                    await self.worker.scanClaude(dirs: dirs, cacheToken: token, migrateLegacy: migrate)
                }.value
                accountUsages[group.account.id] = Self.usage(from: result)
                anyBacklog = anyBacklog || result.hasBacklog
            case .codex:
                let dirs = group.dirs
                let migrate = group.migrateLegacy
                let result = await Task(priority: .utility) {
                    await self.worker.scanCodex(dirs: dirs, cacheToken: token, migrateLegacy: migrate)
                }.value
                accountUsages[group.account.id] = Self.usage(from: result)
                anyBacklog = anyBacklog || result.hasBacklog
            default:
                break
            }
        }
        let included = mine.filter { !$0.account.hidden }.compactMap { accountUsages[$0.account.id] }
        let i = idx(tool)
        let kind = tools[i].costKind
        if let merged = UsageMerge.combine(included) {
            tools[i] = merged
            tools[i].costKind = kind
            localStatus[tool] = merged.status
        } else {
            var empty = ToolUsage(tool: tool)
            empty.costKind = kind
            empty.status = .notInstalled
            tools[i] = empty
            localStatus[tool] = .notInstalled
        }
        recomputeStatus(tool)
        if anyBacklog { catchUpSoon(tool) }
    }

    private func reloadAccounts() {
        let snapshot = AccountDirectory.load()
        let cursor = accounts.filter { $0.tool == .cursor }
        accounts = snapshot.accounts + cursor
        suggestions = snapshot.suggestions
        groups = snapshot.groups
    }

    private func replaceCursorAccounts(_ cursor: [AIAccount]) {
        accounts = accounts.filter { $0.tool != .cursor } + cursor
    }

    private func scheduleRefresh(_ tool: AITool) {
        Task { [weak self] in
            guard let self else { return }
            await self.refreshLocal(tool)
        }
    }

    private static func usage(from result: ClaudeLocalResult) -> ToolUsage {
        var u = ToolUsage(tool: .claude)
        u.costKind = .apiEquivalent
        u.status = result.status
        u.today = result.today
        u.daily = result.daily
        u.models = result.models
        u.history = result.history
        u.hourly = result.hourly
        u.recentRequests = result.recentRequests
        u.projects = result.projects
        u.hourlyDetail = result.hourlyDetail
        u.dailyDetail = result.dailyDetail
        u.pricing = result.pricing
        u.lastActivity = result.lastActivity
        u.tokensPerMinute = result.tokensPerMinute
        u.currentBlock = result.currentBlock
        u.recentBlocks = result.recentBlocks
        u.peakBlockTokens = result.peakBlockTokens
        return u
    }

    private static func usage(from result: CodexLocalResult) -> ToolUsage {
        var u = ToolUsage(tool: .codex)
        u.costKind = .apiEquivalent
        u.status = result.status
        u.today = result.today
        u.daily = result.daily
        u.models = result.models
        u.history = result.history
        u.hourly = result.hourly
        u.recentRequests = result.recentRequests
        u.projects = result.projects
        u.hourlyDetail = result.hourlyDetail
        u.dailyDetail = result.dailyDetail
        u.pricing = result.pricing
        u.quotas = result.quotas
        if !result.quotas.isEmpty { u.quotaUpdatedAt = result.lastActivity }
        u.lastActivity = result.lastActivity
        u.tokensPerMinute = result.tokensPerMinute
        u.currentBlock = result.currentBlock
        u.recentBlocks = result.recentBlocks
        u.peakBlockTokens = result.peakBlockTokens
        return u
    }

    private func applyOpenCodeLocal(_ result: OpenCodeLocalResult) {
        let i = idx(.opencode)
        tools[i].today = result.today
        tools[i].daily = result.daily
        tools[i].models = result.models
        tools[i].history = result.history
        tools[i].hourly = result.hourly
        tools[i].recentRequests = result.recentRequests
        tools[i].projects = result.projects
        tools[i].hourlyDetail = result.hourlyDetail
        tools[i].dailyDetail = result.dailyDetail
        tools[i].pricing = result.pricing
        tools[i].lastActivity = result.lastActivity
        tools[i].tokensPerMinute = result.tokensPerMinute
        tools[i].currentBlock = result.currentBlock
        tools[i].recentBlocks = result.recentBlocks
        tools[i].peakBlockTokens = result.peakBlockTokens
        localStatus[.opencode] = result.status
        recomputeStatus(.opencode)
    }

    private func refreshCursorLocal() async {
        vaultRecords = AccountVault.loadAll()
        guard await worker.isCursorInstalled else {
            cursorSession = nil
            if vaultRecords.isEmpty {
                localStatus[.cursor] = .notInstalled
                pendingLogins = []
                replaceCursorAccounts([])
            } else {
                localStatus[.cursor] = .ok
                syncCursorAccounts()
                await publishCursorUsage()
            }
            recomputeStatus(.cursor)
            return
        }
        cursorSession = await worker.readCursorAccount()
        if cursorSession == nil && vaultRecords.isEmpty {
            localStatus[.cursor] = .failed("未检测到 Cursor 登录账号")
            pendingLogins = []
            replaceCursorAccounts([])
            recomputeStatus(.cursor)
            return
        }
        let i = idx(.cursor)
        if let membership = cursorSession?.membershipType, !membership.isEmpty, tools[i].plan == nil {
            tools[i].plan = "Cursor " + membership.capitalized
        }
        localStatus[.cursor] = .ok
        syncCursorAccounts()
        await publishCursorUsage()
        recomputeStatus(.cursor)
    }

    // MARK: 额度刷新

    private func refreshQuota(_ tool: AITool, force: Bool) async {
        lastQuotaRefresh[tool] = Date()
        switch tool {
        case .claude, .opencode, .codex:
            break // Claude 不读凭据、不查额度；OpenCode 没有额度接口；Codex 的额度从本机日志里读，不联网
        case .cursor:
            await refreshCursorQuotas(force: force)
        }
    }

    /// 合计视图的 quotas 只跟当前登录走。记住的其他账号用钥匙串里自己的令牌，互不影响。
    /// 逐条用量和额度走同一轮：不可见时根本进不来；自动刷新最快 5 分钟一次。当前登录不换令牌。
    private func refreshCursorQuotas(force: Bool) async {
        cursorSession = await worker.readCursorAccount() ?? cursorSession
        vaultRecords = AccountVault.loadAll()
        let currentID = cursorSession?.accountID

        if let current = cursorSession {
            syncCurrentTokenIntoVault(current)
            await refreshOneCursor(id: current.accountID, account: current, allowRefresh: false, force: force)
        } else {
            applyCursorQuota(CursorQuotaResult(quotas: [], plan: nil, failureReason: "未找到 Cursor 登录信息"))
        }

        let others = vaultRecords.filter { $0.key != currentID }
        for (id, secret) in others {
            if !force && !accountDue(id) { continue }
            await refreshOneCursor(id: id, account: secret.cursorAccount(), allowRefresh: true, force: force)
        }
        syncCursorAccounts()
        await publishCursorUsage()
    }

    private func refreshOneCursor(id: String, account: CursorAccount, allowRefresh: Bool, force: Bool) async {
        let outcome = await worker.fetchCursorQuota(account, allowRefresh: allowRefresh)
        let isCurrent = id == cursorSession?.accountID
        if isCurrent { applyCursorQuota(outcome.result) }
        if allowRefresh && outcome.result.failureReason == nil {
            adoptRotation(originalUser: account.userID, updated: outcome.account)
        }
        recordCursorResult(id, outcome.result)

        var failed = outcome.result.failureReason != nil
        if !failed && cursorEventsDue(id, force: force) {
            lastCursorEvents[id] = Date()
            let synced = await worker.syncCursorEvents(account: outcome.account, allowRefresh: allowRefresh,
                                                        cacheToken: AccountCacheKey.token(for: id))
            if allowRefresh && synced.failureReason == nil {
                adoptRotation(originalUser: account.userID, updated: synced.account)
            }
            if let reason = synced.failureReason {
                failed = true
                var live = cursorLive[id] ?? CursorLive()
                live.status = .partial(reason)
                cursorLive[id] = live
                if isCurrent {
                    quotaFailureReason[.cursor] = reason
                    quotaBackoff[.cursor] = min((quotaBackoff[.cursor] ?? Self.baseQuotaInterval) * 2, Self.maxQuotaInterval)
                    recomputeStatus(.cursor)
                }
            }
        }
        if !isCurrent { noteAccountQuota(id, failed: failed) }
    }

    /// 自动拉逐条用量最快 5 分钟一次。用户手动刷新和调试冷拉可以 force。
    private func cursorEventsDue(_ id: String, force: Bool) -> Bool {
        if force { return true }
        let interval = accountQuotaBackoff[id] ?? Self.baseQuotaInterval
        let last = lastCursorEvents[id] ?? .distantPast
        return Date().timeIntervalSince(last) >= interval
    }

    /// 各账号一份用量。合计把未隐藏的账号相加；同一个账号 id 只出现一次。额度仍用当前登录那份。
    private func publishCursorUsage() async {
        let cursorAccounts = accounts.filter { $0.tool == .cursor }
        guard !cursorAccounts.isEmpty else { return }
        var parts: [ToolUsage] = []
        for account in cursorAccounts {
            var usage = await worker.cachedCursorUsage(cacheToken: AccountCacheKey.token(for: account.id))
            if let live = cursorLive[account.id] {
                usage.quotas = live.quotas
                usage.quotaUpdatedAt = live.quotaUpdatedAt
                if let plan = live.plan { usage.plan = plan }
                usage.status = live.status
            }
            usage.costKind = .billed
            accountUsages[account.id] = usage
            if !account.hidden { parts.append(usage) }
        }
        let valid = Set(cursorAccounts.map(\.id))
        for id in accountUsages.keys where id.hasPrefix("cursor:") && !valid.contains(id) {
            accountUsages[id] = nil
        }

        let i = idx(.cursor)
        let quotas = tools[i].quotas
        let quotaAt = tools[i].quotaUpdatedAt
        let plan = tools[i].plan
        if let merged = UsageMerge.combine(parts) {
            tools[i] = merged
        }
        tools[i].quotas = quotas
        tools[i].quotaUpdatedAt = quotaAt
        if let plan { tools[i].plan = plan }
        tools[i].costKind = .billed
        recomputeStatus(.cursor)
    }

    /// 这个账号正在被 Cursor 登录着：钥匙串跟 state.vscdb 保持同一份，不另走刷新
    private func syncCurrentTokenIntoVault(_ current: CursorAccount) {
        let id = current.accountID
        guard var secret = vaultRecords[id] else { return }
        guard secret.accessToken != current.accessToken || secret.refreshToken != current.refreshToken else { return }
        secret.accessToken = current.accessToken
        secret.refreshToken = current.refreshToken
        if let email = current.email { secret.email = email }
        if let membership = current.membershipType { secret.membershipType = membership }
        guard AccountVault.save(id: id, secret: secret) else { return }
        vaultRecords[id] = secret
    }

    private func adoptRotation(originalUser: String, updated: CursorAccount) {
        guard updated.userID == originalUser else { return }
        if cursorSession?.userID == updated.userID {
            cursorSession = updated
        }
        let id = updated.accountID
        guard var secret = vaultRecords[id] else { return }
        guard secret.accessToken != updated.accessToken || secret.refreshToken != updated.refreshToken else { return }
        secret.accessToken = updated.accessToken
        if let refresh = updated.refreshToken { secret.refreshToken = refresh }
        if let email = updated.email { secret.email = email }
        if let membership = updated.membershipType { secret.membershipType = membership }
        guard AccountVault.save(id: id, secret: secret) else { return }
        vaultRecords[id] = secret
    }

    private func recordCursorResult(_ id: String, _ result: CursorQuotaResult) {
        var live = cursorLive[id] ?? CursorLive()
        if let plan = result.plan { live.plan = plan }
        if let reason = result.failureReason {
            live.status = .partial(reason)
        } else {
            live.status = .ok
            live.quotas = result.quotas
            live.quotaUpdatedAt = Date()
        }
        cursorLive[id] = live
    }

    private func accountDue(_ id: String) -> Bool {
        let interval = accountQuotaBackoff[id] ?? Self.baseQuotaInterval
        let last = accountQuotaLast[id] ?? .distantPast
        return Date().timeIntervalSince(last) >= interval
    }

    private func noteAccountQuota(_ id: String, failed: Bool) {
        accountQuotaLast[id] = Date()
        if failed {
            accountQuotaBackoff[id] = min((accountQuotaBackoff[id] ?? Self.baseQuotaInterval) * 2, Self.maxQuotaInterval)
        } else {
            accountQuotaBackoff[id] = nil
        }
    }

    private func syncCursorAccounts() {
        var cursor: [AIAccount] = []
        var seen = Set<String>()
        if let current = cursorSession {
            let id = current.accountID
            seen.insert(id)
            let secret = vaultRecords[id]
            cursor.append(makeCursorAccount(id: id, email: current.email ?? secret?.email,
                                            membership: current.membershipType ?? secret?.membershipType, isCurrent: true))
        }
        for id in vaultRecords.keys.sorted() where !seen.contains(id) {
            let secret = vaultRecords[id]!
            cursor.append(makeCursorAccount(id: id, email: secret.email, membership: secret.membershipType, isCurrent: false))
        }
        replaceCursorAccounts(cursor)

        guard let current = cursorSession else {
            pendingLogins = []
            return
        }
        let id = current.accountID
        if vaultRecords[id] == nil && !AccountPrefs.cursorLoginSuppressed(id) {
            let account = cursor.first { $0.id == id }
            pendingLogins = [PendingLogin(tool: .cursor, maskedEmail: account?.maskedEmail, plan: account?.plan, id: id)]
        } else {
            pendingLogins = []
        }
    }

    private func makeCursorAccount(id: String, email: String?, membership: String?, isCurrent: Bool) -> AIAccount {
        let masked = email.flatMap { AccountDirectory.maskEmail($0) }
        let live = cursorLive[id]
        let plan = live?.plan ?? membership.map { "Cursor " + $0.capitalized }
        let display = AccountPrefs.alias(for: id) ?? masked ?? "Cursor"
        return AIAccount(id: id, tool: .cursor, dir: nil, displayName: display, maskedEmail: masked, plan: plan,
                         isDefault: false, hidden: AccountPrefs.isHidden(id), isCurrentLogin: isCurrent,
                         quotas: live?.quotas ?? [], quotaUpdatedAt: live?.quotaUpdatedAt, status: live?.status ?? .loading)
    }

    private func applyCursorQuota(_ result: CursorQuotaResult) {
        let i = idx(.cursor)
        if let plan = result.plan { tools[i].plan = plan }
        if let reason = result.failureReason {
            quotaFailureReason[.cursor] = reason
            quotaBackoff[.cursor] = min((quotaBackoff[.cursor] ?? Self.baseQuotaInterval) * 2, Self.maxQuotaInterval)
        } else {
            quotaFailureReason.removeValue(forKey: .cursor)
            quotaBackoff[.cursor] = nil
            tools[i].quotas = result.quotas
            tools[i].quotaUpdatedAt = Date()
        }
        recomputeStatus(.cursor)
    }

    // MARK: 状态合成

    private func recomputeStatus(_ tool: AITool) {
        let i = idx(tool)
        let local = localStatus[tool] ?? .loading
        switch local {
        case .notInstalled: tools[i].status = .notInstalled
        case .failed(let reason): tools[i].status = .failed(reason)
        case .loading: tools[i].status = .loading
        case .partial(let reason): tools[i].status = .partial(reason)
        case .ok:
            if let reason = quotaFailureReason[tool] {
                tools[i].status = .partial(reason)
            } else {
                tools[i].status = .ok
            }
        }
    }

    private func idx(_ tool: AITool) -> Int {
        tools.firstIndex { $0.tool == tool }!
    }

    #if DEBUG
    /// 调试harness用：直接 await 两轮完整刷新，量出冷/热耗时（不靠 sleep 猜）
    func debugTimedRefresh() async -> (coldMs: Double, warmMs: Double) {
        // dump 要打出每个账号的 30 天合计，非默认账号只在可见时才扫
        visible = true
        await worker.resetCursorDebug()
        var peak = UsageFootprint.bytes()
        let t0 = CFAbsoluteTimeGetCurrent()
        await refreshLocalAll()
        peak = max(peak, UsageFootprint.bytes())
        await maybeRefreshQuotas(force: true, staleAfter: 0)
        peak = max(peak, UsageFootprint.bytes(), await worker.cursorPeakFootprint)
        let coldMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        debugColdCursorRequests = await worker.cursorEventRequests
        debugColdPeakBytes = peak

        await worker.resetCursorDebug()
        let t1 = CFAbsoluteTimeGetCurrent()
        await refreshLocalAll()
        await maybeRefreshQuotas(force: true, staleAfter: 0)
        let warmMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        return (coldMs, warmMs)
    }

    private var debugColdCursorRequests = 0
    private var debugColdPeakBytes: UInt64 = 0

    func debugCursorColdStats() -> (requests: Int, peakBytes: UInt64) {
        (debugColdCursorRequests, debugColdPeakBytes)
    }

    func debugFallbackPricedModels() async -> Set<String> { await worker.fallbackPricedModels }
    func debugCodexFallbackPricedModels() async -> Set<String> { await worker.codexFallbackPricedModels }
    func debugOpenCodeZeroCostProviders() async -> Set<String> { await worker.openCodeZeroCostProviders }
    func debugClaudeOutputDedupe() async -> (before: Int64, after: Int64) { await worker.debugClaudeOutputDedupe() }
    func debugCodexSqliteBackfill() async -> (threads: Int, tokens: Int64) { await worker.debugCodexSqliteBackfill() }
    func debugBacklog() async -> (claude: Bool, opencode: Bool, codex: Bool) { await worker.debugBacklog() }

    func debugRefreshCursorIdentity() async {
        visible = true
        await refreshCursorLocal()
    }

    func debugAcceptAllSuggestions() {
        let pending = suggestions
        for suggestion in pending {
            AccountPrefs.undismiss(suggestion.id)
            AccountPrefs.add(tool: suggestion.tool, dir: suggestion.dir)
        }
        reloadAccounts()
    }
    #endif
}
