# Build a focused iOS app from production sources when the independent Ring SDK is absent.
# The only stand-ins are unrelated Ring metadata and a navigation enum (see BoundaryTypes.swift).
require 'xcodeproj'
require 'fileutils'
root = File.expand_path('..', __dir__)
output = ARGV[0] || '/private/tmp/wiselife-speaker-ios'
FileUtils.mkdir_p(output)
project = Xcodeproj::Project.new(File.join(output, 'SpeakerVerification.xcodeproj'))
app = project.new_target(:application, 'SpeakerVerification', :ios, '26.0')
names = %w[NotesModel NoteRepository LocalTranscriptionService LocalAudioInferenceGate BoundedAudioReader OnDeviceSpeechActivity AudioSpeakerMapping AudioProcessing AudioAdaptiveInference AudioWindowPlanner OnDeviceTranscriber SpeakerTranscript SpeakerModelStore WhisperModelStore AppleSpeechReservationCoordinator AppleSpeechResources PhoneConnectivity PhoneWatchStatus OnDeviceSummarizer OnDeviceRecordingTitleGenerator AppSettings AIConfiguration CustomAISummarizer KeychainSecretStore AISettingsModel TranscriptionConfiguration TranscriptionSettingsModel LiveTranscriptionResources TranscriptionSettingsView SettingsViews NotesStyle DaybookStyle AudioPlayback NoteDetailView DaybookVoiceDetailView SpeakerTranscriptView SpeakerContactViews]
names += %w[VoiceIdentity VoiceEmbeddingEngine VoiceIdentityModelStore VoiceSpeechSelection MyVoiceProfileModel MyVoiceEnrollmentView PhoneRecorder PhoneRecordingDraftStore PhoneRecordingSession]
names += %w[DaybookComponents DayRecord LifeSourceStore DaybookDatabase DaybookPlacesView]
names += %w[WatchSyncStore RecordingSessionRepository RecordingChunkReceiver]
names += %w[AudioProcessingModel AudioProcessingCoordinator AudioProcessingRepository ContentSegmentation ContentSegmentRepository ContentEnrichmentService ContentSegmentPresentation ContentSegmentModel ContentSegmentDetailView RecordingRangePlayback RecordingSessionModel RecordingSessionDetailView RecordingSessionPresentation]
paths = names.map { |name| File.join(root, 'Sources/iPhone', name + '.swift') }
paths += %w[VoiceNote RecordingFormat CaptureMetadata CaptureLocationService WatchSyncSnapshot RecordingSession RecordingChunkProtocol RecordingAudioFile RecordingChunkTransport].map { |name| File.join(root, 'Sources/Shared', name + '.swift') }
paths += %w[BoundaryTypes VerificationApp].map { |name| File.join(root, 'Tests/SpeakerVerification', name + '.swift') }
paths.each { |path| app.source_build_phase.add_file_reference(project.main_group.new_file(path)) }
%w[WhisperModels.json SpeakerModels.json VoiceIdentityModels.json Assets.xcassets].each { |name| app.resources_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Sources/iPhone', name))) }
app.build_configurations.each do |config|
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => 'cloud.karama.wiselife.speaker-verification', 'PRODUCT_NAME' => 'WiseNote', 'PRODUCT_MODULE_NAME' => 'WiseNote', 'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'INFOPLIST_KEY_CFBundleDisplayName' => 'Speaker Check', 'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES', 'TARGETED_DEVICE_FAMILY' => '1', 'CODE_SIGN_IDENTITY' => '-', 'CODE_SIGNING_ALLOWED' => 'YES')
end
[['https://github.com/argmaxinc/WhisperKit.git', '0.18.0', %w[WhisperKit SpeakerKit]], ['https://github.com/huggingface/swift-transformers.git', '1.1.6', %w[Hub Tokenizers]]].each do |url, version, products|
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = url; package.requirement = { 'kind' => 'exactVersion', 'version' => version }
  project.root_object.package_references << package
  products.each do |name|
    product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    product.package = package; product.product_name = name; app.package_product_dependencies << product
    file = project.new(Xcodeproj::Project::Object::PBXBuildFile); file.product_ref = product; app.frameworks_build_phase.files << file
  end
end
test = project.new_target(:unit_test_bundle, 'SpeakerTests', :ios, '26.0')
%w[NotesDiarizationTests.swift SpeakerResourceTests.swift VoiceEnrollmentTests.swift PhoneRecorderEnrollmentTests.swift].each { |file| test.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Tests', file))) }
test.add_dependency(app)
test.build_configurations.each do |config|
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => 'cloud.karama.wiselife.speaker-tests', 'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/WiseNote.app/WiseNote', 'BUNDLE_LOADER' => '$(TEST_HOST)', 'CODE_SIGN_IDENTITY' => '-')
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, test, launch_target: true)
scheme.save_as(project.path, 'SpeakerVerification', true)
puts project.path
