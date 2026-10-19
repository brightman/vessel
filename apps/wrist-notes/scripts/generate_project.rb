require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'WristNotes.xcodeproj')
existing_development_teams = {}
if File.file?(project_path)
  existing_project = Xcodeproj::Project.open(project_path)
  existing_project.targets.each do |target|
    team = target.build_configurations.map do |configuration|
      configuration.build_settings['DEVELOPMENT_TEAM']
    end.compact.first
    existing_development_teams[target.name] = team if team
  end
end
project = Xcodeproj::Project.new(project_path)
project.root_object.attributes['LastUpgradeCheck'] = '2630'
project.build_configurations.each do |configuration|
  configuration.build_settings['SWIFT_VERSION'] = '5.0'
end

sources = project.main_group.new_group('Sources', 'Sources')
shared = sources.new_group('Shared', 'Shared')
phone = sources.new_group('iPhone', 'iPhone')
watch = sources.new_group('Watch', 'Watch')
shared_files = %w[VoiceNote.swift RecordingFormat.swift].map { |name| shared.new_file(name) }
phone_files = %w[WristNotesApp.swift NotesListView.swift NoteDetailView.swift NotesModel.swift
                 NoteRepository.swift PhoneConnectivity.swift OnDeviceTranscriber.swift
                 OnDeviceSummarizer.swift NotesStyle.swift AudioPlayback.swift
                 AIConfiguration.swift AppSettings.swift KeychainSecretStore.swift
                 CustomAISummarizer.swift AISettingsModel.swift PhoneWatchStatus.swift SettingsViews.swift].map { |name| phone.new_file(name) }
watch_files = %w[WristNotesWatchApp.swift WatchContentView.swift WatchRecorder.swift
                 WatchConnectivityStatus.swift RecordingButtonInteraction.swift].map { |name| watch.new_file(name) }

phone_target = project.new_target(:application, 'WristNotes', :ios, '26.0')
shared_files.each { |file| phone_target.source_build_phase.add_file_reference(file) }
phone_files.each { |file| phone_target.source_build_phase.add_file_reference(file) }
if File.directory?(File.join(root, 'Sources/iPhone/Assets.xcassets'))
  phone_target.resources_build_phase.add_file_reference(phone.new_file('Assets.xcassets'))
end
phone_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['SWIFT_VERSION'] = '5.0'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.vessel.wristnotes'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['INFOPLIST_FILE'] = 'Sources/iPhone/Info.plist'
  settings['INFOPLIST_KEY_CFBundleDisplayName'] = '语音笔记'
  settings['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
  settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  settings['TARGETED_DEVICE_FAMILY'] = '1'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = existing_development_teams[phone_target.name] if
    existing_development_teams[phone_target.name]
end

watch_target = project.new_target(:application, 'WristNotesWatch', :watchos, '10.0')
shared_files.each { |file| watch_target.source_build_phase.add_file_reference(file) }
watch_files.each { |file| watch_target.source_build_phase.add_file_reference(file) }
if File.directory?(File.join(root, 'Sources/Watch/Assets.xcassets'))
  watch_target.resources_build_phase.add_file_reference(watch.new_file('Assets.xcassets'))
end
watch_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['SWIFT_VERSION'] = '5.0'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.vessel.wristnotes.watchkitapp'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = 'Sources/Watch/Info.plist'
  settings['TARGETED_DEVICE_FAMILY'] = '4'
  settings['WATCHOS_DEPLOYMENT_TARGET'] = '10.0'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = existing_development_teams[watch_target.name] if
    existing_development_teams[watch_target.name]
end

phone_target.add_dependency(watch_target)
copy_phase = phone_target.new_copy_files_build_phase('Embed Watch Content')
copy_phase.dst_subfolder_spec = '1'
copy_phase.dst_path = 'Watch'
copy_phase.add_file_reference(watch_target.product_reference)

project.save
puts project_path
