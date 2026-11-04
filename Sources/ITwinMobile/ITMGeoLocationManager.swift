/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import CoreLocation
import Foundation
import AsyncLocationKit
import WebKit

// MARK: - Structs for Geolocation related JS objects

// Note: The defintion of these structs represent Geolocation related objects available
// in most browsers. The objective of these structs is to map values between
// CoreLocation and objects expected by the browser API (window.navigator.geolocation)

/// Swift struct representing a JavaScript `GeolocationCoordinates` value.
///
/// - SeeAlso: [GeolocationCoordinates reference](https://developer.mozilla.org/en-US/docs/Web/API/GeolocationCoordinates)
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
/// - SeeAlso: [GeolocationPosition reference](https://developer.mozilla.org/en-US/docs/Web/API/GeolocationPosition)
public struct GeolocationPosition: Codable {
    var coords: GeolocationCoordinates
    var timestamp: Int64

    func jsonObject() throws -> JSON {
        let jsonData = try JSONEncoder().encode(self)
        return try JSONSerialization.jsonObject(with: jsonData) as! JSON
    }
}

/// Swift struct representing a JavaScript `GeolocationPositionError` value.
/// - SeeAlso: [GeolocationPositionError reference](https://developer.mozilla.org/en-US/docs/Web/API/GeolocationPositionError)
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

    func jsonObject() -> JSON {
        // Note: with this struct, it is impossible for the encode or jsonObject calls
        // below to fail, which is why we use try!. Having this function be marked
        // as throws causes unnecessary complications where this function is used.
        let jsonData = try! JSONEncoder().encode(self)
        return try! JSONSerialization.jsonObject(with: jsonData) as! JSON
    }
}

// MARK: - CoreLocation extensions

@MainActor
private final class SingleLocationLookup: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func location() async throws -> CLLocation {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                manager.requestLocation()
            }
        }, onCancel: {
            Task { @MainActor in
                self.finish(.failure(CancellationError()))
            }
        })
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        manager.stopUpdatingLocation()
        manager.delegate = nil
        continuation.resume(with: result)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last(where: {
                $0.horizontalAccuracy.isFinite && $0.horizontalAccuracy >= 0
            }) else {
                finish(.failure(NSError(domain: kCLErrorDomain, code: CLError.locationUnknown.rawValue)))
                return
            }
            finish(.success(location))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            finish(.failure(error))
        }
    }
}

/// Extension to `AsyncLocationManager` that allows getting the location in a format suitable for sending to JavaScript.
public extension AsyncLocationManager {
    /// Get the current location and convert it into a JavaScript-compatible ``GeolocationPosition`` object
    /// converted to a JSON-compatible dictionary.
    /// - Throws: Throws if there is anything that prevents the position lookup from working.
    /// - Returns: ``GeolocationPosition`` object converted to a JSON-compatible dictionary.
    func geolocationPosition() async throws -> JSON {
        try await geolocationPosition { await self.requestPermission(with: .whenInUsage) }
    }

    /// Variant that lets the caller supply the permission call, so concurrent requests can be managed to avoid a crash in
    /// AsyncLocationKit's `requestPermission` path.
    internal func geolocationPosition(getPermission: () async -> CLAuthorizationStatus) async throws -> JSON {
        let permission = await getPermission()
        try Task.checkCancellation()
        if !ITMGeolocationManager.isAuthorized(permission) {
            throw ITMError(json: ["message": "Permission denied."])
        }
        let lookup = await SingleLocationLookup()
        let location = try await lookup.location()
        try Task.checkCancellation()
        return try location.geolocationPosition()
    }
}

