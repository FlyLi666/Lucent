import Foundation

// AI 编程工具用量：界面和后端之间的约定。
// 界面只读这里的类型；读日志、查接口、算价格都在 Usage/ 下的后端里。

/// 统计哪些工具。Claude Code 的命令行和桌面版写同一份 ~/.claude/projects，合成一项；Cursor 桌面版和命令行是同一个账号，也合成一项。
enum AITool: String, CaseIterable, Identifiable, Sendable {
    case claude, cursor, opencode, codex
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        }
    }

    /// 表格里用的短名
    var shortTitle: String {
        switch self {
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        }
    }

    /// 有本机逐条记录（能做请求日志、热力图、缓存分析）的工具；Cursor 只有账号额度
    /// 有逐条记录（请求日志、热力图、按模型）：Claude / Codex / OpenCode 读本机，Cursor 10-24 起从 cursor.com 拉逐条用量
    var hasLocalLogs: Bool { true }

    /// Lucent 自己去查订阅额度的（只有 Cursor）。
    /// Claude 不读任何凭据（官方条款不允许第三方收集会话令牌），额度只给“打开用量页”按钮；OpenCode 用自己的 API key，没有额度
    var hasQuota: Bool { self == .cursor }

    /// 数据来源的一句话说明，显示在主窗口
    var sourceNote: String {
        switch self {
        case .claude: return "命令行 + 桌面版 · 本机记录"
        case .cursor: return "桌面版 + 命令行 · 账号用量"
        case .opencode: return "本机记录"
        case .codex: return "命令行 + 桌面版 · 本机记录"
        }
    }
}

/// 一个已加入监看的账号。同一 accountUuid 的多个目录在发现时合成一条。
struct AIAccount: Sendable, Identifiable, Equatable {
    var id: String          // 稳定：tool.rawValue + ":" + (accountUuid ?? 标准化目录路径)
    var tool: AITool
    var dir: String?        // Claude 配置目录 / CODEX_HOME；Cursor 没有目录，是 nil
    var displayName: String // 别名 > oauthAccount.displayName > 目录名（如 ".claude-work"）
    var maskedEmail: String?// "li***@gmail.com"：本地部分保留前 2 个字符
    var plan: String?
    var isDefault: Bool     // ~/.claude 或 ~/.codex（或环境变量指的那个）
    var hidden: Bool
    /// Cursor 本机正在登录的那个账号。没记住也会显示；令牌不在这个结构里
    var isCurrentLogin: Bool = false
    /// 这个账号自己的额度。Cursor 合计视图不看这里，仍用当前登录那一份
    var quotas: [QuotaWindow] = []
    var quotaUpdatedAt: Date?
    /// 令牌过期等写 partial；Claude / Codex 不用，保持 ok
    var status: UsageStatus = .ok
}

/// 本机发现了一个还没记住的登录（目前只有 Cursor）。用户点记住才进钥匙串。
struct PendingLogin: Sendable, Identifiable, Equatable {
    var tool: AITool
    var maskedEmail: String?
    var plan: String?
    var id: String
}

/// 家目录下发现、但还没加入监看的目录。
struct AccountSuggestion: Sendable, Identifiable, Equatable {
    var tool: AITool; var dir: String
    var id: String { tool.rawValue + ":" + dir }
}

struct TokenCounts: Sendable, Equatable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    /// 思考 token。Claude 的思考已算在 output 里，这里只做展示，不重复加进 total
    var reasoning: Int64 = 0
    /// 只有总数、分不出输入/输出/缓存（Codex sqlite 里被删掉的旧会话就是这样）
    var unsplit: Int64 = 0

    var total: Int64 { input + output + cacheRead + cacheWrite + unsplit }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                    cacheWrite: a.cacheWrite + b.cacheWrite, reasoning: a.reasoning + b.reasoning, unsplit: a.unsplit + b.unsplit)
    }
}

