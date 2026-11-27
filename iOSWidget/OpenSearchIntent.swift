import AppIntents
import Foundation

/// The Search widget's capsule: opens Dew and asks it for a new tab with the search box ready. A widget button can't
/// open a URL itself, and a small widget has only one tap target for links, so the request goes through the App
/// Group that Dew and the widget share. Part of both targets.
struct OpenSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "Search in Dew"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    /// When the capsule was tapped (seconds since 1970), waiting for Dew to act on it.
    static let requestKey = "widgetSearchRequested"
    /// Posted when the intent runs inside Dew itself, which is then already in front.
    static let requested = Notification.Name("DewWidgetSearchRequested")

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: "group.com.automate.dew")?.set(Date().timeIntervalSince1970, forKey: Self.requestKey)
        await MainActor.run { NotificationCenter.default.post(name: Self.requested, object: nil) }
        return .result()
    }
}
