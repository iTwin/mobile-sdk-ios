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
    let application: ITMApplication
    private var iTwinMobile: ITwinMobile?
    private var loadedOnce = false
    private var willEnterForegroundObserver: Any? = nil

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        application = type(of: self).createApplication()
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    required public init?(coder: NSCoder) {
        application = type(of: self).createApplication()
        super.init(coder: coder)
    }

    deinit {
        if let willEnterForegroundObserver = willEnterForegroundObserver {
            NotificationCenter.default.removeObserver(willEnterForegroundObserver)
        }
    }

    open class func createApplication() -> ITMApplication {
        return ITMApplication()
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

    open override func viewDidLoad() {
        willEnterForegroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            if !self.loadedOnce {
                self.application.loadBackend(true)
                // Due to a bug in iModelJS, loadFrontend must be executed after the initial willEnterForegroundNotification.
                Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                    self.application.loadFrontend();
                }
                self.loadedOnce = true
            }
        }
        super.viewDidLoad()
        let webView = application.webView
        view = webView
    }
}
