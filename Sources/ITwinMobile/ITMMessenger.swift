/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import WebKit

// MARK: - Convenience extensions

extension String {
    /// Convert a String into BASE64-encoded UTF-8 data.
    func toBase64() -> String {
        return Data(utf8).base64EncodedString()
    }
}

internal extension JSONSerialization {
    static func string(withITMJSONObject object: Any?) -> String? {
        return string(withITMJSONObject: object, prettyPrint: false)
    }

    static func string(withITMJSONObject object: Any?, prettyPrint: Bool) -> String? {
        guard let object = object else {
            return ""
        }
        if let _ = object as? Void {
            // Return empty JSON string for void.
            return ""
        }
        let wrapped: Bool
        let validJSONObject: Any
        if JSONSerialization.isValidJSONObject(object) {
            wrapped = false
            validJSONObject = object
        } else {
            wrapped = true
            // Wrap object in an array
            validJSONObject = [object]
        }
        let options: JSONSerialization.WritingOptions = prettyPrint ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: validJSONObject, options: options) else {
            return nil
        }
        guard let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }
        if wrapped {
            // Remove the array delimiters ("[" and "]") from the beginning and end of the string.
            return String(String(jsonString.dropFirst()).dropLast())
        } else {
            return jsonString
        }
    }

    static func jsonObject(withString string: String) -> Any? {
        if string == "" {
            return ()
        }
        guard let data = string.data(using: .utf8) else {
            return nil
        }
        guard let result = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) else {
            return nil
        }
        return result
    }
}

extension Task where Success == Never, Failure == Never {
    // Convenience so you don't have to figure out how many zeros to add to your sleep.
    static func sleep(milliseconds: UInt64) async throws {
        try await sleep(nanoseconds: milliseconds * 1000000)
    }
}

// MARK: - ITMQueryHandler protocol

/// Protocol for ITMMessenger query handlers.
public protocol ITMQueryHandler: NSObjectProtocol {
    /// Called when a query arrives from TypeScript.
    /// You must eventually call `ITMMessenger.respondToQuery` (passing the given queryId) if you respond to a given query. Return true after doing that.
    /// - Note: If there is an error, call `ITMMessenger.respondToQuery` with a nil `responseJson` and an appropriate value for `error`.
    /// - Parameters:
    ///   - queryId: The query ID that must be sent back to TypeScript in the reponse.
    ///   - type: The query type.
    ///   - body: Optional message data sent from TypeScript.
    /// - Returns: true if you handle the given query, or false otherwise. If you return true, the query will not be passed to any other query handlers.
    func handleQuery(_ queryId: Int64, _ type: String, _ body: Any?) async -> Bool
    /// Gets the type of queries that this ``ITMQueryHandler`` handles.
    func getQueryType() -> String?
}

// MARK: - ITMQueryHandler extension with default implementation

public extension ITMQueryHandler {
    /// This default implementation always returns `nil`.
    func getQueryType() -> String? {
        return nil
    }
}

// MARK: - ITMWeakScriptMessageHandler class

/// Because the WKWebView has a strong reference to any WKScriptMessageHandler
/// objects attached to its userContentController, and ITMMessenger has a
/// strong reference to the WKWebView, a retain cycle is created if we connect
/// the two directly. This class acts as a go-between, and since it has a weak
/// reference to its delegate, the retain cycle is broken.
public class ITMWeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    public init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - ITMError class

/// Error with a JSON-encoded string with information about what went wrong.
open class ITMError: Error {
    public let jsonString: String
    
    /// Create an ITMError with an empty jsonString.
    public init() {
        self.jsonString = ""
    }
    
    /// Create an ITMError with the given JSON string.
    /// - Parameter jsonString: The jsonString for this ITMError.
    public init(jsonString: String) {
        self.jsonString = jsonString
    }
    
    /// Create an ITMError with a JSON string created from the given dictionary.
    /// - Parameter json: A dictionary that will be converted to a JSON string for this ITMError.
    public init(json: [String: Any]) {
        self.jsonString = JSONSerialization.string(withITMJSONObject: json) ?? ""
    }
}

// MARK: - ITMMessenger class

