import Foundation
@main struct NotebookPeopleSmoke {
 static func main() throws {
  let db = try DaybookDatabase(inMemory:true)
  let repo = try NotebookPeopleRepository(database:db)
  let normalized = try repo.createContact(name:"  Five fields  ",organization:"  Studio  ",email:"  person@example.test  ",phone:"  +86 138 0000 0000  ",relationships:["朋友"," 跑友 ","跑友"])
  precondition(normalized.organization == "Studio", "contact form must trim organization on save and reload")
  let filled = try repo.page().first(where:{$0.id == normalized.identifier})!
  precondition(filled.name == "Five fields" && filled.email == "person@example.test" && filled.phone == "+86 138 0000 0000")
  precondition(filled.relationships == ["朋友","跑友"])
  let changed = try repo.save(id:filled.id,expectedRevision:filled.revision,name:"Updated",organization:" New studio ",email:"new@example.test",phone:"+1 202 555 0100",relationships:["同事","朋友"])
  let changedRead = try repo.page().first(where:{$0.id == filled.id})!
  precondition(changedRead.email == "new@example.test" && changedRead.phone == "+1 202 555 0100" && changedRead.organization == "New studio")
  precondition(changed.revision == filled.revision+1 && changedRead.relationships == ["同事","朋友"])
  do { _ = try repo.save(id:filled.id,expectedRevision:filled.revision,name:"Stale",organization:nil,email:"stale@example.test",phone:"999",relationships:[]); preconditionFailure("stale five-field update accepted") } catch NotebookPeopleError.conflict {}
  let afterConflict = try repo.page().first(where:{$0.id == filled.id})!
  precondition(afterConflict.name == "Updated" && afterConflict.email == "new@example.test" && afterConflict.relationships == ["同事","朋友"])
  let cleared = try repo.save(id:changed.id,expectedRevision:changed.revision,name:changed.name,organization:" ",email:" ",phone:" ",relationships:[])
  precondition(cleared.organization == nil && cleared.email.isEmpty && cleared.phone.isEmpty && cleared.relationships.isEmpty)
  do { _ = try repo.save(id:nil,expectedRevision:nil,name:"Bad email",organization:nil,email:"invalid email",relationships:[]); preconditionFailure("invalid email accepted") } catch NotebookPeopleError.invalidEmail {}
  let afterInvalid = try repo.page(); precondition(!afterInvalid.contains(where:{$0.name == "Bad email"}))
  let a = try repo.save(id:nil, expectedRevision:nil, name:"Alice", organization:"Acme", relationships:["朋友"," 同学 ","朋友",""])
  precondition(a.relationships == ["朋友","同学"])
  let b = try repo.save(id:nil, expectedRevision:nil, name:"Alice", organization:nil, relationships:[])
  precondition(a.id != b.id && b.relationships.isEmpty)
  let filtered = try repo.page(relationship:"同学"); precondition(filtered.count == 1)
  let edited = try repo.save(id:a.id,expectedRevision:a.revision,name:"Alice 2",organization:nil,relationships:["自定义"])
  precondition(edited.revision == a.revision+1)
  do { _ = try repo.save(id:a.id,expectedRevision:a.revision,name:"stale",organization:nil,relationships:[]); preconditionFailure("conflict accepted") } catch NotebookPeopleError.conflict {}
  let reopened = try NotebookPeopleRepository(database:db)
  let all = try reopened.page(); precondition(all.first(where:{$0.id == a.id})?.relationships == ["自定义"])
  let next = try reopened.page(limit:1,offset:1); precondition(next.count == 1)
  // Old contacts without metadata remain editable; external contact saves invalidate stale editors.
  try db.execute("INSERT INTO contacts(id,origin_type,display_name,sync_state,created_at,updated_at) VALUES('manual:old','manual','Old','manual',0,0)")
  let old = try repo.page().first(where:{$0.id == "manual:old"})!
  precondition(old.revision == 0 && old.relationships.isEmpty)
  try db.execute("UPDATE contacts SET display_name='External edit' WHERE id=?",[.text(a.id)])
  do { _ = try repo.save(id:a.id,expectedRevision:edited.revision,name:"stale",organization:nil,relationships:[]); preconditionFailure("external conflict accepted") } catch NotebookPeopleError.conflict {}
  let saved = try repo.createContact(name:"New",organization:nil,email:"a@example.test",phone:"123",relationships:["朋友","朋友"])
  precondition(saved.emails.first?.value == "a@example.test")
  let session=UUID().uuidString,key="session:"+session
  try db.execute("INSERT INTO recording_sessions(id,started_at,created_at) VALUES(?,100,100)",[.text(session)])
  try db.execute("INSERT INTO audio_processing_sources(source_key,kind,source_id,session_id,descriptor,fingerprint,configuration_key) VALUES(?,'session',?,?,?,'f','c')",[.text(key),.text(session),.text(session),.blob(Data())])
  try db.execute("INSERT INTO audio_processing_jobs(id,source_key,configuration_key,core_start,core_end,window,state,result) VALUES('j',?,'c',0,20,?,'completed',?)",[.text(key),.blob(Data()),.blob(Data())])
  try db.execute("INSERT INTO audio_transcript_spans(job_id,position,start,end,text,speaker_id) VALUES('j',0,2,7,'hello','speaker-1')")
  try db.execute("INSERT INTO recording_speaker_contacts(source_key,speaker_id,contact_id,linked_at,speaker_revision) VALUES(?,'speaker-1',?,0,'outdated')",[.text(key),.text(b.id)])
  let sources=try repo.sources(contactID:b.id)
  precondition(sources.count == 1 && sources[0].sourceID.uuidString == session && sources[0].start == 2 && sources[0].end == 7 && sources[0].needsReview)
  _ = try repo.save(id:b.id,expectedRevision:b.revision,name:b.name,organization:"Studio",email:"bound@example.test",phone:"123",relationships:["朋友"])
  let preservedSources=try repo.sources(contactID:b.id)
  precondition(preservedSources.count == 1 && preservedSources[0].sourceID.uuidString == session && preservedSources[0].speakerID == "speaker-1")
  try db.execute("DELETE FROM recording_speaker_contacts WHERE contact_id=?",[.text(b.id)])
  let unbound=try repo.page(); precondition(unbound.contains(where:{$0.id==b.id}))
  try db.execute("INSERT INTO recording_speaker_contacts(source_key,speaker_id,contact_id,linked_at,speaker_revision) VALUES(?,'speaker-1',?,0,'outdated')",[.text(key),.text(b.id)])
  try db.execute("DELETE FROM recording_sessions WHERE id=?",[.text(session)])
  let remaining=try repo.page(),deletedSources=try repo.sources(contactID:b.id)
  precondition(remaining.contains(where:{$0.id==b.id}) && deletedSources.isEmpty)
  try testExistingContactFields()
  try testDiskReopen()
  print("Notebook people smoke passed: five-field save/reload/clear, extra fields, source preservation, revisions and disk reopen")
 }

