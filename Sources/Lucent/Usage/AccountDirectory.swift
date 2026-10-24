import CryptoKit
import Foundation

// 多账号发现与偏好。一个目录 = 一个账号；同一 Claude accountUuid 的多个目录合成一个。
// Claude 身份只读 `<目录>/.claude.json`（默认目录读 `<家目录>/.claude.json`）里
// oauthAccount 的 emailAddress / displayName / organizationName / accountUuid。
// 不读 .credentials.json、钥匙串、config.json。

enum AccountPrefs {
    static let added = "accounts.added"
    static let dismissed = "accounts.dismissed"
    static let aliases = "accounts.aliases"
    static let hidden = "accounts.hidden"

    struct DirRef: Codable, Equatable, Sendable {
        var tool: String
        var dir: String
    }

    #if DEBUG
    /// `--home` 时指到独立的 UserDefaults 域，避免把临时目录写进真正的偏好
    static var debugStore: UserDefaults?
    #endif

    static var store: UserDefaults {
        #if DEBUG
        if let debugStore { return debugStore }
        #endif
        return .standard
    }

    static func addedDirs() -> [DirRef] {
        guard let data = store.data(forKey: added),
              let refs = try? JSONDecoder().decode([DirRef].self, from: data) else { return [] }
        return refs
    }

    static func add(tool: AITool, dir: String) {
        var refs = addedDirs()
        let ref = DirRef(tool: tool.rawValue, dir: dir)
        guard !refs.contains(ref) else { return }
        refs.append(ref)
        save(refs, key: added)
    }

    static func remove(tool: AITool, dir: String) {
        let refs = addedDirs().filter { !($0.tool == tool.rawValue && $0.dir == dir) }
        save(refs, key: added)
    }

    static func dismissedIDs() -> Set<String> {
        guard let data = store.data(forKey: dismissed),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    static func dismiss(_ id: String) {
        var ids = dismissedIDs()
        guard ids.insert(id).inserted else { return }
        save(Array(ids).sorted(), key: dismissed)
    }

    static func undismiss(_ id: String) {
        let ids = dismissedIDs()
        guard ids.contains(id) else { return }
        save(Array(ids.subtracting([id])).sorted(), key: dismissed)
    }

    static func alias(for id: String) -> String? {
        aliasesMap()[id]
    }

    static func setAlias(_ id: String, _ alias: String?) {
        var map = aliasesMap()
        if let alias, !alias.isEmpty { map[id] = alias } else { map.removeValue(forKey: id) }
        save(map, key: aliases)
    }

    /// Cursor 登录提示被关掉之后的到期时间（Unix 秒）。这里只有账号 id，没有令牌
    static let cursorLoginDismissed = "accounts.cursorLoginDismissedUntil"

    static func cursorLoginSuppressed(_ id: String, now: Date = Date()) -> Bool {
        guard let until = cursorDismissMap()[id] else { return false }
        return until > now.timeIntervalSince1970
    }

    /// 本次不再提示，并且 7 天内同一账号不再提示
    static func suppressCursorLogin(_ id: String, days: Double = 7, now: Date = Date()) {
        var map = cursorDismissMap()
        map[id] = now.addingTimeInterval(days * 86400).timeIntervalSince1970
        save(map, key: cursorLoginDismissed)
    }

    static func clearCursorLoginSuppression(_ id: String) {
        var map = cursorDismissMap()
        guard map.removeValue(forKey: id) != nil else { return }
        save(map, key: cursorLoginDismissed)
    }

    static func isHidden(_ id: String) -> Bool { hiddenMap()[id] ?? false }

    static func setHidden(_ id: String, _ hidden: Bool) {
        var map = hiddenMap()
        if hidden { map[id] = true } else { map.removeValue(forKey: id) }
        save(map, key: Self.hidden)
    }

    private static func aliasesMap() -> [String: String] { loadMap() ?? [:] }
    private static func cursorDismissMap() -> [String: Double] {
        guard let data = store.data(forKey: cursorLoginDismissed),
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return map
    }
    private static func hiddenMap() -> [String: Bool] {
        guard let data = store.data(forKey: hidden),
              let map = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return map
    }

    private static func loadMap() -> [String: String]? {
        guard let data = store.data(forKey: aliases) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        store.set(data, forKey: key)
    }
}

enum AccountCacheKey {
    /// 缓存文件名用的短哈希，避免把路径或 uuid 直接写进文件名
    static func token(for accountID: String) -> String {
        let digest = SHA256.hash(data: Data(accountID.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

enum AccountDirectory {
    struct Group: Sendable {
        var account: AIAccount
        var dirs: [String]
        /// 这组里包含默认目录时，第一次扫描把旧的单账号缓存文件拷到新文件名
        var migrateLegacy: Bool
    }

    struct Snapshot: Sendable {
        var accounts: [AIAccount]
        var suggestions: [AccountSuggestion]
        var groups: [Group]
    }

    static func load() -> Snapshot {
        let home = UsageHome.url
        let claudeDefault = defaultDir(for: .claude, home: home)
        let codexDefault = defaultDir(for: .codex, home: home)
        var claudeDirs = [claudeDefault]
        var codexDirs = [codexDefault]
        for ref in AccountPrefs.addedDirs() {
            guard let tool = AITool(rawValue: ref.tool) else { continue }
            let path = standardize(ref.dir)
            switch tool {
            case .claude where path != claudeDefault: claudeDirs.append(path)
            case .codex where path != codexDefault: codexDirs.append(path)
            default: break
            }
        }

        let claudeGroups = groupClaude(dirs: claudeDirs, defaultDir: claudeDefault, home: home)
        let codexGroups = groupCodex(dirs: codexDirs, defaultDir: codexDefault)
        let groups = claudeGroups + codexGroups
        let watched = Set(groups.flatMap { group in group.dirs.map { group.account.tool.rawValue + ":" + $0 } })
        let suggestions = discover(home: home, watched: watched, dismissed: AccountPrefs.dismissedIDs())
        return Snapshot(accounts: groups.map(\.account), suggestions: suggestions, groups: groups)
    }

    static func defaultDir(for tool: AITool, home: URL = UsageHome.url) -> String {
        switch tool {
        case .claude:
            if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
                return standardize(env)
            }
            return home.appendingPathComponent(".claude").standardizedFileURL.path
        case .codex:
            if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
                return standardize(env)
            }
            return home.appendingPathComponent(".codex").standardizedFileURL.path
        case .cursor, .opencode:
            return ""
        }
    }

    static func standardize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    static func maskEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = email.firstIndex(of: "@"), at != email.startIndex else { return nil }
        let local = email[..<at]
        let domain = email[email.index(after: at)...]
        guard !domain.isEmpty else { return nil }
        return String(local.prefix(2)) + "***@" + domain
    }

    // MARK: 分组

    private struct ClaudeID {
        var accountUuid: String?
        var displayName: String?
        var maskedEmail: String?
    }

    /// 只取 oauthAccount 里允许的四个显示字段。organizationName 读出来但不进账号模型（它不是套餐名）。
    private static func readClaudeIdentity(at url: URL) -> ClaudeID? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any] else { return nil }
        let email = oauth["emailAddress"] as? String
        let name = oauth["displayName"] as? String
        _ = oauth["organizationName"] as? String
        let uuid = oauth["accountUuid"] as? String
        return ClaudeID(accountUuid: uuid.flatMap { $0.isEmpty ? nil : $0 },
                        displayName: name.flatMap { $0.isEmpty ? nil : $0 },
                        maskedEmail: email.flatMap { maskEmail($0) })
    }

