/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import WebKit

/// ``ITMNativeUIComponent`` that presents a `UIAlertController` with a style of `.actionSheet`.
/// This class is used by the `ActionSheet` TypeScript class in @itwin/mobile-core.
final public class ITMActionSheet: ITMNativeUIComponent {
    ///   - itmNativeUI: The ``ITMNativeUI`` used to present the action sheet.
    override init(itmNativeUI: ITMNativeUI) {
        super.init(itmNativeUI: itmNativeUI)
        queryHandler = itmMessenger.registerQueryHandler("Bentley_ITM_presentActionSheet", handleQuery)
    }

    private func handleQuery(params: [String: Any]) async throws -> String? {
        if self.viewController == nil {
            throw ITMError(json: ["message": "ITMActionSheet: no view controller"])
        }
        let alertActions = try ITMAlert.extractActions(params: params, errorPrefix: "ITMActionSheet")
        return await withCheckedContinuation({ (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.main .async {
                var actionSelected = false
                let alert = ITMAlertController(title: params["title"] as? String, message: params["message"] as? String, preferredStyle: .actionSheet)
                alert.showStatusBar = params["showStatusBar"] as? Bool ?? false
                alert.onClose = {
                    // When an action is selected, this gets called before the action's handler.
                    // By running async in the main event queue, we delay processing this until
                    // after the handler has had a chance to execute.
                    DispatchQueue.main.async {
                        if !actionSelected {
                            // If no action has been selected, then the user tapped outside the popover on
                            // an iPad. This cancels the action sheet.
                            continuation.resume(returning: nil)
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
                for action in alertActions {
                    alert.addAction(UIAlertAction(title: action.title, style: UIAlertAction.Style(action.style)) { _ in
                        actionSelected = true
                        continuation.resume(returning: action.name)
                    })
                }
                self.viewController?.present(alert, animated: true)
            }
        })
    }
}
