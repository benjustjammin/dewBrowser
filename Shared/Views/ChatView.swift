import SwiftUI

/// Dia-style Chat: ask about the current page and any other tabs you add.
struct ChatPanelView: View {
    @Environment(BrowserStore.self) private var store
    @FocusState private var composerFocused: Bool

    var body: some View {
        let chat = store.chat
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if !chat.isReady {
                ChatSetupView()
            } else {
                transcript
                composer
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            store.open(url, inNewTab: true)
            return .handled
        })
        .onAppear {
            store.chat.refreshKeys()
            #if os(macOS)
            composerFocused = true   // on iOS that would raise the keyboard over the conversation straight away
            #endif
            // Debug: `-DewChatAttachTabs YES` shares the space's first few tabs (for checking the card stack).
            if UserDefaults.standard.bool(forKey: "DewChatAttachTabs") {
                store.orderedTabs.filter { $0.url != nil }.prefix(6).forEach { store.chat.attach($0) }
            }
        }
        .modifier(ChatGPTWelcome())
    }

    #if os(macOS)
    /// A roomy box from the start (3 lines), growing to 10.
    private static let composerLines: ClosedRange<Int> = 3...10
    #else
    /// One line to start on a phone (the keyboard already takes half the screen), growing to 6.
    private static let composerLines: ClosedRange<Int> = 1...6
    #endif

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(store.currentSpace.color)
            Text("Chat").font(.headline)
            Spacer()
            ChatModelMenu()
            iconButton("square.and.pencil", help: "New chat") { store.chat.newConversation() }
                .disabled(store.chat.messages.isEmpty)
            iconButton("xmark", help: "Close chat") { store.isChatOpen = false }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        #if os(iOS)
        .padding(.horizontal, 16)
        .frame(height: 48)
        .padding(.top, 12)   // clear of the sheet's grab handle
        #else
        .padding(.horizontal, 12)
        .frame(height: 40)
        #endif
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .help(help)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.chat.messages.isEmpty {
                        ChatSuggestions { store.chat.send($0) }
                    }
                    ForEach(store.chat.messages) { message in
                        ChatMessageView(message: message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: store.chat.messages.last?.answerText) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.chat.messages.last?.parts.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.chat.messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    // MARK: Composer

    private var composer: some View {
        @Bindable var chat = store.chat
        let tabs = chat.contextTabs
        let canSend = !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            // Dia-style composer: shared tabs as cards on top, the question and buttons underneath.
            VStack(alignment: .leading, spacing: 6) {
                if !tabs.isEmpty {
                    TabCardStack(tabs: tabs) { chat.detach($0) }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField(tabs.isEmpty ? "Ask anything…" : "Ask anything, or about \(tabs.count == 1 ? "this page" : "these tabs")…",
                              text: $chat.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineLimit(Self.composerLines)
                        .focused($composerFocused)
                        .onSubmit { chat.send() }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    AddTabMenu()
                        .padding(.bottom, 1)
                    if chat.isResponding {
                        Button { chat.stop() } label: {
                            Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(store.currentSpace.color))
                        }
                        .buttonStyle(.plain)
                        .help("Stop")
                    } else {
                        Button { chat.send() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(canSend ? AnyShapeStyle(store.currentSpace.color) : AnyShapeStyle(Color.secondary.opacity(0.35))))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (Return)")
                    }
                }
                .padding(.leading, 4)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.7)))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            if chat.provider == .chatGPT {
                HStack(spacing: 4) {
                    Text("Using ChatGPT plan")
                    Text("·")
                    Button("Manage usage") { store.open(ChatGPTAccount.manageUsageURL, inNewTab: true) }
                        .buttonStyle(.borderless)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            }
        }
        .padding(10)
    }
}

/// Shared tabs as overlapping cards, like Dia. Within a row each card tucks under the one to its left; when a
/// row is full the next row starts just below, overlapping it slightly and nudged right, so the cards read as
/// a stack. The order never changes and every icon, title and ✕ stays visible. Hovering lifts a card;
/// clicking it switches to the tab. Past three rows, the stack scrolls.
private struct TabCardStack: View {
    @Environment(BrowserStore.self) private var store
    let tabs: [BrowserTab]
    let onRemove: (BrowserTab) -> Void
    @State private var hovered: UUID?
    @State private var width: CGFloat = 320

