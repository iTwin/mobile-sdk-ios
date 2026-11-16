/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/
import WebKit

/// Document-bound transport; authorization is independent of overridable messenger methods.
internal final class ITMFrontendQueryTransport: NSObject, ITMQueryTransport, WKScriptMessageHandler, @unchecked Sendable {
    private final class DocumentSession {
        let id = UUID().uuidString
        let origin: String
        var documentId: String?
        var pending: [Int64: CheckedContinuation<ITMQueryResponse, Never>] = [:]
        var incoming: [Int64: Task<Void, Never>] = [:]
        var rateStart: TimeInterval = 0
        var rateCount = 0

        init(origin: String) { self.origin = origin }
    }

    private static let queryName = "Bentley_ITMMessenger_Query"
    private static let responseName = "Bentley_ITMMessenger_QueryResponse"
    private static let secureScript = "window.Bentley_ITMMessengerSecureBridge = true;"
    // Internal handler IDs must never be reused by a replacement document.
    private static var incomingId: Int64 = 0
    weak var delegate: ITMQueryTransportDelegate?
    weak var messageHandler: WKScriptMessageHandler?
    var sessionEnded: ((Error, Bool) -> Void)?
    var isFrontendLaunched: (() -> Bool)?
    var restoreFrontendLaunch: (() -> Void)?
    private(set) var webView: WKWebView
    private var allowedOrigins = ITMBridgeOriginPolicy.defaultAllowedOrigins
    private var session: DocumentSession?
    private var attached = false
    private var hasAttached = false
    private var navigating = false
    private var hasDocument = false
    private var suspendedDocumentId: String?
    private var loadingObservation: NSKeyValueObservation?
    private var lastDiagnostic: TimeInterval = -1
    private struct Evaluation {
        let script: String
        let session: DocumentSession?
        let closing: Bool
    }

    private var jsQueue: [Evaluation] = []
    private var jsBusy = false