/// Extension that allows conversion of a `CLLocation` value to a ``GeolocationPosition``-based JSON-compatible dictionary.
public extension CLLocation {
    /// Convert the `CLLocation` to a ``GeolocationPosition`` object converted to a JSON-compatible dictionary.
    /// - Parameter heading: The optional direction that will be stored in the `heading` field of the
    /// ``GeolocationCoordinates`` in the ``GeolocationPosition``. Note that this is the device's
    /// compass heading, not the motion heading as would normally be expected.
    /// - Returns: A ``GeolocationPosition`` object representing the ``CLLocation`` at the given
    /// heading, converted to a JSON-compatible dictionary.
    func geolocationPosition(_ heading: CLLocationDirection? = nil) throws -> JSON {
        let coordinates = GeolocationCoordinates(
            accuracy: horizontalAccuracy,
            altitude: altitude,
            altitudeAccuracy: verticalAccuracy,
            heading: heading,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            speed: speed
        )
        return try GeolocationPosition(coords: coordinates, timestamp: Int64(timestamp.timeIntervalSince1970 * 1000.0)).jsonObject()
    }
}

// MARK: - ITMGeolocationManagerDelegate protocol

/// Methods for getting more information from and exerting more contol over an ``ITMGeolocationManager`` object.
public protocol ITMGeolocationManagerDelegate: AnyObject {
    /// Called to determine whether or not to call `ITMDevicePermissionsHelper.openLocationAccessDialog`.
    ///
    /// The default implementation returns `true`. Implement this method if you want to prevent
    /// `ITMDevicePermissionsHelper.openLocationAccessDialog` from being
    /// called for a given action.
    /// - Note: `action` will never be `clearWatch`.
    /// - Parameters:
    ///   - manager: The ``ITMGeolocationManager`` ready to show the dialog.
    ///   - action: The action that wants to show the dialog.
    func geolocationManager(_ manager: ITMGeolocationManager, shouldShowLocationAccessDialogFor action: ITMGeolocationManager.Action) -> Bool

    /// Called when ``ITMGeolocationManager`` receives a `clearWatch` request from web view.
    ///
    /// The default implementation doesn't do anything.
    /// - Parameters:
    ///   - manager: The ``ITMGeolocationManager`` informing the delegate of the impending event.
    ///   - position: The positionId of the request sent from the web view.
    func geolocationManager(_ manager: ITMGeolocationManager, willClearWatch position: Int64)

    /// Called when ``ITMGeolocationManager`` receives a `getCurrentPosition` request from web view.
    ///
    /// The default implementation doesn't do anything.
    /// - Parameters:
    ///   - manager: The ``ITMGeolocationManager`` informing the delegate of the impending event.
    ///   - position: The positionId of the request sent from the web view.
    func geolocationManager(_ manager: ITMGeolocationManager, willGetCurrentPosition position: Int64)

    /// Called when ``ITMGeolocationManager`` receives a `watchPosition` request from a web view.
    ///
    /// The default implementation doesn't do anything.
    /// - Parameters:
    ///   - manager: The ``ITMGeolocationManager`` informing the delegate of the impending event.
    ///   - position: The positionId of the request sent from the web view.
    func geolocationManager(_ manager: ITMGeolocationManager, willWatchPosition position: Int64)
}

// MARK: - ITMGeolocationManagerDelegate extension with default implementations

/// Default implemenation for pseudo-optional ITMGeolocationManagerDelegate protocol functions.
public extension ITMGeolocationManagerDelegate {
    /// This default implementation always returns `true`.
    func geolocationManager(_ manager: ITMGeolocationManager, shouldShowLocationAccessDialogFor action: ITMGeolocationManager.Action) -> Bool {
        return true
    }

    /// This default implementation does nothing.
    func geolocationManager(_ manager: ITMGeolocationManager, willClearWatch position: Int64) {
        //do nothing
    }

    /// This default implementation does nothing.
    func geolocationManager(_ manager: ITMGeolocationManager, willGetCurrentPosition position: Int64) {
        //do nothing
    }

    /// This default implementation does nothing.
    func geolocationManager(_ manager: ITMGeolocationManager, willWatchPosition position: Int64) {
        //do nothing
    }
}

// MARK: - ITMGeolocationManager class

/// Class for the native-side implementation of a `navigator.geolocation` polyfill.
public class ITMGeolocationManager: NSObject, CLLocationManagerDelegate, WKScriptMessageHandler {
    /// Actions taken by ``ITMGeolocationManager``.
    @objc public enum Action: Int {
        case watchPosition = 0
        case clearWatch
        case getCurrentLocation
    }

