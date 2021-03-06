/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import WebKit

/// Convenience UIViewController that shows a `WKWebView` with an ITwin Mobile frontend running inside it.
open class ITMViewController: UIViewController {
    /// The ``ITMApplication`` used by this view controller. You **must** set this value before using this view controller.
    /// - Note: This will often be set to an application-specific subclass of ``ITMApplication``
    public static var application: ITMApplication!
    /// Whether or not to automatically load the web application the first time the view loads.
    public static var autoLoadWebApplication = true
    /// Whether or not to delay loading the web application the first time the view loads.
    public static var delayedAutoLoad = false
    public private(set) var itmNativeUI: ITMNativeUI?
    private var loadedOnce = false
    private var willEnterForegroundObserver: Any? = nil
    private static var activeVC: ITMViewController?

    deinit {
        removeWillEnterForegroundObserver()
    }
    
    private func removeWillEnterForegroundObserver() {
        if let willEnterForegroundObserver = willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(willEnterForegroundObserver)
        }
    }

    /// Creates an ``ITMNativeUI`` and attaches it to this view controller and the `application`'s `itmMessenger`.
    open override func viewWillAppear(_ animated: Bool) {
        itmNativeUI = ITMNativeUI(viewController: self, itmMessenger: ITMViewController.application.itmMessenger)
        ITMViewController.application.viewWillAppear(viewController: self)
        super.viewWillAppear(animated)
    }

    /// Detaches and clears this view controller's ``ITMNativeUI``.
    open override func viewWillDisappear(_ animated: Bool) {
        itmNativeUI?.detach()
        itmNativeUI = nil
        super.viewWillDisappear(animated)
    }

    /// Attaches the `application`'s webView as this view controller's view.
    open override func loadView() {
        // If you close an ITMViewController and then later create a new one, the old one continues
        // to reference ITMViewController.application.webView. This throws an exception, which normally
        // crashes the app. Each time an ITMViewController is connected to
        // ITMViewController.application.webView, store that view controller in the activeVC static
        // member variable. Then, before attaching a webView to this view controller, make sure that
        // it's not attached to the old one.
        if let activeVC = ITMViewController.activeVC {
            activeVC.view = UIView()
        }
        ITMViewController.activeVC = self
        let webView = ITMViewController.application.webView
        view = webView
    }

    /// Call to load the backend and frontend of the iTwin Mobile app. Repeat calls are ignored.
    public func loadWebApplication() {
        if !self.loadedOnce {
            ITMViewController.application.loadBackend(true)
            ITMViewController.application.loadFrontend();
            self.loadedOnce = true
        }
    }

    /// Loads the iTwin Mobile app if ``autoLoadWebApplication`` is true.
    open override func viewDidLoad() {
        if ITMViewController.autoLoadWebApplication {
            if ITMViewController.delayedAutoLoad {
                willEnterForegroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                    self?.loadWebApplication()
                    self?.removeWillEnterForegroundObserver()
                }
            } else {
                loadWebApplication()
            }
        }
        super.viewDidLoad()
    }
}
