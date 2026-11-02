import Foundation
import Security

// Run as a command-line process in the simulator, using a unique test bundle ID.
// No UI, network calls, production preferences, or real credentials are used.
@main
struct KeychainSimulatorSmoke {
    @MainActor static func main() {
        do { try run() }
        catch {
            fputs("Keychain simulator check failed: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func run() throws {
        guard let bundleID = Bundle.main.bundleIdentifier,
              bundleID.hasPrefix("cloud.karama.wisenote.keychaincheck.") else {
            throw CheckFailure(message: "Refusing to use a non-test Keychain namespace")
        }
        let suite = bundleID + ".settings"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        let voiceStore = VoiceProfileStore(root: nil,
            persistence: KeychainVoiceProfilePersistence(service: bundleID + ".voice-profile"),
            legacyRoot: FileManager.default.temporaryDirectory.appendingPathComponent(bundleID))
        let configuration = AIConfiguration(mode: .custom, model: "fixture-model", baseURL: "https://example.com/v1")
        let command = CommandLine.arguments[1]
        switch command {
        case "unsigned":
            for operation in [
                { _ = try settings.apiKey() },
                { try settings.saveAI(configuration, apiKey: "fixture-key-not-real") }
            ] {
                do {
                    try operation()
                    throw CheckFailure(message: "An unsigned client unexpectedly accessed Keychain")
                } catch let error as AIServiceError {
                    try require(error.localizedDescription.contains("-34018"), "Missing entitlement error must retain OSStatus -34018")
                    try require(!error.localizedDescription.contains("解锁"), "Missing entitlements must not be diagnosed as a locked device")
                }
            }
            try require(settings.ai.mode == .local, "Failed Keychain write must preserve active settings")
            try require(defaults.data(forKey: "aiConfiguration") == nil, "Failed Keychain write must not persist custom settings")
        case "write":
            let absent = try settings.apiKey()
            try require(absent.isEmpty, "A new test namespace must start empty")
            try require(try voiceStore.load() == nil, "A new voice-profile Keychain namespace must start empty")
            try settings.saveAI(configuration, apiKey: "fixture-key-not-real")
            let saved = try settings.apiKey()
            try require(saved == "fixture-key-not-real", "Signed client must save and read Keychain")
            try require(!String(decoding: defaults.data(forKey: "aiConfiguration")!, as: UTF8.self).contains("fixture-key-not-real"), "Credentials must not enter UserDefaults")
            let profile = try voiceProfile(variant: 0)
            try voiceStore.save(profile)
            try require(try voiceStore.load() == profile, "Voice enrollment must be stored in the device Keychain")
        case "update":
            let saved = try settings.apiKey()
            try require(saved == "fixture-key-not-real", "Credential must survive process restart")
            try require(try voiceStore.load() == (try voiceProfile(variant: 0)), "Voice profile must survive process restart")
            try require(settings.ai == configuration, "Configuration must survive process restart")
            try settings.saveAI(configuration, apiKey: "fixture-key-updated-not-real")
            let updated = try settings.apiKey()
            try require(updated == "fixture-key-updated-not-real", "Existing Keychain item must update")
            try voiceStore.save(voiceProfile(variant: 1))
            try require(try voiceStore.load() == (try voiceProfile(variant: 1)), "Voice profile replacement must update the Keychain item")
        case "verify":
            let updated = try settings.apiKey()
            try require(updated == "fixture-key-updated-not-real", "Updated credential must survive another restart")
            try require(try voiceStore.load() == (try voiceProfile(variant: 1)), "Updated voice profile must survive another process restart")
        case "cleanup":
            try voiceStore.delete()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: bundleID + ".ai",
                kSecAttrAccount as String: "custom-model-api-key"
            ]
            let status = SecItemDelete(query as CFDictionary)
            try require([errSecSuccess, errSecItemNotFound].contains(status), "Clean up only the test credential")
            defaults.removePersistentDomain(forName: suite)
        default:
            throw CheckFailure(message: "Unknown test command")
        }
        print("Keychain simulator \(command): passed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }

    private static func voiceProfile(variant: Int) throws -> VoiceProfile {
        let vector: [Float] = variant == 0
            ? [Float](repeating: 0, count: 255) + [1]
            : [Float](repeating: 0, count: 254) + [1, 0]
        let id = UUID(uuidString: variant == 0 ? "A31A8CA3-A2E1-4C28-9A8B-4E8310200001" : "A31A8CA3-A2E1-4C28-9A8B-4E8310200002")!
        return VoiceProfile(id: id, enrolledAt: Date(timeIntervalSince1970: 1_700_000_000),
            recordingDuration: 35, modelID: VoiceIdentityPolicy.modelID,
            embeddings: try [vector, vector, vector].map(VoiceIdentityPolicy.normalized))
    }

    private struct CheckFailure: Error { let message: String }
}
