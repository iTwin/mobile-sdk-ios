//---------------------------------------------------------------------------------------
//
//     $Source: FieldiOS/App/Utils/ITMAlert.swift $
//
//  $Copyright: (c) 2021 Bentley Systems, Incorporated. All rights reserved. $
//
//---------------------------------------------------------------------------------------

import PromiseKit
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
    let style: String
}

// MARK: - ITMAlert class

class ITMAlert: ITMComponent {
    override init(viewController: UIViewController, itmMessenger: ITMMessenger) {
        super.init(viewController: viewController, itmMessenger: itmMessenger)
        queryHandler = itmMessenger.registerQueryHandler("Bentley_ITM_presentAlert", handleQuery)
    }

    private func handleQuery(params: [String: Any]) -> Promise<String> {
        let presentedPromise: Promise<String>
        let presentedResolver: Resolver<String>
        (presentedPromise, presentedResolver) = Promise<String>.pending()
        if viewController == nil {
            presentedResolver.reject(ITMError())
        } else {
            if let actions = params["actions"] as? [[String: Any]] {
                let alert = ITMAlertController(title: params["title"] as? String, message: params["message"] as? String, preferredStyle: .alert)
                if actions.isEmpty {
                    presentedResolver.reject(ITMError())
                } else {
                    for actionDict in actions {
                        if let action: ITMAlertAction = try? ITMDictionaryDecoder.decode(actionDict),
                            let actionStyle = ITMAlertActionStyle(rawValue: action.style) {
                            alert.addAction(UIAlertAction(title: action.title, style: UIAlertAction.Style(actionStyle)) { _ in
                                presentedResolver.fulfill(action.name)
                            })
                        }
                    }
                    alert.modalPresentationCapturesStatusBarAppearance = true
                    viewController?.present(alert, animated: true, completion: nil)
                }
            } else {
                presentedResolver.reject(ITMError())
            }
        }
        return presentedPromise
    }
}
