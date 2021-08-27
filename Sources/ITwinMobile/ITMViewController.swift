//---------------------------------------------------------------------------------------
//
//     $Source: $
//
//  $Copyright: (c) 2021 Bentley Systems, Incorporated. All rights reserved. $
//
//---------------------------------------------------------------------------------------

import UIKit
import WebKit

open class ITMViewController: UIViewController {
    public static var application: ITMApplication!
    public static var autoLoadWebApplication = true
    public static var delayedAutoLoad = false
    private var itmNativeUI: ITMNativeUI?
    private var loadedOnce = false
    private var willEnterForegroundObserver: Any? = nil

    deinit {
        if let willEnterForegroundObserver = willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(willEnterForegroundObserver)
        }
    }

    open override func viewWillAppear(_ animated: Bool) {
        itmNativeUI = ITMNativeUI(viewController: self, itmMessenger: ITMViewController.application.itmMessenger)
        super.viewWillAppear(animated)
    }

    open override func viewWillDisappear(_ animated: Bool) {
        itmNativeUI?.detach()
        itmNativeUI = nil
        super.viewWillDisappear(animated)
    }

    open override func loadView() {
        let webView = ITMViewController.application.webView
        view = webView
    }

    public func loadWebApplication() {
        if !self.loadedOnce {
            ITMViewController.application.loadBackend(true)
            // Due to a bug in iModelJS, loadFrontend must be executed after the initial willEnterForegroundNotification.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                ITMViewController.application.loadFrontend();
            }
            self.loadedOnce = true
        }
    }
    
    open override func viewDidLoad() {
        if ITMViewController.autoLoadWebApplication {
            if ITMViewController.delayedAutoLoad {
                willEnterForegroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
                    self.loadWebApplication()
                }
            } else {
                loadWebApplication()
            }
        }
        super.viewDidLoad()
    }
}