    private actor Authorizer {
        private var permissionTask: Task<CLAuthorizationStatus, Never>?

        func getPermission(using locationManager: AsyncLocationManager) async -> CLAuthorizationStatus {
            guard let permissionTask else {
                let newTask = Task { await locationManager.requestPermission(with: .whenInUsage) }
                self.permissionTask = newTask
                defer { self.permissionTask = nil }
                return await newTask.value
            }
            return await permissionTask.value
        }
    }

    private final class DocumentSession {
        let id = UUID().uuidString
        let origin: String
        var documentId: String?
        var watchRequests: Set<Int64> = []
        var positionRequests: Set<Int64> = []
        var watchTasks: [Int64: Task<Void, Never>] = [:]
        var positionTasks: [Int64: Task<Void, Never>] = [:]
        var locationTask: Task<JSON, Error>?
        var rateWindowStart: TimeInterval = 0
        var rateWindowCount = 0

        init(origin: String) { self.origin = origin }

        func cancel() {
            locationTask?.cancel()
            for task in watchTasks.values { task.cancel() }
            for task in positionTasks.values { task.cancel() }
        }
    }

    private static let bridgeName = "Bentley_ITMGeolocation"
    private static let secureBridgeScript = "window.Bentley_ITMGeolocationSecureBridge = true;"
    private var allowedOrigins = ITMBridgeOriginPolicy.defaultAllowedOrigins
    private var documentSession: DocumentSession?
    private var loadingObservation: NSKeyValueObservation?
    private var attached = false

    var locationManager: CLLocationManager = CLLocationManager()
    var watchIds: Set<Int64> = []
    private let authorizer = Authorizer()
    var itmMessenger: ITMMessenger
    /// Backing variable for ``asyncLocationManager`` computed property.
    private var _asyncLocationManager: AsyncLocationManager?
    private var lastLocationTimeThreshold: Double = 0.0
    var webView: WKWebView
    private let observers = ITMObservers()
    private var isUpdatingPosition = false
    /// The delegate for ITMGeolocationManager.
    public weak var delegate: ITMGeolocationManagerDelegate?

