require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'WiseLifeDesktop.xcodeproj')
project = Xcodeproj::Project.new(project_path)
target = project.new_target(:application, 'WiseLifeDesktop', :osx, '15.0')
target.product_reference.path = 'WiseLife.app'
group = project.main_group.new_group('Sources', '.')
Dir.glob(File.join(root, '{Shared,Sources}/**/*.swift')).sort.each do |path|
  target.source_build_phase.add_file_reference(group.new_file(path.delete_prefix(root + '/')))
end
resources = project.main_group.new_group('Resources', 'Resources')
%w[Assets.xcassets PrivacyInfo.xcprivacy].each do |name|
  target.resources_build_phase.add_file_reference(resources.new_file(name)) if File.exist?(File.join(root, 'Resources', name))
end
target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'cloud.karama.wiselife.desktop'
  settings['PRODUCT_NAME'] = 'WiseLife'
  settings['SWIFT_VERSION'] = '5.0'
  settings['MACOSX_DEPLOYMENT_TARGET'] = '15.0'
  settings['MARKETING_VERSION'] = '1.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['INFOPLIST_FILE'] = 'Resources/Info.plist'
  settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'WiseLife'
  settings['INFOPLIST_KEY_NSPrincipalClass'] = 'NSApplication'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  settings['ENABLE_APP_SANDBOX'] = 'NO'
  settings['OTHER_LDFLAGS'] = ['$(inherited)', '-lsqlite3']
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(target, nil, launch_target: true)
scheme.save_as(project_path, 'WiseLifeDesktop', true)
puts project_path
