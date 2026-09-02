import SwiftUI

// MARK: - Palette

/// The handful of colours every view is allowed to use. A colorway swaps these
/// values; layout, spacing and type never change with it.
struct Palette {
    let paper: Color      // main background
    let side: Color       // sidebar / secondary surface
    let ink: Color        // text, rules, solid blocks
    let onInk: Color      // text sitting on an ink-filled block
    let line: Color       // quiet border, inactive outline
    let muted: Color      // secondary text
    let accent: Color     // the one signal colour, for fills
    let onAccent: Color   // text sitting on accent
    let accentText: Color // the accent darkened enough to read as text on paper
    let isDark: Bool
}

// MARK: - Colorway

enum Colorway: String, CaseIterable, Identifiable {
    case schwefel, saeure, zinnober, bleiRost, signalblau, magenta

    var id: String { rawValue }

    var label: String {
        switch self {
        case .schwefel:   return "Schwefel"
        case .saeure:     return "Säure"
        case .zinnober:   return "Zinnober"
        case .bleiRost:   return "Blei & Rost"
        case .signalblau: return "Signalblau"
        case .magenta:    return "Magenta"
        }
    }

    var note: String {
        switch self {
        case .schwefel:   return "Textmarker-Gelb. Der Standard."
        case .saeure:     return "Wach und laut."
        case .zinnober:   return "Warm und dringlich."
        case .bleiRost:   return "Ruhig; als einziger auch auf Papier und in Graustufen sauber."
        case .signalblau: return "Nüchtern — kollidiert aber mit der Systemakzentfarbe."
        case .magenta:    return "Die mutigste."
        }
    }

    func palette(dark: Bool) -> Palette { dark ? darkPalette : lightPalette }

    private var lightPalette: Palette {
        switch self {
        case .schwefel:
            return Palette(paper: .hex(0xFFFDF5), side: .hex(0xF3EFE1), ink: .hex(0x14120C),
                           onInk: .hex(0xFFFDF5), line: .hex(0xE2DDC9), muted: .hex(0x9A9584),
                           accent: .hex(0xFFC400), onAccent: .hex(0x14120C), accentText: .hex(0xB08600),
                           isDark: false)
        case .saeure:
            return Palette(paper: .hex(0xFFFFFF), side: .hex(0xF4F4F4), ink: .hex(0x111111),
                           onInk: .hex(0xFFFFFF), line: .hex(0xE2E2E2), muted: .hex(0x9A9A9A),
                           accent: .hex(0xD8F235), onAccent: .hex(0x111111), accentText: .hex(0x6B7A00),
                           isDark: false)
        case .zinnober:
            return Palette(paper: .hex(0xFFFFFF), side: .hex(0xF4F2F0), ink: .hex(0x111111),
                           onInk: .hex(0xFFFFFF), line: .hex(0xE4E0DC), muted: .hex(0x9A9590),
                           accent: .hex(0xFF4D1F), onAccent: .hex(0xFFFFFF), accentText: .hex(0xD63A0F),
                           isDark: false)
        case .bleiRost:
            return Palette(paper: .hex(0xF5F3EE), side: .hex(0xE7E4DD), ink: .hex(0x14161A),
                           onInk: .hex(0xF5F3EE), line: .hex(0xD4D0C6), muted: .hex(0x8E8B82),
                           accent: .hex(0xB7410E), onAccent: .hex(0xFFFFFF), accentText: .hex(0xB7410E),
                           isDark: false)
        case .signalblau:
            return Palette(paper: .hex(0xFAFAF8), side: .hex(0xEDEDEA), ink: .hex(0x101418),
                           onInk: .hex(0xFAFAF8), line: .hex(0xDCDCD8), muted: .hex(0x93938E),
                           accent: .hex(0x1A4DFF), onAccent: .hex(0xFFFFFF), accentText: .hex(0x1A4DFF),
                           isDark: false)
        case .magenta:
            return Palette(paper: .hex(0xFCFAFB), side: .hex(0xF1EDEF), ink: .hex(0x0E0E10),
                           onInk: .hex(0xFCFAFB), line: .hex(0xDFDADD), muted: .hex(0x959093),
                           accent: .hex(0xFF2D6F), onAccent: .hex(0xFFFFFF), accentText: .hex(0xE01055),
                           isDark: false)
        }
    }

