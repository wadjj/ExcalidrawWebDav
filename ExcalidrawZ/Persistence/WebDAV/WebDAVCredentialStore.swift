import Foundation
#if canImport(Security)
import Security
#endif

#if !canImport(Security)
typealias OSStatus = Int32
#endif

struct WebDAVCredential: Sendable {
    let username: String
    let password: String
}

enum WebDAVCredentialStoreError: LocalizedError {
    case invalidPasswordData
    case unhandledError(OSStatus)
    case keychainUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPasswordData:
            return "Stored WebDAV password could not be decoded"
        case .unhandledError(let status):
            return "Keychain operation failed with status: \(status)"
        case .keychainUnavailable:
            return "Keychain APIs are unavailable in this runtime"
        }
    }
}

actor WebDAVCredentialStore {
    private let service = "com.chocoford.excalidraw.webdav"

    func save(credential: WebDAVCredential, account: String = "default") throws {
        #if canImport(Security)
        let passwordData = Data(credential.password.utf8)
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecAttrLabel] = credential.username
        addQuery[kSecValueData] = passwordData

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WebDAVCredentialStoreError.unhandledError(status)
        }
        #else
        _ = credential
        _ = account
        throw WebDAVCredentialStoreError.keychainUnavailable
        #endif
    }

    func load(account: String = "default") throws -> WebDAVCredential? {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw WebDAVCredentialStoreError.unhandledError(status)
        }

        guard let dictionary = result as? [CFString: Any],
              let passwordData = dictionary[kSecValueData] as? Data,
              let username = dictionary[kSecAttrLabel] as? String,
              let password = String(data: passwordData, encoding: .utf8) else {
            throw WebDAVCredentialStoreError.invalidPasswordData
        }

        return WebDAVCredential(username: username, password: password)
        #else
        _ = account
        throw WebDAVCredentialStoreError.keychainUnavailable
        #endif
    }

    func delete(account: String = "default") throws {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WebDAVCredentialStoreError.unhandledError(status)
        }
        #else
        _ = account
        throw WebDAVCredentialStoreError.keychainUnavailable
        #endif
    }
}
