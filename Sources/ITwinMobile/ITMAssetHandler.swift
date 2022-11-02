/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import WebKit

/// Default asset handler for loading frontend resources.
public class ITMAssetHandler: NSObject, WKURLSchemeHandler {
    private let assetPath: String

    init(assetPath: String) {
        self.assetPath = assetPath
        super.init()
    }
    
    /// `WKURLSchemeHandler` protocol function.
    /// - Parameters:
    ///   - webView: The web view invoking the method.
    ///   - urlSchemeTask: The task that your app should start loading data for.
    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let fileUrl = getFileUrl(urlSchemeTask: urlSchemeTask)
        if fileUrl != nil {
            Self.respondWithDiskFile(urlSchemeTask: urlSchemeTask, fileUrl: fileUrl!)
        } else {
            Self.cancelWithFileNotFound(urlSchemeTask: urlSchemeTask)
        }
    }
    
    /// `WKURLSchemeHandler` protocol function.
    /// - Parameters:
    ///   - webView: The web view invoking the method.
    ///   - urlSchemeTask: The task that your app should stop handling.
    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    func getFileUrl(urlSchemeTask: WKURLSchemeTask) -> URL? {
        let assetFolderUrl = Bundle.main.resourceURL?.appendingPathComponent(assetPath)
        let url = urlSchemeTask.request.url!
        let fileUrl = assetFolderUrl?.appendingPathComponent(url.path)
        if FileManager.default.fileExists(atPath: (fileUrl?.path)!) {
            ITMApplication.logger.log(.info, "Loading: \(url.absoluteString)")
            return fileUrl
        }

        ITMApplication.logger.log(.error, "Not found: \(url)")
        return nil
    }
    
    /// Responds to the given file URL with the file contents.
    /// - Note: This loads the whole file into memory and then sends its data to the URL scheme task.
    /// - Parameters:
    ///   - urlSchemeTask: The `WKURLSchemeTask` that will receive the file data.
    ///   - fileUrl: The file URL to get the data from.
    open class func respondWithDiskFile(urlSchemeTask: WKURLSchemeTask, fileUrl: URL) {
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: fileUrl)
                let taskResponse: URLResponse
                taskResponse = HTTPURLResponse(url: urlSchemeTask.request.url!, mimeType: response.mimeType, expectedContentLength: Int(response.expectedContentLength), textEncodingName: response.textEncodingName)
                urlSchemeTask.didReceive(taskResponse)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                cancelWithFileNotFound(urlSchemeTask: urlSchemeTask)
            }
        }
    }
    
    /// Cancels the request in the `urlSchemeTask` with a "file not found" error.
    /// - Parameter urlSchemeTask: The `WKURLSchemeTask` object to send the error to.
    open class func cancelWithFileNotFound(urlSchemeTask: WKURLSchemeTask) {
        let taskResponse = URLResponse(url: urlSchemeTask.request.url!, mimeType: "text", expectedContentLength: -1, textEncodingName: "utf8")
        urlSchemeTask.didReceive(taskResponse)
        urlSchemeTask.didReceive(Data())
        urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist, userInfo: nil))
    }
}
