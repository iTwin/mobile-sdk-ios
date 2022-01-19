# iTwin mobile-sdk-ios

Copyright © Bentley Systems, Incorporated. All rights reserved. See [LICENSE.md](./LICENSE.md) for license terms and full copyright notice.

## Warning

This is pre-release software and provided as-is.

## About this Repository

This repository contains the Swift code used to build [iTwin.js](http://www.itwinjs.org) applications on iOS devices.

__Note 1:__ This package is designed to be used with the [@itwin/mobile-sdk-core](https://github.com/iTwin/mobile-sdk-core) and [@itwin/mobile-ui-react](https://github.com/iTwin/mobile-ui-react) packages. Those two packages are intended to be installed via npm, and their version number must match the version number of this package. Furthermore, they use __iTwin.js 3.0.0-dev.185__, and your app must use that same version of iModel.js. If you are using this package via CocoaPods, make sure to update the itwin-mobile-ios-package CocoaPod to version __3.0.31__.

__Note 2:__ You will get two warnings relating to `IPHONEOS_DEPLOYMENT_TARGET` when you build any project that includes this as a Swift Package. Unfortunately, there is no way that I know of to disable those warnings. They can be ignored, though.
