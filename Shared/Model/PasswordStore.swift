import Foundation
import CryptoKit
import Security
import Observation
import WebKit

struct SavedLogin: Codable, Identifiable, Hashable {
    var id = UUID()
    var spaceID: UUID
    var host: String
    var username: String
    var password: String
    var created = Date()
    var lastUsed: Date?
}

/// A login the page just submitted, waiting for "Save password?".
struct PendingLogin: Identifiable, Equatable {
    let id = UUID()
    let tabID: UUID
    let spaceID: UUID
    let host: String
    let username: String
    let password: String
    let isUpdate: Bool
}

/// Saved passwords, per space. Stored as one AES-GCM encrypted file; the 256-bit key lives in the
/// Keychain, so the file is useless without this Mac's (or iPhone's) Keychain.
@MainActor @Observable
final class PasswordStore {
    private(set) var logins: [SavedLogin] = []
    /// True if a passwords file exists but couldn't be decrypted (e.g. Keychain access denied).
    /// Saving is refused in that state so the existing file is never overwritten.
    private(set) var isLocked = false

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var neverSave = Set(UserDefaults.standard.stringArray(forKey: "neverSavePasswords") ?? [])

    private static let service = "com.local.dew.passwords"
    private static var fileURL: URL {
        let directory = URL.applicationSupportDirectory.appending(path: "Dew", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "passwords.dat")
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        guard let key = encryptionKey(create: false),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key),
              let list = try? JSONDecoder().decode([SavedLogin].self, from: plain) else {
            isLocked = true
            return
        }
        logins = list
    }

    // MARK: Queries

    static func normalize(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    /// Logins for a site, like Dia/Chrome: anything on the same registrable domain (so my.control4.com
    /// and customer.control4.com both show on control4.com), exact host first, then most recently used.
    func logins(forHost host: String, in spaceID: UUID) -> [SavedLogin] {
        loadIfNeeded()
        let target = Self.normalize(host)
        let site = Self.site(of: target)
        return logins
            .filter { $0.spaceID == spaceID && Self.site(of: $0.host) == site }
            .sorted { a, b in
                let exactA = Self.normalize(a.host) == target, exactB = Self.normalize(b.host) == target
                if exactA != exactB { return exactA }
                return (a.lastUsed ?? a.created) > (b.lastUsed ?? b.created)
            }
    }

    private static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk", "nhs.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "co.jp", "ne.jp", "or.jp",
        "com.br", "com.cn", "com.mx", "co.in", "co.za", "com.sg", "com.hk", "co.kr", "com.tr", "com.ar",
    ]

    /// Approximate registrable domain ("eTLD+1"); IP addresses and single-label hosts are their own site.
    static func site(of host: String) -> String {
        let host = normalize(host)
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return multiPartSuffixes.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }

    /// Home-network and on-device addresses, where plain HTTP is normal (routers, NAS, Homebridge…).
    nonisolated static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") || host.hasPrefix("10.")
            || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") { return true }
        if host.hasPrefix("172."), let second = host.split(separator: ".").dropFirst().first.flatMap({ Int($0) }),
           (16...31).contains(second) { return true }
        return [".local", ".lan", ".home", ".home.arpa", ".internal", ".localdomain"].contains { host.hasSuffix($0) }
    }

    func isNeverSave(host: String, spaceID: UUID) -> Bool {
        neverSave.contains("\(spaceID)|\(Self.normalize(host))")
    }

    // MARK: Changes

    func save(host: String, username: String, password: String, spaceID: UUID) {
        loadIfNeeded()
        if let index = logins.firstIndex(where: { $0.spaceID == spaceID && Self.normalize($0.host) == Self.normalize(host) && $0.username == username }) {
            logins[index].password = password
            logins[index].lastUsed = .now
        } else {
            logins.append(SavedLogin(spaceID: spaceID, host: host, username: username, password: password))
        }
        persist()
    }

    func neverSave(host: String, spaceID: UUID) {
        neverSave.insert("\(spaceID)|\(Self.normalize(host))")
        UserDefaults.standard.set(Array(neverSave), forKey: "neverSavePasswords")
    }

    func delete(_ login: SavedLogin) {
        logins.removeAll { $0.id == login.id }
        persist()
    }

    func deleteAll(in spaceID: UUID) {
        logins.removeAll { $0.spaceID == spaceID }
        persist()
    }

    func markUsed(_ login: SavedLogin) {
        guard let index = logins.firstIndex(where: { $0.id == login.id }) else { return }
        logins[index].lastUsed = .now
        persist()
    }

    /// Imports a CSV exported by Dia/Chrome (name,url,username,password,note), Safari/Passwords
    /// (Title,URL,Username,Password,…), 1Password, Bitwarden and similar. Returns (added, updated).
    func importCSV(_ text: String, into spaceID: UUID) -> (added: Int, updated: Int) {
        loadIfNeeded()
        let rows = CSV.parse(text)
        guard let header = rows.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) else { return (0, 0) }
        func column(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let urlColumn = column(["url", "website", "login_uri", "login uri", "web site"]),
              let userColumn = column(["username", "login_username", "user name", "login", "email"]),
              let passwordColumn = column(["password", "login_password"]) else { return (0, 0) }

        var added = 0
        var updated = 0
        for row in rows.dropFirst() where row.count > max(urlColumn, userColumn, passwordColumn) {
            let password = row[passwordColumn]
            let urlString = row[urlColumn].trimmingCharacters(in: .whitespaces)
            guard !password.isEmpty,
                  let url = URL(string: urlString.contains("://") ? urlString : "https://" + urlString),
                  url.scheme?.hasPrefix("http") == true, let host = url.host, !host.isEmpty else { continue }
            let username = row[userColumn]
            if let index = logins.firstIndex(where: { $0.spaceID == spaceID && Self.normalize($0.host) == Self.normalize(host) && $0.username == username }) {
                if logins[index].password != password {
                    logins[index].password = password
                    updated += 1
                }
            } else {
                logins.append(SavedLogin(spaceID: spaceID, host: host, username: username, password: password))
                added += 1
            }
        }
        persist()
        return (added, updated)
    }

    // MARK: Storage

    private func persist() {
        guard !isLocked, let key = encryptionKey(create: true),
              let data = try? JSONEncoder().encode(logins),
              let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        try? sealed.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
    }

    private func encryptionKey(create: Bool) -> SymmetricKey? {
        if let key { return key }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "encryption-key",
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            key = SymmetricKey(data: data)
            return key
        }
        guard create else { return nil }
        let newKey = SymmetricKey(size: .bits256)
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "encryption-key",
            kSecAttrLabel as String: "Dew Passwords",
            kSecValueData as String: newKey.withUnsafeBytes { Data($0) },
        ]
        #if os(iOS)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        key = newKey
        return newKey
    }
}

