require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'WiseLifeMac.xcodeproj')
project = Xcodeproj::Project.new(project_path)
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '.'
project.root_object.package_references << package

[['WiseLifeCompanion', :application, 'Sources/WiseLifeCompanion'], ['CompanionBenchmark', :command_line_tool, 'Sources/CompanionBenchmark']].each do |name, type, source|
  target = project.new_target(type, name, :osx, '15.0')
  group = project.main_group.new_group(name, '.')
  Dir.glob(File.join(root, source, '*.swift')).sort.each do |path|
    target.source_build_phase.add_file_reference(group.new_file(path.delete_prefix(root + '/')))
  end
  %w[CompanionCore CompanionMLX].each do |product_name|
    dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dependency.package = package
    dependency.product_name = product_name
    target.package_product_dependencies << dependency
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = dependency
    target.frameworks_build_phase.files << build_file
  end
  if type == :application
    %w[Assets.xcassets PrivacyInfo.xcprivacy ThirdPartyNotices.txt].each do |resource|
      path = File.join('Resources', resource)
      target.resources_build_phase.add_file_reference(group.new_file(path)) if File.exist?(File.join(root, path))
    end
  end
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'cloud.karama.wiselife.mac-companion' + (type == :application ? '' : '.benchmark')
    settings['PRODUCT_NAME'] = name
    settings['SWIFT_VERSION'] = '5.0'
    settings['SWIFT_OPTIMIZATION_LEVEL'] = configuration.name == 'Debug' ? '-Onone' : '-O'
    settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = ['$(inherited)', 'DEBUG'] if configuration.name == 'Debug'
    settings['MACOSX_DEPLOYMENT_TARGET'] = '15.0'
    settings['ARCHS'] = 'arm64'
    settings['MARKETING_VERSION'] = '0.2.0'
    settings['CURRENT_PROJECT_VERSION'] = '2'
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
    settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] = 'NO' if configuration.name == 'Release'
    if type == :application
      settings['GENERATE_INFOPLIST_FILE'] = 'YES'
      settings['INFOPLIST_FILE'] = 'Resources/Info.plist'
      settings['CODE_SIGN_ENTITLEMENTS'] = 'Resources/Companion.entitlements'
      settings['ENABLE_APP_SANDBOX'] = 'YES'
      settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
    end
  end
  scheme = Xcodeproj::XCScheme.new
  scheme.configure_with_targets(target, nil, launch_target: true)
  scheme.save_as(project_path, name, true)
end
project.save
puts project_path
