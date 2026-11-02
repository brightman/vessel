# Create an isolated UI test runner for the already-installed native app.
# Build/install WiseLife first, then xcodebuild test this project on the same simulator.
require 'xcodeproj'
require 'fileutils'
root = File.expand_path('..', __dir__)
output = ARGV[0] || '/private/tmp/wiselife-keyboard-ui'
FileUtils.mkdir_p(output)
project = Xcodeproj::Project.new(File.join(output, 'KeyboardUI.xcodeproj'))
tests = project.new_target(:ui_test_bundle, 'KeyboardUI', :ios, '26.0')
tests.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root, 'Tests/KeyboardInteractionUITests.swift')))
tests.build_configurations.each do |config|
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => 'cloud.karama.wiselife.keyboard-tests',
    'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES',
    'TARGETED_DEVICE_FAMILY' => '1', 'CODE_SIGN_IDENTITY' => '-')
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(tests)
scheme.add_test_target(tests)
scheme.save_as(project.path, 'KeyboardUI', true)
puts project.path
