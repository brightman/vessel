#!/usr/bin/env ruby

source = File.read(File.expand_path("../Sources/Watch/WatchContentView.swift", __dir__))

recorder = File.read(File.expand_path("../Sources/Watch/WatchRecorder.swift", __dir__))
abort "Recording rows must use the receipt-aware transfer status" unless source.include?("recorder.transferStatus(for: item)")
required_copy = ["iPhone 已保存", "传输失败", "系统传输中", "系统排队", "等待手机回执", "Watch 待发送"]
missing = required_copy.reject { |copy| (source + recorder).include?(copy) }
abort "Watch recording rows need compact sync states: #{missing.join(', ')}" unless missing.empty?

if source.include?("已保存 \\(progress.savedChunkCount)/\\(progress.sealedChunkCount) 个已封口分片到 iPhone")
  abort "Chunk-level transfer details should stay out of the recording list"
end

puts "Watch recorder UI design contract passed"
