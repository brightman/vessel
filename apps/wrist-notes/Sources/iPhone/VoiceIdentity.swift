import Foundation
import Security

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
        case .inconsistentVoice: return NSLocalizedString("声音档案未保存：录音中的声音特征不一致。请在安静环境中独自讲话并重新录制。", comment: "")
        case .invalidAudio: return NSLocalizedString("可用于识别的清晰讲话片段不足，请重新录制。", comment: "")
        case .incompatibleModel: return NSLocalizedString("声纹模型不兼容，请在语音转写设置中重新下载资源。", comment: "")
        }
    }
}

enum VoiceIdentityPolicy {
    static let modelID = "wespeaker-v2-7eab74f3463c736418d0eb10296261ae581146c9"
    // Conservative engineering defaults, not population-calibrated thresholds.
    // Compare windows with their shared center rather than every pair: a valid
    // voice can vary across phrases even when its aggregate identity is stable.
    static let enrollmentCentroidSimilarity: Float = 0.88
    static let queryCentroidSimilarity: Float = 0.90
    static let matchSimilarity: Float = 0.82
    static func normalized(_ vector: [Float]) throws -> [Float] {
        guard vector.count == 256, vector.allSatisfy(\.isFinite) else { throw VoiceIdentityError.invalidProfile }
        let norm = sqrt(vector.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-8 else { throw VoiceIdentityError.invalidProfile }
        return vector.map { Float(Double($0) / norm) }
    }
    private static func similarity(_ a: [Float], _ b: [Float]) -> Float { zip(a,b).reduce(0) { $0 + $1.0 * $1.1 } }
    static func centroid(_ vectors: [[Float]]) throws -> [Float] {
        guard !vectors.isEmpty else { throw VoiceIdentityError.invalidProfile }
        var mean = [Float](repeating: 0, count: 256)
        for vector in vectors {
            for index in mean.indices { mean[index] += vector[index] / Float(vectors.count) }
        }
        return try normalized(mean)
    }
    static func isConsistent(_ embeddings: [[Float]], minimum: Float) -> Bool {
        guard embeddings.count >= 2, let vectors = try? embeddings.map(normalized),
              let center = try? centroid(vectors) else { return false }
        return vectors.allSatisfy { similarity($0, center) >= minimum }
    }
    static func validate(_ profile: VoiceProfile) throws {
        guard profile.modelID == modelID, profile.recordingDuration.isFinite,
              (30...60).contains(profile.recordingDuration), profile.enrolledAt.timeIntervalSince1970.isFinite,
              (3...20).contains(profile.embeddings.count) else { throw VoiceIdentityError.invalidProfile }
        let vectors = try profile.embeddings.map(normalized)
        guard isConsistent(vectors, minimum: enrollmentCentroidSimilarity) else {
            throw VoiceIdentityError.inconsistentVoice
        }
    }
    static func makeProfile(embeddings: [[Float]], duration: TimeInterval) throws -> VoiceProfile {
        let vectors = try embeddings.map(normalized)
        let id = UUID(), enrolledAt = Date()
        func profile(_ samples: [[Float]]) -> VoiceProfile {
            VoiceProfile(id: id, enrolledAt: enrolledAt, recordingDuration: duration,
                         modelID: modelID, embeddings: samples)
        }
        let complete = profile(vectors)
        do { try validate(complete); return complete }
        catch VoiceIdentityError.inconsistentVoice {
            // A single noisy five-second window can fail center validation.
            // Keep the stored-profile rule, and only discard one uniquely
            // identifiable outlier when at least four consistent windows remain.
            guard vectors.count >= 5 else { throw VoiceIdentityError.inconsistentVoice }
            var recovered: VoiceProfile?
            for index in vectors.indices {
                var remaining = vectors
                remaining.remove(at: index)
                let candidate = profile(remaining)
                guard (try? validate(candidate)) != nil else { continue }
                guard recovered == nil else { throw VoiceIdentityError.inconsistentVoice }
                recovered = candidate
            }
            guard let recovered else { throw VoiceIdentityError.inconsistentVoice }
            return recovered
        }
    }
    static func matches(embeddings: [[Float]], profile: VoiceProfile) -> Bool {
        guard (2...20).contains(embeddings.count), (try? validate(profile)) != nil,
              let samples = try? embeddings.map(normalized),
              isConsistent(samples, minimum: queryCentroidSimilarity),
              let enrolled = try? centroid(profile.embeddings) else { return false }
        // A mixed query cluster abstains; every clean window must match the
        // enrollment center before the speaker is labeled as the owner.
        return samples.allSatisfy { similarity($0, enrolled) >= matchSimilarity }
    }
}

protocol VoiceProfilePersistence: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

struct KeychainVoiceProfilePersistence: VoiceProfilePersistence {
    let service: String
    private let account = "profile"

