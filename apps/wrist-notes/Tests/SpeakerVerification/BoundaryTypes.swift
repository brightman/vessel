import Foundation

// Verification target only. The unavailable external Ring SDK and unrelated route
// are represented solely to compile NotesModel/SettingsViews. Ring paths are not tested.
struct RingTransferJob {
    struct File { let name: String; let recordedAt: Date? }
    let id: UUID
    let deviceID: String
    let file: File
    let capturedAt: Date
    let recordingKind: RecordingKind
}
enum DaybookRoute: Hashable { case preferences }

import SwiftUI
// Unrelated semantic-search settings are outside this focused target.
struct DaybookSemanticSettingsView: View { var body: some View { EmptyView() } }
