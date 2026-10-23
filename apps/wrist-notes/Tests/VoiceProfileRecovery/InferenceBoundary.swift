import Foundation

// Enrollment inference is outside these storage/lifecycle tests; all profile IO is production code.
struct LocalTranscriptionService {
    static let shared = LocalTranscriptionService()
    func enrollVoice(fileURL: URL) async throws -> VoiceProfile { throw VoiceIdentityError.invalidAudio }
}
