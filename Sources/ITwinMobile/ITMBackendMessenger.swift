/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import IModelJsNative

// MARK: - ITMBackendMessenger class

/// Class for sending queries to, and handling queries from, the backend JavaScript code.
///
/// - Note: Logging settings are shared with ``ITMMessenger`` (see ``ITMMessenger/isLoggingEnabled``).
open class ITMBackendMessenger: NSObject, ITMMessengerImplDelegate, @unchecked Sendable {
    private let implementation: ITMMessengerImpl

    /// Indicates whether or not the backend has finished launching. Specfically, if ``backendLaunchSucceeded()`` has been called.
    public var backendLaunchDone: Bool {
        get { implementation.launchDone }
        set { implementation.launchDone = newValue }
    }

    /// Create an ``ITMBackendMessenger`` attached to the shared `IModelJsHost`.
    /// - Important: Only one ``ITMBackendMessenger`` can receive backend queries at a time; the most recently created one takes priority.
    public override init() {
        let transport = ITMBackendQueryTransport(host: IModelJsHost.sharedInstance())
        implementation = ITMMessengerImpl(transport: transport, targetName: "JS backend", incomingIdPrefix: "MBID")
        super.init()
        implementation.delegate = self
        initBackendLaunch()
    }

    /// Initializes things in preperation of launching the backend. This is done automatically from `init`.
    open func initBackendLaunch() {
        implementation.initLaunch()
    }

    /// Wait until this ``ITMBackendMessenger`` has fully finished initializing.
    public func waitUntilReady() async {
        await implementation.waitUntilReady()
    }

    /// Call after the backend has successfully launched.
    /// - Important: Until you call this, all queries sent to the backend are kept on hold.
    open func backendLaunchSucceeded() {
        implementation.launchSucceeded()
    }

    /// Call if the backend fails to launch. This prevents any queries from being sent to the backend.
    open func backendLaunchFailed(_ error: Error) {
        implementation.launchFailed(error)
    }

    /// Async property that resolves when the backend launch has succeeded (``backendLaunchSucceeded()`` has been called).
    /// - Throws: The value passed to the `error` parameter of ``backendLaunchFailed(_:)``.
    public var backendLaunched: () {
        get async throws {
            try await implementation.launched
        }
    }

    /// Send query and receive void response. Errors are shown automatically using ``ITMMessenger/errorHandler``, but not thrown.
    /// - Parameters:
    ///   - vc: View controller passed to ``ITMMessenger/errorHandler``.
    ///   - type: Query type.
    ///   - data: Optional request data to send.
    public func queryAndShowError(_ vc: UIViewController?, _ type: String, _ data: Any? = nil) async {
        do {
            let _: Void = try await implementation.queryAndShowError(vc, type, data)
        } catch {
            // Ignore error (it has been shown).
        }
    }

    /// Send query and receive a typed response. Errors are shown automatically using ``ITMMessenger/errorHandler``.
    /// - Throws: If the query produces an error, it is thrown after being shown via ``ITMMessenger/errorHandler``.
    /// - Parameters:
    ///   - vc: View controller passed to ``ITMMessenger/errorHandler``.
    ///   - type: Query type.
    ///   - data: Optional request data to send.
    /// - Returns: The value returned by the backend.
    @discardableResult
    public func queryAndShowError<T>(_ vc: UIViewController?, _ type: String, _ data: Any? = nil) async throws -> T {
        return try await implementation.queryAndShowError(vc, type, data)
    }

    /// Send query with no response. Errors are logged.
    /// - Parameters:
    ///   - type: Query type.
    ///   - data: Optional request data to send.
    public func send(_ type: String, _ data: Any? = nil) {
        implementation.send(type, data)
    }

    /// Send query without a return value and wait for it to complete.
    /// - Throws: Throws an error if there is a problem.
    /// - Parameters:
    ///   - type: Query type.
    ///   - data: Optional request data to send.
    public func query(_ type: String, _ data: Any? = nil) async throws {
        let _: Void = try await implementation.query(type, data)
    }

    /// Send query and receive a typed response.
    /// - Throws: Throws an error if there is a problem.
    /// - Parameters:
    ///   - type: Query type.
    ///   - data: Optional request data to send.
    /// - Returns: The value returned by the backend.
    public func query<T>(_ type: String, _ data: Any? = nil) async throws -> T {
        return try await implementation.query(type, data)
    }

    /// Register a specific query handler for the given query type. Returns created handler, use it with ``unregisterQueryHandler(_:)``
    /// - SeeAlso: ``unregisterQueryHandler(_:)``
    /// ``unregisterQueryHandlers(_:)``
    /// - Parameters:
    ///   - type: Query type.
    ///   - handler: Callback function for query.
    /// - Returns: The query handler created to handle the given query type.
    public func registerQueryHandler<T, U: Sendable>(_ type: String, _ handler: @MainActor @escaping (T) async throws -> U) -> ITMQueryHandler {
        return implementation.registerQueryHandler(type, handler)
    }

