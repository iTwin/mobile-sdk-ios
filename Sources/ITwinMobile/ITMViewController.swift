/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import WebKit

/// Convenience UIViewController that shows a `WKWebView` with an ITwin Mobile frontend running inside it.
open class ITMViewController: UIViewController {
    /// The ``ITMApplication`` used by this view controller. You __must__ set this value before using this view controller.
    /// - Note: This will often be set to an application-specific subclass of ``ITMApplication``
    public static var application: ITMApplication!
    /// Whether or not to automatically load the web application the first time the view loads.
    public static var autoLoadWebApplication = true
    /// Whether or not to delay loading the web application the first time the view loads.
    public static var delayedAutoLoad = false
    /// Whether or not a Chrome debugger can be attached to the backend.
    /// - Note: You should almost certainly never set this to true in production app builds.
    public static var allowInspectBackend = false
    /// The ``ITMNativeUI`` that this view controller communicates with.
    /// - SeeAlso: ``viewWillAppear(_:)``
    public private(set) var itmNativeUI: ITMNativeUI?
    private var loadedOnce = false
    private var observers: ITMObservers? = ITMObservers()
    private static var activeVC: ITMViewController?

    private func clearObservers() {
        observers = nil
    }

    /// Initializes ``itmNativeUI`` and attaches it to this view controller and the `application`'s `itmMessenger`.
    /// - Note: This calls ``application``'s `viewWillAppear` function. If you have custom ``ITMNativeUIComponent``
    /// types, you will usually override `viewWillAppear` in a custom ``ITMApplication`` subclass instead of creating a custom
    /// ``ITMViewController`` subclass.
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

    /// Attaches ``application``'s webView as this view controller's view.
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
        view = ITMViewController.application.webView
    }

    /// Call to load the backend and frontend of the iTwin Mobile app. Repeat calls are ignored.
    public func loadWebApplication() {
        if !loadedOnce {
            ITMViewController.application.loadBackend(ITMViewController.allowInspectBackend)
            ITMViewController.application.loadFrontend()
            loadedOnce = true
        }
    }

    /// Loads the iTwin Mobile app if ``autoLoadWebApplication`` is true.
    /// - Note: If ``delayedAutoLoad`` is true, this delays the load until `UIApplication.willEnterForegroundNotification`
    /// is received.
    open override func viewDidLoad() {
        if ITMViewController.autoLoadWebApplication {
            if ITMViewController.delayedAutoLoad {
                observers?.addObserver(forName: UIApplication.willEnterForegroundNotification) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.loadWebApplication()
                        self?.clearObservers()
                    }
                }
            } else {
                loadWebApplication()
            }
        }
        super.viewDidLoad()
    }
}