    private static func claudeIdentityURL(home: URL, configDir: String, isDefault: Bool) -> URL {
        if isDefault { return home.appendingPathComponent(".claude.json") }
        return URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
    }

    private static func groupClaude(dirs: [String], defaultDir: String, home: URL) -> [Group] {
        struct Acc {
            var dirs: [String]
            var isDefault: Bool
            var identity: ClaudeID?
        }
        var buckets: [String: Acc] = [:]
        var order: [String] = []
        for dir in dirs {
            let isDefault = dir == defaultDir
            let identity = readClaudeIdentity(at: claudeIdentityURL(home: home, configDir: dir, isDefault: isDefault))
            let key = identity?.accountUuid ?? dir
            if buckets[key] == nil { order.append(key) }
            var acc = buckets[key] ?? Acc(dirs: [], isDefault: false, identity: nil)
            acc.dirs.append(dir)
            acc.isDefault = acc.isDefault || isDefault
            if acc.identity == nil || isDefault { acc.identity = identity ?? acc.identity }
            if isDefault, let identity { acc.identity = identity }
            buckets[key] = acc
        }
        return order.compactMap { key in
            guard let acc = buckets[key] else { return nil }
            let primary = acc.dirs.first { $0 == defaultDir } ?? acc.dirs.sorted().first!
            let id = AITool.claude.rawValue + ":" + (acc.identity?.accountUuid ?? primary)
            let dirName = URL(fileURLWithPath: primary).lastPathComponent
            let alias = AccountPrefs.alias(for: id)
            let display = alias ?? acc.identity?.displayName ?? dirName
            let account = AIAccount(id: id, tool: .claude, dir: primary, displayName: display,
                                    maskedEmail: acc.identity?.maskedEmail, plan: nil,
                                    isDefault: acc.isDefault, hidden: AccountPrefs.isHidden(id))
            return Group(account: account, dirs: acc.dirs, migrateLegacy: acc.isDefault)
        }
    }

    private static func groupCodex(dirs: [String], defaultDir: String) -> [Group] {
        dirs.map { dir in
            let id = AITool.codex.rawValue + ":" + dir
            let dirName = URL(fileURLWithPath: dir).lastPathComponent
            let display = AccountPrefs.alias(for: id) ?? dirName
            let account = AIAccount(id: id, tool: .codex, dir: dir, displayName: display,
                                    maskedEmail: nil, plan: nil, isDefault: dir == defaultDir,
                                    hidden: AccountPrefs.isHidden(id))
            return Group(account: account, dirs: [dir], migrateLegacy: dir == defaultDir)
        }
    }

    // MARK: 建议

    /// 家目录下一级：`.claude-*` 且含 `projects/`，`.codex-*` 且含 `sessions/` 或 `state_5.sqlite`。
    /// 已经在监看里的、被忽略的，不再提示。默认目录本身不是建议。
    private static func discover(home: URL, watched: Set<String>, dismissed: Set<String>) -> [AccountSuggestion] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var found: [AccountSuggestion] = []
        for url in children {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let path = url.standardizedFileURL.path
            if name.hasPrefix(".claude-"), fm.dirExists(path + "/projects") {
                let suggestion = AccountSuggestion(tool: .claude, dir: path)
                if !watched.contains(suggestion.id), !dismissed.contains(suggestion.id) { found.append(suggestion) }
            } else if name.hasPrefix(".codex-"),
                      fm.dirExists(path + "/sessions") || fm.fileExists(atPath: path + "/state_5.sqlite") {
                let suggestion = AccountSuggestion(tool: .codex, dir: path)
                if !watched.contains(suggestion.id), !dismissed.contains(suggestion.id) { found.append(suggestion) }
            }
        }
        return found.sorted { $0.id < $1.id }
    }
}

private extension FileManager {
    func dirExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
