/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import IModelJsNative
import AppAuth
#if SWIFT_PACKAGE
import AppAuthCore
#endif

// MARK: - Helpers

/// A struct to hold the settings used by ITMOIDCAuthorizationClient
public struct ITMOIDCAuthSettings {
    public var issuerUrl: String
    public var clientId: String
    public var redirectUrl: String
    public var scope: String
}

public typealias ITMOIDCAuthorizationClientCallback = (Error?) -> Void

// MARK: - ITMOIDCAuthorizationClient class

/// An implementation of the AuthorizationClient protocol that uses the AppAuth library to prompt the user.
open class ITMOIDCAuthorizationClient: NSObject, ITMAuthorizationClient, OIDAuthStateChangeDelegate, OIDAuthStateErrorDelegate {
    /// Instance for `onAccessTokenChanged` property from the `AuthorizationClient` protocol.
    public var onAccessTokenChanged: AccessTokenChangedCallback?
    /// Instance for `errorDomain` property from the `ITMAuthorizationClient` protocol.
    public let errorDomain = "com.bentley.itwin-mobile-sdk"

    /// The AuthSettings object from imodeljs.
    public var authSettings: ITMOIDCAuthSettings?
    public let itmApplication: ITMApplication
    /// The UIViewController into which to display the sign in Safari WebView.
    public let viewController: UIViewController?
    /// The OIDAuthState from the AppAuth library
    public var authState: OIDAuthState? {
        willSet {
            authState?.stateChangeDelegate = nil
            authState?.errorDelegate = nil
            newValue?.stateChangeDelegate = self
            newValue?.errorDelegate = self
        }
        didSet {
            saveState()
        }
    }
    /// The service configuration from the issuer URL.
    public var serviceConfig: OIDServiceConfiguration? {
        didSet {
            saveState()
        }
    }
    private var currentAuthorizationFlow: OIDExternalUserAgentSession?
    private var loadStateActive = false

    /// Initializes and returns a newly allocated authorization client object with the specified view controller.
    /// - Parameter itmApplication: The ``ITMApplication`` in which this ``ITMOIDCAuthorizationClient`` is being used.
    /// - Parameter viewController: The view controller in which to display the sign in Safari WebView.
    /// - Parameter configData: A JSON object containing at least an `ITMAPPLICATION_CLIENT_ID` value, and optionally `ITMAPPLICATION_ISSUER_URL`, `ITMAPPLICATION_REDIRECT_URI`, `ITMAPPLICATION_SCOPE`, and/or `ITMAPPLICATION_API_PREFIX` values. If `ITMAPPLICATION_CLIENT_ID` is not present this initializer will fail.
    public init?(itmApplication: ITMApplication, viewController: UIViewController? = nil, configData: JSON) {
        self.itmApplication = itmApplication
        self.viewController = viewController
        super.init()
        let apiPrefix = configData["ITMAPPLICATION_API_PREFIX"] as? String ?? ""
        let issuerUrl = configData["ITMAPPLICATION_ISSUER_URL"] as? String ?? "https://\(apiPrefix)ims.bentley.com/"
        let clientId = configData["ITMAPPLICATION_CLIENT_ID"] as? String ?? ""
        let redirectUrl = configData["ITMAPPLICATION_REDIRECT_URI"] as? String ?? "imodeljs://app/signin-callback"
        let scope = configData["ITMAPPLICATION_SCOPE"] as? String ?? "email openid profile organization itwinjs offline_access"
        authSettings = ITMOIDCAuthSettings(issuerUrl: issuerUrl, clientId: clientId, redirectUrl: redirectUrl, scope: scope)
        
        do {
            try checkSettings()
        } catch {
            return nil
        }
        loadState()
    }

    /// Creates a mutable dictionary populated with the common keys and values needed for every keychain query.
    /// - Returns: An NSMutableDictionary with the common query items, or nil if issuerUrl and clientId are not set in authSettings.
    public func commonKeychainQuery() -> NSMutableDictionary? {
        guard let issuerUrl = authSettings?.issuerUrl,
              let clientId = authSettings?.clientId else {
            return nil
        }
        return (([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ITMOIDCAuthorizationClient",
            kSecAttrAccount as String: "\(issuerUrl)@\(clientId)",
        ] as NSDictionary).mutableCopy() as! NSMutableDictionary)
    }
    
