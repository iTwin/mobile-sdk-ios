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

internal extension Set {
    mutating func insertIfNotNull(_ element: Element?) {
        if let element = element {
            insert(element)
        }
    }
}

public typealias ITMOIDCAuthorizationClientCallback = (Error?) -> Void

/// Extension to add async wrappers to `OIDAuthState` functions that don't get them automatically.
///
/// See [here](https://developer.apple.com/documentation/swift/calling-objective-c-apis-asynchronously)
/// for automatic wrapper rules.
public extension OIDAuthState {
    /// async wrapper for `-performActionWithFreshTokens:` Objective-C function.
    /// - Returns: A tuple containing the optional authorizationToken and idToken.
    /// - Throws: If the `OIDAuthStateAction` callback has a non-nil `error`, that error is thrown.
    @discardableResult
    func performAction() async throws -> (String?, String?) {
        // The action parameter of -performActionWithFreshTokens: doesn't trigger an automatic async wrapper.
        return try await withCheckedThrowingContinuation { continuation in
            self.performAction() { accessToken, idToken, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (accessToken, idToken))
            }
        }
    }
    
    /// async wrapper for `+authStateByPresentingAuthorizationRequest:presentingViewController:callback:`
    /// Objective-C function.
    /// - Note: Because the return value for the original function is not used with the app delegate in iOS 11 and later, that is hidden by this function.
    /// - Returns: The auth state, if the authorization request succeeded.
    /// - Throws: If the `OIDAuthStateAuthorizationCallback` has a non-nil `error`, that error is thrown. Also, if
    /// `OIDAuthStateAuthorizationCallback` produces a nil `authState`, an exception is thrown.
    @MainActor
    static func authState(byPresenting request: (OIDAuthorizationRequest), presenting viewController: UIViewController) async throws -> OIDAuthState {
        // +authStateByPresentingAuthorizationRequest:presentingViewController:callback: returns a value,
        // so isn't eligible for an automatic async wrapper.
        return try await withCheckedThrowingContinuation { continuation in
            // Note: The return value below is only really used by AppAuth in versions of iOS prior to iOS 11.
            // However, even though we require an iOS version later than 11, if we ignore the value, it gets
            // deleted by Swift, which prevents everything from working. So, store the value in a static member
            // variable.
            ITMOIDCAuthorizationClient.currentAuthorizationFlow = Self.authState(byPresenting: request, presenting: viewController) { authState, error in
                ITMOIDCAuthorizationClient.currentAuthorizationFlow = nil
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let authState = authState else {
                    continuation.resume(throwing: NSError.authorizationClientError(domain: "com.bentley.itwin-mobile-sdk", reason: "Unknown authorization error"))
                    return
                }
                continuation.resume(returning: authState)
            }
        }
    }
}

// MARK: - ITMOIDCAuthorizationClient class

/// An implementation of the AuthorizationClient protocol that uses the AppAuth library to prompt the user.
open class ITMOIDCAuthorizationClient: NSObject, ITMAuthorizationClient, OIDAuthStateChangeDelegate, OIDAuthStateErrorDelegate {
    /// A struct to hold the settings used by ``ITMOIDCAuthorizationClient``
    public struct Settings {
        public var issuerURL: URL
        public var clientId: String
        public var redirectURL: URL
        public var scopes: [String]
    }

    /// Value for `errorDomain` property from the `ITMAuthorizationClient` protocol.
    public let errorDomain = "com.bentley.itwin-mobile-sdk"

    /// The settings for this ``ITMOIDCAuthorizationClient``. These are initialized using the contents of the `configData`
    /// parameter to ``init(itmApplication:viewController:configData:)``.
    public var settings: Settings
    /// Whether or not to include `prompt: login` in the additional parameters passed to the OIDC authorization request.
    ///
    /// By default, this is set to `true` in the constructor if `offline_access` is present in scopes.
    public var promptForLogin: Bool
    /// The ``ITMApplication`` using this authorization client.
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
    internal static var currentAuthorizationFlow: OIDExternalUserAgentSession?
    private var loadStateActive = false
    private let defaultScopes = "projects:read imodelaccess:read itwinjs organization profile email imodels:read realitydata:read savedviews:read savedviews:modify itwins:read openid offline_access"
    private let defaultRedirectUri = "imodeljs://app/signin-callback"

