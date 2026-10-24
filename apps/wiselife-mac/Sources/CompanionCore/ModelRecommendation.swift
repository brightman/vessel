import Foundation
import Darwin

public struct MacHardware: Sendable, Equatable {
    public let memoryBytes: UInt64
    public let chip: String
    public let isAppleSilicon: Bool
    public var memoryGB: Int { Int(memoryBytes / 1_073_741_824) }
    public init(memoryBytes: UInt64, chip: String, isAppleSilicon: Bool) {
        self.memoryBytes = memoryBytes; self.chip = chip; self.isAppleSilicon = isAppleSilicon
    }
    public static func current() -> Self {
        var length = 0
        var chip = "Apple silicon"
        if sysctlbyname("machdep.cpu.brand_string", nil, &length, nil, 0) == 0, length > 0 {
            var bytes = [CChar](repeating: 0, count: length)
            if sysctlbyname("machdep.cpu.brand_string", &bytes, &length, nil, 0) == 0 { chip = String(cString: bytes) }
        }
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return .init(memoryBytes: ProcessInfo.processInfo.physicalMemory, chip: chip, isAppleSilicon: appleSilicon)
    }
}

/// Conservative selection within the pinned catalog, not a measured performance
/// guarantee. Disk weight size is deliberately not used as a runtime RAM estimate.
public enum ModelRecommendation {
    public static let balanced = "mlx-community/Qwen3-4B-4bit"
    public static let lightweight = "mlx-community/Qwen3-1.7B-4bit"
    public static func suggestedMemoryGB(for modelID: String) -> Int? {
        switch modelID { case balanced: 16; case lightweight: 8; default: nil }
    }
    public static func fits(_ modelID: String, hardware: MacHardware) -> Bool {
        guard hardware.isAppleSilicon, let minimum = suggestedMemoryGB(for: modelID) else { return false }
        return hardware.memoryBytes >= UInt64(minimum) * 1_073_741_824
    }
    public static func preferredID(hardware: MacHardware, catalog: [CatalogModel]) -> String? {
        [balanced, lightweight].first { id in
            fits(id, hardware: hardware) && catalog.contains(where: { $0.id == id })
        }
    }
    public static func explanation(for modelID: String, hardware: MacHardware) -> String {
        if !fits(modelID, hardware: hardware) {
            return "建议 \(suggestedMemoryGB(for: modelID) ?? 16) GB 或以上统一内存。"
        }
        if modelID == balanced { return "适合这台 \(hardware.memoryGB) GB Mac，优先用于中文总结、标题和问答。" }
        return "更轻量，适合同时运行其他应用或内存比较紧张时使用。"
    }
}
