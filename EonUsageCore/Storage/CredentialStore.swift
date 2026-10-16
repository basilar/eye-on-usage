import Foundation
import Security

/// Keeps the portal e-mail and password in the keychain.
///
/// The password is only ever needed to mint a fresh session GUID, which the portal
/// invalidates after a short idle period — so the app re-authenticates rather than
/// caching a token, and the password never leaves the device except in the login call.
struct CredentialStore: Sendable {
    struct Credentials: Sendable, Equatable {
        var email: String
        var password: String
    }

    static let shared = CredentialStore()

    private let service = "hu.randart.EonUsage.portal"
    private let account = "primary"

    func save(_ credentials: Credentials) throws {
        let payload = try JSONEncoder().encode(["email": credentials.email, "password": credentials.password])

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PortalError.notConfigured("Could not store your credentials (keychain error \(status)).")
        }
    }

    func load() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let fields = try? JSONDecoder().decode([String: String].self, from: data),
              let email = fields["email"], let password = fields["password"]
        else {
            return nil
        }
        return Credentials(email: email, password: password)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
