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

    var color: Color { Color(hex: colorHex) }

    /// Light space colours (yellow, mint…) need dark text on them; most take white.
    var prefersDarkText: Bool {
        let hex = colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else { return false }
        let r = Double((value >> 16) & 0xFF), g = Double((value >> 8) & 0xFF), b = Double(value & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.7
    }

    var privacySettings: PrivacySettings {
        get { privacy ?? PrivacySettings() }
        set { privacy = newValue }
    }

    static let palette = ["#E8590C", "#D6336C", "#AE3EC9", "#7048E8", "#1C7ED6", "#0C8599", "#2F9E44", "#868E96"]
    static let paletteNames = ["Orange", "Pink", "Purple", "Indigo", "Blue", "Teal", "Green", "Graphite"]
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
