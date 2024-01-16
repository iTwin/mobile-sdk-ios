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
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Loads the stored secret data from the app keychain as an `NSKeyedUnarchiver`.
    /// - Note: You must call `finishDecoding` on the returned value after using it to decode.
    /// - Returns: An `NSKeyedUnarchiver` ready to decode the secret data, or `nil` if nothing is currently saved
    /// in the keychain, or the data in the keychain isn't a valid keyed archive.
    public func loadUnarchiver() -> NSKeyedUnarchiver? {
        if let archivedKeychainData = loadData(),
           let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archivedKeychainData) {
            unarchiver.requiresSecureCoding = false
            return unarchiver
        }
        return nil
    }

    /// Loads the stored secret data from the app keychain as a `Dictionary`.
    /// - Returns: A `Dictionary` containing the secret data, or `nil` if nothing is currently saved in the keychain,
    /// or the data stored in the keychain isn't a `Dictionary`.
    public func loadDict() -> [String: Any]? {
        if let unarchiver = loadUnarchiver() {
            defer {
                unarchiver.finishDecoding()
            }
            if let keychainDict = unarchiver.decodeObject(of: NSDictionary.self, forKey: NSKeyedArchiveRootObjectKey) {
                return keychainDict as? [String: Any]
            }
        }
        return nil
    }

    /// Loads the stored secret data from the app keychain as a `String`.
    /// - Returns: A `String` containing the secret data, or `nil` if nothing is currently saved in the keychain,
    /// or the data stored in the keychain isn't a `String`.
    public func loadString() -> String? {
        if let unarchiver = loadUnarchiver() {
            defer {
                unarchiver.finishDecoding()
            }
            if let keychainString = unarchiver.decodeObject(of: NSString.self, forKey: NSKeyedArchiveRootObjectKey) {
                return keychainString as String
            }
        }
        return nil
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

    /// Saves the given secret `Dictionary` value to the app's keychain.
    /// - Parameter value: A `Dictionary` value containing the secret data.
    /// - Returns: `true` if it succeeds, or `false` otherwise.
    @discardableResult public func save(dict: Dictionary<String, Any>) -> Bool {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: dict as NSDictionary, requiringSecureCoding: true) {
            return save(data: data)
        }
        return false
    }

    /// Saves the given secret `String` value to the app's keychain.
    /// - Parameter value: A `String` value containing the secret data.
    /// - Returns: `true` if it succeeds, or `false` otherwise.
    @discardableResult public func save(string: String) -> Bool {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: string as NSString, requiringSecureCoding: true) {
            return save(data: data)
        }
        return false
    }

    /// Deletes the secret data from the app's keychain.
    /// - Returns: true if it succeeds, or false otherwise.
    @discardableResult public func deleteData() -> Bool {
        let status = SecItemDelete(commonKeychainQuery() as CFDictionary)
        return status == errSecSuccess
    }
}
