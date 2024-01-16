/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import Foundation

/// Helper class to handler NotificationCenter observers that automatically remove themselves.
class ITMObservers {
    private var observers: [Any] = []

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Add an observer to the default notification center using `nil` for `object` and `queue`, recording the observer
    /// for removal in `deinit`.
    /// - Parameters:
    ///   - name: The name of the notification to observe.
    ///   - block: The block that executes when receiving a notification.
    func addObserver(
        forName name: NSNotification.Name?,
        using block: @escaping @Sendable (Notification) -> Void
    ) {
        observers.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil, using: block)
        )
    }
}
