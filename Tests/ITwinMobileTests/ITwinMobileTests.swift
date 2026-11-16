/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/
import XCTest
import WebKit
@testable import ITwinMobile

@MainActor
final class ITwinMobileTests: XCTestCase {
    private final class Fixtures: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
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
                    send({operation:'ready'});
                };
                window.Bentley_ITMMessengerReceive = function(payload) {
                    const message = JSON.parse(payload);
                    received.push(message);
                    if (message.operation === 'ready') ready = true;
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

    private func createMessenger() -> (WKWebView, ITMMessenger) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(Fixtures(), forURLScheme: "imodeljs")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)
        let messenger = ITMMessenger(view)
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
}