    /// Create a geolocation manager.
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
        observers.addObserver(forName: UIDevice.orientationDidChangeNotification) { [weak self] _ in
            Task { @MainActor in
                self?.updateHeadingOrientation()
            }
        }
        updateHeadingOrientation()
        attach(webView)
    }

    deinit {
        let sessionCopy = documentSession
        let locationManagerCopy = locationManager
        let webViewCopy = webView
        let wasAttached = attached
        Task { @MainActor in
            sessionCopy?.cancel()
            locationManagerCopy.stopUpdatingLocation()
            locationManagerCopy.stopUpdatingHeading()
            if wasAttached {
                webViewCopy.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
            }
        }
    }

    /// Attach before loading the frontend, using exact native-configured origins.
    public func attach(_ webView: WKWebView, allowedOrigins: Set<String> = ITMBridgeOriginPolicy.defaultAllowedOrigins) {
        let origins = ITMBridgeOriginPolicy.validOrigins(allowedOrigins)
        if attached, self.webView === webView, self.allowedOrigins == origins { return }
        detach()
        self.webView = webView
        self.allowedOrigins = origins
        guard !origins.isEmpty else { return }
        attached = true
        let controller = webView.configuration.userContentController
        if !controller.userScripts.contains(where: { $0.source == Self.secureBridgeScript }) {
            controller.addUserScript(WKUserScript(source: Self.secureBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        controller.add(ITMWeakScriptMessageHandler(self), name: Self.bridgeName)
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            if view.isLoading {
                self?.onPageStarted(view)
            } else {
                self?.onPageFinished(view)
            }
        }
        onPageFinished(webView)
    }

    /// Remove the handler and cancel the attached document's work and location updates.
    public func detach() {
        invalidateSession()
        loadingObservation = nil
        if attached {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        }
        attached = false
    }

    /// Invalidate requests when the main frame starts navigating.
    public func onPageStarted(_ webView: WKWebView) {
        guard attached, self.webView === webView else { return }
        invalidateSession()
    }

    /// Initialize an authorized loaded document, including recovery after failed provisional navigation.
    public func onPageFinished(_ webView: WKWebView) {
        guard attached, self.webView === webView, !webView.isLoading, documentSession == nil,
              let url = webView.url, let origin = ITMBridgeOriginPolicy.origin(for: url),
              allowedOrigins.contains(origin) else { return }
        let session = DocumentSession(origin: origin)
        documentSession = session
        webView.evaluateJavaScript("""
            (function() {
                if (window !== window.top) return false;
                window.Bentley_ITMGeolocationNativeSession = '\(session.id)';
                if (typeof window.Bentley_ITMGeolocationInitialize !== 'function') return false;
                window.Bentley_ITMGeolocationInitialize('\(session.id)');
                return true;
            })();
            """) { [weak self] result, _ in
                if self?.documentSession === session, result as? Bool != true {
                    ITMApplication.log(.error, "Geolocation requires a session-aware mobile-sdk-core frontend.")
                }
            }
    }

    private func invalidateSession() {
        let session = documentSession
        documentSession = nil
        session?.cancel()
        watchIds.removeAll()
        stopUpdatingPosition()
    }

    /// Sets the threshold when "last location" is used in location requests instead of requesting a
    /// new location. The default of `0.0` means that all location requests ask for the location (which
    /// can take time).
    /// - Parameter value: The threshold value (in seconds)
    public func setLastLocationTimeThreshold(_ value: Double) {
        lastLocationTimeThreshold = value
    }

    /// `WKScriptMessageHandler` function for handling messages from the JavaScript side of this polyfill.
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard attached, message.webView === webView, message.name == Self.bridgeName,
              userContentController === webView.configuration.userContentController,
              message.frameInfo.isMainFrame, !webView.isLoading, let session = documentSession else { return }
        let source = message.frameInfo.securityOrigin
        guard (0...65535).contains(source.port) else { return }
        var components = URLComponents()
        components.scheme = source.protocol
        components.host = source.host
        components.port = source.port == 0 ? nil : source.port
        guard let sourceURL = components.url,
              ITMBridgeOriginPolicy.origin(for: sourceURL) == session.origin,
              let currentURL = webView.url, ITMBridgeOriginPolicy.origin(for: currentURL) == session.origin else { return }
        guard let body = message.body as? String, body.utf8.count <= 8192,
              let data = body.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? JSON,
              request["sessionId"] as? String == session.id,
              let documentId = request["documentId"] as? String,
              documentId.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              let operation = request["messageName"] as? String else { return }
        if operation == "ready" {
            guard request.count == 3, session.documentId == nil else { return }
            session.documentId = documentId
            sendResponse(session, messageName: "ready", messageData: "")
            return
        }
        guard session.documentId == documentId,
              Set(request.keys).isSubset(of: ["messageName", "sessionId", "documentId", "positionId", "options"]),
              let number = request["positionId"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 1, number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue == Double(number.int64Value) else { return }
        let positionId = number.int64Value
        if operation == "clearWatch" {
            guard session.watchRequests.remove(positionId) != nil else { return }
            session.watchTasks.removeValue(forKey: positionId)?.cancel()
            delegate?.geolocationManager(self, willClearWatch: positionId)
            watchIds.remove(positionId)
            if watchIds.isEmpty { stopUpdatingPosition() }
            return
        }
        guard operation == "watchPosition" || operation == "getCurrentPosition" else { return }
        let isWatch = operation == "watchPosition"
        guard !(isWatch ? session.watchRequests : session.positionRequests).contains(positionId) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - session.rateWindowStart >= 1 {
            session.rateWindowStart = now
            session.rateWindowCount = 0
        }
        if session.rateWindowCount >= 100 || session.watchRequests.count + session.positionRequests.count >= 128 {
            sendResponse(session, messageName: operation, messageData: itmMessenger.jsonString([
                "positionId": positionId, "error": positionUnavailableError
            ]).toBase64())
            return
        }
        session.rateWindowCount += 1
        if isWatch { session.watchRequests.insert(positionId) } else { session.positionRequests.insert(positionId) }
        let task = Task { @MainActor [weak self] in
            guard let self, self.documentSession === session, !Task.isCancelled else { return }
            defer {
                if !Task.isCancelled {
                    if isWatch { session.watchTasks.removeValue(forKey: positionId) } else { session.positionTasks.removeValue(forKey: positionId) }
                }
            }
            if isWatch {
                await self.watchPosition(positionId, session: session)
            } else {
                await self.getCurrentPosition(positionId, session: session)
            }
        }
        if isWatch { session.watchTasks[positionId] = task } else { session.positionTasks[positionId] = task }
    }

    private func updateHeadingOrientation() {
        let deviceOrientation = UIDevice.current.orientation
        let orientation: CLDeviceOrientation = switch deviceOrientation {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        default: .unknown // face up and face down are ignored by CLLocationManager
        }
        guard orientation != .unknown, locationManager.headingOrientation != orientation else { return }
        locationManager.headingOrientation = orientation
        if isUpdatingPosition {
            // I'm not sure if this is necessary or not, but it can't hurt.
            // Note that to force an immediate heading update, you have to
            // call stop then start.
            locationManager.stopUpdatingHeading()
            locationManager.startUpdatingHeading()
        }
    }

    /// Determine if the given permission indicates the user is authorized to check location.
    /// - Parameter permission: The `CLAuthorizationStatus` to check.
    /// - Returns: `true` if `permission` is `authorizedAlways` or `authorizedWhenInUse`,
    /// and `false` otherwise.
    public static func isAuthorized(_ permission: CLAuthorizationStatus) -> Bool {
        return permission == .authorizedAlways || permission == .authorizedWhenInUse
    }

    private func requestAuth() async throws {
        let permission = await authorizer.getPermission(using: asyncLocationManager)
        guard Self.isAuthorized(permission) else {
            throw ITMError(json: ["message": "Permission denied."])
        }
    }

    /// Ask the user for location authorization if not already granted.
    /// - Throws: Throws an exception if the user does not grant access.
    public func checkAuth() async throws {
        switch CLLocationManager.authorizationStatus() {
        case .authorizedAlways, .authorizedWhenInUse:
            return
        case .notDetermined:
            return try await requestAuth()
        default:
            throw ITMError(json: ["message": "Permission denied."])
        }
    }

    private func watchPosition(_ positionId: Int64, session: DocumentSession) async {
        // NOTE: this ignores the optional options.
        guard documentSession === session, session.watchRequests.contains(positionId), !Task.isCancelled else { return }
        if ITMDevicePermissionsHelper.isLocationDenied {
            let showDialog = delegate?.geolocationManager(self, shouldShowLocationAccessDialogFor: .watchPosition) ?? true
            guard documentSession === session, session.watchRequests.contains(positionId), !Task.isCancelled else { return }
            if showDialog {
                ITMDevicePermissionsHelper.openLocationAccessDialog() { [self] _ in
                    sendError("watchPosition", positionId: positionId, errorJson: notAuthorizedError, session: session)
                }
            } else {
                sendError("watchPosition", positionId: positionId, errorJson: notAuthorizedError, session: session)
            }
            return
        }
        delegate?.geolocationManager(self, willWatchPosition: positionId)
        guard documentSession === session, session.watchRequests.contains(positionId), !Task.isCancelled else { return }
        watchIds.insert(positionId)
        do {
            try await checkAuth()
            // The watch may have been cleared while we awaited authorization.
            guard documentSession === session, !Task.isCancelled, watchIds.contains(positionId) else { return }
            startUpdatingPosition()
        } catch {
            guard documentSession === session, !Task.isCancelled else { return }
            guard watchIds.remove(positionId) != nil else { return }
            if watchIds.isEmpty {
                stopUpdatingPosition()
            }
            sendError("watchPosition", positionId: positionId, errorJson: notAuthorizedError, session: session)
        }
    }

    /// Starts location tracking if there are any registered position watches.
    /// - Note: This happens automatically when the "watchPosition" message is received from TypeScript.
    ///         Only call this after a corresponding call to ``stopUpdatingPosition()``.
    public func startUpdatingPosition() {
        if !watchIds.isEmpty, !isUpdatingPosition {
            isUpdatingPosition = true
            locationManager.startUpdatingLocation()
            locationManager.startUpdatingHeading()
        }
    }

    /// Stops tracking location without clearing registered position watches.
    /// - Note: Tracking can be resumed with ``startUpdatingPosition()``.
    public func stopUpdatingPosition() {
        isUpdatingPosition = false
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
    }

    private var notAuthorizedError: JSON {
        return GeolocationPositionError(code: .PERMISSION_DENIED, message: NSLocalizedString("LocationNotAuthorized", value: "Not authorized", comment: "Location lookup not authorized")).jsonObject()
    }

    private var positionUnavailableError: JSON {
        return GeolocationPositionError(code: .POSITION_UNAVAILABLE, message: NSLocalizedString("LocationPositionUnavailable", value: "Unable to determine position.", comment: "Location lookup could not determine position")).jsonObject()
    }

    private func sendError(_ messageName: String, positionId: Int64, errorJson: JSON, session: DocumentSession) {
        guard documentSession === session else { return }
        if messageName == "watchPosition", !session.watchRequests.contains(positionId) { return }
        let message: JSON = [
            "positionId": positionId,
            "error": errorJson
        ]
        sendResponse(session, messageName: messageName, messageData: itmMessenger.jsonString(message).toBase64())
        if messageName == "getCurrentPosition" { session.positionRequests.remove(positionId) }
        if messageName == "watchPosition", !watchIds.contains(positionId) { session.watchRequests.remove(positionId) }
    }

    private func sendErrorToWatchers(_ messageName: String, errorJson: JSON, session: DocumentSession) {
        for positionId in watchIds {
            sendError(messageName, positionId: positionId, errorJson: errorJson, session: session)
        }
    }

    private func requireAsyncLocationManager() -> AsyncLocationManager {
        if _asyncLocationManager == nil {
            _asyncLocationManager = AsyncLocationManager(desiredAccuracy: .bestAccuracy)
        }
        return _asyncLocationManager!
    }

    /// This ``ITMGeolocationManager``'s `AsyncLocationManager`. If this has not yet been initialized, that
    /// happens automatically in the main thread.
    public var asyncLocationManager: AsyncLocationManager {
        get async {
            return requireAsyncLocationManager()
        }
    }

    private func getCurrentPosition(_ positionId: Int64, session: DocumentSession) async {
        // NOTE: this ignores the optional options.
        guard documentSession === session, !Task.isCancelled else { return }
        if ITMDevicePermissionsHelper.isLocationDenied {
            let showDialog = delegate?.geolocationManager(self, shouldShowLocationAccessDialogFor: .getCurrentLocation) ?? true
            guard documentSession === session, !Task.isCancelled else { return }
            if showDialog {
                ITMDevicePermissionsHelper.openLocationAccessDialog() { [self] _ in
                    sendError("getCurrentPosition", positionId: positionId, errorJson: notAuthorizedError, session: session)
                }
            } else {
                sendError("getCurrentPosition", positionId: positionId, errorJson: notAuthorizedError, session: session)
            }
            return
        }

        delegate?.geolocationManager(self, willGetCurrentPosition: positionId)
        guard documentSession === session, !Task.isCancelled else { return }

        if lastLocationTimeThreshold != 0.0, let lastLocation = locationManager.location, abs(lastLocation.timestamp.timeIntervalSinceNow) < lastLocationTimeThreshold {
            do {
                let position = try lastLocation.geolocationPosition()
                sendPosition(position, positionId: positionId, session: session)
                return
            } catch {} // Ignore and do new lookup below
        }

        do {
            let lookup = session.locationTask ?? Task { @MainActor [self, weak session] in
                defer { session?.locationTask = nil }
                return try await asyncLocationManager.geolocationPosition { [self] in
                    await authorizer.getPermission(using: asyncLocationManager)
                }
            }
            session.locationTask = lookup
            let position = try await lookup.value
            guard documentSession === session, !Task.isCancelled else { return }
            sendPosition(position, positionId: positionId, session: session)
        } catch {
            guard documentSession === session, !Task.isCancelled else { return }
            stopUpdatingPosition()
            // If it's not PERMISSION_DENIED, the only other two options are POSITION_UNAVAILABLE
            // and TIMEOUT. Since we don't have any timeout handling yet, always fall back
            // to POSITION_UNAVAILABLE.
            sendError("getCurrentPosition", positionId: positionId, errorJson: positionUnavailableError, session: session)
        }
    }

    private func sendPosition(_ position: JSON, positionId: Int64, session: DocumentSession, messageName: String = "getCurrentPosition") {
        guard documentSession === session else { return }
        if messageName == "watchPosition", !session.watchRequests.contains(positionId) { return }
        let message: JSON = [
            "positionId": positionId,
            "position": position
        ]
        sendResponse(session, messageName: messageName, messageData: itmMessenger.jsonString(message).toBase64())
        if messageName == "getCurrentPosition" { session.positionRequests.remove(positionId) }
    }

    private func sendResponse(_ session: DocumentSession, messageName: String, messageData: String) {
        guard attached, documentSession === session, !webView.isLoading,
              let documentId = session.documentId, let url = webView.url,
              ITMBridgeOriginPolicy.origin(for: url) == session.origin else { return }
        webView.evaluateJavaScript("""
            if (window.Bentley_ITMGeolocationNativeSession === '\(session.id)' &&
                window.Bentley_ITMGeolocationDocumentId === '\(documentId)' &&
                typeof window.Bentley_ITMGeolocationResponse === 'function') {
                window.Bentley_ITMGeolocationResponse('\(messageName)', '\(messageData)', '\(session.id)', '\(documentId)');
            }
            """, completionHandler: nil)
    }

    private nonisolated func sendLocationUpdates() {
        Task {
            await sendLocationUpdates()
        }
    }

    private func sendLocationUpdates() async {
        guard isUpdatingPosition, let session = documentSession else { return }
        do {
            try await checkAuth()
            guard documentSession === session, isUpdatingPosition else { return }
            if let lastLocation = locationManager.location {
                var positionJson: JSON?
                do {
                    positionJson = try lastLocation.geolocationPosition(locationManager.heading?.trueHeading)
                } catch let ex {
                    ITMApplication.log(.error, "Error converting CLLocation to GeolocationPosition: \(ex)")
                    sendErrorToWatchers("watchPosition", errorJson: positionUnavailableError, session: session)
                }
                if let positionJson {
                    for positionId in watchIds {
                        sendPosition(positionJson, positionId: positionId, session: session, messageName: "watchPosition")
                    }
                }
            }
        } catch {
            guard documentSession === session else { return }
            sendErrorToWatchers("watchPosition", errorJson: notAuthorizedError, session: session)
        }
    }

    // MARK: CLLocationManagerDelegate

    /// `CLLocationManagerDelegate` function that reports location updates to the JavaScript side of the polyfill.
    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        sendLocationUpdates()
    }

    /// `CLLocationManagerDelegate` function that reports heading updates to the JavaScript side of the polyfill.
    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        sendLocationUpdates()
    }

    /// `CLLocationManagerDelegate` function that reports location errors to the JavaScript side of the polyfill.
    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let (domain, code) = { ($0.domain, $0.code) }(error as NSError)
        if code == CLError.locationUnknown.rawValue, domain == kCLErrorDomain {
            // Apple docs say you should just ignore this error
        } else {
            Task { @MainActor in
                guard let session = documentSession else { return }
                let errorJson: JSON
                stopUpdatingPosition()
                if code == CLError.denied.rawValue, domain == kCLErrorDomain {
                    errorJson = notAuthorizedError
                } else {
                    // If it's not PERMISSION_DENIED, the only other two options are POSITION_UNAVAILABLE
                    // and TIMEOUT. Since we don't have any timeout handling yet, always fall back
                    // to POSITION_UNAVAILABLE.
                    errorJson = positionUnavailableError
                }
                sendErrorToWatchers("watchPosition", errorJson: errorJson, session: session)
            }
        }
    }

    /// `CLLocationManagerDelegate` function that reports location to the JavaScript side of the polyfill when the authorization first comes through.
    public nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            if !watchIds.isEmpty {
                sendLocationUpdates()
            }
        }
    }
}