    /// Loads the stored secret data from the app keychain.
    /// - Returns: A Data object with the encoded secret data, or nil if nothing is currently saved in the keychain.
    public func loadFromKeychain() -> Data? {
        guard let getQuery = commonKeychainQuery() else {
            return nil
        }
        getQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        getQuery[kSecReturnData as String] = kCFBooleanTrue
        var item: CFTypeRef?
        let status = SecItemCopyMatching(getQuery as CFMutableDictionary, &item)
        if status != errSecItemNotFound, status != errSecSuccess {
            ITMApplication.logger.log(.warning, "Unknown error: \(status)")
        }
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }
    
    /// Saves the given secret data to the app's keychain.
    /// - Parameter value: A Data object containing the ITMOIDCAuthorizationClient secret data.
    /// - Returns: true if it succeeds, or false otherwise.
    @discardableResult public func saveToKeychain(value: Data) -> Bool {
        guard let query = commonKeychainQuery() else {
            return false
        }
        query[kSecValueData as String] = value
        var status = SecItemAdd(query as CFMutableDictionary, nil)
        if status == errSecDuplicateItem {
            query.removeObject(forKey: kSecValueData as String)
            status = SecItemUpdate(query as CFMutableDictionary, [kSecValueData as String: value] as CFDictionary)
        }
        return status == errSecSuccess
    }
    
    /// Deletes the ITMOIDCAuthorizationClient secret data from the app's keychain.
    /// - Returns: true if it succeeds, or false otherwise.
    @discardableResult public func deleteFromKeychain() -> Bool {
        guard let deleteQuery = commonKeychainQuery() as CFDictionary? else {
            return false
        }
        let status = SecItemDelete(deleteQuery)
        return status == errSecSuccess
    }
    
