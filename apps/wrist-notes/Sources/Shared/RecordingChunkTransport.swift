import Foundation
import Darwin

/// Stable identity is independent of the short-lived handshake nonce.
struct RecordingCounterpart: Codable, Equatable {
    let phoneID: UUID
    let pairingID: UUID
    var key: String { "\(phoneID.uuidString)_\(pairingID.uuidString)" }
}
struct RecordingTransferBinding: Codable, Equatable {
    let counterpart: RecordingCounterpart
    let watchID: UUID
    let nonce: UUID
}
struct RecordingCapabilityHello: Codable, Equatable {
    var version = 2
    let watchID: UUID
    let nonce: UUID
    var generation = 0
}
struct RecordingCapabilityReply: Codable {
    let version: Int
    let versions: [Int]
    let binding: RecordingTransferBinding
    // Missing in older V2 peers. Optional decoding preserves their wire reply.
    var maximumChunkDuration: TimeInterval? = nil
    var supportsLocationSamples: Bool? = nil
}
struct RecordingWireEnvelope<Payload: Codable & Equatable>: Codable, Equatable {
    var version = 2
    let binding: RecordingTransferBinding
    let payload: Payload
    func validate(binding expected: RecordingTransferBinding) throws {
        guard version == RecordingChunkProtocol.version, binding == expected else { throw RecordingTransportError.invalidEnvelope }
    }
}
struct RecordingSavedChunk: Codable, Equatable {
    let receipt: RecordingChunkReceipt
    let savedAt: Date
    func validate() throws {
        try receipt.validate()
        guard savedAt.timeIntervalSinceReferenceDate.isFinite else { throw RecordingTransportError.invalidEnvelope }
    }
}
enum RecordingTransferAcknowledgement {
    case chunk(RecordingWireEnvelope<RecordingSavedChunk>)
    case end(RecordingWireEnvelope<RecordingSessionEnd>)
    case location(RecordingWireEnvelope<RecordingLocationSample>)
    var binding: RecordingTransferBinding {
        switch self { case .chunk(let v): v.binding; case .end(let v): v.binding; case .location(let v): v.binding }
    }
    func message() throws -> [String: Any] {
        switch self {
        case .chunk(let value): return [RecordingChunkProtocol.receiptKey: try JSONEncoder().encode(value)]
        case .end(let value): return [RecordingChunkWire.endReceiptKey: try JSONEncoder().encode(value)]
        case .location(let value): return [RecordingChunkWire.locationReceiptKey: try JSONEncoder().encode(value)]
        }
    }
}
enum RecordingTransportError: Error { case invalidEnvelope, unsupported, unavailable, conflict, invalidStorage }

/// Small recording control messages use the acknowledged realtime path while
/// the counterpart is reachable, with durable user-info delivery as fallback.
enum RecordingReachableMessageDelivery {
    static func submit(isReachable: Bool,
                       sendImmediately: (@escaping (Bool) -> Void) -> Void,
                       queue: @escaping () -> Void) {
        guard isReachable else { queue(); return }
        sendImmediately { accepted in
            if !accepted { queue() }
        }
    }
}

enum RecordingChunkWire {
    static let locationKey = "wiseLifeRecordingLocationV2"
    static let locationReceiptKey = "wiseLifeRecordingLocationReceiptV2"
    static let endReceiptKey = "wiseLifeRecordingEndReceiptV2"
    static let offerKey = "wiseLifeRecordingCapabilityOfferV2"
    static let maximumMetadataBytes = 128 * 1024
    /// A recording-family key always owns dispatch, even when future/invalid. Never fall through to V1.
    static func owns(_ metadata: [String: Any]) -> Bool {
        metadata.keys.contains { $0.hasPrefix("wiseLifeRecording") }
    }
    static func decode<T: Decodable>(_ type: T.Type, key: String, from metadata: [String: Any]) throws -> T {
        guard metadata.keys.filter({ $0.hasPrefix("wiseLifeRecording") }).count == 1,
              metadata["id"] == nil, metadata["ack"] == nil,
              let data = metadata[key] as? Data, data.count <= maximumMetadataBytes else {
            throw RecordingTransportError.invalidEnvelope
        }
        return try JSONDecoder().decode(type, from: data)
    }
    static func matches(_ receipt: RecordingChunkReceipt, _ chunk: RecordingChunkDescriptor) -> Bool {
        receipt.sessionID == chunk.sessionID && receipt.chunkID == chunk.id && receipt.ordinal == chunk.ordinal &&
        receipt.sha256.caseInsensitiveCompare(chunk.sha256) == .orderedSame
    }
    /// Only retire a decodable V2 job from this Watch after a new binding has
    /// been accepted. Its old envelope can no longer pass the phone's validation.
    static func obsoleteChunkID(in metadata: [String: Any], binding: RecordingTransferBinding) -> UUID? {
        guard let value = try? decode(RecordingWireEnvelope<RecordingChunkDescriptor>.self,
                                     key: RecordingChunkProtocol.chunkKey, from: metadata),
              value.version == RecordingChunkProtocol.version,
              value.binding.watchID == binding.watchID, value.binding != binding else { return nil }
        return value.payload.id
    }
}

/// Atomic, flushed private metadata. Complete protection is preserved on iPhone.
/// Audio validation is always delegated to RecordingAudioFile.
enum RecordingTransportDisk {
    static func directory(_ url: URL) throws {
        try RecordingAudioFile.requireSafePath(url)
        var created: [URL] = [], cursor = url
        while !FileManager.default.fileExists(atPath: cursor.path), cursor.path != "/" {
            created.append(cursor); cursor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Protect and flush every newly created parent too, not just the leaf.
        for component in Set(created + [url]).sorted(by: { $0.pathComponents.count < $1.pathComponents.count }) {
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: component.path)
            #endif
            var value = component; var resources = URLResourceValues(); resources.isExcludedFromBackup = true
            try value.setResourceValues(resources)
            try syncDirectory(component)
            try syncDirectory(component.deletingLastPathComponent())
        }
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        try RecordingAudioFile.requireSafePath(url)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        try syncFile(url); try syncDirectory(url.deletingLastPathComponent())
    }
    static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try RecordingAudioFile.requireSafePath(url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= RecordingChunkWire.maximumMetadataBytes else { throw RecordingTransportError.invalidStorage }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    static func syncFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw RecordingTransportError.invalidStorage }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw RecordingTransportError.invalidStorage }
    }
}
