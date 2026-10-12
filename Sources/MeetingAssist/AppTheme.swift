import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable {
    case dark = "Dark"
    case light = "Light"
    var scheme: ColorScheme { self == .dark ? .dark : .light }
    var appearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
    var next: Self { self == .dark ? .light : .dark }
}

enum MeetlyPalette {
    static func adaptive(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static let canvas = Color(nsColor: adaptive(dark: 0x131616, light: 0xF3F5F8))
    static let panel = Color(nsColor: adaptive(dark: 0x1C2020, light: 0xFFFFFF))
    static let accentColor = adaptive(dark: 0xA8DBB8, light: 0x176548)
    static let accent = Color(nsColor: accentColor)
    static let codeBackground = Color(nsColor: adaptive(dark: 0x111717, light: 0xEAF0F3))
    static let comment = Color(nsColor: adaptive(dark: 0xA8DBB8, light: 0x226344))
}

struct ThemeButton: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        Button {
            model.theme = model.theme.next
        } label: {
            Image(systemName: model.theme == .dark ? "sun.max" : "moon")
                .frame(width: 24, height: 24)
        }.accessibilityLabel("Switch to \(model.theme.next.rawValue.lowercased()) mode")
            .help("Switch the whole app to \(model.theme.next.rawValue.lowercased()) mode")
    }
}

private struct SurfaceOpacityKey: EnvironmentKey { static let defaultValue = 1.0 }
extension EnvironmentValues {
    var surfaceOpacity: Double {
        get { self[SurfaceOpacityKey.self] }
        set { self[SurfaceOpacityKey.self] = newValue }
    }
}
