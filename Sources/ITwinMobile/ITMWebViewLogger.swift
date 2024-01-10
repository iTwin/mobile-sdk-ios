/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import WebKit

/// Logger that, when attached to a `WKWebView`, redirects console messages from JavaScript to `ITMApplication.logger`.
open class ITMWebViewLogger: NSObject, WKScriptMessageHandler {
    /// The logger name to show in log messages.
    var name: String

    /// - Parameter name: The logger name to show in log messages.
    public init(name: String) {
        self.name = name
    }

    /// Reattach to webview so that console output will continue to be forwarded after the webview has been reloaded.
    public func reattach(_ webView: WKWebView) {
        // TODO: this overrides stack traces when looking into console logs via Safari browser.
        // TODO: only "Script error." is printed for unhandled exceptions.
        let js = """
        (function() {
            var injectLogger = function(type) {
                var originalLogger = console[type];
                console[type] = function(msg) {
                    originalLogger.apply(console, arguments);
                    if (msg == null) msg = "";
                    window.webkit.messageHandlers.itmLogger.postMessage({ "type" : type, "msg" : msg });
                };
            };

            injectLogger("error");
            injectLogger("warn");
            injectLogger("info");
            injectLogger("log");
            injectLogger("trace");

            var originalAssert = console.assert;
            console.assert = function(expr, msg) {
                originalAssert.apply(console, arguments);
                if (expr) return;
                if (msg == null) msg = "";
                window.webkit.messageHandlers.itmLogger.postMessage({ "type" : "assert", "msg" : "Assertion Failed: " + msg });
            }

            window.addEventListener("error", function (e) {
                window.webkit.messageHandlers.itmLogger.postMessage({ "type" : "error", "msg" : e.message });
                return false;
            });
        })();
        true;
        """

        webView.evaluateJavaScript(js) { [self] value, error in
            if error == nil {
                return
            }
            log("error", "ITMWebViewLogger: failed to init: \(error!)")
        }
    }

    /// Attach this ``ITMWebViewLogger`` to the given `WKWebView`.
    public func attach(_ webView: WKWebView) {
        webView.configuration.userContentController.add(ITMWeakScriptMessageHandler(self), name: "itmLogger")
        reattach(webView)
    }

    /// `WKScriptMessageHandler` delegate function.
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String] else {
            log("error", "ITMWebViewLogger: bad message format")
            return
        }
        let type = body["type"]
        let logMessage = "JS - \(name): \(body["msg"]!)"

        log(type, logMessage)
    }

    /// Log the given message using `ITMApplication.logger`.
    ///
    /// Override this function in a subclass in order to add custom behavior.
    /// - Parameters:
    ///   - severity: The log severity string. Must be a value from ``ITMLogger.Severity``.
    ///   - logMessage: The message to log.
    open func log(_ severity: String?, _ logMessage: String) {
        ITMApplication.logger.log(ITMLogger.Severity(severity), logMessage)
    }
}
