import AVFoundation
import Combine
import PhotosUI
import SwiftUI
import UIKit

struct PhotoCaptureView: View {
    @ObservedObject var library: PhotoLibraryModel
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var capture = PhotoCaptureModel()
    @State private var selection: [PhotosPickerItem] = []
    @State private var caption = ""
    @State private var showCamera = false
    @State private var requestingCamera = false
    @State private var showDiscard = false
    @State private var isActive = true

    private var title: String {
        if !capture.photos.isEmpty { return "留住这些画面" }
        return capture.isLoading ? "正在准备图片" : "用图片记此刻"
    }

    var body: some View {
        DaybookSheetLayout(title: title, onClose: requestClose) {
            VStack(alignment: .leading, spacing: 0) {
                if capture.photos.isEmpty {
                    if capture.isLoading {
                        VStack(spacing: 14) {
                            ProgressView().tint(DaybookStyle.accent)
                            Text("正在打开你选择的图片…")
                                .font(.system(size: 14, weight: .medium))
                            Text("照片仅保存在此 iPhone，不会上传。")
                                .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 38)
                    } else {
                        Text("眼前的风景、讨论的白板，或一张值得留住的截图。")
                            .font(.system(size: 12)).lineSpacing(7)
                            .foregroundStyle(DaybookStyle.secondary)
                            .padding(.top, 6).padding(.bottom, 20)
                        sources
                        footnote("仅使用你主动选择的图片，不会上传。照片和识别文字保存在此 iPhone。")
                            .padding(.top, 14)
                    }
                } else {
                    previews
                    captionField.padding(.top, 18)
                    recognitionStatus.padding(.top, 14)
                    footnote("图片保存在此 iPhone，文字识别在设备上完成。")
                        .padding(.top, 12)
                    actions.padding(.top, 22)
                }
                if let message = capture.errorMessage {
                    Text(message).font(.system(size: 11)).lineSpacing(6)
                        .foregroundStyle(DaybookStyle.red).padding(.top, 14)
                }
            }
        }
        .tint(DaybookStyle.accent)
        .confirmationDialog("放弃这次照片记录？", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("放弃记录", role: .destructive) { cancel() }
            Button("继续编辑", role: .cancel) {}
        }
        .interactiveDismissDisabled(!capture.photos.isEmpty || !caption.isEmpty || capture.isLoading)
        .fullScreenCover(isPresented: $showCamera) {
            PhotoCameraView { result in
                showCamera = false
                switch result {
                case .success(let image): capture.addCameraImage(image)
                case .failure(let error): capture.errorMessage = error.localizedDescription
                case nil: break
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            capture.load(items)
            selection = []
        }
        .onChange(of: caption) { _, value in
            if value.count > 500 { caption = String(value.prefix(500)) }
        }
        .onAppear { isActive = true }
        .onDisappear {
            // A camera presentation temporarily covers this view without cancelling its draft.
            if !showCamera { isActive = false; capture.cancel() }
        }
    }

    private var sources: some View {
        VStack(spacing: 0) {
            Button { Task { await openCamera() } } label: {
                sourceRow("拍照", description: "拍下眼前这一刻。", icon: "Camera")
            }
            .disabled(requestingCamera || capture.isLoading || capture.photos.count >= 6)
            PhotosPicker(selection: $selection, maxSelectionCount: max(1, 6 - capture.photos.count),
                         matching: .images, preferredItemEncoding: .compatible) {
                sourceRow("从相册选择", description: "一次最多 6 张，确认前可以移除。", icon: "Images")
            }
            .disabled(capture.isLoading || capture.photos.count >= 6)
        }
        .buttonStyle(.plain)
    }

    private func sourceRow(_ title: String, description: String, icon: String) -> some View {
        HStack(spacing: 15) {
            DaybookIcon(icon, size: 24).foregroundStyle(DaybookStyle.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(DaybookStyle.ink)
                Text(description).font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            DaybookIcon("ChevronRight", size: 16).foregroundStyle(DaybookStyle.accent)
        }
        .padding(.vertical, 19).contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(DaybookStyle.line).frame(height: 1) }
    }

    private var previews: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(capture.photos.count) / 6 张图片")
                    .foregroundStyle(DaybookStyle.secondary)
                Spacer()
                PhotosPicker(selection: $selection, maxSelectionCount: max(1, 6 - capture.photos.count),
                             matching: .images, preferredItemEncoding: .compatible) {
                    HStack(spacing: 4) { DaybookIcon("Plus", size: 14); Text("再选几张") }
                        .foregroundStyle(DaybookStyle.accent)
                }
                .disabled(capture.isLoading || capture.photos.count >= 6)
            }
            .font(.system(size: 12)).padding(.top, 10).padding(.bottom, 16)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: capture.photos.count == 1 ? 1 : 2), spacing: 9) {
                ForEach(Array(capture.photos.enumerated()), id: \.element.id) { index, photo in
                    Color(red: 232/255, green: 238/255, blue: 238/255)
                        .aspectRatio(1.15, contentMode: .fit)
                        .overlay {
                            GeometryReader { geometry in
                                Image(uiImage: photo.preview).resizable().scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Button { capture.remove(photo.id) } label: {
                                DaybookIcon("X", size: 16).foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(Color(red: 38/255, green: 60/255, blue: 70/255).opacity(0.85), in: Circle())
                            }
                            .buttonStyle(.plain).padding(8)
                            .accessibilityLabel("移除第 \(index + 1) 张图片")
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("第 \(index + 1) 张图片")
                }
            }
            if capture.isLoading {
                ProgressView("正在载入照片…").font(.system(size: 11)).padding(.top, 12)
            }
        }
    }

    private var captionField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("补充一句（选填）").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            ZStack(alignment: .topLeading) {
                if caption.isEmpty {
                    Text("比如：这次讨论，决定先把范围收小")
                        .font(.system(size: 13)).foregroundStyle(DaybookStyle.secondary)
                        .padding(.horizontal, 13).padding(.top, 13).allowsHitTesting(false)
                }
                TextEditor(text: $caption)
                    .font(.system(size: 13)).lineSpacing(6)
                    .foregroundStyle(DaybookStyle.ink).scrollContentBackground(.hidden)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(minHeight: 124).accessibilityLabel("补充一句，选填")
            }
            .background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(red: 213/255, green: 223/255, blue: 230/255), lineWidth: 1))
        }
    }

    private var recognitionStatus: some View {
        VStack(alignment: .leading, spacing: 9) {
            if capture.isRecognizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("正在识别图片文字…").font(.system(size: 11))
                }.foregroundStyle(DaybookStyle.secondary)
            }
            ForEach(Array(capture.photos.enumerated()), id: \.element.id) { index, photo in
                if let error = photo.recognitionError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("第 \(index + 1) 张图片文字识别失败：\(error)")
                            .font(.system(size: 11)).foregroundStyle(DaybookStyle.red)
                        HStack(spacing: 10) {
                            Button("重试识别") { capture.recognize(photo.id) }
                                .foregroundStyle(DaybookStyle.accent)
                            Text("仍可保存图片和说明。").foregroundStyle(DaybookStyle.secondary)
                        }.font(.system(size: 11))
                    }
                } else if !photo.isRecognizing && photo.recognizedText.isEmpty {
                    footnote("第 \(index + 1) 张图片未识别到文字。")
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("取消", action: requestClose)
                .font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Color(red: 234/255, green: 240/255, blue: 244/255), in: RoundedRectangle(cornerRadius: 14))
            Button(action: save) {
                HStack(spacing: 7) { DaybookIcon("Check", size: 15); Text("保存到今天") }
                    .font(.system(size: 12)).foregroundStyle(DaybookStyle.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(DaybookStyle.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(capture.photos.isEmpty || capture.isLoading || capture.isRecognizing)
            .opacity(capture.isLoading || capture.isRecognizing ? 0.5 : 1)
        }
        .buttonStyle(.plain)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
    }

    private func requestClose() {
        if capture.photos.isEmpty && caption.isEmpty { cancel() }
        else { showDiscard = true }
    }

    @MainActor
    private func openCamera() async {
        requestingCamera = true
        defer { requestingCamera = false }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            capture.errorMessage = "此设备无法使用相机，请从相册选择照片。"
            return
        }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard isActive else { return }
        if allowed { showCamera = true }
        else { capture.errorMessage = "相机权限未开启。可在系统设置中允许 WiseNote 使用相机，或从相册选择。" }
    }

    private func save() {
        do {
            let photos = capture.photos.map {
                PhotoImport(jpegData: $0.jpegData, recognizedText: $0.recognizedText, recognitionError: $0.recognitionError)
            }
            _ = try library.save(caption: caption, photos: photos)
            capture.cancel()
            onSaved()
            dismiss()
        } catch { capture.errorMessage = "保存失败：\(error.localizedDescription)" }
    }

    private func cancel() { isActive = false; capture.cancel(); dismiss() }
}

