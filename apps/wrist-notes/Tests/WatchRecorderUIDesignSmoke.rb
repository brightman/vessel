#!/usr/bin/env ruby

source = File.read(File.expand_path("../Sources/Watch/WatchContentView.swift", __dir__))

presentation = File.read(File.expand_path("../Sources/Watch/WatchRecordingLibrary.swift", __dir__))
required_copy = ["已同步", "等待传输", "传输中", "等待手机确认", "传输失败"]
missing = required_copy.reject { |copy| presentation.include?(copy) }
abort "Watch recording rows need compact sync states: #{missing.join(', ')}" unless missing.empty?

if source.include?("已保存 \\(progress.savedChunkCount)/\\(progress.sealedChunkCount) 个已封口分片到 iPhone")
  abort "Chunk-level transfer details should stay out of the recording list"
end

puts "Watch recorder UI design contract passed"
