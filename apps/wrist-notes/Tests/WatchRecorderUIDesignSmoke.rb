#!/usr/bin/env ruby

source = File.read(File.expand_path("../Sources/Watch/WatchContentView.swift", __dir__))

required_copy = ["已同步", "待同步", "同步中"]
missing = required_copy.reject { |copy| source.include?(copy) }
abort "Watch recording rows need compact sync states: #{missing.join(', ')}" unless missing.empty?

if source.include?("已保存 \\(progress.savedChunkCount)/\\(progress.sealedChunkCount) 个已封口分片到 iPhone")
  abort "Chunk-level transfer details should stay out of the recording list"
end

puts "Watch recorder UI design contract passed"
