require 'xcodeproj'
require 'json'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'WristNotes.xcodeproj'))
watch_target = project.targets.find { |target| target.name == 'WristNotesWatch' }
abort 'WristNotesWatch target is missing' unless watch_target

watch_sources = watch_target.source_build_phase.files_references.map { |reference| File.basename(reference.path) }
required_sources = %w[RecordingButtonInteraction.swift WatchConnectivityStatus.swift]
missing_project_sources = required_sources - watch_sources
abort "Watch target is missing sources: #{missing_project_sources.join(', ')}" unless missing_project_sources.empty?

generator = File.read(File.join(root, 'scripts', 'generate_project.rb'))
missing_generator_sources = required_sources.reject { |source| generator.include?(source) }
abort "Project generator is missing sources: #{missing_generator_sources.join(', ')}" unless missing_generator_sources.empty?

puts 'Watch project source membership: passed'

watch_assets_path = File.join(root, 'Sources/Watch/Assets.xcassets')
watch_asset_reference = watch_target.resources_build_phase.files_references.find do |reference|
  reference.path == 'Assets.xcassets'
end
abort 'Watch target is missing its Assets.xcassets resource' unless watch_asset_reference
abort 'Watch Assets.xcassets directory is missing' unless File.directory?(watch_assets_path)

watch_icon_set = File.join(watch_assets_path, 'AppIcon.appiconset')
watch_icon_contents_path = File.join(watch_icon_set, 'Contents.json')
abort 'Watch AppIcon.appiconset is missing' unless File.file?(watch_icon_contents_path)

watch_icon_contents = JSON.parse(File.read(watch_icon_contents_path))
watch_icon = watch_icon_contents.fetch('images').find do |image|
  image['idiom'] == 'universal' && image['platform'] == 'watchos' && image['size'] == '1024x1024'
end
abort 'Watch AppIcon must define a universal 1024x1024 watchOS icon' unless watch_icon
watch_icon_file = File.join(watch_icon_set, watch_icon.fetch('filename'))
abort 'Watch AppIcon image is missing' unless File.file?(watch_icon_file)

generator_assets = File.read(File.join(root, 'scripts', 'generate_project.rb'))
abort 'Project generator does not add Watch Assets.xcassets to target resources' unless
  generator_assets.include?("Sources/Watch/Assets.xcassets") &&
  generator_assets.include?('watch_target.resources_build_phase')
abort 'Project generator does not preserve selected development teams' unless
  generator_assets.include?('existing_development_teams') &&
  generator_assets.include?("settings['DEVELOPMENT_TEAM']")

puts 'Watch app icon resource: passed'

phone_target = project.targets.find { |target| target.name == 'WristNotes' }
phone_sources = phone_target.source_build_phase.files_references.map { |reference| File.basename(reference.path) }
required_phone_sources = Dir.glob(File.join(root, 'Sources/iPhone/*.swift')).map { |path| File.basename(path) }
abort 'iPhone target source membership is incomplete' unless (required_phone_sources - phone_sources).empty?
abort 'Generator iPhone source list is incomplete' unless required_phone_sources.all? { |source| generator.include?(source) }
puts 'iPhone project source membership: passed'

abort 'iPhone local diarization package is missing' unless phone_target.package_product_dependencies.any? { |product| product.product_name == 'WristNotesDiarization' }
abort 'Watch must not link the iPhone diarization package' unless watch_target.package_product_dependencies.empty?
abort 'Local diarization package manifest is missing' unless File.file?(File.join(root, 'Packages/WristNotesDiarization/Package.swift'))
puts 'Local speaker model package membership: passed'

phone_target.build_configurations.each do |configuration|
  abort 'HealthKit entitlement path is missing' unless configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] == 'Sources/iPhone/WristNotes.entitlements'
end
entitlements = Xcodeproj::Plist.read_from_path(File.join(root, 'Sources/iPhone/WristNotes.entitlements'))
abort 'Read-only HealthKit configuration is missing' unless entitlements['com.apple.developer.healthkit'] == true && entitlements['com.apple.developer.healthkit.background-delivery'] == true
info = Xcodeproj::Plist.read_from_path(File.join(root, 'Sources/iPhone/Info.plist'))
abort 'Health read purpose string is missing' unless info['NSHealthShareUsageDescription']
abort 'Read-only implementation should not request HealthKit write access' if info['NSHealthUpdateUsageDescription']
puts 'HealthKit project configuration: passed'
