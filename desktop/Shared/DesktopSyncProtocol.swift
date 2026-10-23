import Foundation
import CryptoKit

enum DesktopSyncError: LocalizedError {
    case invalid(String), network, timeout, unauthorized, storage, model(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message), .model(let message): return message
        case .network: return "无法连接 Mac，请确认两端已打开、连接同一网络，并允许局域网访问。"
        case .timeout: return "连接超时，已保存的同步进度会在下次继续。"
        case .unauthorized: return "配对已失效，请在 Mac 上重新生成配对码。"
        case .storage: return "同步资料暂时无法保存，请检查存储空间后重试。"
        }
    }
}

enum DesktopSyncCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Integral milliseconds make the signed/content-hashed projection stable across platforms.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
            guard milliseconds.isFinite, milliseconds > Double(Int64.min), milliseconds < Double(Int64.max) else {
                throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath, debugDescription: "Invalid timestamp"))
            }
            var value = encoder.singleValueContainer(); try value.encode(Int64(milliseconds))
        }
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(Int64.self)
            return Date(timeIntervalSince1970: Double(value) / 1000)
        }
        return try decoder.decode(type, from: data)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func secret() -> String { UUID().uuidString + UUID().uuidString }
    static func tokenMatches(_ a: String, _ b: String) -> Bool {
        let lhs = Array(SHA256.hash(data: Data(a.utf8))), rhs = Array(SHA256.hash(data: Data(b.utf8)))
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct DesktopTranscriptSpan: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let start: Double?
    let end: Double?
    let speaker: String?
    let text: String
}

/// A deliberately narrow projection. No media paths, contacts, health, location or voiceprints.
struct DesktopTranscript: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let capturedAt: Date
    let duration: Double
    let captureDevice: String
    let kind: String
    let text: String
    let spans: [DesktopTranscriptSpan]
    let isFinal: Bool
    var contentHash: String { (try? DesktopSyncCodec.hash(DesktopSyncCodec.encode(self))) ?? "" }
    func validate() throws {
        guard id.count <= 160, (id.hasPrefix("legacyNote:") || id.hasPrefix("session:")),
              UUID(uuidString: String(id.split(separator: ":").last ?? "")) != nil,
              title.utf8.count <= 4096, text.utf8.count <= 5_000_000,
              duration.isFinite, duration >= 0, capturedAt.timeIntervalSince1970.isFinite,
              spans.count <= 100_000, Set(spans.map(\.id)).count == spans.count,
              captureDevice.count <= 128, kind.count <= 64 else { throw DesktopSyncError.invalid("转写数据无效或过大。") }
        for span in spans {
            guard span.id.count <= 160, span.text.utf8.count <= 1_000_000, (span.speaker?.count ?? 0) <= 100 else { throw DesktopSyncError.invalid("转写片段无效。") }
            if let start = span.start, let end = span.end {
                guard start.isFinite, end.isFinite, start >= 0, end >= start else { throw DesktopSyncError.invalid("转写时间轴无效。") }
            } else if span.start != nil || span.end != nil { throw DesktopSyncError.invalid("转写时间轴无效。") }
        }
    }
}

struct DesktopSyncEvent: Codable, Equatable, Sendable {
    let sequence: Int64
    let recordID: String
    let record: DesktopTranscript?
}

struct DesktopSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordID: String
    let inputHash: String
    let model: String
    let generatedAt: Date
    let markdown: String
    let references: [DesktopTranscriptSpan]
    var processingLocation: String? = nil
    var providerHost: String? = nil
    func validate() throws {
        guard inputHash.count == 64, markdown.utf8.count <= 200_000, !markdown.isEmpty,
              model.count <= 300, recordID.count <= 160, references.count <= 200,
              generatedAt.timeIntervalSince1970.isFinite, Set(references.map(\.id)).count == references.count,
              (processingLocation?.count ?? 0) <= 100, (providerHost?.count ?? 0) <= 300 else { throw DesktopSyncError.invalid("总结数据无效。") }
        for reference in references {
            guard reference.id.count <= 160, reference.text.count <= 1000, (reference.speaker?.count ?? 0) <= 100 else { throw DesktopSyncError.invalid("总结引用无效。") }
            if let start = reference.start, let end = reference.end {
                guard start.isFinite, end.isFinite, start >= 0, end >= start else { throw DesktopSyncError.invalid("总结引用时间无效。") }
            } else if reference.start != nil || reference.end != nil { throw DesktopSyncError.invalid("总结引用时间无效。") }
        }
    }
}

struct DesktopSummaryChange: Codable, Sendable {
    let sequence: Int64
    let summary: DesktopSummary
}

struct DesktopSyncRequest: Codable, Sendable {
    var version = 1
    let operation: String
    let serverID: String
    let deviceID: String
    let deviceName: String
    let credential: String
    var events: [DesktopSyncEvent] = []
    var summaryCursor: Int64 = 0
}

struct DesktopSyncResponse: Codable, Sendable {
    var version = 1
    let serverID: String
    var acknowledged: Int64 = 0
    var deviceToken: String? = nil
    var summaries: [DesktopSummaryChange] = []
    var hasMoreSummaries = false
    var error: String? = nil
}

struct DesktopPairingCode: Codable, Equatable, Sendable {
    let serverID: String
    let name: String
    let host: String
    let port: UInt16
    let certificateHash: String
    let secret: String
    let expiresAt: Date
    var url: String {
        let data = (try? DesktopSyncCodec.encode(self)) ?? Data()
        return "wiselife-sync://pair/" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func parse(_ value: String) throws -> Self {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "wiselife-sync://pair/"
        guard value.hasPrefix(prefix), value.count < 6000 else { throw DesktopSyncError.invalid("请扫描或粘贴 Mac 显示的 WiseLife 配对码。") }
        var encoded = String(value.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let code = try? DesktopSyncCodec.decode(Self.self, data),
              code.port > 0, code.certificateHash.count == 64, code.certificateHash.allSatisfy(\.isHexDigit),
              !code.secret.isEmpty, code.secret.count <= 160, code.serverID.count <= 100, code.name.count <= 128,
              isLocalHost(code.host), code.expiresAt > .now else { throw DesktopSyncError.invalid("配对码无效或已过期，请在 Mac 上重新生成。") }
        return code
    }
    static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("fe80:") || host.hasPrefix("fd") || host.hasPrefix("fc") { return host.contains(":") }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4, host.split(separator: ".").count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }
}

struct DesktopPairedPeer: Codable, Sendable {
    var code: DesktopPairingCode
    let deviceID: String
    let token: String
}
