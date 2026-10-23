import SwiftUI

@main
struct HuaweiNotesApp: App {
    @StateObject private var model = NotesModel()
    var body: some Scene {
        WindowGroup { NotesListView().environmentObject(model) }
    }
}
