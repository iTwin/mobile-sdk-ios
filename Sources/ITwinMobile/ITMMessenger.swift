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

extension WKWebView {
    @discardableResult
    /// Workaround for Swift Compiler bug.
    /// The Swift compiler gives a warning if the completion-based evaluateJavaScript is used in a place where the async version could be used.
    /// Unfortunately, using the async version results in a run-time crash, because its return type is Any instead of Any?. This works around that bug.
    /// This bug has been reported to Apple.
    func evaluateJavaScriptAsync(_ str: String) async throws -> Any? {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.evaluateJavaScript(str) { data, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }
        }
    }
}

internal extension JSONSerialization {
    static func string(withITMJSONObject object: Any?, prettyPrint: Bool = false) -> String? {
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
        return try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])
    }
}

extension Task where Success == Never, Failure == Never {
    // Convenience so you don't have to figure out how many zeros to add to your sleep.
    static func sleep(milliseconds: UInt64) async throws {
        try await sleep(nanoseconds: milliseconds * 1000000)
    }
}

// MARK: - ITMQueryHandler protocol and default extension

/// Protocol for ITMMessenger query handlers.
public protocol ITMQueryHandler: NSObjectProtocol {
    /// Called when a query arrives from TypeScript.
    ///
    /// You must eventually call `ITMMessenger.respondToQuery` (passing the given queryId) if you respond
    /// to a given query. Return true after doing that.
    /// - Note: If there is an error, call `ITMMessenger.respondToQuery` with a nil `responseJson` and
    /// an appropriate value for `error`.
    /// - Parameters:
    ///   - queryId: The query ID that must be sent back to TypeScript in the reponse.
    ///   - type: The query type.
    ///   - body: Optional message data sent from TypeScript.
    /// - Returns: true if you handle the given query, or false otherwise. If you return true, the query will not be passed to any other query handlers.
    @MainActor
    func handleQuery(_ queryId: Int64, _ type: String, _ body: Any?) async -> Bool
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

// MARK: - Concrete Error classes

/// Error with JSON data containing information about what went wrong.
open class ITMError: Error, CustomStringConvertible {
    /// The string version of ``jsonValue`` (Empty string if jsonValue is `null`).
    public let jsonString: String
    /// The JSON data associated with this ``ITMError``.
    public let jsonValue: JSON?

    /// Create an ITMError with a null ``jsonValue`` and empty ``jsonString``.
    public init() {
        self.jsonValue = nil
        self.jsonString = ""
    }

    /// Create an ITMError with the given JSON string.
    /// - Note: `jsonString` should contain an object, not an array or basic value.
    /// - Parameter jsonString: The ``jsonString`` for this ITMError. This will be parsed to generate
    /// ``jsonValue``, and must contain an object value in order to be valid. If it contains an array value or a
    /// primitive value, ``jsonValue`` will be `null`.
    public init(jsonString: String) {
        self.jsonString = jsonString
        self.jsonValue = JSONSerialization.jsonObject(withString: jsonString) as? JSON
    }

    /// Create an ITMError with a JSON string created from the given dictionary.
    /// - Parameter json: A dictionary that will stored in ``jsonValue`` and converted to a string that will be stored
    /// in ``jsonString``.
    public init(json: JSON?) {
        self.jsonValue = json
        self.jsonString = JSONSerialization.string(withITMJSONObject: json) ?? ""
    }

    /// Indicates if this is a "not implemented" error, meaning that the web app received a message for which it does
    /// not have a handler.
    /// - Note: This will return `true` if ``jsonValue`` contains a `true` value for its "MessageNotImplemented" field.
    public var isNotImplemented: Bool {
        return jsonValue?["MessageNotImplemented"] as? Bool == true
    }

    /// The value of the "Description" property in ``jsonValue``, if present, otherwise nil.
    public var errorDescription: String? {
        jsonValue?["Description"] as? String
    }

    /// Provides a description for this ``ITMError``.
    public var description: String {
        if let description = errorDescription {
            return description
        }
        if let jsonObject = JSONSerialization.jsonObject(withString: jsonString),
           let prettyString = JSONSerialization.string(withITMJSONObject: jsonObject, prettyPrint: true) {
            return "ITMError jsonString:\n\(prettyString)"
        } else {
            return "ITMError jsonString:\n\(jsonString)"
        }
    }
}

/// Basic class that implements the `LocalizedError` protocol.
public struct ITMStringError: LocalizedError {
    /// See `LocalizedError` protocol.
    public var errorDescription: String?

