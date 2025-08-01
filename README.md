# iTwin mobile-sdk-ios

Copyright © Bentley Systems, Incorporated. All rights reserved. See [LICENSE.md](./LICENSE.md) for license terms and full copyright notice.

## Warning

This is pre-release software and provided as-is.

## About this Repository

This repository contains the Swift code used to build [iTwin.js](http://www.itwinjs.org) applications on iOS devices. This package requires iOS/iPadOS 13 or later.

## Setup

This package is delivered as source-only and supports two options for dependency management.

### Swift Package Manager

With [Swift Package Manager](https://swift.org/package-manager), add `https://github.com/iTwin/mobile-sdk-ios` to your project's Package Dependencies settings in Xcode, making sure to set the "Dependency Rule" to "Exact Version" and the version to "0.24.0".

Or add the following package to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(name: "itwin-mobile-sdk", url: "https://github.com/iTwin/mobile-sdk-ios", .exact("0.24.0"))
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
  pod 'itwin-mobile-native', podspec: 'https://github.com/iTwin/mobile-native-ios/releases/download/4.11.39/itwin-mobile-native-ios.podspec'
  pod 'itwin-mobile-sdk', podspec: 'https://github.com/iTwin/mobile-sdk-ios/releases/download/0.24.0/itwin-mobile-sdk.podspec'
  pod 'AsyncLocationKit', podspec: 'https://github.com/iTwin/mobile-sdk-ios/releases/download/0.24.0/AsyncLocationKit.podspec'
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

## Notes
- This package is designed to be used with the [@itwin/mobile-sdk-core](https://github.com/iTwin/mobile-sdk-core) and [@itwin/mobile-ui-react](https://github.com/iTwin/mobile-ui-react) packages. Those two packages are intended to be installed via npm, and their version number must match the version number of this package. Furthermore, they use __iTwin.js 4.11.6__, and your app must use that same version of iTwin.js.

- If you are using this package via CocoaPods, make sure to set the `itwin-mobile-native` CocoaPod to version 4.11.39

- You may get a warning from AppAuth's OIDExternalUserAgentIOS.h when you build any project that includes this as a Swift Package. Unfortunately, there is no way that we know of to disable that warning. It can be ignored, though.
