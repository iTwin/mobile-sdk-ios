//---------------------------------------------------------------------------------------
//
//     $Source: FieldiOS/App/Utils/ITMApplication.swift $
//
//  $Copyright: (c) 2021 Bentley Systems, Incorporated. All rights reserved. $
//
//---------------------------------------------------------------------------------------

import PromiseKit
import WebKit

open class ITMApplication: NSObject, WKUIDelegate, WKNavigationDelegate {
    public let webView: WKWebView
    public let webViewLogger: ITMWebViewLogger
    public let wmuMessenger: ITMMessenger
    public var fullyLoaded = false
    public var dormant = true
    private var queryHandlers: [ITMQueryHandler] = []
    private var reachabilityObserver: Any?
    public static var logger = ITMLogger()

    override public init() {
        webView = type(of: self).createEmptyWebView()
        webViewLogger = type(of: self).createWebViewLogger(webView)
        wmuMessenger = type(of: self).createITMMessenger(webView)
        super.init()
    }

    deinit {
        for queryHandler in queryHandlers {
            wmuMessenger.unregisterQueryHandler(queryHandler)
        }
        queryHandlers.removeAll()
        if reachabilityObserver != nil {
            NotificationCenter.default.removeObserver(reachabilityObserver!)
        }
    }

    public class func createEmptyWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let path = getFrontendIndexPath()
        let frontendFolder = path.deletingLastPathComponent()
        let handler = createAssetHandler(assetPath: frontendFolder.absoluteString)
        configuration.setURLSchemeHandler(handler, forURLScheme: "imodeljs")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.isScrollEnabled = false

