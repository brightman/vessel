import Foundation

/// Only navigation and user acknowledgements are durable. Resource availability is always live.
struct OnboardingProgress: Codable, Equatable {
    enum Page: String, Codable, CaseIterable { case welcome, transcription, ai, data, usage, review }
    enum Disposition: String, Codable { case pending, completed, skipped, existingUser }
    var page: Page = .welcome
    var disposition: Disposition = .pending
    var dataReviewed = false
    var usageReviewed = false
    var shouldPresent: Bool { disposition == .pending }
}

enum OnboardingPersistence {
    static let key = "wiselife.onboarding.v1"
    static func load(defaults: UserDefaults, hasExistingData: Bool) -> OnboardingProgress {
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(OnboardingProgress.self, from: data) { return saved }
        // Preserve access if an installed app has unknown/corrupt/newer state.
        let existing = hasExistingData || defaults.object(forKey: key) != nil
        let value = OnboardingProgress(disposition: existing ? .existingUser : .pending)
        save(value, defaults: defaults)
        return value
    }
    static func save(_ value: OnboardingProgress, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    /// Call before any stores are created. Check metadata only; never read personal records.
    static func existingInstallation(defaults: UserDefaults = .standard, files: FileManager = .default) -> Bool {
        if ["aiConfiguration", "transcriptionConfiguration", "interfaceLanguage", "requiresFaceID", "transcriptionLocale"].contains(where: { defaults.object(forKey: $0) != nil }) { return true }
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let paths = [support.appendingPathComponent("WristNotes/Database/daybook.sqlite3"), support.appendingPathComponent("WristNotes/LifeSources/snapshots.json")] + ["VoiceNotes", "PhotoMoments", "DaybookReminders"].map { documents.appendingPathComponent($0) }
        return paths.contains { files.fileExists(atPath: $0.path) }
    }
}

enum OnboardingReadiness {
    static func aiStep(understanding: Bool, retrieval: Bool) -> Bool { understanding && retrieval }
}
