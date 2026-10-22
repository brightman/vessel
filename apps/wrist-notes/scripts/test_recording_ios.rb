# Isolated native tests for real audio-file duration and repository/draft recovery.
# Does not request microphone permission or access the user's app container.
require 'xcodeproj'
require 'fileutils'

root = File.expand_path('..', __dir__)
output = ARGV.fetch(0)
FileUtils.mkdir_p(output)
project = Xcodeproj::Project.new(File.join(output, 'RecordingVerification.xcodeproj'))
app = project.new_target(:application, 'RecordingVerification', :ios, '26.0')
%w[PhoneRecorder PhoneRecordingDraftStore PhoneRecordingSession NoteRepository DaybookDatabase].each do |name|
  app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Sources/iPhone', name + '.swift')))
end
app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Sources/Shared/VoiceNote.swift')))
%w[CaptureMetadata CaptureLocationService].each { |name| app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Sources/Shared', name + '.swift'))) }
File.write(File.join(output, 'VerificationApp.swift'), "import SwiftUI\n@main struct RecordingVerificationApp: App { var body: some Scene { WindowGroup { Text(\"Recording verification\") } } }\n")
app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(output, 'VerificationApp.swift')))
app.build_configurations.each do |config|
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => 'cloud.karama.wiselife.recording-verification', 'PRODUCT_NAME' => 'RecordingVerification', 'PRODUCT_MODULE_NAME' => 'WiseNote', 'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES', 'TARGETED_DEVICE_FAMILY' => '1', 'CODE_SIGN_IDENTITY' => '-')
end
tests = project.new_target(:unit_test_bundle, 'RecordingTests', :ios, '26.0')
%w[PhoneRecorderEnrollmentTests.swift PhoneRecordingPersistenceTests.swift].each do |file|
  tests.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Tests', file)))
end
tests.add_dependency(app)
tests.build_configurations.each do |config|
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => 'cloud.karama.wiselife.recording-tests', 'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/RecordingVerification.app/RecordingVerification', 'BUNDLE_LOADER' => '$(TEST_HOST)', 'CODE_SIGN_IDENTITY' => '-')
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, tests, launch_target: true)
scheme.save_as(project.path, 'RecordingVerification', true)
puts project.path
