# Isolated test host: real profile model/store with only model inference replaced.
require 'xcodeproj'
require 'fileutils'
root = File.expand_path('..', __dir__)
output = ARGV.fetch(0)
FileUtils.mkdir_p(output)
project = Xcodeproj::Project.new(File.join(output, 'VoiceProfileRecovery.xcodeproj'))
app = project.new_target(:application, 'VoiceProfileRecovery', :ios, '26.0')
paths = %w[VoiceIdentity MyVoiceProfileModel SpeakerTranscript VoiceSpeechSelection].map { |name| "Sources/iPhone/#{name}.swift" }
paths += %w[Sources/Shared/CaptureMetadata.swift Sources/Shared/VoiceNote.swift Tests/VoiceProfileRecovery/InferenceBoundary.swift]
paths.each { |path| app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, path))) }
File.write(File.join(output, 'VerificationApp.swift'), "import SwiftUI\n@main struct ProfileCheckApp: App { var body: some Scene { WindowGroup { Text(\"Voice profile recovery verification\") } } }\n")
app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(output, 'VerificationApp.swift')))
app.build_configurations.each do |config|
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => 'cloud.karama.wiselife.profile-verification', 'PRODUCT_MODULE_NAME' => 'WiseLifeProfileVerification', 'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES', 'TARGETED_DEVICE_FAMILY' => '1', 'CODE_SIGN_IDENTITY' => '-')
end
test = project.new_target(:unit_test_bundle, 'VoiceProfileRecoveryTests', :ios, '26.0')
test.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Tests/MyVoiceProfileRecoveryTests.swift')))
test.add_dependency(app)
test.build_configurations.each do |config|
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => 'cloud.karama.wiselife.profile-tests', 'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/VoiceProfileRecovery.app/VoiceProfileRecovery', 'BUNDLE_LOADER' => '$(TEST_HOST)', 'CODE_SIGN_IDENTITY' => '-')
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, test, launch_target: true)
scheme.save_as(project.path, 'VoiceProfileRecovery', true)
puts project.path