    /// Initializes and returns a newly allocated authorization client object with the specified view controller.
    /// - Parameters:
    ///   - itmApplication: The ``ITMApplication`` in which this ``ITMOIDCAuthorizationClient`` is being used.
    ///   - viewController: The view controller in which to display the sign in Safari WebView.
    ///   - configData: A JSON object containing at least an `ITMAPPLICATION_CLIENT_ID` value, and optionally
    ///   `ITMAPPLICATION_ISSUER_URL`, `ITMAPPLICATION_REDIRECT_URI`, `ITMAPPLICATION_SCOPE`, and/or
    ///   `ITMAPPLICATION_API_PREFIX` values. If `ITMAPPLICATION_CLIENT_ID` is not present or empty, this initializer will
    ///   fail. If the values in `ITMAPPLICATION_ISSUER_URL` or `ITMAPPLICATION_REDIRECT_URI` are not valid URLs, this
    ///   initializer will fail. If the value in `ITMAPPLICATION_SCOPE` is empty, this initializer will fail.
    public init?(itmApplication: ITMApplication, viewController: UIViewController? = nil, configData: JSON) {
        self.itmApplication = itmApplication
        self.viewController = viewController
        let apiPrefix = configData["ITMAPPLICATION_API_PREFIX"] as? String ?? ""
        let issuerURLString = configData["ITMAPPLICATION_ISSUER_URL"] as? String ?? "https://\(apiPrefix)ims.bentley.com/"
        let clientId = configData["ITMAPPLICATION_CLIENT_ID"] as? String ?? ""
        let redirectURLString = configData["ITMAPPLICATION_REDIRECT_URI"] as? String ?? defaultRedirectUri
        let scope = configData["ITMAPPLICATION_SCOPE"] as? String ?? defaultScopes
        guard let issuerURL = URL(string: issuerURLString),
              let redirectURL = URL(string: redirectURLString),
              !clientId.isEmpty,
              !scope.isEmpty else {
            return nil
        }
        settings = Settings(issuerURL: issuerURL, clientId: clientId, redirectURL: redirectURL, scopes: scope.components(separatedBy: " "))
        promptForLogin = settings.scopes.contains("offline_access")
        super.init()
        loadState()
    }

