import Foundation

// Cursor 用量：本机 sqlite 只给账号信息（JWT），真正的用量要查 cursor.com 的网页接口。
// 桌面版和 cursor-agent 命令行共用一个账号，不分开算。
//
// 接口和取 cookie 的方式参考/移植自 CodexBar（MIT）：
// Adapted from CodexBar (MIT) — Sources/CodexBarCore/Providers/Cursor/CursorAppAuth.swift, CursorStatusProbe.swift
// （JWT sub 取用户 id、WorkosCursorSessionToken cookie 拼法、/api/usage-summary 字段形状）

struct CursorAccount: Sendable {
    var accessToken: String
    var refreshToken: String?
    var userID: String
    var email: String?
    var membershipType: String?   // 本机 sqlite 里的 stripeMembershipType，查接口失败时兜底显示

    var accountID: String { AccountVault.accountID(userID: userID) }
}

struct CursorQuotaResult: Sendable {
    var quotas: [QuotaWindow]
    var plan: String?
    var failureReason: String?
    /// access token 被拒绝，而且 refresh 也没换成能用的
    var unauthorized: Bool = false
}

struct CursorFetchOutcome: Sendable {
    var result: CursorQuotaResult
    var account: CursorAccount
}

final class CursorUsageReader {
    private static let defaultDBPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
    /// Cursor 客户端公开的 OAuth client_id，不是用户密钥
    private static let oauthClientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    private static let expiredReason = "登录已过期，在 Cursor 里重新登录这个账号即可"

    #if DEBUG
    /// `--cursor-db`：只读一份 sqlite .backup 副本，不碰正在用的库
    static var debugDatabasePath: String?
    #endif

