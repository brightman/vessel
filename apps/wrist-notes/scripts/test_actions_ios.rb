require 'xcodeproj'
require 'fileutils'
root = File.expand_path('..', __dir__)
output = ARGV.fetch(0)
FileUtils.mkdir_p(output)
project = Xcodeproj::Project.new(File.join(output, 'Actions.xcodeproj'))
app = project.new_target(:application, 'Actions', :ios, '26.0')
%w[DaybookDatabase ActionItem ActionStore ActionSystemService DaybookReminderPersistence DaybookReminderStore AppleReminderService].each { |name| app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root,'Sources/iPhone',name+'.swift'))) }
File.write(File.join(output,'App.swift'), "import SwiftUI\n@main struct TestApp: App { var body: some Scene { WindowGroup { Text(\"Actions verification\") } } }\n")
app.source_build_phase.add_file_reference(project.main_group.new_file(File.join(output,'App.swift')))
app.build_configurations.each { |c| c.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER'=>'cloud.karama.wiselife.action-verification','PRODUCT_NAME'=>'Actions','PRODUCT_MODULE_NAME'=>'WiseLifeActionVerification','SWIFT_VERSION'=>'5.0','GENERATE_INFOPLIST_FILE'=>'YES','INFOPLIST_KEY_UILaunchScreen_Generation'=>'YES','TARGETED_DEVICE_FAMILY'=>'1','CODE_SIGN_IDENTITY'=>'-') }
test = project.new_target(:unit_test_bundle,'ActionTests',:ios,'26.0')
test.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root,'Tests/ActionIntegrationTests.swift')))
test.add_dependency(app)
test.build_configurations.each { |c| c.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER'=>'cloud.karama.wiselife.action-tests','SWIFT_VERSION'=>'5.0','GENERATE_INFOPLIST_FILE'=>'YES','TEST_HOST'=>'$(BUILT_PRODUCTS_DIR)/Actions.app/Actions','BUNDLE_LOADER'=>'$(TEST_HOST)','CODE_SIGN_IDENTITY'=>'-') }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app,test,launch_target:true)
scheme.save_as(project.path,'Actions',true)
