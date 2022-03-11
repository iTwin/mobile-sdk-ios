Pod::Spec.new do |spec|
  spec.name         = "itwin-mobile-sdk"
  spec.version      = "0.10.6"
  spec.summary      = "iTwin Mobile SDK"
  spec.homepage     = "https://github.com/iTwin/mobile-sdk-ios"
  spec.license      = { :type => "MIT", :file => "LICENSE.md" }
  spec.author       = "Bentley Systems Inc."
  spec.platform     = :ios
  spec.source       = { :git => "#{spec.homepage}.git", :tag => "#{spec.version}"}
  spec.source_files = "Sources/**/*"
  spec.exclude_files = "Sources/ITwinMobile/ITwinMobile.docc/**/*"
  spec.swift_versions = "5.3"
  spec.ios.deployment_target = "12.2"
  spec.pod_target_xcconfig = { 'ENABLE_BITCODE' => 'NO' }
  spec.pod_target_xcconfig = { 'ONLY_ACTIVE_ARCH' => 'YES' }
  spec.user_target_xcconfig = { 'ONLY_ACTIVE_ARCH' => 'YES' } # not recommended but `pod lib lint` fails without it
  spec.dependency "PromiseKit", "~> 6.8"
  spec.dependency "PromiseKit/CoreLocation", "~> 6.0"
  spec.dependency "PromiseKit/Foundation", "~> 6.0"
  spec.dependency "ReachabilitySwift"
  spec.dependency "AppAuth", "~> 1.4"
  spec.dependency "itwin-mobile-native", "3.0.33"
end
