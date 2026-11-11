import Foundation
import Observation

// 界面语言。源码里写的中文原文就是查表的键：中文界面直接用原文，
// 英文界面去 Resources/en.lproj/Lucent.strings 里查，查不到退回中文原文。
// 新增或改动界面文字后跑 scripts/l10n-check.py，它会列出英文表里缺的和多余的。
//
// 文件故意不叫 Localizable.strings：SwiftUI 的 Text("字面量") 会自己去那张表里按系统语言查，
// 那样用户在设置里选的语言就管不住它了。

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en
    var id: String { rawValue }
}

/// 视图在 body 里调用 L()、L10n.isEnglish 或 L10n.locale 时会读到 revision，语言一变这些视图自动重画。
@Observable final class L10nState {
    var revision = 0
}

enum L10n {
    static let prefKey = "ui.language"
    static let didChange = Notification.Name("LucentLanguageChanged")
    static let state = L10nState()

    private static let lock = NSLock()
    /// nil = 中文界面，不查表。后台线程也会读，所以和 code 一起用锁护着
    private static var table: [String: String]?
    private static var code = AppLanguage.zhHans.rawValue

    static var preference: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: prefKey) ?? ""
        // An earlier build stored Chinese as "zh"
        return AppLanguage(rawValue: raw == "zh" ? AppLanguage.zhHans.rawValue : raw) ?? .system
    }

    static var isEnglish: Bool {
        track()
        lock.lock(); defer { lock.unlock() }
        return code == AppLanguage.en.rawValue
    }

    /// 在视图 body 里读到语言，就让这个视图在换语言时重画。后台线程不碰界面状态
    private static func track() {
        if Thread.isMainThread { _ = state.revision }
    }

    /// 日期、月份名按界面语言走，不按系统区域（系统是中文、界面选了英文时两者不一样）
    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "zh_CN") }

    /// 用户在设置里改语言
    static func setPreference(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: prefKey)
        // 系统自带的界面（关于面板、系统报错）只认 AppleLanguages，下次启动生效
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
        reload()
    }

    /// 启动时和改语言后调用，只在主线程
    static func reload() {
        let resolved = resolve(preference)
        let loaded = resolved == AppLanguage.en.rawValue ? loadTable(resolved) : nil
        lock.lock()
        let changed = resolved != code
        code = resolved
        table = loaded
        lock.unlock()
        guard changed else { return }
        state.revision += 1
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func resolve(_ preference: AppLanguage) -> String {
        if preference != .system { return preference.rawValue }
        let first = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first
            ?? Locale.preferredLanguages.first ?? "en"
        // 繁体中文系统也给中文界面，比给英文合适
        return first.hasPrefix("zh") ? AppLanguage.zhHans.rawValue : AppLanguage.en.rawValue
    }

    private static func loadTable(_ code: String) -> [String: String] {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: "Lucent", withExtension: "strings", subdirectory: nil, localization: code) {
            candidates.append(url)
        }
        #if DEBUG
        // 调试版直接从 .build 里跑，没有应用包，回源码目录找
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/\(code).lproj/Lucent.strings"))
        #endif
        for url in candidates {
            if let dict = NSDictionary(contentsOf: url) as? [String: String] { return dict }
        }
        return [:]
    }

    fileprivate static func string(_ text: LText) -> String {
        track()
        lock.lock()
        let template = table?[text.key] ?? text.key
        lock.unlock()
        return text.args.isEmpty ? template : fill(template, text.args)
    }

    /// 把模板里的 {0} {1} 换成参数。一遍扫完，参数里就算有花括号也不会被再替换一次
    private static func fill(_ template: String, _ args: [String]) -> String {
        var out = ""
        out.reserveCapacity(template.count + 16)
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let n = Int(after[..<close]), args.indices.contains(n) {
                out += args[n]
                rest = after[after.index(after: close)...]
            } else {
                out += "{"
                rest = after
            }
        }
        out += rest
        return out
    }
}

/// 可翻译的文字：中文原文里的 \(…) 变成 {0} {1}，译文可以调换它们的顺序
struct LText: ExpressibleByStringInterpolation {
    var key: String
    var args: [String]

    init(stringLiteral value: String) {
        key = value
        args = []
    }

    init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        args = stringInterpolation.args
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var args: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity + interpolationCount * 3)
            args.reserveCapacity(interpolationCount)
        }

        mutating func appendLiteral(_ literal: String) { key += literal }

        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(args.count)}"
            args.append(String(describing: value))
        }
    }
}

/// 界面文字一律过这个函数
func L(_ text: LText) -> String { L10n.string(text) }
