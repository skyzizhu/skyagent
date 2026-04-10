import Foundation
import Security

final class MCPKeychainStore: Sendable {
    static let shared = MCPKeychainStore()

    private let service = "com.skyzizhu.skyagent.mcp"

    nonisolated func token(for serverID: UUID) -> String? {
        secretString(forAccount: account(for: serverID))
    }

    nonisolated func additionalSecretHeaders(for serverID: UUID) -> [String: String] {
        guard let raw = secretString(forAccount: headersAccount(for: serverID)),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    @discardableResult
    nonisolated func setAdditionalSecretHeaders(_ headers: [String: String], for serverID: UUID) -> Bool {
        let sanitized = headers.reduce(into: [String: String]()) { result, item in
            let name = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { return }
            result[name] = value
        }
        guard !sanitized.isEmpty else {
            return deleteSecretString(forAccount: headersAccount(for: serverID))
        }
        guard let data = try? JSONEncoder().encode(sanitized),
              let raw = String(data: data, encoding: .utf8) else {
            return false
        }
        return setSecretString(raw, forAccount: headersAccount(for: serverID))
    }

    @discardableResult
    nonisolated func deleteAdditionalSecretHeaders(for serverID: UUID) -> Bool {
        deleteSecretString(forAccount: headersAccount(for: serverID))
    }

    @discardableResult
    nonisolated func setToken(_ token: String?, for serverID: UUID) -> Bool {
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedToken.isEmpty {
            return deleteToken(for: serverID)
        }
        return setSecretString(trimmedToken, forAccount: account(for: serverID))
    }

    @discardableResult
    nonisolated func deleteToken(for serverID: UUID) -> Bool {
        deleteSecretString(forAccount: account(for: serverID))
    }

    nonisolated private func secretString(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    @discardableResult
    nonisolated private func setSecretString(_ value: String, forAccount account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    nonisolated private func deleteSecretString(forAccount account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    nonisolated private func account(for serverID: UUID) -> String {
        "mcp.server.\(serverID.uuidString.lowercased())"
    }

    nonisolated private func headersAccount(for serverID: UUID) -> String {
        "mcp.server.headers.\(serverID.uuidString.lowercased())"
    }
}
