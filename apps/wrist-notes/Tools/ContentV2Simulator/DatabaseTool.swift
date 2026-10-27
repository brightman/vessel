import Foundation

/// Development tool: prepares normal application schema without launching inference.
@main struct DatabaseTool {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw ToolError.arguments }
        let db = try DaybookDatabase(url: URL(fileURLWithPath: args[2]))
        if args[1] == "init" { print("schema_ready"); return }
        guard args.count == 4, args[1] == "reconcile",
              let id = UUID(uuidString:args[3]) else { throw ToolError.arguments }
        let source = AudioSourceID(kind:.legacyNote,id:id)
        try ContentSegmentRepository(database:db).reconcile(sourceID:source)
        print("content_prepared")
    }
    enum ToolError: Error { case arguments }
}
