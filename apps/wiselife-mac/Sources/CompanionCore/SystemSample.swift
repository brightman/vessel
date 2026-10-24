import Foundation
import Darwin

public struct SystemSample: Codable, Sendable {
    public let peakProcessBytes: Int64
    public let pressure: String
    public let thermal: String
    public static func current() -> Self {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        var pressure: Int32 = 0, size = MemoryLayout<Int32>.size
        let status = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        let pressureText = status == 0 ? ([1: "normal", 2: "warning", 4: "critical"][Int(pressure)] ?? "unknown") : "unavailable"
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return .init(peakProcessBytes: Int64(usage.ru_maxrss), pressure: pressureText, thermal: thermal)
    }
}