    /// Loads the ITMOIDCAuthorizationClient's state data from the keychain.
    open func loadState() {
        loadStateActive = true
        authState = nil
        serviceConfig = nil
        if let archivedKeychainData = loadFromKeychain(),
           let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archivedKeychainData) {
            unarchiver.requiresSecureCoding = false
            if let keychainDict = unarchiver.decodeObject(of: NSDictionary.self, forKey: NSKeyedArchiveRootObjectKey) {
                authState = keychainDict["auth-state"] as? OIDAuthState
                serviceConfig = keychainDict["service-config"] as? OIDServiceConfiguration
            }
        }
        loadStateActive = false
    }
    
    /// Saves the ITMOIDCAuthorizationClient's state data to the keychain.
    open func saveState() {
        if loadStateActive { return }
        var keychainDict: [String: Any] = [:]
        if let authState = authState {
            keychainDict["auth-state"] = authState
        }
        if let serviceConfig = serviceConfig {
            keychainDict["service-config"] = serviceConfig
        }
        if !keychainDict.isEmpty {
            let nsDict = NSDictionary(dictionary: keychainDict)
            if let archivedKeychainDict = try? NSKeyedArchiver.archivedData(withRootObject: nsDict, requiringSecureCoding: true) {
                saveToKeychain(value: archivedKeychainDict)
            }
        }
    }
    
    /// Called when the auth state changes.
    open func stateChanged() {
        saveState()
    }
    
    private func isInvalidGrantError(_ error: NSError) -> Bool {
        return error.code == OIDErrorCodeOAuth.invalidGrant.rawValue && error.domain == OIDOAuthTokenErrorDomain
    }

    private func isTokenRefreshError(_ error: NSError) -> Bool {
        return error.code == OIDErrorCode.tokenRefreshError.rawValue && error.domain == OIDGeneralErrorDomain
    }

    /// Refreshes the user's access token.
    /// - Parameter completion: Callback to call upon success or error.
    open func refreshAccessToken(_ completion: @escaping ITMOIDCAuthorizationClientCallback) {
        guard let authState = authState else {
            signIn() { [self] error in
                if let error = error {
                    completion(error)
                } else {
                    refreshAccessToken(completion)
                }
            }
            return
        }
        authState.performAction() { [self] accessToken, idToken, error in
            if let error = error as? NSError {
                ITMApplication.logger.log(.error, "Error fetching fresh tokens: \(error)")
                if isInvalidGrantError(error) || isTokenRefreshError(error) {
                    innerSignOut()
                    signIn(completion)
                } else {
                    completion(error)
                }
                return
            }
            completion(error)
        }
    }
    
    /// Presents a Safari WebView to the user to sign in.
    /// - Parameters:
    ///   - serviceConfig: The service configuration for the issuer URL.
    ///   - clientID: The imodeljs app's clientID.
    ///   - clientSecret: The optional clientSecret.
    ///   - completion: The callback to call upon success or error.
    open func doAuthCodeExchange(serviceConfig: OIDServiceConfiguration?, clientID: String?, clientSecret: String?, onComplete completion: @escaping ITMOIDCAuthorizationClientCallback) {
        guard let authSettings = authSettings else {
            completion(createError(reason: "ITMOIDCAuthorizationClient: not initialized"))
            return
        }
        guard let redirectUrl = URL(string: authSettings.redirectUrl) else {
            completion(createError(reason: "ITMOIDCAuthorizationClient: invalid or empty redirectUrl"))
            return
        }
        guard let serviceConfig = serviceConfig else {
            completion(createError(reason: "ITMOIDCAuthorizationClient: missing server config"))
            return
        }
        guard let clientID = clientID else {
            completion(createError(reason: "ITMOIDCAuthorizationClient: missing clientID"))
            return
        }
        let scopes = NSString(string: authSettings.scope).components(separatedBy: " ")
        let request = OIDAuthorizationRequest(configuration: serviceConfig,
                                              clientId: clientID,
                                              clientSecret: clientSecret,
                                              scopes: scopes,
                                              redirectURL: redirectUrl,
                                              responseType: OIDResponseTypeCode,
                                              additionalParameters: nil)
        Task { @MainActor in
            if let viewController = ITMApplication.topViewController {
                // Note: The return value below is only really used by AppAuth in versions of iOS prior to iOS 11.
                // However, even though we require iOS 12.2, if we ignore the value, it gets deleted by the system,
                // which prevents everything from working. So, store the value in our member variable.
                currentAuthorizationFlow = OIDAuthState.authState(byPresenting: request, presenting: viewController) { authState, error in
                    self.authState = authState
                    if authState == nil {
                        if let error = error {
                            ITMApplication.logger.log(.warning, "Authorization error: \(error.localizedDescription)")
                        } else {
                            ITMApplication.logger.log(.error, "Unknown authorization error")
                        }
                    }
                    completion(error)
                }
            }
        }
    }
    
    /// Check to see if the authSettings member variable contains valid data.
    /// - Throws: an error if the settings aren't valid
    open func checkSettings() throws {
        guard let authSettings = authSettings else {
            throw createError(reason: "ITMOIDCAuthorizationClient: initialize() was never called")
        }
        if authSettings.clientId.count == 0 {
            throw createError(reason: "ITMOIDCAuthorizationClient: initialize() was called with invalid or empty clientId")
        }
        if authSettings.scope.count == 0 {
            throw createError(reason: "ITMOIDCAuthorizationClient: initialize() was called with invalid or empty scope")
        }
        guard let _ = URL(string: authSettings.redirectUrl) else {
            throw createError(reason: "ITMOIDCAuthorizationClient: initialize() was called with invalid or empty redirectUrl")
        }
        guard let _ = URL(string: authSettings.issuerUrl) else {
            throw createError(reason: "ITMOIDCAuthorizationClient: initialize() was called with invalid or empty issuerUrl")
        }
    }

    private func innerSignOut() {
        deleteFromKeychain()
        authState = nil
        serviceConfig = nil
    }

    public var isAuthorized: Bool {
        get {
            return authState?.isAuthorized ?? false
        }
    }

    open func signIn(_ completion: @escaping ITMOIDCAuthorizationClientCallback) {
        do {
            try checkSettings()
        } catch {
            completion(error)
            return
        }
        guard let authSettings = authSettings else {
            completion(createError(reason: "ITMOIDCAuthorizationClient not initialized"))
            return
        }
        guard let issuerUrl = URL(string: authSettings.issuerUrl) else {
            completion(createError(reason: "AuthSettings provided issuer URL that is invalid"))
            return
        }
        if serviceConfig == nil {
            OIDAuthorizationService.discoverConfiguration(forIssuer: issuerUrl) { [self] serviceConfig, error in
                if let error = error {
                    ITMApplication.logger.log(.error, "Failed to discover issuer configuration from \(issuerUrl): Error \(error)")
                    completion(error)
                    return
                }
                self.serviceConfig = serviceConfig
                signIn(completion)
            }
            return
        }
        if authState == nil {
            doAuthCodeExchange(serviceConfig: serviceConfig, clientID: authSettings.clientId, clientSecret: nil) { error in
                completion(error)
            }
        } else {
            refreshAccessToken() { [self] error in
                if error == nil {
                    completion(error)
                } else {
                    // Refresh failed; sign out and try again from scratch.
                    innerSignOut()
                    signIn(completion)
                }
            }
        }
    }

    open func signOut(_ completion: @escaping ITMOIDCAuthorizationClientCallback) {
        do {
            try checkSettings()
        } catch {
            completion(error)
            return
        }
        innerSignOut()
        raiseOnAccessTokenChanged(nil, nil)
        completion(nil)
    }
    
    /// Returns the access token from the given `OIDTokenResponse`, if present, with the appropriate token type prefix.
    /// - Parameter response: The `OIDTokenResponse` containing the token.
    /// - Returns: The access token from `response`, or nil if it is not present or if `response` is nil.
    open class func getToken(response: OIDTokenResponse?) -> String? {
        if let accessToken = response?.accessToken {
            return "\(response?.tokenType ?? "Bearer") \(accessToken)"
        }
        return nil
    }
    
    /// Returns the access token from the given `OIDAuthState`, if present, with the appropriate token type prefix.
    /// - Parameter authState: `OIDAuthState` value possibly containing a token in its `lastTokenResponse` field.
    /// - Returns: The access token from `authState`, or nil if there isn't one.
    open class func getToken(authState: OIDAuthState) -> String? {
        getToken(response: authState.lastTokenResponse)
    }

    // MARK: - OIDAuthStateChangeDelegate Protocol implementation

    /// Called when the authorization state changes and any backing storage needs to be updated.
    /// - Parameter state: The OIDAuthState that changed.
    /// - Note: If you are storing the authorization state, you should update the storage when the state changes.
    public func didChange(_ state: OIDAuthState) {
        self.authState = state
        stateChanged()
        raiseOnAccessTokenChanged(Self.getToken(authState: state), state.lastTokenResponse?.accessTokenExpirationDate)
    }

    // MARK: - OIDAuthStateErrorDelegate Protocol implementation

    public func authState(_ state: OIDAuthState, didEncounterAuthorizationError error: Error) {
        ITMApplication.logger.log(.error, "ITMOIDCAuthorizationClient didEncounterAuthorizationError: \(error)")
    }

    // MARK: - AuthorizationClient Protocol implementation
    open func getAccessToken(_ completion: @escaping GetAccessTokenCallback) {
        do {
            try checkSettings()
        } catch {
            completion(nil, nil, error)
            return
        }
        if !itmApplication.itmMessenger.frontendLaunchDone {
            completion(nil, nil, nil)
            return
        }
        refreshAccessToken() { [self] error in
            if let error = error {
                completion(nil, nil, error)
                return
            }
            guard let authState = authState,
                  let lastTokenResponse = authState.lastTokenResponse else {
                completion(nil, nil, createError(reason: "No token after refresh"))
                return
            }
            guard let token = Self.getToken(authState: authState) else {
                completion(nil, nil, createError(reason: "Invalid token after refresh"))
                return
            }
            guard let expirationDate = lastTokenResponse.accessTokenExpirationDate else {
                completion(nil, nil, createError(reason: "Invalid expiration date after refresh"))
                return
            }
            completion(token, expirationDate, nil)
        }
    }
}
