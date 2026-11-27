import SwiftUI

/// A space is a separate browsing identity: its own tabs, history, and its own
/// persistent WebKit data store (cookies, logins, local storage, cache).
struct Space: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorHex: String
    var symbol: String
    /// Optional so state saved before this existed still decodes.
    var privacy: PrivacySettings?

    /// The space's colour. The neutrals (greys and black) lift in Dark Mode, keeping their order, so the space's
    /// name and accents stay readable on a dark window, as the system's own label colour does.
    var color: Color {
        let base = Color(hex: colorHex)
        guard Space.neutrals.contains(colorHex) else { return base }
        let lum = Color.luminance(colorHex), target = 0.6 + lum * 0.25
        let light = base.mix(with: .white, by: max(0, (target - lum) / (1 - lum)))
        #if os(macOS)
        return Color(NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(light) : NSColor(base) })
        #else
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(light) : UIColor(base) })
        #endif
    }

    /// Light space colours (yellow, mint…) need dark text on them; most take white.
    var prefersDarkText: Bool { Color.luminance(colorHex) > 0.7 }

    var privacySettings: PrivacySettings {
        get { privacy ?? PrivacySettings() }
        set { privacy = newValue }
    }

    /// Orange, Pink, Purple, Indigo, Blue, Teal, Green.
    static let colours = ["#E8590C", "#D6336C", "#AE3EC9", "#7048E8", "#1C7ED6", "#0C8599", "#2F9E44"]
    /// The quiet ones: Stone, Graphite, Slate, Charcoal, Black.
    static let neutrals = ["#8C8279", "#868E96", "#5F6B78", "#3A3F45", "#16181B"]
    /// New spaces take the first unused, so colours come before neutrals.
    static let palette = colours + neutrals
    static let paletteNames = ["Orange", "Pink", "Purple", "Indigo", "Blue", "Teal", "Green",
                               "Stone", "Graphite", "Slate", "Charcoal", "Black"]

    static func colourName(_ hex: String) -> String { palette.firstIndex(of: hex).map { paletteNames[$0] } ?? "Colour" }
    static let symbols = ["person.fill", "briefcase.fill", "house.fill", "graduationcap.fill", "gamecontroller.fill",
                          "cart.fill", "heart.fill", "star.fill", "leaf.fill", "hammer.fill", "paintbrush.fill", "airplane"]

    static func makeDefault() -> [Space] {
        [Space(name: "Personal", colorHex: "#D6336C", symbol: "person.fill"),
         Space(name: "Work", colorHex: "#1C7ED6", symbol: "briefcase.fill")]
    }
}

struct SpaceEditorState: Identifiable {
    let id = UUID()
    var space: Space
    var isNew: Bool
}

extension Color {
    /// Perceived brightness of a "#RRGGBB" colour, 0–1.
    static func luminance(_ hex: String) -> Double {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count >= 6, let value = UInt32(digits.prefix(6), radix: 16) else { return 0.5 }
        let r = Double((value >> 16) & 0xFF), g = Double((value >> 8) & 0xFF), b = Double(value & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255
    }

    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x868E96
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// A website's colour (sampled from the top of the page), 0–255 per channel.
struct RGBColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    var color: Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255) }
    var isDark: Bool { (0.299 * r + 0.587 * g + 0.114 * b) / 255 < 0.6 }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

enum AutoClearSchedule: String, Codable, CaseIterable, Identifiable {
    case never, onQuit, daily, weekly, monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .onQuit: "When Dew quits"
        case .daily: "Every day"
        case .weekly: "Every week"
        case .monthly: "Every month"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .never, .onQuit: nil
        case .daily: 86_400
        case .weekly: 7 * 86_400
        case .monthly: 30 * 86_400
        }
    }
}

/// Per-space automatic clearing.
struct PrivacySettings: Codable, Hashable {
    var schedule: AutoClearSchedule = .never
    var clearHistory = true
    var clearCookies = true
    var lastCleared: Date?
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    let spaceID: UUID
    var title: String
    var url: URL
    var faviconURL: URL?
    /// Last local change, for iCloud sync (newest edit wins). Optional so older saved data decodes.
    var modified: Date?
}
