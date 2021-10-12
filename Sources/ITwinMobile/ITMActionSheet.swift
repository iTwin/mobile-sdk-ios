/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import PromiseKit
import UIKit
import WebKit

/// ``ITMNativeUIComponent`` that presents a `UIAlertController` with a style of `.actionSheet`.
/// This class is used by the `ActionSheet` TypeScript class in @itwin/mobile-core.
final public class ITMActionSheet: ITMNativeUIComponent {
    override init(viewController: UIViewController, itmMessenger: ITMMessenger) {
        super.init(viewController: viewController, itmMessenger: itmMessenger)
        queryHandler = itmMessenger.registerQueryHandler("Bentley_ITM_presentActionSheet") { (params: [String: Any]) -> Promise<String?> in
            if self.viewController == nil {
                return Promise.value(nil)
            }
            let (presentedPromise, presentedResolver) = Promise<String?>.pending()
            if let actions = params["actions"] as? [[String: Any]] {
                var actionSelected = false
                let alert = ITMAlertController(title: params["title"] as? String, message: params["message"] as? String, preferredStyle: .actionSheet)
                alert.onClose = {
                    // When an action is selected, this gets called before the action's handler.
                    // By running async in the main event queue, we delay processing this until
                    // after the handler has had a chance to execute.
                    DispatchQueue.main.async {
                        if !actionSelected {
                            // If no action has been selected, then the user tapped outside the popover on
                            // an iPad. This cancels the action sheet.
                            presentedResolver.fulfill(nil)
                        }
                    }
                }
                alert.popoverPresentationController?.sourceView = self.itmMessenger.webView
                if let sourceRectDict = params["sourceRect"] as? [String: Any],
                    let sourceRect: ITMRect = try? ITMDictionaryDecoder.decode(sourceRectDict) {
                    alert.popoverPresentationController?.sourceRect = CGRect(sourceRect)
                } else {
                    // We shouldn't ever get here, but a 0,0 popover is better than an unhandled exception.
                    assert(false)
                    alert.popoverPresentationController?.sourceRect = CGRect()
                }
                for actionDict in actions {
                    if let action: ITMAlertAction = try? ITMDictionaryDecoder.decode(actionDict),
                        let actionStyle = ITMAlertActionStyle(rawValue: action.style) {
                        alert.addAction(UIAlertAction(title: action.title, style: UIAlertAction.Style(actionStyle)) { _ in
                            actionSelected = true
                            presentedResolver.fulfill(action.name)
                        })
                    }
                }
                self.viewController?.present(alert, animated: true)
            }
            return presentedPromise
        }
    }
}
