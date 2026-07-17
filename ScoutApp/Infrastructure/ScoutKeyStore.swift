import Foundation
import Security

/// Owns the device-bound key that encrypts Scout's local event bodies.
///
/// The key is generated on this Mac, never synchronized, and never leaves the
/// Keychain. Callers receive the bytes only long enough to initialize the
/// persistence cipher.
enum ScoutKeyStore {
    private static let service = "dev.scout.discovery.event-store"
    private static let account = "primary-v1"
    private static let keyByteCount = 32

    static func eventStoreKey() throws -> Data {
        switch copyExistingKey() {
        case let .success(key):
            return key
        case let .failure(error) where error.status == errSecItemNotFound:
            return try createKey()
        case let .failure(error):
            throw error
        }
    }

    private static func copyExistingKey() -> Result<Data, KeyStoreError> {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary,
            &result
        )

        guard status == errSecSuccess else {
            return .failure(KeyStoreError(status: status))
        }
        guard let key = result as? Data, key.count == keyByteCount else {
            return .failure(KeyStoreError(status: errSecDecode))
        }
        return .success(key)
    }

    private static func createKey() throws -> Data {
        var bytes = Data(count: keyByteCount)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, keyByteCount, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw KeyStoreError(status: randomStatus)
        }

        let addStatus = SecItemAdd(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
                kSecValueData as String: bytes,
            ] as CFDictionary,
            nil
        )

        if addStatus == errSecDuplicateItem {
            // Another app task won the creation race. Resolve and validate the
            // single authoritative Keychain item instead of overwriting it.
            return try copyExistingKey().get()
        }
        guard addStatus == errSecSuccess else {
            throw KeyStoreError(status: addStatus)
        }
        return bytes
    }

    struct KeyStoreError: LocalizedError, Equatable {
        let status: OSStatus

        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Scout could not access its device-bound event-store key: "
                + (message ?? "Keychain status \(status)")
        }
    }
}
