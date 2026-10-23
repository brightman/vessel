require 'xcodeproj'
root = File.expand_path('../iphone', __dir__)
path = File.join(root, 'HuaweiNotes.xcodeproj')
project = Xcodeproj::Project.new(path)
project.root_object.attributes['LastUpgradeCheck'] = '2630'
target = project.new_target(:application, 'HuaweiNotes', :ios, '26.0')
sources = project.main_group.new_group('Sources', 'Sources')
%w[Shared iPhone].each do |name|
  group = sources.new_group(name, name)
  Dir.glob(File.join(root, 'Sources', name, '*.swift')).sort.each do |file|
    target.source_build_phase.add_file_reference(group.new_file(File.basename(file)))
  end
  if name == 'iPhone'
    target.resources_build_phase.add_file_reference(group.new_file('Assets.xcassets'))
  end
end
target.build_configurations.each do |config|
  config.build_settings.merge!({
    'SWIFT_VERSION' => '5.0',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.vessel.wristnotes.huawei',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'INFOPLIST_KEY_CFBundleDisplayName' => '腕记·华为',
    'INFOPLIST_KEY_UIApplicationSceneManifest_Generation' => 'YES',
    'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
    'TARGETED_DEVICE_FAMILY' => '1',
    'IPHONEOS_DEPLOYMENT_TARGET' => '26.0',
    'CODE_SIGN_STYLE' => 'Automatic',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon'
  })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(path, 'HuaweiNotes', true)
puts path
