/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import ObjectiveC

/// Protocol for ``ITMMessenger`` and ``ITMBackendMessenger`` query handlers.
public protocol ITMQueryHandler: NSObjectProtocol, Sendable {
    /// Called when a query arrives from TypeScript.
    ///
    /// You must eventually call `respondToQuery` on the messenger this handler is registered with (passing the given queryId)
    /// if you respond to a given query. Return true after doing that.
    /// - Note: If there is an error, call `respondToQuery` with a nil `responseJson` and
    /// an appropriate value for `error`.
    /// - Parameters:
    ///   - queryId: The query ID that must be sent back to TypeScript in the reponse.
    ///   - type: The query type.
    ///   - body: Optional message data sent from TypeScript.
    /// - Returns: true if you handle the given query, or false otherwise. If you return true, the query will not be passed to any other query handlers.
    @MainActor
    func handleQuery(_ queryId: Int64, _ type: String, _ body: Sendable?) async -> Bool
    /// Gets the type of queries that this ``ITMQueryHandler`` handles.
    func getQueryType() -> String?
}

/// Default implementation for ``ITMQueryHandler`` protocol.
public extension ITMQueryHandler {
    /// - Returns: This default implementation always returns `nil`.
    func getQueryType() -> String? {
        return nil
    }
}
