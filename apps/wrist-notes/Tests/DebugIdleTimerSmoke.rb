source = File.read(File.join(__dir__, '..', 'Sources', 'iPhone', 'WristNotesApp.swift'))
expected_debug_initialization = /struct WristNotesApp: App \{.*?init\(\)\s*\{\s*#if DEBUG\s*UIApplication\.shared\.isIdleTimerDisabled = true\s*#endif/m
abort 'iPhone app must disable the idle timer only during DEBUG initialization' unless
  source.match?(expected_debug_initialization)

puts 'Debug idle timer smoke passed'
