import Foundation

struct VoiceProfile: Codable, Sendable, Equatable {
    let id: UUID
    let enrolledAt: Date
    let recordingDuration: TimeInterval
    let modelID: String
    let embeddings: [[Float]]
}

enum VoiceIdentityError: Error, LocalizedError {
    case invalidProfile, inconsistentVoice, invalidAudio, incompatibleModel
    var errorDescription: String? {
        switch self {
        case .invalidProfile: return NSLocalizedString("声音档案无效，请重新录制 30～60 秒清晰的独立讲话。", comment: "")
        case .inconsistentVoice: return NSLocalizedString("声音特征不一致，请在安静环境中独自讲话并重新录制。", comment: "")
        case .invalidAudio: return NSLocalizedString("可用于识别的清晰讲话片段不足，请重新录制。", comment: "")
        case .incompatibleModel: return NSLocalizedString("声纹模型不兼容，请在语音转写设置中重新下载资源。", comment: "")
        }
    }
}

enum VoiceIdentityPolicy {
    static let modelID = "wespeaker-v2-7eab74f3463c736418d0eb10296261ae581146c9"
    // Deliberately conservative, uncalibrated thresholds. Never adapt from inferred matches.
    static let enrollmentSimilarity: Float = 0.80
    static let matchSimilarity: Float = 0.82
    static func normalized(_ vector: [Float]) throws -> [Float] {
        guard vector.count == 256, vector.allSatisfy(\.isFinite) else { throw VoiceIdentityError.invalidProfile }
        let norm = sqrt(vector.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-8 else { throw VoiceIdentityError.invalidProfile }
        return vector.map { Float(Double($0) / norm) }
    }
    private static func similarity(_ a: [Float], _ b: [Float]) -> Float { zip(a,b).reduce(0) { $0 + $1.0 * $1.1 } }
    static func validate(_ profile: VoiceProfile) throws {
        guard profile.modelID == modelID, profile.recordingDuration.isFinite,
              (30...60).contains(profile.recordingDuration), profile.enrolledAt.timeIntervalSince1970.isFinite,
              (3...20).contains(profile.embeddings.count) else { throw VoiceIdentityError.invalidProfile }
        let vectors = try profile.embeddings.map(normalized)
        for i in vectors.indices {
            for j in vectors.indices where j > i {
                guard similarity(vectors[i], vectors[j]) >= enrollmentSimilarity else { throw VoiceIdentityError.inconsistentVoice }
            }
        }
    }
    static func makeProfile(embeddings: [[Float]], duration: TimeInterval) throws -> VoiceProfile {
        let profile = VoiceProfile(id: UUID(), enrolledAt: Date(), recordingDuration: duration,
                                   modelID: modelID, embeddings: try embeddings.map(normalized))
        try validate(profile)
        return profile
    }
    static func matches(embeddings: [[Float]], profile: VoiceProfile) -> Bool {
        guard (2...20).contains(embeddings.count), (try? validate(profile)) != nil,
              let samples = try? embeddings.map(normalized), let enrolled = try? profile.embeddings.map(normalized) else { return false }
        // Every clean window must agree with every enrollment window; mixed clusters abstain.
        return samples.allSatisfy { sample in enrolled.allSatisfy { similarity(sample, $0) >= matchSimilarity } }
    }
}

struct VoiceProfileStore: Sendable {
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WristNotes/PrivateVoiceIdentity", isDirectory: true)) { self.root = root }
    private var file: URL { root.appendingPathComponent("profile.json") }
    func load() throws -> VoiceProfile? {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let profile = try JSONDecoder().decode(VoiceProfile.self, from: data)
        try VoiceIdentityPolicy.validate(profile)
        return profile
    }
    func save(_ profile: VoiceProfile) throws {
        try VoiceIdentityPolicy.validate(profile)
        let data = try JSONEncoder().encode(profile)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try protect(root)
        // Prepare and protect before atomic rename so a failed replacement preserves the prior profile.
        let temporary = root.appendingPathComponent(".profile-\(UUID()).json")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try protect(temporary)
        if manager.fileExists(atPath: file.path) { _ = try manager.replaceItemAt(file, withItemAt: temporary) }
        else { try manager.moveItem(at: temporary, to: file) }
    }
    func delete() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private func protect(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}
