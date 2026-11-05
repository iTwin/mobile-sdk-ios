/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

/// Message logging settings shared by ``ITMMessenger`` and ``ITMBackendMessenger``.
public class ITMMessengerLoggingOptions {
    public static let shared = ITMMessengerLoggingOptions()

    /// Whether or not to log messages.
    public var isLoggingEnabled = false

    /// Whether or not full logging of all messages (with their optional bodies) is enabled.
    /// - Important: You should only enable this in debug builds, since message bodies may contain private information.
    public var isFullLoggingEnabled = false

    /// Query types for which queries are not logged.
    ///
    /// - SeeAlso: ``addUnloggedQueryType(_:)``
    public private(set) var unloggedQueryTypes = Set<String>()

    /// Add a query type to the list of unlogged queries.
    ///
    /// Unlogged queries are ignored when logging sent or received queries. This is useful (for example)
    /// for queries that are themselves intended to produce log output, to prevent double log output.
    ///
    /// - SeeAlso: ``removeUnloggedQueryType(_:)``
    /// - Parameter type: The type of the query for which logging is disabled.
    public func addUnloggedQueryType(_ type: String) {
        unloggedQueryTypes.insert(type)
    }

    /// Remove a query type from the list of unlogged queries.
    ///
    /// - SeeAlso: ``addUnloggedQueryType(_:)``
    /// - Parameter type: The type of the query to remove.
    public func removeUnloggedQueryType(_ type: String) {
        unloggedQueryTypes.remove(type)
    }
}
