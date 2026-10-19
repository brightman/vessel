import SwiftUI

@main
struct WristNotesWatchApp: App {
    @StateObject private var recorder = WatchRecorder()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(recorder)
        }
    }
}
