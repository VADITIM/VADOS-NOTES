import Foundation
import Security

enum Keychain {
    private static let service = "com.vaditim.notes.github"
    private static let account = "token"

    static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

struct SyncSettings: Codable, Equatable {
    var owner: String
    var repository: String
    var branch: String

    static let empty = SyncSettings(owner: "", repository: "", branch: "main")
    private static let defaultsKey = "syncSettings"

    var isComplete: Bool {
        !owner.isEmpty && !repository.isEmpty && !branch.isEmpty
    }

    static func load() -> SyncSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey), let settings = try? JSONDecoder().decode(SyncSettings.self, from: data) else { return .empty }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

enum DeviceIdentity {
    private static let defaultsKey = "deviceId"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey) {
            return existing
        }
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let created = "ipad-\(suffix)"
        UserDefaults.standard.set(created, forKey: defaultsKey)
        return created
    }
}