    static let cardWidth: CGFloat = 150
    static let cardHeight: CGFloat = 46
    /// How much a card tucks under the one to its left (its leading padding grows by the same amount).
    static let overlap: CGFloat = 22
    /// How much a row tucks under the row above (just the cards' bottom padding).
    private static let rowOverlap: CGFloat = 9
    /// Each row starts a little further right than the one above.
    private static let rowStagger: CGFloat = 10
    /// Room above and to the right for the ✕ on each card's top-right corner.
    private static let inset: CGFloat = 7
    private static let maxVisibleRows = 3

    var body: some View {
        let rows = Self.rows(tabs, width: width)
        let rowHeight = Self.cardHeight - Self.rowOverlap
        let contentHeight = Self.inset + Self.cardHeight + CGFloat(rows.count - 1) * rowHeight + 3
        let visibleHeight = Self.inset + Self.cardHeight + CGFloat(min(rows.count, Self.maxVisibleRows) - 1) * rowHeight + 3
        ScrollView(.vertical, showsIndicators: rows.count > Self.maxVisibleRows) {
            VStack(alignment: .leading, spacing: -Self.rowOverlap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: -Self.overlap) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { index, tab in
                            TabCard(tab: tab, isTucked: index > 0, isHovered: hovered == tab.id) { onRemove(tab) }
                                .zIndex(Double(row.count - index))
                                .onHover { inside in
                                    if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
                                }
                                .onTapGesture { store.select(tab) }
                                .help(tab.url?.absoluteString ?? tab.displayTitle)
                                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
                        }
                    }
                    .padding(.leading, CGFloat(rowIndex) * Self.rowStagger)
                    .zIndex(Double(rowIndex))   // lower rows on top, so their ✕ buttons aren't covered
                }
            }
            .padding(.top, Self.inset)
            .padding(.trailing, Self.inset)
            .padding(.bottom, 3)   // room for the shadow
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: contentHeight, alignment: .top)
        }
        .frame(height: visibleHeight)
        .scrollDisabled(rows.count <= Self.maxVisibleRows)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(.spring(duration: 0.3, bounce: 0.15), value: tabs.map(\.id))
        .animation(.spring(duration: 0.3, bounce: 0.15), value: rows.count)
    }

    /// Splits the cards into rows that fit the width (allowing for each row's stagger).
    private static func rows(_ tabs: [BrowserTab], width: CGFloat) -> [[BrowserTab]] {
        var rows: [[BrowserTab]] = []
        var remaining = tabs[...]
        while !remaining.isEmpty {
            let available = width - inset - CGFloat(rows.count) * rowStagger
            let fit = max(1, Int((available - cardWidth) / (cardWidth - overlap)) + 1)
            rows.append(Array(remaining.prefix(fit)))
            remaining = remaining.dropFirst(fit)
        }
        return rows
    }
}

/// One shared tab: favicon on a white tile, title, and site, in a rounded box.
private struct TabCard: View {
    let tab: BrowserTab
    /// Tucked under the card to its left: its content starts further in.
    let isTucked: Bool
    let isHovered: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FaviconView(url: tab.faviconURL, page: tab.url, size: 16)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator.opacity(0.5)))
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(URLInput.displayHost(tab.url) ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8 + (isTucked ? TabCardStack.overlap : 0))   // the left edge tucks under the previous card
        .padding(.trailing, 8)
        .frame(width: TabCardStack.cardWidth, height: TabCardStack.cardHeight, alignment: .leading)
        .background {
            // Opaque, so overlapped cards don't show through each other.
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.background)
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.primary.opacity(0.055))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(isHovered ? 0.14 : 0.08), radius: isHovered ? 4 : 2, x: 1.5, y: isHovered ? 2 : 1)
        .offset(y: isHovered ? -1.5 : 0)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        // Before the ✕ is added: the ✕ sits on the rounded corner, outside this shape, and must stay clickable.
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(.background))
                    .overlay(Circle().strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.1), radius: 1.5, y: 0.5)
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .help("Don't share this tab")
        }
    }
}

