import SwiftUI

/// "Soft" completion as you type a site's name, like Safari's: "git" becomes "git|hub.com" with the added part
/// selected, so typing carries on over it, Delete removes it and Return goes there. Call `update` from
/// `onChange(of: text)` and `reset` whenever the text is set some other way.
struct InlineCompletion {
    /// What the user has typed, without any completion.
    private var typed = ""
    /// The text as last set here (so the change it causes isn't taken for typing).
    private var shown = ""

    mutating func reset(to text: String) {
        typed = text
        shown = text
    }

    @MainActor mutating func update(_ text: inout String, _ selection: inout TextSelection?, store: BrowserStore) {
        guard text != shown else { return }
        // Typing on at the end, or a first letter over the whole (selected) address; never while deleting.
        let deleting = typed.hasPrefix(text)
        let typedOn = !deleting && (text.hasPrefix(typed) || text.count == 1)
        reset(to: text)
        guard typedOn, let site = store.addressCompletion(for: text) else { return }
        let completed = text + site.dropFirst(text.count)
        let start = completed.index(completed.startIndex, offsetBy: text.count)
        shown = completed
        text = completed
        selection = TextSelection(range: start..<completed.endIndex)
    }
}
