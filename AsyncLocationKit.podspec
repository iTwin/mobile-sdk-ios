Pod::Spec.new do |s|
  s.name = "AsyncLocationKit"
  s.version = "1.0.5"
  s.summary = "async/await CoreLocation"
  s.homepage = "https://github.com/AsyncSwift/AsyncLocationKit"
  s.author = "Pavel Grechikhin"
  s.description = "Wrapper for Apple CoreLocation framework with new Concurency Model. No more delegate pattern or completion blocks."
  s.source = {
    :git => "#{s.homepage}.git",
    :tag => "#{s.version}"
  }
  s.license = {
    :type => "MIT",
    :file => "LICENSE"
  }
  s.platforms = {
    :ios => "13.0",
    :osx => "12.0"
  }
  s.source_files = "Sources/**/*"
  s.swift_versions = ["5.5"]
end