/// 连续用量窗口，固定 5 小时。分窗算法见 UsageBlocks.swift（参照 ccusage 的 session blocks）。
struct UsageBlock: Sendable, Equatable, Identifiable {
    var start: Date
    var end: Date          // end = start + 5h
    var lastActivity: Date
    var tokens = TokenCounts()
    var cost: Double = 0
    var requests: Int = 0
    var isActive: Bool                       // now < end
    var tokensPerMinute: Double              // 窗口内从 start 到 min(now,lastActivity) 的平均
    var costPerHour: Double
    var projectedTokens: Int64
    var projectedCost: Double   // 活跃窗口按当前速率外推到 end；非活跃 = 实际值
    var id: Date { start }
}

/// 一天的用量（本地时区的自然日）
struct DailyUsage: Sendable, Identifiable, Equatable {
    var day: Date            // 当天 00:00
    var tokens = TokenCounts()
    var cost: Double = 0     // 美元
    var requests: Int = 0    // 请求数（一条 assistant 回复算一次）
    /// 缓存省下的钱：缓存读的 token 如果按普通输入价计费要多花多少（美元，>=0）
    var cacheSavings: Double = 0
    /// 缓存写里按 1 小时缓存计费的部分（其余是 5 分钟缓存）
    var cacheWrite1h: Int64 = 0
    var id: Date { day }
}

/// 一小时的用量（本地时区整点），给“星期 × 时段”热力图和缓存曲线用
struct HourlyUsage: Sendable, Identifiable, Equatable {
    var hour: Date           // 整点
    var tokens = TokenCounts()
    var cost: Double = 0
    var requests: Int = 0
    var id: Date { hour }
}

/// 一次请求（一条带 usage 的 assistant 回复），给“请求明细”表用
struct UsageRequest: Sendable, Identifiable, Equatable {
    var id: String           // message.id 或数据库主键，全局唯一
    var time: Date
    var tool: AITool
    var model: String
    var project: String?     // 项目目录的最后一级名称，例如 "Lucent"（不含完整路径以外的信息）
    var sessionID: String?
    var tokens = TokenCounts()
    var cacheWrite1h: Int64 = 0
    var cost: Double = 0
    /// 供应商：Claude Code 固定 "Anthropic"；OpenCode 用自己记录的 providerID（例如 "openrouter"）
    var provider: String = ""
    /// 这次请求从发出到回复写完的大致耗时（毫秒）。拿不到就是 nil，界面显示 “—”
    var durationMs: Int?
    /// 耗时是精确值（工具自己记录了开始和结束）还是从日志时间戳估出来的
    var durationIsEstimate = true
}

/// 按“时间段 × 工具 × 供应商 × 模型”汇总的一格，给看板按任意时间范围 / 筛选重新加总用
struct UsageBucket: Sendable, Identifiable, Equatable {
    var start: Date              // 整点（逐小时）或 当天 00:00（逐日）
    var tool: AITool
    var provider: String
    var model: String
    var tokens = TokenCounts()
    var cost: Double = 0
    var requests: Int = 0
    var cacheSavings: Double = 0
    var cacheWrite1h: Int64 = 0
    /// 有耗时的那部分请求：输出 token 之和与耗时之和，用来算平均速度（tok/s）
    var timedOutputTokens: Int64 = 0
    var timedDurationMs: Int64 = 0
    var id: String { "\(start.timeIntervalSince1970)|\(tool.rawValue)|\(provider)|\(model)" }
}

/// 一个模型的单价（美元 / 每百万 token）
struct PricingEntry: Sendable, Identifiable, Equatable {
    var model: String
    var tool: AITool
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheWrite5m: Double?
    var cacheWrite1h: Double?
    /// 价格从哪来：例如 "LiteLLM"、"同系列回退（按 claude-opus-5-5）"、"OpenCode 记录"
    var source: String
    var id: String { tool.rawValue + "/" + model }
}

