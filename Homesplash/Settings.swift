import Foundation
import Security

/// Server address lives in UserDefaults; the push token in the Keychain.
enum Settings {
    static let serverKey = "serverURL"
    static let moduleKey = "moduleKey"
    private static let tokenAccount = "homesplash.pushToken"

    static var server: String {
        get { UserDefaults.standard.string(forKey: serverKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: serverKey) }
    }

    static var module: String {
        let m = UserDefaults.standard.string(forKey: moduleKey) ?? ""
        return m.isEmpty ? "apple_health" : m
    }

    /// e.g. http://192.168.1.20:8080 -> http://192.168.1.20:8080/api/push/apple_health
    static var pushURL: URL? {
        var base = server
        guard !base.isEmpty else { return nil }
        if !base.lowercased().hasPrefix("http") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/api/push/\(module)")
    }

    static var isConfigured: Bool { pushURL != nil && !(token ?? "").isEmpty }

    static var token: String? {
        get {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(baseQuery as CFDictionary)
            guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            var add = baseQuery
            add[kSecValueData as String] = Data(value.utf8)
            // readable in the background after the first unlock
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: tokenAccount]
    }
}
