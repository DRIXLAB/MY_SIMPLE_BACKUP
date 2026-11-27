import BackupCore
import Foundation
import Security

/// Mot de passe des archives iCloud, dans le trousseau **local** de la session (élément non
/// synchronisé avec le trousseau iCloud). Il n'est jamais écrit ailleurs.
///
/// Note : macOS rattache l'accès à l'élément à la signature de l'app ; en signature ad hoc, macOS
/// peut demander l'autorisation d'y accéder après chaque nouvelle compilation.
enum PasswordKeychain {
    static let service = "com.cepe.sauvegarde-mac.icloud"
    static let account = "archive"

    enum Failure: Error, LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let code):
                let message = (SecCopyErrorMessageString(code, nil) as String?) ?? "\(code)"
                return tr("Trousseau : \(message)", "Keychain: \(message)")
            }
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// Un mot de passe est-il enregistré ? (sans lire le secret : pas de demande d'autorisation)
    static func exists() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.status(status) }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String) throws {
        let data = Data(password.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.status(update) }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "MY SIMPLE BACKUP — iCloud"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }
}
