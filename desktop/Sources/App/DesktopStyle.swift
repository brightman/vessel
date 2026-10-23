import SwiftUI
import AppKit

/// Same semantic colors and corner radii as the iPhone's DaybookStyle.
enum DesktopStyle {
    static let ink = adaptive(0x20272e, 0xe9edf1)
    static let secondary = adaptive(0x65717c, 0xa6b3bf)
    static let line = adaptive(0xe5e9ed, 0x303943)
    static let paper = adaptive(0xfafbfc, 0x11171d)
    static let accent = adaptive(0x335f83, 0x9cbedb)
    static let blueSoft = adaptive(0xedf3f8, 0x202e3c)
    static let green = adaptive(0x34745e, 0x8ec6ac)
    static let red = adaptive(0xbd454c, 0xf08c93)
    static let card = adaptive(0xffffff, 0x1b232b)
    static let field = adaptive(0xedf0f3, 0x27323d)
    static let bodyText = adaptive(0x41525f, 0xc4cfd9)
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static func timestamp(_ value: Double) -> String { String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60) }
}
struct DesktopPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(DesktopStyle.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct DesktopQuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(DesktopStyle.accent)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(DesktopStyle.blueSoft.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}
extension View {
    func desktopCard() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(DesktopStyle.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(DesktopStyle.line, lineWidth: 1))
    }
}