    /// Creates a dictionary populated with the common keys and values needed for every keychain query.
    /// - Returns: A dictionary with the common query items, or nil if issuerURL and clientId are not set in authSettings.
    public func commonKeychainQuery() -> [String: Any]? {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ITMOIDCAuthorizationClient",
            kSecAttrAccount as String: "\(settings.issuerURL)@\(settings.clientId)",
        ]
    }
    
    /// Loads the stored secret data from the app keychain.
    /// - Returns: A Data object with the encoded secret data, or nil if nothing is currently saved in the keychain.
    public func loadFromKeychain() -> Data? {
        guard var getQuery = commonKeychainQuery() else {
            return nil
        }
        getQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        getQuery[kSecReturnData as String] = kCFBooleanTrue
        var item: CFTypeRef?
        let status = SecItemCopyMatching(getQuery as CFDictionary, &item)
        if status != errSecItemNotFound, status != errSecSuccess {
            ITMApplication.logger.log(.warning, "Unknown error: \(status)")
        }
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }
    
    /// Saves the given secret data to the app's keychain.
    /// - Parameter value: A Data object containing the ``ITMOIDCAuthorizationClient`` secret data.
    /// - Returns: true if it succeeds, or false otherwise.
    @discardableResult public func saveToKeychain(value: Data) -> Bool {
        guard var query = commonKeychainQuery() else {
            return false
        }
        let secValueData = kSecValueData as String
        query[secValueData] = value
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            query.removeValue(forKey: secValueData)
            status = SecItemUpdate(query as CFDictionary, [secValueData: value] as CFDictionary)
        }
        return status == errSecSuccess
    }
    
    /// Deletes the ``ITMOIDCAuthorizationClient`` secret data from the app's keychain.
    /// - Returns: true if it succeeds, or false otherwise.
    @discardableResult public func deleteFromKeychain() -> Bool {
        guard let deleteQuery = commonKeychainQuery() else {
            return false
        }
        let status = SecItemDelete(deleteQuery as CFDictionary)
        return status == errSecSuccess
    }
    
    /// Loads the receiver's state data from the keychain.
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
            if let archivedKeychainDict = try? NSKeyedArchiver.archivedData(withRootObject: keychainDict as NSDictionary, requiringSecureCoding: true) {
                saveToKeychain(value: archivedKeychainDict)
            }
        }
    }
    
    /// Called when the auth state changes.
    open func stateChanged() {
        saveState()
    }
    
    private func isInvalidGrantError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.code == OIDErrorCodeOAuth.invalidGrant.rawValue && error.domain == OIDOAuthTokenErrorDomain
    }

    private func isTokenRefreshError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.code == OIDErrorCode.tokenRefreshError.rawValue && error.domain == OIDGeneralErrorDomain
    }

    /// Gets the access token and expiration date from the last token request.
    /// - Returns: A tuple containing an access token (with token type prefix) and its expiration date.
    /// - Throws: If a token request has not been made, or the last token request does not contain an access token and
    ///           expiration date, this will throw an exception.
    open func getLastAccessToken() throws -> (String, Date) {
        guard let lastTokenResponse = authState?.lastTokenResponse,
              let accessToken = Self.getToken(response: lastTokenResponse),
              let expirationDate = lastTokenResponse.accessTokenExpirationDate else {
            throw createError(reason: "Access token or expiration date not available")
        }
        return (accessToken, expirationDate)
    }
    
    /// Ensure that an auth state is available.
    /// - Returns: The current value of ``authState`` if that is non-nil, or the result of ``signIn()`` otherwise.
    /// - Throws: If ``authState`` is nil and ``signIn()`` throws an exception, that exception is thrown.
    public func requireAuthState() async throws -> OIDAuthState {
        // Note: this function exists because the following is not legal in Swift:
        // let authState = self.authState ?? try await signIn()
        // Neither try nor await is legal on the right hand side of ??.
        if let authState = authState {
            return authState
        }
        return try await signIn()
    }

    /// Refreshes the user's access token if needed.
    /// - Returns: A tuple containg an access token (with token type prefix) and its expiration date.
    /// - Throws: If there are any problems refreshing the access token, this will throw an exception.
    @discardableResult
    open func refreshAccessToken() async throws -> (String, Date) {
        let authState = try await requireAuthState()
        do {
            try await authState.performAction()
            return try getLastAccessToken()
        } catch {
            if self.isInvalidGrantError(error) || self.isTokenRefreshError(error) {
                do {
                    try? await self.signOut() // If signOut fails, ignore the failure.
                    try await signIn()
                    return try getLastAccessToken()
                } catch {
                    ITMApplication.logger.log(.error, "Error refreshing tokens: \(error)")
                    throw error
                }
            } else {
                ITMApplication.logger.log(.error, "Error refreshing tokens: \(error)")
                throw error
            }
        }
    }

    /// Ensure that a view controller is available.
    /// - Returns: ``viewController`` if that is non, nil, otherwise `ITMApplication.topViewController`.
    /// - Throws: If both ``viewController`` and `ITMApplication.topViewController` are nil, throws an exception.
    open func requireViewController() async throws -> UIViewController {
        if let viewController = viewController {
            return viewController
        }
        if let topViewController = await ITMApplication.topViewController {
            return topViewController
        }
        throw createError(reason: "No view controller is available.")
    }

    /// Presents a Safari WebView to the user to sign in.
    /// - Throws: Anything preventing the sign in (including user cancel and lack of internet) will throw an exception.
    open func doAuthCodeExchange() async throws -> OIDAuthState {
        let serviceConfig = try await requireServiceConfig()
        // NOTE: Bentley IMS sometimes doesn't give the user a chance to specify who they
        // are logging in as when prompt:login is missing. Due to the inability to truly
        // sign out, stuff gets left in the Safari cookies (or somewhere) that cause it to
        // just login again as the same user as before, even if the program called the
        // signout() function in this class. That would make it so that a user who signed
        // out and signed back in wasn't ask who they wanted to sign in as. I think that
        // this problem does not occur when offline_access is not present in scopes, so
        // by default promptForLogin is only true if offline_access is present in scopes.
        let request = OIDAuthorizationRequest(configuration: serviceConfig,
                                              clientId: settings.clientId,
                                              clientSecret: nil,
                                              scopes: settings.scopes,
                                              redirectURL: settings.redirectURL,
                                              responseType: OIDResponseTypeCode,
                                              additionalParameters: promptForLogin ? ["prompt": "login"] : nil)
        let viewController = try await requireViewController()
        do {
            let authState = try await OIDAuthState.authState(byPresenting: request, presenting: viewController)
            self.authState = authState
            return authState
        } catch {
            authState = nil
            ITMApplication.logger.log(.warning, "Authorization error: \(error.localizedDescription)")
            throw error
        }
    }

    /// Ensure that a service configuration is available.
    /// - Returns: The `OIDServiceConfiguration` fetched from the OIDC server.
    /// - Throws: If there are any problems fetching the service configuration, an exception is thrown.
    open func requireServiceConfig() async throws -> OIDServiceConfiguration {
        if let serviceConfig = serviceConfig {
            return serviceConfig
        }
        do {
            let serviceConfig = try await OIDAuthorizationService.discoverConfiguration(forIssuer: settings.issuerURL)
            self.serviceConfig = serviceConfig
            return serviceConfig
        } catch {
            self.serviceConfig = nil
            ITMApplication.logger.log(.error, "Failed to discover issuer configuration from \(settings.issuerURL): Error \(error)")
            throw error
        }
    }

    /// Revoke the given token.
    /// - Parameters:
    ///   - revokeURL: The OIDC server's token revocation URL.
    ///   - clientId: The clientId of the token being revoked.
    ///   - token: The token to revoke.
    /// - Throws: If anything prevents the token from being revoked, an exception is thrown.
    open class func revokeToken(_ revokeURL: URL, _ clientId: String, _ token: String) async throws {
        var request = URLRequest(url: revokeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \("\(clientId):".toBase64())", forHTTPHeaderField: "Authorization")
        request.httpBody = "token=\(token)".data(using: .utf8)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw NSError.authorizationClientError(domain: "com.bentley.itwin-mobile-sdk", reason: "Response revoking token is not http.")
        }
        if response.statusCode != 200 {
            throw NSError.authorizationClientError(domain: "com.bentley.itwin-mobile-sdk", reason: "Wrong status code in revoke token response: \(response.statusCode)")
        }
    }

    private func revokeTokens() async throws {
        guard let authState = authState else { return }
        var tokens = Set<String>()
        tokens.insertIfNotNull(authState.lastTokenResponse?.idToken)
        tokens.insertIfNotNull(authState.lastAuthorizationResponse.idToken)
        tokens.insertIfNotNull(authState.lastTokenResponse?.accessToken)
        tokens.insertIfNotNull(authState.lastAuthorizationResponse.accessToken)
        tokens.insertIfNotNull(authState.refreshToken)
        tokens.insertIfNotNull(authState.lastTokenResponse?.refreshToken)
        if tokens.isEmpty { return }
        let serviceConfig = try await requireServiceConfig()
        guard let revokeURLString = serviceConfig.discoveryDocument?.discoveryDictionary["revocation_endpoint"] as? String,
              let revokeURL = URL(string: revokeURLString) else {
            throw createError(reason: "Could not find valid revocation URL.")
        }
        guard let scheme = revokeURL.scheme,
              scheme.localizedCompare("https") == .orderedSame else {
            throw createError(reason: "Token revocation URL is not https.")
        }
        var errors: [String] = []
        for token in tokens {
            do {
                try await Self.revokeToken(revokeURL, settings.clientId, token)
            } catch {
                errors.append("\(error)")
            }
        }
        if !errors.isEmpty {
            throw createError(reason: "Error\(errors.count > 1 ? "s" : "") revoking tokens:\n\(errors.joined(separator: "\n"))")
        }
    }

    /// Sign in to OIDC and fetch ``serviceConfig`` and ``authState`` if necessary.
    /// - Returns: The `OIDAuthState` object generated by the sign in.
    /// - Throws: Anything preventing the sign in (including user cancel and lack of internet) will throw an exception.
    @discardableResult
    open func signIn() async throws -> OIDAuthState {
        if authState == nil {
            return try await doAuthCodeExchange()
        } else {
            do {
                try await refreshAccessToken()
                guard let authState = authState else {
                    throw createError(reason: "No auth state after refreshAccessToken")
                }
                return authState
            } catch {
                // Refresh failed; sign out and try again from scratch.
                try? await signOut() // If signOut fails, ignore the failure.
                return try await signIn()
            }
        }
    }
    
    /// Sign out of OIDC.
    /// - Note: Since Bentley's default OIDC servers don't properly handle sign out, this instead revokes all the current tokens
    ///         and deletes them from the iOS keychain.
    /// - Throws: If there are any problems with token revocation, an exception is thrown.
    open func signOut() async throws {
        defer {
            authState = nil
            serviceConfig = nil
            deleteFromKeychain()
            raiseOnAccessTokenChanged(nil, nil)
        }
        try await revokeTokens()
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

    /// Get the access token and expiration date. This is an async wrapper around the `AuthorizationClient` protocol's
    /// completion-based `getAccessToken()` function.
    /// - Returns: Tuple containing the access token (with token type prefix) and expiration date
    /// - Throws: If token refresh is necessary and fails, this throws an exception.
    open func getAccessToken() async throws -> (String, Date) {
        return try await refreshAccessToken()
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

    /// Instance for `onAccessTokenChanged` property from the `AuthorizationClient` protocol.
    public var onAccessTokenChanged: AccessTokenChangedCallback?

    open func getAccessToken(_ completion: @escaping GetAccessTokenCallback) {
        guard itmApplication.itmMessenger.frontendLaunchDone else {
            completion(nil, nil, nil)
            return
        }
        Task {
            do {
                let (accessToken, expirationDate) = try await getAccessToken()
                completion(accessToken, expirationDate, nil)
            } catch {
                completion(nil, nil, error)
            }
        }
    }
}
