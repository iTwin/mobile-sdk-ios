/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import PromiseKit
import UIKit
import WebKit

// MARK: - Helper classes and extensions for converting the data that comes from WKWebView
class ITMDictionaryDecoder<T: Decodable> {
    static func decode(_ d: [String: Any]) throws -> T {
        let jsonData = try JSONSerialization.data(withJSONObject: d, options: .prettyPrinted)
        return try JSONDecoder().decode(T.self, from: jsonData)
    }
}


struct ITMRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

extension CGRect {
    init(_ alertRect: ITMRect) {
        // NOTE: Even though CGFloat is Float on 32-bit hardware, CGPoint and CGSize both have overridden initializers
        // that explicitly take Double.
        self.init(
            origin: CGPoint(x: alertRect.x, y: alertRect.y),
            size: CGSize(width: alertRect.width, height: alertRect.height)
        )
    }
}

// MARK: - ITMNativeUI class

/// Container class for all ``ITMNativeUIComponent`` objects.
open class ITMNativeUI {
    private var components: [ITMNativeUIComponent] = []
    
    /// - Parameters:
    ///   - viewController: The `UIViewController` to display the native UI components in.
    ///   - itmMessenger: The ``ITMMessenger`` to communicate with the iTwin Mobile app's frontend.
    public init(viewController: UIViewController, itmMessenger: ITMMessenger) {
        components.append(ITMActionSheet(viewController: viewController, itmMessenger: itmMessenger))
        components.append(ITMAlert(viewController: viewController, itmMessenger: itmMessenger))
//        components.append(ITMDatePicker(viewController: viewController, itmMessenger: itmMessenger))
    }

    /// Add a component to the ``ITMNativeUI``.
    /// - Parameter component: The ``ITMNativeUIComponent`` to add to the ``ITMNativeUI``.
    public func addComponent(_ component: ITMNativeUIComponent) {
        components.append(component)
    }

    /// Detach all components from the ``ITMMessenger``.
    public func detach() {
        for component in components {
            component.detach()
        }
    }
}

/// Base class for all UI components in ``ITMNativeUI``.
open class ITMNativeUIComponent: NSObject {
    /// The query handler handling messages from the iTwin Mobile app frontend.
    public var queryHandler: ITMQueryHandler?
    /// The ``ITMMessenger`` that sends messages to this component, and optionally receives messages.
    public var itmMessenger: ITMMessenger
    /// The `UIViewController` that this component displays in.
    public weak var viewController: UIViewController?

    /// - Parameters:
    ///   - viewController: The `UIViewController` that this component displays in.
    ///   - itmMessenger: The ``ITMMessenger`` that sends messages to this component, and optionally receives messages.
    public init(viewController: UIViewController, itmMessenger: ITMMessenger) {
        self.viewController = viewController
        self.itmMessenger = itmMessenger
        super.init()
    }

    /// Detach this component from its ``ITMMessenger``.
    public func detach() {
        if let queryHandler = queryHandler {
            itmMessenger.unregisterQueryHandler(queryHandler)
            self.queryHandler = nil
        }
    }
}
