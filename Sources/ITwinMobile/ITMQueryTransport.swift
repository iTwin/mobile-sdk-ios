/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import Foundation

/// The response to a query sent through an ``ITMQueryTransport``.
internal enum ITMQueryResponse {
    case success(Sendable?)
    case failure(Error)
    case unhandled
}

/// Receives queries arriving through an ``ITMQueryTransport``.
internal protocol ITMQueryTransportDelegate: AnyObject {
    /// Handles an incoming query.
    /// - Returns: The JSON message string to send back to the sender of the query.
    @MainActor
    func processQuery(_ type: String, _ queryId: Int64, _ body: Sendable?) async -> String
    func logError(_ message: String)
}

/// Transport used by ``ITMMessengerImpl`` to send and receive queries.
internal protocol ITMQueryTransport: AnyObject {
    var delegate: ITMQueryTransportDelegate? { get set }
    func sendQuery(_ type: String, _ queryId: Int64, _ dataString: String) async -> ITMQueryResponse
}