    init(_ webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    func attach(_ view: WKWebView, allowedOrigins: Set<String>? = nil) {
        let origins = ITMBridgeOriginPolicy.validOrigins(allowedOrigins ?? self.allowedOrigins)
        if attached, webView === view, self.allowedOrigins == origins { return }
        if attached { detach() }
        if hasAttached { sessionEnded?(ITMStringError(errorDescription: "Messenger document replaced."), true) }
        hasAttached = true
        webView = view
        self.allowedOrigins = origins
        guard !origins.isEmpty else {
            sessionEnded?(ITMStringError(errorDescription: "Messenger has no trusted origins."), false)
            return
        }
        attached = true
        navigating = view.isLoading
        hasDocument = false
        let controller = view.configuration.userContentController
        if !controller.userScripts.contains(where: { $0.source == Self.secureScript }) {
            controller.addUserScript(WKUserScript(source: Self.secureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        for name in [Self.queryName, Self.responseName] {
            controller.add(ITMWeakScriptMessageHandler(self), name: name)
        }
        loadingObservation = view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            if view.isLoading { self?.onPageStarted(view) }
            else { self?.onPageFinished(view) }
        }
        onPageFinished(view)
    }

    func detach() {
        suspendedDocumentId = nil
        invalidateSession()
        loadingObservation = nil
        if attached {
            for name in [Self.queryName, Self.responseName] {
                webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
            }
        }
        attached = false
    }

    deinit {
        let view = webView
        let current = session
        let wasAttached = attached
        Task { @MainActor in
            for task in current?.incoming.values ?? [:].values { task.cancel() }
            for continuation in current?.pending.values ?? [:].values {
                continuation.resume(returning: .failure(ITMStringError(errorDescription: "Messenger detached.")))
            }
            if wasAttached {
                for name in [Self.queryName, Self.responseName] {
                    view.configuration.userContentController.removeScriptMessageHandler(forName: name)
                }
            }
        }
    }

    func onPageStarted(_ view: WKWebView) {
        guard attached, webView === view, !navigating else { return }
        navigating = true
        if let current = session {
            suspendedDocumentId = isFrontendLaunched?() == true ? current.documentId : nil
            invalidateSession(awaitingLaunch: true)
        } else if hasDocument {
            sessionEnded?(ITMStringError(errorDescription: "Messenger document session ended."), true)
        }
    }

    func onPageFinished(_ view: WKWebView) {
        guard attached, webView === view, !view.isLoading else { return }
        navigating = false
        guard session == nil, let url = view.url else { return }
        hasDocument = true
        guard let origin = ITMBridgeOriginPolicy.origin(for: url), allowedOrigins.contains(origin) else {
            diagnostic("Messenger frontend origin is not authorized.")
            sessionEnded?(ITMStringError(errorDescription: "Messenger frontend origin is not authorized."), false)
            return
        }
        let current = DocumentSession(origin: origin)
        session = current
        view.evaluateJavaScript("""
            (function() {
                if (window !== window.top) return false;
                window.Bentley_ITMMessengerNativeSession = '\(current.id)';
                if (typeof window.Bentley_ITMMessengerInitialize !== 'function') return false;
                window.Bentley_ITMMessengerInitialize('\(current.id)');
                return true;
            })();
            """) { [weak self] result, error in
                guard let self, self.session === current else { return }
                if error != nil {
                    self.diagnostic("Messenger bootstrap evaluation failed.")
                    self.invalidateSession()
                } else if result as? Bool != true {
                    // Core can initialize after load, then consume the published native session.
                    self.diagnostic("Messenger is waiting for a session-aware mobile-sdk-core frontend.")
                }
            }
    }

    private func invalidateSession(awaitingLaunch: Bool = false) {
        let previous = session
        session = nil
        jsQueue.removeAll()
        let error = ITMStringError(errorDescription: "Messenger document session ended.")
        if let previous {
            for task in previous.incoming.values { task.cancel() }
            for continuation in previous.pending.values { continuation.resume(returning: .failure(error)) }
            previous.pending.removeAll()
            previous.incoming.removeAll()
            // This cleanup contains no result data and is guarded in the receiving document.
            deliver(["operation": "closed"], session: previous, closing: true)
        }
        sessionEnded?(error, awaitingLaunch)
    }

    private func diagnostic(_ message: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDiagnostic >= 1 else { return }
        lastDiagnostic = now
        delegate?.logError(message)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard controller === webView.configuration.userContentController,
              let validated = validateScriptMessage(message) else { return }
        if let messageHandler {
            messageHandler.userContentController(controller, didReceive: message)
        } else {
            dispatchScriptMessage(message, session: validated.session, request: validated.request)
        }
    }

    func handleScriptMessage(_ message: WKScriptMessage) {
        // An override may change the document before forwarding through super.
        guard let validated = validateScriptMessage(message) else { return }
        dispatchScriptMessage(message, session: validated.session, request: validated.request)
    }

    private func validateScriptMessage(_ message: WKScriptMessage) -> (session: DocumentSession, request: JSON)? {
        guard attached, message.webView === webView, message.frameInfo.isMainFrame,
              !webView.isLoading, let current = session else {
            diagnostic("Rejected unauthorized Messenger caller.")
            return nil
        }
        let source = message.frameInfo.securityOrigin
        var components = URLComponents()
        components.scheme = source.protocol
        components.host = source.host
        guard (0...65535).contains(source.port) else { return nil }
        components.port = source.port == 0 ? nil : source.port
        guard let url = components.url, ITMBridgeOriginPolicy.origin(for: url) == current.origin,
              let currentURL = webView.url, ITMBridgeOriginPolicy.origin(for: currentURL) == current.origin else {
            diagnostic("Rejected unauthorized Messenger origin.")
            return nil
        }
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? JSON,
              request["sessionId"] as? String == current.id,
              let documentId = request["documentId"] as? String,
              documentId.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              let operation = request["operation"] as? String else {
            diagnostic("Rejected invalid Messenger envelope.")
            return nil
        }
        let isReady = operation == "ready" && message.name == Self.queryName &&
            request.count == 3 && current.documentId == nil
        guard isReady || current.documentId == documentId else {
            diagnostic("Rejected invalid Messenger document.")
            return nil
        }
        return (current, request)
    }

    private func dispatchScriptMessage(_ message: WKScriptMessage, session current: DocumentSession, request: JSON) {
        guard let documentId = request["documentId"] as? String,
              let operation = request["operation"] as? String else {
            diagnostic("Rejected invalid Messenger envelope.")
            return
        }
        if operation == "ready", message.name == Self.queryName {
            guard request.count == 3, current.documentId == nil else { return }
            current.documentId = documentId
            deliver(["operation": "ready"], session: current)
            if suspendedDocumentId == documentId { restoreFrontendLaunch?() }
            suspendedDocumentId = nil
            return
        }
        if operation == "closed", message.name == Self.queryName,
           current.documentId == documentId, request.count == 3 {
            invalidateSession()
            return
        }
        guard current.documentId == documentId,
              let number = request["queryId"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue == Double(number.int64Value) else {
            diagnostic("Rejected invalid Messenger query ID.")
            return
        }
        let queryId = number.int64Value
        if operation == "query", message.name == Self.queryName {
            guard Set(request.keys).isSubset(of: ["operation", "sessionId", "documentId", "queryId", "name", "message"]),
                  let name = request["name"] as? String, !name.isEmpty, name.utf16.count <= 1024 else {
                diagnostic("Rejected invalid Messenger query.")
                return
            }
            receiveQuery(name, queryId, request["message"], session: current)
        } else if operation == "queryResponse", message.name == Self.responseName {
            guard Set(request.keys).isSubset(of: ["operation", "sessionId", "documentId", "queryId", "response", "error", "unhandled"]),
                  let continuation = current.pending.removeValue(forKey: queryId) else {
                diagnostic("Rejected invalid Messenger response.")
                return
            }
            if let error = request["error"] {
                continuation.resume(returning: .failure(ITMError(jsonString: ITMMessenger.jsonString(error))))
            } else if request["unhandled"] as? Bool == true {
                continuation.resume(returning: .unhandled)
            } else {
                continuation.resume(returning: .success(request["response"]))
            }
        } else {
            diagnostic("Rejected unknown Messenger operation.")
        }
    }

    private func receiveQuery(_ name: String, _ queryId: Int64, _ body: Sendable?, session current: DocumentSession) {
        guard current.incoming[queryId] == nil else {
            diagnostic("Rejected duplicate Messenger query.")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - current.rateStart >= 1 { current.rateStart = now; current.rateCount = 0 }
        guard current.incoming.count < 128, current.rateCount < 100 else {
            deliverResponse(queryId, "{\"error\":\"Messenger request limit reached.\"}", session: current)
            return
        }
        current.rateCount += 1
        Self.incomingId += 1
        let internalId = Self.incomingId
        current.incoming[queryId] = Task { @MainActor [weak self] in
            guard let self, self.session === current, !Task.isCancelled else { return }
            defer { current.incoming.removeValue(forKey: queryId) }
            guard let response = await self.delegate?.processQuery(name, internalId, body),
                  !Task.isCancelled, self.session === current else { return }
            self.deliverResponse(queryId, response, session: current)
        }
    }

    private func deliverResponse(_ queryId: Int64, _ response: String, session current: DocumentSession) {
        deliver(["operation": "queryResponse", "queryId": queryId, "message": response.toBase64()], session: current)
    }

    private func deliver(_ message: JSON, session current: DocumentSession, closing: Bool = false) {
        guard closing || session === current, let documentId = current.documentId else { return }
        var envelope = message
        envelope["sessionId"] = current.id
        envelope["documentId"] = documentId
        let payload = ITMMessenger.jsonString(envelope)
        let encoded = ITMMessenger.jsonString(payload)
        // Check the document token at execution time, not just before scheduling.
        enqueueEvaluation(Evaluation(script: """
            (function() {
                if (window !== window.top || window.Bentley_ITMMessengerNativeSession !== '\(current.id)' ||
                    window.Bentley_ITMMessengerDocumentId !== '\(documentId)' ||
                    typeof window.Bentley_ITMMessengerReceive !== 'function') return false;
                window.Bentley_ITMMessengerReceive(\(encoded));
                return true;
            })();
            """, session: current, closing: closing))
    }

    @MainActor
    func sendQuery(_ type: String, _ queryId: Int64, _ dataString: String, isCurrent: @Sendable () -> Bool) async -> ITMQueryResponse {
        guard isCurrent(), let current = session, current.documentId != nil else {
            return .failure(ITMStringError(errorDescription: "Messenger has no ready document for this query."))
        }
        return await withCheckedContinuation { continuation in
            guard current.pending.count < 128 else {
                continuation.resume(returning: .failure(ITMStringError(errorDescription: "Messenger request limit reached.")))
                return
            }
            current.pending[queryId] = continuation
            deliver(["operation": "query", "queryId": queryId, "name": type, "message": dataString.toBase64()], session: current)
        }
    }

    /// Public arbitrary evaluation remains available, but sensitive transport delivery never uses it.
    nonisolated func enqueueJavaScript(_ js: String) {
        Task { @MainActor in
            enqueueEvaluation(Evaluation(script: js, session: nil, closing: false))
        }
    }

    @MainActor
    private func enqueueEvaluation(_ evaluation: Evaluation) {
        jsQueue.append(evaluation)
        guard !jsBusy else { return }
        jsBusy = true
        Task { @MainActor in
            defer { jsBusy = false }
            while !jsQueue.isEmpty {
                let next = jsQueue.removeFirst()
                if let expected = next.session, !next.closing, self.session !== expected { continue }
                do {
                    let result = try await webView.evaluateJavaScriptAsync(next.script)
                    if let expected = next.session, self.session === expected, result as? Bool != true {
                        diagnostic("Messenger response channel failed.")
                        invalidateSession()
                    }
                } catch {
                    diagnostic("Messenger JavaScript evaluation failed.")
                    if let expected = next.session, self.session === expected { invalidateSession() }
                }
            }
        }
    }
}
