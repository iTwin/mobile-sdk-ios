// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import PackageDescription

let package = Package(
    name: "itwin-mobile-sdk",
    platforms: [
        .iOS("13"),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "ITwinMobile",
            targets: ["ITwinMobile"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(name: "itwin-mobile-native", url: "https://github.com/iTwin/mobile-native-ios", .exact("4.8.42")),
        .package(url: "https://github.com/AsyncSwift/AsyncLocationKit.git", .upToNextMajor(from: "1.5.6")),
        .package(name: "Reachability", url: "https://github.com/ashleymills/Reachability.swift", from: "5.1.0"),
        .package(name: "AppAuth", url: "https://github.com/openid/AppAuth-iOS.git", .upToNextMajor(from: "1.6.0")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "ITwinMobile",
            dependencies: [
                .product(name: "IModelJsNative", package: "itwin-mobile-native"),
                .product(name: "AsyncLocationKit", package: "AsyncLocationKit"),
                .product(name: "Reachability", package: "Reachability"),
                .product(name: "AppAuth", package: "AppAuth"),
            ]),
//        .testTarget(
//            name: "ITwinMobileTests",
//            dependencies: ["ITwinMobile"]),
    ],
    swiftLanguageVersions: [.version("5.5")]
)
