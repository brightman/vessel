require 'xcodeproj'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'rexml/document'

root = File.expand_path('..', __dir__)

def check(root)
  path = File.join(root, 'WristNotes.xcodeproj')
  project = Xcodeproj::Project.open(path)
  phone, watch, activity, widget = %w[WristNotes WristNotesWatch WiseLifeRecordingActivity WiseLifeWatchRecordingWidget].map do |name|
    project.targets.find { |target| target.name == name } or abort "Missing target: #{name}"
  end
  phone.build_configurations.each do |configuration|
    [watch, activity, widget].each do |target|
      settings = target.build_configurations.find { |item| item.name == configuration.name }.build_settings
      %w[MARKETING_VERSION CURRENT_PROJECT_VERSION DEVELOPMENT_TEAM].each do |key|
        abort "#{target.name} #{configuration.name}: #{key} differs from iPhone" unless settings[key] == configuration.build_settings[key]
      end
    end
  end
  info = Xcodeproj::Plist.read_from_path(File.join(root, 'Sources/Watch/Info.plist'))
  abort 'Watch marketing version must use build settings' unless info['CFBundleShortVersionString'] == '$(MARKETING_VERSION)'
  abort 'Watch build number must use build settings' unless info['CFBundleVersion'] == '$(CURRENT_PROJECT_VERSION)'
  scheme = REXML::Document.new(File.read(File.join(path, 'xcshareddata/xcschemes/WristNotesWatch.xcscheme')))
  launch = REXML::XPath.first(scheme, '/Scheme/LaunchAction/BuildableProductRunnable/BuildableReference')
  abort 'Shared Watch scheme must launch the Watch target' unless launch && launch.attributes['BlueprintIdentifier'] == watch.uuid
  project
end

check(root)
Dir.mktmpdir('wiselife-watch-project-') do |temporary|
  %w[scripts Config Sources/Watch].each { |dir| FileUtils.mkdir_p(File.join(temporary, dir)) }
  %w[generate_project.rb build_features.rb watch_recording_widget_project.rb].each do |name|
    FileUtils.cp(File.join(root, 'scripts', name), File.join(temporary, 'scripts', name))
  end
  FileUtils.cp(File.join(root, 'Config/BuildFeatures.json'), File.join(temporary, 'Config'))
  FileUtils.cp(File.join(root, 'Sources/Watch/Info.plist'), File.join(temporary, 'Sources/Watch'))
  generate = lambda do
    output, status = Open3.capture2e(RbConfig.ruby, File.join(temporary, 'scripts/generate_project.rb'))
    abort output unless status.success?
    check(temporary)
  end
  project = generate.call
  project.targets.each do |target|
    target.build_configurations.each do |configuration|
      configuration.build_settings['DEVELOPMENT_TEAM'] = 'TESTTEAM01'
      next unless target.name == 'WristNotes'
      configuration.build_settings['MARKETING_VERSION'] = '2.3'
      configuration.build_settings['CURRENT_PROJECT_VERSION'] = configuration.name == 'Debug' ? '42' : '43'
    end
  end
  project.save
  project = generate.call
  phone = project.targets.find { |target| target.name == 'WristNotes' }
  phone.build_configurations.each do |configuration|
    abort 'Regeneration reset marketing version' unless configuration.build_settings['MARKETING_VERSION'] == '2.3'
    expected = configuration.name == 'Debug' ? '42' : '43'
    abort 'Regeneration reset build number' unless configuration.build_settings['CURRENT_PROJECT_VERSION'] == expected
  end
end
puts 'Watch install configuration: matching versions/teams, shared scheme and project regeneration passed'
