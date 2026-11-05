import Foundation
import CryptoKit

/// Construct and call on a background worker. Relations deliberately live outside contact snapshots,
/// so ordinary speaker rebindings and system-contact refreshes cannot erase them.
final class NotebookPeopleRepository {
    private let db:DaybookDatabase
    init(database:DaybookDatabase) throws {
        db=database
        try db.transaction {
            try db.execute("CREATE TABLE IF NOT EXISTS notebook_contact_metadata (contact_id TEXT PRIMARY KEY REFERENCES contacts(id) ON DELETE CASCADE, revision INTEGER NOT NULL DEFAULT 0)")
            try db.execute("CREATE TABLE IF NOT EXISTS notebook_contact_relationships (contact_id TEXT NOT NULL REFERENCES contacts(id) ON DELETE CASCADE, relationship TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY(contact_id,relationship))")
            // Detect edits from existing speaker/contact writers as well as this category.
            try db.execute("CREATE TRIGGER IF NOT EXISTS notebook_contact_revision AFTER UPDATE ON contacts BEGIN INSERT INTO notebook_contact_metadata(contact_id,revision) VALUES(NEW.id,1) ON CONFLICT(contact_id) DO UPDATE SET revision=revision+1; END")
        }
    }
    func page(relationship:String? = nil,limit:Int = 40,offset:Int = 0) throws -> [NotebookPerson] {
        let rows=try db.query("SELECT c.id,c.display_name,c.organization,c.emails_json,c.phone_numbers_json,COALESCE(m.revision,0) AS revision FROM contacts c LEFT JOIN notebook_contact_metadata m ON m.contact_id=c.id WHERE ? IS NULL OR EXISTS(SELECT 1 FROM notebook_contact_relationships r WHERE r.contact_id=c.id AND r.relationship=?) ORDER BY c.display_name COLLATE NOCASE,c.id LIMIT ? OFFSET ?",[relationship.map{.text($0)} ?? .null,relationship.map{.text($0)} ?? .null,.integer(Int64(max(1,min(100,limit)))),.integer(Int64(max(0,offset)))])
        return try rows.map(person)
    }
    func relationships() throws -> [String] {
        try db.query("SELECT DISTINCT relationship FROM notebook_contact_relationships ORDER BY relationship").compactMap{$0["relationship"]?.string}
    }
    private func person(_ row:DaybookDatabase.Row) throws -> NotebookPerson {
        let id=try row.requiredString("id")
        let relationships=try db.query("SELECT relationship FROM notebook_contact_relationships WHERE contact_id=? ORDER BY position",[.text(id)]).compactMap{$0["relationship"]?.string}
        return .init(id:id,name:try row.requiredString("display_name"),organization:row["organization"]?.string,emails:try contactFields(row,"emails_json"),phoneNumbers:try contactFields(row,"phone_numbers_json"),relationships:relationships,revision:Int(row["revision"]?.double ?? 0))
    }
    private func contactFields(_ row:DaybookDatabase.Row,_ key:String) throws -> [SpeakerContactField] {
        try JSONDecoder().decode([SpeakerContactField].self,from:Data((row[key]?.string ?? "[]").utf8))
    }
    /// nil keeps existing values; an explicit empty string removes only the displayed first entry.
    private func updatingFirst(_ fields:[SpeakerContactField],with value:String?,label:String) -> [SpeakerContactField] {
        guard let supplied=value else { return fields }
        let value=supplied.trimmingCharacters(in:.whitespacesAndNewlines)
        var result=fields
        if value.isEmpty {
            if !result.isEmpty { result.removeFirst() }
        } else if let first=result.first {
            result[0] = .init(label:first.label,value:value)
        } else {
            result.append(.init(label:label,value:value))
        }
        return result
    }
    @discardableResult func save(id:String?,expectedRevision:Int?,name:String,organization:String?,email:String? = nil,phone:String? = nil,relationships:[String]) throws -> NotebookPerson {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else { throw NotebookPeopleError.invalidName }
        let organization=organization?.trimmingCharacters(in:.whitespacesAndNewlines)
        let organizationValue:DaybookDatabase.Value = organization.flatMap{$0.isEmpty ? nil : $0}.map{.text($0)} ?? .null
        return try db.transaction {
            let key=id ?? "manual:\(UUID().uuidString)"
            let now=Date.now.timeIntervalSinceReferenceDate
            let existing=try db.query("SELECT c.id,c.emails_json,c.phone_numbers_json,COALESCE(m.revision,0) AS revision FROM contacts c LEFT JOIN notebook_contact_metadata m ON m.contact_id=c.id WHERE c.id=?",[.text(key)]).first
            if id != nil {
                guard let existing,Int(existing["revision"]?.double ?? 0)==expectedRevision else { throw NotebookPeopleError.conflict }
            }
            let originalEmails=try existing.map{try contactFields($0,"emails_json")} ?? []
            let originalPhones=try existing.map{try contactFields($0,"phone_numbers_json")} ?? []
            if let email=email?.trimmingCharacters(in:.whitespacesAndNewlines),!email.isEmpty,email != originalEmails.first?.value {
                guard email.range(of:#"^[^\s@]+@[^\s@]+$"#,options:.regularExpression) != nil else { throw NotebookPeopleError.invalidEmail }
            }
            let emails=updatingFirst(originalEmails,with:email,label:"email")
            let phones=updatingFirst(originalPhones,with:phone,label:"phone")
            let emailJSON=String(decoding:try JSONEncoder().encode(emails),as:UTF8.self)
            let phoneJSON=String(decoding:try JSONEncoder().encode(phones),as:UTF8.self)
            if id != nil {
                try db.execute("UPDATE contacts SET display_name=?,organization=?,emails_json=?,phone_numbers_json=?,updated_at=? WHERE id=?",[.text(name),organizationValue,.text(emailJSON),.text(phoneJSON),.real(now),.text(key)])
            } else {
                try db.execute("INSERT INTO contacts(id,origin_type,display_name,organization,emails_json,phone_numbers_json,sync_state,created_at,updated_at) VALUES(?,'manual',?,?,?,?,'manual',?,?)",[.text(key),.text(name),organizationValue,.text(emailJSON),.text(phoneJSON),.real(now),.real(now)])
            }
            try db.execute("DELETE FROM notebook_contact_relationships WHERE contact_id=?",[.text(key)])
            for (position,value) in NotebookRelationships.normalized(relationships).enumerated() {
                try db.execute("INSERT INTO notebook_contact_relationships(contact_id,relationship,position) VALUES(?,?,?)",[.text(key),.text(value),.integer(Int64(position))])
            }
            return try person(db.query("SELECT c.id,c.display_name,c.organization,c.emails_json,c.phone_numbers_json,COALESCE(m.revision,0) AS revision FROM contacts c LEFT JOIN notebook_contact_metadata m ON m.contact_id=c.id WHERE c.id=?",[.text(key)]).first!)
        }
    }
    func createContact(name:String,organization:String?,email:String?,phone:String?,relationships:[String]) throws -> SpeakerContactSnapshot {
        let person=try save(id:nil,expectedRevision:nil,name:name,organization:organization,email:email,phone:phone,relationships:relationships)
        return .init(identifier:person.id,displayName:person.name,thumbnailData:nil,origin:.manual,organization:person.organization,emails:person.emails,phoneNumbers:person.phoneNumbers)
    }
    func sources(contactID:String,limit:Int = 30,offset:Int = 0) throws -> [NotebookPersonSource] {
        let rows=try db.query("SELECT l.source_key,l.speaker_id,l.speaker_revision,s.source_id,COALESCE(n.captured_at,r.started_at,r.created_at) AS captured_at FROM recording_speaker_contacts l JOIN audio_processing_sources s ON s.source_key=l.source_key LEFT JOIN voice_notes n ON n.id=s.note_id LEFT JOIN recording_sessions r ON r.id=s.session_id WHERE l.contact_id=? ORDER BY captured_at DESC,l.source_key,l.speaker_id LIMIT ? OFFSET ?",[.text(contactID),.integer(Int64(max(1,min(100,limit)))),.integer(Int64(max(0,offset)))])
        return try rows.compactMap { row in
            guard let uuid=row["source_id"]?.string.flatMap(UUID.init(uuidString:)) else { return nil }
            let key=try row.requiredString("source_key"),speaker=try row.requiredString("speaker_id")
            let spans=try db.query("SELECT j.id,j.result_hash,t.position,t.start,t.end,t.text FROM audio_transcript_spans t JOIN audio_processing_jobs j ON j.id=t.job_id JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL AND t.speaker_id=? ORDER BY t.start,t.end,j.id,t.position",[.text(key),.text(speaker)])
            var parts:[String]=[]
            for span in spans { parts += [span["id"]?.string ?? "",span["result_hash"]?.string ?? "",String(span["position"]?.double ?? 0),String(span["start"]?.double ?? 0),String(span["end"]?.double ?? 0),span["text"]?.string ?? ""] }
            let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
            let revision=SHA256.hash(data:try encoder.encode(parts)).map{String(format:"%02x",$0)}.joined()
            return .init(sourceID:uuid,sourceKey:key,speakerID:speaker,capturedAt:Date(timeIntervalSinceReferenceDate:row["captured_at"]?.double ?? 0),start:spans.compactMap{$0["start"]?.double}.min(),end:spans.compactMap{$0["end"]?.double}.max(),needsReview:spans.isEmpty || revision != row["speaker_revision"]?.string)
        }
    }
}
