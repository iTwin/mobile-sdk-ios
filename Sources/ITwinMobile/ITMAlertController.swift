/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit

class ITMErrorViewController: UIViewController {
    public static var statusBarStyle: UIStatusBarStyle = .default
    public static var statusBarHidden = false

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return ITMErrorViewController.statusBarStyle
    }

    override var prefersStatusBarHidden: Bool {
        return ITMErrorViewController.statusBarHidden
    }
}

/// `UIAlertController` subclass that hides the status bar and presents on top of everything else.
open class ITMAlertController: UIAlertController {
    var onClose: (() -> Void)?
    var rootBounds: CGRect?
    var deviceOrientation: UIDeviceOrientation?
    private static var alertWindow: UIWindow?

    /// - Returns: An instance of ``ITMAlertController`` that is properly configured. May return a preexisting instance.
    public static var getAlertVC: () -> UIViewController = {
        // This avoids cases where topmost view controller is dismissed while presenting alert
        // Create temporary window to show alert anywhere and anytime and avoid view hiearchy issues.
        if alertWindow == nil {
            alertWindow = UIWindow(frame: UIScreen.main.bounds)
            if #available(iOS 13.0, *) {
                alertWindow?.overrideUserInterfaceStyle = .light
            }
            alertWindow!.rootViewController = ITMErrorViewController()
            alertWindow!.windowLevel = UIWindow.Level.alert + 1
            ITMAlertController.alertWindow = alertWindow
        }
        if #available(iOS 13.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if scene.activationState == .foregroundActive {
                    alertWindow?.windowScene = (scene as? UIWindowScene)
                }
            }
        }
        alertWindow!.makeKeyAndVisible()
        return alertWindow!.rootViewController!
    }

    @available(iOS 13.0, *)
    /// Override to allow for the app to force light or dark mode.
    public override var overrideUserInterfaceStyle: UIUserInterfaceStyle {
        get {
            switch ITMApplication.preferredColorScheme {
            case .automatic:
                return .unspecified
            case .light:
                return .light
            case .dark:
                return .dark
            }
        }
        set(newValue) {
            super.overrideUserInterfaceStyle = newValue
        }
    }

    /// Call this to indicate that you are done using the ``ITMAlertController``, so that it can clean up.
    public static var doneWithAlertWindow: () -> () = {
        if #available(iOS 13.0, *) {
            alertWindow?.windowScene = nil
        }
        alertWindow = nil
    }

    open override var prefersStatusBarHidden: Bool {
        return true
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        rootBounds = view.window?.rootViewController?.view.bounds
        deviceOrientation = UIDevice.current.orientation
    }
    
    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onClose?()
    }

    open override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        if let deviceOrientation = deviceOrientation, deviceOrientation != UIDevice.current.orientation {
            dismiss(animated: true)
        }
        coordinator.animate(alongsideTransition: nil) { _ in
            if let rootBounds = self.rootBounds, let deviceOrientation = self.deviceOrientation {
                if rootBounds != self.view.window?.rootViewController?.view.bounds || deviceOrientation != UIDevice.current.orientation {
                    self.dismiss(animated: true)
                }
            }
        }
    }
}
