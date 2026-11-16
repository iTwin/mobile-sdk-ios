/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/
import XCTest
import WebKit
@testable import ITwinMobile

@MainActor
final class ITwinMobileTests: XCTestCase {
    private final class CallbackMessenger: ITMMessenger, @unchecked Sendable {
        var receivedMessages: [WKScriptMessage] = []
        var beforeMessage: ((WKScriptMessage) -> Void)?

        override func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            receivedMessages.append(message)
            beforeMessage?(message)
            super.userContentController(userContentController, didReceive: message)
        }
    }

    private final class DispatchProbeMessenger: ITMMessenger, @unchecked Sendable {
        var onDiscardedResponse: (() -> Void)?

        override func respondToQuery(_ queryId: Int64, _ type: String, _ responseJson: String?, _ error: Error? = nil) {
            if type == "discarded" {
                onDiscardedResponse?()
            } else {
                super.respondToQuery(queryId, type, responseJson, error)
            }
        }
    }

    private final class AsyncQueryHandler: NSObject, ITMQueryHandler, @unchecked Sendable {
        private let type: String?
        private let handle: @MainActor () async -> Bool

        init(type: String? = nil, handle: @escaping @MainActor () async -> Bool) {
            self.type = type
            self.handle = handle
        }

        func getQueryType() -> String? { type }

        @MainActor
        func handleQuery(_ queryId: Int64, _ type: String, _ body: Sendable?) async -> Bool {
            await handle()
        }
    }

    private final class PausingMessenger: ITMMessenger, @unchecked Sendable {
        var beforeSerializing: (() -> Void)?

        override func jsonString(_ value: Any?, prettyPrint: Bool = false) -> String {
            if value as? String == "sensitive" { beforeSerializing?() }
            return super.jsonString(value, prettyPrint: prettyPrint)
        }
    }

    private final class Fixtures: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            if task.request.url?.path == "/cancelled" {
                task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                return
            }
            let frame = task.request.url?.path == "/frame"
            let source = frame ? """
                <script>
                const payload = JSON.parse(new URL(location.href).searchParams.get('payload'));
                const handler = payload.operation === 'queryResponse' ? 'Bentley_ITMMessenger_QueryResponse' : 'Bentley_ITMMessenger_Query';
                webkit.messageHandlers[handler].postMessage(JSON.stringify(payload));
                parent.postMessage('attempted', '*');
                </script>
                """ : """
                <script>
                window.received = []; window.attempts = 0; window.ready = false;
                window.Bentley_ITMMessengerDocumentId = 'document-' + Math.random().toString(36).slice(2);
                window.send = function(message) {
                    webkit.messageHandlers.Bentley_ITMMessenger_Query.postMessage(JSON.stringify(Object.assign({
                        sessionId: Bentley_ITMMessengerNativeSession,
                        documentId: Bentley_ITMMessengerDocumentId
                    }, message)));
                };
                window.Bentley_ITMMessengerInitialize = function(id) {
                    window.Bentley_ITMMessengerNativeSession = id;
                    window.ready = false;
                    send({operation:'ready'});
                };
                window.Bentley_ITMMessengerReceive = function(payload) {
                    const message = JSON.parse(payload);
                    received.push(message);
                    if (message.operation === 'ready') ready = true;
                    if (message.operation === 'closed') ready = false;
                    if (message.operation === 'query' && !ready) throw new Error('Query arrived before ready');
                    if (message.operation === 'query' && !window.holdResponses) {
                        webkit.messageHandlers.Bentley_ITMMessenger_QueryResponse.postMessage(JSON.stringify({
                            operation:'queryResponse', queryId:message.queryId,
                            response:message.name === 'large' ? JSON.parse(atob(message.message)) : 'h\u{00e9}llo',
                            sessionId:message.sessionId, documentId:message.documentId
                        }));
                    }
                };
                window.addEventListener('message', function(event) { if (event.data === 'attempted') attempts++; });
                </script>
                """
            let data = Data(source.utf8)
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    private func createMessenger(
        documentEndScript: String? = nil,
        factory: @MainActor (WKWebView) -> ITMMessenger = { ITMMessenger($0) }
    ) -> (WKWebView, ITMMessenger) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(Fixtures(), forURLScheme: "imodeljs")
        if let documentEndScript {
            configuration.userContentController.addUserScript(WKUserScript(
                source: documentEndScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)
        let messenger = factory(view)
        return (view, messenger)
    }

    private func evaluate(_ source: String, in view: WKWebView) async throws -> Any? {
        try await view.evaluateJavaScriptAsync(source)
    }

    private func waitFor(_ source: String, in view: WKWebView) async throws {
        for _ in 0..<300 {
            if try await evaluate(source, in: view) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("WebKit condition timed out: \(source)")
        throw ITMStringError(errorDescription: "WebKit condition timed out.")
    }

    private func load(_ view: WKWebView, _ origin: String = "imodeljs://app") async throws {
        view.load(URLRequest(url: URL(string: "\(origin)/main?run=\(UUID().uuidString)")!))
        // Avoid evaluating in the old document before the new navigation commits.
        for _ in 0..<300 {
            if !view.isLoading, view.url?.host == URL(string: origin)?.host { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if origin == "imodeljs://app" { try await waitFor("window.ready === true", in: view) }
    }

    func testBidirectionalQueriesAndDetach() async throws {
        let (view, messenger) = createMessenger()
        defer { messenger.detach() }
        _ = messenger.registerQueryHandler("echo") { (body: String) -> String in body }
        try await load(view)
        messenger.frontendLaunchSucceeded()
        let result: String = try await messenger.query("native's-query", ["value": "hello"])
        XCTAssertEqual(result, "h\u{00e9}llo")
        _ = try await evaluate("send({operation:'query',queryId:0,name:'echo',message:'world'}); true", in: view)
        try await waitFor("received.some(m => m.operation === 'queryResponse' && m.queryId === 0)", in: view)
        let encoded = try await evaluate("received.find(m => m.operation === 'queryResponse' && m.queryId === 0).message", in: view) as! String
        let response = try JSONSerialization.jsonObject(with: Data(base64Encoded: encoded)!) as! JSON
        XCTAssertEqual(response["response"] as? String, "world")
        _ = try await evaluate("window.holdResponses = true; true", in: view)
        let pending = Task { () -> Bool in
            do { let _: String = try await messenger.query("pending"); return false }
            catch { return true }
        }
        try await waitFor("received.some(m => m.name === 'pending')", in: view)
        _ = try await evaluate("""
            (function() {
                const queryId = received.find(m => m.name === 'pending').queryId;
                const payload = {operation:'queryResponse',queryId:queryId,response:'forged',
                    sessionId:Bentley_ITMMessengerNativeSession,documentId:Bentley_ITMMessengerDocumentId};
                webkit.messageHandlers.Bentley_ITMMessenger_QueryResponse.postMessage(JSON.stringify(Object.assign({}, payload, {sessionId:'wrong'})));
                webkit.messageHandlers.Bentley_ITMMessenger_QueryResponse.postMessage(JSON.stringify(Object.assign({}, payload, {documentId:'wrong'})));
                const frame = document.createElement('iframe');
                frame.src = 'imodeljs://app/frame?payload=' + encodeURIComponent(JSON.stringify(payload));
                document.body.appendChild(frame); return true;
            })();
            """, in: view)
        try await waitFor("attempts === 1", in: view)
        messenger.detach()
        let failed = await pending.value
        XCTAssertTrue(failed)
        do {
            let _: String = try await messenger.query("after-detach")
            XCTFail("Detached queries must fail instead of waiting for another document.")
        } catch {}
        _ = try await evaluate("window.holdResponses = false; window.ready = false; true", in: view)
        messenger.attach(view)
        try await waitFor("window.ready === true", in: view)
        messenger.frontendLaunchSucceeded()
        let reattached: String = try await messenger.query("reattached")
        XCTAssertEqual(reattached, "h\u{00e9}llo")
    }

    func testLargePayloadsRoundTripInBothDirections() async throws {
        let (view, messenger) = createMessenger()
        defer { messenger.detach() }
        _ = messenger.registerQueryHandler("echo") { (body: String) -> String in body }
        try await load(view)
        messenger.frontendLaunchSucceeded()
        let message = String(repeating: "x", count: 1_048_577)
        let result: String = try await messenger.query("large", message)
        XCTAssertEqual(result, message)
        _ = try await evaluate("send({operation:'query',queryId:0,name:'echo',message:'x'.repeat(1048577)}); true", in: view)
        try await waitFor("received.some(m => m.operation === 'queryResponse' && m.queryId === 0)", in: view)
        let matches = try await evaluate("""
            JSON.parse(atob(received.find(m => m.operation === 'queryResponse' && m.queryId === 0).message)).response === 'x'.repeat(1048577)
            """, in: view) as? Bool
        XCTAssertEqual(matches, true)
    }

    func testBackgroundJavaScriptEvaluationsAreNotLost() async throws {
        let (view, messenger) = createMessenger()
        defer { messenger.detach() }
        try await load(view)
        _ = try await evaluate("window.evaluationIds = []; true", in: view)
        await withTaskGroup(of: Void.self) { group in
            for id in 0..<200 {
                group.addTask {
                    messenger.evaluateJavaScript("evaluationIds.push(\(id));")
                }
            }
        }
        try await waitFor("evaluationIds.length === 200", in: view)
        let uniqueCount = try await evaluate("new Set(evaluationIds).size", in: view) as? Int
        XCTAssertEqual(uniqueCount, 200)
    }

    func testSubclassCallbacksReceiveOnlyAuthorizedDocumentMessages() async throws {
        let (view, messenger) = createMessenger(factory: { CallbackMessenger($0) })
        let observer = messenger as! CallbackMessenger
        defer { messenger.detach() }
        _ = messenger.registerQueryHandler("echo") { (body: String) -> String in body }
        try await load(view)
        messenger.frontendLaunchSucceeded()
        _ = try await evaluate("send({operation:'query',queryId:0,name:'echo',message:'valid'}); true", in: view)
        try await waitFor("received.some(m => m.operation === 'queryResponse' && m.queryId === 0)", in: view)
        let response: String = try await messenger.query("native-query")
        XCTAssertEqual(response, "h\u{00e9}llo")
        _ = try await evaluate("""
            send({operation:'query',queryId:10,name:'echo',message:'wrong session',sessionId:'wrong'});
            send({operation:'query',queryId:11,name:'echo',message:'wrong document',documentId:'wrong'});
            const frame = document.createElement('iframe');
            frame.src = 'imodeljs://app/frame?payload=' + encodeURIComponent(JSON.stringify({
                operation:'query',queryId:12,name:'echo',message:'subframe',
                sessionId:Bentley_ITMMessengerNativeSession,documentId:Bentley_ITMMessengerDocumentId
            }));
            document.body.appendChild(frame); true;
            """, in: view)
        try await waitFor("attempts === 1", in: view)
        _ = try await evaluate("send({operation:'query',queryId:1,name:'echo',message:'sentinel'}); true", in: view)
        try await waitFor("received.some(m => m.operation === 'queryResponse' && m.queryId === 1)", in: view)
        XCTAssertEqual(observer.receivedMessages.count, 4)
        XCTAssertEqual(observer.receivedMessages.map(\.name), [
            "Bentley_ITMMessenger_Query", "Bentley_ITMMessenger_Query",
            "Bentley_ITMMessenger_QueryResponse", "Bentley_ITMMessenger_Query",
        ])
    }

    func testReadyPrecedesHighPriorityQueriesDuringCancelledNavigationRecovery() async throws {
        let (view, messenger) = createMessenger(factory: { CallbackMessenger($0) })
        let observer = messenger as! CallbackMessenger
        defer { messenger.detach() }
        try await load(view)
        messenger.frontendLaunchSucceeded()
        for _ in 0..<8 {
            let finished = expectation(description: "Recovery query receives a reply after ready")
            var pending: Task<Void, Never>?
            observer.beforeMessage = { message in
                guard let body = message.body as? String, body.contains("\"operation\":\"ready\"") else { return }
                pending = Task(priority: .high) {
                    do {
                        let response: String = try await messenger.query("during-recovery")
                        XCTAssertEqual(response, "h\u{00e9}llo")
                    } catch { XCTFail("Recovery query failed: \(error)") }
                    finished.fulfill()
                }
            }
            _ = try await evaluate("window.originalSession = Bentley_ITMMessengerNativeSession; true", in: view)
            view.load(URLRequest(url: URL(string: "imodeljs://app/cancelled")!))
            await fulfillment(of: [finished], timeout: 5)
            try await waitFor("ready && Bentley_ITMMessengerNativeSession !== originalSession", in: view)
            let inOrder = try await evaluate("""
                (function() {
                    const messages = received.filter(m => m.sessionId === Bentley_ITMMessengerNativeSession);
                    return messages[0].operation === 'ready' && messages[1].name === 'during-recovery';
                })();
                """, in: view) as? Bool
            XCTAssertEqual(inOrder, true)
            await pending?.value
        }
    }

    func testNavigationDuringSerializationCannotRetargetQuery() async throws {
        let (view, messenger) = createMessenger(factory: { PausingMessenger($0) })
        let pausingMessenger = messenger as! PausingMessenger
        defer { messenger.detach() }
        try await load(view)
        messenger.frontendLaunchSucceeded()
        let serializing = expectation(description: "Old query admitted before navigation")
        let finished = expectation(description: "Stale query rejected")
        let release = DispatchSemaphore(value: 0)
        pausingMessenger.beforeSerializing = {
            serializing.fulfill()
            release.wait()
        }
        defer { release.signal() }
        let pending = Task.detached {
            do {
                let _: String = try await messenger.query("sensitive-query", "sensitive")
                XCTFail("An admitted query must not move to a replacement document.")
            } catch {}
            finished.fulfill()
        }
        await fulfillment(of: [serializing], timeout: 5)
        try await load(view)
        XCTAssertFalse(messenger.frontendLaunchDone)
        release.signal()
        await fulfillment(of: [finished], timeout: 5)
        let leaked = try await evaluate("received.some(m => m.name === 'sensitive-query')", in: view) as? Bool
        XCTAssertEqual(leaked, false)
        messenger.frontendLaunchSucceeded()
        let result: String = try await messenger.query("replacement-query")
        XCTAssertEqual(result, "h\u{00e9}llo")
        await pending.value
    }

    func testCancelledNavigationRestoresLaunchedDocumentButDiscardsPendingWork() async throws {
        let (view, messenger) = createMessenger()
        defer { messenger.detach() }
        try await load(view)
        messenger.frontendLaunchSucceeded()
        _ = try await evaluate("window.holdResponses = true; true", in: view)
        let failed = expectation(description: "Old pending query fails")
        let pending = Task {
            do {
                let _: String = try await messenger.query("pending-before-cancellation")
                XCTFail("Pending work must be discarded even if the document survives.")
            } catch { failed.fulfill() }
        }
        try await waitFor("received.some(m => m.name === 'pending-before-cancellation')", in: view)
        _ = try await evaluate("""
            window.originalSession = Bentley_ITMMessengerNativeSession;
            window.originalDocument = Bentley_ITMMessengerDocumentId;
            window.ready = false; true;
            """, in: view)
        view.load(URLRequest(url: URL(string: "imodeljs://app/cancelled")!))
        await fulfillment(of: [failed], timeout: 5)
        try await waitFor("ready && Bentley_ITMMessengerNativeSession !== originalSession", in: view)
        let sameDocument = try await evaluate("Bentley_ITMMessengerDocumentId === originalDocument", in: view) as? Bool
        XCTAssertEqual(sameDocument, true)
        XCTAssertTrue(messenger.frontendLaunchDone)
        _ = try await evaluate("window.holdResponses = false; true", in: view)
        let result: String = try await messenger.query("after-cancelled-navigation")
        XCTAssertEqual(result, "h\u{00e9}llo")
        await pending.value
    }

    func testBootstrapEvaluationFailureRejectsLaunchWaitersAndCanRetry() async throws {
        let (view, messenger) = createMessenger(documentEndScript: """
            window.initializeNormally = Bentley_ITMMessengerInitialize;
            window.Bentley_ITMMessengerInitialize = function() { throw new Error('bootstrap failed'); };
            """)
        defer { messenger.detach() }
        let failed = expectation(description: "Bootstrap failure releases launch waiters")
        let pending = Task {
            do {
                let _: String = try await messenger.query("waiting-for-launch")
                XCTFail("A bootstrap evaluation failure must reject waiting queries.")
            } catch { failed.fulfill() }
        }
        view.load(URLRequest(url: URL(string: "imodeljs://app/main")!))
        await fulfillment(of: [failed], timeout: 5)
        _ = try await evaluate("window.Bentley_ITMMessengerInitialize = initializeNormally; true", in: view)
        messenger.initFrontendLaunch()
        messenger.onPageFinished(view)
        try await waitFor("ready", in: view)
        messenger.frontendLaunchSucceeded()
        let result: String = try await messenger.query("retry")
        XCTAssertEqual(result, "h\u{00e9}llo")
        await pending.value
    }

    func testCoreMayInitializeAfterPageLoad() async throws {
        let (view, messenger) = createMessenger(documentEndScript: """
            window.initializeLater = Bentley_ITMMessengerInitialize;
            delete window.Bentley_ITMMessengerInitialize;
            """)
        defer { messenger.detach() }
        view.load(URLRequest(url: URL(string: "imodeljs://app/main")!))
        try await waitFor("typeof Bentley_ITMMessengerNativeSession === 'string'", in: view)
        let finished = expectation(description: "Query waits for delayed core initialization")
        let pending = Task {
            do {
                let result: String = try await messenger.query("delayed-core")
                XCTAssertEqual(result, "h\u{00e9}llo")
            } catch { XCTFail("Delayed core initialization must not fail launch: \(error)") }
            finished.fulfill()
        }
        _ = try await evaluate("""
            window.Bentley_ITMMessengerInitialize = initializeLater;
            Bentley_ITMMessengerInitialize(Bentley_ITMMessengerNativeSession); true;
            """, in: view)
        try await waitFor("ready", in: view)
        messenger.frontendLaunchSucceeded()
        await fulfillment(of: [finished], timeout: 5)
        await pending.value
    }

    func testFrameAndEnvelopeRejectionsInRealWebKit() async throws {
        let (view, messenger) = createMessenger()
        defer { messenger.detach() }
        var invocations = 0
        _ = messenger.registerQueryHandler("probe") { (_: JSON) -> Void in invocations += 1 }
        try await load(view)
        for (index, frame) in [("imodeljs://foreign", false), ("imodeljs://app", false), ("imodeljs://app", true)].enumerated() {
            _ = try await evaluate("""
                (function() {
                    const frame = document.createElement('iframe');
                    \(frame.1 ? "frame.sandbox = 'allow-scripts';" : "")
                    const payload = {operation:'query', queryId:\(index), name:'probe', message:{},
                        sessionId:Bentley_ITMMessengerNativeSession, documentId:Bentley_ITMMessengerDocumentId};
                    frame.src = '\(frame.0)/frame?payload=' + encodeURIComponent(JSON.stringify(payload));
                    document.body.appendChild(frame); return true;
                })();
                """, in: view)
            try await waitFor("attempts === \(index + 1)", in: view)
        }
        _ = try await evaluate("""
            send({operation:'query',queryId:10,name:'probe',message:{},sessionId:'wrong'});
            send({operation:'query',queryId:true,name:'probe',message:{}});
            send({operation:'query',queryId:11,message:{}});
            send({operation:'unknown',queryId:12,name:'probe'});
            send({operation:'query',queryId:13,name:'probe',message:{}});
            true;
            """, in: view)
        try await waitFor("received.some(m => m.queryId === 13)", in: view)
        XCTAssertEqual(invocations, 1)
    }

    func testNavigationSettlesPendingQueriesAndResetsReadiness() async throws {
        let (view, messenger) = createMessenger()
        defer { messenger.detach() }
        try await load(view)
        messenger.frontendLaunchSucceeded()
        _ = try await evaluate("window.holdResponses = true; true", in: view)
        let pending = Task { () -> Bool in
            do { let _: String = try await messenger.query("old-document"); return false }
            catch { return true }
        }
        try await waitFor("received.some(m => m.name === 'old-document')", in: view)
        try await load(view)
        let failed = await pending.value
        XCTAssertTrue(failed)
        XCTAssertFalse(messenger.frontendLaunchDone)
        messenger.frontendLaunchSucceeded()
        let current: String = try await messenger.query("new-document")
        XCTAssertEqual(current, "h\u{00e9}llo")
        let leaked = try await evaluate("received.some(m => m.name === 'old-document')", in: view) as? Bool
        XCTAssertEqual(leaked, false)
    }

    func testUntrustedStartupFailsWaitingQueriesAndTrustedNavigationRecovers() async throws {
        let (view, messenger) = createMessenger()
        defer { messenger.detach() }
        let pending = Task { () -> Bool in
            do { let _: String = try await messenger.query("startup"); return false }
            catch { return true }
        }
        try await load(view, "imodeljs://foreign")
        let failed = await pending.value
        XCTAssertTrue(failed)
        try await load(view)
        messenger.frontendLaunchSucceeded()
        let recovered: String = try await messenger.query("recovered")
        XCTAssertEqual(recovered, "h\u{00e9}llo")
    }

    func testLateHandlerCannotRespondToAReusedIdInTheNextDocument() async throws {
        let (view, messenger) = createMessenger()
        defer { messenger.detach() }
        var oldResponse: CheckedContinuation<String, Never>?
        _ = messenger.registerQueryHandler("delayed") { (_: JSON) -> String in
            await withCheckedContinuation { oldResponse = $0 }
        }
        _ = messenger.registerQueryHandler("echo") { (_: JSON) -> String in "current" }
        try await load(view)
        _ = try await evaluate("send({operation:'query',queryId:7,name:'delayed',message:{}}); true", in: view)
        for _ in 0..<300 {
            if oldResponse != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(oldResponse)
        try await load(view)
        oldResponse?.resume(returning: "old sensitive result")
        _ = try await evaluate("send({operation:'query',queryId:7,name:'echo',message:{}}); true", in: view)
        try await waitFor("received.some(m => m.queryId === 7)", in: view)
        let encoded = try await evaluate("received.find(m => m.queryId === 7).message", in: view) as! String
        let response = try JSONSerialization.jsonObject(with: Data(base64Encoded: encoded)!) as! JSON
        XCTAssertEqual(response["response"] as? String, "current")
        let count = try await evaluate("received.filter(m => m.queryId === 7).length", in: view) as? Int
        XCTAssertEqual(count, 1)
    }

    func testCancelledDispatchDoesNotInvokeRemainingHandlersOrFallback() async throws {
        for navigates in [true, false] {
            for (named, hasFollowingHandler) in [(true, true), (false, true), (false, false)] {
                let (view, messenger) = createMessenger(factory: { DispatchProbeMessenger($0) })
                let probe = messenger as! DispatchProbeMessenger
                defer { messenger.detach() }
                let started = expectation(description: "Handler suspended")
                let resumed = expectation(description: "Cancelled handler resumed")
                let discardedAction = expectation(description: "No further dispatch after teardown")
                discardedAction.isInverted = true
                probe.onDiscardedResponse = { discardedAction.fulfill() }
                var resume: CheckedContinuation<Bool, Never>?
                messenger.registerQueryHandler(AsyncQueryHandler(type: named ? "discarded" : nil) {
                    let handled = await withCheckedContinuation {
                        resume = $0
                        started.fulfill()
                    }
                    XCTAssertTrue(Task.isCancelled)
                    resumed.fulfill()
                    return handled
                })
                if hasFollowingHandler {
                    messenger.registerQueryHandler(AsyncQueryHandler {
                        discardedAction.fulfill()
                        return false
                    })
                }
                try await load(view)
                _ = try await evaluate("send({operation:'query',queryId:7,name:'discarded',message:{}}); true", in: view)
                await fulfillment(of: [started], timeout: 5)
                let continuation = try XCTUnwrap(resume)
                if navigates {
                    try await load(view)
                } else {
                    messenger.detach()
                }
                continuation.resume(returning: false)
                await fulfillment(of: [resumed], timeout: 5)
                await fulfillment(of: [discardedAction], timeout: 0.1)
            }
        }
    }
}
