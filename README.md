# iTwin mobile-sdk-ios

Copyright © Bentley Systems, Incorporated. All rights reserved. See [LICENSE.md](./LICENSE.md) for license terms and full copyright notice.

## Warning

This is pre-release software and provided as-is.

## About this Repository

This repository contains the Swift code used to build [iTwin.js](http://www.itwinjs.org) applications on iOS devices. This package requires iOS/iPadOS 13 or later.

## Setup

This package is delivered as source-only and supports two options for dependency management.

### Swift Package Manager

With [Swift Package Manager](https://swift.org/package-manager), add `https://github.com/iTwin/mobile-sdk-ios` to your project's Package Dependencies settings in Xcode, making sure to set the "Dependency Rule" to "Exact Version" and the version to "0.32.10".

Or add the following package to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(name: "itwin-mobile-sdk", url: "https://github.com/iTwin/mobile-sdk-ios", .exact("0.32.10"))
]
```

### CocoaPods

With [CocoaPods](https://guides.cocoapods.org/using/getting-started.html), add `itwin-mobile-native`, `itwin-mobile-sdk`, and `AsyncLocationKit` to your `Podfile`. __Note:__ these are not hosted on the CocoaPods CDN so the correct URLs must be specified. Also, AsyncLocationKit does not have a podspec, so one is included as part of the `mobile-sdk-ios` release.

It is also necessary to disable bitcode for the itwin projects, which can be done via a `post_install` function.

```ruby
project 'MyMobileApp.xcodeproj/'

# Uncomment the next line to define a global platform for your project
# platform :ios, '9.0'

target 'MyMobileApp' do
  # Comment the next line if you don't want to use dynamic frameworks
  use_frameworks!

  # Pods for MyMobileApp
  pod 'itwin-mobile-native', podspec: 'https://github.com/iTwin/mobile-native-ios/releases/download/5.15.40/itwin-mobile-native-ios.podspec'
  pod 'itwin-mobile-sdk', podspec: 'https://github.com/iTwin/mobile-sdk-ios/releases/download/0.32.10/itwin-mobile-sdk.podspec'
  pod 'AsyncLocationKit', podspec: 'https://github.com/iTwin/mobile-sdk-ios/releases/download/0.32.10/AsyncLocationKit.podspec'
end

post_install do |installer|
  installer.generated_projects.each do |project|
    project.targets.each do |target|
      target.build_configurations.each do |config|
        # Disables bitcode for the itwin pods
        if target.name.start_with?("itwin-mobile-")
          config.build_settings['ENABLE_BITCODE'] = 'NO'
        end
      end
    end
  end
end
```

## WebView Bridge Origins

`ITMApplication.getBridgeAllowedOrigins()` configures trusted origins for native WebView bridges.
The packaged frontend origin, `imodeljs://app`, and any HTTP(S) origin returned by `getBaseUrl()` are
trusted by default. This includes remote frontends configured through `ITMAPPLICATION_BASE_URL`
or a `getBaseUrl()` override. Invalid or unsupported URLs add no origin.
Override this policy in your application subclass to authorize additional origins:

```swift
override func getBridgeAllowedOrigins() -> Set<String> {
  super.getBridgeAllowedOrigins().union(["https://frontend.example.com"])
}
```

Use exact origins without paths, credentials, wildcards, or default ports. Development origins
should only be added in development builds. Standalone loggers accept an explicit origin set;
`ITMBridgeOriginPolicy` provides shared defaults and origin validation. This policy controls
console forwarding, geolocation, and frontend messaging.

### Loading bundled pages without `file://`

The files can stay on disk; what matters is the URL the WebView loads. The bridge checks
the sending frame's origin, which does not identify a particular file or directory.
Adding a file path to `allowedOrigins` or widening `loadFileURL`'s read access does not
authorize the page.

If you use `ITMApplication`'s packaged frontend, no migration is needed: the SDK already
serves it at `imodeljs://app/index.html`. For a standalone WebView that currently calls
`loadFileURL`, register a `WKURLSchemeHandler` **before creating the WebView**, then load
the entry page through that scheme:

```swift
let configuration = WKWebViewConfiguration()
configuration.setURLSchemeHandler(FormsAssetHandler(), forURLScheme: "formswebapp")
let webView = WKWebView(frame: .zero, configuration: configuration)
let messenger = ITMMessenger(webView, allowedOrigins: ["formswebapp://app"])
webView.load(URLRequest(url: URL(string: "formswebapp://app/index.html")!))
```

Keep the messenger for the lifetime of the view. The allowlist entry is the **origin**
(`formswebapp://app`), not the entry page URL or the scheme alone.

For example, package `index.html`, `main.js`, and `styles.css` in a `FormsWebApp`
directory in the app bundle. Reference the script and stylesheet from the HTML as
`./main.js` and `./styles.css`. This handler maps only those requests to bundled files;
add an entry for each additional asset your forms page needs.

```swift
import ITwinMobile
import WebKit

final class FormsAssetHandler: NSObject, WKURLSchemeHandler {
    private let assets = [
        "/index.html": (file: "index.html", mime: "text/html"),
        "/main.js": (file: "main.js", mime: "text/javascript"),
        "/styles.css": (file: "styles.css", mime: "text/css"),
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              ITMBridgeOriginPolicy.origin(for: url) == "formswebapp://app",
              let asset = assets[url.path],
              let file = Bundle.main.url(forResource: asset.file, withExtension: nil,
                                         subdirectory: "FormsWebApp") else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        do {
            let data = try Data(contentsOf: file)
            task.didReceive(URLResponse(url: url, mimeType: asset.mime,
                                        expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // These small bundled assets are read synchronously; there is no pending work to cancel.
    }
}
```

### Frontend messaging

`ITMMessenger` requires a session-aware `@itwin/mobile-sdk-core` frontend.

The native transport authenticates the WebView, main frame, exact origin, and document session
before dispatch. Responses are delivered only to the authenticated document.
Navigation, detach, replacement, and process termination settle pending
work and reset readiness. Late handlers cannot respond to reused IDs in a replacement document.
If a provisional navigation is cancelled and the launched document survives, reauthentication
restores its launch readiness without restoring discarded queries.
There are at most 128 pending queries per direction and 100 incoming native-handler queries per second.

For standalone messengers, call `attach(webView, allowedOrigins: origins)` before loading and
`detach()` before destroying or replacing the WebView. Loading observation invalidates sessions
independently of application delegate overrides. Forward WebKit process termination to
`onPageStarted(webView)` before reloading. `ITMApplication` provides this integration.
Missing session-aware frontend support produces a native diagnostic; requests without a current
document session are rejected.
Core may initialize asynchronously after page load. Bootstrap evaluation errors fail launch
waiters; call `initFrontendLaunch()` before retrying frontend startup.

Run the real-WebKit messenger tests from the package directory with
`xcodebuild -scheme itwin-mobile-sdk -destination 'platform=iOS Simulator,name=<installed simulator>' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test`,
substituting an installed simulator name. The test target and its local fixtures are separate
from the production library.

### Geolocation

Geolocation requires a session-aware `@itwin/mobile-sdk-core` frontend. The native bridge accepts
requests only within the authorized document session.

Use the `navigator.geolocation` callback API to request locations and manage watches.
`watchPosition()` returns its ID synchronously. `clearWatch()` removes its callbacks
immediately and enqueues native cancellation, returning `undefined`. Navigation and detach cancel
the document's watches and lookups; late responses are suppressed.

For standalone managers, call `attach(webView, allowedOrigins: origins)` before loading the
frontend and `detach()` when replacing or destroying the WebView. Loading observation invalidates
sessions independently of application navigation delegate overrides. `ITMApplication` also
forwards navigation and WebKit process-termination events to the manager.

## Notes
- This package is designed to be used with the [@itwin/mobile-sdk-core](https://github.com/iTwin/mobile-sdk-core) and [@itwin/mobile-ui-react](https://github.com/iTwin/mobile-ui-react) packages. Those two packages are intended to be installed via npm, and their version number must match the version number of this package. Furthermore, they use __iTwin.js 5.15.0__, and your app must use that same version of iTwin.js.

- If you are using this package via CocoaPods, make sure to set the `itwin-mobile-native` CocoaPod to version 5.15.40

- You may get a warning from AppAuth's OIDExternalUserAgentIOS.h when you build any project that includes this as a Swift Package. Unfortunately, there is no way that we know of to disable that warning. It can be ignored, though.
