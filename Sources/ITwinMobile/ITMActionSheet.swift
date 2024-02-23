/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import WebKit

/// ``ITMNativeUIComponent`` that presents a `UIAlertController` with a style of `.actionSheet`.
/// This class is used by the `presentActionSheet` TypeScript function in @itwin/mobile-core as well as
/// the `ActionSheetButton` TypeScript React Component in @itwin/mobile-ui-react.
final public class ITMActionSheet: ITMNativeUIComponent {
    private var activeContinuation: CheckedContinuation<String?, Never>? = nil
    /// Creates an ``ITMActionSheet``.
    /// - Parameter itmNativeUI: The ``ITMNativeUI`` used to present the action sheet.
    override init(itmNativeUI: ITMNativeUI) {
        super.init(itmNativeUI: itmNativeUI)
        queryHandler = itmMessenger.registerQueryHandler("Bentley_ITM_presentActionSheet", handleQuery)
    }

    private func resume(returning value: String?) {
        activeContinuation?.resume(returning: value)
        activeContinuation = nil
    }

    /// Try to convert the `sourceRect` property of `params` into an ``ITMRect``.
    /// - Parameter params: JSON data from the web app.
    /// - Throws: If `params` does not contain a `sourceRect` property that can be converted to an ``ITMRect``,
    /// an exception is thrown.
    /// - Returns: The contents of the `sourceRect` property in `params` converted to an ``ITMRect``.
    public static func getSourceRect(from params: JSON) throws -> ITMRect {
        guard let sourceRectDict = params["sourceRect"] as? JSON,
              let sourceRect: ITMRect = try? ITMDictionaryDecoder.decode(sourceRectDict) else {
            throw ITMError(json: ["message": "ITMActionSheet: no source rect"])
        }
        return sourceRect
    }

    @MainActor
    private func handleQuery(params: JSON) async throws -> String? {
        guard let viewController = viewController else {
            throw ITMError(json: ["message": "ITMActionSheet: no view controller"])
        }
        let alertActions = try ITMAlertAction.createArray(from: params, errorPrefix: "ITMActionSheet")
        let sourceRect = try Self.getSourceRect(from: params)
        // If a previous query hasn't fully resolved yet, resolve it now with nil.
        resume(returning: nil)
        return await withCheckedContinuation { continuation in
            activeContinuation = continuation
            let alert = ITMAlertController(title: params["title"] as? String, message: params["message"] as? String, preferredStyle: .actionSheet)
            alert.showStatusBar = params["showStatusBar"] as? Bool ?? false
            alert.onDeinit = {
                // When an action is selected, this gets called before the action's handler.
                // By running async in the main event queue, we delay processing this until
                // after the handler has had a chance to execute.
                // NOTE: Task { @MainActor won't work below, because we're already on the UI thread when
                // we get here; using DispatchQueue.main.async forces the code inside to run later.
                DispatchQueue.main.async { [self] in
                    // If no action has been selected, then the user tapped outside the popover on
                    // an iPad, OR an orientation change or window resize trigerred a cancel. This
                    // cancels the action sheet without calling any of the actions. When the action
                    // is selected, it sets activeContinuation to nil, which makes this do nothing.
                    resume(returning: nil)
                }
            }
            alert.onClose = alert.onDeinit
            alert.popoverPresentationController?.sourceView = itmMessenger.webView
            alert.popoverPresentationController?.sourceRect = CGRect(sourceRect)
            ITMAlertAction.add(actions: alertActions, to: alert) { [self] action in
                resume(returning: action.name)
            }
            viewController.present(alert, animated: true)
        }
    }
}
