import SwiftUI

struct OnboardingUsageView: View {
    @State private var watch = false
    @State private var topic = 0
    @State private var fullImage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("选择设备使用说明", selection: $watch) {
                Text("使用 iPhone").tag(false)
                Text("Apple Watch").tag(true)
            }.pickerStyle(.segmented)
            if watch { watchGuide } else { phoneGuide }
            Text("图示来自 WiseLife 原生 App 模拟器截图。轻点图片可查看完整截图。")
                .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
        }
        .sheet(isPresented: Binding(get: { fullImage != nil }, set: { if !$0 { fullImage = nil } })) {
            NavigationStack {
                GeometryReader { geometry in
                    ScrollView(.vertical) {
                        Image(fullImage ?? "").resizable().scaledToFit()
                            .frame(width: max(1, geometry.size.width - 32)).padding(16)
                            .accessibilityLabel("WiseLife 完整模拟器截图")
                    }
                }.background(DaybookStyle.paper)
                    .navigationTitle("模拟器截图").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { fullImage = nil } } }
            }
        }
    }
    private var phoneGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("iPhone 使用主题", selection: $topic) {
                Text("开始录音").tag(0)
                Text("结束保存").tag(1)
                Text("拍照与相册").tag(2)
            }.pickerStyle(.segmented)
            switch topic {
            case 0:
                instruction("1. 从「记此刻」开始", "在首页右下角轻点「＋ 记此刻」，再选择「语音」，就会开始录音。")
                screenshot("iphone-home", caption: "首页 · 右下角入口")
                screenshot("iphone-capture", caption: "记此刻 · 选择语音")
                SettingsInfo(title: "只想记一个想法？", text: "点「记一条闪念 →」。说完后，同样点「结束并保存」。iPhone 这里不需要一直按住按钮。")
            case 1:
                instruction("2. 说完，点「结束并保存」", "录音时，页面底部会出现红色计时条。轻点「结束并保存」，等待保存完成。")
                screenshot("iphone-recording", caption: "录音中 · 结束并保存")
                SettingsInfo(title: "之后在哪里看？", text: "图片和闪念可在「一天」查看；长录音加工后的内容片段也会进入时间轴。完整录音可从「查看全部 → 原始录音」查找。")
                SettingsFootnote(text: "模型尚未就绪时，原始录音仍可保存。转写和整理需要等待相应模型准备好，不代表保存失败。")
            default:
                instruction("3. 用图片，留下眼前的画面", "轻点「记此刻 → 图片」。拍下眼前，或从相册选取已有照片。")
                screenshot("iphone-photo", caption: "图片 · 拍照或从相册选择")
                instruction("拍照", "选择「拍照」，首次允许相机访问；拍摄后确认使用这张照片。")
                instruction("从相册选择", "只选择你想记录的图片，一次最多 6 张；确认前可以移除。")
                instruction("确认并保存", "预览图片，可补充一句话。文字识别完成后，点「保存记录」，回到「一天」查看。")
                SettingsFootnote(text: "图片与识别文字保存在 iPhone。模拟器展示的是图片入口，实际拍摄需要在真机上完成。")
            }
            SettingsFootnote(text: "麦克风、相机权限在首次使用时申请。若未允许，可在 iPhone「设置 → App → WiseLife」中调整。")
        }
    }
    private var watchGuide: some View {
        VStack(alignment: .leading, spacing: 20) {
            instruction("先把 WiseLife 装到手表", "打开 iPhone 自带的 Watch App，先完成与这部 iPhone 的配对，再进入「我的手表」。")
            instruction("找到 WiseLife，轻点「安装」", "进入 App 列表，在「可用 App」中找到 WiseLife。部分系统版本直接在「我的手表」下显示此列表。")
            instruction("在手表上打开 WiseLife", "若已自动安装，可在「已安装在 Apple Watch 上」查看。首次录音时，允许手表的麦克风权限。")
            SettingsFootnote(text: "没有找到 WiseLife？确认 iPhone 安装的版本包含 Watch App、手表系统兼容，并等待安装完成。阅读说明不会自动安装或配对。")
            Link("Apple 官方安装说明 ↗", destination: URL(string: "https://support.apple.com/zh-cn/109023")!).font(.system(size: 12))
            screenshot("watch-recorder", caption: "Apple Watch · 原生录音页面", cropped: false)
            instruction("轻点：持续录音", "点一下红色按钮开始；再次点按停止按钮，结束并保存。")
            instruction("按住：记录闪念", "按住红色按钮，震动后说话；松手保存。向上滑再松手可取消。")
            SettingsInfo(title: "先保存在手表，再同步到 iPhone", text: "让两台设备靠近，保持蓝牙与 Wi-Fi 开启。无需在同一个 Wi-Fi；系统会安排传输，可能需要等待。\n在 iPhone 首页点左上角手表状态，查看「待同步」或「最近同步」。已配对不等于文件已传完，也不代表 Watch App 已安装。")
            SettingsFootnote(text: "可选：长按表盘 → 编辑 → 复杂功能，添加 WiseLife 录音入口。轻点入口可开始录音；已经录音时只打开 App，结束仍需点停止按钮。")
            Button("没有手表？查看 iPhone 录音与拍照") { watch = false }.font(.system(size: 12)).padding(.vertical, 8)
        }
    }
    private func instruction(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 15, weight: .medium))
            Text(text).font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).lineSpacing(7)
        }
    }
    private func screenshot(_ name: String, caption: String, cropped: Bool = true) -> some View {
        Button { fullImage = "Onboarding-" + name } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image("Onboarding-" + name + (cropped ? "-detail" : ""))
                    .resizable().scaledToFit().frame(maxWidth: .infinity).frame(maxHeight: cropped ? 280 : 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Label(caption, systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
            }
        }.accessibilityLabel(caption + "，查看完整截图")
    }
}
