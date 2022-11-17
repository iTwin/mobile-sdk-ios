/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import WebKit

// MARK: - Helper classes and extensions for converting the data that comes from WKWebView

/// Decodes JSON dictionary into a compatible struct.
///
/// See ``ITMRect`` for example usage.
public class ITMDictionaryDecoder<T: Decodable> {
    public static func decode(_ d: [String: Any]) throws -> T {
        let jsonData = try JSONSerialization.data(withJSONObject: d, options: .prettyPrinted)
        return try JSONDecoder().decode(T.self, from: jsonData)
    }
}

/// Struct for converting between JSON dictionary and Swift representing a rectangle.
///
/// You can use ``ITMDictionaryDecoder`` to decode dictionary data to create an ``ITMRect``, and then
/// use a custom `init` on `CGRect` to convert that to a CGRect:
///
/// ```swift
/// if let sourceRectDict = params["sourceRect"] as? [String: Any],
///    let sourceRect: ITMRect = try? ITMDictionaryDecoder.decode(sourceRectDict) {
///     alert.popoverPresentationController?.sourceRect = CGRect(sourceRect)
/// }
/// ```
public struct ITMRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// CGRect extension to initialize a CGRect from an ``ITMRect``.
public extension CGRect {
    /// Create a CGRect from an ``ITMRect``.
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
    /// The `UIViewController` that components display in.
    public weak var viewController: UIViewController?
    /// The ``ITMMessenger`` that sends messages to components, and optionally receives messages.
    public var itmMessenger: ITMMessenger
    
    /// - Parameters:
    ///   - viewController: The `UIViewController` to display the native UI components in.
    ///   - itmMessenger: The ``ITMMessenger`` to communicate with the iTwin Mobile app's frontend.
    public init(viewController: UIViewController, itmMessenger: ITMMessenger) {
        self.viewController = viewController
        self.itmMessenger = itmMessenger
        components.append(ITMActionSheet(itmNativeUI: self))
        components.append(ITMAlert(itmNativeUI: self))
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

// MARK: - ITMNativeUI class

/// Base class for all UI components in ``ITMNativeUI``.
open class ITMNativeUIComponent: NSObject {
    /// The ``ITMNativeUI`` used to present the component.
    public let itmNativeUI: ITMNativeUI
    /// The query handler handling messages from the iTwin Mobile app frontend.
    public var queryHandler: ITMQueryHandler?

    /// - Parameters:
    ///   - itmNativeUI: The ``ITMNativeUI`` used to present the component.
    public init(itmNativeUI: ITMNativeUI) {
        self.itmNativeUI = itmNativeUI
        super.init()
    }

    /// Detach this component from its ``ITMMessenger``.
    public func detach() {
        if let queryHandler = queryHandler {
            itmMessenger.unregisterQueryHandler(queryHandler)
            self.queryHandler = nil
        }
    }
    
    /// The `UIViewController` for this component; this comes from ``itmNativeUI``.
    public var viewController: UIViewController? {
        itmNativeUI.viewController
    }
    
    /// The ``ITMMessenger`` this component uses to communicate with the iTwin Mobile app's frontend; this comes from ``itmNativeUI``.
    public var itmMessenger: ITMMessenger {
        itmNativeUI.itmMessenger
    }
}
