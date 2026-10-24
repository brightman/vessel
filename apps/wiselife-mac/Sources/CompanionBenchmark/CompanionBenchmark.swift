import Foundation
import CompanionCore
import CompanionMLX

@main struct CompanionBenchmark {
    struct Sample: Codable {
        let task: String
        let result: GenerationResult
        let system: SystemSample
    }
    struct Report: Codable {
        let createdAt: Date
        let os: String
        let hardware: String
        let chip: String
        let xcode: String
        let physicalMemory: UInt64
        let model: CatalogModel
        let loadSeconds: Double
        let contextLimit: Int
        let samples: [Sample]
        let timeline: [TimedSystemSample]
        let acceptance: String
    }
    struct TimedSystemSample: Codable, Sendable { let date: Date; let system: SystemSample }
    actor Sampler {
        private var values: [TimedSystemSample] = []
        func sample() { values.append(.init(date: Date(), system: .current())) }
        func all() -> [TimedSystemSample] { values }
    }
    static func sysctlString(_ name: String) -> String {
        var count = 0
        guard sysctlbyname(name, nil, &count, nil, 0) == 0, count > 0 else { return "unavailable" }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname(name, &bytes, &count, nil, 0) == 0 else { return "unavailable" }
        return String(cString: bytes)
    }
    static func xcodeVersion() -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild"); process.arguments = ["-version"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unavailable" }
        catch { return "unavailable" }
    }
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--check-metal") {
            let value = await MLXTextEngine().verifyMetal()
            guard value == 6 else { exit(1) }
            print("MLX Metal check passed: 1 + 2 + 3 = 6. No model weights loaded.")
            return
        }
        guard args.contains("--run"), let index = args.firstIndex(of: "--model"), args.indices.contains(index + 1) else {
            print("Usage: CompanionBenchmark --run --model <catalog-model-id> [--download] [--minutes 30] --output <report.json>\nRuns synthetic Chinese tasks. Download requires --download. No M3 acceptance is inferred.")
            return
        }
        func argument(_ key: String) -> String? { args.firstIndex(of: key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        do {
            guard let model = try CatalogModel.bundled().first(where: { $0.id == args[index + 1] }),
                  let output = argument("--output") else { throw ServiceError.invalidRequest }
            let store = try ModelStore()
            if args.contains("--download") {
                print("Downloading explicitly selected \(model.id) @ \(model.revision), \(model.license)")
                try await store.install(model) { _ in }
            }
            let directory = try await store.verifiedDirectory(model)
            let sampler = Sampler()
            let monitor = Task {
                while !Task.isCancelled { await sampler.sample(); do { try await Task.sleep(for: .seconds(1)) } catch { return } }
            }
            defer { monitor.cancel() }
            let runtime = ModelRuntime(engine: MLXTextEngine())
            try await runtime.load(model.id, directory: directory)
            let load = await runtime.snapshot().loadSeconds ?? 0
            let source = "[1] 周一我和小林讨论了新产品的发布计划，决定周五完成测试。[2] 小林负责测试，我负责整理说明文档。[3] 周三检查进度时，测试已完成一半，没有讨论具体预算。"
            let tasks = [
                ("summary", "用中文概括材料中的三点事实，不添加推测。"),
                ("title", "为材料拟一个中文标题，不超过12个字，只输出标题。"),
                ("citation", "谁负责测试？只根据材料回答，并标注原文编号，如[2]。"),
                ("insight-json", "只输出合法JSON，格式为{\"insight\":\"一句中文观察\",\"source_ids\":[2]}，不添加材料之外的事实。"),
                ("content-decision", "判断材料是否包含明确待办。只输出合法JSON，格式为{\"has_action\":true,\"action\":\"中文待办\",\"source_ids\":[1,2]}。")
            ]
            let until = Date().addingTimeInterval(max(0, Double(argument("--minutes") ?? "0") ?? 0) * 60)
            var samples: [Sample] = []
            repeat {
                for (name, instruction) in tasks {
                    let result = try await runtime.generate(.init(model: model.id, system: instruction, user: source, maxTokens: 512, temperature: 0), device: UUID())
                    samples.append(.init(task: name, result: result, system: .current()))
                }
            } while Date() < until
            await runtime.shutdown()
            monitor.cancel(); await monitor.value
            let report = Report(createdAt: Date(), os: ProcessInfo.processInfo.operatingSystemVersionString,
                hardware: sysctlString("hw.model"), chip: sysctlString("machdep.cpu.brand_string"), xcode: xcodeVersion(), physicalMemory: ProcessInfo.processInfo.physicalMemory,
                model: model, loadSeconds: load, contextLimit: 8192, samples: samples,
                timeline: await sampler.all(),
                acceptance: "UNREVIEWED: manually review Chinese outputs and memory/thermal samples on the exact M3 Air. No automatic product pass.")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
            print("Saved \(samples.count) synthetic samples. Manual acceptance review required.")
        } catch {
            FileHandle.standardError.write(Data("Benchmark failed: \((error as? ServiceError)?.message ?? "model or file operation failed")\n".utf8))
            exit(1)
        }
    }
}
