import Foundation

// Only the inference boundary is replaced; real files, profile validation and model state are used.
struct LocalTranscriptionService {
    static let shared = LocalTranscriptionService()
    func enrollVoice(fileURL: URL) async throws -> VoiceProfile { throw VoiceIdentityError.invalidAudio }
}

@main struct MyVoiceProfileRecoverySmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceProfileStore(root: root)
        let vector = [Float](repeating: 0, count: 255) + [1]
        let original = try VoiceIdentityPolicy.makeProfile(embeddings: [vector, vector, vector], duration: 35)
        try store.save(original)
        let first = MyVoiceProfileModel(store: store)
        precondition(first.profile == original)
        let reopened = MyVoiceProfileModel(store: VoiceProfileStore(root: root))
        precondition(reopened.profile == original, "Successful enrollment must survive model recreation")
        let file = root.appendingPathComponent("profile.json")
        let valid = try Data(contentsOf: file)
        try Data("temporarily unreadable profile".utf8).write(to: file)
        let unavailable = MyVoiceProfileModel(store: store)
        precondition(!unavailable.label.contains("未登记"), "A failed read must not be reported as an absent enrollment")
        precondition(unavailable.storageError != nil && unavailable.profile == nil)
        let rejected = await unavailable.saveRecording(url: root, duration: 35, confirmedSolo: true)
        precondition(!rejected, "Unreadable existing enrollment must not be overwritten")
        first.reload()
        precondition(first.profile == original && first.storageError != nil, "A failed refresh keeps the last known valid profile")
        try valid.write(to: file)
        unavailable.reload(); first.reload()
        precondition(unavailable.profile == original && unavailable.storageError == nil && !unavailable.label.contains("未登记"))
        precondition(first.profile == original && first.storageError == nil)
        unavailable.cancelEnrollment(); unavailable.reload()
        precondition(unavailable.profile == original, "Leaving enrollment must not delete the saved identity")
        precondition(unavailable.delete())
        let deleted = MyVoiceProfileModel(store: store)
        precondition(deleted.profile == nil && deleted.storageError == nil && deleted.label.contains("未登记"))
        print("Voice profile recovery: reopen, unavailable state, retained identity, retry, cancellation and explicit deletion passed")
    }
}
