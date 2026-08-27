//
//  Color+Theme.swift
//  Folder
//
//  Custom theme colors
//

import SwiftUI
import AppKit

extension Color {
    /// IntelliLab's single action color. It is reserved for focus, selection
    /// and primary actions so the browser keeps Finder's information density.
    static let folderAccent = Color(hex: "#00A98F")
    static let folderAccentMuted = Color(hex: "#073F3B")
    static let folderSurface = Color.dynamic(light: "#F7F9FB", dark: "#1C242E")
    static let folderElevated = Color.dynamic(light: "#FFFFFF", dark: "#26313D")
    static let folderStroke = Color.dynamic(light: "#DDE3E9", dark: "#3A4653")
    static let folderSubtleFill = Color.dynamic(light: "#EEF3F5", dark: "#202A34")

    // Adaptive colors for light/dark mode
    static var folderBase: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(red: 20/255, green: 27/255, blue: 35/255, alpha: 1)  // Dark mode
                : NSColor(red: 1, green: 1, blue: 1, alpha: 1)                  // Light mode (white)
        })
    }

    static var folderSidebar: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(red: 22/255, green: 29/255, blue: 38/255, alpha: 1)   // Dark mode
                : NSColor(red: 245/255, green: 245/255, blue: 247/255, alpha: 1) // Light mode (light gray)
        })
    }

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
            return NSColor(Color(hex: value))
        })
    }
}

/// Compact IntelliLab chrome for the navigation controls. The style keeps the
/// native hit target and disabled-state behavior but gives actions a consistent
/// surface instead of unrelated bare glyphs.
struct FolderChromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.45))
            .frame(width: 30, height: 30)
            .background(configuration.isPressed ? Color.folderAccent.opacity(0.20) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension NSColor {
    static let folderAccent = NSColor(red: 0x00 / 255.0, green: 0xA9 / 255.0, blue: 0x8F / 255.0, alpha: 1.0)
    static let folderSidebar = NSColor(red: 22/255, green: 29/255, blue: 38/255, alpha: 1.0)
}
