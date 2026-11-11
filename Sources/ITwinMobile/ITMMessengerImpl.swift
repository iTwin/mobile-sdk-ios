/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit

/// Delegate that allows customizing some aspects of query handling. The delegate is used to give back control to ``ITMMessenger``
/// and ``ITMBackendMessenger`` open methods that can be overridden by deriving messenger classes.
internal protocol ITMMessengerImplDelegate: AnyObject {
    func respondToQuery(_ queryId: Int64, _ type: String, _ responseJson: String?, _ error: Error?)
    func logQuery(_ title: String, _ queryId: String, _ type: String, prettyDataString: String?)
    func jsonString(_ value: Any?, prettyPrint: Bool) -> String
}

/// Messaging logic shared by ``ITMMessenger`` and ``ITMBackendMessenger``. Queries are sent and received using an ``ITMQueryTransport``.
internal final class ITMMessengerImpl: ITMQueryTransportDelegate, @unchecked Sendable {
    private final class TypedQueryHandler<T, U: Sendable>: NSObject, ITMQueryHandler, @unchecked Sendable {
        private weak var messenger: ITMMessengerImpl?
        private let type: String
        private let handler: (T) async throws -> U

        init(_ messenger: ITMMessengerImpl, _ type: String, _ handler: @escaping (T) async throws -> U) {
            self.messenger = messenger
            self.type = type
            self.handler = handler
        }

        func getQueryType() -> String? {
            return type
        }

        @MainActor
        func handleQuery(_ queryId: Int64, _ type: String, _ body: Sendable?) async -> Bool {
            guard let messenger else { return false }
            messenger.logQuery("Request  \(messenger.targetName) -> SWIFT", messenger.incomingTag(queryId), type, messageData: body)
            do {
                let response: U
                if T.self == Void.self {
                    response = try await handler(() as! T)
                } else if let typedBody = body as? T {
                    response = try await handler(typedBody)
                } else {
                    messenger.respondToQuery(queryId, type, nil, ITMError(json: ["message": "Invalid input"]))
                    return true
                }
                messenger.respondToQuery(queryId, type, messenger.jsonString(response))
            } catch {
                messenger.respondToQuery(queryId, type, nil, error)
            }
            return true
        }
    }

    private actor QueryId {
        private var queryId: Int64 = 0

        func next() -> Int64 {
            queryId += 1
            return queryId
        }
    }

    // Note: queryId is static so that sequential messengers that make use of the
    // same transport target will work properly (e.g. after messenger recreation).
    private static let queryId = QueryId()

    private let transport: ITMQueryTransport
    private let targetName: String
    private let incomingIdPrefix: String
    private let outgoingIdPrefix: String?

    private var queryHandlerDict: [String: ITMQueryHandler] = [:]
    private var queryHandlers: [ITMQueryHandler] = []
    private var pendingResponses: [Int64: CheckedContinuation<String, Never>] = [:]

    weak var delegate: ITMMessengerImplDelegate?
    var launchDone = false
    private var launchTask: Task<Void, Error>?
    private var launchContinuation: CheckedContinuation<Void, Error>?

    /// - Parameters:
    ///   - transport: The transport used to send and receive queries.
    ///   - targetName: The name of the other side of the transport, used in log messages.
    ///   - incomingIdPrefix: Prefix for the IDs of incoming queries in log messages.
    ///   - outgoingIdPrefix: Prefix for the IDs of outgoing queries in log messages.
    init(transport: ITMQueryTransport, targetName: String, incomingIdPrefix: String, outgoingIdPrefix: String? = nil) {
        self.transport = transport
        self.targetName = targetName
        self.incomingIdPrefix = incomingIdPrefix
        self.outgoingIdPrefix = outgoingIdPrefix
        transport.delegate = self
    }

    // MARK: - Launch management

    func initLaunch() {
        launchDone = false
        launchTask = Task {
            try await withCheckedThrowingContinuation { continuation in
                launchContinuation = continuation
            }
        }
    }

    func waitUntilReady() async {
        await ITMMessenger.waitUntilReady({ [self] in launchContinuation != nil })
    }

    func launchSucceeded() {
        launchDone = true
        launchContinuation?.resume(returning: ())
        launchContinuation = nil
    }

    func launchFailed(_ error: Error) {
        launchContinuation?.resume(throwing: error)
        launchContinuation = nil
    }

    var launched: Void {
        get async throws {
            try await launchTask?.value
        }
    }

