/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import SwiftUI

/// Helper struct for using ITMViewController from Swift UI
public struct ITMSwiftUIWebView: UIViewControllerRepresentable {
    /// The ``ITMApplication`` that this Swift UI WebView is attached to.
    public var application: ITMApplication

    /// Creates a `UIViewController` for this `UIViewControllerRepresentable`.
    /// - Parameter context: The `UIViewControllerRepresentableContext` for this ``ITMSwiftUIWebView``
    /// - Returns: An ``ITMViewController`` with the appropritate ``ITMApplication``.
    public func makeUIViewController(context: Context) -> ITMViewController {
        ITMViewController.application = application
        return ITMViewController()
    }

    /// Intentionally does nothing, since ``ITMViewController`` does not accept data from Swift UI.
    public func updateUIViewController(_ uiViewController: ITMViewController, context: Context) {
        // intentionally doing nothing here
    }
}

/// Swift UI wrapper for an ``ITMSwiftUIWebView``.
public struct ITMSwiftUIContentView: View {
    /// The ``ITMApplication`` that this Swift UI WebView is attached to.
    public var application: ITMApplication

    public init(application: ITMApplication) {
        self.application = application
    }
    public var body: some View {
        ITMSwiftUIWebView(application: application)
    }
}
