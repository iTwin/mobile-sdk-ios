/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import WebKit

// MARK: - Helper classes and extensions for converting the data that comes from WKWebView

/// Type to map between JavaScript and `UIAlertAction.Style`.
public enum ITMAlertActionStyle: String, Codable, Equatable {
    case `default` = "default"
    case cancel = "cancel"
    case destructive = "destructive"
}

extension UIAlertAction.Style {
    init(_ style: ITMAlertActionStyle) {
        switch style {
        case .default:
            self = .default
        case .cancel:
            self = .cancel
        case .destructive:
            self = .destructive
        }
    }
}

/// Swift class that holds data passed from JavaScript for each action in an ``ITMAlert`` and ``ITMActionSheet``.
public struct ITMAlertAction: Codable, Equatable {
    /// The name of the action, passed back to JavaScript when the user selects it.
    let name: String
    /// The title of the action.
    /// - Note: UIAlertAction's title is in theory optional. However, if the title is missing when used in an action sheet
    /// on an iPad, it will ALWAYS throw an exception. So title here is not optional.
    let title: String
    /// The style of the action.
    let style: ITMAlertActionStyle

    /// Create an array of ``ITMAlertAction`` values from the given JSON data passed from JavaScript.
    /// - Parameters:
    ///   - params: The JSON data passed from JavaScript. This must contain an `actions` array property
    ///   containing the individual alert actions.
    ///   - errorPrefix: The prefix to use in any error thrown if `params` contains invalid data.
    /// - Returns: An array of ``ITMAlertAction`` values based on the data in `params`.
    static func createArray(from params: JSON, errorPrefix: String) throws -> [ITMAlertAction] {
        guard let actions = params["actions"] as? [JSON], !actions.isEmpty else {
            throw ITMError(json: ["message": "\(errorPrefix): actions must be present and not empty"])
        }
        do {
            return try actions.map { try ITMDictionaryDecoder.decode($0) }
        } catch {
            throw ITMError(json: ["message": "\(errorPrefix): invalid actions"])
        }
    }

    /// Adds the given array of ``ITMAlertAction`` values to the given `UIAlertController`.
    /// - Parameters:
    ///   - actions: The actions to add to the alert controller.
    ///   - alertController: The `UIAlertController` to add the actions to.
    ///   - handler: The handler that is called when an action is selected by the `UIAlertController`.
    @MainActor
    static func add(actions: [ITMAlertAction], to alertController: UIAlertController, handler: ((ITMAlertAction) -> Void)? = nil) {
        for action in actions {
            alertController.addAction(UIAlertAction(title: action.title, style: UIAlertAction.Style(action.style)) { _ in
                handler?(action)
            })
        }
    }
}

// MARK: - ITMAlert class

/// ``ITMNativeUIComponent`` that presents a `UIAlertController` with a style of `.alert`.
/// This class is used by the `presentAlert` TypeScript function in @itwin/mobile-core.
final public class ITMAlert: ITMNativeUIComponent {
    private var activeContinuation: CheckedContinuation<String?, Never>? = nil
    /// Creates an ``ITMAlert``.
    /// - Parameter itmNativeUI: The ``ITMNativeUI`` used to present the alert.
    override init(itmNativeUI: ITMNativeUI) {
        super.init(itmNativeUI: itmNativeUI)
        queryHandler = itmMessenger.registerQueryHandler("Bentley_ITM_presentAlert", handleQuery)
    }

    private func resume(returning value: String?) {
        activeContinuation?.resume(returning: value)
        activeContinuation = nil
    }

    @MainActor
    private func handleQuery(params: JSON) async throws -> String? {
        guard let viewController else {
            throw ITMError(json: ["message": "ITMAlert: no view controller"])
        }
        let alertActions = try ITMAlertAction.createArray(from: params, errorPrefix: "ITMAlert")
        // If a previous query hasn't fully resolved yet, resolve it now with nil.
        resume(returning: nil)
        return await withCheckedContinuation { continuation in
            activeContinuation = continuation
            let alert = ITMAlertController(title: params["title"] as? String, message: params["message"] as? String, preferredStyle: .alert)
            alert.showStatusBar = params["showStatusBar"] as? Bool ?? false
            ITMAlertAction.add(actions: alertActions, to: alert) { action in
                self.resume(returning: action.name)
            }
            alert.onDeinit = {
                DispatchQueue.main.async {
                    self.resume(returning: nil)
                }
            }
            alert.modalPresentationCapturesStatusBarAppearance = true
            viewController.present(alert, animated: true)
        }
    }
}