    init(service: String = (Bundle.main.bundleIdentifier ?? "cloud.karama.wisenote") + ".voice-profile") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw VoiceProfileStoreError.keychain(status == errSecSuccess ? errSecDecode : status)
        }
        return data
    }

    func save(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addition = query.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
                throw VoiceProfileStoreError.keychain(addStatus)
            }
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else { throw VoiceProfileStoreError.keychain(retryStatus) }
            }
        } else if status != errSecSuccess {
            throw VoiceProfileStoreError.keychain(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoiceProfileStoreError.keychain(status)
        }
    }
}

enum VoiceProfileStoreError: Error, LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        guard case .keychain(let status) = self else { return nil }
        switch status {
        case errSecMissingEntitlement:
            return "当前 App 签名缺少钥匙串访问权限（错误 \(status)）。请使用正确签名的版本后重试。"
        case errSecInteractionNotAllowed:
            return "系统暂不允许访问钥匙串（错误 \(status)），请解锁 iPhone 后重试。"
        default:
            return "无法访问本机声音档案（钥匙串错误 \(status)），请稍后重试。"
        }
    }
}

struct VoiceProfileStore: Sendable {
    private let root: URL?
    private let persistence: (any VoiceProfilePersistence)?
    private let legacyRoot: URL?

    init(root: URL? = nil, persistence: (any VoiceProfilePersistence)? = nil, legacyRoot: URL? = nil) {
        if let root {
            self.persistence = nil
            self.legacyRoot = nil
            self.root = root
        } else {
            self.persistence = persistence ?? KeychainVoiceProfilePersistence()
            self.legacyRoot = legacyRoot ?? Self.defaultProfileRoot
            self.root = nil
        }
    }

    private static var defaultProfileRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WristNotes/PrivateVoiceIdentity", isDirectory: true)
    }
    private var file: URL? { root?.appendingPathComponent("profile.json") }
    private var legacyFile: URL? { legacyRoot?.appendingPathComponent("profile.json") }

    func load() throws -> VoiceProfile? {
        if let file { return try Self.readProfile(at: file) }
        guard let persistence else { return nil }
        if let data = try persistence.load() { return try Self.decodeProfile(data) }
        guard let legacyFile, let profile = try Self.readProfile(at: legacyFile) else { return nil }
        // Migrate only after the protected Keychain write succeeds. Keep the legacy file
        // if Keychain is unavailable so a failed migration never loses the enrollment.
        try persistence.save(JSONEncoder().encode(profile))
        try? FileManager.default.removeItem(at: legacyFile)
        return profile
    }

    private static func readProfile(at file: URL) throws -> VoiceProfile? {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        return try decodeProfile(data)
    }

    private static func decodeProfile(_ data: Data) throws -> VoiceProfile {
        let profile = try JSONDecoder().decode(VoiceProfile.self, from: data)
        try VoiceIdentityPolicy.validate(profile)
        return profile
    }

    func save(_ profile: VoiceProfile) throws {
        try VoiceIdentityPolicy.validate(profile)
        let data = try JSONEncoder().encode(profile)
        guard let file else {
            guard let persistence else { return }
            try persistence.save(data)
            return
        }
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try protect(file.deletingLastPathComponent())
        // Prepare and protect before atomic rename so a failed replacement preserves the prior profile.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".profile-\(UUID()).json")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try protect(temporary)
        if manager.fileExists(atPath: file.path) { _ = try manager.replaceItemAt(file, withItemAt: temporary) }
        else { try manager.moveItem(at: temporary, to: file) }
    }

    func delete() throws {
        if let file {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try persistence?.delete()
        if let legacyFile, FileManager.default.fileExists(atPath: legacyFile.path) {
            try FileManager.default.removeItem(at: legacyFile)
        }
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
