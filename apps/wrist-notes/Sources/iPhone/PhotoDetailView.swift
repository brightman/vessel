import SwiftUI
import UIKit

struct PhotoDetailView: View {
    let momentID: UUID
    @ObservedObject var library: PhotoLibraryModel
    var onAskAI: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int?
    @State private var confirmDelete = false

    private var moment: PhotoMoment? { library.moments.first { $0.id == momentID } }

    var body: some View {
        GeometryReader { geometry in
            DaybookSheetLayout(title: selectedIndex == nil ? (moment?.title ?? "图片记录") : "查看原图", onClose: { dismiss() }) {
                if let moment {
                    if let selectedIndex, moment.photos.indices.contains(selectedIndex) {
                        original(moment, index: selectedIndex, height: geometry.size.height * 0.63)
                    } else {
                        detail(moment)
                    }
                } else {
                    VStack(spacing: 12) {
                        DaybookIcon("Images", size: 28).foregroundStyle(DaybookStyle.secondary)
                        Text("照片记录不存在").font(.system(size: 14, weight: .medium))
                        if let error = library.errorMessage {
                            Text(error).font(.system(size: 11)).foregroundStyle(DaybookStyle.red)
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            }
            .id(selectedIndex == nil)
        }
        .toolbar(.hidden, for: .navigationBar)
        .tint(DaybookStyle.accent)
        .confirmationDialog("删除这条记录和本地照片？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除记录", role: .destructive) {
                library.delete(momentID)
                if library.errorMessage == nil { dismiss() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func detail(_ moment: PhotoMoment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(moment.capturedAt.formatted(.dateTime.month().day().hour().minute())) · iPhone · \(moment.photos.count) 张图片")
                .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
                .padding(.bottom, 18)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: moment.photos.count == 1 ? 1 : 2), spacing: 9) {
                ForEach(Array(moment.photos.enumerated()), id: \.element.id) { index, attachment in
                    Button { selectedIndex = index } label: {
                        Color(red: 232/255, green: 238/255, blue: 238/255)
                            .aspectRatio(1.3, contentMode: .fit)
                            .overlay {
                                GeometryReader { geometry in
                                    PhotoStoredImage(url: library.imageURL(for: attachment), fit: false)
                                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain).accessibilityLabel("查看第 \(index + 1) 张原图")
                }
            }
            sectionTitle("补充说明")
            bodyText(moment.caption.isEmpty ? "没有补充说明，也可以先留住画面。" : moment.caption)
            sectionTitle("图片文字")
            VStack(alignment: .leading, spacing: 13) {
                ForEach(Array(moment.photos.enumerated()), id: \.element.id) { index, photo in
                    VStack(alignment: .leading, spacing: 5) {
                        if moment.photos.count > 1 {
                            Text("第 \(index + 1) 张图片").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                        }
                        if let error = photo.recognitionError {
                            Text("文字识别失败：\(error)")
                                .font(.system(size: 13)).lineSpacing(8).foregroundStyle(DaybookStyle.red)
                        } else {
                            bodyText(photo.recognizedText.isEmpty ? "未识别到文字。" : photo.recognizedText)
                        }
                    }
                }
            }
            if let onAskAI {
                Button(action: onAskAI) {
                    HStack(spacing: 7) { DaybookIcon("MessageCircle", size: 15); Text("问问 AI 这些图片") }
                        .font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(red: 234/255, green: 240/255, blue: 244/255), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain).padding(.top, 12)
            }
            if let error = library.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(DaybookStyle.red).padding(.top, 14)
            }
        }
        .contextMenu {
            Button("删除图片记录", role: .destructive) { confirmDelete = true }
        }
        .accessibilityAction(named: "删除图片记录") { confirmDelete = true }
    }

    private func original(_ moment: PhotoMoment, index: Int, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            PhotoStoredImage(url: library.imageURL(for: moment.photos[index]), fit: true)
                .id(moment.photos[index].id)
                .frame(height: height).frame(maxWidth: .infinity)
                .padding(4)
                .background(Color(red: 237/255, green: 240/255, blue: 242/255), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("第 \(index + 1) 张原图，可双指缩放")
            HStack(spacing: 25) {
                Button { selectedIndex = index - 1 } label: {
                    DaybookIcon("ChevronLeft", size: 22).frame(width: 32, height: 32)
                }
                .disabled(index == 0).opacity(index == 0 ? 0.5 : 1).accessibilityLabel("上一张")
                Text("\(index + 1) / \(moment.photos.count)")
                    .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                Button { selectedIndex = index + 1 } label: {
                    DaybookIcon("ChevronRight", size: 22).frame(width: 32, height: 32)
                }
                .disabled(index == moment.photos.count - 1).opacity(index == moment.photos.count - 1 ? 0.5 : 1)
                .accessibilityLabel("下一张")
            }
            .buttonStyle(.plain).foregroundStyle(DaybookStyle.ink).padding(.vertical, 12)
            Button { selectedIndex = nil } label: {
                Text("回到图片记录").font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color(red: 234/255, green: 240/255, blue: 244/255), in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).padding(.top, 12)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(DaybookStyle.ink)
            .padding(.top, 24).padding(.bottom, 12)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).lineSpacing(8)
            .foregroundStyle(Color(red: 67/255, green: 84/255, blue: 96/255))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PhotoStoredImage: View {
    let url: URL?
    let fit: Bool
    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                if fit { PhotoZoomImage(image: image) }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else if loaded {
                VStack(spacing: 8) {
                    DaybookIcon("Images", size: 22)
                    Text("照片文件不可用").font(.system(size: 11))
                }
                .foregroundStyle(DaybookStyle.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(DaybookStyle.field)
            } else { ProgressView() }
        }
        .task(id: url) {
            loaded = false
            image = nil
            if let url {
                let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
                if !Task.isCancelled, let data { image = UIImage(data: data) }
            }
            loaded = true
        }
    }
}

private struct PhotoZoomImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PhotoZoomScrollView {
        let view = PhotoZoomScrollView()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1
        view.maximumZoomScale = 5
        view.backgroundColor = UIColor(red: 237/255, green: 240/255, blue: 242/255, alpha: 1)
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.imageView.image = image
        view.imageView.contentMode = .scaleAspectFit
        view.addSubview(view.imageView)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ view: PhotoZoomScrollView, context: Context) {
        if view.imageView.image !== image {
            view.setZoomScale(1, animated: false)
            view.imageView.image = image
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? PhotoZoomScrollView)?.imageView
        }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PhotoZoomScrollView else { return }
            if view.zoomScale > 1 { view.setZoomScale(1, animated: true) }
            else {
                let point = gesture.location(in: view.imageView)
                let size = CGSize(width: view.bounds.width / 3, height: view.bounds.height / 3)
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), animated: true)
            }
        }
    }
}

private final class PhotoZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    private var previousSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize {
            previousSize = bounds.size
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }
}
