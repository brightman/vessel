import SwiftUI
import ContactsUI

/// Personal names are literal text; only built-in speaker labels are localization keys.
struct SpeakerNameText: View {
    let note: VoiceNote
    let speakerID: String
    var body: some View {
        if let contact = note.speakerContacts?[speakerID],!contact.needsReview {
            Text(verbatim: contact.displayName)
        } else if let name = note.speakerNames?[speakerID], !name.isEmpty {
            Text(verbatim: name)
        } else if note.speakerNames?[speakerID] == nil, note.ownerSpeakerIDs?.contains(speakerID) == true {
            Text("我")
        } else {
            Text("说话人 \(speakerID.replacingOccurrences(of: "speaker-", with: ""))")
        }
    }
}

struct SpeakerAvatar: View {
    let contact: SpeakerContactSnapshot?
    var body: some View {
        Group {
            if let data = contact?.thumbnailData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image(systemName: "person.crop.circle").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: 36, height: 36).clipShape(Circle())
    }
}

struct SpeakerContactPicker: UIViewControllerRepresentable {
    let selected: (SpeakerContactSnapshot) -> Void
    let cancelled: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = []
        return picker
    }
    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}
    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: SpeakerContactPicker
        init(parent: SpeakerContactPicker) { self.parent = parent }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { parent.cancelled() }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let nameKeys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
            let personal = contact.areKeysAvailable(nameKeys)
                ? (CNContactFormatter.string(from: contact, style: .fullName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : ""
            let organization = contact.isKeyAvailable(CNContactOrganizationNameKey)
                ? contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let name = personal.isEmpty ? (organization.isEmpty ? NSLocalizedString("未命名联系人", comment: "") : organization) : personal
            var thumbnail: Data?
            if contact.isKeyAvailable(CNContactThumbnailImageDataKey), let data = contact.thumbnailImageData, let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 {
                let ratio = min(1, 96 / max(image.size.width, image.size.height))
                let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let reduced = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                if let encoded = reduced.jpegData(compressionQuality: 0.7), encoded.count <= 32 * 1024 { thumbnail = encoded }
            }
            let emails = contact.isKeyAvailable(CNContactEmailAddressesKey)
                ? contact.emailAddresses.prefix(8).map { SpeakerContactField(label:CNLabeledValue<NSString>.localizedString(forLabel:$0.label ?? ""),value:$0.value as String) } : []
            let phones = contact.isKeyAvailable(CNContactPhoneNumbersKey)
                ? contact.phoneNumbers.prefix(8).map { SpeakerContactField(label:CNLabeledValue<CNPhoneNumber>.localizedString(forLabel:$0.label ?? ""),value:$0.value.stringValue) } : []
            parent.selected(.init(identifier: contact.identifier, displayName: name, thumbnailData: thumbnail,origin:.ios,
                organization:organization.isEmpty ? nil : organization,emails:emails,phoneNumbers:phones))
        }
    }
}

