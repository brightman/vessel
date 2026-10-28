require 'xcodeproj'
require 'json'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'WristNotes.xcodeproj'))
watch_target = project.targets.find { |target| target.name == 'WristNotesWatch' }
abort 'WristNotesWatch target is missing' unless watch_target

watch_sources = watch_target.source_build_phase.files_references.map { |reference| File.basename(reference.path) }
required_sources = %w[RecordingButtonInteraction.swift WatchConnectivityStatus.swift SegmentedAudioCapture.swift]
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

abort 'Watch target is missing the shared app localization catalog' unless
  watch_target.resources_build_phase.files_references.any? { |reference| reference.path == 'Localizable.xcstrings' }
puts 'Watch localized session resources: passed'

phone_target = project.targets.find { |target| target.name == 'WristNotes' }
phone_sources = phone_target.source_build_phase.files_references.map { |reference| File.basename(reference.path) }
required_phone_sources = Dir.glob(File.join(root, 'Sources/iPhone/*.swift')).map { |path| File.basename(path) }
abort 'iPhone target source membership is incomplete' unless (required_phone_sources - phone_sources).empty?
abort 'Generator iPhone source list is incomplete' unless required_phone_sources.all? { |source| generator.include?(source) }
puts 'iPhone project source membership: passed'

session_sources = %w[RecordingSession.swift RecordingSessionFiles.swift RecordingFramePartition.swift RecordingAudioFile.swift RecordingDiagnostics.swift]
abort 'Recording session sources must belong to iPhone and Watch' unless
  (session_sources - phone_sources).empty? && (session_sources - watch_sources).empty?
abort 'Generator recording session sources are incomplete' unless session_sources.all? { |source| generator.include?(source) }
puts 'Recording session shared source membership: passed'

widget_target = project.targets.find { |target| target.name == 'WiseLifeRecordingActivity' }
abort 'Recording widget extension target is missing' unless widget_target
widget_sources = widget_target.source_build_phase.files_references.map { |reference| File.basename(reference.path) }
abort 'Recording session sources leaked into widget target' unless (session_sources & widget_sources).empty?
shared_recording_sources = Dir.glob(File.join(root, 'Sources/RecordingShared/*.swift')).map { |path| File.basename(path) }
widget_only_sources = Dir.glob(File.join(root, 'Sources/RecordingActivity/*.swift')).map { |path| File.basename(path) }
abort 'Shared recording source membership is incomplete' unless
  (shared_recording_sources - phone_sources).empty? && (shared_recording_sources - widget_sources).empty?
abort 'Widget source membership is incomplete' unless (widget_only_sources - widget_sources).empty?
abort 'Recording widget sources leaked into Watch target' unless
  ((shared_recording_sources + widget_only_sources) & watch_sources).empty?
abort 'Widget-only sources leaked into iPhone app target' unless (widget_only_sources & phone_sources).empty?
abort 'Generator recording source list is incomplete' unless
  (shared_recording_sources + widget_only_sources).all? { |source| generator.include?(source) }
puts 'Recording widget and shared intent source membership: passed'
