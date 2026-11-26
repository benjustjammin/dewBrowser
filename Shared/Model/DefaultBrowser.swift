import SwiftUI
import Observation

/// Whether Dew is the default web browser, and a way to make it so.
/// Mac: asks macOS directly (with its confirmation dialog). iOS: only you can change it in Settings, and
/// Dew appears there once Apple grants the default-browser entitlement; iOS 18.2+ can tell us the status.
@MainActor @Observable
final class DefaultBrowser {
    /// nil = unknown (older iOS, or iOS declined to say right now).
    private(set) var isDefault: Bool?

    func refresh() {
        #if os(macOS)
        let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        isDefault = current.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
        #else
        if #available(iOS 18.2, *) {
            isDefault = try? UIApplication.shared.isDefault(.webBrowser)
        }
        #endif
    }

    func makeDefault() {
        #if os(macOS)
        Task {
            for scheme in ["http", "https"] {
                try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
            }
            refresh()
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}
