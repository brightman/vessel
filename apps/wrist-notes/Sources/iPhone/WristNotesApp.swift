import SwiftUI
import UIKit

@main
struct WristNotesApp: App {
    @StateObject private var model = NotesModel()

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
        }
    }
}
