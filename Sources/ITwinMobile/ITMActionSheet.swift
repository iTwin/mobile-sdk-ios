/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import WebKit

/// ``ITMNativeUIComponent`` that presents a `UIAlertController` with a style of `.actionSheet`.
/// This class is used by the `ActionSheet` TypeScript class in @itwin/mobile-core.
final public class ITMActionSheet: ITMNativeUIComponent {
    var activeContinuation: CheckedContinuation<String?, Never>? = nil
    ///   - itmNativeUI: The ``ITMNativeUI`` used to present the action sheet.
    override init(itmNativeUI: ITMNativeUI) {
        super.init(itmNativeUI: itmNativeUI)
        queryHandler = itmMessenger.registerQueryHandler("Bentley_ITM_presentActionSheet", handleQuery)
    }

    private func resume(returning value: String?) {
        activeContinuation?.resume(returning: value)
        activeContinuation = nil
    }

    private func handleQuery(params: [String: Any]) async throws -> String? {
        guard let viewController = self.viewController else {
            throw ITMError(json: ["message": "ITMActionSheet: no view controller"])
        }
        let alertActions = try ITMAlert.extractActions(params: params, errorPrefix: "ITMActionSheet")
        // It shouldn't be possible to get here with activeContinuation non-nil, but trigger a cancel of
        // any previous continuation just in case.
        resume(returning: nil)
        return await withCheckedContinuation({ (continuation: CheckedContinuation<String?, Never>) in
            self.activeContinuation = continuation
            DispatchQueue.main.async {
                let alert = ITMAlertController(title: params["title"] as? String, message: params["message"] as? String, preferredStyle: .actionSheet)
                alert.showStatusBar = params["showStatusBar"] as? Bool ?? false
                alert.onClose = {
                    // When an action is selected, this gets called before the action's handler.
                    // By running async in the main event queue, we delay processing this until
                    // after the handler has had a chance to execute.
                    DispatchQueue.main.async {
                        // If no action has been selected, then the user tapped outside the popover on
                        // an iPad, OR an orientation change or window resize trigerred a cancel. This
                        // cancels the action sheet without calling any of the actions. When the action
                        // is selected, it sets self.activeContinuation to nil, which makes this do nothing.
                        self.resume(returning: nil)
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
                        self.resume(returning: action.name)
                    })
                }
                viewController.present(alert, animated: true)
            }
        })
    }
}
