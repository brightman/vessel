require 'xcodeproj'

# Shared by the generator and targeted project updates; never regenerates existing targets.
module WatchRecordingWidgetProject
  def self.apply(project, root:)
    watch = project.targets.find { |t| t.name == 'WristNotesWatch' }
    raise 'WristNotesWatch target is required' unless watch
    sources = project.main_group.groups.find { |g| g.path == 'Sources' } || project.main_group.new_group('Sources', 'Sources')
    group = lambda do |name|
      sources.groups.find { |g| g.path == name } || sources.new_group(name, name)
    end
    file = lambda do |g, name|
      g.files.find { |f| f.path == name } || g.new_file(name)
    end
    add_source = lambda do |target, reference|
      target.source_build_phase.add_file_reference(reference, true)
    end
    watch_group = group.call('Watch')
    add_source.call(watch, file.call(watch_group, 'WatchRecordingLauncher.swift'))
    shared_group = group.call('WatchRecordingShared')
    link = file.call(shared_group, 'WatchRecordingLink.swift')
    add_source.call(watch, link)

    widget_group = group.call('WatchRecordingWidget')
    widget = project.targets.find { |t| t.name == 'WiseLifeWatchRecordingWidget' } ||
      project.new_target(:app_extension, 'WiseLifeWatchRecordingWidget', :watchos, '10.0')
    add_source.call(widget, link)
    add_source.call(widget, file.call(widget_group, 'WatchRecordingWidget.swift'))
    widget.resources_build_phase.add_file_reference(file.call(widget_group, 'Localizable.xcstrings'), true)
    file.call(widget_group, 'Info.plist')
    info = Xcodeproj::Plist.read_from_path(File.join(root, 'Sources/Watch/Info.plist'))
    widget.build_configurations.each do |configuration|
      parent = watch.build_configurations.find { |c| c.name == configuration.name }.build_settings
      settings = configuration.build_settings
      settings['SWIFT_VERSION'] = '5.0'
      settings['PRODUCT_BUNDLE_IDENTIFIER'] = parent.fetch('PRODUCT_BUNDLE_IDENTIFIER') + '.recording-widget'
      settings['MARKETING_VERSION'] = parent['MARKETING_VERSION'] || info.fetch('CFBundleShortVersionString')
      settings['CURRENT_PROJECT_VERSION'] = parent['CURRENT_PROJECT_VERSION'] || info.fetch('CFBundleVersion')
      settings['GENERATE_INFOPLIST_FILE'] = 'YES'
      settings['INFOPLIST_FILE'] = 'Sources/WatchRecordingWidget/Info.plist'
      settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'WiseLife'
      settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
      settings['SKIP_INSTALL'] = 'YES'
      settings['TARGETED_DEVICE_FAMILY'] = '4'
      settings['WATCHOS_DEPLOYMENT_TARGET'] = '10.0'
      settings['CODE_SIGN_STYLE'] = parent['CODE_SIGN_STYLE'] || 'Automatic'
      settings['DEVELOPMENT_TEAM'] = parent['DEVELOPMENT_TEAM'] if parent['DEVELOPMENT_TEAM']
    end
    watch.add_dependency(widget) unless watch.dependencies.any? { |d| d.target == widget }
    embed = watch.copy_files_build_phases.find { |p| p.name == 'Embed Watch Recording Widget' } ||
      watch.new_copy_files_build_phase('Embed Watch Recording Widget')
    embed.dst_subfolder_spec = '13'
    embed.add_file_reference(widget.product_reference, true).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
    widget
  end
end
