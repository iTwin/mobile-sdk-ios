/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import IModelJsNative
import PromiseKit
import WebKit

// MARK: - JSON convenience
/// Convenience type alias for a dictionary intended for interop via JSON.
public typealias JSON = [String: Any]

/// Extension to create a dictionary from JSON text.
public extension JSON {
    /// Deserializes passed String and returns Dictionary representing the JSON object encoded in the string
    /// - Parameters:
    ///   - jsonString: string to parse and convert to Dictionary
    ///   - encoding: encoding of the source `jsonString`. Defaults to UTF8.
    /// - Returns: Dictionary representation of the JSON string
    static func fromString(_ jsonString: String?, _ encoding: String.Encoding = String.Encoding.utf8) -> JSON? {
        if jsonString == nil {
            return nil
        }
        let stringData = jsonString!.data(using: encoding)
        do {
            return try JSONSerialization.jsonObject(with: stringData!, options: []) as? JSON
        } catch {
            ITMApplication.logger.log(.error, error.localizedDescription)
        }
        return nil
    }
    
    /// Check if a key's value equals "YES"
    /// - Parameter key: The key to check.
    /// - Returns: True if the value of the given key equals "YES".
    func isYes(_ key: String) -> Bool {
        return self[key] as? String == "YES"
    }
}

/// Main class for interacting with one iTwin Mobile web app.
/// - Note: Most applications will override this class in order to customize the behavior and register for messages.
open class ITMApplication: NSObject, WKUIDelegate, WKNavigationDelegate {
    /// The `MobileUi.preferredColorScheme` value set by the TypeScript code.
    public enum PreferredColorScheme: Int, Codable, Equatable {
        case automatic = 0
        case light = 1
        case dark = 2
    }

    /// Struct used to store a hash parameter.
    public struct HashParam {
        /// The name of the hash parameter.
        public let name: String
        /// The value of the hash parameter.
        public let value: String
        /// Creates a hash parameter with the given name and value
        /// - Parameters:
        ///   - name: The name of the hash parameter.
        ///   - value: The value of the hash parameter.
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
        /// Creates a hash parameter with the given name and boolean value.
        /// - Parameters:
        ///   - name: The name of the hash parameter.
        ///   - value: The boolean value of the hash parameter: true converts to "YES" and false converts to "NO"
        public init(name: String, value: Bool) {
            self.name = name
            self.value = value ? "YES" : "NO"
        }
    }

    /// Type used to store an array of hash parameters.
    public typealias HashParams = [HashParam]
    
    /// The `WKWebView` that the web app runs in.
    public let webView: WKWebView
    /// The ``ITMWebViewLogger`` for JavaScript console output.
    public let webViewLogger: ITMWebViewLogger
    /// The ``ITMMessenger`` for communication between native code and JavaScript code (and vice versa).
    public let itmMessenger: ITMMessenger
    /// Tracks whether the initial page has been loaded in the web view.
    public var fullyLoaded = false
    /// Tracks whether the web view should be visible in the application, or kept hidden. (Once the web view has been created
    /// it cannot be destroyed. It must instead be hidden.)
    public var dormant = true
    /// Tracks whether the fronend URL is on a remote server (used for debugging via react-scripts).
    public var usingRemoteServer = false
    private var queryHandlers: [ITMQueryHandler] = []
    private var reachabilityObserver: Any?
    /// The ``ITMLogger`` responsible for handling log messages (both from native code and JavaScript code). The default logger
    /// uses `NSLog` for the messages. Replace this object with an ``ITMLogger`` subclass to change the logging behavior.
    public static var logger = ITMLogger()
    
    /// The ``ITMGeolocationManager`` handling the application's geo-location requests.
    public let geolocationManager: ITMGeolocationManager
    /// The `AuthorizationClient` used by the `IModelJsHost`. This must be an ``ITMAuthorizationClient`` in order to
    /// use the `ITMAuthorizationClient` TypeScript class.
    public var authorizationClient: AuthorizationClient?
    
    /// A DispatchGroup that is busy until the backend is finished loading. Use `backendLoadingDispatchGroup.wait()` on a
    /// background `DispatchQueue` to ensure the backend is done loading. Do __not__ do that on the main DispatchQueue, or it
    /// may lead to deadlock. This is done automatically in `loadFrontend`.
    public let backendLoadingDispatchGroup = DispatchGroup()
    private var backendLoaded = false
    /// The MobileUi.preferredColorScheme value set by the TypeScript code, default is automatic.
    static public var preferredColorScheme = PreferredColorScheme.automatic

