require 'json'
require 'shellwords'

# Shared by CocoaPods and the project generator. Apply with `pod install` after editing JSON.
module WristNotesBuildFeatures
  FLAG = 'WISELIFE_EUREKA_RING'.freeze
  SOURCES = {
    'WristNotes' => %w[EurekaRingModel.swift RingTransferStore.swift],
    'RingIntegrationTests' => %w[RingIntegrationTests.swift]
  }.freeze

  def self.enabled?(root)
    value = JSON.parse(File.read(File.join(root, 'Config/BuildFeatures.json'))).fetch('eurekaRing')
    raise ArgumentError, 'eurekaRing must be true or false' unless value == true || value == false
    value
  end

  def self.apply(project, enabled:)
    project.targets.each do |target|
      sources = SOURCES[target.name]
      next unless sources
      target.build_configurations.each do |configuration|
        settings = configuration.build_settings
        flags = tokens(settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']) - [FLAG]
        flags.unshift('$(inherited)') unless flags.include?('$(inherited)')
        flags << FLAG if enabled
        settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = flags.uniq
        excluded = tokens(settings['EXCLUDED_SOURCE_FILE_NAMES']) - sources
        excluded.unshift('$(inherited)') unless excluded.include?('$(inherited)')
        excluded.concat(sources) unless enabled
        settings['EXCLUDED_SOURCE_FILE_NAMES'] = excluded.uniq
        settings['WISELIFE_EUREKA_RING_ENABLED'] = enabled ? 'YES' : 'NO'
      end
    end
  end

  def self.tokens(value)
    value.is_a?(Array) ? value.dup : Shellwords.split(value.to_s)
  end
end
