import Foundation

enum WatchRecordingLink {
    static let url = URL(string: "wiselife-watch://record")!
    static func matches(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "wiselife-watch" && components.host == "record"
            && components.path.isEmpty && components.query == nil && components.fragment == nil
            && components.user == nil && components.password == nil && components.port == nil
    }
}
