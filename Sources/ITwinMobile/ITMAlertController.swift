/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit

// MARK: - Helper class used by ITMAlertController

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

// MARK: - ITMAlertController class

/// `UIAlertController` subclass that hides the status bar by default and presents on top of everything else.
open class ITMAlertController: UIAlertController {
    /// Called from viewDidDisappear. Note that when an action is selected in an action sheet, this will be called
    /// before the action's handler.
    var onClose: (() -> Void)?
    var onDeinit: (() -> Void)?
    var rootBounds: CGRect?
    var deviceOrientation: UIDeviceOrientation?
    /// Set this to true to not hide the status bar.
    var showStatusBar = false
    private static var alertWindow: UIWindow?

    /// - Returns: An instance of ``ITMAlertController`` that is properly configured. May return a preexisting instance.
    public static var getAlertVC: () -> UIViewController = {
        // This avoids cases where topmost view controller is dismissed while presenting alert
        // Create temporary window to show alert anywhere and anytime and avoid view hiearchy issues.
        if alertWindow == nil {
            var alertWindow = UIWindow(frame: UIScreen.main.bounds)
            alertWindow.rootViewController = ITMErrorViewController()
            alertWindow.windowLevel = UIWindow.Level.alert + 1
            ITMAlertController.alertWindow = alertWindow
        }
        alertWindow!.windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        alertWindow!.makeKeyAndVisible()
        // Even though we initialized the UIWindow with the proper frame, makeKeyAndVisible sometimes
        // corrupts the frame, changing the orientation and moving it completely off-screen. I think
        // this is a bug in iOS, and I am not sure why it happens sometimes and not other times.
        // However, resetting the frame after the makeKeyAndVisible call fixes the problem.
        alertWindow!.frame = alertWindow?.windowScene?.screen.bounds ?? UIScreen.main.bounds
        return alertWindow!.rootViewController!
    }

    deinit {
        // If an ITMAlertController is presented in a view that has been asked to present a different
        // one but hasn't had time to yet, the viewDidAppear and viewDidDisappear functions never get
        // called, which means that onClose never gets called. This call to onDeinit makes sure that
        // this sequence can still be dealt with.
        onDeinit?()
    }

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
    public static var doneWithAlertWindow: () -> Void = {
        alertWindow?.windowScene = nil
        alertWindow = nil
    }

    open override var prefersStatusBarHidden: Bool {
        return !showStatusBar
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

        // don't dismiss modal alerts as they stay in the center of the screen and should be handled by the user
        if preferredStyle == .alert { return }

        if let deviceOrientation = deviceOrientation, deviceOrientation != UIDevice.current.orientation {
            dismiss(animated: true)
        }
        coordinator.animate(alongsideTransition: nil) { [self] _ in
            if let rootBounds = rootBounds, let deviceOrientation = deviceOrientation {
                if rootBounds != view.window?.rootViewController?.view.bounds || deviceOrientation != UIDevice.current.orientation {
                    dismiss(animated: true)
                }
            }
        }
    }
}
