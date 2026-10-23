import Foundation

/// Only used by test_ios.sh. The production App never creates fixture summaries.
@main struct PhoneFixtureServer {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { return }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let store = try DesktopStore(url: root.appendingPathComponent("fixture.sqlite3"))
        let server = DesktopSyncServer(serverID: UUID().uuidString, identity: try DesktopTLSIdentity.ephemeral(), store: store)
        server.onReady = { port in
            Task {
                let code = await server.pairingCode(host: "127.0.0.1", port: port)
                try Data(code.url.utf8).write(to: output, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            }
        }
        server.onChange = {
            do {
                for item in try store.items() where item.summary == nil && item.transcript.isFinal && !item.transcript.text.isEmpty {
                    let summary = DesktopSummary(id: UUID(), recordID: item.transcript.id, inputHash: item.transcript.contentHash,
                        model: "iOS transport fixture", generatedAt: .now, markdown: "## 概览\n手机端到端测试记录已保存。 [S1]",
                        references: [.init(id: "S1", start: item.transcript.spans.first?.start, end: item.transcript.spans.first?.end, speaker: nil, text: String(item.transcript.text.prefix(100)))])
                    try store.save(summary, item: item)
                }
            } catch { fputs("Fixture save failed\n", stderr) }
        }
        try server.start()
        while !Task.isCancelled { try await Task.sleep(nanoseconds: 30_000_000_000) }
    }
}
