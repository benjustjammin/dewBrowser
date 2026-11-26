import AppIntents
import SwiftUI
import WidgetKit

/// Where Dew keeps its Light / Dark / Auto choice, shared between the app and this widget.
private let sharedDefaults = UserDefaults(suiteName: "group.com.automate.dew")

/// The widget's Light / Dark / Auto buttons: saves the choice for Dew, which applies it when it next opens
/// or comes to the front.
struct SetAppearanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Dew's Appearance"
    static let description = IntentDescription("Switch Dew between light, dark and following the system.")

    @Parameter(title: "Appearance") var mode: String

    init() {}
    init(mode: String) { self.mode = mode }

    func perform() async throws -> some IntentResult {
        sharedDefaults?.set(mode, forKey: "appearanceMode")
        return .result()
    }
}

/// "Search" widget: opens Dew in a new tab with the search box ready (`dew://search`). Which space it opens in is
/// set in Dew (Settings → General → Search widget). It follows the home screen's light, dark and tinted looks.
@main
struct DewWidgetBundle: WidgetBundle {
    var body: some Widget {
        DewSearchWidget()
    }
}

struct DewSearchWidget: Widget {
    static let searchURL = URL(string: "dew://search")!

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DewSearch", provider: Provider()) { entry in
            DewSearchWidgetView(appearance: entry.appearance)
                .widgetURL(Self.searchURL)
        }
        .configurationDisplayName("Search")
        .description("Jump straight to searching in Dew, and switch it between light, dark and auto.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

/// One entry: the current appearance choice. It's redrawn when a button is tapped or Dew changes it.
struct Provider: TimelineProvider {
    struct Entry: TimelineEntry {
        let date: Date
        let appearance: String
    }
    private func current() -> Entry { Entry(date: .now, appearance: sharedDefaults?.string(forKey: "appearanceMode") ?? "system") }
    func placeholder(in context: Context) -> Entry { Entry(date: .now, appearance: "system") }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(current()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }
}

struct DewSearchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    /// Dew's current choice: "light", "dark" or "system".
    let appearance: String

    var body: some View {
        switch family {
        case .accessoryCircular:
            // Lock Screen: a round search button.
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold))
            }
            .widgetAccentable()
            .containerBackground(for: .widget) { Color.clear }
            .accessibilityLabel("Search in Dew")
        default:
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    // Light / Dark / Auto for Dew; the current one is filled in.
                    HStack(spacing: 6) {
                        modeButton("light", symbol: "sun.max.fill", label: "Light")
                        modeButton("dark", symbol: "moon.fill", label: "Dark")
                        modeButton("system", symbol: "circle.lefthalf.filled", label: "Auto")
                    }
                    Spacer(minLength: 4)
                    mark
                }
                Spacer(minLength: 0)
                // The search capsule, like the address bar.
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                    Text("Search").font(.system(size: 19, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Capsule().fill(.background))
                .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                .widgetAccentable()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Search in Dew")
            }
            .containerBackground(for: .widget) { Color(uiColor: .secondarySystemBackground) }
        }
    }

    /// A round Light / Dark / Auto button; tapping it switches Dew without opening it.
    private func modeButton(_ mode: String, symbol: String, label: String) -> some View {
        let selected = appearance == mode
        return Button(intent: SetAppearanceIntent(mode: mode)) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
                .background(Circle().fill(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.background)))
        }
        .buttonStyle(.plain)
        .widgetAccentable(selected)
        .accessibilityLabel("\(label) appearance")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Dew's drop in full colour; a plain drop when the home screen is tinted or clear.
    @ViewBuilder private var mark: some View {
        if renderingMode == .fullColor {
            DewMark(size: 22).frame(height: 40, alignment: .top)
        } else {
            DropShape().fill(.primary).frame(width: 20, height: 26).widgetAccentable()
        }
    }
}

#Preview(as: .systemSmall) {
    DewSearchWidget()
} timeline: {
    Provider.Entry(date: .now, appearance: "dark")
}
