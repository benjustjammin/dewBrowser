import AppIntents
import SwiftUI
import WidgetKit

/// "Search" widget, small or wide: its search capsule opens Dew in a new tab with the search box ready (`dew://search`),
/// and the rest of it just opens Dew. Which space the search opens in is set in Dew (Settings → General → Search widget); its drop matches the app icon chosen in Dew. Its own
/// look is a widget setting: touch and hold the widget, Edit Widget → Appearance (Automatic follows the Home Screen;
/// Light or Dark keeps it that way).
@main
struct DewWidgetBundle: WidgetBundle {
    var body: some Widget {
        DewSearchWidget()
    }
}

/// The widget's look, chosen in Edit Widget.
enum WidgetAppearance: String, AppEnum {
    case automatic, light, dark

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Appearance"
    static let caseDisplayRepresentations: [WidgetAppearance: DisplayRepresentation] = [
        .automatic: "Automatic",
        .light: "Light",
        .dark: "Dark",
    ]
}

/// Edit Widget options.
struct SearchWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Search"
    static let description = IntentDescription("Choose how the widget looks.")

    @Parameter(title: "Appearance", default: .automatic)
    var appearance: WidgetAppearance
}

struct DewSearchWidget: Widget {
    static let searchURL = URL(string: "dew://search")!

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DewSearch", intent: SearchWidgetConfiguration.self, provider: Provider()) { entry in
            DewSearchWidgetView(appearance: entry.appearance, style: entry.style)
        }
        .configurationDisplayName("Search")
        .description("Jump straight to searching in Dew.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

/// One entry with the chosen look; it changes when the widget is edited or the app icon is (Dew reloads it then).
struct Provider: AppIntentTimelineProvider {
    struct Entry: TimelineEntry {
        let date: Date
        let appearance: WidgetAppearance
        var style = Provider.appIconStyle
    }

    /// The app icon chosen in Dew, shared through the App Group.
    static var appIconStyle: DewMark.Style {
        DewMark.Style(appIcon: UserDefaults(suiteName: "group.com.automate.dew")?.string(forKey: "appIcon") ?? "")
    }

    func placeholder(in context: Context) -> Entry { Entry(date: .now, appearance: .automatic) }
    func snapshot(for configuration: SearchWidgetConfiguration, in context: Context) async -> Entry {
        Entry(date: .now, appearance: configuration.appearance)
    }
    func timeline(for configuration: SearchWidgetConfiguration, in context: Context) async -> Timeline<Entry> {
        Timeline(entries: [Entry(date: .now, appearance: configuration.appearance)], policy: .never)
    }
}

struct DewSearchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var systemScheme
    let appearance: WidgetAppearance
    let style: DewMark.Style

    /// Light or Dark from Edit Widget, otherwise the Home Screen's.
    private var scheme: ColorScheme {
        switch appearance {
        case .automatic: systemScheme
        case .light: .light
        case .dark: .dark
        }
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            // Lock Screen: a round search button (the Lock Screen sets its own look).
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold))
            }
            .widgetAccentable()
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(DewSearchWidget.searchURL)
            .accessibilityLabel("Search in Dew")
        default:
            let dark = scheme == .dark, wide = family == .systemMedium
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    mark
                }
                Spacer(minLength: 0)
                // The search capsule, like the address bar: it alone opens search (the rest just opens Dew).
                Button(intent: OpenURLIntent(DewSearchWidget.searchURL)) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                        Text(wide ? "Search or enter address" : "Search")
                            .font(.system(size: 15))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(dark ? Color(white: 0.62) : Color(white: 0.45))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Capsule().fill(dark ? Color(white: 0.24) : Color.white))
                    .shadow(color: .black.opacity(dark ? 0.3 : 0.1), radius: 6, y: 2)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .widgetAccentable()
                .accessibilityLabel("Search in Dew")
            }
            .environment(\.colorScheme, scheme)
            .containerBackground(for: .widget) { dark ? Color(white: 0.12) : Color(white: 0.95) }
        }
    }

    /// Dew's drop as on the app icon, in full colour; a plain drop when the Home Screen is tinted or clear.
    @ViewBuilder private var mark: some View {
        if renderingMode == .fullColor {
            DewMark(size: 22, style: style).frame(height: 42, alignment: .top)
        } else {
            DropShape().fill(.primary).frame(width: 20, height: 26).widgetAccentable()
        }
    }
}

#Preview(as: .systemSmall) {
    DewSearchWidget()
} timeline: {
    Provider.Entry(date: .now, appearance: .light)
    Provider.Entry(date: .now, appearance: .dark, style: .halo)
}

#Preview(as: .systemMedium) {
    DewSearchWidget()
} timeline: {
    Provider.Entry(date: .now, appearance: .light, style: .bead)
    Provider.Entry(date: .now, appearance: .dark, style: .halo)
}
