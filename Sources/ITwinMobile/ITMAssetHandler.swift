/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import UIKit
import WebKit

/// Default asset handler for loading frontend resources.
final public class ITMAssetHandler: NSObject, WKURLSchemeHandler {
    private let assetPath: String

    init(assetPath: String) {
        self.assetPath = assetPath
        super.init()
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let fileUrl = getFileUrl(urlSchemeTask: urlSchemeTask)
        if fileUrl != nil {
            respondWithDiskFile(urlSchemeTask: urlSchemeTask, fileUrl: fileUrl!)
        } else if canHandle(url: urlSchemeTask.request.url! as NSURL) {
            handle(urlSchemeTask: urlSchemeTask)
        } else {
            cancelWithFileNotFound(urlSchemeTask: urlSchemeTask)
        }
    }

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

    func respondWithDiskFile(urlSchemeTask: WKURLSchemeTask, fileUrl: URL) {
        URLSession.shared.dataTask(with: fileUrl) { data, response, error in
            if error != nil {
                // cancel
                return
            }
            let taskResponse: URLResponse
            if #available(iOS 13, *) {
                taskResponse = HTTPURLResponse(url: urlSchemeTask.request.url!, mimeType: response?.mimeType, expectedContentLength: Int(response?.expectedContentLength ?? 0), textEncodingName: response?.textEncodingName)
            } else {
                // The HTTPURLResponse object created above using the URLResponse constructor crashes when sent to
                // urlSchemeTask.didReceive below in iOS 12. I have no idea why that is, but it DOESN'T crash if we
                // instead use the HTTPURLResponse-only constructor. Similarly, it doesn't crash if we create a
                // URLResponse object instead of an HTTPURLResponse object. So, if we know the mimeType, construct an
                // HTTPURLResponse using the HTTPURLResponse constructor, and add the appropriate header field for that
                // mime type. If we don't know the mime type, construct a URLResponse instead.
                if let mimeType = response?.mimeType {
                    // The imodeljs code that loads approximateTerrainHeights.json requires the HTTP Content-Type header
                    // to be present and accurate. URLResponse doesn't have any headers. I have no idea how the
                    // HTTPURLResponse contstructor could fail, but just in case it does, we fall back to the
                    // URLResponse object.
                    taskResponse = HTTPURLResponse(url: urlSchemeTask.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "\(mimeType); charset=UTF-8"]) ?? URLResponse(url: urlSchemeTask.request.url!, mimeType: response?.mimeType, expectedContentLength: Int(response?.expectedContentLength ?? 0), textEncodingName: response?.textEncodingName)
                } else {
                    taskResponse = URLResponse(url: urlSchemeTask.request.url!, mimeType: response?.mimeType, expectedContentLength: Int(response?.expectedContentLength ?? 0), textEncodingName: response?.textEncodingName)
                }
            }
            urlSchemeTask.didReceive(taskResponse)
            urlSchemeTask.didReceive(data!)
            urlSchemeTask.didFinish()
        }.resume()
    }

    func canHandle(url: NSURL) -> Bool {
        return false
    }

    func handle(urlSchemeTask: WKURLSchemeTask) {}

    func cancelWithFileNotFound(urlSchemeTask: WKURLSchemeTask) {
        let taskResponse = URLResponse(url: urlSchemeTask.request.url!, mimeType: "text", expectedContentLength: -1, textEncodingName: "utf8")
        urlSchemeTask.didReceive(taskResponse)
        urlSchemeTask.didReceive(Data())
        urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist, userInfo: nil))
    }
}
