import Foundation

/// User-facing copy. English keys live in code; `Resources/zh.lproj` holds the original Chinese.
/// `build.sh` copies `*.lproj` into `Lucent.app/Contents/Resources`. `Bundle.main` then
/// picks `zh` for any preferred `zh-*`, and falls back to the English key otherwise.
enum L10n {
    static func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: args)
    }

    static func n(_ value: some BinaryInteger) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: Int64(truncatingIfNeeded: value))) ?? "\(value)"
    }

    static var bundle: Bundle {
        switch override {
        case .english: return lproj("en") ?? .main
        case .chinese: return lproj("zh") ?? .main
        case .system: return .main
        }
    }

    static var locale: Locale {
        switch override {
        case .english: return Locale(identifier: "en_US")
        case .chinese: return Locale(identifier: "zh_CN")
        case .system: return .autoupdatingCurrent
        }
    }

    static var override: Language {
        Language(rawValue: UserDefaults.standard.string(forKey: Prefs.language) ?? "") ?? .system
    }

    enum Language: String, CaseIterable, Identifiable {
        case system, english = "en", chinese = "zh"
        var id: String { rawValue }
        /// Picker labels stay recognizable in every language.
        var pickerTitle: String {
            switch self {
            case .system: return L10n.t("System")
            case .english: return "English"
            case .chinese: return "中文"
            }
        }
    }

    // MARK: - Plurals

    static func days(_ n: Int) -> String { n == 1 ? t("1 day") : t("%d days", n) }
    static func hours(_ n: Int) -> String { n == 1 ? t("1 hour") : t("%d hours", n) }
    static func minutes(_ n: Int) -> String { n == 1 ? t("1 minute") : t("%d minutes", n) }
    static func requests(_ n: Int) -> String { n == 1 ? t("1 request") : t("%d requests", n) }
    static func cores(_ n: Int) -> String { n == 1 ? t("1 GPU core") : t("%d GPU cores", n) }

    // MARK: - Dates (locale-aware; Chinese keeps 月/日, English uses short month)

    enum Dates {
        static func hourTick(_ d: Date) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.dateFormat = "HH:00"
            return f.string(from: d)
        }

        static func monthDayNumeric(_ d: Date) -> String {
            fmt(template: "Md", date: d)
        }

        static func monthDay(_ d: Date) -> String {
            fmt(template: "MMMd", date: d)
        }

        static func monthDayHour(_ d: Date) -> String {
            fmt(template: "MMMdHHmm", date: d)
        }

        static func yearMonthDay(_ d: Date) -> String {
            fmt(template: "yMMMd", date: d)
        }

        static func timeHMS(_ d: Date) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.dateFormat = "HH:mm:ss"
            return f.string(from: d)
        }

        static func monthDayTime(_ d: Date) -> String {
            fmt(template: "Mdjmm", date: d)
        }

        static func monthLabel(_ month: Int) -> String {
            let f = DateFormatter()
            f.locale = locale
            let names = f.shortMonthSymbols ?? []
            guard month >= 1, month <= names.count else { return "\(month)" }
            return names[month - 1]
        }

        /// Monday-first very short names for heatmap row labels (一…日 / M…S).
        static var weekdaysMonFirstVeryShort: [String] {
            mondayFirst(calendar.veryShortStandaloneWeekdaySymbols)
        }

        /// Monday-first short names for hover copy (周一 / Mon).
        static var weekdaysMonFirstShort: [String] {
            mondayFirst(calendar.shortStandaloneWeekdaySymbols)
        }

        private static var calendar: Calendar {
            var c = Calendar(identifier: .gregorian)
            c.locale = locale
            return c
        }

        private static func mondayFirst(_ sundayFirst: [String]?) -> [String] {
            guard let sundayFirst, sundayFirst.count == 7 else { return sundayFirst ?? [] }
            return Array(sundayFirst[1...6]) + [sundayFirst[0]]
        }

        private static func fmt(template: String, date: Date) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
    }

    private static func lproj(_ code: String) -> Bundle? {
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}
