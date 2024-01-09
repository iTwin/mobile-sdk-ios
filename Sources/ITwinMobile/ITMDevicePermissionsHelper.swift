/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import CoreLocation
import AVFoundation
import Photos

/// Helper class for dealing with device permissions such as camera access and location access.
open class ITMDevicePermissionsHelper {
    /// Title for missing permissions dialog
    public static var accessRequiredStr = NSLocalizedString("Access required", comment: "Title for missing permissions dialog")
    /// Title for missing location permission dialog
    public static var locationDisabledStr = NSLocalizedString("Location services disabled", comment: "Title for missing location permission dialog")
    /// Button label for navigating to app setting page
    public static var settingsStr = NSLocalizedString("Settings", comment: "Button label for navigating to app setting page")
    /// Button label for cancelling operation
    public static var cancelStr = NSLocalizedString("Cancel", comment: "Button label for cancelling operation")
    
    /// No location access message
    public static var noLocationPermissionsStr = NSLocalizedString("Turn on location services to allow your location to be shown.", comment: "No location access message")
    /// Missing photo galery permission to import
    public static var noPhotoGalleryPermissionsStr = NSLocalizedString("To import photos and videos, allow access to Photos.", comment: "Missing photo galery permission to import")
    /// Missing camera permission to record video
    public static var noVideoCapturePermissionsStr = NSLocalizedString("To record videos, allow access to Camera.", comment: "Missing camera permission to record video")
    /// Missing photo galery and camera permissions to capture photo
    public static var noPhotoCapturePermissionsStr = NSLocalizedString("To take photos, allow access to Camera and Photos.", comment: "Missing photo galery and camera permissions to capture photo")
    /// Missing microphone access to record video
    public static var noMicrophonePermissionsStr = NSLocalizedString("To record videos with sound, allow access to Microphone.", comment: "Missing microphone access to record video")
    
    /// Indicates whether the user has denied location access to the app.
    public static var isLocationDenied: Bool {
        return CLLocationManager.authorizationStatus() == .denied || CLLocationManager.authorizationStatus() == .restricted
    }

    /// Indicates whether the user has denied microphone access to the app.
    public static var isMicrophoneDenied: Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted
    }

    /// Indicates whether the user has denied photo library access to the app.
    public static var isPhotoLibraryDenied: Bool {
        return PHPhotoLibrary.authorizationStatus() == .denied || PHPhotoLibrary.authorizationStatus() == .restricted
    }

    /// Indicates whether the user has denied video capture access to the app.
    public static var isVideoCaptureDenied: Bool {
        return AVCaptureDevice.authorizationStatus(for: .video) == .denied || AVCaptureDevice.authorizationStatus(for: .video) == .restricted
    }

    /// Indicates whether the user has denied photo capture access to the app.
    public static var isPhotoCaptureDenied: Bool {
        return isVideoCaptureDenied || isPhotoLibraryDenied
    }
    
    /// Show a dialog telling the user that their action requires location access, which has been denied, and allowing them to
    /// either open the iOS Settings app or cancel.
    /// - Parameter actionSelected: Callback indicating the user's response.
    /// - Note: This will have a style of .cancel for the cancel action and .default for the "Open Settings" action.
    @MainActor
    public static func openLocationAccessDialog(actionSelected: ((UIAlertAction) -> Void)? = nil) {
        openMissingPermissionsDialog(message: noLocationPermissionsStr, title: locationDisabledStr, actionSelected: actionSelected)
    }

    /// Show a dialog telling the user that their action requires microphone access, which has been denied, and allowing them to
    /// either open the iOS Settings app or cancel.
    /// - Parameter actionSelected: Callback indicating the user's response.
    /// - Note: This will have a style of .cancel for the cancel action and .default for the "Open Settings" action.
    @MainActor
    public static func openMicrophoneAccessDialog(actionSelected: ((UIAlertAction) -> Void)? = nil) {
        openMissingPermissionsDialog(message: noMicrophonePermissionsStr, actionSelected: actionSelected)
    }

    /// Show a dialog telling the user that their action requires photo gallery access, which has been denied, and allowing them to
    /// either open the iOS Settings app or cancel.
    /// - Parameter actionSelected: Callback indicating the user's response.
    /// - Note: This will have a style of .cancel for the cancel action and .default for the "Open Settings" action.
    @MainActor
    public static func openPhotoGalleryAccessAccessDialog(actionSelected: ((UIAlertAction) -> Void)? = nil) {
        openMissingPermissionsDialog(message: noPhotoGalleryPermissionsStr, actionSelected: actionSelected)
    }

    /// Show a dialog telling the user that their action requires video capture access, which has been denied, and allowing them to
    /// either open the iOS Settings app or cancel.
    /// - Parameter actionSelected: Callback indicating the user's response.
    /// - Note: This will have a style of .cancel for the cancel action and .default for the "Open Settings" action.
    @MainActor
    public static func openVideoCaptureAccessAccessDialog(actionSelected: ((UIAlertAction) -> Void)? = nil) {
        openMissingPermissionsDialog(message: noVideoCapturePermissionsStr, actionSelected: actionSelected)
    }

    /// Show a dialog telling the user that their action requires photo capture access, which has been denied, and allowing them to
    /// either open the iOS Settings app or cancel.
    /// - Parameter actionSelected: Callback indicating the user's response.
    /// - Note: This will have a style of .cancel for the cancel action and .default for the "Open Settings" action.
    @MainActor
    public static func openPhotoCaptureAccessAccessDialog(actionSelected: ((UIAlertAction) -> Void)? = nil) {
        openMissingPermissionsDialog(message: noPhotoCapturePermissionsStr, actionSelected: actionSelected)
    }

    @MainActor
    private static func openMissingPermissionsDialog(message: String, title: String? = nil, actionSelected: ((UIAlertAction) -> Void)? = nil) {
        let viewController = ITMAlertController.getAlertVC()
        let alert = UIAlertController(title: title == nil ? accessRequiredStr : title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: cancelStr, style: .cancel) { action in
            actionSelected?(action)
            ITMAlertController.doneWithAlertWindow()
        })
        alert.addAction(UIAlertAction(title: settingsStr, style: .default) { [self] action in
            openApplicationSettings()
            actionSelected?(action)
            ITMAlertController.doneWithAlertWindow()
        })
        viewController.present(alert, animated: true)
    }

    private static func openApplicationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url, options: [:])
        }
    }
}