    // MARK: - Outgoing queries

    func send(_ type: String, _ data: Any?) {
        Task {
            do {
                let _: Void = try await query(type, data)
            } catch {
                guard let itmError = error as? ITMError, !itmError.isNotImplemented else {
                    return
                }
                logError("Error with one-way query \"\(type)\": \(error)")
            }
        }
    }

    func query<T>(_ type: String, _ data: Any?) async throws -> T {
        try await launched
        let queryId = await Self.queryId.next()
        let tag = "\(outgoingIdPrefix ?? incomingIdPrefix)\(queryId)"
        let dataString = jsonString(data)
        logQuery("Request  SWIFT -> \(targetName)", tag, type, dataString: dataString)
        switch await transport.sendQuery(type, queryId, dataString) {
        case .success(let response):
            logQuery("Response \(targetName) -> SWIFT", tag, type, messageData: response)
            return try convertResult(type, jsonString(response))
        case .failure(let error):
            logQuery("Error Response \(targetName) -> SWIFT", tag, type, dataString: (error as? ITMError)?.jsonString)
            if let itmError = error as? ITMError, itmError.isNotImplemented {
                logError("\(targetName) \(itmError.errorDescription ?? "No handler for <Unknown> query.")")
            }
            throw error
        case .unhandled:
            logQuery("Unhandled Response \(targetName) -> SWIFT", tag, type, dataString: nil)
            let description = "No handler for '\(type)' query."
            logError("\(targetName) \(description)")
            throw ITMError(json: ["MessageNotImplemented": true, "Description": description])
        }
    }

    func queryAndShowError<T>(_ vc: UIViewController?, _ type: String, _ data: Any?) async throws -> T {
        do {
            return try await query(type, data)
        } catch {
            await ITMMessenger.errorHandler(vc, error)
            throw error
        }
    }

    // MARK: - Incoming queries

    func registerQueryHandler<T, U: Sendable>(_ type: String, _ handler: @escaping (T) async throws -> U) -> ITMQueryHandler {
        let queryHandler = TypedQueryHandler<T, U>(self, type, handler)
        queryHandlerDict[type] = queryHandler
        return queryHandler
    }

    func registerQueryHandler(_ handler: ITMQueryHandler) {
        queryHandlers.append(handler)
    }

    func unregisterQueryHandler(_ handler: ITMQueryHandler) {
        if let queryType = handler.getQueryType() {
            queryHandlerDict.removeValue(forKey: queryType)
        }
        queryHandlers.removeAll { $0.isEqual(handler) }
    }

    @MainActor
    func processQuery(_ type: String, _ queryId: Int64, _ body: Sendable?) async -> String {
        return await withCheckedContinuation { continuation in
            if pendingResponses[queryId] != nil {
                logError("ITMMessenger: duplicate pending query \(incomingTag(queryId)) '\(type)'")
            }
            pendingResponses[queryId] = continuation
            Task { @MainActor in
                await dispatchQueryToHandlers(type, queryId, body)
            }
        }
    }
    
    @MainActor
    private func dispatchQueryToHandlers(_ type: String, _ queryId: Int64, _ body: Sendable?) async {
        if let queryHandler = queryHandlerDict[type] {
            if await queryHandler.handleQuery(queryId, type, body) {
                return
            }
        }
        for queryHandler in queryHandlers {
            // These query handlers don't indicate what queries they handle.
            // So iterate through all of them until one indicates that it has
            // handled the query.
            if await queryHandler.handleQuery(queryId, type, body) {
                return
            }
        }
        logError("ITMMessenger no SWIFT handler for \(incomingTag(queryId)) '\(type)'")
        respondToQuery(queryId, type, nil)
    }

    func respondToQuery(_ queryId: Int64, _ type: String, _ responseJson: String?, _ error: Error? = nil) {
        if let delegate {
            delegate.respondToQuery(queryId, type, responseJson, error)
        } else {
            completeQuery(queryId, type, responseJson, error)
        }
    }

