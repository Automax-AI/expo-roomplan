require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ExpoRoomplan'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = package['author']
  s.homepage       = package['homepage']
  s.platforms      = {
    :ios => '17.0'
  }
  s.swift_version  = '5.4'
  s.source         = { git: 'https://github.com/fordat/expo-roomplan' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # Swift/Objective-C compatibility
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.ios.deployment_target = '17.0'

  # Explicitly link system frameworks used by RoomPlan
  s.frameworks = 'RoomPlan', 'RealityKit', 'ARKit'

  # IMPORTANT:
  # This podspec lives under `ios/`. Avoid globs like `**/*` here because they
  # accidentally include Xcode/CocoaPods artifacts (e.g. `ios/Pods/**`) and
  # React Native codegen output (e.g. `ios/build/generated/**`), which can break
  # CI/EAS builds with errors like missing `folly/folly-config.h`.
  #
  # This module's native code is only these Swift files.
  s.source_files = [
    'ExpoRoomPlanModule.swift',
    'ExpoRoomPlanViewModule.swift',
    'RoomPlanCaptureUIView.swift',
    'RoomPlanCaptureViewController.swift',
    'RoomPlanUtils.swift',
  ]

end