private struct ManualSpeakerContactForm: View {
    let save: (SpeakerContactSnapshot) async -> SpeakerContactSnapshot?
    let onSaved: (SpeakerContactSnapshot) -> Void
    let cancel: () -> Void
    @State private var name=""
    @State private var organization=""
    @State private var email=""
    @State private var phone=""
    @State private var saving=false
    @State private var relationships:[String]=[]
    @State private var failure:String?
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    NotebookContactFields(name:$name,organization:$organization,email:$email,phone:$phone,relationships:$relationships)
                        .disabled(saving)
                    Text("仅保存在 WiseLife，不修改系统通讯录。").font(.caption).foregroundStyle(DaybookStyle.secondary)
                    if let failure { Text(failure).font(.subheadline).foregroundStyle(DaybookStyle.red) }
                }.padding(24)
            }.scrollDismissesKeyboard(.interactively).background(DaybookStyle.paper)
            .navigationTitle("添加联系人").navigationBarTitleDisplayMode(.inline)
            .tint(DaybookStyle.accent).interactiveDismissDisabled(saving)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("取消",action:cancel).disabled(saving) }
                ToolbarItem(placement:.confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        saving=true
                        Task {
                            do {
                                let name=name,organization=organization,email=email,phone=phone,relationships=relationships
                                let created = try await Task.detached {
                                    try NotebookPeopleRepository(database:DaybookDatabase()).createContact(name:name,organization:organization,email:email,phone:phone,relationships:relationships)
                                }.value
                                if let contact=await save(created) { onSaved(contact) }
                                else { failure="联系人已保存，但关联失败，请从已保存联系人重试。"; saving=false }
                            } catch { failure=error.localizedDescription; saving=false }
                        }
                    }.disabled(saving || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct SavedSpeakerContactPicker: View {
    let load: (String) async -> [SpeakerContactSnapshot]
    let selected: (SpeakerContactSnapshot) -> Void
    let cancelled: () -> Void
    @State private var search=""
    @State private var contacts:[SpeakerContactSnapshot]=[]
    @State private var loading=false

    var body:some View {
        NavigationStack {
            Group {
                if loading && contacts.isEmpty {
                    ProgressView("正在读取联系人…")
                } else if contacts.isEmpty {
                    ContentUnavailableView("没有找到联系人",systemImage:"person.crop.circle",
                        description:Text(search.isEmpty ? "可先从通讯录选择，或手动添加联系人。" : "请尝试其他姓名或公司名称。"))
                } else {
                    List(contacts,id:\.identifier) { contact in
                        Button { selected(contact) } label: {
                            HStack(spacing:12) {
                                SpeakerAvatar(contact:contact)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(verbatim:contact.displayName).foregroundStyle(.primary)
                                    let detail=[contact.organization,contact.emails.first?.value,contact.phoneNumbers.first?.value]
                                        .compactMap{$0}.first
                                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            }
                        }.buttonStyle(.plain)
                    }.listStyle(.plain)
                }
            }
            .searchable(text:$search,prompt:"姓名或公司")
            .navigationTitle("已保存联系人").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消",action:cancelled) } }
            .task(id:search) {
                loading=true
                let result=await load(search)
                guard !Task.isCancelled else { return }
                contacts=result; loading=false
            }
        }
    }
}

struct SpeakerManagementView: View {
    let note: VoiceNote
    let speakerID: String
    @EnvironmentObject private var model: NotesModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var showSavedContacts=false
    @State private var showManualContact = false
    @State private var showUnlink = false
    @State private var showRename = false
    @State private var nameDraft = ""
    @State private var failure: String?
    private var current: VoiceNote { model.note(note.id) ?? note }
    private var contact: SpeakerContactSnapshot? { current.speakerContacts?[speakerID] }
    private var valid: Bool { model.note(note.id)?.canEditSpeaker(speakerID, expectedRevision: note.transcriptRevision, expectedSegments: note.transcriptSegments ?? []) == true }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        SpeakerAvatar(contact: contact)
                        VStack(alignment: .leading, spacing: 4) {
                            SpeakerNameText(note: current, speakerID: speakerID).font(.headline)
                            Text(contact == nil ? "尚未关联联系人" : contact?.needsReview == true ? "说话人识别已变化，请复核关联" : "已关联联系人").font(.caption).foregroundStyle(contact?.needsReview == true ? Color.orange : Color.secondary)
                        }
                    }
                    if let contact {
                        VStack(alignment:.leading,spacing:4) {
                            if let organization=contact.organization,!organization.isEmpty { Text(organization) }
                            if let email=contact.emails.first?.value { Text(email).textSelection(.enabled) }
                            if let phone=contact.phoneNumbers.first?.value { Text(phone).textSelection(.enabled) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    if let excerpt = note.transcriptSegments?.first(where: { $0.speakerID == speakerID })?.text {
                        Text(verbatim: excerpt).font(.system(size: 14)).lineSpacing(6).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(contact == nil ? "关联联系人" : "更换联系人") { showPicker = true }.disabled(!valid)
                    Button("选择已保存联系人") { showSavedContacts=true }.disabled(!valid)
                    Button("手动添加联系人") { showManualContact=true }.disabled(!valid)
                    if contact == nil {
                        Button("修改说话人名称") { nameDraft = current.speakerName(speakerID); showRename = true }.disabled(!valid)
                    } else {
                        Button("解除关联", role: .destructive) { showUnlink = true }.disabled(!valid)
                    }
                    Text("仅用于这条录音。不会修改系统联系人。") .font(.caption).foregroundStyle(.secondary)
                }
                if !valid { Text("说话人信息已更新，请处理完成后再编辑。").foregroundStyle(.orange) }
                if let failure { Text(verbatim: failure).foregroundStyle(.orange) }
            }
            .navigationTitle("说话人").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showPicker) {
                SpeakerContactPicker(selected: { contact in
                    // Persist while this view is still alive. On device, dismissing the
                    // system contact picker can also dismiss this nested speaker sheet.
                    if save(contact) { showPicker = false }
                }, cancelled: { showPicker = false })
            }
            .sheet(isPresented:$showSavedContacts) {
                SavedSpeakerContactPicker(load:{ model.contactProfiles(search:$0) },selected:{ contact in
                    _=save(contact); showSavedContacts=false
                },cancelled:{ showSavedContacts=false })
            }
            .sheet(isPresented:$showManualContact) {
                ManualSpeakerContactForm(save:{ created in
                    guard save(created) else { return nil }
                    return created
                },onSaved:{ _ in showManualContact=false },cancel:{ showManualContact=false })
            }
            .alert("解除关联", isPresented: $showUnlink) {
                Button("取消", role: .cancel) {}
                Button("解除关联", role: .destructive) { _ = save(nil) }
            } message: { Text("解除后恢复默认说话人名称。") }
            .alert("修改说话人名称", isPresented: $showRename) {
                TextField("名称", text: $nameDraft)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    guard valid else { failure = NSLocalizedString("说话人信息已更新，请处理完成后再编辑。", comment: ""); return }
                    if !model.renameSpeaker(noteID: note.id, speakerID: speakerID, name: nameDraft) { failure = model.errorMessage }
                }
            } message: { Text("应用于这条录音中该说话人的所有段落。留空可恢复默认名称。") }
        }
    }
    private func save(_ contact: SpeakerContactSnapshot?) -> Bool {
        let saved = model.setSpeakerContact(noteID: note.id, speakerID: speakerID, contact: contact, expectedRevision: note.transcriptRevision, expectedSegments: note.transcriptSegments ?? [])
        failure = saved ? nil : model.errorMessage
        return saved
    }
}

