//---------------------------------------------------------------------------------------
//
//     $Source: FieldiOS/App/Reachability/InternetReachability.swift $
//
//  $Copyright: (c) 2020 Bentley Systems, Incorporated. All rights reserved. $
//
//---------------------------------------------------------------------------------------

import ITMNative

/// Shared object for performing any internet reachability tests.
class ITMInternetReachability {
    private let reachability: Reachability
    public static let shared = ITMInternetReachability()

    private init() {
        reachability = Reachability.forInternetConnection()
        reachability.startNotifier()
    }

    /// Get current internet reachability status
    func currentReachabilityStatus() -> NetworkStatus {
        return reachability.currentReachabilityStatus()
    }

    func connectionRequired() -> Bool {
        return reachability.connectionRequired()
    }
}
