import AppKit
import SwiftUI

// AI 用量的多账号：一个目录 = 一个账号（Claude 配置目录 / CODEX_HOME）。
// 只有一个账号时，这里的东西一个都不出现；多了才有账号下拉、卡片分行、设置里的账号列表。

enum UsageAccounts {
    static let selectedKey = "usage.account"

    /// 界面里能看到的账号：没隐藏、所属工具在设置里打开着
    @MainActor static func visible(_ store: UsageStore) -> [AIAccount] {
        let enabled = UsageVisibility.enabled
        return store.accounts.filter { !$0.hidden && enabled.contains($0.tool) }
    }

    /// 某个工具是否有多个可见账号（有才按账号分开显示）
    @MainActor static func isMulti(_ tool: AITool, _ store: UsageStore) -> Bool {
        visible(store).filter { $0.tool == tool }.count > 1
    }

    /// 账号下拉里能选的：有本机逐条记录的工具（Claude、Codex）。Cursor 只有额度，在额度面板里按账号分开
    @MainActor static func filterable(_ store: UsageStore) -> [AIAccount] {
        visible(store).filter { $0.tool.hasLocalLogs }
    }

    /// 至少有一个能筛选的工具有多个账号，账号下拉才出现
    @MainActor static func anyMulti(_ store: UsageStore) -> Bool {
        Dictionary(grouping: filterable(store), by: \.tool).values.contains { $0.count > 1 }
    }

    /// Cursor 已经记住过的账号数（当前登录如果还在等“记住”，不算）
    @MainActor static func rememberedCursor(_ store: UsageStore) -> Int {
        let pending = Set(store.pendingLogins.map(\.id))
        return store.accounts.filter { $0.tool == .cursor && !pending.contains($0.id) }.count
    }

    /// 当前选中的账号（选的账号被隐藏 / 移除了、或已经不是多账号了就当没选）
    @MainActor static func selected(_ store: UsageStore) -> AIAccount? {
        guard anyMulti(store) else { return nil }
        guard let id = UserDefaults.standard.string(forKey: selectedKey), !id.isEmpty else { return nil }
        return filterable(store).first { $0.id == id }
    }

    static func label(_ a: AIAccount) -> String { "\(a.tool.shortTitle) · \(a.displayName)" }
}

// MARK: - 主窗口标题栏：账号下拉

/// 放在 AI 用量页签切换器左边；只有多于一个账号时出现。选中一个账号后，所有页签都只看它
struct AccountMenu: View {
    let store: UsageStore
    @AppStorage(UsageAccounts.selectedKey) private var selectedID = ""

    var body: some View {
        let accounts = UsageAccounts.filterable(store)
        if UsageAccounts.anyMulti(store) {
            let picked = UsageAccounts.selected(store)
            Menu {
                Button { selectedID = "" } label: {
                    if picked == nil { Label("全部账号", systemImage: "checkmark") } else { Text("全部账号") }
                }
                ForEach(AITool.allCases) { tool in
                    let group = accounts.filter { $0.tool == tool }
                    if !group.isEmpty {
                        Section(tool.title) {
                            ForEach(group) { a in
                                Button { selectedID = a.id } label: {
                                    let text = a.maskedEmail.map { "\(a.displayName)  \($0)" } ?? a.displayName
                                    if picked?.id == a.id { Label(text, systemImage: "checkmark") } else { Text(text) }
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle").font(.system(size: 12))
                    Text(picked.map(UsageAccounts.label) ?? "全部账号").lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 160)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 12, weight: picked == nil ? .regular : .semibold))
                .foregroundStyle(picked == nil ? Theme.dim(0.84) : .white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.white.opacity(picked == nil ? 0.06 : 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("只看某一个账号的用量；Claude、Codex 的账号按配置目录区分")
        }
    }
}

// MARK: - AI 用量页顶部：发现新目录的提示

/// 家目录里发现了另一个 Claude / Codex 目录：一次只提示一个，加入或不用，不会自己加
struct AccountSuggestionBanner: View {
    let store: UsageStore

    var body: some View {
        let enabled = UsageVisibility.enabled
        // 已经在用多账号（记住过至少一个 Cursor 账号）时，Cursor 里登了一个新号才问；只有一个号的人不打扰
        if enabled.contains(.cursor), let login = store.pendingLogins.first, UsageAccounts.rememberedCursor(store) > 0 {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 14)).foregroundStyle(Theme.dim(0.9))
                Text("Cursor 里登录了新账号 \(login.maskedEmail ?? "")，记住它以便换号后继续查额度？")
                    .foregroundStyle(Theme.dim(0.9)).lineLimit(1)
                Spacer(minLength: 8)
                Button("不用") { store.dismissLogin(login) }
                    .buttonStyle(PillButtonStyle(prominent: false))
                Button("记住") { store.rememberLogin(login) }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        } else if let s = store.suggestions.first(where: { enabled.contains($0.tool) }) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 14)).foregroundStyle(Theme.dim(0.9))
                HStack(spacing: 4) {
                    Text("发现另一个 \(s.tool.title) 目录")
                    Text(AccountPath.short(s.dir)).font(Theme.mono(11.5)).foregroundStyle(.white)
                    Text("，加为一个账号单独统计？")
                }
                .foregroundStyle(Theme.dim(0.9))
                .lineLimit(1)
                Spacer(minLength: 8)
                Button("不用") { store.dismissSuggestion(s) }
                    .buttonStyle(PillButtonStyle(prominent: false))
                Button("加入") { store.acceptSuggestion(s) }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.black : Theme.dim(0.9))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(prominent ? Color.white.opacity(configuration.isPressed ? 0.75 : 0.92) : Color.white.opacity(configuration.isPressed ? 0.14 : 0.06),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0 : 0.14), lineWidth: 1))
            .contentShape(Capsule())
    }
}