struct ContentSpeakerManagementRequest: Identifiable {
    let sourceID:AudioSourceID
    let speakerID:String
    let label:String
    let excerpt:String
    let contact:SpeakerContactSnapshot?
    var id:String { sourceID.key+":"+speakerID }
}

struct ContentSpeakerAssociationView: View {
    let request:ContentSpeakerManagementRequest
    @EnvironmentObject private var content:ContentSegmentModel
    @Environment(\.dismiss) private var dismiss
    @State private var linkedContact:SpeakerContactSnapshot?
    @State private var showPicker=false
    @State private var showSavedContacts=false
    @State private var showManualContact=false
    @State private var showUnlink=false
    @State private var saving=false
    @State private var failure:String?
    @State private var savedMessage:String?

    init(request:ContentSpeakerManagementRequest) {
        self.request=request
        _linkedContact=State(initialValue:request.contact)
    }

    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    HStack(spacing:12) {
                        SpeakerAvatar(contact:linkedContact).frame(width:42,height:42)
                        VStack(alignment:.leading,spacing:4) {
                            Text(linkedContact?.displayName ?? request.label)
                                .font(.system(size:15,weight:.semibold)).foregroundStyle(DaybookStyle.ink)
                            Text(linkedContact == nil ? "尚未关联通讯录" : linkedContact?.needsReview == true ? "说话人识别已变化，请复核关联" : "已关联通讯录")
                                .font(.system(size:11)).foregroundStyle(linkedContact?.needsReview == true ? DaybookStyle.red : DaybookStyle.secondary)
                        }
                        Spacer()
                    }.daybookRecordingCard(padding:14)

                    if !request.excerpt.isEmpty {
                        VStack(alignment:.leading,spacing:7) {
                            Text("对话片段").font(.system(size:11,weight:.semibold)).foregroundStyle(DaybookStyle.secondary)
                            Text(request.excerpt).font(.system(size:13)).lineSpacing(6).foregroundStyle(DaybookStyle.bodyText)
                                .textSelection(.enabled)
                        }.daybookRecordingCard(padding:14)
                    }