    private var dbPath: String {
        #if DEBUG
        if let override = Self.debugDatabasePath, !override.isEmpty { return override }
        #endif
        return Self.defaultDBPath
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: dbPath) }

    /// 只读 ItemTable 里登录相关的 key，绝不写
    func readAccount() -> CursorAccount? {
        guard let db = ReadOnlySQLite(path: dbPath) else { return nil }
        var accessToken: String?
        var refreshToken: String?
        var membershipType: String?
        var cachedEmail: String?
        db.query("""
        SELECT key, value FROM ItemTable WHERE key IN (
            'cursorAuth/accessToken','cursorAuth/refreshToken',
            'cursorAuth/stripeMembershipType','cursorAuth/cachedEmail')
        """) { row in
            guard let key = row.text(0) else { return }
            let value = row.text(1)
            switch key {
            case "cursorAuth/accessToken": accessToken = value
            case "cursorAuth/refreshToken": refreshToken = value
            case "cursorAuth/stripeMembershipType": membershipType = value
            case "cursorAuth/cachedEmail": cachedEmail = value
            default: break
            }
        }
        guard let token = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              let claims = Self.claims(fromJWT: token) else { return nil }
        let email = claims.email ?? Self.nonEmpty(cachedEmail)
        return CursorAccount(accessToken: token, refreshToken: Self.nonEmpty(refreshToken),
                             userID: claims.userID, email: email, membershipType: Self.nonEmpty(membershipType))
    }

    /// JWT 的 sub 形如 "auth0|abc123"，取 "|" 之后的部分。邮箱只留给界面打码，不往外打日志
    private static func claims(fromJWT jwt: String) -> (userID: String, email: String?)? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let sub = json["sub"] as? String
        else { return nil }
        let userID: String
        if let bar = sub.range(of: "|", options: .backwards) {
            userID = String(sub[bar.upperBound...])
        } else {
            userID = sub
        }
        guard !userID.isEmpty else { return nil }
        return (userID, nonEmpty(json["email"] as? String))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var base64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    private static let waitingReason = "等 Cursor 刷新登录"

    /// GET https://cursor.com/api/usage-summary。
    /// 只有「已记住、且不是 Cursor 当前登录」才允许在 401 时用 refreshToken 换新令牌。
    /// 当前登录的 refreshToken 是 Cursor 自己在用的那份，Lucent 换掉会把 Cursor 踢下线。
    /// 用量只打 cursor.com。刷新：POST https://api2.cursor.sh/oauth/token
    /// Adapted from the Cursor IDE refresh call. CodexBar (MIT) CursorAppAuth.swift 只读 accessToken，自己不刷新；
    /// 请求体与公开 client_id 跟 Cursor 客户端一致。成功后的新令牌由调用方写回钥匙串，这里不写 state.vscdb。
    func fetchQuota(account: CursorAccount, allowRefresh: Bool) async -> CursorFetchOutcome {
        let first = await requestSummary(account)
        if first.status != 401 {
            return CursorFetchOutcome(result: first.result, account: account)
        }
        guard allowRefresh else {
            return CursorFetchOutcome(result: waitingResult(account), account: account)
        }
        guard let refreshToken = account.refreshToken,
              let rotated = await refreshAccessToken(refreshToken, userID: account.userID) else {
            return CursorFetchOutcome(result: expiredResult(account), account: account)
        }
        var updated = account
        updated.accessToken = rotated.access
        if let next = rotated.refresh { updated.refreshToken = next }
        let second = await requestSummary(updated)
        if second.status == 401 {
            return CursorFetchOutcome(result: expiredResult(updated), account: updated)
        }
        return CursorFetchOutcome(result: second.result, account: updated)
    }

    private struct SummaryHTTP {
        var result: CursorQuotaResult
        var status: Int?
    }

    /// GET https://cursor.com/api/usage-summary，Cookie: WorkosCursorSessionToken=<userId>::<accessToken>（URL 编码）
    private func requestSummary(_ account: CursorAccount) async -> SummaryHTTP {
        guard var request = Self.allowedRequest(URL(string: "https://cursor.com/api/usage-summary")!) else {
            return SummaryHTTP(result: CursorQuotaResult(quotas: [], plan: fallbackPlan(account), failureReason: "网络请求失败"), status: nil)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.sessionCookie(account), forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await UsageHTTP.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return SummaryHTTP(result: CursorQuotaResult(quotas: [], plan: fallbackPlan(account), failureReason: "网络请求失败"), status: nil)
            }
            if http.statusCode == 401 {
                return SummaryHTTP(result: CursorQuotaResult(quotas: [], plan: fallbackPlan(account), failureReason: nil), status: 401)
            }
            if http.statusCode == 403 {
                return SummaryHTTP(result: CursorQuotaResult(quotas: [], plan: fallbackPlan(account), failureReason: "登录状态已失效，重新登录一次 Cursor 即可"), status: 403)
            }
            if http.statusCode == 429 {
                return SummaryHTTP(result: CursorQuotaResult(quotas: [], plan: fallbackPlan(account), failureReason: "请求过于频繁（429），暂用上次额度"), status: 429)
            }
            guard http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return SummaryHTTP(result: CursorQuotaResult(quotas: [], plan: fallbackPlan(account), failureReason: "额度接口返回异常（HTTP \(http.statusCode)）"), status: http.statusCode)
            }
            return SummaryHTTP(result: Self.mapUsageSummary(obj, account: account), status: 200)
        } catch {
            return SummaryHTTP(result: CursorQuotaResult(quotas: [], plan: fallbackPlan(account), failureReason: "网络请求失败"), status: nil)
        }
    }

    private func expiredResult(_ account: CursorAccount) -> CursorQuotaResult {
        CursorQuotaResult(quotas: [], plan: fallbackPlan(account), failureReason: Self.expiredReason, unauthorized: true)
    }

    private func waitingResult(_ account: CursorAccount) -> CursorQuotaResult {
        CursorQuotaResult(quotas: [], plan: fallbackPlan(account), failureReason: Self.waitingReason, unauthorized: true)
    }

    /// 只允许 cursor.com（用量）和 api2.cursor.sh（刷新）。别处一律不发。
    static func sessionCookie(_ account: CursorAccount) -> String {
        "WorkosCursorSessionToken=\(account.userID)%3A%3A\(account.accessToken)"
    }

    /// 当前登录不要走这里：换掉 refresh 会把 Cursor 自己踢下线。失败就 nil，不写日志。
    func refreshedAccount(_ account: CursorAccount) async -> CursorAccount? {
        guard let refreshToken = account.refreshToken,
              let rotated = await refreshAccessToken(refreshToken, userID: account.userID) else { return nil }
        var updated = account
        updated.accessToken = rotated.access
        if let next = rotated.refresh { updated.refreshToken = next }
        return updated
    }

    /// POST /api/dashboard/get-filtered-usage-events 的一页。调用方负责停页，这里不累积历史。
    func fetchEventsPage(account: CursorAccount, page: Int, pageSize: Int, startMS: Int64, endMS: Int64) async -> CursorEventsPageResult {
        guard var request = Self.allowedRequest(URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!) else {
            return CursorEventsPageResult(status: nil, total: nil, events: [], failureReason: "网络请求失败")
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue(Self.sessionCookie(account), forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 30
        let body: [String: Any] = [
            "page": page,
            "pageSize": pageSize,
            "startDate": String(startMS),
            "endDate": String(endMS),
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return CursorEventsPageResult(status: nil, total: nil, events: [], failureReason: "网络请求失败")
        }
        request.httpBody = payload
        do {
            let (data, response) = try await UsageHTTP.session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url?.host?.lowercased() == "cursor.com" else {
                return CursorEventsPageResult(status: nil, total: nil, events: [], failureReason: "网络请求失败")
            }
            if http.statusCode == 401 {
                return CursorEventsPageResult(status: 401, total: nil, events: [], failureReason: nil)
            }
            if http.statusCode == 403 {
                return CursorEventsPageResult(status: 403, total: nil, events: [], failureReason: "登录状态已失效，重新登录一次 Cursor 即可")
            }
            if http.statusCode == 429 {
                return CursorEventsPageResult(status: 429, total: nil, events: [], failureReason: "请求过于频繁（429），暂用上次用量")
            }
            // 一页 1000 条大约几百 KB；再大就停，避免一次把整段历史读进内存
            guard http.statusCode == 200, data.count <= 8_000_000,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return CursorEventsPageResult(status: http.statusCode, total: nil, events: [], failureReason: "用量接口返回异常（HTTP \(http.statusCode)）")
            }
            // 这个窗口没有事件时，接口回的是空对象 {}，不是带空数组的正常页
            if obj.isEmpty {
                return CursorEventsPageResult(status: 200, total: 0, events: [], failureReason: nil)
            }
            guard obj["usageEventsDisplay"] != nil || obj["totalUsageEventsCount"] != nil else {
                return CursorEventsPageResult(status: http.statusCode, total: nil, events: [], failureReason: "用量接口返回异常（HTTP \(http.statusCode)）")
            }
            let total = Self.jsonInt(obj["totalUsageEventsCount"])
            let rows = obj["usageEventsDisplay"] as? [[String: Any]] ?? []
            let events = rows.compactMap(Self.parseEvent)
            return CursorEventsPageResult(status: 200, total: total, events: events, failureReason: nil)
        } catch {
            return CursorEventsPageResult(status: nil, total: nil, events: [], failureReason: "网络请求失败")
        }
    }

    private static func parseEvent(_ row: [String: Any]) -> CursorRemoteEvent? {
        guard let id = jsonString(row["usageEventId"]), let timeMS = jsonInt64(row["timestamp"]), timeMS > 0 else { return nil }
        let usage = row["tokenUsage"] as? [String: Any] ?? [:]
        let model = jsonString(row["model"]) ?? "unknown"
        let charged = jsonDouble(row["chargedCents"]) ?? 0
        return CursorRemoteEvent(id: id, timeMS: timeMS, model: model,
                                  input: jsonInt64(usage["inputTokens"]) ?? 0,
                                  output: jsonInt64(usage["outputTokens"]) ?? 0,
                                  cacheRead: jsonInt64(usage["cacheReadTokens"]) ?? 0,
                                  cacheWrite: jsonInt64(usage["cacheWriteTokens"]) ?? 0,
                                  costUSD: max(0, charged) / 100)
    }

    private static func jsonString(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func jsonInt(_ value: Any?) -> Int? {
        guard let wide = jsonInt64(value) else { return nil }
        return Int(exactly: wide)
    }

    private static func jsonInt64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) ?? Double(text).flatMap(Int64.init(exactly:)) }
        return nil
    }

    private static func jsonDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let wide = number.doubleValue
            return wide.isFinite ? wide : nil
        }
        if let text = value as? String, let wide = Double(text), wide.isFinite { return wide }
        return nil
    }

    private static func allowedRequest(_ url: URL) -> URLRequest? {
        guard let host = url.host?.lowercased(), host == "cursor.com" || host == "api2.cursor.sh" else { return nil }
        return URLRequest(url: url)
    }

    private struct RotatedToken {
        var access: String
        var refresh: String?
    }

    private func refreshAccessToken(_ refreshToken: String, userID: String) async -> RotatedToken? {
        guard var request = Self.allowedRequest(URL(string: "https://api2.cursor.sh/oauth/token")!) else { return nil }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": Self.oauthClientID,
            "refresh_token": refreshToken,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = payload
        do {
            let (data, response) = try await UsageHTTP.session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count < 1_000_000,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["shouldLogout"] as? Bool) != true
            else { return nil }
            let access = Self.nonEmpty((obj["access_token"] as? String) ?? (obj["accessToken"] as? String))
            guard let access, Self.claims(fromJWT: access)?.userID == userID else { return nil }
            let refresh = Self.nonEmpty((obj["refresh_token"] as? String) ?? (obj["refreshToken"] as? String))
            return RotatedToken(access: access, refresh: refresh)
        } catch {
            return nil
        }
    }

    private func fallbackPlan(_ account: CursorAccount) -> String? {
        guard let m = account.membershipType, !m.isEmpty else { return nil }
        return "Cursor " + m.capitalized
    }

    private static func mapUsageSummary(_ obj: [String: Any], account: CursorAccount) -> CursorQuotaResult {
        let individual = obj["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        var windows: [QuotaWindow] = []

        let cycleEnd = (obj["billingCycleEnd"] as? String).flatMap(ISO8601.parse)

        // 总计以 Cursor 自己给的 totalPercentUsed 为准（和官网仪表盘一致）；
        // plan.used/limit 是套餐内含的 API 额度美元数，Ultra 用满 $400 后仍可继续用，不能当成“总计已用 100%”
        let used = (plan?["used"] as? NSNumber)?.doubleValue, limit = (plan?["limit"] as? NSNumber)?.doubleValue
        let onDemand = ((individual?["onDemand"] as? [String: Any])?["used"] as? NSNumber)?.doubleValue ?? 0
        var detailParts: [String] = []
        if let used, let limit, limit > 0 { detailParts.append(String(format: "内含额度 $%.0f / $%.0f", used / 100, limit / 100)) }
        if onDemand > 0 { detailParts.append(String(format: "按量 $%.2f", onDemand / 100)) }
        let totalFraction: Double? = ((plan?["totalPercentUsed"] as? NSNumber)?.doubleValue).map { $0 / 100 }
            ?? { if let used, let limit, limit > 0 { return used / limit } else { return nil } }()
        if let totalFraction {
            windows.append(QuotaWindow(id: "total", title: "总计", usedFraction: totalFraction, resetsAt: cycleEnd,
                                       detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")))
        }
        if let autoPct = (plan?["autoPercentUsed"] as? NSNumber)?.doubleValue {
            windows.append(QuotaWindow(id: "cursor", title: "Cursor", usedFraction: autoPct / 100, resetsAt: cycleEnd, detail: nil))
        }
        if let apiPct = (plan?["apiPercentUsed"] as? NSNumber)?.doubleValue {
            windows.append(QuotaWindow(id: "api", title: "第三方模型", usedFraction: apiPct / 100, resetsAt: cycleEnd, detail: nil))
        }

        let membershipType = (obj["membershipType"] as? String) ?? account.membershipType
        let planName = membershipType.map { "Cursor " + $0.capitalized }
        return CursorQuotaResult(quotas: windows, plan: planName, failureReason: nil)
    }
}
