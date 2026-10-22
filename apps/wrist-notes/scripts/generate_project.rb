require 'xcodeproj'
require_relative 'build_features'
require_relative 'watch_recording_widget_project'

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
shared_files = %w[VoiceNote.swift WatchSyncSnapshot.swift RecordingFormat.swift CaptureMetadata.swift CaptureLocationService.swift RecordingSession.swift RecordingChunkProtocol.swift RecordingFramePartition.swift RecordingAudioFile.swift RecordingChunkTransport.swift].map { |name| shared.new_file(name) }
phone_files = %w[WristNotesApp.swift NotesListView.swift NoteDetailView.swift NotesModel.swift
                 NoteRepository.swift RecordingSessionRepository.swift RecordingChunkReceiver.swift
                 RecordingSessionModel.swift RecordingSessionDetailView.swift RecordingRangePlayback.swift RecordingSessionPresentation.swift
                 PhoneConnectivity.swift OnDeviceTranscriber.swift
                 RingTransferStore.swift EurekaRingModel.swift RingHardwareViews.swift
                 OnDeviceSummarizer.swift OnDeviceRecordingTitleGenerator.swift RecordingTitleCoordinator.swift NotesStyle.swift AudioPlayback.swift
                 AIConfiguration.swift AppSettings.swift KeychainSecretStore.swift
                 CustomAISummarizer.swift ChatGPTProtocol.swift ChatGPTIDToken.swift ChatGPTAPI.swift
                 ChatGPTLoopback.swift ChatGPTBrowserAuthorization.swift ChatGPTAccountStore.swift ChatGPTAccountModel.swift
                 ChatGPTSettingsSection.swift ChatGPTSummarizer.swift RemoteSummaryConfirmationView.swift AISettingsModel.swift PhoneWatchStatus.swift WatchSyncStore.swift SettingsViews.swift
                 TranscriptionConfiguration.swift TranscriptionSettingsModel.swift TranscriptionSettingsView.swift
                 AppleSpeechResources.swift AppleSpeechReservationCoordinator.swift WhisperModelStore.swift LiveTranscriptionResources.swift LocalTranscriptionService.swift OfflineWhisperTokenizer.swift SpeakerTranscript.swift SpeakerModelStore.swift SpeakerTranscriptView.swift SpeakerContactViews.swift
                 VoiceIdentity.swift VoiceEmbeddingEngine.swift VoiceIdentityModelStore.swift VoiceSpeechSelection.swift MyVoiceProfileModel.swift MyVoiceEnrollmentView.swift
                 DaybookStyle.swift DaybookCalendarView.swift DaybookVoiceDetailView.swift DayRecord.swift LifeSourceStore.swift LifeSourceReader.swift LifeSourceModel.swift LifeSourceViews.swift LifeMomentBuilder.swift LocationMovementBuilder.swift LifeMomentViews.swift DaybookAnswerService.swift DaybookAssistantModel.swift DaybookAssistantView.swift DaybookComponents.swift DaybookPreferences.swift DaybookReminderPersistence.swift DaybookReminderStore.swift AppleReminderService.swift DaybookReminderViews.swift DaybookSemanticIndex.swift DaybookFullTextIndex.swift DaybookTextChunks.swift AppleDaybookEmbedding.swift DaybookSemanticSearchModel.swift DaybookSemanticSettingsView.swift DaybookDatabase.swift DaybookConversationStore.swift DaybookRetrieval.swift DaybookSuggestionStore.swift DaybookInsightStore.swift DaybookInsightService.swift DaybookInsightModel.swift DaybookInsightView.swift DaybookView.swift PhoneRecorder.swift PhoneRecordingSession.swift PhoneRecordingDraftStore.swift RecordingActivityManager.swift WiseLifeRuntime.swift RecordingIntents.swift QuickRecordingSettingsView.swift PhoneRecordingView.swift PhotoCaptureView.swift PhotoDetailView.swift PhotoLibraryModel.swift PhotoMoment.swift PhotoRepository.swift PhotoMetadataReader.swift DaybookPlaces.swift DaybookPlacesView.swift CaptureAddressModel.swift AppleCaptureAddressResolver.swift].map { |name| phone.new_file(name) }