                    Button(linkedContact == nil ? "关联联系人" : "更换联系人") { showPicker=true }
                        .buttonStyle(DaybookPrimaryButtonStyle(wide:true)).disabled(saving)
                    Button("选择已保存联系人") { showSavedContacts=true }
                        .font(.system(size:12,weight:.medium)).foregroundStyle(DaybookStyle.accent)
                        .frame(maxWidth:.infinity).padding(.vertical,4).disabled(saving)
                    Button("手动添加联系人") { showManualContact=true }
                        .font(.system(size:12,weight:.medium)).foregroundStyle(DaybookStyle.accent)
                        .frame(maxWidth:.infinity).padding(.vertical,6).disabled(saving)
                    if let linkedContact {
                        VStack(alignment:.leading,spacing:4) {
                            if let organization=linkedContact.organization,!organization.isEmpty { Text(organization) }
                            if let email=linkedContact.emails.first?.value { Text(email).textSelection(.enabled) }
                            if let phone=linkedContact.phoneNumbers.first?.value { Text(phone).textSelection(.enabled) }
                        }.font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
                    }
                    if linkedContact != nil {
                        Button("解除关联") { showUnlink=true }
                            .font(.system(size:12)).foregroundStyle(DaybookStyle.red)
                            .frame(maxWidth:.infinity).padding(.vertical,8).disabled(saving)
                    }
                    Text("关联仅用于这条录音中的说话人，不会修改系统通讯录，也不会用于其他录音。")
                        .font(.system(size:10)).lineSpacing(4).foregroundStyle(DaybookStyle.secondary)
                    if saving {
                        ProgressView("正在保存联系人关联…")
                            .font(.system(size:11)).tint(DaybookStyle.accent)
                    } else if let savedMessage {
                        Label(savedMessage, systemImage:"checkmark.circle.fill")
                            .font(.system(size:11,weight:.medium)).foregroundStyle(DaybookStyle.green)
                    }
                    if let failure { Text(failure).font(.system(size:11)).foregroundStyle(DaybookStyle.red) }
                }.padding(20)
            }
            .background(DaybookStyle.paper.ignoresSafeArea())
            .navigationTitle("说话人").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() }.disabled(saving) } }
            .tint(DaybookStyle.accent)
            .sheet(isPresented:$showPicker) {
                SpeakerContactPicker(selected:{ contact in
                    // Do the durable write before dismissing the picker. This avoids
                    // losing the pending selection when UIKit closes both nested sheets.
                    save(contact)
                    showPicker=false
                },cancelled:{ showPicker=false })
            }
            .sheet(isPresented:$showSavedContacts) {
                SavedSpeakerContactPicker(load:{ await content.contactProfiles(search:$0) },selected:{ contact in
                    save(contact); showSavedContacts=false
                },cancelled:{ showSavedContacts=false })
            }
            .sheet(isPresented:$showManualContact) {
                ManualSpeakerContactForm(save:{ created in
                    guard await content.setSpeakerContact(sourceID:request.sourceID,speakerID:request.speakerID,contact:created) else { return nil }
                    return created
                },onSaved:{ contact in
                    linkedContact=contact; savedMessage="已关联到 \(contact.displayName)"; showManualContact=false
                },cancel:{ showManualContact=false })
            }
            .confirmationDialog("解除联系人关联？",isPresented:$showUnlink,titleVisibility:.visible) {
                Button("解除关联",role:.destructive) { save(nil) }
                Button("取消",role:.cancel) {}
            } message: { Text("之后会恢复为“\(request.label)”。") }
        }
        .presentationDetents([.medium,.large])
    }

    private func save(_ contact:SpeakerContactSnapshot?) {
        saving=true; failure=nil
        Task {
            let saved=await content.setSpeakerContact(sourceID:request.sourceID,speakerID:request.speakerID,contact:contact)
            saving=false
            if saved {
                linkedContact=contact
                savedMessage=contact.map { "已关联到 \($0.displayName)" } ?? "已解除联系人关联"
            }
            else { failure=content.errorMessage ?? "保存失败，请刷新后重试。" }
        }
    }
}
