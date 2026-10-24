import SwiftUI

/// Light appearance shared with iPhone NotesStyle / DaybookStyle.
enum Theme {
    static let ink = color(0x20272e)
    static let muted = color(0x65717c)
    static let accent = color(0x335f83)
    static let blueSoft = color(0xedf3f8)
    static let green = color(0x34745e)
    static let line = color(0xe5e9ed)
    static let background = color(0xf5f5f7)
    static let sidebar = color(0xedf0f3)
    static let field = color(0xedf0f3)
    static let card = Color.white
    static let warning = color(0x916014)
    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct CompanionPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(enabled ? .white : Theme.muted.opacity(0.55))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(enabled ? Theme.accent.opacity(configuration.isPressed ? 0.8 : 1) : Theme.field,
                        in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CompanionSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Theme.field.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}