    private var darkPalette: Palette {
        switch self {
        case .schwefel:
            return Palette(paper: .hex(0x14120C), side: .hex(0x1E1B15), ink: .hex(0xFFFDF5),
                           onInk: .hex(0x14120C), line: .hex(0x3A362C), muted: .hex(0x8C866F),
                           accent: .hex(0xFFC400), onAccent: .hex(0x14120C), accentText: .hex(0xFFC400),
                           isDark: true)
        case .saeure:
            return Palette(paper: .hex(0x111111), side: .hex(0x1A1A1A), ink: .hex(0xFFFFFF),
                           onInk: .hex(0x111111), line: .hex(0x333333), muted: .hex(0x8A8A8A),
                           accent: .hex(0xD8F235), onAccent: .hex(0x111111), accentText: .hex(0xD8F235),
                           isDark: true)
        case .zinnober:
            return Palette(paper: .hex(0x111111), side: .hex(0x1B1918), ink: .hex(0xFFFFFF),
                           onInk: .hex(0x111111), line: .hex(0x35312F), muted: .hex(0x8A847F),
                           accent: .hex(0xFF4D1F), onAccent: .hex(0xFFFFFF), accentText: .hex(0xFF6A42),
                           isDark: true)
        case .bleiRost:
            return Palette(paper: .hex(0x14161A), side: .hex(0x1E2126), ink: .hex(0xF5F3EE),
                           onInk: .hex(0x14161A), line: .hex(0x383C44), muted: .hex(0x868C96),
                           accent: .hex(0xC4551F), onAccent: .hex(0xFFFFFF), accentText: .hex(0xE07A45),
                           isDark: true)
        case .signalblau:
            return Palette(paper: .hex(0x101418), side: .hex(0x191E25), ink: .hex(0xFAFAF8),
                           onInk: .hex(0x101418), line: .hex(0x303740), muted: .hex(0x848B96),
                           accent: .hex(0x4A73FF), onAccent: .hex(0xFFFFFF), accentText: .hex(0x7A9BFF),
                           isDark: true)
        case .magenta:
            return Palette(paper: .hex(0x0E0E10), side: .hex(0x18181C), ink: .hex(0xFCFAFB),
                           onInk: .hex(0x0E0E10), line: .hex(0x2E2E34), muted: .hex(0x85858C),
                           accent: .hex(0xFF2D6F), onAccent: .hex(0xFFFFFF), accentText: .hex(0xFF6D9C),
                           isDark: true)
        }
    }
}

// MARK: - Appearance

enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light:  return "Hell"
        case .dark:   return "Dunkel"
        case .system: return "System"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }
}

// MARK: - Environment

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Colorway.schwefel.palette(dark: false)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Wraps a scene's content and injects the palette the user picked. Kept as one
/// view so "System" can read the real colour scheme before resolving.
struct Themed<Content: View>: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var systemScheme
    @ViewBuilder var content: Content

    var body: some View {
        let appearance = settings.appearanceValue
        let dark = appearance == .dark || (appearance == .system && systemScheme == .dark)
        let palette = settings.colorwayValue.palette(dark: dark)
        content
            .environment(\.palette, palette)
            .environment(\.locale, settings.uiLocale ?? Locale.autoupdatingCurrent)
            .tint(palette.accent)
            .preferredColorScheme(appearance.colorScheme)
    }
}

// MARK: - Type

/// One place for the brand's type. Swapping in a bundled face later means
/// changing these four functions and nothing else.
enum Brand {
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }
    static func label(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func body(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
}

extension View {
    /// The small uppercase label used for section headers and buttons.
    func caps(_ size: CGFloat = 10, tracking: CGFloat = 1.2) -> some View {
        self.font(Brand.label(size, .semibold))
            .textCase(.uppercase)
            .tracking(tracking)
    }
}

extension Color {
    static func hex(_ value: UInt32) -> Color {
        Color(.sRGB,
              red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255,
              opacity: 1)
    }
}
