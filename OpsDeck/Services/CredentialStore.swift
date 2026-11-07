import Foundation
import Security

enum CredentialKind: String, Sendable, CaseIterable {
    case password
    case privateKey
    case privateKeyPassphrase
}

struct CredentialRecord: Sendable, Equatable {
    var id: String
    var kind: CredentialKind
    var value: String
}

enum CredentialStoreError: LocalizedError, Sendable, Equatable {
    case emptySecret
    case notFound
    case unexpectedData
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptySecret:
            return String(localized: "凭据不能为空。")
        case .notFound:
            return String(localized: "未在钥匙串中找到凭据，请重新编辑服务器并保存凭据。")
        case .unexpectedData:
            return String(localized: "钥匙串返回了无法识别的凭据格式。")
        case .keychainStatus(let status):
            return String(localized: "钥匙串操作失败（状态码 \(status)）。")
        }
    }
}

final class CredentialStore: @unchecked Sendable {
    private let service = "com.hansen.opsdeck.credentials"

    func save(_ value: String, kind: CredentialKind, id: String = UUID().uuidString) throws -> String {
        guard !value.isEmpty else { throw CredentialStoreError.emptySecret }

        let data = Data(value.utf8)
        var query = baseQuery(id: id)
        query[kSecAttrLabel as String] = kind.rawValue
        query[kSecAttrDescription as String] = "OpsDeck \(kind.rawValue)"

        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.keychainStatus(status) }
        return id
    }

    func read(id: String, kind: CredentialKind? = nil) throws -> CredentialRecord {
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status != errSecItemNotFound else { throw CredentialStoreError.notFound }
        guard status == errSecSuccess else { throw CredentialStoreError.keychainStatus(status) }
        guard
            let item = out as? [String: Any],
            let data = item[kSecValueData as String] as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw CredentialStoreError.unexpectedData
        }

        let storedKind = (item[kSecAttrLabel as String] as? String).flatMap(CredentialKind.init(rawValue:)) ?? kind ?? .password
        if let kind, storedKind != kind { throw CredentialStoreError.notFound }
        return CredentialRecord(id: id, kind: storedKind, value: value)
    }

    func delete(id: String) throws {
        let status = SecItemDelete(baseQuery(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainStatus(status)
        }
    }

    func exists(id: String) -> Bool {
        var query = baseQuery(id: id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]
    }
}