 static func testExistingContactFields() throws {
  let db=try DaybookDatabase(inMemory:true),repo=try NotebookPeopleRepository(database:db)
  try db.execute("INSERT INTO contacts(id,origin_type,system_contact_identifier,display_name,emails_json,phone_numbers_json,avatar_thumbnail,sync_state,created_at,updated_at) VALUES('ios:fixture','ios','fixture','Imported',?,? ,?,'current',0,0)",[
   .text("[{\"label\":\"work\",\"value\":\"first@example.test\"},{\"label\":\"home\",\"value\":\"second@example.test\"}]"),
   .text("[{\"label\":\"mobile\",\"value\":\"111\"},{\"label\":\"work\",\"value\":\"222\"}]"),.blob(Data([1,2,3]))])
  let old=try repo.page()[0]
  let edited=try repo.save(id:old.id,expectedRevision:old.revision,name:"Imported edit",organization:nil,email:"updated@example.test",phone:"333",relationships:["朋友"])
  precondition(edited.emails == [.init(label:"work",value:"updated@example.test"),.init(label:"home",value:"second@example.test")])
  precondition(edited.phoneNumbers == [.init(label:"mobile",value:"333"),.init(label:"work",value:"222")])
  let row=try db.query("SELECT origin_type,system_contact_identifier,avatar_thumbnail,sync_state FROM contacts WHERE id='ios:fixture'")[0]
  precondition(row["origin_type"]?.string == "ios" && row["system_contact_identifier"]?.string == "fixture" && row["avatar_thumbnail"]?.data == Data([1,2,3]) && row["sync_state"]?.string == "current")
  let relationOnly=try repo.save(id:edited.id,expectedRevision:edited.revision,name:edited.name,organization:nil,relationships:["客户"])
  precondition(relationOnly.emails == edited.emails && relationOnly.phoneNumbers == edited.phoneNumbers)
  let removedFirst=try repo.save(id:relationOnly.id,expectedRevision:relationOnly.revision,name:relationOnly.name,organization:nil,email:"",phone:"",relationships:[])
  precondition(removedFirst.emails == [.init(label:"home",value:"second@example.test")] && removedFirst.phoneNumbers == [.init(label:"work",value:"222")])
 }

 static func testDiskReopen() throws {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent("notebook-contact-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:directory) }
  let url=directory.appendingPathComponent("test.sqlite")
  let id:String
  do {
   let repo=try NotebookPeopleRepository(database:DaybookDatabase(url:url))
   id=try repo.save(id:nil,expectedRevision:nil,name:"Persistent",organization:"Studio",email:"persist@example.test",phone:"+86 138 0000 0000",relationships:["朋友"," 跑友 ","跑友"]).id
  }
  let repo=try NotebookPeopleRepository(database:DaybookDatabase(url:url)),person=try repo.page()[0]
  precondition(person.id == id && person.name == "Persistent" && person.organization == "Studio")
  precondition(person.email == "persist@example.test" && person.phone == "+86 138 0000 0000" && person.relationships == ["朋友","跑友"])
  let choices=try repo.relationships();precondition(choices.contains("跑友"))
 }
}
