require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'WristNotes.xcodeproj'))
watch = project.targets.find { |t| t.name == 'WristNotesWatch' }
widget = project.targets.find { |t| t.name == 'WiseLifeWatchRecordingWidget' }
abort 'Watch recording complication extension is missing' unless widget
phone = project.targets.find { |t| t.name == 'WristNotes' }
abort 'Widget must be a watchOS extension' unless widget.product_type == 'com.apple.product-type.app-extension' && widget.platform_name == :watchos
abort 'Watch must depend on its complication extension' unless watch.dependencies.any? { |d| d.target == widget }
embed = watch.copy_files_build_phases.find { |p| p.files_references.include?(widget.product_reference) }
abort 'Widget must be embedded in Watch PlugIns' unless embed && embed.dst_subfolder_spec == '13'
abort 'Watch widget must not be embedded directly in iPhone' if phone.copy_files_build_phases.any? { |p| p.files_references.include?(widget.product_reference) }

watch_sources = watch.source_build_phase.files_references.map { |f| File.basename(f.path) }
widget_sources = widget.source_build_phase.files_references.map { |f| File.basename(f.path) }
phone_sources = phone.source_build_phase.files_references.map { |f| File.basename(f.path) }
abort 'Watch launch routing is not compiled into the Watch app' unless %w[WatchRecordingLauncher.swift WatchRecordingLink.swift].all? { |s| watch_sources.include?(s) }
abort 'Widget entry point and URL must be compiled together' unless widget_sources.sort == %w[WatchRecordingLink.swift WatchRecordingWidget.swift].sort
abort 'Watch widget code leaked into iPhone' unless (phone_sources & %w[WatchRecordingLink.swift WatchRecordingLauncher.swift WatchRecordingWidget.swift]).empty?
abort 'Widget-only main leaked into Watch app' if watch_sources.include?('WatchRecordingWidget.swift')
abort 'Missing widget localization resource' unless widget.resources_build_phase.files_references.any? { |r| File.basename(r.path) == 'Localizable.xcstrings' }
info = Xcodeproj::Plist.read_from_path(File.join(root, 'Sources/Watch/Info.plist'))
abort 'Watch URL scheme must be registered' unless info.fetch('CFBundleURLTypes').any? { |t| t['CFBundleURLSchemes'].include?('wiselife-watch') }
widget.build_configurations.each do |c|
  settings = c.build_settings
  parent = watch.build_configurations.find { |w| w.name == c.name }.build_settings
  abort 'Wrong widget bundle scope' unless settings['PRODUCT_BUNDLE_IDENTIFIER'].start_with?(parent['PRODUCT_BUNDLE_IDENTIFIER'] + '.')
  abort 'Widget version must match Watch app' unless settings['CURRENT_PROJECT_VERSION'] == (parent['CURRENT_PROJECT_VERSION'] || info['CFBundleVersion'])
  abort 'Widget must support watchOS 10' unless settings['WATCHOS_DEPLOYMENT_TARGET'] == '10.0'
  abort 'Widget extension-only API guard missing' unless settings['APPLICATION_EXTENSION_API_ONLY'] == 'YES'
end
puts 'Watch complication target, source separation, URL registration and embedding: passed'
