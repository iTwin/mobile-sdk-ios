/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import WebKit

/// Logger that, when attached to a `WKWebView`, redirects console messages from JavaScript to `ITMApplication.logger`.
open class ITMWebViewLogger: NSObject, WKScriptMessageHandler {
    public static let defaultAllowedOrigins: Set<String> = ["imodeljs://app"]

    /// The logger name to show in log messages.
    var name: String
    private var allowedOrigins: Set<String>
    private weak var attachedWebView: WKWebView?
    private var loadingObservation: NSKeyValueObservation?
    private var sessionId: String?
    private var rateWindowStart: TimeInterval = 0
    private var rateWindowCount = 0

    /// - Parameter name: The logger name to show in log messages.
    public init(name: String) {
        self.name = name
        self.allowedOrigins = Self.defaultAllowedOrigins
    }

    /// Gets an exact origin for a supported frontend URL. File and opaque origins are not supported.
    public static func origin(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty, !host.contains("*"),
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        guard scheme == "http" || scheme == "https" ||
                (scheme == "imodeljs" && host == "app" && components.port == nil) else { return nil }
        var result = URLComponents()
        result.scheme = scheme
        result.host = host
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        result.port = components.port == defaultPort ? nil : components.port
        return result.string
    }

    private static func validOrigins(_ origins: Set<String>) -> Set<String> {
        Set(origins.filter { value in
            guard let url = URL(string: value) else { return false }
            return origin(for: url) == value
        })
    }

    /// Invalidates queued console output when the main frame starts navigating.
    public func onPageStarted() {
        sessionId = nil
        rateWindowStart = 0
        rateWindowCount = 0
    }

    /// Reinstalls wrappers in an authorized document without nesting existing wrappers.
    public func reattach(_ webView: WKWebView) {
        guard attachedWebView === webView, !webView.isLoading,
              let url = webView.url, let origin = Self.origin(for: url),
              allowedOrigins.contains(origin) else { return }
        let newSessionId = UUID().uuidString
        sessionId = newSessionId
        let js = """
        (function(sessionId) {
            if (window !== window.top) return;
            var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.itmLogger;
            if (!bridge || typeof bridge.postMessage !== "function") return;
            var stateName = "Bentley_ITMConsoleLoggerState";
            var state = window[stateName];
            if (state) { state.sessionId = sessionId; return; }
            state = { sessionId: sessionId, active: true, originals: {}, wrappers: {} };
            var forward = function(type, msg) {
                try {
                    if (!state.active) return;
                    if (msg == null) msg = "";
                    msg = String(msg);
                    if (msg.length > 16384) return;
                    bridge.postMessage({ sessionId: state.sessionId, type: type, msg: msg });
                } catch (_) {}
            };
            var injectLogger = function(type) {
                state.originals[type] = console[type];
                state.wrappers[type] = function(msg) {
                    state.originals[type].apply(console, arguments);
                    forward(type, msg);
                };
                console[type] = state.wrappers[type];
            };
            injectLogger("error");
            injectLogger("warn");
            injectLogger("info");
            injectLogger("log");
            injectLogger("trace");
            state.originals.assert = console.assert;
            state.wrappers.assert = function(expr, msg) {
                state.originals.assert.apply(console, arguments);
                if (expr) return;
                try { forward("assert", "Assertion Failed: " + (msg == null ? "" : String(msg))); } catch (_) {}
            };
            console.assert = state.wrappers.assert;
            var onError = function(event) { forward("error", event.message); };
            window.addEventListener("error", onError);
            state.detach = function() {
                state.active = false;
                Object.keys(state.originals).forEach(function(type) {
                    if (console[type] === state.wrappers[type]) console[type] = state.originals[type];
                });
                window.removeEventListener("error", onError);
                delete window[stateName];
            };
            window[stateName] = state;
        })("\(newSessionId)");
        true;
        """

        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Attach this ``ITMWebViewLogger`` to the given `WKWebView`.
    public func attach(_ webView: WKWebView) {
        if attachedWebView === webView {
            reattach(webView)
            return
        }
        detach()
        guard !allowedOrigins.isEmpty else { return }
        attachedWebView = webView
        webView.configuration.userContentController.add(ITMWeakScriptMessageHandler(self), name: "itmLogger")
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            if view.isLoading {
                self?.onPageStarted()
            } else {
                self?.reattach(view)
            }
        }
        reattach(webView)
    }

    /// Attaches using exact native-configured origins. Invalid entries are ignored; an empty set disables forwarding.
    public func attach(_ webView: WKWebView, allowedOrigins: Set<String>) {
        detach()
        self.allowedOrigins = Self.validOrigins(allowedOrigins)
        attach(webView)
    }

    /// Removes the handler and restores console methods where this logger installed wrappers.
    public func detach() {
        let oldSessionId = sessionId
        onPageStarted()
        loadingObservation = nil
        guard let webView = attachedWebView else { return }
        attachedWebView = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "itmLogger")
        if let oldSessionId {
            webView.evaluateJavaScript("""
                (function() {
                    var state = window.Bentley_ITMConsoleLoggerState;
                    if (state && state.sessionId === "\(oldSessionId)") state.detach();
                })();
                """, completionHandler: nil)
        }
    }

    /// `WKScriptMessageHandler` delegate function.
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = attachedWebView, message.webView === webView,
              message.name == "itmLogger", message.frameInfo.isMainFrame,
              let sessionId, !webView.isLoading else { return }
        let source = message.frameInfo.securityOrigin
          guard ["http", "https", "imodeljs"].contains(source.protocol.lowercased()),
              !source.host.isEmpty, (0...65535).contains(source.port) else { return }
        var components = URLComponents()
        components.scheme = source.protocol
        components.host = source.host
        components.port = source.port == 0 ? nil : source.port
        guard let sourceURL = components.url, let origin = Self.origin(for: sourceURL),
              allowedOrigins.contains(origin), let currentURL = webView.url,
              Self.origin(for: currentURL) == origin else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - rateWindowStart >= 1 {
            rateWindowStart = now
            rateWindowCount = 0
        }
        guard rateWindowCount < 100 else { return }
        rateWindowCount += 1
        guard let body = message.body as? [String: String], body.count == 3,
              body["sessionId"] == sessionId, let type = body["type"],
              ["error", "warn", "info", "log", "trace", "assert"].contains(type),
              let text = body["msg"], text.utf16.count <= 16384 else { return }
        log(type, "JS - \(name): \(text)")
    }

    /// Log the given message using `ITMApplication.logger`.
    ///
    /// Override this function in a subclass in order to add custom behavior.
    /// - Parameters:
    ///   - severity: The log severity string. Must be a value from ``ITMLogger.Severity``.
    ///   - logMessage: The message to log.
    open func log(_ severity: String?, _ logMessage: String) {
        ITMApplication.log(ITMLogger.Severity(severity), logMessage)
    }
}
