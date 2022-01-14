/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import SwiftUI

public struct ITMSwiftUIWebView: UIViewControllerRepresentable {
    public var application: ITMApplication
    public func makeUIViewController(context: Context) -> ITMViewController {
        ITMViewController.application = application
        return ITMViewController()
    }
    
    public func updateUIViewController(_ uiViewController: ITMViewController, context: Context) {
        // intentionally doing nothing here
    }
}

public struct ITMSwiftUIContentView: View {
    public var application: ITMApplication
    
    public init(application: ITMApplication) {
        self.application = application
    }
    public var body: some View {
        ITMSwiftUIWebView(application: application)
    }
}
