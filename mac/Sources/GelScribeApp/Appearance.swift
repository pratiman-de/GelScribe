import AppKit
import SwiftUI

/// The app's look: dark (the default, Pixelmator-style) or light, whatever macOS itself uses. View › Appearance.
enum AppAppearance: String, CaseIterable, Identifiable {
    case dark, light

    static let key = "appearance"
    var id: String { rawValue }
    var title: String { self == .dark ? "Dark" : "Light" }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var nsAppearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }

    static var current: AppAppearance { AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark }

    /// AppKit (the canvas, popovers, menus) follows NSApp.appearance; SwiftUI views read the same setting through
    /// @AppStorage.
    static func apply(_ a: AppAppearance = current) { NSApp.appearance = a.nsAppearance }
}

extension NSAppearance {
    nonisolated var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// Colors that differ between the two looks. Dark values are the ones the app has always used.
enum Chrome {
    /// Behind the figure. (The dark one in Generic RGB, as the canvas always drew it.)
    static let backdrop = dynamic(dark: NSColor(cgColor: CGColor(red: 0.105, green: 0.105, blue: 0.115, alpha: 1))!,
                                  light: NSColor(white: 0.8, alpha: 1))   // mid gray, so the white page stands out
    /// Canvas editors: solid, so the gel and inspector don't show through the glass.
    static let popover = dynamic(dark: NSColor(white: 0.155, alpha: 1), light: NSColor(white: 0.975, alpha: 1))
    /// Subtle fills and borders (cards, chips, fields): white on dark, black on light, at the same opacities.
    static let ink = dynamic(dark: .white, light: .black)
    /// The histogram's well.
    static let inset = dynamic(dark: NSColor(white: 0, alpha: 0.25), light: NSColor(white: 0, alpha: 0.06))

    nonisolated static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

extension Color {
    static let ink = Color(nsColor: Chrome.ink)
    static let inset = Color(nsColor: Chrome.inset)
}

/// The floating panels. Dark: glass, as they always were. Light: solid near-white with a hairline edge and a soft
/// shadow. Glass on the light backdrop came out gray on gray, and a white tint only made it darker.
struct PanelGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if scheme == .dark {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(shape.fill(Color(nsColor: NSColor(white: 0.985, alpha: 1))))
                .overlay(shape.strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                .clipShape(shape)
                .shadow(color: .black.opacity(0.14), radius: 12, y: 3)
        }
    }
}

extension View {
    func panelGlass<S: InsettableShape>(in shape: S) -> some View { modifier(PanelGlass(shape: shape)) }
}