watch_files = %w[WristNotesWatchApp.swift WatchContentView.swift WatchRecorder.swift SegmentedAudioCapture.swift WatchRecordingSessionStore.swift WatchChunkTransferQueue.swift
                 WatchConnectivityStatus.swift RecordingButtonInteraction.swift].map { |name| watch.new_file(name) }

phone_target = project.new_target(:application, 'WristNotes', :ios, '26.0')
phone_target.product_reference.path = 'WiseNote.app'
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
  settings['CURRENT_PROJECT_VERSION'] = '4'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['INFOPLIST_FILE'] = 'Sources/iPhone/Info.plist'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'Sources/iPhone/WristNotes.entitlements'
  settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'WiseLife'
  settings['INFOPLIST_KEY_CFBundleName'] = 'WiseLife'
  settings['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
  settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  settings['TARGETED_DEVICE_FAMILY'] = '1'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = existing_development_teams[phone_target.name] if
    existing_development_teams[phone_target.name]
end

# Pinned sqlite-vector sources, statically registered against system SQLite on iPhone only.
vector = project.main_group.new_group('SQLiteVector', 'Vendor/SQLiteVector')
Dir.glob(File.join(root, 'Vendor/SQLiteVector/src/*.c')).map { |path| "src/#{File.basename(path)}" }.push('Bridge.c').each do |path|
  file = phone_target.source_build_phase.add_file_reference(vector.new_file(path))
  file.settings = { 'COMPILER_FLAGS' => '-DSQLITE_CORE' }
end
phone_target.resources_build_phase.add_file_reference(vector.new_file('SQLiteVector-NOTICES.txt'))
phone_target.build_configurations.each do |configuration|
  configuration.build_settings['HEADER_SEARCH_PATHS'] = ['$(inherited)', '$(SRCROOT)/Vendor/SQLiteVector/src', '$(SRCROOT)/Vendor/SQLiteVector/libs']
  configuration.build_settings['SWIFT_INCLUDE_PATHS'] = ['$(inherited)', '$(SRCROOT)/Vendor/SQLiteVector']
  configuration.build_settings['OTHER_LDFLAGS'] = ['$(inherited)', '-lsqlite3']
end

phone_target.resources_build_phase.add_file_reference(phone.new_file('WhisperModels.json'))
phone_target.resources_build_phase.add_file_reference(phone.new_file('SpeakerModels.json'))
phone_target.resources_build_phase.add_file_reference(phone.new_file('SpeakerModels-NOTICES.txt'))
phone_target.resources_build_phase.add_file_reference(phone.new_file('VoiceIdentityModels.json'))
phone_target.resources_build_phase.add_file_reference(phone.new_file('VoiceIdentityModels-NOTICES.txt'))
phone_target.resources_build_phase.add_file_reference(phone.new_file('Lucide-LICENSE.txt'))
phone_target.resources_build_phase.add_file_reference(phone.new_file('Localizable.xcstrings'))
phone_target.resources_build_phase.add_file_reference(phone.new_file('InfoPlist.xcstrings'))
phone_target.resources_build_phase.add_file_reference(phone.new_file('PrivacyInfo.xcprivacy'))
# Pin reproducible versions; these dependencies are linked only into the iPhone application.
[
  ['https://github.com/argmaxinc/WhisperKit.git', '0.18.0', ['WhisperKit', 'SpeakerKit']],
  ['https://github.com/huggingface/swift-transformers.git', '1.1.6', ['Hub', 'Tokenizers']]
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
watch_target.resources_build_phase.add_file_reference(watch.new_file('PrivacyInfo.xcprivacy'))
watch_target.resources_build_phase.add_file_reference(phone.files.find { |file| file.path == 'Localizable.xcstrings' })
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
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = existing_development_teams[watch_target.name] if
    existing_development_teams[watch_target.name]
end

WatchRecordingWidgetProject.apply(project, root: root)

# Recording attributes and shared intents belong to iPhone and its extension only.
recording_shared = sources.new_group('RecordingShared', 'RecordingShared')
recording_shared_files = %w[RecordingActivityAttributes.swift StartWiseLifeRecordingIntent.swift StopWiseLifeRecordingIntent.swift].map { |name| recording_shared.new_file(name) }
recording_shared_files.each { |file| phone_target.source_build_phase.add_file_reference(file) }
recording_group = sources.new_group('RecordingActivity', 'RecordingActivity')
recording_target = project.new_target(:app_extension, 'WiseLifeRecordingActivity', :ios, '26.0')
recording_target.source_build_phase.add_file_reference(recording_group.new_file('RecordingActivityWidget.swift'))
recording_target.source_build_phase.add_file_reference(recording_group.new_file('QuickRecordingWidget.swift'))
recording_target.source_build_phase.add_file_reference(shared_files.find { |file| file.path == 'RecordingFormat.swift' })
recording_target.resources_build_phase.add_file_reference(recording_group.new_file('Localizable.xcstrings'))
recording_shared_files.each { |file| recording_target.source_build_phase.add_file_reference(file) }
recording_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  app_settings = phone_target.build_configurations.find { |item| item.name == configuration.name }.build_settings
  settings['SWIFT_VERSION'] = '5.0'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'cloud.karama.wisenote.recording-activity'
  settings['MARKETING_VERSION'] = app_settings['MARKETING_VERSION']
  settings['CURRENT_PROJECT_VERSION'] = app_settings['CURRENT_PROJECT_VERSION']
  settings['DEVELOPMENT_TEAM'] = app_settings['DEVELOPMENT_TEAM'] if app_settings['DEVELOPMENT_TEAM']
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['INFOPLIST_FILE'] = 'Sources/RecordingActivity/Info.plist'
  settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'WiseLife 录音'
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['SKIP_INSTALL'] = 'YES'
  settings['TARGETED_DEVICE_FAMILY'] = '1'
  settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) WISELIFE_RECORDING_WIDGET'
end
phone_target.add_dependency(recording_target)
recording_embed = phone_target.new_copy_files_build_phase('Embed Recording Activity')
recording_embed.dst_subfolder_spec = '13'
recording_embed.add_file_reference(recording_target.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

phone_target.add_dependency(watch_target)
copy_phase = phone_target.new_copy_files_build_phase('Embed Watch Content')
copy_phase.dst_subfolder_spec = '1'
copy_phase.dst_path = 'Watch'
copy_phase.add_file_reference(watch_target.product_reference)

test_target = project.new_target(:unit_test_bundle, 'RingIntegrationTests', :ios, '26.0')
tests_group = project.main_group.new_group('Tests', 'Tests')
test_target.source_build_phase.add_file_reference(tests_group.new_file('RingIntegrationTests.swift'))
test_target.source_build_phase.add_file_reference(tests_group.new_file('NotesDiarizationTests.swift'))
test_target.source_build_phase.add_file_reference(tests_group.new_file('SpeakerResourceTests.swift'))
test_target.source_build_phase.add_file_reference(tests_group.new_file('VoiceEnrollmentTests.swift'))
test_target.source_build_phase.add_file_reference(tests_group.new_file('PhoneRecorderEnrollmentTests.swift'))
test_target.resources_build_phase.add_file_reference(tests_group.new_file('Fixtures/sdk-opus-16k-mono.bin'))
test_target.add_dependency(phone_target)
test_target.build_configurations.each do |configuration|
  configuration.build_settings['SWIFT_VERSION'] = '5.0'
  configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'cloud.karama.wisenote.RingIntegrationTests'
  configuration.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  configuration.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/WiseNote.app/WiseNote'
  configuration.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
WristNotesBuildFeatures.apply(project, enabled: WristNotesBuildFeatures.enabled?(root))
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(phone_target, test_target, launch_target: true)
scheme.save_as(project_path, 'WristNotes', true)
puts project_path
