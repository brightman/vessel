#!/usr/bin/env ruby
# Ensure receiver diagnostics are rendered on the Watch details screen that users open
# from the Daybook hardware sheet, rather than only on the legacy NotesList popover.
source = File.read(File.expand_path('../Sources/iPhone/DaybookView.swift', __dir__))
watch_sheet = source[/private var watchSheet: some View \{(.*?)\n    private var watchSyncActions:/m, 1]
abort 'Apple Watch detail sheet is missing' unless watch_sheet
abort 'Watch detail sheet does not show iPhone transfer diagnostics' unless
  watch_sheet.include?('iPhone 最近传输事件') &&
  watch_sheet.include?('model.watchStatus.diagnosticEvents') &&
  watch_sheet.include?('暂无传输事件')

puts 'Watch transfer diagnostics view: passed'

phone = File.read(File.expand_path('../Sources/iPhone/PhoneConnectivity.swift', __dir__))
abort 'Watch file callback is not visible in iPhone transfer diagnostics' unless
  phone.include?('recordDiagnostic("iPhone 收到录音文件"') &&
  phone.include?('recordDiagnostic("录音文件校验失败"')

puts 'iPhone Watch file callback diagnostics: passed'

watch = File.read(File.expand_path('../Sources/Watch/WatchContentView.swift', __dir__))
abort 'Long recordings are missing a swipe-to-delete action' unless
  watch.include?('.swipeActions(edge: .trailing, allowsFullSwipe: false)') &&
  watch.include?('recorder.delete(item.id)')
abort 'Watch deletion does not explain preservation of the iPhone copy' unless
  watch.include?('删除 Watch 副本') &&
  watch.include?('iPhone 上的副本会保留')
abort 'Watch diagnostics does not show live file-transfer activity' unless
  watch.include?('系统文件队列') &&
  watch.include?('系统正在传输') &&
  watch.include?('TimelineView(.periodic(from: .now, by: 5))') &&
  watch.include?('diagnosticFileTransferStatus')

puts 'Watch long recording deletion UI: passed'