enum AccountPath {
    /// /Users/x/.claude-work → ~/.claude-work
    static func short(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    /// 用户选的目录属于哪个工具：有 projects/ 是 Claude，有 sessions/ 或 state_5.sqlite 是 Codex
    static func detectTool(_ url: URL) -> AITool? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("projects").path) { return .claude }
        if fm.fileExists(atPath: url.appendingPathComponent("sessions").path)
            || fm.fileExists(atPath: url.appendingPathComponent("state_5.sqlite").path) { return .codex }
        return nil
    }
}

// MARK: - 设置：AI 账号

struct UsageAccountSettings: View {
    let store: UsageStore
    @State private var addError: String?

    var body: some View {
        let accounts = store.accounts.filter { $0.tool == .claude || $0.tool == .codex }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(accounts) { AccountSettingsRow(store: store, account: $0) }
            ForEach(store.suggestions) { s in
                HStack(spacing: 8) {
                    Text(s.tool.shortTitle).frame(width: 56, alignment: .leading)
                    Text(AccountPath.short(s.dir)).font(Theme.mono(11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    Text("未加入").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Button("加入") { store.acceptSuggestion(s) }.buttonStyle(PillButtonStyle(prominent: false))
                }
                .font(.system(size: 12.5))
            }
            ForEach(store.accounts.filter { $0.tool == .cursor }) { CursorSettingsRow(store: store, account: $0) }
            HStack(spacing: 8) {
                Button("添加目录…", action: addDirectory).buttonStyle(PillButtonStyle(prominent: false))
                if let addError {
                    Text(addError).font(.system(size: 11)).foregroundStyle(Theme.heat)
                }
            }
            Text("Claude、Codex 一个目录算一个账号（CLAUDE_CONFIG_DIR / CODEX_HOME），账号名取该目录里的显示名，Lucent 不读它们的登录凭据。Cursor 要在换号前点「记住」，换号后才能继续查那个号的额度；令牌只存在本机钥匙串。")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "加为账号"
        panel.message = "选一个 Claude 配置目录（里面有 projects/）或 Codex 目录（里面有 sessions/）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tool = AccountPath.detectTool(url) else {
            addError = "这个目录里没有 Claude（projects/）或 Codex（sessions/）的记录"
            return
        }
        addError = nil
        store.addAccount(tool: tool, dir: url.path)
    }
}

private struct AccountSettingsRow: View {
    let store: UsageStore
    let account: AIAccount
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let a = account
        HStack(spacing: 8) {
            Text(a.tool.shortTitle).frame(width: 56, alignment: .leading)
            if editing {
                TextField("账号名", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 140)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, f in if !f { commit() } }
            } else {
                Text(a.displayName).lineLimit(1)
                    .opacity(a.hidden ? 0.45 : 1)
                    .onTapGesture(count: 2) { startEditing() }
                    .help("双击改名")
            }
            if let e = a.maskedEmail { Text(e).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1) }
            if a.isDefault { Text("默认").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary) }
            Spacer(minLength: 6)
            Menu {
                Button("改名…", action: startEditing)
                Button(a.hidden ? "重新显示" : "隐藏") { store.setHidden(a.id, !a.hidden) }
                if !a.isDefault {
                    Divider()
                    Button("移除这个账号") { store.removeAccount(a.id) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .font(.system(size: 12.5))
        .help(a.dir.map(AccountPath.short) ?? "")
    }

    private func startEditing() {
        draft = account.displayName
        editing = true
        focused = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        if draft != account.displayName { store.setAlias(account.id, draft) }
    }
}

/// 设置里的一行 Cursor 账号：当前登录的可以「记住」，记住过的可以「不再监看」
private struct CursorSettingsRow: View {
    let store: UsageStore
    let account: AIAccount

    var body: some View {
        let a = account
        let pending = store.pendingLogins.first { $0.id == a.id }
        HStack(spacing: 8) {
            Text("Cursor").frame(width: 56, alignment: .leading)
            Text(a.displayName).lineLimit(1).opacity(a.hidden ? 0.45 : 1)
            if let plan = a.plan { Text(plan).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1) }
            if a.isCurrentLogin { Text("当前登录").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary) }
            if case let .partial(r) = a.status {
                Image(systemName: "exclamationmark.circle").font(.system(size: 10.5)).foregroundStyle(Theme.heat).help(r)
            }
            Spacer(minLength: 6)
            if let pending {
                Button("记住") { store.rememberLogin(pending) }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help("把这个账号的登录存进本机钥匙串：以后在 Cursor 里换了号，Lucent 还能继续查它的额度")
            } else {
                Menu {
                    Button(a.hidden ? "重新显示" : "隐藏") { store.setHidden(a.id, !a.hidden) }
                    Divider()
                    Button("不再监看（从钥匙串删除）") { store.forgetAccount(a.id) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        }
        .font(.system(size: 12.5))
    }
}
