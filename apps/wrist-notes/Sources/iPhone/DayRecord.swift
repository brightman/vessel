import Foundation

/// A searchable projection of existing stores. Original IDs and media remain in their repositories.
struct DayRecord: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case voice, thought, image }
    let id: UUID
    let capturedAt: Date
    let kind: Kind
    let title: String
    let text: String
    let summary: String
    let duration: TimeInterval

    init(id: UUID, capturedAt: Date, kind: Kind, title: String, text: String,
         summary: String = "", duration: TimeInterval = 0) {
        self.id = id; self.capturedAt = capturedAt; self.kind = kind
        self.title = title; self.text = text; self.summary = summary; self.duration = duration
    }
}