    /// Create an ``ITMStringError`` (needed to use this type outside the framework).
    /// - Parameter errorDescription: value for ``errorDescription``.
    public init(errorDescription: String?) {
        self.errorDescription = errorDescription
    }
}

// MARK: - ITMMessenger class

/// Class for interacting with the Messenger TypeScript class to allow messages to go back and forth between Swift and TypeScript.
open class ITMMessenger: NSObject, WKScriptMessageHandler {
    private static var unloggedQueryTypes = Set<String>()
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
                if T.self == Void.self {
                    response = try await handler(() as! T)
                } else if let typedBody = body as? T {
                    response = try await handler(typedBody)
                } else {
                    itmMessenger.respondToQuery(queryId, type, nil, ITMError(json: ["message": "Invalid input"]))
                    return true
                }
                let responseString = itmMessenger.jsonString(response)
                itmMessenger.respondToQuery(queryId, type, responseString)
            } catch {
                itmMessenger.respondToQuery(queryId, type, nil, error)
            }
            return true
        }
    }

    /// Wrapper for a dictionary that uses an actor to ensure that all modifications happen in the same thread.
    private actor ResponseHandlers {
        private var responseHandlers: [Int64: ITMResponseHandler] = [:]
        private var types: [Int64: String] = [:]

        func set(_ key: Int64, _ type: String, _ value: @escaping ITMResponseHandler) {
            responseHandlers[key] = value
            types[key] = type
        }
        func getAndRemoveValue(forKey key: Int64) -> (String, ITMResponseHandler)? {
            guard let type = types[key], let responseHandler = responseHandlers[key] else {
                return nil
            }
            responseHandlers.removeValue(forKey: key)
            types.removeValue(forKey: key)
            return (type, responseHandler)
        }
    }

    private actor QueryId {
        private var queryId: Int64 = 0

        func next() -> Int64 {
            queryId += 1
            return queryId
        }
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

    /// Add a query type to the list of unlogged queries.
    ///
    /// Unlogged queries are ignored by ``logQuery(_:_:_:prettyDataString:)``. This is useful (for example)
    /// for queries that are themselves intended to produce log output, to prevent double log output.
    ///
    /// - SeeAlso: ``removeUnloggedQueryType(_:)``
    /// - Parameter type: The type of the query for which logging is disabled.
    open class func addUnloggedQueryType(_ type: String) {
        unloggedQueryTypes.insert(type)
    }

    /// Remove a query type from the list of unlogged queries.
    ///
    /// - SeeAlso: ``addUnloggedQueryType(_:)``
    /// - Parameter type: The type of the query to remove.
    open class func removeUnloggedQueryType(_ type: String) {
        unloggedQueryTypes.remove(type)
    }

    // Note: queryId is static so that sequential ITMMessengers that make use of the
    // same WKWebView will work properly. You cannot have two ITMMessengers refer to
    // the same WKWebView at the same time, but you can create one, destroy it, then
    // create another.
    private static var queryId = QueryId()
    private static var weakWebViews: [WeakWKWebView] = []
    /// Whether or not to log messages.
    public static var isLoggingEnabled = false
    /// Whether or not full logging of all messages (with their optional bodies) is enabled.
    /// - Important: You should only enable this in debug builds, since message bodies may contain private information.
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

    /// Create an ``ITMMessenger`` attached to a `WKWebView`.
    /// - Parameter webView: The `WKWebView` to which to attach this ``ITMMessenger``.
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
        initFrontendLaunch()
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

    /// Initializes things in preperation of launching the frontend. This is done automatically from `init`,
    /// and must be done again if the frontend crashes or is killed by iOS or iPadOS due to lack of memory.
    open func initFrontendLaunch() {
        frontendLaunchDone = false
        frontendLaunchTask = Task {
            try await withCheckedThrowingContinuation { continuation in
                frontendLaunchContinuation = continuation
            }
        }
    }

    /// Wait until this ``ITMMessenger`` has fully finished initializing.
    public func waitUntilReady() async {
        // It's highly unlikely we could get here with frontendLaunchContinuation nil,
        // but if we do, we need to wait for it to be initialized before continuing, or
        // nothing will work.
        await ITMMessenger.waitUntilReady({ [self] in frontendLaunchContinuation != nil })
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
    ///   - vc: If specified, is checked for visiblity and only then error is shown. View controller that displays error dialog if
    ///   still visible. Errors shown globally if nil.
    ///   - type: Query type.
    ///   - data: Optional request data to send.
    public func queryAndShowError(_ vc: UIViewController?, _ type: String, _ data: Any? = nil) async {
        do {
            return try await internalQueryAndShowError(vc, type, data)
        } catch {
            // Ignore error (it has been shown, and we aren't being asked to produce a return
            // value that we don't have.)
        }
    }

    /// Send message and receive an async parsed typed response. Errors are shown automatically using ``errorHandler``.
    /// - Throws: If the query produces an error, it is thrown after being shown to the user via ``errorHandler``.
    /// - Parameters:
    ///   - vc: If specified, is checked for visiblity and only then error is shown. View controller that displays error dialog if
    ///   still visible.Errors shown globally if nil.
    ///   - type: Query type.
    ///   - data: Optional request data to send.
    /// - Returns: The value returned by the TypeScript code.
    @discardableResult
    public func queryAndShowError<T>(_ vc: UIViewController?, _ type: String, _ data: Any? = nil) async throws -> T {
        return try await internalQueryAndShowError(vc, type, data)
    }

    /// Send message with no response.
    /// - Note: Since this function returns without waiting for the message to finish sending or the Void response to
    /// be returned from the web app, there is no way to know if a failure occurs. (An error will be logged using
    /// `ITMMessenger.logger`.) Use ``query(_:_:)-447in`` if you need to wait for the message to finish or
    /// handle errors.
    /// - Parameters:
    ///   - type: Query type.
    ///   - data: Optional request data to send.
    public func send(_ type: String, _ data: Any? = nil) {
        Task {
            do {
                try await query(type, data)
            } catch {
                guard let itmError = error as? ITMError, !itmError.isNotImplemented else {
                    return
                }
                logError("Error with one-way query \"\(type)\": \(error)")
            }
        }
    }

    /// Send message without a return value and wait for it to complete.
    ///
    /// This is a convenience function to avoid requiring the following:
    ///
    /// ```swift
    /// let _: Void = try await itMessenger.query("blah")
    /// ```
    /// - Throws: Throws an error if there is a problem.
    /// - Parameters:
    ///   - type: Query type.
    ///   - data: Optional request data to send.
    public func query(_ type: String, _ data: Any? = nil) async throws {
        let _: Void = try await internalQuery(type, data)
    }

    /// Send message and receive an async parsed typed response.
    /// - Throws: Throws an error if there is a problem.
    /// - Parameters:
    ///   - type: Query type.
    ///   - data: Optional request data to send.
    /// - Returns: The value returned by the TypeScript code.
    public func query<T>(_ type: String, _ data: Any? = nil) async throws -> T {
        return try await internalQuery(type, data)
    }

    /// Register a specific query handler for the given query type. Returns created handler, use it with ``unregisterQueryHandler(_:)``
    /// - SeeAlso: ``unregisterQueryHandler(_:)``
    /// ``unregisterQueryHandlers(_:)``
    /// - Parameters:
    ///   - type: Query type.
    ///   - handler: Callback function for query.
    /// - Returns: The query handler created to handle the given query type.
    public func registerQueryHandler<T, U>(_ type: String, _ handler: @MainActor @escaping (T) async throws -> U) -> ITMQueryHandler {
        return internalRegisterQueryHandler(type, handler)
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
        queryHandlers.append(handler)
    }

    /// Unregister a query handler registered with ``registerQueryHandler(_:_:)`` or ``registerQueryHandler(_:)``.
    /// - SeeAlso: ``registerQueryHandler(_:_:)``
    /// ``registerQueryHandler(_:)``
    /// - Parameter handler: Query handler to unregister.
    public func unregisterQueryHandler(_ handler: ITMQueryHandler) {
        if let queryType = handler.getQueryType() {
            queryHandlerDict.removeValue(forKey: queryType)
        }
        queryHandlers.removeAll { $0.isEqual(handler) }
    }

    /// Unregister a query handlers registered with ``registerQueryHandler(_:_:)`` or ``registerQueryHandler(_:)``.
    /// - SeeAlso: ``registerQueryHandler(_:_:)``
    /// ``registerQueryHandler(_:)``
    /// - Parameter handlers: Array of query handlers to unregister.
    public func unregisterQueryHandlers(_ handlers: [ITMQueryHandler]) {
        for handler in handlers {
            unregisterQueryHandler(handler)
        }
    }

    /// Evaluate a JavaScript string in this `ITMMessenger`'s `WKWebView`. Note that this uses a queue, and only one JavaScript
    /// string is evaluated at a time. `WKWebView` doesn't work right when multiple `evaluateJavaScript` calls are active at the
    /// same time. This function returns immediately, while the JavaScript is scheduled for later evaluation.
    /// - Parameter js: The JavaScript string to evaluate.
    open func evaluateJavaScript(_ js: String) {
        Task { @MainActor in
            // Calling evaluateJavascript multiple times in a row before the prior
            // evaluation completes results in loss of all but one. Either the first
            // or last is called, and the rest disappear.
            if jsBusy {
                jsQueue.append(js)
                return
            }
            jsBusy = true
            do {
                try await webView.evaluateJavaScriptAsync(js)
            } catch {} // Ignore
            jsBusy = false
            if jsQueue.isEmpty {
                return
            }
            let nextJs = jsQueue.removeFirst()
            evaluateJavaScript(nextJs)
        }
    }

    /// Implementation of the `WKScriptMessageHandler` function. If you override this function, it is __STRONGLY__ recommended
    /// that you call this version via super as part of your implementation.
    /// - Note: Since query handling is async, this function will return before that finishes if the message is a query.
    open func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? JSON
        else {
            logError("ITMMessenger: Invalid or missing body")
            return
        }
        switch message.name {
        case queryName:
            guard let name = jsonObject["name"] as? String,
                  let queryId = jsonObject["queryId"] as? Int64 else {
                logError("ITMMessenger: Invalid message body")
                return
            }
            Task {
                await processQuery(name, withBody: jsonObject["message"], queryId: queryId)
            }
        case queryResponseName:
            let error = jsonObject["error"]
            guard let queryId = jsonObject["queryId"] as? Int64 else {
                logError("ITMMessenger: Invalid message body")
                return
            }
            processQueryResponse(jsonObject["response"], queryId: queryId, error: error)
        default:
            logError("ITMMessenger: Unexpected message type: \(message.name)\n")
        }
    }

    /// Send query response to WKWebView.
    /// - Parameters:
    ///   - queryId: The queryId for the query. This must be the queryId passed into `ITMQueryHandler.handleQuery`.
    ///   - type: The type of the query that is being responded to.
    ///   - responseJson: The JSON-encoded response string. If this is `nil`, it indicates an error. To indicate "no response" without
    ///   triggering an error, use an empty string.
    open func respondToQuery(_ queryId: Int64, _ type: String, _ responseJson: String?, _ error: Error? = nil) {
        logQuery("Response SWIFT -> JS", "WKID\(queryId)", type, dataString: responseJson)
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
            } else if let stringError = error as? ITMStringError, let errorDescription = stringError.errorDescription {
                let errorString = jsonString("\(errorDescription)")
                messageJson = "{\"error\":\(errorString)}"
            } else if let error = error {
                let errorString = jsonString("\(error)")
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
    /// - Note: If conversion fails (due to the value not being a type that can be converted to JSON), this returns an empty string.
    /// - Parameter value: The value to convert to a JSON string.
    /// - Returns: The JSON string for the given value.
    public static func jsonString(_ value: Any?, prettyPrint: Bool = false) -> String {
        return JSONSerialization.string(withITMJSONObject: value, prettyPrint: prettyPrint) ?? ""
    }

    /// Convert a value into a JSON string. This supports both void values and base types (String, Bool, numeric types).
    /// - Note: If conversion fails (due to the value not being a type that can be converted to JSON), this returns an empty string.
    /// - Parameter value: The value to convert to a JSON string.
    /// - Returns: The JSON string for the given value.
    open func jsonString(_ value: Any?, prettyPrint: Bool = false) -> String {
        return Self.jsonString(value, prettyPrint: prettyPrint)
    }

    /// Log the given query using ``logInfo(_:)``.
    /// - Note: If  ``isLoggingEnabled`` is false or `type` has been passed to ``addUnloggedQueryType(_:)``,
    /// the query will not be logged.
    /// - Parameters:
    ///   - title: A title to show along with the logged message.
    ///   - queryId: The queryId of the query.
    ///   - type: The type of the query.
    ///   - prettyDataString: The pretty-printed JSON representation of the query data. This is ignored if
    ///   ``isFullLoggingEnabled`` is `false`.
    open func logQuery(_ title: String, _ queryId: String, _ type: String, prettyDataString: String?) {
        guard ITMMessenger.isLoggingEnabled, !ITMMessenger.unloggedQueryTypes.contains(type) else {return}
        var message = "ITMMessenger [\(title)] \(queryId): \(type)"
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

    /// Call after the frontend has successfully launched, indicating that any queries that are sent to TypeScript will be received.
    /// - Important: Until you call this, all queries sent to TypeScript are kept on hold.
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
        let queryId = await ITMMessenger.queryId.next()
        logQuery("Request  SWIFT -> JS", "SWID\(queryId)", type, dataString: dataString)
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await responseHandlers.set(queryId, type, { result in
                    switch result {
                    case .success(let resultString):
                        continuation.resume(returning: resultString)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                })
                let js = "window.Bentley_ITMMessenger_Query('\(type)', \(queryId), '\(dataString.toBase64())')"
                evaluateJavaScript(js)
            }
        }
    }

    private func processQuery(_ type: String, withBody body: Any?, queryId: Int64) async {
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
        // If we get this far, nothing handled the query. Send an error response back.
        logError("ITMMessenger no SWIFT handler for WKID\(queryId) '\(type)'")
        respondToQuery(queryId, type, nil)
    }

    private func processQueryResponse(_ response: Any?, queryId: Int64, error: Any?) {
        Task {
            guard let (type, handler) = await responseHandlers.getAndRemoveValue(forKey: queryId) else {
                logError("Query response with invalid or repeat queryId: \(queryId)")
                return
            }
            let responseString = jsonString(response)
            if let error = error {
                logQuery("Error Response JS -> SWIFT", "SWID\(queryId)", type, messageData: error)
                if !handleNotImplementedError(error: error, handler: handler) {
                    handler(.failure(ITMError(json: error as? JSON)))
                }
            } else {
                logQuery("Response JS -> SWIFT", "SWID\(queryId)", type, messageData: response)
                handler(.success(responseString))
            }
        }
    }

    private func logQuery(_ title: String, _ queryId: String, _ type: String, messageData: Any?) {
        logQuery(title, queryId, type, prettyDataString: messageData != nil && ITMMessenger.isFullLoggingEnabled ? JSONSerialization.string(withITMJSONObject: messageData, prettyPrint: true) : nil)
    }

    private func logQuery(_ title: String, _ queryId: String, _ type: String, dataString: String?) {
        // Note: the original string is not pretty-printed, so convert it into an object here, then
        // logMessage(,,,messageData:) will convert it to a pretty-printed JSON string.
        logQuery(title, queryId, type, messageData: dataString != nil && ITMMessenger.isFullLoggingEnabled ? JSONSerialization.jsonObject(withString: dataString!) : nil)
    }

    private func handleNotImplementedError(error: Any, handler: ITMResponseHandler) -> Bool {
        let itmError = ITMError(json: error as? JSON)
        guard itmError.isNotImplemented else { return false }
        let description = itmError.errorDescription ?? "No handler for <Unknown> query."
        logError("ModelWebApp \(description)")
        handler(.failure(itmError))
        return true
    }

    private func internalQuery<T>(_ type: String, _ data: Any? = nil) async throws -> T {
        try await frontendLaunched
        let dataString = try await internalQuery(type, dataString: jsonString(data))
        return try convertResult(type, dataString)
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

        throw ITMError(json: ["REASON": reason, "Internal": true])
    }

    private static func parseMessageJsonString(_ jsonStr: String) -> Any? {
        return JSONSerialization.jsonObject(withString: jsonStr)
    }
}
