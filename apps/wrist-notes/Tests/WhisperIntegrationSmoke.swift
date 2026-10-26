import Foundation

@main struct WhisperIntegrationSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 || (args.count == 5 && args[4] == "--offline") else {
            fatalError("usage: smoke manifest.json model-directory audio-file [--offline]")
        }
        let store = WhisperModelStore(root: URL(fileURLWithPath: args[2]), catalogURL: URL(fileURLWithPath: args[1]))
        for size in TranscriptionConfiguration.WhisperSize.allCases {
            let files = try store.files(for: size)
            print("Catalog \(size.rawValue): \(files.count) files / \(files.reduce(Int64(0)) { $0 + $1.bytes }) bytes")
        }
        if args.count == 5 { try store.validate(.tiny) }
        else {
            try await store.download(.tiny) { progress in
                if progress.fraction == 1 { print("Tiny download bytes complete; verifying installation") }
            }
        }
        precondition(store.installed(.tiny))
        try store.validate(.tiny)
        let reloaded = WhisperModelStore(root: store.root, catalogURL: store.catalogURL)
        precondition(reloaded.installed(.tiny), "installation survives a new store instance")
        let service = LocalTranscriptionService(store: reloaded)
        var config = TranscriptionConfiguration(engine: .whisper, whisperSize: .tiny, whisperLanguage: "en")
        let specified = try await service.transcribe(fileURL: URL(fileURLWithPath: args[3]), configuration: config)
        precondition(specified.lowercased().contains("country") && specified.lowercased().contains("ask not"), "expected recognizable JFK test speech")
        print("Specified English: \(specified)")
        config.whisperLanguage = "auto"
        let automatic = try await service.transcribe(fileURL: URL(fileURLWithPath: args[3]), configuration: config)
        precondition(automatic.lowercased().contains("country"))
        print("Automatic: \(automatic)")
        // A truncated asset cannot be treated as installed, even with a valid marker.
        let file = store.folder(for: .tiny).appendingPathComponent("tokenizer_config.json")
        let original = try Data(contentsOf: file)
        defer { try? original.write(to: file, options: .atomic) }
        try Data(original.prefix(20)).write(to: file)
        precondition(!store.installed(.tiny))
        print("PASS: pinned manifest, verified installation, explicit/auto local transcription, incomplete-file rejection")
    }
}
