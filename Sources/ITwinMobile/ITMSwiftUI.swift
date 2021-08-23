//---------------------------------------------------------------------------------------
//
//     $Source: FieldiOS/App/Utils/ITMApplication.swift $
//
//  $Copyright: (c) 2021 Bentley Systems, Incorporated. All rights reserved. $
//
//---------------------------------------------------------------------------------------

import SwiftUI

@available(iOS 13.0, *)
public struct ITMSwiftUIWebView: UIViewControllerRepresentable {
    public func makeUIViewController(context: Context) -> ITMViewController {
        return ITMViewController()
    }
    
    public func updateUIViewController(_ uiViewController: ITMViewController, context: Context) {
        //intentionally doing nothing here
    }
}

@available(iOS 13.0, *)
public struct ITMSwiftUIContentView: View {
    // wihtout this empty init, things wouldn't compile
    public init() {
    }
    public var body: some View {
        ITMSwiftUIWebView()
    }
}
