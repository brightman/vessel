import SwiftUI
import UIKit

@main
struct WristNotesApp: App {
    @StateObject private var model = NotesModel()
    @StateObject private var ring = EurekaRingModel()

    init() {
#if DEBUG
        UIApplication.shared.isIdleTimerDisabled = true
#endif
    }

    var body: some Scene {
        WindowGroup {
            DaybookView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(ring)
                .task { ring.configure(notes: model); await ring.foreground() }
        }
    }
}
