# Generate an isolated simulator test host. It opens only per-test temporary roots.
require 'xcodeproj'
require 'fileutils'
root = File.expand_path('..', __dir__)
output = ARGV.fetch(0)
FileUtils.mkdir_p(output)
project = Xcodeproj::Project.new(File.join(output, 'StorageLifecycle.xcodeproj'))
app = project.new_target(:application, 'StorageLifecycle', :ios, '26.0')
names = %w[DaybookDatabase PhotoMoment PhotoRepository PhotoLibraryModel DaybookReminderPersistence DaybookReminderStore AppleReminderService NotesModel NoteRepository PhoneConnectivity PhoneWatchStatus WatchSyncStore RecordingTitleCoordinator RecordingSessionRepository AudioProcessing AudioProcessingRepository AudioProcessingCoordinator AudioProcessingModel ContentSegmentation ContentSegmentRepository ContentEnrichmentService AudioWindowPlanner AudioSpeakerMapping TranscriptionConfiguration]
names.each { |name| app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Sources/iPhone', name + '.swift'))) }
app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Sources/Shared/VoiceNote.swift')))
%w[CaptureMetadata CaptureLocationService WatchSyncSnapshot RecordingSession RecordingSessionFiles RecordingAudioFile RecordingDiagnostics].each { |name| app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Sources/Shared', name + '.swift'))) }
app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Tests/StorageLifecycle/BoundaryServices.swift')))
File.write(File.join(output, 'VerificationApp.swift'), "import SwiftUI\n@main struct StorageLifecycleApp: App { var body: some Scene { WindowGroup { Text(\"Storage lifecycle verification\") } } }\n")
app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(output, 'VerificationApp.swift')))
app.build_configurations.each do |config|
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => 'cloud.karama.wiselife.storage-lifecycle-verification', 'PRODUCT_NAME' => 'StorageLifecycle', 'PRODUCT_MODULE_NAME' => 'WiseLifeStorageVerification', 'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES', 'TARGETED_DEVICE_FAMILY' => '1', 'CODE_SIGN_IDENTITY' => '-')
end
test = project.new_target(:unit_test_bundle, 'StorageLifecycleTests', :ios, '26.0')
test.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Tests/StorageLifecycleTests.swift')))
test.add_dependency(app)
test.build_configurations.each do |config|
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => 'cloud.karama.wiselife.storage-lifecycle-tests', 'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/StorageLifecycle.app/StorageLifecycle', 'BUNDLE_LOADER' => '$(TEST_HOST)', 'CODE_SIGN_IDENTITY' => '-')
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, test, launch_target: true)
scheme.save_as(project.path, 'StorageLifecycle', true)
puts project.path
