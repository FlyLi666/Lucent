import Foundation
import Security

// Cursor 记住的登录：一个账号一条钥匙串，令牌只放这里。
// service 固定 local.lucent.monitor.accounts，本机解锁后才可读，不同步到 iCloud。
// 不写文件、不写 UserDefaults、不打日志。

enum AccountVault {
    static let productionService = "local.lucent.monitor.accounts"
    #if DEBUG
    /// 刷新测试用的钥匙串，测完删掉。正式路径不设这个
    static var debugService: String?
    static var service: String { debugService ?? productionService }
    #else
    static let service = productionService
    #endif

    struct Secret: Sendable {
        var accessToken: String
        var refreshToken: String?
        var userID: String
        var email: String?
        var membershipType: String?

        func cursorAccount() -> CursorAccount {
            CursorAccount(accessToken: accessToken, refreshToken: refreshToken, userID: userID,
                          email: email, membershipType: membershipType)
        }
    }

    static func accountID(userID: String) -> String { "cursor:" + userID }

    static func save(id: String, secret: Secret) -> Bool {
        let payload = Stored(accessToken: secret.accessToken, refreshToken: secret.refreshToken,
                             userID: secret.userID, email: secret.email, membershipType: secret.membershipType)
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        let base = query(account: id)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Lucent"
        add[kSecAttrSynchronizable as String] = false
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func loadAll() -> [String: Secret] {
        var found: [String: Secret] = [:]
        for id in accountIDs() {
            if let secret = load(id: id) { found[id] = secret }
        }
        return found
    }

    /// 按账号单独取密码。kSecMatchLimitAll 和 kSecReturnData 一起用会返回 errSecParam，所以不这么查
    static func load(id: String) -> Secret? {
        var query = query(account: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              !stored.accessToken.isEmpty, !stored.userID.isEmpty else { return nil }
        return Secret(accessToken: stored.accessToken, refreshToken: stored.refreshToken,
                      userID: stored.userID, email: stored.email, membershipType: stored.membershipType)
    }

    /// 只有账号 id，给调试输出对钥匙串用。不读密码本体
    static func accountIDs() -> [String] {
        matching().compactMap { $0[kSecAttrAccount as String] as? String }
    }

    static func delete(id: String) {
        _ = SecItemDelete(query(account: id) as CFDictionary)
    }

    private struct Stored: Codable {
        var accessToken: String
        var refreshToken: String?
        var userID: String
        var email: String?
        var membershipType: String?
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func matching() -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { return [] }
        return result as? [[String: Any]] ?? []
    }
}
