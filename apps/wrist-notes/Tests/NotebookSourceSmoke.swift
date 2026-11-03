import Foundation
@main struct NotebookSourceSmoke {
    static func main() throws {
        let db=try DaybookDatabase(inMemory:true)
        let id=UUID()
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES(?,?)",[.text(id.uuidString),.real(Date.now.timeIntervalSinceReferenceDate)])
        let sessionKind=try NotebookSourceLookup.kind(id,database:db); precondition(sessionKind == .session)
        try db.execute("DELETE FROM recording_sessions WHERE id=?",[.text(id.uuidString)])
        let missingKind=try NotebookSourceLookup.kind(id,database:db); precondition(missingKind == nil)
        let photo=UUID()
        try db.execute("INSERT INTO photo_moments(id,captured_at,caption,recognized_text) VALUES(?,?,?,?)",[.text(photo.uuidString),.real(0),.text("example"),.text("")])
        let photoKind=try NotebookSourceLookup.kind(photo,database:db); precondition(photoKind == .photo)
        print("Notebook source routing resolves durable session/photo kinds without UI cache; deleted sources return missing")
    }
}
