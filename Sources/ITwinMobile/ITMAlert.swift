/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import WebKit

// MARK: - Helper classes and extensions for converting the data that comes from WKWebView

enum ITMAlertActionStyle: String, Codable, Equatable {
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

struct ITMAlertAction: Codable, Equatable {
    let name: String
    // Note: UIAlertAction's title is in theory optional. However, if the title is missing when used in an action sheet
    // on an iPad, it will ALWAYS throw an exception. So title here is not optional.
    let title: String
    let style: ITMAlertActionStyle
}

// MARK: - ITMAlert class

/// ``ITMNativeUIComponent`` that presents a `UIAlertController` with a style of `.alert`.
/// This class is used by the `presentAlert` TypeScript function in @itwin/mobile-core.
final public class ITMAlert: ITMNativeUIComponent {
    ///   - itmNativeUI: The ``ITMNativeUI`` used to present the alert.
    override init(itmNativeUI: ITMNativeUI) {
        super.init(itmNativeUI: itmNativeUI)
        queryHandler = itmMessenger.registerQueryHandler("Bentley_ITM_presentAlert", handleQuery)
    }

    static func extractActions(params: [String: Any], errorPrefix: String) throws -> [ITMAlertAction] {
        guard let actions = params["actions"] as? [[String: Any]], !actions.isEmpty else {
            throw ITMError(json: ["message": "\(errorPrefix): actions must be present and not empty"])
        }
        var alertActions: [ITMAlertAction] = []
        for actionDict in actions {
            if let action: ITMAlertAction = try? ITMDictionaryDecoder.decode(actionDict) {
                alertActions.append(action)
            } else {
                throw ITMError(json: ["message": "\(errorPrefix): invalid action"])
            }
        }
        return alertActions
    }

    private func handleQuery(params: [String: Any]) async throws -> String {
        guard let viewController = viewController else {
            throw ITMError(json: ["message": "ITMAlert: no view controller"])
        }
        let alertActions = try ITMAlert.extractActions(params: params, errorPrefix: "ITMAlert")
        return await withCheckedContinuation({ (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.main.async {
                let alert = ITMAlertController(title: params["title"] as? String, message: params["message"] as? String, preferredStyle: .alert)
                alert.showStatusBar = params["showStatusBar"] as? Bool ?? false
                for action in alertActions {
                    alert.addAction(UIAlertAction(title: action.title, style: UIAlertAction.Style(action.style)) { _ in
                        continuation.resume(returning: action.name)
                    })
                }
                alert.modalPresentationCapturesStatusBarAppearance = true
                viewController.present(alert, animated: true, completion: nil)
            }
        })
    }
}