/// Class for interacting with the Messenger TypeScript class to allow messages to go back and forth between Swift and TypeScript.
open class ITMMessenger: NSObject, WKScriptMessageHandler {
    private class ITMWKQueryHandler<T, U>: NSObject, ITMQueryHandler {
        private var itmMessenger: ITMMessenger
        private var type: String
        private var handler: (T) async throws -> U

        init(_ itmMessenger: ITMMessenger, _ type: String, _ handler: @escaping (T) async throws -> U) {
            self.itmMessenger = itmMessenger
            self.type = type
            self.handler = handler
        }

        func getQueryType() -> String? {
            return type
        }

        @MainActor
        func handleQuery(_ queryId: Int64, _ type: String, _ body: Any?) async -> Bool {
            itmMessenger.logQuery("Request  JS -> SWIFT", "WKID\(queryId)", type, messageData: body)
            do {
                let response: U
                // swiftformat:disable void
                if T.self == Void.self {
                    response = try await handler(() as! T)
                } else if let typedBody = body as? T {
                    response = try await handler(typedBody)
                } else {
                    itmMessenger.respondToQuery(queryId, nil, ITMError(json: ["message": "Invalid input"]))
                    return true
                }
                let responseString = self.itmMessenger.jsonString(response)
                self.itmMessenger.respondToQuery(queryId, responseString)
            } catch {
                itmMessenger.respondToQuery(queryId, nil, error)
            }
            return true
        }
    }

    /// Wrapper for a dictionary that uses an actor to ensure that all modifications happen in the same thread.
    private actor ResponseHandlers {
        private var responseHandlers: [Int64: ITMResponseHandler] = [:]
        
        // NOTE: subscript set is not supported for actors in Swift. :-/
        subscript(key: Int64) -> ITMResponseHandler? { responseHandlers[key] }

        func set(_ key: Int64, _ value: @escaping ITMResponseHandler) { responseHandlers[key] = value }
        func removeValue(forKey key: Int64) { responseHandlers.removeValue(forKey: key) }
    }

    private struct WeakWKWebView: Equatable {
        weak var webView: WKWebView?
        static func == (lhs: WeakWKWebView, rhs: WeakWKWebView) -> Bool {
            lhs.webView == rhs.webView
        }
    }

    /// Convenience typealias for a function that takes a `String Result` and returns void.
    public typealias ITMResponseHandler = (Result<String, Error>) -> Void
    /// Convenience typealias for an async function that takes an optional UIViewController and an Error.
    public typealias ITMErrorHandler = (_ vc: UIViewController?, _ baseError: Error) async -> Void

    /// The webView associated with this ITMMessenger.
    open var webView: WKWebView
    /// The error handler for this ITMMessenger. Replace this value with a custom ITMErrorHandler to present the error to your user.
    /// The default handler simply logs the error using ITMApplication.logger.
    public static var errorHandler: ITMErrorHandler = { (_ vc: UIViewController?, _ baseError: Error) async -> Void in
        ITMApplication.logger.log(.error, baseError.localizedDescription)
    }

    // Note: queryId is static so that sequential WKMessageSenders that make use of the
    // same WKWebView will work properly. You cannot have two WKMessageSenders refer to
    // the same WKWebView at the same time, but you can create one, destroy it, then
    // create another.
    private static var queryId: Int64 = 0
    private static var weakWebViews: [WeakWKWebView] = []
    /// Whether or not to log messages.
    public static var isLoggingEnabled = false;
    /// Whether or not full logging of all messages (with their optional bodies) is enabled.
    /// - warning: You should only enable this in debug builds, since message bodies may contain private information.
    public static var isFullLoggingEnabled = false
    /// Indicates whether or not the frontend has finished launching. Specfically, if ``frontendLaunchSucceeded()`` has been called.
    public var frontendLaunchDone = false
    private let queryName = "Bentley_ITMMessenger_Query"
    private let queryResponseName = "Bentley_ITMMessenger_QueryResponse"
    private let handlerNames: [String]
    private var queryHandlerDict: [String: ITMQueryHandler] = [:]
    private var queryHandlers: [ITMQueryHandler] = []
    private var responseHandlers = ResponseHandlers()
    private var jsQueue: [String] = []
    private var jsBusy = false
    private var frontendLaunchTask: Task<Void, Error>?
    private var frontendLaunchContinuation: CheckedContinuation<Void, Error>?

