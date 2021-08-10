//---------------------------------------------------------------------------------------
//
//     $Source: FieldiOS/App/Utils/ITMMessenger.swift $
//
//  $Copyright: (c) 2021 Bentley Systems, Incorporated. All rights reserved. $
//
//---------------------------------------------------------------------------------------

import PromiseKit
#if SWIFT_PACKAGE
import PMKFoundation
#endif
import WebKit

extension String {
    /// Convert a String into BASE64-encoded UTF-8 data.
    func toBase64() -> String {
        return Data(utf8).base64EncodedString()
    }
}

fileprivate extension JSONSerialization {
    static func string(withITMJSONObject object: Any?) -> String? {
        return string(withITMJSONObject: object, prettyPrint: false)
    }

    static func string(withITMJSONObject object: Any?, prettyPrint: Bool) -> String? {
        guard let object = object else {
            return ""
        }
        if let _ = object as? () {
            // Return empty JSON string for void.
            return ""
        }
        let options: JSONSerialization.WritingOptions = prettyPrint ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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

/// Protocol for ITMMessenger query handlers.
public protocol ITMQueryHandler: NSObjectProtocol {
    /// Called when a query arrives from TypeScript.
    /// You must eventually call [[ITMMessenger.respondToQuery]] (passing the given queryId) if you respond to a given query. You can do that after returning
    /// true from this function, but you must do so once you are done with the query.
    /// - Parameter queryId: The query ID that must be sent back to TypeScript in the reponse.
    /// - Parameter type: The query type.
    /// - Parameter body: Optional message data sent from TypeScript.
    /// - Returns: true if you handle the given query, or false otherwise
    func handleQuery(_ queryId: Int64, _ type: String, _ body: Any?) -> Bool
    func getQueryType() -> String?
}

public extension ITMQueryHandler {
    /// We'd really like getQueryType to be an optional protocol method that returns
    /// a string, but Swtift only allows optional protocol methods in @objc protocols.
    /// This extension means that any class that implements ITMQueryHandler that
    /// does not have a queryType doesn't have to implement getQueryType to return nil.
    func getQueryType() -> String? {
        return nil
    }
}

/// Because the WKWebView has a strong reference to any WKScriptMessageHandler
/// objects attached to its userContentController, and ITMMessenger has a
/// strong reference to the WKWebView, a retain cycle is created if we connect
/// the two directly. This class acts as a go-between, and since it has a weak
/// reference to its delegate, the retain cycle is broken.
public class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    public init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

/// Error with a JSON-encoded string with information about what went wrong.
open class ITMError: Error {
    public let jsonString: String

    public init() {
        self.jsonString = ""
    }

    public init(jsonString: String) {
        self.jsonString = jsonString
    }

    public init(json: [String: Any]) {
        self.jsonString = JSONSerialization.string(withITMJSONObject: json) ?? ""
    }
}

/// Class for interacting with the Messenger TypeScript class to allow messages to go back and forth between Swift and TypeScript.
open class ITMMessenger: NSObject, WKScriptMessageHandler {
    private class ITMWKQueryHandler<T, U>: NSObject, ITMQueryHandler {
        private var itmMessenger: ITMMessenger
        private var type: String
        private var handler: (T) -> Promise<U>

        init(_ itmMessenger: ITMMessenger, _ type: String, _ handler: @escaping (T) -> Promise<U>) {
            self.itmMessenger = itmMessenger
            self.type = type
            self.handler = handler
        }

        func getQueryType() -> String? {
            return type
        }

        func handleQuery(_ queryId: Int64, _ type: String, _ body: Any?) -> Bool {
            itmMessenger.logQuery("Request  JS -> SWIFT", "WKID\(queryId)", type, messageData: body)
            let promise: Promise<U>
            // swiftformat:disable void
            if T.self == Void.self {
                promise = handler(() as! T)
            } else if let typedBody = body as? T {
                promise = handler(typedBody)
            } else {
                itmMessenger.respondToQuery(queryId, nil)
                return true
            }
            promise.done { response in
                let responseString = self.itmMessenger.jsonString(response)
                self.itmMessenger.respondToQuery(queryId, responseString)
            }.catch { _ in
                self.itmMessenger.respondToQuery(queryId, nil)
            }
            return true
        }
    }

    private struct WeakWKWebView: Equatable {
        weak var webView: WKWebView?
        static func == (lhs: WeakWKWebView, rhs: WeakWKWebView) -> Bool {
            lhs.webView == rhs.webView
        }
    }

    public typealias ITMResponseHandler = (String?) -> ()
    public typealias ITMErrorHandler = (_ vc: UIViewController?, _ baseError: Error) -> Guarantee<()>

    open var webView: WKWebView
    public static var errorHandler: ITMErrorHandler = { (_ vc: UIViewController?, _ baseError: Error) -> Guarantee<()> in
        ITMApplication.logger.log(.error, baseError.localizedDescription)
        return Guarantee.value(())
    }

    // Note: queryId is static so that sequential WKMessageSenders that make use of the
    // same WKWebView will work properly. You cannot have two WKMessageSenders refer to
    // the same WKWebView at the same time, but you can create one, destroy it, then
    // create another.
    private static var queryId: Int64 = 0
    private static var weakWebViews: [WeakWKWebView] = []
    public static var isFullLoggingEnabled = false
    private let queryName = "Bentley_ITMMessenger_Query"
    private let queryResponseName = "Bentley_ITMMessenger_QueryResponse"
    private let handlerNames: [String]
    private var queryHandlerDict: [String: ITMQueryHandler] = [:]
    private var queryHandlers: [ITMQueryHandler] = []
    private var queryResponseHandlers: [Int64: (success: ITMResponseHandler?, failure: ITMResponseHandler?)] = [:]
    private var jsQueue: [String] = []
    private var jsBusy = false
    private var frontendLaunchPromise: Promise<()>
    private var frontendLaunchResolver: Resolver<()>

    /// - Parameter webView: The WKWebView to attach this ITMMessageSender to.
    /// - Parameter errorHandler: The ITMErrorHandler that handles errors inside queryAndShowError.
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
        (frontendLaunchPromise, frontendLaunchResolver) = Promise<()>.pending()
        super.init()
        for handlerName in handlerNames {
            webView.configuration.userContentController.add(WeakScriptMessageHandler(self), name: handlerName)
        }
    }

    deinit {
        let weakWebView = WeakWKWebView(webView: webView)
        ITMMessenger.weakWebViews.removeAll { $0 == weakWebView }
        for handlerName in handlerNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        }
    }

    /// Send query and receive parsed void response via Promise. Errors are shown automatically using errorHandler().
    /// - Parameter vc: if specified, is checked for visiblity and only then error is shown. view controller that displays error dialog if still visible. Errors shown globally if nil.
    /// - Parameter type: query type.
    /// - Parameter data: optional request data to send.
    /// - Returns: A void promise that completes when the query has been handled by the TypeScript code.
    @discardableResult
    public func queryAndShowError(_ vc: UIViewController?, _ type: String, _ data: Any? = nil) -> Promise<()> {
        return internalQueryAndShowError(vc, type, data)
    }

    /// Send message and receive parsed typed response via Promise. Errors are shown automatically using errorHandler().
    /// - Parameter vc: if specified, is checked for visiblity and only then error is shown. view controller that displays error dialog if still visible. Errors shown globally if nil.
    /// - Parameter type: query type.
    /// - Parameter data: optional request data to send.
    /// - Returns: A promise that completes with the value returned by the TypeScript code.
    @discardableResult
    public func queryAndShowError<T>(_ vc: UIViewController?, _ type: String, _ data: Any? = nil) -> Promise<T> {
        return internalQueryAndShowError(vc, type, data)
    }

    /// Send message and receive parsed void response via Promise. Errors cause the returned promise to reject.
    /// - Parameter type: query type.
    /// - Parameter data: optional request data to send.
    /// - Returns: A void promise that completes when the query has been handled by the TypeScript code.
    @discardableResult
    public func query(_ type: String, _ data: Any? = nil) -> Promise<()> {
        return internalQuery(type, data)
    }

    /// Send message and receive parsed typed response via Promise. Errors cause the returned promise to reject.
    /// - Parameter type: query type.
    /// - Parameter data: optional request data to send.
    /// - Returns: A promise that completes with the value returned by the TypeScript code.
    @discardableResult
    public func query<T>(_ type: String, _ data: Any? = nil) -> Promise<T> {
        return internalQuery(type, data)
    }

    /// Register specific query handler for the given query type. Returns created handler, use it with unregisterQueryHandler.
    /// - Parameter type: query type.
    /// - Parameter handler: callback function for query.
    /// - Returns: The query handler created to handle the given query type.
    public func registerQueryHandler<T, U>(_ type: String, _ handler: @escaping (T) -> Promise<U>) -> ITMQueryHandler {
        return internalRegisterQueryHandler(type, handler)
    }

    /// Register query handler for any otherwise unhandled query type.
    /// If you want one query handler to handle queries from multiple query types, create your own class that implements the ITMQueryHandler protocol. Then,
    /// in its handleQuery function, check the type, and handle any queries that have a type that you recognize and return true. Return false from other queries.
    /// - Parameter handler: query handler to register.
    public func registerQueryHandler(_ handler: ITMQueryHandler) {
        queryHandlers.append(handler)
    }

    /// Unregister a query handler registered with either [[registerQueryHandler]] function.
    /// - Parameter handler: query handler to unregister.
    public func unregisterQueryHandler(_ handler: ITMQueryHandler) {
        if let queryType = handler.getQueryType() {
            queryHandlerDict.removeValue(forKey: queryType)
        } else {
            queryHandlers.removeAll { $0.isEqual(handler) }
        }
    }

    /// Evaluate a JavaScript string in this ITMMessenger's WKWebView. Note that this uses a queue, and only one JavaScript string is evaluated at a time.
    /// WKWebView doesn't work right when multiple evaluateJavaScript calls are active at the same time.
    /// - Parameter js: The JavaScript string to evaluate.
    open func evaluateJavaScript(_ js: String) {
        // Calling evaluateJavascript multiple times in a row before the prior
        // evaluation completes results in loss of all but one. Either the first
        // or last is called, and the rest disappear.
        if jsBusy {
            jsQueue.append(js)
            return
        }
        jsBusy = true
        webView.evaluateJavaScript(js, completionHandler: { _, _ in
            self.jsBusy = false
            if self.jsQueue.isEmpty {
                return
            }
            let js = self.jsQueue[0]
            self.jsQueue.remove(at: 0)
            self.evaluateJavaScript(js)
        })
    }

    /// Implementation of the WKScriptMessageHandler function. If you override this function, it is STRONGLY recommended that you call this version via super
    /// as part of your implementation.
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
                processQuery(name, withBody: jsonObject["message"], queryId: queryId)
            }
            break
        case queryResponseName:
            let error = jsonObject["error"]
            if let queryId = jsonObject["queryId"] as? Int64 {
                processQueryResponse(jsonObject["response"], queryId: queryId, error: error != nil ? error as Any : nil)
            }
            break
        default:
            logError("ITMMessenger: Unexpected message type: \(message.name)\n")
            break
        }
    }

    /// Send query response to WKWebView.
    /// - Parameter queryId: The queryId for the query. This must be the queryId passed into [[ITMQueryHandler.handleQuery]].
    /// - Parameter responseJson: The JSON-encoded response string. If this is nil, it indicates an error. To indicate "no response" without triggering an
    ///                           error, use an empty string.
    open func respondToQuery(_ queryId: Int64, _ responseJson: String?) {
        logQuery("Response SWIFT -> JS", "WKID\(queryId)", nil, dataString: responseJson)
        let js: String
        if responseJson != nil {
            js = "window.Bentley_ITMMessenger_QueryResponse\(queryId)('\(responseJson!.toBase64())')"
        } else {
            // If we get here, the JS code sent a query that we don't handle. That should never
            // happen, so assert. Note that if a void response is desired, then responseJson
            // will be an empty string, not nil.
            logError("Unhandled query [JS -> Swift]: WKID\(queryId)\n")
            assert(false)
            js = "window.Bentley_ITMMessenger_QueryResponse\(queryId)()"
        }
        evaluateJavaScript(js)
    }

    /// Convert a value into a JSON string. This supports both void values and base types (String, Bool, numeric types).
    /// - Parameter value: The value to convert to a JSON string.
    /// - Returns: The JSON string for the given value.
    open func jsonString(_ value: Any?) -> String {
        return JSONSerialization.string(withITMJSONObject: value) ?? ""
    }

    /// Log the given query using [[logInfo]].
    /// - Parameter title: A title to show along with the logged message.
    /// - Parameter queryId: The queryId of the query.
    /// - Parameter type: The type of the query.
    /// - Parameter prettyDataString: The pretty-printed JSON representation of the query data.
    open func logQuery(_ title: String, _ queryId: String, _ type: String?, prettyDataString: String?) {
        let typeString = type != nil ? "'\(type!)'" : "(Match ID from Request above)"
        if !ITMMessenger.isFullLoggingEnabled {
            // In release mode, do not include message data.
            logInfo("ITMMessenger [\(title)] \(queryId): \(typeString)")
            return
        }
        // In debug mode, include message data.
        logInfo("ITMMessenger [\(title)] \(queryId): \(typeString)\n\(prettyDataString ?? "null")")
    }

    /// Log an error message using ITMApplication.logger.
    /// - Parameter message: The error message to log.
    public func logError(_ message: String) {
        ITMApplication.logger.log(.error, message)
    }

    /// Log an info message using ITMApplication.logger.
    /// - Parameter message: The info message to log.
    public func logInfo(_ message: String) {
        ITMApplication.logger.log(.info, message)
    }

    /// Called after the frontend has successfully launched, indicating that any queries that are sent to TypeScript will be received.
    open func frontendLaunchSuceeded() {
        frontendLaunchResolver.fulfill(())
    }

    /// Called if the frontend fails to launch. This prevents any queries from being sent to TypeScript.
    open func frontendLaunchFailed(_ error: Error) {
        frontendLaunchResolver.reject(error)
    }

    private func internalRegisterQueryHandler<T, U>(_ type: String, _ handler: @escaping (T) -> Promise<U>) -> ITMQueryHandler {
        let queryHandler = ITMWKQueryHandler<T, U>(self, type, handler)
        queryHandlerDict[type] = queryHandler
        return queryHandler
    }

    private func internalQueryWithCallbacks(_ type: String, dataString: String, success: ITMResponseHandler?, failure: ITMResponseHandler?) {
        _ = firstly {
            frontendLaunchPromise
        }.done {
            let queryId = ITMMessenger.queryId
            self.logQuery("Request  SWIFT -> JS", "SWID\(queryId)", type, dataString: dataString)
            ITMMessenger.queryId += 1
            self.queryResponseHandlers[queryId] = (success: success, failure: failure)
            let js = "window.Bentley_ITMMessenger_Query('\(type)', \(queryId), '\(dataString.toBase64())')"
            self.evaluateJavaScript(js)
        }
    }

    private func processQuery(_ name: String, withBody body: Any?, queryId: Int64) {
        if let queryHandler = queryHandlerDict[name] {
            // The ITMWKQueryHandler implementation of ITMQueryHandler here
            // always returns true. If you register to handle a specific query
            // you must handle it. Since there can be only one handler for any
            // particular query, return if we find one.
            _ = queryHandler.handleQuery(queryId, name, body)
            return
        }
        for queryHandler in queryHandlers {
            // These query handlers don't indicate what queries they handle.
            // So iterate through all of them until one indicates that it has
            // handled the query.
            if queryHandler.handleQuery(queryId, name, body) {
                return
            }
        }
        // If we get this far, nothing handled the query. Send an error response back.
        logError("ITMMessenger no SWIFT handler for WKID\(queryId) '\(name)'")
        respondToQuery(queryId, nil)
    }

    private func processQueryResponse(_ response: Any?, queryId: Int64, error: Any?) {
        if let handler = queryResponseHandlers[queryId] {
            let responseString = jsonString(response)
            if error != nil {
                logQuery("Error Response JS -> SWIFT", "SWID\(queryId)", nil, messageData: error)
                if !handleNotImplementedError(error: error!, failure: handler.failure!) {
                    handler.failure!(jsonString(error))
                }
            } else {
                logQuery("Response JS -> SWIFT", "SWID\(queryId)", nil, messageData: response)
                handler.success!(responseString)
            }
            queryResponseHandlers.removeValue(forKey: queryId)
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

    private func handleNotImplementedError(error: Any, failure: ITMResponseHandler) -> Bool {
        guard let errorDict = error as? [String: Any] else { return false }
        guard let notImplemented = errorDict["MessageNotImplemented"] as? Bool else { return false }
        if !notImplemented { return false }
        let description = errorDict["Description"] as? String ?? "No handler for <Unknown> query."
        logError("ModelWebApp \(description)")
        failure("")
        return true
    }

    private func internalQuery<T>(_ type: String, _ data: Any? = nil) -> Promise<T> {
        return Promise { seal in
            self.internalQueryWithCallbacks(
                type,
                dataString: JSONSerialization.string(withITMJSONObject: data) ?? "",
                success: { (dataStr: String?) in
                    self.callClosureWithGenericData(
                        type,
                        ITMMessenger.parseMessageJsonString(dataStr!),
                        { data in seal.fulfill(data) },
                        { error in seal.reject(error) }
                    )
                },
                failure: { (errorStr: String?) in
                    seal.reject(ITMError(jsonString: errorStr ?? ""))
                }
            )
        }
    }

    private func internalQueryAndShowError<T>(_ vc: UIViewController?, _ type: String, _ data: Any? = nil) -> Promise<T> {
        return firstly {
            internalQuery(type, data)
        }.recover { error -> Promise<T> in
            _ = ITMMessenger.errorHandler(vc, error)
            throw error
        }
    }

    private func callClosureWithGenericData<T>(_ messageType: String, _ data: Any?, _ closure: ((T) -> ())?, _ failure: ((ITMError) -> ())?) {
        if closure == nil {
            return
        }

        // swiftformat:disable void
        if T.self == Void.self {
            (closure as? ((()) -> ()))!(()) // Handle no parameters
            return
        }

        var data = data

        // JSONSerialization converts string "null" to NSNull object, that fails test "data is T" when T is Optional<>.
        if data is NSNull {
            data = nil
        }

        if data is T {
            closure!(data as! T)
            return
        }

        // Type does not match expectation - handle error gracefully.
        let dataType = data == nil ?"<null>" : String(describing: type(of: data!))
        let expectedType = String(describing: T.self)
        let reason =
            "Could not cast response data from '\(dataType)' to expected type '\(expectedType)'. " +
            "Check your type cast for message response of type '\(messageType)' and if data arrived as expected."

        print("ERROR: \(reason)")
        #if DEBUG
            assert(false, reason)
        #endif

        let error = ITMError(jsonString: jsonString(["REASON": reason, "Internal": true]))
        if failure != nil {
            failure!(error)
        } else {
            _ = ITMMessenger.errorHandler(nil, error)
        }
    }

    private static func parseMessageJsonString(_ jsonStr: String) -> Any? {
        return JSONSerialization.jsonObject(withString: jsonStr)
    }
}