    private var keyboardObservers: [Any] = []
    private var keyboardNotifications = [
        UIResponder.keyboardWillShowNotification: "Bentley_ITM_keyboardWillShow",
        UIResponder.keyboardDidShowNotification: "Bentley_ITM_keyboardDidShow",
        UIResponder.keyboardWillHideNotification: "Bentley_ITM_keyboardWillHide",
        UIResponder.keyboardDidHideNotification: "Bentley_ITM_keyboardDidHide"
    ]
    /// The app config JSON from the main bundle.
    public var configData: JSON?
    
    /// Creates an ``ITMApplication``
    required public override init() {
        webView = type(of: self).createEmptyWebView()
        webViewLogger = type(of: self).createWebViewLogger(webView)
        itmMessenger = type(of: self).createITMMessenger(webView)
        geolocationManager = ITMGeolocationManager(itmMessenger: itmMessenger, webView: webView)
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
        backendLoadingDispatchGroup.enter()
        registerQueryHandler("Bentley_ITM_updatePreferredColorScheme") { (params: [String: Any]) -> Promise<()> in
            if let preferredColorScheme = params["preferredColorScheme"] as? Int {
                ITMApplication.preferredColorScheme = PreferredColorScheme(rawValue: preferredColorScheme) ?? .automatic
            }
            return Promise.value(())
        }
        configData = loadITMAppConfig()
        if let configData = configData {
            extractConfigDataToEnv(configData: configData)
            if configData.isYes("ITMAPPLICATION_MESSAGE_LOGGING") {
                ITMMessenger.isLoggingEnabled = true
            }
            if configData.isYes("ITMAPPLICATION_FULL_MESSAGE_LOGGING") {
                ITMMessenger.isLoggingEnabled = true
                ITMMessenger.isFullLoggingEnabled = true
            }
        }
    }

    deinit {
        for queryHandler in queryHandlers {
            itmMessenger.unregisterQueryHandler(queryHandler)
        }
        queryHandlers.removeAll()
        if reachabilityObserver != nil {
            NotificationCenter.default.removeObserver(reachabilityObserver!)
        }
    }