    /// - Parameter webView: The WKWebView to which to attach this ITMMessageSender.
    public init(_ webView: WKWebView) {
        let weakWebView = WeakWKWebView(webView: webView)
        if ITMMessenger.weakWebViews.contains(weakWebView) {
            // Only ONE Messenger can be created at a time for each WKWebView.
            assert(false)
        }
        // Stop tracking all the web views that no longer exist.
        ITMMessenger.weakWebViews.removeAll { $0.webView == nil }
        ITMMessenger.weakWebViews.append(weakWebView)
        self.webView = webView
        handlerNames = [queryName, queryResponseName]
        super.init()
        frontendLaunchTask = Task {
            try await withCheckedThrowingContinuation { continuation in
                frontendLaunchContinuation = continuation
            }
        }
        for handlerName in handlerNames {
            webView.configuration.userContentController.add(ITMWeakScriptMessageHandler(self), name: handlerName)
        }
    }

    deinit {
        let weakWebView = WeakWKWebView(webView: webView)
        ITMMessenger.weakWebViews.removeAll { $0 == weakWebView }
        for handlerName in handlerNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        }
    }

    /// Wait until this ``ITMMessenger`` has fully finished initializing.
    public func waitUntilReady() async {
        // It's highly unlikely we could get here with frontendLaunchContinuation nil,
        // but if we do, we need to wait for it to be initialized before continuing, or
        // nothing will work.
        await ITMMessenger.waitUntilReady({ self.frontendLaunchContinuation != nil })
    }
    
    /// Wait until the given `isReady` predicate returns true.
    /// - Note: If isReady returns true immediately, no waiting occurs.
    /// - Parameter isReady: Predicate to wait on. This function will not return until `isReady` returns true.
    public static func waitUntilReady(_ isReady: @escaping () -> Bool) async {
        if isReady() { return }
        let task = Task {
            while !isReady() {
                // Wait 10ms before trying again.
                // Note: because our task cannot be canceled, sleep can never throw.
                try? await Task.sleep(milliseconds: 10)
            }
        }
        return await task.value
    }

    /// Send query and receive void response. Errors are shown automatically using ``errorHandler``, but not thrown.
    /// - Parameters:
    ///   - vc: if specified, is checked for visiblity and only then error is shown. View controller that displays error dialog if still visible. Errors shown globally if nil.
    ///   - type: query type.
    ///   - data: optional request data to send.
    public func queryAndShowError(_ vc: UIViewController?, _ type: String, _ data: Any? = nil) async -> Void {
        do {
            return try await internalQueryAndShowError(vc, type, data)
        } catch {
            // Ignore error (it has been shown, and we aren't being asked to produce a return value that we don't have.)
        }
    }

    /// Send message and receive an async parsed typed response. Errors are shown automatically using ``errorHandler``.
    /// - Throws: If the query produces an error, it is thrown after being shown to the user via ``errorHandler``.
    /// - Parameters:
    ///   - vc: if specified, is checked for visiblity and only then error is shown. View controller that displays error dialog if still visible. Errors shown globally if nil.
    ///   - type: query type.
    ///   - data: optional request data to send.
    /// - Returns: The value returned by the TypeScript code.
    @discardableResult
    public func queryAndShowError<T>(_ vc: UIViewController?, _ type: String, _ data: Any? = nil) async throws -> T {
        return try await internalQueryAndShowError(vc, type, data)
    }

    /// Send message with no response.
    /// - Throws: Throws an error if there is a problem.
    /// - Parameters:
    ///   - type: query type.
    ///   - data: optional request data to send.
    public func query(_ type: String, _ data: Any? = nil) async throws -> Void {
        return try await internalQuery(type, data)
    }

    /// Send message and receive an async parsed typed response.
    /// - Throws: Throws an error if there is a problem.
    /// - Parameters:
    ///   - type: query type.
    ///   - data: optional request data to send.
    /// - Returns: The value returned by the TypeScript code.
    @discardableResult
    public func query<T>(_ type: String, _ data: Any? = nil) async throws -> T {
        return try await internalQuery(type, data)
    }

    /// Register specific query handler for the given query type. Returns created handler, use it with ``unregisterQueryHandler(_:)``
    /// - Parameters:
    ///   - type: query type.
    ///   - handler: callback function for query.
    /// - Returns: The query handler created to handle the given query type.
    public func registerQueryHandler<T, U>(_ type: String, _ handler: @MainActor @escaping (T) async throws -> U) -> ITMQueryHandler {
        return internalRegisterQueryHandler(type, handler)
    }

    /// Register query handler for any otherwise unhandled query type.
    /// If you want one query handler to handle queries from multiple query types, create your own class that implements the ITMQueryHandler protocol. Then,
    /// in its handleQuery function, check the type, and handle any queries that have a type that you recognize and return true. Return false from other queries.
    /// - Note: Handlers registered here will only be called on queries that don't match the type of any queries that are registered with an explicit type.
    ///         In other words, if you call `registerQueryHandler("myHandler") ...`, then "myHandler" queries will never get to queries
    ///         registered here.
    /// - Parameter handler: query handler to register.
    public func registerQueryHandler(_ handler: ITMQueryHandler) {
        queryHandlers.append(handler)
    }

    /// Unregister a query handler registered with ``registerQueryHandler(_:_:)`` or ``registerQueryHandler(_:)``.
    /// - Parameter handler: query handler to unregister.
    public func unregisterQueryHandler(_ handler: ITMQueryHandler) {
        if let queryType = handler.getQueryType() {
            queryHandlerDict.removeValue(forKey: queryType)
        } else {
            queryHandlers.removeAll { $0.isEqual(handler) }
        }
    }

    /// Evaluate a JavaScript string in this ITMMessenger's WKWebView. Note that this uses a queue, and only one JavaScript string is evaluated at a time.
    /// WKWebView doesn't work right when multiple evaluateJavaScript calls are active at the same time. This function returns immediately, while the
    /// JavaScript is scheduled for later evaluation.
    /// - Parameter js: The JavaScript string to evaluate.
    open func evaluateJavaScript(_ js: String) {
        Task { @MainActor in
            // Calling evaluateJavascript multiple times in a row before the prior
            // evaluation completes results in loss of all but one. Either the first
            // or last is called, and the rest disappear.
            if self.jsBusy {
                self.jsQueue.append(js)
                return
            }
            self.jsBusy = true
            self.webView.evaluateJavaScript(js, completionHandler: { _, _ in
                self.jsBusy = false
                if self.jsQueue.isEmpty {
                    return
                }
                let js = self.jsQueue[0]
                self.jsQueue.remove(at: 0)
                self.evaluateJavaScript(js)
            })
        }
    }

    /// Implementation of the WKScriptMessageHandler function. If you override this function, it is STRONGLY recommended that you call this version via super
    /// as part of your implementation.
    /// - Note: Since query handling is async, this function will return before that finishes if the message is a query.
    open func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
            let data = body.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            logError("Invalid or missing body")
            return
        }
        switch message.name {
        case queryName:
            if let name = jsonObject["name"] as? String, let queryId = jsonObject["queryId"] as? Int64 {
                Task {
                    await processQuery(name, withBody: jsonObject["message"], queryId: queryId)
                }
            }
            break
        case queryResponseName:
            let error = jsonObject["error"]
            if let queryId = jsonObject["queryId"] as? Int64 {
                processQueryResponse(jsonObject["response"], queryId: queryId, error: error)
            }
            break
        default:
            logError("ITMMessenger: Unexpected message type: \(message.name)\n")
            break
        }
    }

    /// Send query response to WKWebView.
    /// - Parameters:
    ///   - queryId: The queryId for the query. This must be the queryId passed into `ITMQueryHandler.handleQuery`.
    ///   - responseJson: The JSON-encoded response string. If this is nil, it indicates an error. To indicate "no response" without triggering an
    ///                   error, use an empty string.
    open func respondToQuery(_ queryId: Int64, _ responseJson: String?, _ error: Error? = nil) {
        logQuery("Response SWIFT -> JS", "WKID\(queryId)", nil, dataString: responseJson)
        let messageJson: String
        if let responseJson = responseJson {
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
            } else if let error = error {
                let errorString = self.jsonString("\(error)")
                messageJson = "{\"error\":\(errorString)}"
            } else {
                // If we get here, the JS code sent a query that we don't handle. That should never
                // happen, so assert. Note that if a void response is desired, then responseJson
                // will be an empty string, not nil.
                logError("Unhandled query [JS -> Swift]: WKID\(queryId)\n")
                assert(false)
                messageJson = "{\"unhandled\":true}"
            }
        }
        let js = "window.Bentley_ITMMessenger_QueryResponse\(queryId)('\(messageJson.toBase64())')"
        evaluateJavaScript(js)
    }

    /// Convert a value into a JSON string. This supports both void values and base types (String, Bool, numeric types).
    /// - Parameter value: The value to convert to a JSON string.
    /// - Returns: The JSON string for the given value.
    open func jsonString(_ value: Any?) -> String {
        return JSONSerialization.string(withITMJSONObject: value) ?? ""
    }

    /// Log the given query using ``logInfo(_:)``.
    /// - Parameters:
    ///   - title: A title to show along with the logged message.
    ///   - queryId: The queryId of the query.
    ///   - type: The type of the query.
    ///   - prettyDataString: The pretty-printed JSON representation of the query data.
    open func logQuery(_ title: String, _ queryId: String, _ type: String?, prettyDataString: String?) {
        guard ITMMessenger.isLoggingEnabled else {return}
        let typeString = type != nil ? "'\(type!)'" : "(Match ID from Request above)"
        var message = "ITMMessenger [\(title)] \(queryId): \(typeString)"
        if ITMMessenger.isFullLoggingEnabled, let prettyDataString = prettyDataString {
            message.append("\n\(prettyDataString)")
        }
        logInfo(message)
    }

    /// Log an error message using `ITMApplication.logger`.
    /// - Parameter message: The error message to log.
    public func logError(_ message: String) {
        ITMApplication.logger.log(.error, message)
    }

    /// Log an info message using `ITMApplication.logger`.
    /// - Parameter message: The info message to log.
    public func logInfo(_ message: String) {
        ITMApplication.logger.log(.info, message)
    }

    /// Called after the frontend has successfully launched, indicating that any queries that are sent to TypeScript will be received.
    open func frontendLaunchSucceeded() {
        frontendLaunchDone = true
        frontendLaunchContinuation?.resume(returning: ())
        frontendLaunchContinuation = nil
    }

    /// Called if the frontend fails to launch. This prevents any queries from being sent to TypeScript.
    open func frontendLaunchFailed(_ error: Error) {
        frontendLaunchContinuation?.resume(throwing: error)
        frontendLaunchContinuation = nil
    }

    private func internalRegisterQueryHandler<T, U>(_ type: String, _ handler: @escaping (T) async throws -> U) -> ITMQueryHandler {
        let queryHandler = ITMWKQueryHandler<T, U>(self, type, handler)
        queryHandlerDict[type] = queryHandler
        return queryHandler
    }

    /// Async property that resolves when the frontend launch has succeeded (``frontendLaunchSucceeded()`` has been called).
    /// - Throws: The value passed to the `error` parameter of ``frontendLaunchFailed(_:)``.
    public var frontendLaunched: () {
        get async throws {
            try await frontendLaunchTask?.value
        }
    }

    private func internalQuery(_ type: String, dataString: String) async throws -> String {
        let queryId = ITMMessenger.queryId
        self.logQuery("Request  SWIFT -> JS", "SWID\(queryId)", type, dataString: dataString)
        ITMMessenger.queryId += 1
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.responseHandlers.set(queryId, { result in
                    switch result {
                    case .success(let resultString):
                        continuation.resume(returning: resultString)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                })
                let js = "window.Bentley_ITMMessenger_Query('\(type)', \(queryId), '\(dataString.toBase64())')"
                self.evaluateJavaScript(js)
            }
        }
    }

    private func processQuery(_ name: String, withBody body: Any?, queryId: Int64) async {
        if let queryHandler = queryHandlerDict[name] {
            // All entries in queryHandlerDict are of type ITMWKQueryHandler.
            // ITMWKQueryHandler's implementation of ITMQueryHandler.handleQuery
            // always returns true. If you register to handle a specific query
            // you must handle it. Since there can be only one handler for any
            // particular query, return if we find one.
            _ = await queryHandler.handleQuery(queryId, name, body)
            return
        }
        for queryHandler in queryHandlers {
            // These query handlers don't indicate what queries they handle.
            // So iterate through all of them until one indicates that it has
            // handled the query.
            if await queryHandler.handleQuery(queryId, name, body) {
                return
            }
        }
        // If we get this far, nothing handled the query. Send an error response back.
        logError("ITMMessenger no SWIFT handler for WKID\(queryId) '\(name)'")
        respondToQuery(queryId, nil)
    }

    private func processQueryResponse(_ response: Any?, queryId: Int64, error: Any?) {
        Task {
            guard let handler = await responseHandlers[queryId] else { return }
            let responseString = jsonString(response)
            if let error = error {
                logQuery("Error Response JS -> SWIFT", "SWID\(queryId)", nil, messageData: error)
                if !handleNotImplementedError(error: error, handler: handler) {
                    handler(.failure(ITMError(jsonString: jsonString(error))))
                }
            } else {
                logQuery("Response JS -> SWIFT", "SWID\(queryId)", nil, messageData: response)
                handler(.success(responseString))
            }
            await responseHandlers.removeValue(forKey: queryId)
        }
    }

    private func logQuery(_ title: String, _ queryId: String, _ type: String?, messageData: Any?) {
        logQuery(title, queryId, type, prettyDataString: messageData != nil && ITMMessenger.isFullLoggingEnabled ? JSONSerialization.string(withITMJSONObject: messageData, prettyPrint: true) : nil)
    }

    private func logQuery(_ title: String, _ queryId: String, _ type: String?, dataString: String?) {
        // Note: the original string is not pretty-printed, so convert it into an object here, then
        // logMessage(,,,messageData:) will convert it to a pretty-printed JSON string.
        logQuery(title, queryId, type, messageData: dataString != nil && ITMMessenger.isFullLoggingEnabled ? JSONSerialization.jsonObject(withString: dataString!) : nil)
    }

    private func handleNotImplementedError(error: Any, handler: ITMResponseHandler) -> Bool {
        guard let errorDict = error as? [String: Any] else { return false }
        guard let notImplemented = errorDict["MessageNotImplemented"] as? Bool, notImplemented else { return false }
        let description = errorDict["Description"] as? String ?? "No handler for <Unknown> query."
        logError("ModelWebApp \(description)")
        handler(.failure(ITMError(jsonString: jsonString(error))))
        return true
    }

    private func internalQuery<T>(_ type: String, _ data: Any? = nil) async throws -> T {
        try await frontendLaunched
        let dataString = try await internalQuery(type, dataString: JSONSerialization.string(withITMJSONObject: data) ?? "")
        return try self.convertResult(type, dataString)
    }

    private func internalQueryAndShowError<T>(_ vc: UIViewController?, _ type: String, _ data: Any? = nil) async throws -> T {
        do {
            return try await internalQuery(type, data)
        } catch {
            _ = await ITMMessenger.errorHandler(vc, error)
            throw error
        }
    }

    private func convertResult<T>(_ messageType: String, _ dataString: String) throws -> T {
        var data = ITMMessenger.parseMessageJsonString(dataString)
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
        let dataType = data == nil ?"<null>" : String(describing: type(of: data!))
        let expectedType = String(describing: T.self)
        let reason =
            "Could not cast response data from '\(dataType)' to expected type '\(expectedType)'. " +
            "Check your type cast for message response of type '\(messageType)' and if data arrived as expected."

        ITMApplication.logger.log(.error, reason)
        #if DEBUG
            assert(false, reason)
        #endif

        throw ITMError(jsonString: jsonString(["REASON": reason, "Internal": true]))
    }

    private static func parseMessageJsonString(_ jsonStr: String) -> Any? {
        return JSONSerialization.jsonObject(withString: jsonStr)
    }
}