/// "+" menu: add any open tab (from any space) to the conversation.
private struct AddTabMenu: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let shared = Set(store.chat.contextTabs.map(\.id))
        let spaces = store.isPrivate ? [BrowserStore.privateSpace] : store.spaces
        Menu {
            if !store.chat.includeCurrentTab, let tab = store.selectedTab, !store.isBlank(tab) {
                Button("Current Tab") { store.chat.includeCurrentTab = true }
                Divider()
            }
            ForEach(spaces) { space in
                let tabs = store.orderedTabs(in: space.id).filter { $0.url != nil && !shared.contains($0.id) }
                if !tabs.isEmpty {
                    Section(space.name) {
                        ForEach(tabs) { tab in
                            Button(tab.displayTitle) { store.chat.attach(tab) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Share another tab with the chat")
    }
}

private struct ChatMessageView: View {
    @Environment(BrowserStore.self) private var store
    let message: ChatSession.Message
    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBubble
        }
    }

    /// Your message: a bubble in the space's colour, on the right.
    private var userBubble: some View {
        let space = store.currentSpace
        return VStack(alignment: .trailing, spacing: 4) {
            Text(message.text)
                .font(.system(size: 14))
                .lineSpacing(2)
                .foregroundStyle(space.prefersDarkText ? Color.black.opacity(0.85) : .white)
                .tint(space.prefersDarkText ? .black : .white)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 5,
                                                   topTrailingRadius: 18, style: .continuous).fill(space.color.gradient))
            if !message.sources.isEmpty {
                HStack(spacing: 4) {
                    ForEach(message.sources) { source in
                        FaviconView(url: source.faviconURL, page: source.url, size: 12)
                            .help(source.title + (source.truncated ? " (page was very long; only the start was shared)" : ""))
                    }
                    Text(message.sources.count == 1 ? message.sources[0].title : "\(message.sources.count) tabs")
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 36)
    }

    /// The answer: a soft bubble on the left holding formatted text and any actions, in order.
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(message.parts) { part in
                    switch part {
                    case .text(_, let text):
                        if !text.isEmpty { MarkdownView(text: text) }
                    case .action(let action):
                        ChatActionRow(action: action, messageID: message.id)
                    }
                }
                if message.isThinking && message.isStreaming {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(message.parts.contains { if case .action = $0 { true } else { false } } ? "Working…" : "Thinking…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    if message.offersManageUsage {
                        Link("Manage usage", destination: ChatGPTAccount.manageUsageURL).font(.callout)
                    }
                }
                if let note = message.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 18, bottomTrailingRadius: 18,
                                               topTrailingRadius: 18, style: .continuous).fill(.primary.opacity(0.055)))
            // Copy the whole answer (on hover on the Mac; always on iOS).
            if !message.isStreaming && !message.answerText.isEmpty {
                Button {
                    copyToClipboard(message.answerText)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .opacity(Self.alwaysShowsCopy || isHovering || copied ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 20)
        .onHover { isHovering = $0 }
    }

    #if os(macOS)
    private static let alwaysShowsCopy = false
    #else
    private static let alwaysShowsCopy = true
    #endif
}

/// Something Chat did ("Closed 3 tabs"), with Undo for closes; click to show the tab it's about.
private struct ChatActionRow: View {
    @Environment(BrowserStore.self) private var store
    let action: ChatAction
    let messageID: UUID
    @State private var isHovering = false

    var body: some View {
        let tab = action.tabID.flatMap { id in store.tabs.first { $0.id == id } }
        HStack(spacing: 8) {
            Image(systemName: action.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(store.currentSpace.color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(store.currentSpace.color.opacity(0.13)))
            Text(action.text)
                .font(.callout)
                .lineLimit(2)
                .strikethrough(action.undone)
                .foregroundStyle(action.undone ? .secondary : .primary)
            Spacer(minLength: 4)
            if !action.closedRecords.isEmpty {
                if action.undone {
                    Text("Undone").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Undo") { store.chat.undo(action, in: messageID) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.primary.opacity(0.07)))
                }
            } else if tab != nil {
                Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(isHovering && tab != nil ? 0.06 : 0.035)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if let tab { store.select(tab) } }
        .help(tab.map { "Show “\($0.displayTitle)”" } ?? "")
    }
}

/// Starting points: about the page (sent straight away) and general ones (put in the box to finish).
private struct ChatSuggestions: View {
    @Environment(BrowserStore.self) private var store
    let onPick: (String) -> Void

    var body: some View {
        let chat = store.chat
        let hasPage = !chat.contextTabs.isEmpty
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How can I help?").font(.title3.weight(.semibold))
                Text(hasPage ? "Ask anything — about this page, your other tabs, or something else entirely."
                             : "Ask anything, or add tabs with + to ask about them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if hasPage {
                section("This page", ["Summarise this page", "What are the key points?", "Explain this simply"]) { onPick($0) }
            }
            section("Anything else", ["Help me write ", "Explain ", "Give me ideas for "]) { chat.draft = $0 }
            if chat.allowsActions {
                section("Your tabs", ["Summarise all my open tabs", "Close duplicate tabs"]) { onPick($0) }
            }
        }
        .padding(.top, 6)
    }

    private func section(_ title: String, _ items: [String], action: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            ForEach(items, id: \.self) { item in
                Button { action(item) } label: {
                    HStack(spacing: 6) {
                        Text(item.trimmingCharacters(in: .whitespaces) + (item.hasSuffix(" ") ? "…" : ""))
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.045)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Model and depth switcher in the panel's header.
private struct ChatModelMenu: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var chat = store.chat
        Menu {
            Picker("Provider", selection: $chat.provider) {
                ForEach(ChatProvider.allCases) { Text($0.title).tag($0) }
            }
            switch chat.provider {
            case .anthropic:
                Picker("Model", selection: $chat.model) {
                    ForEach(ChatModel.allCases) { Text($0.title).tag($0) }
                }
                Picker("Depth", selection: $chat.depth) {
                    ForEach(ChatDepth.allCases) { Text($0.title).tag($0) }
                }
            case .chatGPT:
                if !chat.chatGPTModels.isEmpty {
                    Picker("Model", selection: $chat.chatGPTModel) {
                        ForEach(chat.chatGPTModels) { Text($0.name).tag($0.id) }
                    }
                }
            case .compatible:
                if !chat.compatibleModels.isEmpty {
                    Picker("Model", selection: $chat.compatibleModel) {
                        ForEach(chat.compatibleModels) { Text($0.name).tag($0.id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(chat.modelLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the model")
        .task(id: chat.provider) { await chat.refreshModels() }
    }
}

/// Shown in the panel until the chosen provider is set up.
private struct ChatSetupView: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let chat = store.chat
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(store.currentSpace.color.gradient))
                    .padding(.top, 28)
                Text("Set up Chat").font(.title3.weight(.semibold))
                Text("Ask about your tabs, get help with writing and questions, and let Chat open and tidy tabs for you. Choose who answers: Claude with an Anthropic API key, your ChatGPT plan, or another service such as OpenRouter or a model on this device.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if chat.provider == .chatGPT && !chat.chatGPT.isSignedIn {
                    ContinueWithChatGPTButton()
                }
                #if os(macOS)
                Button("Open AI Chat Settings…") { store.openSettingsTab?("ai") }
                    .controlSize(.large)
                #else
                NavigationLink {
                    AISettingsView().navigationTitle("AI Chat").navigationBarTitleDisplayMode(.inline)
                } label: {
                    Text("Set Up AI Chat").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(store.currentSpace.color)
                .controlSize(.large)
                #endif
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
    }
}

/// OpenAI's wording for starting sign-in: "Continue with ChatGPT".
struct ContinueWithChatGPTButton: View {
    @Environment(BrowserStore.self) private var store
    var reconsent = false

    var body: some View {
        let account = store.chat.chatGPT
        Button {
            Task {
                await account.signIn(reconsent: reconsent)
                await store.chat.refreshModels()
            }
        } label: {
            HStack(spacing: 6) {
                if account.isSigningIn { ProgressView().controlSize(.small).tint(.white) }
                Text(reconsent ? "Use your ChatGPT plan" : "Continue with ChatGPT")
            }
            #if os(iOS)
            .frame(maxWidth: .infinity)
            #endif
        }
        .buttonStyle(.borderedProminent)
        .tint(.black)
        .controlSize(.large)
        .disabled(account.isSigningIn)
    }
}

/// "You're using your ChatGPT plan", shown once after the first sign-in that enables plan use.
private struct ChatGPTWelcome: ViewModifier {
    @Environment(BrowserStore.self) private var store

    func body(content: Content) -> some View {
        let account = store.chat.chatGPT
        content.alert("You're using your ChatGPT plan", isPresented: Bindable(account).showsWelcome) {
            Button("Got it") {}
            Button("Manage usage") { store.open(ChatGPTAccount.manageUsageURL, inNewTab: true) }
        } message: {
            Text("Questions you ask in Dew's Chat now count towards your ChatGPT plan's usage. You can see and limit it in ChatGPT → Settings → Usage.")
        }
    }
}

/// API key rows: a field to paste and save the key, or (once saved) its status and a way to remove it.
/// On the Mac it's one labelled row; on iOS, full-width rows that suit a phone.
private struct APIKeyRows: View {
    let hasKey: Bool
    let placeholder: String
    let onSave: (String) -> Void
    let onRemove: () -> Void
    @State private var key = ""

    var body: some View {
        let canSave = !key.trimmingCharacters(in: .whitespaces).isEmpty
        #if os(macOS)
        LabeledContent("API key") {
            if hasKey {
                HStack {
                    Label("Saved in iCloud Keychain", systemImage: "checkmark.icloud.fill").foregroundStyle(.green)
                    Button("Remove", role: .destructive, action: onRemove)
                }
            } else {
                HStack {
                    SecureField(placeholder, text: $key).textFieldStyle(.roundedBorder).onSubmit(save)
                    Button("Save", action: save).disabled(!canSave)
                }
                .frame(maxWidth: 320)
            }
        }
        #else
        if hasKey {
            LabeledContent("API key") {
                Label("Saved in iCloud Keychain", systemImage: "checkmark.icloud.fill").foregroundStyle(.green)
            }
            Button("Remove Key", role: .destructive, action: onRemove)
        } else {
            SecureField("Paste your API key (\(placeholder))", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(save)
            Button("Save Key", action: save).disabled(!canSave)
        }
        #endif
    }

    private func save() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(key)
        key = ""
    }
}

struct AISettingsView: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var chat = store.chat
        Form {
            Section {
                Picker("Provider", selection: $chat.provider) {
                    ForEach(ChatProvider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                #if os(iOS)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                #endif
            } footer: {
                Text(providerSummary(chat.provider)).font(.footnote).foregroundStyle(.secondary)
            }
            switch chat.provider {
            case .anthropic: AnthropicSection()
            case .chatGPT: ChatGPTSection()
            case .compatible: CompatibleSection()
            }
            Section {
                Toggle("Let Chat open, close and switch tabs", isOn: $chat.allowsActions)
            } header: {
                Text("Actions")
            } footer: {
                Text("Chat can also read your other tabs and search your history and bookmarks when you ask. Closing tabs can be undone from the chat.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("When you ask a question, the text of the tabs shown in the chat box (and anything you've selected on them) is sent to the provider you chose, with your question. Nothing is sent until you ask, and conversations aren't saved.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        .modifier(ChatGPTWelcome())
        .task(id: chat.provider) { await chat.refreshModels() }
        .onAppear { chat.refreshKeys() }
    }

    private func providerSummary(_ provider: ChatProvider) -> String {
        switch provider {
        case .anthropic: "Claude, with your own Anthropic API key. Billed per use by Anthropic."
        case .chatGPT: "Uses your ChatGPT Go, Plus, Pro or Business plan. Sign in with your ChatGPT account."
        case .compatible: "OpenRouter, the OpenAI API, or a model running on this device (Ollama, LM Studio)."
        }
    }
}

private struct AnthropicSection: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var chat = store.chat
        Section {
            APIKeyRows(hasKey: chat.hasAnthropicKey, placeholder: "sk-ant-…",
                       onSave: { chat.setAnthropicKey($0) }, onRemove: { chat.setAnthropicKey(nil) })
        } header: {
            Text("Anthropic")
        } footer: {
            Text("Create a key at console.anthropic.com → API Keys. It's saved in iCloud Keychain, so Dew on your other devices uses it too. Usage is billed to your Anthropic account, separately from a Claude subscription (Anthropic doesn't allow other apps to use Claude plans).")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            Picker("Model", selection: $chat.model) {
                ForEach(ChatModel.allCases) { model in
                    #if os(iOS)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title)
                        Text(model.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                    .tag(model)
                    #else
                    Text("\(model.title) — \(model.detail)").tag(model)
                    #endif
                }
            }
            #if os(iOS)
            .pickerStyle(.navigationLink)
            #endif
            Picker("Depth", selection: $chat.depth) {
                ForEach(ChatDepth.allCases) { Text($0.title).tag($0) }
            }
        } footer: {
            Text("Depth sets how much Claude thinks before answering: Quick is fastest and cheapest, Thorough is best for hard questions.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct ChatGPTSection: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var chat = store.chat
        let account = chat.chatGPT
        Section {
            if account.isSignedIn {
                LabeledContent("Account", value: account.email ?? "ChatGPT account")
                if account.planEnabled {
                    LabeledContent("ChatGPT plan") { Text("In use").foregroundStyle(.green) }
                    Button("Manage Usage") { store.open(ChatGPTAccount.manageUsageURL, inNewTab: true) }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Dew isn't allowed to use your ChatGPT plan yet.").font(.callout)
                        ContinueWithChatGPTButton(reconsent: true)
                    }
                    .padding(.vertical, 4)
                }
                Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sign in with your ChatGPT account to use your plan in Chat.").font(.callout)
                    ContinueWithChatGPTButton()
                }
                .padding(.vertical, 4)
            }
            if let error = account.lastError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("ChatGPT")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Questions count towards your ChatGPT plan, separately from anything else. You can set a weekly limit for Dew in ChatGPT → Settings → Usage. Free plans can sign in but can't use plan usage.")
                Link("Learn more", destination: ChatGPTAccount.learnMoreURL)
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        if account.isSignedIn && account.planEnabled {
            Section {
                ModelPicker(models: chat.chatGPTModels, selection: $chat.chatGPTModel, allowsCustom: false)
            }
        }
    }
}

private struct CompatibleSection: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var chat = store.chat
        Section {
            Picker("Service", selection: $chat.compatiblePreset) {
                ForEach(CompatiblePreset.allCases) { Text($0.title).tag($0) }
            }
            if chat.compatiblePreset == .custom {
                TextField("Server address", text: $chat.compatibleBaseURL, prompt: Text("https://…/v1"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
            } else {
                LabeledContent("Address") {
                    Text(chat.compatibleBaseURL).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            APIKeyRows(hasKey: chat.hasCompatibleKey, placeholder: chat.compatiblePreset.keyHint,
                       onSave: { key in
                           chat.setCompatibleKey(key)
                           Task { await chat.refreshModels() }
                       },
                       onRemove: { chat.setCompatibleKey(nil) })
        } header: {
            Text("Server")
        } footer: {
            Text("Keys are saved in iCloud Keychain and shared with Dew on your other devices. OpenRouter gives one key for Claude, GPT, Gemini, Llama and more, billed per use. Ollama and LM Studio run models on this device, so nothing leaves it; start their server first.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            ModelPicker(models: chat.compatibleModels, selection: $chat.compatibleModel, allowsCustom: true)
        } header: {
            Text("Model")
        }
        .onChange(of: chat.compatibleBaseURL) { Task { await chat.refreshModels() } }
    }
}

/// A model picker from the provider's list; with `allowsCustom`, also a field for typing any model ID.
private struct ModelPicker: View {
    @Environment(BrowserStore.self) private var store
    let models: [RemoteModel]
    @Binding var selection: String
    let allowsCustom: Bool

    var body: some View {
        if allowsCustom {
            TextField("Model ID", text: $selection, prompt: Text("e.g. anthropic/claude-sonnet-5.5"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
        if !models.isEmpty || !allowsCustom {
            Picker(allowsCustom ? "Choose from list" : "Model", selection: $selection) {
                if !models.contains(where: { $0.id == selection }) {
                    Text(selection.isEmpty ? (models.isEmpty ? "Loading…" : "None") : selection).tag(selection)
                }
                ForEach(models) { Text($0.name).tag($0.id) }
            }
            #if os(iOS)
            .pickerStyle(.navigationLink)
            #endif
        }
        Button("Reload Model List") { Task { await store.chat.refreshModels() } }
        if let error = store.chat.modelListError {
            Text(error).font(.footnote).foregroundStyle(.orange)
        }
    }
}
