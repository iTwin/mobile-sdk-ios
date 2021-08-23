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
    public static var applicationType = ITMApplication.self
    public static var autoLoadWebApplication = true
    public static var delayedAutoLoad = false
    public let application: ITMApplication
    private var iTwinMobile: ITwinMobile?
    private var loadedOnce = false
    private var willEnterForegroundObserver: Any? = nil

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        application = ITMViewController.applicationType.init()
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    required public init?(coder: NSCoder) {
        application = ITMViewController.applicationType.init()
        super.init(coder: coder)
    }
    
    deinit {
        if let willEnterForegroundObserver = willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(willEnterForegroundObserver)
        }
    }

    open override func viewWillAppear(_ animated: Bool) {
        iTwinMobile = ITwinMobile(viewController: self, itmMessenger: application.itmMessenger)
        super.viewWillAppear(animated)
    }

    open override func viewWillDisappear(_ animated: Bool) {
        iTwinMobile?.detach()
        iTwinMobile = nil
        super.viewWillDisappear(animated)
    }

    open override func loadView() {
        let webView = application.webView
        view = webView
    }

    public func loadWebApplication() {
        if !self.loadedOnce {
            self.application.loadBackend(true)
            // Due to a bug in iModelJS, loadFrontend must be executed after the initial willEnterForegroundNotification.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                self.application.loadFrontend();
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
