//---------------------------------------------------------------------------------------
//
//     $Source: FieldiOS/App/Reachability/InternetReachability.swift $
//
//  $Copyright: (c) 2021 Bentley Systems, Incorporated. All rights reserved. $
//
//---------------------------------------------------------------------------------------

import Reachability

/// Shared object for performing any internet reachability tests.
class ITMInternetReachability {
    private let reachability = try! Reachability()
    public static let shared = ITMInternetReachability()

    private init() {
        try? reachability.startNotifier()
    }

    public enum NetworkStatus: String {
        case notReachable, reachableViaWiFi, reachableViaWWAN
    }
    
    /// Get current internet reachability status
    func currentReachabilityStatus() -> NetworkStatus {
        switch reachability.connection {
            case .cellular: return .reachableViaWWAN
            case .wifi: return .reachableViaWiFi
            default: return .notReachable
        }
    }
}