    func completeQuery(_ queryId: Int64, _ type: String, _ responseJson: String?, _ error: Error?) {
        logQuery("Response SWIFT -> \(targetName)", incomingTag(queryId), type, dataString: responseJson)
        let messageJson: String
        if let responseJson {
            if responseJson.isEmpty {
                messageJson = "{}"
            } else {
                messageJson = "{\"response\":\(responseJson)}"
            }
        } else {
            if let itmError = error as? ITMError {
                if itmError.jsonString.isEmpty {
                    messageJson = "{\"error\":{}}"
                } else {
                    messageJson = "{\"error\":\(itmError.jsonString)}"
                }
            } else if let stringError = error as? ITMStringError, let errorDescription = stringError.errorDescription {
                let errorString = jsonString("\(errorDescription)")
                messageJson = "{\"error\":\(errorString)}"
            } else if let error {
                let errorString = jsonString("\(error)")
                messageJson = "{\"error\":\(errorString)}"
            } else {
                // If we get here, the other side sent a query that we don't handle. That should never
                // happen, so assert. Note that if a void response is desired, then responseJson
                // will be an empty string, not nil.
                logError("Unhandled query [\(targetName) -> Swift]: \(incomingTag(queryId))\n")
                assert(false)
                messageJson = "{\"unhandled\":true}"
            }
        }
        Task { @MainActor in
            guard let continuation = pendingResponses.removeValue(forKey: queryId) else {
                logError("ITMMessenger: response to unknown query \(incomingTag(queryId)) '\(type)'")
                return
            }
            continuation.resume(returning: messageJson)
        }
    }

    // MARK: - Serialization

    func jsonString(_ value: Any?, prettyPrint: Bool = false) -> String {
        if let delegate {
            return delegate.jsonString(value, prettyPrint: prettyPrint)
        }
        return ITMMessenger.jsonString(value, prettyPrint: prettyPrint)
    }
    
    private func convertResult<T>(_ messageType: String, _ dataString: String) throws -> T {
        var data = JSONSerialization.jsonObject(withString: dataString)
        if T.self == Void.self {
            let voidAsT = () as! T // This has to be a separate variable to avoid a warning in the next line
            return voidAsT
        }

        // JSONSerialization converts string "null" to NSNull object, that fails test "data is T" when T is Optional<>.
        if data is NSNull {
            data = nil
        }

        if data is T {
            return data as! T
        }

        // Type does not match expectation - handle error gracefully.
        let dataType = data == nil ? "<null>" : String(describing: type(of: data!))
        let expectedType = String(describing: T.self)
        let reason =
            "Could not cast response data from '\(dataType)' to expected type '\(expectedType)'. " +
            "Check your type cast for message response of type '\(messageType)' and if data arrived as expected."

        ITMApplication.log(.error, reason)
        #if DEBUG
            assert(false, reason)
        #endif

        throw ITMError(json: ["REASON": reason, "Internal": true])
    }

    // MARK: - Logging

    func logError(_ message: String) {
        ITMApplication.log(.error, message)
    }

    func logInfo(_ message: String) {
        ITMApplication.log(.info, message)
    }

    func writeQueryLog(_ title: String, _ queryTag: String, _ type: String, prettyDataString: String?) {
        let options = ITMMessengerLoggingOptions.shared
        guard options.isLoggingEnabled, !options.unloggedQueryTypes.contains(type) else { return }
        var message = "ITMMessenger [\(title)] \(queryTag): \(type)"
        if options.isFullLoggingEnabled, let prettyDataString, !prettyDataString.isEmpty {
            message.append("\n\(prettyDataString)")
        }
        logInfo(message)
    }

    private func logQuery(_ title: String, _ queryTag: String, _ type: String, prettyDataString: String?) {
        if let delegate {
            delegate.logQuery(title, queryTag, type, prettyDataString: prettyDataString)
        } else {
            writeQueryLog(title, queryTag, type, prettyDataString: prettyDataString)
        }
    }

    private func logQuery(_ title: String, _ queryTag: String, _ type: String, messageData: Any?) {
        logQuery(title, queryTag, type, prettyDataString: messageData != nil && ITMMessengerLoggingOptions.shared.isFullLoggingEnabled ? JSONSerialization.string(withITMJSONObject: messageData, prettyPrint: true) : nil)
    }

    private func logQuery(_ title: String, _ queryTag: String, _ type: String, dataString: String?) {
        // The original string is not pretty-printed, so convert it into an object to be pretty-printed.
        logQuery(title, queryTag, type, messageData: dataString != nil && ITMMessengerLoggingOptions.shared.isFullLoggingEnabled ? JSONSerialization.jsonObject(withString: dataString!) : nil)
    }

    private func incomingTag(_ queryId: Int64) -> String {
        return "\(incomingIdPrefix)\(queryId)"
    }
}
