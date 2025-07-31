/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import Reachability

/// Singleton object for performing any internet reachability tests.
class ITMInternetReachability {
    private let reachability = try! Reachability()
    @MainActor public static let shared = ITMInternetReachability()

    private init() {
        try? reachability.startNotifier()
    }

    /// Internet reachability status.
    ///
    /// *Values*
    ///
    /// `notReachable`
    ///
    /// The internet is not reachable.
    ///
    /// `reachableViaWiFi`
    ///
    /// The internet is reachable via Wi-Fi.
    ///
    /// `reachableViaWWAN`
    ///
    /// The internet is reachable via mobile data.
    public enum NetworkStatus: Int {
        case notReachable, reachableViaWiFi, reachableViaWWAN
    }

    /// Get current internet reachability status
    /// - Returns: The current internet reachability status.
    func currentReachabilityStatus() -> NetworkStatus {
        switch reachability.connection {
            case .cellular: return .reachableViaWWAN
            case .wifi: return .reachableViaWiFi
            default: return .notReachable
        }
    }
}
