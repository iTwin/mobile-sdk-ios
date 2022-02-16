# iTwin mobile-sdk

Copyright © Bentley Systems, Incorporated. All rights reserved. See [LICENSE.md](./LICENSE.md) for license terms and full copyright notice.

## Warning

This is pre-release software and provided as-is.

## About this Repository

This repository contains the Swift code used to build [iTwin.js](http://www.itwinjs.org) applications on iOS devices.

__Note:__ This package is designed to be used with the [@itwin/mobile-sdk-core](https://github.com/iTwin/mobile-sdk-core) and [@itwin/mobile-ui-react](https://github.com/iTwin/mobile-ui-react) packages. Those two packages are intended to be installed via npm, and their version number must match the version number of this package. Furthermore, they use __iModel.js 2.19.31__, and your app must use that same version of iModel.js. If you are using this package via CocoaPods, make sure to update the itwin-native-ios-package CocoaPod to version __2.19.35__.