    /// Register query handler for any otherwise unhandled query type.
    ///
    /// If you want one query handler to handle queries from multiple query types, create your own class that implements the `ITMQueryHandler`
    /// protocol. Then, in its `handleQuery` function, check the type, and handle any queries that have a type that you recognize and return
    /// `true`. Return `false` from other queries.
    /// - Note: Handlers registered here will only be called on queries that don't match the type of any queries that are registered with an
    /// explicit type. In other words, if you call `registerQueryHandler("myHandler", ...)`, then "myHandler" queries will never
    /// get to queries registered here.
    /// - SeeAlso: ``unregisterQueryHandler(_:)``
    /// ``unregisterQueryHandlers(_:)``
    /// - Parameter handler: Query handler to register.
    public func registerQueryHandler(_ handler: ITMQueryHandler) {
        implementation.registerQueryHandler(handler)
    }

    /// Unregister a query handler registered with ``registerQueryHandler(_:_:)`` or ``registerQueryHandler(_:)``.
    /// - Parameter handler: Query handler to unregister.
    public func unregisterQueryHandler(_ handler: ITMQueryHandler) {
        implementation.unregisterQueryHandler(handler)
    }

    /// Unregister query handlers registered with ``registerQueryHandler(_:_:)`` or ``registerQueryHandler(_:)``.
    /// - Parameter handlers: Array of query handlers to unregister.
    public func unregisterQueryHandlers(_ handlers: [ITMQueryHandler]) {
        for handler in handlers {
            unregisterQueryHandler(handler)
        }
    }

    /// Send query response to the backend.
    /// - Parameters:
    ///   - queryId: The queryId for the query. This must be the queryId passed into `ITMQueryHandler.handleQuery`.
    ///   - type: The type of the query that is being responded to.
    ///   - responseJson: The JSON-encoded response string. If this is `nil`, it indicates an error. To indicate "no response" without
    ///   triggering an error, use an empty string.
    open func respondToQuery(_ queryId: Int64, _ type: String, _ responseJson: String?, _ error: Error? = nil) {
        implementation.completeQuery(queryId, type, responseJson, error)
    }

    /// Convert a value into a JSON string. This supports both void values and base types (String, Bool, numeric types).
    /// - Note: If conversion fails (due to the value not being a type that can be converted to JSON), this returns an empty string.
    /// - Parameter value: The value to convert to a JSON string.
    /// - Returns: The JSON string for the given value.
    open func jsonString(_ value: Any?, prettyPrint: Bool = false) -> String {
        return ITMMessenger.jsonString(value, prettyPrint: prettyPrint)
    }

    /// Log the given query using ``logInfo(_:)``.
    /// - Note: If  ``ITMMessenger/isLoggingEnabled`` is false or `type` has been passed to ``ITMMessenger/addUnloggedQueryType(_:)``,
    /// the query will not be logged.
    /// - Parameters:
    ///   - title: A title to show along with the logged message.
    ///   - queryId: The queryId of the query.
    ///   - type: The type of the query.
    ///   - prettyDataString: The pretty-printed JSON representation of the query data. This is ignored if
    ///   ``ITMMessenger/isFullLoggingEnabled`` is `false`.
    open func logQuery(_ title: String, _ queryId: String, _ type: String, prettyDataString: String?) {
        implementation.writeQueryLog(title, queryId, type, prettyDataString: prettyDataString)
    }
}

// MARK: - ITMBackendQueryTransport class

/// ``ITMQueryTransport`` that communicates with the backend JavaScript code via `IModelJsHost`.
fileprivate final class ITMBackendQueryTransport: ITMQueryTransport, @unchecked Sendable {
    weak var delegate: ITMQueryTransportDelegate?
    private let host: IModelJsHost
    private var incomingQueryId: Int64 = 0

    init(host: IModelJsHost) {
        self.host = host
        host.queryCallback = { [weak self] type, data, callback in
            guard let self else {
                callback("No native backend messenger", true)
                return
            }
            self.handleQuery(type, data, callback)
        }
    }

    func sendQuery(_ type: String, _ queryId: Int64, _ dataString: String) async -> ITMQueryResponse {
        return await withCheckedContinuation { continuation in
            host.queryBackend(type, message: dataString) { result, isError in
                continuation.resume(returning: Self.parseResponse(result, isError))
            }
        }
    }

    private func handleQuery(_ type: String, _ data: String, _ onComplete: @escaping QueryResultCallback) {
        var queryBody: Sendable?
        if !data.isEmpty {
            guard let parsedData = JSONSerialization.jsonObject(withString: data) else {
                delegate?.logError("ITMBackendMessenger: Invalid body for query '\(type)'")
                onComplete("Failed to parse query data", true)
                return
            }
            queryBody = parsedData
        }

        incomingQueryId += 1
        let queryId = incomingQueryId
        Task { @MainActor [weak self] in
            guard let delegate = self?.delegate else {
                onComplete("No native backend messenger", true)
                return
            }
            onComplete(await delegate.processQuery(type, queryId, queryBody), false)
        }
    }

    private static func parseResponse(_ responseString: String, _ isError: Bool) -> ITMQueryResponse {
        if isError {
            // Error occurred before reaching the JS messenger, error message is a plain string.
            return .failure(ITMError(json: ["Description": responseString]))
        }
        guard let response = JSONSerialization.jsonObject(withString: responseString) as? JSON else {
            return .failure(ITMError(json: ["Description": "Invalid backend response: \(responseString)"]))
        }
        if response["unhandled"] as? Bool == true {
            return .unhandled
        }
        if let error = response["error"] {
            return .failure(ITMError(json: error as? JSON ?? ["Description": "\(error)"]))
        }
        return .success(response["response"])
    }
}
