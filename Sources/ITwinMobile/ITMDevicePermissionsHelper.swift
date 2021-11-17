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
    public static var accesRequiredStr = NSLocalizedString("Access required", comment: "Title for missing permissions dialog")
    /// Title for missing location permission dialog
    public static var locationDisabledStr = NSLocalizedString("Location services disabled", comment: "Title for missing location permission dialog")
    /// Button label for navigating to app setting page
    public static var settingStr = NSLocalizedString("Settings", comment: "Button label for navigating to app setting page")
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

    public static var isLocationDenied: Bool {
        return CLLocationManager.authorizationStatus() == .denied || CLLocationManager.authorizationStatus() == .restricted
    }

    public static var isMicrophoneDenied: Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted
    }

    public static var isPhotoLibraryDenied: Bool {
        return PHPhotoLibrary.authorizationStatus() == .denied || PHPhotoLibrary.authorizationStatus() == .restricted
    }

    public static var isVideoCaptureDenied: Bool {
        return AVCaptureDevice.authorizationStatus(for: .video) == .denied || AVCaptureDevice.authorizationStatus(for: .video) == .restricted
    }

    public static var isPhotoCaptureDenied: Bool {
        return isVideoCaptureDenied || isPhotoLibraryDenied
    }

    public static func openLocationAccessDialog(dialogCancelHandler: ((UIAlertAction) -> ())? = nil) {
        openMissingPermisionsDialog(message: noLocationPermissionsStr, title: locationDisabledStr, cancelAction: dialogCancelHandler)
    }

    public static func openMicrophoneAccessDialog(dialogCancelHandler: ((UIAlertAction) -> ())? = nil) {
        openMissingPermisionsDialog(message: noMicrophonePermissionsStr, cancelAction: dialogCancelHandler)
    }

    public static func openPhotoGalleryAccessAccessDialog() {
        openMissingPermisionsDialog(message: noPhotoGalleryPermissionsStr)
    }

    public static func openVideoCaptureAccessAccessDialog() {
        openMissingPermisionsDialog(message: noVideoCapturePermissionsStr)
    }

    public static func openPhotoCaptureAccessAccessDialog() {
        openMissingPermisionsDialog(message: noPhotoCapturePermissionsStr)
    }

    private static func openMissingPermisionsDialog(message: String, title: String? = nil, cancelAction: ((UIAlertAction) -> ())? = nil) {
        let viewController = ITMAlertController.getAlertVC()
        let alert = UIAlertController(title: title == nil ? accesRequiredStr : title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: cancelStr, style: .cancel) { action in
            cancelAction?(action)
            ITMAlertController.doneWithAlertWindow()
        })
        alert.addAction(UIAlertAction(title: settingStr, style: .default) { _ in
            self.openApplicationSettings()
            ITMAlertController.doneWithAlertWindow()
        })
        viewController.present(alert, animated: true)
    }

    private static func openApplicationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
