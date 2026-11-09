# MediaPipe Tasks (Face Landmarker) — CocoaPods is the only supported way to
# install it on iOS. Run `pod install` after `xcodegen generate`, and note that
# from now on you open/build MemeMatcher.xcworkspace, not the .xcodeproj.
platform :ios, '17.0'

target 'MemeMatcher' do
  use_frameworks!
  # Only the main app gets MediaPipe. The keyboard extension must stay tiny
  # (tight memory budget) — it never runs the model, it only reads results
  # from the App Group.
  pod 'MediaPipeTasksVision'
end
