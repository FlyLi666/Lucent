#if DEBUG
import CryptoKit
import Foundation

// `Lucent --cursor-refresh-test`
// 用 URLProtocol 桩挡住 cursor.com / api2.cursor.sh，不出网，不碰真实钥匙串。
// 两个假账号写在 local.lucent.monitor.accounts.test，结束时删掉。

enum CursorRefreshTest {
    private static let testService = "local.lucent.monitor.accounts.test"
    private static let otherID = "lucent-other"
    private static let currentID = "lucent-current"

    static func run() async {
        let realBefore = Set(AccountVault.accountIDs())
        AccountVault.debugService = testService
        defer {
            for id in AccountVault.accountIDs() { AccountVault.delete(id: id) }
            AccountVault.debugService = nil
            UsageHTTP.clearDebugSession()
            let realAfter = Set(AccountVault.accountIDs())
            print("realServiceUnchanged=\(realBefore == realAfter) before=\(realBefore.count) after=\(realAfter.count)")
        }

        UsageHTTP.installDebugProtocols([CursorHTTPStub.self])
        let reader = CursorUsageReader()
        let otherKey = AccountVault.accountID(userID: otherID)
        let currentKey = AccountVault.accountID(userID: currentID)

        let oldAccess = jwt(userID: otherID, marker: "old")
        let newAccess = jwt(userID: otherID, marker: "new")
        CursorHTTPStub.reset(mode: .rotate, oldAccess: oldAccess, newAccess: newAccess, newRefresh: "refresh-new-other")
        let oldSecret = AccountVault.Secret(accessToken: oldAccess, refreshToken: "refresh-old-other",
                                            userID: otherID, email: nil, membershipType: nil)
        let currentSecret = AccountVault.Secret(accessToken: jwt(userID: currentID, marker: "live"),
                                                refreshToken: "refresh-live-current",
                                                userID: currentID, email: nil, membershipType: nil)
        guard AccountVault.save(id: otherKey, secret: oldSecret),
              AccountVault.save(id: currentKey, secret: currentSecret) else {
            print("FAIL 测试钥匙串写不进去")
            return
        }

        print("=== cursor refresh test ===")

        let outcomeA = await reader.fetchQuota(account: oldSecret.cursorAccount(), allowRefresh: true)
        if outcomeA.result.failureReason == nil {
            var rotated = oldSecret
            rotated.accessToken = outcomeA.account.accessToken
            rotated.refreshToken = outcomeA.account.refreshToken
            _ = AccountVault.save(id: otherKey, secret: rotated)
        }
        let afterA = AccountVault.load(id: otherKey)?.accessToken ?? ""
        print("(a) before=\(prefix(oldAccess)) after=\(prefix(afterA)) status=\(describe(outcomeA.result)) refreshRequests=\(CursorHTTPStub.refreshCount)")

        CursorHTTPStub.reset(mode: .denyCurrent, oldAccess: "", newAccess: "", newRefresh: "")
        let current = currentSecret.cursorAccount()
        let outcomeB = await reader.fetchQuota(account: current, allowRefresh: false)
        print("(b) status=\(describe(outcomeB.result)) refreshRequests=\(CursorHTTPStub.refreshCount)")

        let beforeC = AccountVault.load(id: otherKey)?.accessToken ?? ""
        CursorHTTPStub.reset(mode: .denyRefresh, oldAccess: beforeC, newAccess: "", newRefresh: "")
        let outcomeC = await reader.fetchQuota(account: AccountVault.load(id: otherKey)?.cursorAccount() ?? oldSecret.cursorAccount(), allowRefresh: true)
        let afterC = AccountVault.load(id: otherKey)?.accessToken ?? ""
        print("(c) before=\(prefix(beforeC)) after=\(prefix(afterC)) status=\(describe(outcomeC.result)) refreshRequests=\(CursorHTTPStub.refreshCount)")

        let hosts = Array(Set(CursorHTTPStub.hosts)).sorted()
        print("hosts: \(hosts.joined(separator: ", "))")
    }

    private static func describe(_ result: CursorQuotaResult) -> String {
        if let reason = result.failureReason { return "partial(\(reason))" }
        return "ok"
    }

    private static func prefix(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func jwt(userID: String, marker: String) -> String {
        func b64(_ obj: [String: String]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return b64(["alg": "none"]) + "." + b64(["sub": "auth0|" + userID, "m": marker]) + ".x"
    }
}

/// 只应答测试会话里的 Cursor 主机。别的请求不接手，也不会被这层发出去。
final class CursorHTTPStub: URLProtocol, @unchecked Sendable {
    enum Mode { case rotate, denyCurrent, denyRefresh }

    private static let lock = NSLock()
    private static var mode: Mode = .rotate
    private static var oldAccess = ""
    private static var newAccess = ""
    private static var newRefresh = ""
    static var hosts: [String] = []
    static var refreshCount = 0

    static func reset(mode: Mode, oldAccess: String, newAccess: String, newRefresh: String) {
        lock.lock()
        self.mode = mode
        self.oldAccess = oldAccess
        self.newAccess = newAccess
        self.newRefresh = newRefresh
        refreshCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        return host == "cursor.com" || host == "api2.cursor.sh"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://cursor.com/")!
        let host = url.host?.lowercased() ?? ""
        let isRefresh = url.host?.lowercased() == "api2.cursor.sh"
        Self.lock.lock()
        Self.hosts.append(host)
        if isRefresh { Self.refreshCount += 1 }
        let mode = Self.mode
        let newAccess = Self.newAccess
        let newRefresh = Self.newRefresh
        Self.lock.unlock()

        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let code: Int
        let body: Data
        if isRefresh {
            if mode == .rotate {
                code = 200
                body = (try? JSONSerialization.data(withJSONObject: [
                    "access_token": newAccess,
                    "refresh_token": newRefresh,
                ])) ?? Data()
            } else {
                code = 401
                body = Data("{}".utf8)
            }
        } else if mode == .rotate, cookie.contains(newAccess), !newAccess.isEmpty {
            code = 200
            body = Data("{}".utf8)
        } else {
            code = 401
            body = Data()
        }

        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
