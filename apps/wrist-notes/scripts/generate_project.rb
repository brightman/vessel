require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'WristNotes.xcodeproj')
existing_development_teams = {}
if File.directory?(project_path)
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
                 CustomAISummarizer.swift AISettingsModel.swift PhoneWatchStatus.swift SettingsViews.swift
                 TranscriptionConfiguration.swift TranscriptionSettingsModel.swift TranscriptionSettingsView.swift
                 AppleSpeechResources.swift AppleSpeechReservationCoordinator.swift WhisperModelStore.swift LiveTranscriptionResources.swift LocalTranscriptionService.swift OfflineWhisperTokenizer.swift
                 DaybookStyle.swift DaybookCalendarView.swift DaybookVoiceDetailView.swift DayRecord.swift DaybookAnswerService.swift DaybookAssistantModel.swift DaybookAssistantView.swift DaybookComponents.swift DaybookPreferences.swift DaybookReminderPersistence.swift DaybookReminderStore.swift DaybookReminderViews.swift DaybookRetrieval.swift DaybookSuggestionStore.swift DaybookView.swift PhoneRecorder.swift PhoneRecordingView.swift PhotoCaptureView.swift PhotoDetailView.swift PhotoLibraryModel.swift PhotoMoment.swift PhotoRepository.swift].map { |name| phone.new_file(name) }
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
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'cloud.karama.wisenote'
  settings['PRODUCT_NAME'] = 'WiseNote'
  settings['MARKETING_VERSION'] = '1.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['INFOPLIST_FILE'] = 'Sources/iPhone/Info.plist'
  settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'WiseNote'
  settings['INFOPLIST_KEY_CFBundleName'] = 'WiseNote'
  settings['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
  settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  settings['TARGETED_DEVICE_FAMILY'] = '1'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = existing_development_teams[phone_target.name] if
    existing_development_teams[phone_target.name]
end

phone_target.resources_build_phase.add_file_reference(phone.new_file('WhisperModels.json'))
phone_target.resources_build_phase.add_file_reference(phone.new_file('Lucide-LICENSE.txt'))
phone_target.resources_build_phase.add_file_reference(phone.new_file('Localizable.xcstrings'))
# Pin reproducible versions; these dependencies are linked only into the iPhone application.
[
  ['https://github.com/argmaxinc/WhisperKit.git', '0.15.0', ['WhisperKit']],
  ['https://github.com/huggingface/swift-transformers.git', '1.1.2', ['Hub', 'Tokenizers']]
].each do |url, version, products|
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = url
  package.requirement = { 'kind' => 'exactVersion', 'version' => version }
  project.root_object.package_references << package
  products.each do |name|
    product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    product.package = package
    product.product_name = name
    phone_target.package_product_dependencies << product
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = product
    phone_target.frameworks_build_phase.files << build_file
  end
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
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'cloud.karama.wisenote.watchkitapp'
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