/// 近 30 天按项目汇总
struct ProjectShare: Sendable, Identifiable, Equatable {
    var project: String
    var tool: AITool
    var tokens = TokenCounts()
    var cost: Double = 0
    var requests: Int = 0
    var lastActive: Date?
    var id: String { tool.rawValue + "/" + project }
}

struct ModelShare: Sendable, Identifiable, Equatable {
    var model: String        // 原样的模型 id，例如 claude-opus-5-5
    var tokens: Int64
    var cost: Double
    var detail = TokenCounts()   // 分类型的 token（tokens == detail.total）
    var requests: Int = 0
    var id: String { model }
}

/// 订阅额度的一个窗口，例如 Claude 的“5 小时”“本周”，Cursor 的“本期总计”
struct QuotaWindow: Sendable, Identifiable, Equatable {
    var id: String           // 稳定 id，例如 "five_hour"
    var title: String        // 中文标题，例如 "5 小时"
    var usedFraction: Double // 0...1（可能 >1 表示超额）
    var resetsAt: Date?
    var detail: String?      // 额外一句，例如 "超额 5%"
}

/// 金额是怎么来的，界面据此加标注
enum CostKind: Sendable, Equatable {
    case apiEquivalent       // 按公开 API 价目表折算（订阅用户并不按这个付钱）
    case recorded            // 工具自己记录的金额（OpenCode）
    case billed              // 平台账单 / 计量金额（Cursor）
}

enum UsageStatus: Sendable, Equatable {
    case loading
    case ok
    case notInstalled                 // 本机没装 / 没有任何记录
    case partial(String)              // 本机记录正常，但额度查不到（令牌过期、接口 429 等），附中文原因
    case failed(String)               // 整项失败，附中文原因
}

struct ToolUsage: Sendable, Identifiable, Equatable {
    var tool: AITool
    var status: UsageStatus = .loading
    var plan: String?                 // 例如 "Claude Max"、"Cursor Ultra"
    var costKind: CostKind = .apiEquivalent

    var today = DailyUsage(day: Calendar.current.startOfDay(for: Date()))
    /// 近 30 天，最早在前，没用的日子补 0，共 30 项（最后一项是今天）
    var daily: [DailyUsage] = []
    /// 近 30 天按模型，用量大的在前
    var models: [ModelShare] = []
    /// 能拿到的更长历史（最多 365 天，最早在前，补 0，最后一项是今天），给日历热力图用
    var history: [DailyUsage] = []
    /// 近 30 天逐小时（只放有用量的小时，时间升序）
    var hourly: [HourlyUsage] = []
    /// 最近的请求，最新在前，最多 300 条
    var recentRequests: [UsageRequest] = []
    /// 近 30 天按项目，用量大的在前
    var projects: [ProjectShare] = []
    /// 近 30 天逐小时 × 供应商 × 模型（只放非空格子，时间升序）
    var hourlyDetail: [UsageBucket] = []
    /// 全部历史逐日 × 供应商 × 模型（最多 365 天，只放非空格子，时间升序）
    var dailyDetail: [UsageBucket] = []
    /// 近 30 天用到的模型的单价
    var pricing: [PricingEntry] = []

    var quotas: [QuotaWindow] = []
    var quotaUpdatedAt: Date?

    /// 最近一条记录的时间，用来显示“正在用”
    var lastActivity: Date?
    /// 最近 5 分钟每分钟的 token 数，给波形的激烈程度用
    var tokensPerMinute: Double = 0
    /// 当前还没结束的 5 小时窗口；没有就 nil
    var currentBlock: UsageBlock?
    /// 近 7 天的窗口，最新在前
    var recentBlocks: [UsageBlock] = []
    /// 近 30 天里单个窗口的最大 token，界面当参考上限
    var peakBlockTokens: Int64 = 0

    var id: AITool { tool }
    var last30Tokens: TokenCounts { daily.reduce(TokenCounts()) { $0 + $1.tokens } }
    var last30Cost: Double { daily.reduce(0) { $0 + $1.cost } }
}
