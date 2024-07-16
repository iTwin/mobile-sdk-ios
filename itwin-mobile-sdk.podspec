Pod::Spec.new do |spec|
  spec.name         = "itwin-mobile-sdk"
  spec.version      = "0.22.6"
  spec.summary      = "iTwin Mobile SDK"
  spec.homepage     = "https://github.com/iTwin/mobile-sdk-ios"
  spec.license      = { :type => "MIT", :file => "LICENSE.md" }
  spec.author       = "Bentley Systems Inc."
  spec.platform     = :ios
  spec.source       = { :git => "#{spec.homepage}.git", :tag => "#{spec.version}"}
  spec.source_files = "Sources/**/*"
  spec.exclude_files = "Sources/ITwinMobile/ITwinMobile.docc/**/*"
  spec.swift_version = "5.5"
  spec.ios.deployment_target = "13.0"
  spec.pod_target_xcconfig = { 'ENABLE_BITCODE' => 'NO' }
  spec.pod_target_xcconfig = { 'ONLY_ACTIVE_ARCH' => 'YES' }
  spec.user_target_xcconfig = { 'ONLY_ACTIVE_ARCH' => 'YES' } # not recommended but `pod lib lint` fails without it
  spec.dependency "ReachabilitySwift"
  spec.dependency "AsyncLocationKit", "~> 1.0.5"
  spec.dependency "AppAuth", "~> 1.4"
  spec.dependency "itwin-mobile-native", "4.7.29"
end
