//---------------------------------------------------------------------------------------
//
//     $Source: FieldiOS/App/Utils/ITMWebViewLogger.swift $
//
//  $Copyright: (c) 2021 Bentley Systems, Incorporated. All rights reserved. $
//
//---------------------------------------------------------------------------------------

import WebKit

open class ITMWebViewLogger: NSObject, WKScriptMessageHandler {
    private let name: String

    public init(name: String) {
        self.name = name
    }

    /// Reattach to webview so that console output will continue to be forwarded after the webview has been reloaded.
    func reattach(_ webView: WKWebView) {
        // TODO: this overrides stack traces when looking into console logs via Safari browser.
        // TODO: only "Script error." is printed for unhandled exceptions.
        let js = """
        (function() {
            var injectLogger = function(type) {
                var originalLogger = console[type];
                console[type] = function(msg) {
                    originalLogger.apply(console, arguments);
                    if (msg == null) msg = "";
                    window.webkit.messageHandlers.wmuLogger.postMessage({ "type" : type, "msg" : msg });
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
                window.webkit.messageHandlers.wmuLogger.postMessage({ "type" : "assert", "msg" : "Assertion Failed: " + msg });
            }

            window.addEventListener("error", function (e) {
                window.webkit.messageHandlers.wmuLogger.postMessage({ "type" : "error", "msg" : e.message });
                return false;
            });
        })();
        true;
        """

        webView.evaluateJavaScript(js, completionHandler: { value, error in
            if error == nil {
                return
            }
            self.log("error", "ITMWebViewLogger: failed to init: \(error!)")
        })
    }

    /// Forward JavaScript console output to NSLog. Can be called on any new web view after creation.
    public func attach(_ webView: WKWebView) {
        webView.configuration.userContentController.add(self, name: "wmuLogger")
        reattach(webView)
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String] else {
            log("error", "ITMWebViewLogger: bad message format")
            return
        }
        let type = body["type"]
        let logMessage = "JS - \(name): \(body["msg"]!)"

        log(type, logMessage)
    }

    func log(_ severity: String?, _ logMessage: String) {
        ITMApplication.logger.log(ITMLogger.Severity(severity), logMessage)
    }
}