    open func viewWillAppear(viewController: ITMViewController) {
        for (key, value) in keyboardNotifications {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: key, object: nil, queue: nil, using: { [weak self] notification in
                if let messenger = self?.itmMessenger,
                   let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
                   let keyboardSize = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
                    messenger.queryAndShowError(viewController, value, [
                        "duration": duration,
                        "height": keyboardSize.size.height
                    ])
                }
            }))
        }
    }
    
    /// Creates an empty `WKWebView` and configures it to run an iTwin Mobile web app. The web view starts out hidden.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Returns: A `WKWebView` configured for use by iTwin Mobile.
    open class func createEmptyWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let path = getFrontendIndexPath()
        let frontendFolder = path.deletingLastPathComponent()
        let handler = createAssetHandler(assetPath: frontendFolder.absoluteString)
        configuration.setURLSchemeHandler(handler, forURLScheme: "imodeljs")
        updateWebViewConfiguration(configuration)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.isScrollEnabled = false

        return webView
    }
    
    /// Override this to update the `WKWebViewConfiguration` used for the web view before the web view is created.
    ///
    /// An example use for this would be to add a custom URL scheme handler, which must be done before the web view is created.
    /// - Parameter configuration: The `WKWebViewConfiguration` object that will be used to create the web view.
    open class func updateWebViewConfiguration(_ configuration: WKWebViewConfiguration) {}

    /// Creates a `WKURLSchemeHandler` for use with an iTwin Mobile web app.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Returns: An ``ITMAssetHandler`` object that properly loads appropriate files.
    open class func createAssetHandler(assetPath: String) -> WKURLSchemeHandler {
        return ITMAssetHandler(assetPath: assetPath)
    }

    /// Creates an ``ITMMessenger`` for use with an iTwin Mobile web app.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Parameter webView: The `WKWebView` to which to attach the ``ITMMessenger``.
    /// - Returns: An ``ITMMessenger`` object attached to `webView`.
    open class func createITMMessenger(_ webView: WKWebView) -> ITMMessenger {
        return ITMMessenger(webView)
    }

    /// Creates an ``ITMWebViewLogger`` for use with an iTwin Mobile web app.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Parameter webView: The `WKWebView` to which to attach the ``ITMWebViewLogger``.
    /// - Returns: An ``ITMWebViewLogger`` object attached to `webView`.
    open class func createWebViewLogger(_ webView: WKWebView) -> ITMWebViewLogger {
        let webViewLogger = ITMWebViewLogger(name: "ITMApplication Logger")
        return webViewLogger
    }

    /// Registers a handler for the given query from the web view.
    /// You can use `unregisterQueryHandler` to unregister this at any time. Otherwise, it will be automatically unregistered when
    /// this ``ITMApplication`` is destroyed.
    /// - Parameters:
    ///   - type: The query type used by the JavaScript code to perform the query.
    ///   - handler: The handler for the query.
    public func registerQueryHandler<T, U>(_ type: String, _ handler: @escaping (T) -> Promise<U>) {
        let queryHandler = itmMessenger.registerQueryHandler(type, handler)
        queryHandlers.append(queryHandler)
    }

    /// Unregisters a handler for the given query from the web view.
    /// - Note: This can only be used to unregister a handler that was previously registered using `registerQueryHandler`.
    /// - Parameter type: The type used when the query was registered.
    /// - Returns: true if the given query was previously registered (and thus unregistered here), or false otherwise.
    public func unregisterQueryHandler(_ type: String) -> Bool {
        for i in 0..<queryHandlers.count {
            let queryHandler = queryHandlers[i]
            if queryHandler.getQueryType() == type {
                itmMessenger.unregisterQueryHandler(queryHandler)
                queryHandlers.remove(at: i)
                return true
            }
        }
        return false
    }

    /// Updates the reachability status in the web view. This is called automatically any time the reachability status changes.
    /// - Note: You should not ever need to call this.
    public func updateReachability() {
        // NOTE: In addition to setting a variable, in the future we might want to
        // send a message that can trigger an event that our TS code can listen for.
        let js = "window.Bentley_InternetReachabilityStatus = \(ITMInternetReachability.shared.currentReachabilityStatus().rawValue)"
        itmMessenger.evaluateJavaScript(js)
    }

    /// Gets the directory name used for the iTwin Mobile web app.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Returns: The name of the directory in the main bundle that contains the iTwin Mobile web app.
    open class func getWebAppDir() -> String {
        return "ITMApplication"
    }

    /// Gets the relative path inside the main bundle to the index.html file for the frontend of the iTwin Mobile web app.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Returns: The relative path inside the main bundle to the index.html file for the frontend of the iTwin Mobile web app.
    open class func getFrontendIndexPath() -> URL {
        return URL(string: "\(getWebAppDir())/frontend/index.html")!
    }

    /// Gets the file URL to the main.js file for the iTwin Mobile web app's backend.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Returns: A file URL to the main.js file for the iTwin Mobile web app's backend.
    open func getBackendUrl() -> URL {
        return Bundle.main.url(forResource: "main", withExtension: "js", subdirectory: "\(type(of: self).getWebAppDir())/backend")!
    }

    /// Gets the base URL string for the frontend. `loadFrontend` will automatically add necessary hash parameters to this URL string.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Returns: The base URL string for the frontend.
    open func getBaseUrl() -> String {
        if let configData = configData,
            let baseUrlString = configData["ITMAPPLICATION_BASE_URL"] as? String {
            usingRemoteServer = true
            return baseUrlString
        }
        usingRemoteServer = false
        return "imodeljs://app/index.html"
    }

    /// Gets custom URL hash parameters to be passed when loading the frontend.
    /// Override this function in a subclass in order to add custom behavior.
    ///
    /// - Note: The default implementation returns hash parameters that are required in order for the TypeScript
    /// code to work. You must include those values if you override this function to return other values.
    /// - Returns: Empty string.
    open func getUrlHashParams() -> HashParams {
        return [
            HashParam(name: "port", value: "\(IModelJsHost.sharedInstance().getPort())"),
            HashParam(name: "platform", value: "ios")
        ]
    }

    /// Gets the `AuthorizationClient` to be used for this iTwin Mobile web app.
    /// Override this function in a subclass in order to add custom behavior.
    /// If your application handles authorization on its own, create a class that implements the `AuthorizationClient` protocol
    /// to handle authorization.
    /// - Returns: A `MobileAuthorizationClient` instance from IModelJsNative.
    open func getAuthClient() -> AuthorizationClient? {
        guard let viewController = type(of: self).topViewController else {
            return nil
        }
        return ITMAuthorizationClient(itmApplication: self, viewController: viewController)
    }

    /// Loads the app config JSON from the main bundle.
    /// Override this function in a subclass in order to add custom behavior.
    ///
    /// The following keys in the returned value are used by iTwin Mobile SDK:
    /// |Key|Description|
    /// |---|-----------|
    /// | ITMAPPLICATION\_CLIENT\_ID | ITMAuthorizationClient required value containing the app's client ID. |
    /// | ITMAPPLICATION\_SCOPE | ITMAuthorizationClient required value containing the app's scope. |
    /// | ITMAPPLICATION\_ISSUER\_URL | ITMAuthorizationClient optional value containing the app's issuer URL. |
    /// | ITMAPPLICATION\_REDIRECT\_URI | ITMAuthorizationClient optional value containing the app's redirect URL. |
    /// | ITMAPPLICATION\_MESSAGE\_LOGGING | Set to YES to have ITMMessenger log message traffic between JavaScript and Swift. |
    /// | ITMAPPLICATION\_FULL\_MESSAGE\_LOGGING | Set to YES to include full message data in the ITMMessenger message logs. (__Do not use in production.__) |
    /// Note: Other keys may be present but are ignored by iTwin Mobile SDK. For example, the iTwin Mobile SDK sample apps include keys with an `ITMSAMPLE_` prefix.
    /// - Returns: The parsed contents of ITMAppConfig.json in the main bundle in the directory returned by `getWebAppDir`.
    open func loadITMAppConfig() -> JSON? {
        if let configUrl = Bundle.main.url(forResource: "ITMAppConfig", withExtension: "json", subdirectory: type(of: self).getWebAppDir()),
            let configString = try? String(contentsOf: configUrl),
            let configData = JSON.fromString(configString) {
            return configData
        }
        return nil
    }

    /// Extracts config values and stores them in the environment so they can be seen by the backend JavaScript code.
    ///
    /// All top-level keys in configData that have a string value and a key name with the given prefix will be stored in the environment with the given key name and value.
    /// - Parameters:
    ///   - configData: The JSON dictionary containing the configs (by default from ITMAppConfig.json).
    ///   - prefix: The prefix to include values for.
    public func extractConfigDataToEnv(configData: JSON, prefix: String = "ITMAPPLICATION_") {
        for (key, value) in configData {
            if key.hasPrefix(prefix), let stringValue = value as? String {
                setenv(key, stringValue, 1);
            }
        }
    }

    /// Loads the iTwin Mobile web app backend.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Note: This function returns before the loading has completed.
    /// - Parameter allowInspectBackend: Whether or not to all debugging of the backend.
    open func loadBackend(_ allowInspectBackend: Bool) {
        if backendLoaded {
            return
        }
        let backendUrl = getBackendUrl()

        // Allow backend loader to know the full path to the directory containing
        // main.js. Put that into the ITMAPPLICATION_BACKEND_ROOT environment variable so
        // that it is available there.
        let backendDir = backendUrl.deletingLastPathComponent().path
        setenv("ITMAPPLICATION_BACKEND_ROOT", backendDir, 1)

        authorizationClient = getAuthClient()
        IModelJsHost.sharedInstance().loadBackend(
            backendUrl,
            withAuthClient: authorizationClient,
            withInspect: allowInspectBackend
        ) { _ in
            // This callback gets called each time the app returns to the foreground. That is
            // probably a bug in iModelJS, but this check avoids having that cause problems.
            if !self.backendLoaded {
                self.backendLoaded = true
                self.backendLoadingDispatchGroup.leave()
            }
        }
        IModelJsHost.sharedInstance().register(webView)
    }

    /// Suffix to add to the user agent reported by the frontend.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Returns: Empty string.
    open func getUserAgentSuffix() -> String {
        return ""
    }

    /// Loads the iTwin Mobile web app frontend.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Note: This function returns before the loading has completed.
    open func loadFrontend() {
        DispatchQueue(label: "ITM.WaitForBackend", qos: .userInitiated).async {
            // We must wait for the backend to finish loading before loading the frontend.
            // The wait has to happen without blocking the main thread.
            self.backendLoadingDispatchGroup.wait()
            let url = self.getBaseUrl() + self.getUrlHashParams().toString()
            let request = URLRequest(url: URL(string: url)!)
            // The call to evaluateJavaScript must happen in the main thread.
            DispatchQueue.main.async {
                // NOTE: the below runs before the webView's main page has been loaded, and
                // we wait for the execution to complete before loading the main page. So we
                // can't use itmMessenger.evaluateJavaScript here, even though we use it
                // everywhere else in this file.
                self.webView.evaluateJavaScript("navigator.userAgent") { [weak webView = self.webView] result, error in
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
                        if self.usingRemoteServer {
                            _ = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
                                if !self.fullyLoaded {
                                    let alert = UIAlertController(title: "Error", message: "Could not connect to React debug server at URL \(url).", preferredStyle: .alert)
                                    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
                                        ITMAlertController.doneWithAlertWindow()
                                    }))
                                    alert.modalPresentationCapturesStatusBarAppearance = true
                                    type(of: self).topViewController?.present(alert, animated: true, completion: nil)
                                }
                            }
                        }
                        self.reachabilityObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.reachabilityChanged, object: nil, queue: nil) { [weak self] _ in
                            self?.updateReachability()
                        }
                    }
                }
            }
        }
    }

    // MARK: - ITMApplication (WebView) presentation

    /// Top view for presenting iTwin Mobile web app in dormant state.
    /// Override this function in a subclass in order to add custom behavior.
    /// Always add dormant application to ``topViewController``'s view to ensure it appears in presented view hierarchy
    /// - Returns: The top view.
    public class var topView: UIView? {
        guard let topViewController = self.topViewController else { return nil }
        return topViewController.view
    }

    /// Top view controller for presenting iTwin Mobile web app.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Returns: The top view controller.
    public class var topViewController: UIViewController? {
        let keyWindow = UIApplication
            .shared
            .connectedScenes
            .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
            .first { $0.isKeyWindow }
        if var topController = keyWindow?.rootViewController {
            while let presentedViewController = topController.presentedViewController {
                topController = presentedViewController
            }
            return topController
        }
        return nil
    }

    /// If the view is valid, iTwin Mobile app is added in active state.
    /// If the view is nil, iTwin Mobile app is hidden and set as dormant.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Parameter view: View to which to add the iTwin Mobile app, or nil to hid the iTwin Mobile app.
    open func addApplicationToView(_ view: UIView?) {
        guard let parentView = view ?? type(of: self).topView else {
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

    /// Present the iTwin Mobile app in the given view, filling it completely.
    /// Override this function in a subclass in order to add custom behavior.
    /// - Parameter view: View in which to present the iTiwn Mobile app.
    open func presentInView(_ view: UIView) {
        addApplicationToView(view)
    }

    /// Hide the iTwin Mobile app and set it as dormant.
    /// Override this function in a subclass in order to add custom behavior.
    open func presentHidden() {
        addApplicationToView(nil)
    }

    // MARK: - WKUIDelegate Methods

    /// See `WKUIDelegate` documentation.
    /// Override this function in a subclass in order to add custom behavior.
    open func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> ()) {
        let alert = ITMAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            completionHandler()
            ITMAlertController.doneWithAlertWindow()
        }))
        alert.modalPresentationCapturesStatusBarAppearance = true
        ITMAlertController.getAlertVC().present(alert, animated: true, completion: nil)
    }

    /// See `WKUIDelegate` documentation.
    /// Override this function in a subclass in order to add custom behavior.
    open func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> ()) {
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

    /// See `WKUIDelegate` documentation.
    /// Override this function in a subclass in order to add custom behavior.
    open func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> ()) {
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

    /// Open the URL for the given navigation action.
    /// If the navigation action's `targetFrame` is nil, open the URL using iOS default behavior (opens it in Safari).
    /// If the navigation action's `targetFrame` is not nil, return an unattached WKWebView (which prevents a crash). In
    /// this case, the URL is not opened anywhere.
    /// Override this function in a subclass in order to add custom behavior.
    open func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
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

    /// Handle necessary actions after the frontend web page is loaded (or reloaded).
    /// See `WKNavigationDelegate` documentation.
    /// Override this function in a subclass in order to add custom behavior.
    open func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // There is an apparent bug in WKWebView when running in landscape mode on a
        // phone with a notch. In that case, the html page content doesn't go all the
        // way across the screen.
        webView.setNeedsLayout()
        if fullyLoaded {
            // Reattach our webViewLogger.
            webViewLogger.reattach(webView)
        } else {
            // Attach our webViewLogger.
            webViewLogger.attach(webView)
        }
        fullyLoaded = true
        if !dormant {
            webView.isHidden = false
        }
        updateReachability()
        itmMessenger.evaluateJavaScript("window.Bentley_FinishLaunching()")
    }
}

/// Extension allowing a ``ITMApplication.HashParams`` to be converted into a string.
public extension ITMApplication.HashParams {
    /// Converts the receiver into a URL hash string, encoding values so that they are valid for use in a URL.
    /// - Returns: The hash parameters converted to a URL hash string.
    func toString() -> String {
        if self.count == 0 {
            return ""
        }
        // Note: URL strings probably allow other characters, but we know for sure that these all work.
        // Also, we can't use `CharacterSet.alphanumerics` as a base, because that includes all Unicode
        // upper case and lower case letters, and we only want ASCII upper case and lower case letters.
        // Similarly, `CharacterSet.decimalDigits` includes the Unicode category Number, Decimal Digit,
        // which contains 660 characters.
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        let encoded = self.map { "\($0.name)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowedCharacters)!)" }
        return "#" + encoded.joined(separator: "&")
    }
}