        return webView
    }

    public class func createAssetHandler(assetPath: String) -> WKURLSchemeHandler {
        return ITMAssetHandler(assetPath: assetPath)
    }

    public class func createITMMessenger(_ webView: WKWebView) -> ITMMessenger {
        return ITMMessenger(webView)
    }

    public class func createWebViewLogger(_ webView: WKWebView) -> ITMWebViewLogger {
        let webViewLogger = ITMWebViewLogger(name: "ITMApplication")
        webViewLogger.attach(webView)
        return webViewLogger
    }

    public func registerQueryHandler<T, U>(_ type: String, _ handler: @escaping (T) -> Promise<U>) {
        let queryHandler = wmuMessenger.registerQueryHandler(type, handler)
        queryHandlers.append(queryHandler)
    }

    public func updateReachability() {
        // NOTE: In addition to setting a variable, in the future we might want to
        // send a message that can trigger an event that our TS code can listen for.
        let js = "window.Bentley_InternetReachabilityStatus = \(ITMInternetReachability.shared.currentReachabilityStatus().rawValue)"
        wmuMessenger.evaluateJavaScript(js)
    }

    public class func getFrontendIndexPath() -> URL {
        return URL(string: "ITMApplication/frontend/index.html")!
    }

    public func getBackendUrl() -> URL {
        return Bundle.main.url(forResource: "main", withExtension: "js", subdirectory: "ITMApplication/backend")!
    }

    public func getBaseUrl() -> String {
        return "imodeljs://app/index.html"
    }

    public func getUrlHashParams() -> String {
        return ""
    }

    public func getAuthClient() -> AuthorizationClient? {
        return nil
    }

    public func loadBackend(_ allowInspectBackend: Bool) {
        let backendUrl = getBackendUrl()

        IModelJsHost.sharedInstance().loadBackend(
            backendUrl,
            withAuthClient: getAuthClient(),
            withInspect: allowInspectBackend
        )
        IModelJsHost.sharedInstance().register(webView)
    }

    public func getUserAgentSuffix() -> String {
        return ""
    }

    public func loadFrontend() {
        var url = getBaseUrl()
        url += "#port=\(IModelJsHost.sharedInstance().getPort())"
        url += "&platform=ios"
        url += getUrlHashParams()
        let request = URLRequest(url: URL(string: url)!)
        // NOTE: the below runs before the webView's main page has been loaded, and
        // we wait for the execution to complete before loading the main page. So we
        // can't use wkMessageSender.evaluateJavaScript here, even though we use it
        // everywhere else in this file.
        webView.evaluateJavaScript("navigator.userAgent") { [weak webView = self.webView] result, error in
            if let webView = webView {
                if let userAgent = result as? String {
                    var customUserAgent: String
                    if userAgent.contains("Mobile") {
                        // The userAgent in the webView starts out as a mobile userAgent, and
                        // then subsequently changes to a Mac desktop userAgent. If we set
                        // customUserAgent to the original mobile one, all will be fine.
                        customUserAgent = userAgent
                    } else {
                        // If in the future the webView starts out with a Mac desktop userAgent,
                        // append /Mobile to the end so that UIFramework.isMobile() will work.
                        customUserAgent = userAgent + " Mobile"
                    }
                    customUserAgent += self.getUserAgentSuffix()
                    webView.customUserAgent = customUserAgent
                }
                webView.load(request)
                self.reachabilityObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.reachabilityChanged, object: nil, queue: nil, using: { _ in
                    self.updateReachability()
                })
            }
        }
    }

    // MARK: - ITMApplication (WebView) presentation

    // Top View for presenting application in dormant state.
    // Always add dormant application to topViewController's view
    // to ensure it appears in presented view hierarchy
    public static var topView: UIView? {
        guard let topViewController = self.topViewController else { return nil }
        return topViewController.view
    }

    public static var topViewController: UIViewController? {
        if var topController = UIApplication.shared.keyWindow?.rootViewController {
            while let presentedViewController = topController.presentedViewController {
                topController = presentedViewController
            }
            return topController
        }
        return nil
    }

    // If the view is valid, application is added in active state.
    // If the view is nil, appliation is added in dormant state
    public func addApplicationToView(_ view: UIView?) {
        guard let parentView = view ?? ITMApplication.topView else {
            return
        }
        dormant = view == nil ? true : false

        let att: [NSLayoutConstraint.Attribute] = dormant ?
            [.leadingMargin, .topMargin, .trailingMargin, .bottomMargin] :
            [.leading, .top, .trailing, .bottom]

        parentView.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        parentView.addConstraint(NSLayoutConstraint(item: webView, attribute: .leading, relatedBy: .equal, toItem: parentView, attribute: att[0], multiplier: 1, constant: 0))
        parentView.addConstraint(NSLayoutConstraint(item: webView, attribute: .top, relatedBy: .equal, toItem: parentView, attribute: att[1], multiplier: 1, constant: 0))
        parentView.addConstraint(NSLayoutConstraint(item: webView, attribute: .trailing, relatedBy: .equal, toItem: parentView, attribute: att[2], multiplier: 1, constant: 0))
        parentView.addConstraint(NSLayoutConstraint(item: webView, attribute: .bottom, relatedBy: .equal, toItem: parentView, attribute: att[3], multiplier: 1, constant: 0))

        if dormant {
            parentView.sendSubviewToBack(webView)
            webView.isHidden = true
        } else {
            parentView.bringSubviewToFront(webView)
            // Note: even though we stay hidden if not fully loaded, we still want the
            // webview to be in the front, because that means we are still in the process
            // of loading, and as soon as the loading completes, the webView will be
            // shown.
            webView.isHidden = !fullyLoaded
        }
    }

    public func presentInView(_ view: UIView) {
        addApplicationToView(view)
    }

    public func presentHidden() {
        addApplicationToView(nil)
    }

    // MARK: - WKUIDelegate Methods

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> ()) {
        let alert = ITMAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            completionHandler()
            ITMAlertController.doneWithAlertWindow()
        }))
        alert.modalPresentationCapturesStatusBarAppearance = true
        ITMAlertController.getAlertVC().present(alert, animated: true, completion: nil)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> ()) {
        let alert = ITMAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            completionHandler(true)
            ITMAlertController.doneWithAlertWindow()
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .default, handler: { _ in
            completionHandler(false)
            ITMAlertController.doneWithAlertWindow()
        }))
        alert.modalPresentationCapturesStatusBarAppearance = true
        ITMAlertController.getAlertVC().present(alert, animated: true, completion: nil)
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> ()) {
        let alert = ITMAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = defaultText
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            if let text = alert.textFields?.first?.text {
                completionHandler(text)
            } else {
                completionHandler(defaultText)
            }
            ITMAlertController.doneWithAlertWindow()
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .default, handler: { _ in
            completionHandler(nil)
            ITMAlertController.doneWithAlertWindow()
        }))
        alert.modalPresentationCapturesStatusBarAppearance = true
        ITMAlertController.getAlertVC().present(alert, animated: true, completion: nil)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // The iModelJs about panel has a link to www.bentley.com with the link target set to "_blank".
        // This requests that the link be opened in a new window. The check below detects this, and
        // then opens the link in the default browser.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            ITMApplication.logger.log(.info, "Opening URL \(url) in Safari.")
            UIApplication.shared.open(url)
        }
        // The iModelJs PropertyGridCommons._handleLinkClick code doesn't check if the window.open
        // returns null, so this works around it by aways returning a web view. The code should definitely
        // be fixed as it's doing the following:
        //   window.open(foundLink.url, "_blank")!.focus();
        return WKWebView(frame: webView.frame, configuration: configuration)
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // There is an apparent bug in WKWebView when running in landscape mode on a
        // phone with a notch. In that case, the html page content doesn't go all the
        // way across the screen.
        webView.setNeedsLayout()
        fullyLoaded = true
        if !dormant {
            webView.isHidden = false
        }
        updateReachability()
        wmuMessenger.evaluateJavaScript("window.Bentley_FinishLaunching()")
    }
}
