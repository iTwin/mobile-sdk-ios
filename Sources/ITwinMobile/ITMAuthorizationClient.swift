/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import IModelJsNative

/// Convenience implemenation of the `AuthorizationClient` protocol.
/// - Warning: If you create a subclass of this class, you __must__ implement ``getAccessToken(_:)``.
open class ITMAuthorizationClient: NSObject, AuthorizationClient {
    /// The domain to use in the ``error(domain:code:reason:)`` function, default `"com.bentley.itwin-mobile-sdk"`.
    public var errorDomain = "com.bentley.itwin-mobile-sdk"

    /// Creates and returns an NSError object with the specified settings.
    /// - Parameters:
    ///   - domain: The domain to use for the NSError, default to nil, which uses the value from ``errorDomain``.
    ///   - code: The code to use for the NSError, defaults 200.
    ///   - reason: The reason to use for the NSError's NSLocalizedFailureReasonErrorKey userInfo value
    /// - Returns: An NSError object with the specified values.
    public func error(domain: String? = nil, code: Int = 200, reason: String) -> NSError {
        return NSError(domain: domain ?? errorDomain, code: code, userInfo: [NSLocalizedFailureReasonErrorKey: reason])
    }
    
    /// Calls the onAccessTokenChanged callback, if that callback is set.
    open func raiseOnAccessTokenChanged() {
        if let onAccessTokenChanged = onAccessTokenChanged {
            self.getAccessToken() { token, expirationDate, error in
                if let token = token,
                   let expirationDate = expirationDate {
                    onAccessTokenChanged(token, expirationDate)
                } else {
                    onAccessTokenChanged(nil, nil)
                }
            }
        }
    }

    // MARK: - AuthorizationClient Protocol implementation

    /// Stub to satisfy AuthorizationClient protocol. You __must__ implement this in your subclass.
    open func getAccessToken(_ completion: @escaping GetAccessTokenCallback) {
        completion(nil, nil, nil)
    }

    /// The `onAccessTokenChanged` property from the `AuthorizationClient` protocol.
    public var onAccessTokenChanged: AccessTokenChangedCallback?
}
