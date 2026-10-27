import Foundation

struct AppReleaseInfo {
    let version: String
    let build: String
    let builtAt: Date?

    init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let metadata = bundle.url(forResource: "BuildMetadata", withExtension: "plist")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String] }
        builtAt = metadata?["BuiltAt"].flatMap { ISO8601DateFormatter().date(from: $0) }
    }
    var versionLabel: String { "\(version)（\(build)）" }
    func releaseLabel(locale: Locale) -> String? {
        guard let builtAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: builtAt)
    }
}
