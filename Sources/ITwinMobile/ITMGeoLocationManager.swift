/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import CoreLocation
import Foundation
import PromiseKit
#if SWIFT_PACKAGE
import PMKFoundation
import PMKCoreLocation
#endif
import WebKit

fileprivate class ITMDevicePermissionsHelper {
    private static let accesRequiredStr = NSLocalizedString("Access required", comment: "Title for missing permissions dialog")
    private static let locationDisabledStr = NSLocalizedString("Location services disabled", comment: "Title for missing location permission dialog")
    private static let settingStr = NSLocalizedString("Settings", comment: "Button label for navigating to app setting page")
    private static let cancelStr = NSLocalizedString("Cancel", comment: "Button label for cancelling operation")
    private static let noLocationPermissionsStr = NSLocalizedString("Turn on location services to allow Field to show your location.", comment: "No location access message")

    static var isLocationDenied: Bool {
        return CLLocationManager.authorizationStatus() == .denied || CLLocationManager.authorizationStatus() == .restricted
    }

    static func openLocationAccessDialog(dialogCancelHandler: ((UIAlertAction) -> ())? = nil) {
        openMissingPermisionsDialog(message: noLocationPermissionsStr, title: locationDisabledStr, cancelAction: dialogCancelHandler)
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

// Note: The defintion of these structs represent Geolocation related objects available
// in most browsers. The objective of these structs is to map values between
// CoreLocation and objects expected by the browser API (window.navigator.geolocation)

/// Swift struct representing a JavaScript `GeolocationCoordinates` value.
/// See https://developer.mozilla.org/en-US/docs/Web/API/GeolocationCoordinates
public struct GeolocationCoordinates: Codable {
    var accuracy: CLLocationAccuracy
    var altitude: CLLocationDistance?
    var altitudeAccuracy: CLLocationAccuracy?
    /// The device's compass heading, not the movement heading that `GeolocationCoordinates` normally contain.
    var heading: CLLocationDirection?
    var latitude: CLLocationDegrees
    var longitude: CLLocationDegrees
    var speed: CLLocationSpeed?
}

/// Swift struct representing a JavaScript `GeolocationPosition` value.
/// See https://developer.mozilla.org/en-US/docs/Web/API/GeolocationPosition
public struct GeolocationPosition: Codable {
    var coords: GeolocationCoordinates
    var timestamp: TimeInterval

    func jsonObject() throws -> [String: Any] {
        let jsonData = try JSONEncoder().encode(self)
        return try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]
    }
}

/// Swift struct representing a JavaScript `GeolocationPositionError` value.
/// See https://developer.mozilla.org/en-US/docs/Web/API/GeolocationPositionError
public struct GeolocationPositionError: Codable {
    enum Code: UInt16, Codable {
        case PERMISSION_DENIED = 1
        case POSITION_UNAVAILABLE = 2
        case TIMEOUT = 3
    }

    var code: Code
    var message: String
    var PERMISSION_DENIED: Code = .PERMISSION_DENIED
    var POSITION_UNAVAILABLE: Code = .POSITION_UNAVAILABLE
    var TIMEOUT: Code = .TIMEOUT

    func jsonObject() -> [String: Any] {
        // Note: with this struct, it is impossible for the encode or jsonObject calls
        // below to fail, which is why we use try!. Having this function be marked
        // as throws causes unnecessary complications where this function is used.
        let jsonData = try! JSONEncoder().encode(self)
        return try! JSONSerialization.jsonObject(with: jsonData) as! [String: Any]
    }
}

public extension CLLocationManager {
    /// Get the current location and convert it into a JavaScript-compatible ``GeolocationPosition`` object converted to a JSON-compatible dictionary..
    /// - Returns: `Promise` that when resolved contains a ``GeolocationPosition`` object converted to a JSON-compatible dictionary.
    ///            The `Promise` is rejected if there is an error looking up the position.
    static func geolocationPosition() -> Promise<[String: Any]> {
        firstly {
            // NOTE: authorizationType: .whenInUse is REQUIRED below. The .automatic
            // option does not work right. See here:
            // https://dev.azure.com/bentleycs/beconnect/_workitems/edit/334106
            CLLocationManager.requestLocation(authorizationType: .whenInUse)
        }.then { (locations: [CLLocation]) -> Promise<[String: Any]> in
            if let location = locations.last {
                return try Promise.value(location.geolocationPosition())
            }
            throw ITMError(json: ["message": "Locations list empty."])
        }
    }
}

public extension CLLocation {
    /// Convert the ``CLLocation`` to a ``GeolocationPosition`` object converted to a JSON-compatible dictionary.
    /// - Parameter heading: The optional direction that will be stored in the `heading` field of the ``GeolocationCoordinates`` in the ``GeolocationPosition``.
    ///                      Note that this is the device's compass heading, not the motion heading as would normally be expected.
    /// - Returns: A ``GeolocationPosition`` object representing the ``CLLocation`` at the given heading, converted to a JSON-compatible dictionary.
    func geolocationPosition(_ heading: CLLocationDirection? = nil) throws -> [String: Any] {
        let coordinates = GeolocationCoordinates(
            accuracy: horizontalAccuracy,
            altitude: altitude,
            altitudeAccuracy: verticalAccuracy,
            heading: heading,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            speed: speed
        )
        return try GeolocationPosition(coords: coordinates, timestamp: timestamp.timeIntervalSince1970).jsonObject()
    }
}

/// Class for the native-side implementation of a `navigator.geolocation` polyfill.
public class ITMGeolocationManager: NSObject, CLLocationManagerDelegate, WKScriptMessageHandler {
    var locationManager: CLLocationManager = CLLocationManager()
    var watchIds: Set<Int64> = []
    var itmMessenger: ITMMessenger
    var webView: WKWebView
    private var orientationObserver: Any?

    /// - Parameters:
    ///   - itmMessenger: The ``ITMMessenger`` used to communicate with the JavaScript side of this polyfill.
    ///   - webView: The `WKWebView` containing the JavaScript side of this polyfill.
    public init(itmMessenger: ITMMessenger, webView: WKWebView) {
        self.itmMessenger = itmMessenger
        self.webView = webView
        super.init()
        locationManager.delegate = self
        // NOTE: kCLLocationAccuracyBest is actually not as good as
        // kCLLocationAccuracyBestForNavigation, so "best" is a misnomer
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        orientationObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: nil) { _ in
            self.updateHeadingOrientation()
        }
        updateHeadingOrientation()
        webView.configuration.userContentController.add(ITMWeakScriptMessageHandler(self), name: "Bentley_ITMGeolocation")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "Bentley_ITMGeolocation")
        if orientationObserver != nil {
            NotificationCenter.default.removeObserver(orientationObserver!)
        }
    }

    /// `WKScriptMessageHandler` function for handling messages from the JavaScript side of this polyfill.
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
            let data = body.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            ITMApplication.logger.log(.error, "ITMGeolocationManager: bad message format")
            return
        }
        if let messageName = jsonObject["messageName"] as? String {
            switch messageName {
            case "watchPosition":
                watchPosition(jsonObject)
                break
            case "clearWatch":
                clearWatch(jsonObject)
                break
            case "getCurrentPosition":
                getCurrentPosition(jsonObject)
                break
            default:
                ITMApplication.logger.log(.error, "Unknown Bentley_ITMGeolocation messageName: \(messageName)")
            }
        } else {
            ITMApplication.logger.log(.error, "Bentley_ITMGeolocation messageName is not a string.")
        }
    }

    private func updateHeadingOrientation() {
        var orientation: CLDeviceOrientation
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            orientation = .landscapeLeft
            break
        case .landscapeRight:
            orientation = .landscapeRight
            break
        case .portrait:
            orientation = .portrait
            break
        case .portraitUpsideDown:
            orientation = .portraitUpsideDown
            break
        default:
            return
        }
        if locationManager.headingOrientation != orientation {
            locationManager.headingOrientation = orientation
            if !watchIds.isEmpty {
                // I'm not sure if this is necessary or not, but it can't hurt.
                // Note that to force an immediate heading update, you have to
                // call stop then start.
                locationManager.stopUpdatingHeading()
                locationManager.startUpdatingHeading()
            }
        }
    }

    private func requestAuth() -> Promise<()> {
        return firstly {
            // NOTE 1: We don't really want the location here, but PromiseKit's
            // CLLocationManager.requestLocation() automatically handles all of the
            // authorization requesting, and there is a lot of (private) code behind
            // that. So, instead of copying all of that code into here, we instead
            // ask for a location but then ignore the result. If there is an
            // authorization error, our return Promise will be rejected.
            // NOTE 2: authorizationType: .whenInUse is REQUIRED below. The .automatic
            // option does not work right. See here:
            // https://dev.azure.com/bentleycs/beconnect/_workitems/edit/334106
            CLLocationManager.requestLocation(authorizationType: .whenInUse)
        }.map { _ -> () in
            ()
        }.recover { error -> Promise<()> in
            if let pmkError = error as? CLLocationManager.PMKError, pmkError == CLLocationManager.PMKError.notAuthorized {
                throw ITMError()
            }
            // If we get an error other than PMKError.notAuthorized, it means that the
            // authorization portion of the requestLocation succeeded, so ignore the
            // error and let it get handled later.
            return Promise.value(())
        }
    }

    /// Ask the user for location authorization if not already granted.
    /// - Returns: `Promise` with no data that resolves if authorization is granted, or rejects if authorization is denied.
    public func checkAuth() -> Promise<()> {
        switch CLLocationManager.authorizationStatus() {
        case .authorizedAlways, .authorizedWhenInUse:
            return Promise.value(())
        case .notDetermined:
            return requestAuth()
        case .denied, .restricted:
            return Promise(error: ITMError())
        default:
            return Promise(error: ITMError())
        }
    }

    private func watchPosition(_ message: [String: Any]) {
        // NOTE: this ignores the optional options.
        guard let positionId = message["positionId"] as? Int64 else {
            ITMApplication.logger.log(.error, "watchPosition error: no Int64 positionId in request.")
            return
        }
        watchIds.insert(positionId)
        if watchIds.count == 1 {
            locationManager.startUpdatingLocation()
            locationManager.startUpdatingHeading()
        }
        checkAuth().catch { _ in
            self.sendError("watchPosition", positionId: positionId, errorJson: self.notAuthorizedError)
        }
    }

    private func clearWatch(_ message: [String: Any]) {
        guard let positionId = message["positionId"] as? Int64 else {
            ITMApplication.logger.log(.error, "clearWatch error: no Int64 positionId in request.")
            return
        }
        watchIds.remove(positionId)
        if watchIds.isEmpty {
            stopUpdating()
        }
    }

    private func stopUpdating() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
    }

    private var notAuthorizedError: [String: Any] {
        return GeolocationPositionError(code: .PERMISSION_DENIED, message: NSLocalizedString("LocationNotAuthorized", value: "Not authorized", comment: "Location lookup not authorized")).jsonObject()
    }

    private var positionUnavailableError: [String: Any] {
        return GeolocationPositionError(code: .POSITION_UNAVAILABLE, message: NSLocalizedString("LocationPositionUnavailable", value: "Unable to determine position.", comment: "Location lookup could not determine position")).jsonObject()
    }

    private func sendError(_ messageName: String, positionId: Int64, errorJson: [String: Any]) {
        let message: [String: Any] = [
            "positionId": positionId,
            "error": errorJson
        ]
        let js = "window.Bentley_ITMGeolocation('\(messageName)', '\(itmMessenger.jsonString(message).toBase64())')"
        itmMessenger.evaluateJavaScript(js)
    }

    private func getCurrentPosition(_ message: [String: Any]) {
        if ITMDevicePermissionsHelper.isLocationDenied {
            ITMDevicePermissionsHelper.openLocationAccessDialog()
            return
        }

        // NOTE: this ignores the optional options.
        guard let positionId = message["positionId"] as? Int64 else {
            ITMApplication.logger.log(.error, "getCurrentPosition error: no Int64 positionId in request.")
            return
        }
        firstly {
            CLLocationManager.geolocationPosition()
        }.done { position in
            let message: [String: Any] = [
                "positionId": positionId,
                "position": position
            ]
            let js = "window.Bentley_ITMGeolocation('getCurrentPosition', '\(self.itmMessenger.jsonString(message).toBase64())')"
            self.itmMessenger.evaluateJavaScript(js)
        }.catch { error in
            var errorJson: [String: Any]
            self.stopUpdating()
            // If it's not PERMISSION_DENIED, the only other two options are POSITION_UNAVAILABLE
            // and TIMEOUT. Since we don't have any timeout handling yet, always fall back
            // to POSITION_UNAVAILABLE.
            errorJson = self.positionUnavailableError
            self.sendError("getCurrentPosition", positionId: positionId, errorJson: errorJson)
        }
    }

    private func sendLocationUpdates() {
        firstly {
            checkAuth()
        }.done {
            if let lastLocation = self.locationManager.location {
                var positionJson: [String: Any]?
                do {
                    positionJson = try lastLocation.geolocationPosition(self.locationManager.heading?.trueHeading)
                } catch let ex {
                    ITMApplication.logger.log(.error, "Error converting CLLocation to GeolocationPosition: \(ex)")
                    let errorJson = self.positionUnavailableError
                    for positionId in self.watchIds {
                        self.sendError("watchPosition", positionId: positionId, errorJson: errorJson)
                    }
                }
                if let positionJson = positionJson {
                    for positionId in self.watchIds {
                        let message: [String: Any] = [
                            "positionId": positionId,
                            "position": positionJson
                        ]
                        let js = "window.Bentley_ITMGeolocation('watchPosition', '\(self.itmMessenger.jsonString(message).toBase64())')"
                        self.itmMessenger.evaluateJavaScript(js)
                    }
                }
            }
        }.catch { _ in
            let errorJson = self.notAuthorizedError
            for positionId in self.watchIds {
                self.sendError("watchPosition", positionId: positionId, errorJson: errorJson)
            }
        }
    }

    // MARK: - CLLocationManagerDelegate
    
    /// `CLLocationManagerDelegate` function that reports location updates to the JavaScript side of the polyfill.
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        sendLocationUpdates()
    }

    /// `CLLocationManagerDelegate` function that reports heading updates to the JavaScript side of the polyfill.
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        sendLocationUpdates()
    }

    /// `CLLocationManagerDelegate` function that reports location errors to the JavaScript side of the polyfill.
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let (domain, code) = { ($0.domain, $0.code) }(error as NSError)
        if code == CLError.locationUnknown.rawValue, domain == kCLErrorDomain {
            // Apple docs say you should just ignore this error
        } else {
            let errorJson: [String: Any]
            stopUpdating()
            if code == CLError.denied.rawValue, domain == kCLErrorDomain {
                errorJson = notAuthorizedError
            } else {
                // If it's not PERMISSION_DENIED, the only other two options are POSITION_UNAVAILABLE
                // and TIMEOUT. Since we don't have any timeout handling yet, always fall back
                // to POSITION_UNAVAILABLE.
                errorJson = positionUnavailableError
            }
            for positionId in watchIds {
                sendError("watchPosition", positionId: positionId, errorJson: errorJson)
            }
        }
    }

    /// `CLLocationManagerDelegate` function that reports location  to the JavaScript side of the polyfill when the authorization first comes through.
    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if !watchIds.isEmpty {
            sendLocationUpdates()
        }
    }
}
