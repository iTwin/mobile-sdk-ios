Pod::Spec.new do |spec|
  spec.name         = "itwin-mobile-sdk"
  spec.version      = "0.0.4"
  spec.summary      = "iTwin Mobile SDK"
  spec.homepage     = "https://github.com/iTwin/itwin-mobile-sdk"
  spec.license      = "MIT"
  spec.author       = "Bentley Systems Inc."
  spec.platform     = :ios
  spec.source       = { :git => "#{spec.homepage}.git", :tag => "#{spec.version}"}
  spec.source_files = "**/*"
  spec.ios.deployment_target = "12.2"
  spec.dependency "PromiseKit", "~> 6.8"
  spec.dependency "PromiseKit/CoreLocation", "~> 6.0"
  spec.dependency "itwin-mobile-ios-package"
end