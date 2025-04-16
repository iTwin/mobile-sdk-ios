/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import Foundation

/// Helper class to facilitate storage of arbitrary data in a "Generic Password" iOS keychain item.
///
/// In addition to the low-level loading and saving of `Data` values, also includes convenience functions
/// to load and save `Dictionary` and `String` values.
open class ITMKeychainHelper {
    private let service: String
    private let account: String

    /// Create a keychain helper.
    /// - Parameters:
    ///   - service: The service this helper uses in the iOS keychain.
    ///   - account: The account this helper uses in the iOS keychain.
    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// Creates a dictionary populated with the common keys and values needed for every keychain query.
    ///
    /// Override this function in a subclass in order to add custom behavior.
    /// - Returns: A dictionary with the common query items.
    open func commonKeychainQuery() -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Loads the stored secret `Data` value from the app keychain.
    /// - Returns: A `Data` value with the arbitrary secret data, or `nil` if nothing is currently saved in the keychain.
    public func loadData() -> Data? {
        var getQuery = commonKeychainQuery()
        getQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        getQuery[kSecReturnData as String] = kCFBooleanTrue
        var item: CFTypeRef?
        let status = SecItemCopyMatching(getQuery as CFDictionary, &item)
        if status != errSecItemNotFound, status != errSecSuccess {
            ITMApplication.logger.log(.warning, "ITMKeychain: Unknown load error: \(status)")
        }
        return status == errSecSuccess ? item as? Data : nil
    }

    /// Saves the given secret `Data` value to the app's keychain.
    /// - Parameter value: A `Data` value containing the secret data.
    /// - Returns: `true` if it succeeds, or `false` otherwise.
    @discardableResult public func save(data: Data) -> Bool {
        var query = commonKeychainQuery()
        let secValueData = kSecValueData as String
        query[secValueData] = data
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(commonKeychainQuery() as CFDictionary, [secValueData: data] as CFDictionary)
        }
        return status == errSecSuccess
    }

    /// Deletes the secret data from the app's keychain.
    /// - Returns: true if it succeeds, or false otherwise.
    @discardableResult public func deleteData() -> Bool {
        let status = SecItemDelete(commonKeychainQuery() as CFDictionary)
        return status == errSecSuccess
    }
}
