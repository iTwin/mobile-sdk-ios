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
    }
    /// The user info from the auth server.
    public var userInfo: NSDictionary?
    /// The service configuration from the issuer URL.
    public var serviceConfig: OIDServiceConfiguration?
    private var currentAuthorizationFlow: OIDExternalUserAgentSession?

    /// Initializes and returns a newly allocated authorization client object with the specified view controller.
    /// - Parameter itmApplication: The ``ITMApplication`` in which this ``ITMOIDCAuthorizationClient`` is being used.
    /// - Parameter viewController: The view controller in which to display the sign in Safari WebView.
    /// - Parameter configData: A JSON object containing at least an `ITMAPPLICATION_CLIENT_ID` value, and optionally `ITMAPPLICATION_ISSUER_URL`, `ITMAPPLICATION_REDIRECT_URI`, and/or `ITMAPPLICATION_SCOPE` values. If `ITMAPPLICATION_CLIENT_ID` is not present this initializer will fail.
    public init?(itmApplication: ITMApplication, viewController: UIViewController? = nil, configData: JSON) {
        self.itmApplication = itmApplication
        self.viewController = viewController
        super.init()
        let issuerUrl = configData["ITMAPPLICATION_ISSUER_URL"] as? String ?? "https://ims.bentley.com/"
        let clientId = configData["ITMAPPLICATION_CLIENT_ID"] as? String ?? ""
        let redirectUrl = configData["ITMAPPLICATION_REDIRECT_URI"] as? String ?? "imodeljs://app/signin-callback"
        let scope = configData["ITMAPPLICATION_SCOPE"] as? String ?? "email openid profile organization itwinjs"
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
        self.authState = nil
        self.userInfo = nil
        self.serviceConfig = nil
        if let archivedKeychainData = loadFromKeychain(),
           let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archivedKeychainData) {
            unarchiver.requiresSecureCoding = false
            if let keychainDict = unarchiver.decodeObject(of: NSDictionary.self, forKey: NSKeyedArchiveRootObjectKey) {
                self.authState = keychainDict["access-token"] as? OIDAuthState
                self.userInfo = keychainDict["user-info"] as? NSDictionary
                self.serviceConfig = keychainDict["service-config"] as? OIDServiceConfiguration
            }
        }
    }
    
    /// Saves the ITMOIDCAuthorizationClient's state data to the keychain.
    open func saveState() {
        var keychainDict: [String: Any] = [:]
        if let authState = authState {
            keychainDict["access-token"] = authState
        }
        if let userInfo = userInfo {
            keychainDict["user-info"] = userInfo
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
            signIn() { error in
                if let error = error {
                    completion(error)
                } else {
                    self.refreshAccessToken(completion)
                }
            }
            return
        }
        authState.performAction() { accessToken, idToken, error in
            if let error = error as? NSError {
                ITMApplication.logger.log(.error, "Error fetching fresh tokens: \(error)")
                if self.isInvalidGrantError(error) || self.isTokenRefreshError(error) {
                    self.innerSignOut()
                    self.signIn(completion)
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
            completion(error(reason: "ITMOIDCAuthorizationClient: not initialized"))
            return
        }
        guard let redirectUrl = URL(string: authSettings.redirectUrl) else {
            completion(error(reason: "ITMOIDCAuthorizationClient: invalid or empty redirectUrl"))
            return
        }
        guard let serviceConfig = serviceConfig else {
            completion(error(reason: "ITMOIDCAuthorizationClient: missing server config"))
            return
        }
        guard let clientID = clientID else {
            completion(error(reason: "ITMOIDCAuthorizationClient: missing clientID"))
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
                self.currentAuthorizationFlow = OIDAuthState.authState(byPresenting: request, presenting: viewController) { authState, error in
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
            throw error(reason: "ITMOIDCAuthorizationClient: initialize() was never called")
        }
        if authSettings.clientId.count == 0 {
            throw error(reason: "ITMOIDCAuthorizationClient: initialize() was called with invalid or empty clientId")
        }
        if authSettings.scope.count == 0 {
            throw error(reason: "ITMOIDCAuthorizationClient: initialize() was called with invalid or empty scope")
        }
        guard let _ = URL(string: authSettings.redirectUrl) else {
            throw error(reason: "ITMOIDCAuthorizationClient: initialize() was called with invalid or empty redirectUrl")
        }
        guard let _ = URL(string: authSettings.issuerUrl) else {
            throw error(reason: "ITMOIDCAuthorizationClient: initialize() was called with invalid or empty issuerUrl")
        }
    }
    
    /// Fetch and store the userInfo data from the userinfo endpoint, if needed. If userInfo has already been fetched, just call the completion.
    /// - Parameter completion: The callback to call once the userInfo has been stored.
    open func fetchUserInfo(_ completion: @escaping (Result<(), Error>) -> Void) {
        if userInfo != nil {
            if JSONSerialization.string(withITMJSONObject: userInfo) != nil {
                completion(.success(()))
            } else {
                userInfo = nil
            }
        }
        guard let authState = authState else {
            completion(.failure(error(reason: "ITMOIDCAuthorizationClient not signed in")))
            return
        }
        guard let userinfoEnpoint = authState.lastAuthorizationResponse.request.configuration.discoveryDocument?.userinfoEndpoint else {
            completion(.failure(error(reason: "ITMOIDCAuthorizationClient: Userinfo endpoint not declared in discovery document")))
            return
        }
        authState.performAction() { accessToken, idToken, error in
            if let error = error {
                ITMApplication.logger.log(.error, "ITMOIDCAuthorizationClient: Error fetching fresh tokens: \(error)")
                completion(.failure(error))
                return
            }
            guard let accessToken = accessToken else {
                completion(.failure(self.error(reason: "ITMOIDCAuthorizationClient: No access token after fetching fresh tokens")))
                return
            }
            Task { @MainActor in
                var request = URLRequest(url: userinfoEnpoint)
                request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw self.error(reason: "ITMOIDCAuthorizationClient: Response not HTTP fetching user info")
                    }
                    guard let jsonDictionaryOrArray = try? JSONSerialization.jsonObject(with: data, options: []) else {
                        throw self.error(reason: "ITMOIDCAuthorizationClient: Error parsing response as JSON")
                    }
                    guard let jsonDictionary = jsonDictionaryOrArray as? [AnyHashable: Any] else {
                        throw self.error(reason: "ITMOIDCAuthorizationClient: Error parsing response as JSON")
                    }
                    if httpResponse.statusCode != 200 {
                        // Server replied with an error
                        if httpResponse.statusCode == 401 {
                            // "401 Unauthorized" generally indicates there is an issue with the authorization
                            // grant. Puts OIDAuthState into an error state.
                            let oauthError = OIDErrorUtilities.resourceServerAuthorizationError(withCode: 0, errorResponse: jsonDictionary, underlyingError: error)
                            authState.update(withAuthorizationError: oauthError)
                            ITMApplication.logger.log(.error, "ITMOIDCAuthorizationClient: Authorization error: \(oauthError)")
                            throw self.error(reason: "ITMOIDCAuthorizationClient: Authorization error")
                        } else {
                            if let error = error {
                                throw self.error(reason: "ITMOIDCAuthorizationClient: Unknown error: \(error)")
                            } else {
                                throw self.error(reason: "ITMOIDCAuthorizationClient: Unknown error")
                            }
                        }
                    }
                    // Success response
                    self.userInfo = jsonDictionary as NSDictionary
                    completion(.success(()))
                } catch let error as NSError {
                    if error.userInfo[ITMAuthorizationClientErrorKey] as? Bool == true {
                        completion(.failure(error))
                    } else {
                        completion(.failure(self.error(reason: "ITMOIDCAuthorizationClient: HTTP Request failed fetching user info: \(error)")))
                    }
                }
            }
        }
    }
    
    private func innerSignOut() {
        deleteFromKeychain()
        authState = nil
        serviceConfig = nil
        userInfo = nil
    }

    // MARK: - OIDAuthStateChangeDelegate Protocol implementation

    /// Called when the authorization state changes and any backing storage needs to be updated.
    /// - Parameter state: The OIDAuthState that changed.
    /// - Note: If you are storing the authorization state, you should update the storage when the state changes.
    public func didChange(_ state: OIDAuthState) {
        stateChanged()
        raiseOnAccessTokenChanged()
    }

    // MARK: - OIDAuthStateErrorDelegate Protocol implementation

    public func authState(_ state: OIDAuthState, didEncounterAuthorizationError error: Error) {
        ITMApplication.logger.log(.error, "ITMOIDCAuthorizationClient didEncounterAuthorizationError: \(error)")
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
            completion(error(reason: "ITMOIDCAuthorizationClient not initialized"))
            return
        }
        guard let issuerUrl = URL(string: authSettings.issuerUrl) else {
            completion(error(reason: "AuthSettings provided issuer URL that is invalid"))
            return
        }
        if serviceConfig == nil {
            OIDAuthorizationService.discoverConfiguration(forIssuer: issuerUrl) { serviceConfig, error in
                if let error = error {
                    ITMApplication.logger.log(.error, "Failed to discover issuer configuration from \(issuerUrl): Error \(error)")
                    completion(error)
                    return
                }
                self.serviceConfig = serviceConfig
                self.saveState()
                self.signIn(completion)
            }
            return
        }
        if authState == nil {
            doAuthCodeExchange(serviceConfig: serviceConfig, clientID: authSettings.clientId, clientSecret: nil) { error in
                completion(error)
                self.raiseOnAccessTokenChanged()
            }
        } else {
            refreshAccessToken() { error in
                if error == nil {
                    completion(error)
                } else {
                    // Refresh failed; sign out and try again from scratch.
                    self.innerSignOut()
                    self.signIn(completion)
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
        raiseOnAccessTokenChanged()
        completion(nil)
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
        refreshAccessToken() { error in
            if let error = error {
                completion(nil, nil, error)
                return
            }
            self.fetchUserInfo() { response in
                switch response {
                case .failure(let error):
                    completion(nil, nil, error)
                case .success:
                    guard let authState = self.authState,
                          let lastTokenResponse = authState.lastTokenResponse else {
                        completion(nil, nil, self.error(reason: "No token after refresh"))
                        return
                    }
                    guard let tokenString = lastTokenResponse.accessToken else {
                        completion(nil, nil, self.error(reason: "Invalid token after refresh"))
                        return
                    }
                    guard let expirationDate = lastTokenResponse.accessTokenExpirationDate else {
                        completion(nil, nil, self.error(reason: "Invalid expiration date after refresh"))
                        return
                    }
                    completion("Bearer \(tokenString)", expirationDate, nil)
                }
            }
        }
    }
}
