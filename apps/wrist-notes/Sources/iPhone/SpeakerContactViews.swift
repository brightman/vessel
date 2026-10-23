import SwiftUI
import ContactsUI

/// Personal names are literal text; only built-in speaker labels are localization keys.
struct SpeakerNameText: View {
    let note: VoiceNote
    let speakerID: String
    var body: some View {
        if let contact = note.speakerContacts?[speakerID] {
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
            parent.selected(.init(identifier: contact.identifier, displayName: name, thumbnailData: thumbnail))
        }
    }
}

struct SpeakerManagementView: View {
    let note: VoiceNote
    let speakerID: String
    @EnvironmentObject private var model: NotesModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var pendingContact: SpeakerContactSnapshot?
    @State private var showConfirmation = false
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
                            Text(contact == nil ? "尚未关联联系人" : "已关联联系人").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let excerpt = note.transcriptSegments?.first(where: { $0.speakerID == speakerID })?.text {
                        Text(verbatim: excerpt).font(.system(size: 14)).lineSpacing(6).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(contact == nil ? "关联联系人" : "更换联系人") { showPicker = true }.disabled(!valid)
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
            .sheet(isPresented: $showPicker, onDismiss: { if pendingContact != nil { showConfirmation = true } }) {
                SpeakerContactPicker(selected: { pendingContact = $0; showPicker = false }, cancelled: { pendingContact = nil; showPicker = false })
            }
            .alert("确认关联联系人", isPresented: $showConfirmation) {
                Button("取消", role: .cancel) { pendingContact = nil }
                Button("确认关联") { if save(pendingContact) { pendingContact = nil } }
            } message: { Text(verbatim: pendingContact?.displayName ?? "") }
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