/// Minimal RFC 4180 CSV parser (quoted fields, escaped quotes, newlines inside quotes).
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field); field = ""
                    if row != [""] { rows.append(row) }
                    row = []
                default: field.append(character)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Autofill

/// Finds login forms, fills saved logins, and reports submitted ones. Runs in an isolated JS world,
/// so page scripts can neither see these functions nor talk to the handler.
@MainActor
final class PasswordAutofillHandler: NSObject, WKScriptMessageHandler {
    static let name = "dewPasswords"
    private weak var store: BrowserStore?

    init(store: BrowserStore) { self.store = store }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let store, let webView = message.webView,
              let tab = store.tab(for: webView), let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let origin = message.frameInfo.securityOrigin
        let host = origin.host
        // HTTPS sites, plus local devices (router, NAS, Homebridge…) which are usually plain HTTP.
        guard !host.isEmpty, origin.protocol == "https" || PasswordStore.isLocal(host) else { return }

        switch type {
        case "request":
            // Give the page's suggestion dropdown the usernames (never passwords) for this site, and
            // fill straight away when there's exactly one login.
            let matches = store.passwords.logins(forHost: host, in: tab.spaceID)
            Task { await store.sendSuggestions(matches, to: tab, pageHost: host) }
            if matches.count == 1 && body["autofill"] as? Bool != false { Task { await store.fill(matches[0], in: tab) } }
        case "choose":
            // Picked from the dropdown: only fill a login that really belongs to this site and space.
            guard let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let login = store.passwords.logins(forHost: host, in: tab.spaceID).first(where: { $0.id == id }) else { return }
            Task { await store.fill(login, in: tab) }
        case "manage":
            store.showPasswordSettings()
        case "submit":
            // Private browsing doesn't offer to save passwords.
            guard !store.isPrivate(tab.spaceID), let password = body["password"] as? String, !password.isEmpty else { return }
            let username = body["username"] as? String ?? ""
            let existing = store.passwords.logins(forHost: host, in: tab.spaceID)
            if existing.contains(where: { $0.username == username && $0.password == password }) { return }
            if store.passwords.isNeverSave(host: host, spaceID: tab.spaceID) { return }
            store.pendingLogin = PendingLogin(tabID: tab.id, spaceID: tab.spaceID, host: host, username: username,
                                              password: password, isUpdate: existing.contains { $0.username == username })
        default:
            break
        }
    }

    static let script = """
    (() => {
      const handler = window.webkit.messageHandlers.\(name);
      const visible = (el) => el && !el.disabled && el.type !== 'hidden' && el.getClientRects().length > 0;
      const passwordFields = () => [...document.querySelectorAll('input[type=password]')].filter(visible);
      const usernameOnly = () => [...document.querySelectorAll('input[autocomplete~=username], input[type=email], input[name*=user i], input[id*=user i], input[name*=email i], input[name*=login i]')]
        .filter((el) => visible(el) && el.type !== 'password')[0] || null;
      const usernameFor = (pw) => {
        const scope = pw.form || document;
        const inputs = [...scope.querySelectorAll('input')]
          .filter((el) => visible(el) && ['text', 'email', 'tel', ''].includes(el.type));
        const before = inputs.filter((el) => el.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING);
        return before[before.length - 1] || usernameOnly();
      };
      const isLoginField = (el) => {
        if (!el || el.tagName !== 'INPUT' || !visible(el)) return false;
        if (el.type === 'password') return true;
        return passwordFields().some((pw) => usernameFor(pw) === el) || el === usernameOnly();
      };
      const setValue = (el, value) => {
        if (!el || value == null || value === '') return;
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        el.focus();
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };
      window.__dewFill = (username, password) => {
        hide();
        const pw = passwordFields()[0];
        setValue(pw ? usernameFor(pw) : usernameOnly(), username);
        setValue(pw, password);
      };

      // Suggestion dropdown under login fields. It lives in a closed shadow root so the page's CSS
      // can't restyle it, and only ever holds usernames; the password is sent only when one is picked.
      let logins = [], host = null, root = null, field = null, items = [], active = -1;
      window.__dewSetLogins = (list) => {
        logins = list || [];
        if (isLoginField(document.activeElement)) show(document.activeElement);
      };
      const hide = () => { if (host) host.style.display = 'none'; field = null; items = []; active = -1; };
      const build = () => {
        host = document.createElement('dew-suggestions');
        host.style.cssText = 'all:initial;position:fixed;z-index:2147483647;display:none;';
        root = host.attachShadow({ mode: 'closed' });
        document.documentElement.appendChild(host);
      };
      const globe = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="9.2"/><path d="M2.8 12h18.4M12 2.8c2.6 2.6 3.9 5.6 3.9 9.2s-1.3 6.6-3.9 9.2c-2.6-2.6-3.9-5.6-3.9-9.2S9.4 5.4 12 2.8z"/></svg>';
      const key = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="7.5" cy="12" r="4"/><path d="M11.5 12H21M17.5 12v3.2M20.5 12v2.4"/></svg>';
      const render = () => {
        const typed = field && field.type !== 'password' ? field.value.toLowerCase() : '';
        const matches = logins.filter((l) => !typed || l.username.toLowerCase().startsWith(typed) || l.username.toLowerCase() === typed);
        if (!field || !matches.length) { hide(); return; }
        if (!host) build();
        const rect = field.getBoundingClientRect();
        const dark = matchMedia('(prefers-color-scheme: dark)').matches;
        const bg = dark ? '#2c2c2e' : '#ffffff', fg = dark ? '#f2f2f7' : '#1d1d1f';
        const line = dark ? 'rgba(255,255,255,.12)' : 'rgba(0,0,0,.09)', hover = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.05)';
        root.innerHTML = `<style>
          .card { position: relative; font: 13px -apple-system, system-ui, sans-serif; color: ${fg};
                  width: ${Math.min(Math.max(rect.width, 400), 480)}px; background: ${bg}; border: 0.5px solid ${line};
                  border-radius: 12px; box-shadow: 0 10px 32px rgba(0,0,0,.2), 0 1px 3px rgba(0,0,0,.08); padding: 6px; box-sizing: border-box; }
          .arrow { position: absolute; top: -6px; left: 22px; width: 12px; height: 12px; background: ${bg};
                   border-left: 0.5px solid ${line}; border-top: 0.5px solid ${line}; transform: rotate(45deg); }
          .card.up .arrow { top: auto; bottom: -6px; transform: rotate(225deg); }
          .item { display: flex; align-items: flex-start; gap: 12px; padding: 8px 10px; border-radius: 8px; cursor: default; }
          .item.on, .item:hover { background: ${hover}; }
          .icon { width: 16px; padding-top: 1px; opacity: .8; flex: none; display: flex; }
          .text { min-width: 0; flex: 1; }
          .top { display: flex; align-items: baseline; gap: 10px; }
          .name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 0 1 auto; }
          .site { opacity: .6; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex: 0 100 auto; min-width: 60px; }
          .dots { letter-spacing: 1px; opacity: .55; font-size: 12px; margin-top: 3px; }
          .sep { height: 1px; background: ${line}; margin: 5px 4px; }
          .manage { display: flex; align-items: center; gap: 12px; padding: 9px 10px; border-radius: 8px; }
          .manage:hover { background: ${hover}; }
          .manage span { flex: 1; }
        </style><div class="card"><div class="arrow"></div><div class="list"></div><div class="sep"></div>
        <div class="manage"><div class="icon">${key}</div><span>Manage Passwords…</span></div></div>`;
        const card = root.querySelector('.card'), list = root.querySelector('.list');
        items = matches.map((login, index) => {
          const row = document.createElement('div');
          row.className = 'item' + (index === active ? ' on' : '');
          row.innerHTML = `<div class="icon">${globe}</div><div class="text"><div class="top"><span class="name"></span><span class="site"></span></div><div class="dots">••••••••</div></div>`;
          row.querySelector('.name').textContent = login.username || 'No username';
          row.querySelector('.site').textContent = login.site || '';
          // mousedown + preventDefault keeps focus in the field.
          row.addEventListener('mousedown', (e) => { e.preventDefault(); handler.postMessage({ type: 'choose', id: login.id }); });
          list.appendChild(row);
          return { row, login };
        });
        root.querySelector('.manage').addEventListener('mousedown', (e) => { e.preventDefault(); hide(); handler.postMessage({ type: 'manage' }); });
        host.style.display = 'block';
        const height = card.offsetHeight, width = card.offsetWidth;
        const fitsBelow = rect.bottom + 10 + height <= innerHeight;
        card.classList.toggle('up', !fitsBelow);
        host.style.top = (fitsBelow ? rect.bottom + 10 : Math.max(4, rect.top - height - 10)) + 'px';
        const left = Math.max(4, Math.min(rect.left + Math.min(rect.width, 120) - 28, innerWidth - width - 4));
        host.style.left = left + 'px';
        root.querySelector('.arrow').style.left = Math.max(10, Math.min(rect.left + 14 - left, width - 24)) + 'px';
      };
      const show = (el) => { if (!logins.length) return; field = el; active = -1; render(); };
      document.addEventListener('focusin', (e) => { if (isLoginField(e.target)) show(e.target); else hide(); }, true);
      document.addEventListener('focusout', () => setTimeout(() => { if (!isLoginField(document.activeElement)) hide(); }, 120), true);
      document.addEventListener('input', (e) => { if (e.target === field) { active = -1; render(); } }, true);
      document.addEventListener('keydown', (e) => {
        if (!field || !items.length || host.style.display === 'none') return;
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
          active = (active + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
          items.forEach((item, i) => item.row.classList.toggle('on', i === active));
          e.preventDefault();
        } else if (e.key === 'Enter' && active >= 0) {
          handler.postMessage({ type: 'choose', id: items[active].login.id });
          e.preventDefault();
          e.stopPropagation();
        } else if (e.key === 'Escape') {
          hide();
        }
      }, true);
      addEventListener('scroll', () => { if (field) render(); }, { passive: true, capture: true });
      addEventListener('resize', () => { if (field) render(); });

      // Ask for logins when a login form appears (also catches two-step sign-ins).
      let seenPasswordFields = 0, askedForUsername = false, timer = null;
      const check = () => {
        const count = passwordFields().length;
        if (count > seenPasswordFields) { seenPasswordFields = count; handler.postMessage({ type: 'request' }); }
        else if (!count && !askedForUsername && usernameOnly()) { askedForUsername = true; handler.postMessage({ type: 'request' }); }
      };
      const schedule = () => { clearTimeout(timer); timer = setTimeout(check, 250); };
      check();
      new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });

      // Offer to save on submit.
      let lastSent = '';
      const capture = () => {
        const pw = passwordFields().find((el) => el.value);
        if (!pw) return;
        const user = usernameFor(pw);
        const key = (user ? user.value : '') + '\\u0000' + pw.value;
        if (key === lastSent) return;
        lastSent = key;
        handler.postMessage({ type: 'submit', username: user ? user.value : '', password: pw.value });
      };
      document.addEventListener('submit', capture, true);
      document.addEventListener('click', (e) => { if (e.target.closest && e.target.closest('button, input[type=submit]')) capture(); }, true);
      document.addEventListener('keydown', (e) => { if (e.key === 'Enter' && e.target.type === 'password') capture(); }, true);
    })();
    """
}