private struct PhotoDraft: Identifiable {
    let id = UUID()
    let jpegData: Data
    let preview: UIImage
    var recognizedText = ""
    var recognitionError: String?
    var isRecognizing = true
}

@MainActor
private final class PhotoCaptureModel: ObservableObject {
    @Published var photos: [PhotoDraft] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    private var loadTask: Task<Void, Never>?
    private var recognitionTasks: [UUID: Task<Void, Never>] = [:]
    var isRecognizing: Bool { photos.contains { $0.isRecognizing } }

    func load(_ items: [PhotosPickerItem]) {
        guard !isLoading else { return }
        errorMessage = nil
        isLoading = true
        loadTask = Task {
            defer { isLoading = false }
            for item in items.prefix(max(0, 6 - photos.count)) {
                do {
                    try Task.checkCancellation()
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoStorageError.invalidImage }
                    try await append(data)
                } catch is CancellationError { return }
                catch { errorMessage = "部分照片无法载入：\(error.localizedDescription)" }
            }
        }
    }

    func addCameraImage(_ image: UIImage) {
        guard photos.count < 6, !isLoading else { return }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            errorMessage = PhotoStorageError.invalidImage.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            defer { isLoading = false }
            do { try await append(data) }
            catch is CancellationError {}
            catch { errorMessage = "照片载入失败：\(error.localizedDescription)" }
        }
    }

    private func append(_ data: Data) async throws {
        let jpeg = try await PhotoImageProcessing.prepare(data)
        try Task.checkCancellation()
        guard photos.count < 6, let preview = UIImage(data: jpeg) else { throw PhotoStorageError.invalidImage }
        let photo = PhotoDraft(jpegData: jpeg, preview: preview)
        photos.append(photo)
        recognize(photo.id)
    }

    func recognize(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        recognitionTasks[id]?.cancel()
        photos[index].isRecognizing = true
        photos[index].recognitionError = nil
        let data = photos[index].jpegData
        recognitionTasks[id] = Task {
            do {
                let text = try await PhotoImageProcessing.recognize(data)
                try Task.checkCancellation()
                guard let current = photos.firstIndex(where: { $0.id == id }) else { return }
                photos[current].recognizedText = text
                photos[current].isRecognizing = false
            } catch {
                guard !Task.isCancelled, let current = photos.firstIndex(where: { $0.id == id }) else { return }
                photos[current].isRecognizing = false
                photos[current].recognitionError = error.localizedDescription
            }
            recognitionTasks[id] = nil
        }
    }

    func remove(_ id: UUID) {
        recognitionTasks.removeValue(forKey: id)?.cancel()
        photos.removeAll { $0.id == id }
    }

    func cancel() {
        loadTask?.cancel()
        recognitionTasks.values.forEach { $0.cancel() }
        recognitionTasks.removeAll()
    }
}

private struct PhotoCameraView: UIViewControllerRepresentable {
    let onFinish: (Result<UIImage, Error>?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Result<UIImage, Error>?) -> Void
        init(onFinish: @escaping (Result<UIImage, Error>?) -> Void) { self.onFinish = onFinish }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onFinish(.success(image)) }
            else { onFinish(.failure(PhotoStorageError.invalidImage)) }
        }
    }
}
