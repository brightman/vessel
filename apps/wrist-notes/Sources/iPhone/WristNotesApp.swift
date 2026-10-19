import SwiftUI
import UIKit

@main
struct WristNotesApp: App {
    @StateObject private var model = NotesModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
#if DEBUG
        UIApplication.shared.isIdleTimerDisabled = true
#endif
    }

    var body: some Scene {
        WindowGroup {
            NotesListView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .task { await model.refreshHeartRates() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.refreshHeartRates() } }
                }
        }
    }
}
