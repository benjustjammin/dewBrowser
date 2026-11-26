import SwiftUI

/// Tabs open on your other devices (from iCloud), grouped by device and space, with Open All.
struct RemoteTabsView: View {
    @Environment(BrowserStore.self) private var store
    var query = ""
    var limitPerSpace = 6
    var onOpen: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.cloudSync.remoteDevices) { device in
                HStack(spacing: 6) {
                    Image(systemName: device.symbol).font(.caption)
                    Text(device.name).font(.caption.weight(.semibold))
                    Text(device.updated.formatted(.relative(presentation: .named)))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                ForEach(device.spaces, id: \.name) { space in
                    let tabs = space.tabs.filter(matches)
                    if !tabs.isEmpty {
                        if device.spaces.count > 1 {
                            Text(space.name)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color(hex: space.colorHex))
                                .padding(.horizontal, 8)
                                .padding(.top, 2)
                        }
                        ForEach(Array(tabs.prefix(limitPerSpace)), id: \.self) { tab in
                            RemoteTabRow(tab: tab) {
                                store.openRemote(tab, fromSpace: space.name)
                                onOpen()
                            }
                        }
                        if query.isEmpty && space.tabs.count > 1 {
                            Button {
                                store.openAll(space)
                                onOpen()
                            } label: {
                                Label("Open All \(space.tabs.count)", systemImage: "square.and.arrow.down.on.square")
                                    .font(.callout)
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
    }

    private func matches(_ tab: DeviceSession.SyncedTab) -> Bool {
        query.isEmpty || tab.title.localizedCaseInsensitiveContains(query)
            || tab.url.absoluteString.localizedCaseInsensitiveContains(query)
    }
}

private struct RemoteTabRow: View {
    let tab: DeviceSession.SyncedTab
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                FaviconView(url: tab.faviconURL, page: tab.url, size: 16)
                Text(tab.title).lineLimit(1)
                Spacer(minLength: 8)
                Text(URLInput.displayHost(tab.url) ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(isHovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
    }
}

/// Offers the current page to your other devices (Handoff) and opens pages handed off to this one.
struct HandoffModifier: ViewModifier {
    let store: BrowserStore

    func body(content: Content) -> some View {
        content
            .userActivity(BrowserStore.handoffActivityType, element: store.handoffURL) { url, activity in
                activity.title = store.selectedTab?.displayTitle
                activity.webpageURL = url
                activity.isEligibleForHandoff = true
            }
            .onContinueUserActivity(BrowserStore.handoffActivityType) { open($0) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { open($0) }
    }

    private func open(_ activity: NSUserActivity) {
        guard let url = activity.webpageURL, url.scheme?.hasPrefix("http") == true else { return }
        store.newTab(url: url)
    }
}
