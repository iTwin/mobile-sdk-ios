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
                self.evaluateJavaScript(str) { (data: Sendable?, error) in
                    if let error {
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
        guard let object else {
            return ""
        }
        if let _ = object as? Void {
            // Return empty JSON string for void.
            return ""
        }
        if let array = object as? NSArray, array.count == 0 {
            // JSONSerialization is broken and puts two newlines between the square brackets. For an empty array we
            // don't want any newlines, even if prettyPrint is true, so just hard code a replacement.
            return "[]"
        }
        if let dict = object as? NSDictionary, dict.count == 0 {
            // JSONSerialization is broken and puts two newlines between the curly braces. For an empty dictionary we
            // don't want any newlines, even if prettyPrint is true, so just hard code a replacement.
            return "{}"
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
        let options: JSONSerialization.WritingOptions = prettyPrint && !wrapped ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.fragmentsAllowed]
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
open class ITMError: Error, CustomStringConvertible, @unchecked Sendable {
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
open class ITMMessenger: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    /// Convenience typealias for a function that takes a `String Result` and returns void.
    public typealias ITMResponseHandler = @Sendable (Result<String, Error>) -> Void
    /// Convenience typealias for an async function that takes an optional UIViewController and an Error.
    public typealias ITMErrorHandler = (_ vc: UIViewController?, _ baseError: Error) async -> Void

    private let transport: ITMFrontendQueryTransport
    private let implementation: ITMMessengerImpl

    /// The webView associated with this ITMMessenger.
    open var webView: WKWebView {
        get { transport.webView }
        set { transport.webView = newValue }
    }

    /// The error handler for this ITMMessenger. Replace this value with a custom ITMErrorHandler to present the error to your user.
    /// The default handler simply logs the error using ITMApplication.logger.
    public static var errorHandler: ITMErrorHandler = { (_ vc: UIViewController?, _ baseError: Error) async -> Void in
        ITMApplication.log(.error, baseError.localizedDescription)
    }

    /// Add a query type to the list of unlogged queries.
    ///
    /// Unlogged queries are ignored by ``logQuery(_:_:_:prettyDataString:)``. This is useful (for example)
    /// for queries that are themselves intended to produce log output, to prevent double log output.
    ///
    /// - Note: This is shared with ``ITMBackendMessenger``.
    /// - SeeAlso: ``removeUnloggedQueryType(_:)``
    /// - Parameter type: The type of the query for which logging is disabled.
    open class func addUnloggedQueryType(_ type: String) {
        ITMMessengerLoggingOptions.shared.addUnloggedQueryType(type)
    }

    /// Remove a query type from the list of unlogged queries.
    ///
    /// - Note: This is shared with ``ITMBackendMessenger``.
    /// - SeeAlso: ``addUnloggedQueryType(_:)``
    /// - Parameter type: The type of the query to remove.
    open class func removeUnloggedQueryType(_ type: String) {
        ITMMessengerLoggingOptions.shared.removeUnloggedQueryType(type)
    }

    /// Whether or not to log messages.
    /// - Note: This is shared with ``ITMBackendMessenger``.
    public static var isLoggingEnabled: Bool {
        get { ITMMessengerLoggingOptions.shared.isLoggingEnabled }
        set { ITMMessengerLoggingOptions.shared.isLoggingEnabled = newValue }
    }
    /// Whether or not full logging of all messages (with their optional bodies) is enabled.
    /// - Important: You should only enable this in debug builds, since message bodies may contain private information.
    /// - Note: This is shared with ``ITMBackendMessenger``.
    public static var isFullLoggingEnabled: Bool {
        get { ITMMessengerLoggingOptions.shared.isFullLoggingEnabled }
        set { ITMMessengerLoggingOptions.shared.isFullLoggingEnabled = newValue }
    }
    /// Indicates whether or not the frontend has finished launching. Specfically, if ``frontendLaunchSucceeded()`` has been called.
    public var frontendLaunchDone: Bool {
        get { implementation.launchDone }
        set { implementation.launchDone = newValue }
    }

    /// Create an ``ITMMessenger`` attached to a `WKWebView`.
    /// - Parameter webView: The `WKWebView` to which to attach this ``ITMMessenger``.
    public init(_ webView: WKWebView) {
        transport = ITMFrontendQueryTransport(webView)
        implementation = ITMMessengerImpl(transport: transport, targetName: "JS", incomingIdPrefix: "WKID", outgoingIdPrefix: "SWID")
        super.init()
        initFrontendLaunch()
    }

    /// Initializes things in preperation of launching the frontend. This is done automatically from `init`,
    /// and must be done again if the frontend crashes or is killed by iOS or iPadOS due to lack of memory.
    open func initFrontendLaunch() {
        implementation.initLaunch()
    }

    /// Wait until this ``ITMMessenger`` has fully finished initializing.
    public func waitUntilReady() async {
        await implementation.waitUntilReady()
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
            // TODO: return?
            let _: Void = try await implementation.queryAndShowError(vc, type, data)
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
        return try await implementation.queryAndShowError(vc, type, data)
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
        implementation.send(type, data)
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
        let _: Void = try await implementation.query(type, data)
    }

    /// Send message and receive an async parsed typed response.
    /// - Throws: Throws an error if there is a problem.
    /// - Parameters:
    ///   - type: Query type.
    ///   - data: Optional request data to send.
    /// - Returns: The value returned by the TypeScript code.
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
    /// - SeeAlso: ``registerQueryHandler(_:_:)``
    /// ``registerQueryHandler(_:)``
    /// - Parameter handler: Query handler to unregister.
    public func unregisterQueryHandler(_ handler: ITMQueryHandler) {
        implementation.unregisterQueryHandler(handler)
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
        transport.evaluateJavaScript(js)
    }

    /// Implementation of the `WKScriptMessageHandler` function. If you override this function, it is __STRONGLY__ recommended
    /// that you call this version via super as part of your implementation.
    /// - Note: Since query handling is async, this function will return before that finishes if the message is a query.
    open func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        transport.userContentController(userContentController, didReceive: message)
    }

    /// Send query response to WKWebView.
    /// - Parameters:
    ///   - queryId: The queryId for the query. This must be the queryId passed into `ITMQueryHandler.handleQuery`.
    ///   - type: The type of the query that is being responded to.
    ///   - responseJson: The JSON-encoded response string. If this is `nil`, it indicates an error. To indicate "no response" without
    ///   triggering an error, use an empty string.
    open func respondToQuery(_ queryId: Int64, _ type: String, _ responseJson: String?, _ error: Error? = nil) {
        implementation.respondToQuery(queryId, type, responseJson, error)
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
        implementation.logQuery(title, queryId, type, prettyDataString: prettyDataString)
    }

    /// Log an error message using `ITMApplication.logger`.
    /// - Parameter message: The error message to log.
    public func logError(_ message: String) {
        ITMApplication.log(.error, message)
    }

    /// Log an info message using `ITMApplication.logger`.
    /// - Parameter message: The info message to log.
    public func logInfo(_ message: String) {
        ITMApplication.log(.info, message)
    }

    /// Call after the frontend has successfully launched, indicating that any queries that are sent to TypeScript will be received.
    /// - Important: Until you call this, all queries sent to TypeScript are kept on hold.
    open func frontendLaunchSucceeded() {
        implementation.launchSucceeded()
    }

    /// Called if the frontend fails to launch. This prevents any queries from being sent to TypeScript.
    open func frontendLaunchFailed(_ error: Error) {
        implementation.launchFailed(error)
    }

    /// Async property that resolves when the frontend launch has succeeded (``frontendLaunchSucceeded()`` has been called).
    /// - Throws: The value passed to the `error` parameter of ``frontendLaunchFailed(_:)``.
    public var frontendLaunched: () {
        get async throws {
            try await implementation.launched
        }
    }
}

// MARK: - ITMFrontendQueryTransport class

/// ``ITMQueryTransport`` that communicates with the frontend running in a `WKWebView`.
fileprivate final class ITMFrontendQueryTransport: NSObject, ITMQueryTransport, WKScriptMessageHandler, @unchecked Sendable {
    private struct WeakWKWebView: Equatable {
        weak var webView: WKWebView?
        static func == (lhs: WeakWKWebView, rhs: WeakWKWebView) -> Bool {
            lhs.webView == rhs.webView
        }
    }

    private static var weakWebViews: [WeakWKWebView] = []
    private static let queryName = "Bentley_ITMMessenger_Query"
    private static let queryResponseName = "Bentley_ITMMessenger_QueryResponse"
    private static let handlerNames = [queryName, queryResponseName]

    weak var delegate: ITMQueryTransportDelegate?
    var webView: WKWebView
    private var pendingQueries: [Int64: CheckedContinuation<ITMQueryResponse, Never>] = [:]
    private var jsQueue: [String] = []
    private var jsBusy = false

    init(_ webView: WKWebView) {
        let weakWebView = WeakWKWebView(webView: webView)
        if Self.weakWebViews.contains(weakWebView) {
            // Only ONE Messenger can be created at a time for each WKWebView.
            assert(false)
        }
        // Stop tracking all the web views that no longer exist.
        Self.weakWebViews.removeAll { $0.webView == nil }
        Self.weakWebViews.append(weakWebView)
        self.webView = webView
        super.init()
        for handlerName in Self.handlerNames {
            webView.configuration.userContentController.add(ITMWeakScriptMessageHandler(self), name: handlerName)
        }
    }

    deinit {
        let weakWebView = WeakWKWebView(webView: webView)
        let webViewCopy = webView
        Task { @MainActor in
            ITMFrontendQueryTransport.weakWebViews.removeAll { $0 == weakWebView }
            for handlerName in ITMFrontendQueryTransport.handlerNames {
                webViewCopy.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
            }
        }
    }

    func sendQuery(_ type: String, _ queryId: Int64, _ dataString: String) async -> ITMQueryResponse {
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                pendingQueries[queryId] = continuation
                evaluateJavaScript("window.\(Self.queryName)('\(type)', \(queryId), '\(dataString.toBase64())')")
            }
        }
    }

    /// Evaluates JavaScript strings one at a time, since `WKWebView` loses all but one of multiple concurrent evaluations.
    func evaluateJavaScript(_ js: String) {
        Task { @MainActor in
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

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? JSON
        else {
            delegate?.logError("ITMMessenger: Invalid or missing body")
            return
        }
        guard let queryId = jsonObject["queryId"] as? Int64 else {
            delegate?.logError("ITMMessenger: Invalid message body")
            return
        }
        switch message.name {
        case Self.queryName:
            guard let name = jsonObject["name"] as? String else {
                delegate?.logError("ITMMessenger: Invalid message body")
                return
            }
            let queryBody = jsonObject["message"]
            Task { @MainActor [weak self] in
                guard let messageJson = await self?.delegate?.processQuery(name, queryId, queryBody) else { return }
                self?.evaluateJavaScript("window.\(Self.queryResponseName)\(queryId)('\(messageJson.toBase64())')")
            }
        case Self.queryResponseName:
            let response: ITMQueryResponse
            if let error = jsonObject["error"] {
                response = .failure(ITMError(json: error as? JSON))
            } else {
                response = .success(jsonObject["response"])
            }
            Task { @MainActor in
                guard let continuation = pendingQueries.removeValue(forKey: queryId) else {
                    delegate?.logError("Query response with invalid or repeat queryId: \(queryId)")
                    return
                }
                continuation.resume(returning: response)
            }
        default:
            delegate?.logError("ITMMessenger: Unexpected message type: \(message.name)\n")
        }
    }
}
