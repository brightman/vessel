Pod::Spec.new do |s|
  s.name = 'br_flutter_plugin_ble'
  s.version = '3.0.0'
  s.summary = 'Native iOS binary distribution of the BR recording-device plugin.'
  s.description = 'BRBluetoothLib, BRRecorderCore and the portable Opus codec for Swift hosts. No Flutter runtime or app-service dependency.'
  s.homepage = 'https://www.bairong.com'
  s.license = { :type => 'Proprietary', :file => 'Licenses/BRBluetoothLib.txt' }
  s.author = { 'Bairong' => 'flutter@bairong.com' }
  s.source = { :path => '.' }
  s.ios.deployment_target = '14.0'
  s.swift_version = '5.0'
  s.static_framework = true
  s.default_subspec = 'Native'

  s.subspec 'Bluetooth' do |sdk|
    sdk.vendored_frameworks = 'Frameworks/BRBluetoothLib.xcframework'
    sdk.frameworks = 'Foundation', 'CoreBluetooth', 'CoreLocation', 'Network', 'NetworkExtension', 'SystemConfiguration', 'UIKit'
  end

  s.subspec 'Opus' do |codec|
    codec.vendored_frameworks = 'Frameworks/BRRecorderOpus.xcframework'
    codec.resource_bundles = { 'BRRecorderOpusNotices' => ['Licenses/Opus-COPYING.txt', 'Licenses/Opus-AUTHORS.txt'] }
  end

  s.subspec 'Native' do |native|
    native.vendored_frameworks = 'Frameworks/BRRecorderCore.xcframework'
    native.frameworks = 'Foundation', 'CoreBluetooth', 'AVFoundation'
    native.resource_bundles = { 'BRRecorderSDKPrivacy' => ['Resources/PrivacyInfo.xcprivacy'] }
    native.dependency 'br_flutter_plugin_ble/Bluetooth', '= 3.0.0'
    native.dependency 'br_flutter_plugin_ble/Opus', '= 3.0.0'
  end
end
