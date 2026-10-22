require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require 'open3'
require 'xcodeproj'

class BuildFeaturesSmoke < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def pod_dependencies(enabled)
    Dir.mktmpdir('wiselife-build-features') do |root|
      FileUtils.cp(File.join(ROOT, 'Podfile'), root)
      FileUtils.mkdir_p(File.join(root, 'Config'))
      FileUtils.mkdir_p(File.join(root, 'scripts'))
      helper = File.join(ROOT, 'scripts/build_features.rb')
      FileUtils.cp(helper, File.join(root, 'scripts')) if File.file?(helper)
      File.write(File.join(root, 'Config/BuildFeatures.json'), JSON.generate('eurekaRing' => enabled))
      output, error, status = Open3.capture3('pod', 'ipc', 'podfile', File.join(root, 'Podfile'))
      assert status.success?, error + output
      collect_dependencies(YAML.load(output))
    end
  end

  def collect_dependencies(node)
    case node
    when Hash
      own = Array(node['dependencies']).flat_map { |dependency| dependency.is_a?(Hash) ? dependency.keys : dependency }
      own + node.reject { |key, _| key == 'dependencies' }.values.flat_map { |value| collect_dependencies(value) }
    when Array then node.flat_map { |value| collect_dependencies(value) }
    else []
    end
  end

  # Catches restoring an unconditional native dependency in the default build.
  def test_disabled_build_does_not_resolve_native_ring_pods
    assert_empty pod_dependencies(false)
  end

  # Catches a switch that hides Swift code but cannot restore native SDK dependencies.
  def test_enabled_build_resolves_all_three_native_modules
    assert_equal %w[BRBluetoothLib BRRecorderCore BRRecorderOpus], pod_dependencies(true).uniq.sort
  end

  # Catches non-reversible exclusions or overwriting unrelated developer build settings.
  def test_switch_round_trip_preserves_other_flags_and_watch_configuration
    helper = File.join(ROOT, 'scripts/build_features.rb')
    assert File.file?(helper), 'Shared build-feature configuration has not been implemented'
    require helper
    Dir.mktmpdir('wiselife-feature-project') do |root|
      project = Xcodeproj::Project.new(File.join(root, 'App.xcodeproj'))
      phone = project.new_target(:application, 'WristNotes', :ios, '26.0')
      tests = project.new_target(:unit_test_bundle, 'RingIntegrationTests', :ios, '26.0')
      watch = project.new_target(:application, 'WristNotesWatch', :watchos, '10.0')
      project.targets.each do |target|
        target.build_configurations.each do |config|
          config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) DEBUG ANOTHER_FEATURE'
          config.build_settings['EXCLUDED_SOURCE_FILE_NAMES'] = ['Unrelated.swift']
        end
      end
      original_watch = Marshal.load(Marshal.dump(watch.build_configurations.map(&:build_settings)))
      [false, true, false].each do |enabled|
        WristNotesBuildFeatures.apply(project, enabled: enabled)
        [phone, tests].each do |target|
          target.build_configurations.each do |config|
            flags = Array(config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'])
            assert_includes flags, 'ANOTHER_FEATURE'
            assert_equal enabled, flags.include?('WISELIFE_EUREKA_RING')
            excluded = Array(config.build_settings['EXCLUDED_SOURCE_FILE_NAMES'])
            assert_includes excluded, 'Unrelated.swift'
            names = target == phone ? %w[EurekaRingModel.swift RingTransferStore.swift] : %w[RingIntegrationTests.swift]
            names.each { |name| assert_equal !enabled, excluded.include?(name) }
          end
        end
      end
      assert_equal original_watch, watch.build_configurations.map(&:build_settings)
    end
  end
end
