require 'xcodeproj'

repository = File.expand_path('../..', __dir__)
root = File.join(repository, 'apps/wrist-notes')
path = File.join(root, 'WristNotes.xcodeproj')
project = Xcodeproj::Project.open(path)
target = project.targets.find { |item| item.name == 'WristNotes' }
phone = project.main_group['Sources']['iPhone']
%w[PhoneDesktopSyncRepository.swift PhoneDesktopSyncModel.swift DesktopSyncViews.swift].each do |name|
  file = phone.files.find { |item| item.path == name } || phone.new_file(name)
  target.source_build_phase.add_file_reference(file, true)
end
shared = project.main_group['DesktopSync'] || project.main_group.new_group('DesktopSync', '../../desktop/Shared')
Dir.glob(File.join(repository, 'desktop/Shared/*.swift')).sort.each do |source|
  name = File.basename(source)
  next if name == 'SyncSQLite.swift'
  file = shared.files.find { |item| item.path == name } || shared.new_file(name)
  target.source_build_phase.add_file_reference(file, true)
end
project.save
tests = project.targets.find { |item| item.name == 'RingIntegrationTests' }
test_group = project.main_group['Tests']
name = 'DesktopSyncIntegrationTests.swift'
file = test_group.files.find { |item| item.path == name } || test_group.new_file(name)
tests.source_build_phase.add_file_reference(file, true)
tests.build_configurations.each do |configuration|
  configuration.build_settings['SWIFT_INCLUDE_PATHS'] = ['$(inherited)', '$(SRCROOT)/Vendor/SQLiteVector']
end
project.save
puts path
