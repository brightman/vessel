import SwiftUI
import UIKit

enum NotesStyle {
    static let background = adaptive(dark: 0x080809, light: 0xf5f5f7)
    static let card = adaptive(dark: 0x1b1b1e, light: 0xffffff)
    static let field = adaptive(dark: 0x202023, light: 0xe9e9ed)
    static let border = adaptive(dark: 0x2b2b30, light: 0xe0e0e5)
    static let selected = adaptive(dark: 0x353539, light: 0xffffff)
    static let red = adaptive(dark: 0xff555d, light: 0xc41e29)
    static let green = adaptive(dark: 0x40d77c, light: 0x178541)
    static let greenBackground = adaptive(dark: 0x183625, light: 0xe2f3e7)
    static let warning = adaptive(dark: 0xf4b96f, light: 0x916014)

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self { case .dark: .dark; case .light: .light; case .system: nil }
    }
}
