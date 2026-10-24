import SwiftUI
import UIKit

/// Values copied from prototype/daybook.css, in points at the default content size.
enum DaybookStyle {
    static let ink = adaptive(0x20272e, dark: 0xe9edf1)
    static let secondary = adaptive(0x65717c, dark: 0xa6b3bf)
    static let line = adaptive(0xe5e9ed, dark: 0x303943)
    static let paper = adaptive(0xfafbfc, dark: 0x11171d)
    static let accent = adaptive(0x335f83, dark: 0x9cbedb)
    static let blueSoft = adaptive(0xedf3f8, dark: 0x202e3c)
    static let green = adaptive(0x34745e, dark: 0x8ec6ac)
    static let red = adaptive(0xbd454c, dark: 0xf08c93)
    static let white = adaptive(0xffffff, dark: 0x1b232b)
    static let field = adaptive(0xedf0f3, dark: 0x27323d)
    static let paleBlue = adaptive(0xf3f7fa, dark: 0x192733)
    static let nudge = adaptive(0xf0f5f8, dark: 0x1d2a36)
    static let player = adaptive(0xeef2f6, dark: 0x202e3c)
    static let tabs = adaptive(0xe8edf1, dark: 0x27323d)
    static let bodyText = adaptive(0x41525f, dark: 0xc4cfd9)
    static let recapSurface = adaptive(0xf5f3ef, dark: 0x282722)
    static let recapBorder = adaptive(0xe9e5df, dark: 0x3d3932)
    static let recapLabel = adaptive(0x786d60, dark: 0xc6b9a7)
    static let recapMuted = adaptive(0x8b8177, dark: 0xa59b8e)

    private static func adaptive(_ light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

struct DaybookIcon: View {
    let name: String
    var size: CGFloat = 22
    init(_ name: String, size: CGFloat = 22) { self.name = name; self.size = size }
    var body: some View {
        Image("Daybook" + name).renderingMode(.template).resizable().scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct DaybookSheetLayout<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: Content
    init(title: String, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title; self.onClose = onClose; self.content = content()
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(LocalizedStringKey(title)).font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: onClose) { DaybookIcon("X", size: 17).frame(width: 32, height: 32).background(DaybookStyle.field, in: Circle()) }
                    .accessibilityLabel("关闭")
            }.padding(.horizontal, 23).padding(.top, 7).padding(.bottom, 8)
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 25).padding(.top, 5).padding(.bottom, 32)
            }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
        }.padding(.top, 16).foregroundStyle(DaybookStyle.ink)
            .background(DaybookStyle.paper.ignoresSafeArea())
            .tint(DaybookStyle.accent).buttonStyle(.plain)
            .toolbar(.hidden, for: .navigationBar)
            .presentationCornerRadius(28).presentationDragIndicator(.visible)
    }
}

struct DaybookPrimaryButtonStyle: ButtonStyle {
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: wide ? 13 : 11, weight: .medium))
            .foregroundStyle(DaybookStyle.white).padding(.horizontal, 14).padding(.vertical, wide ? 14 : 10)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(DaybookStyle.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: wide ? 14 : 20))
    }
}

struct DaybookSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(DaybookStyle.blueSoft.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 14))
    }
}
