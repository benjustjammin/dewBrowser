import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "Sign in with ChatGPT": lets Chat use your ChatGPT plan, following OpenAI's flow for open-source and
/// local apps (developers.openai.com/siwc/token-sharing-open-source). OAuth with PKCE, no client secret:
/// the first sign-in registers Dew dynamically and OpenAI issues a client ID that's reused afterwards.
/// The sign-in page opens in the system's web authentication sheet, and the reply comes back to a
/// one-off server on 127.0.0.1 (OpenAI requires a loopback redirect).
@MainActor @Observable
final class ChatGPTAccount {
    /// A constant, so safe to read from any thread (the request builders aren't on the main actor).
    nonisolated static let apiBase = URL(string: "https://api.openai.com/v1")!
    private static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    private static let resource = "https://api.openai.com/v1"
    private static let planScope = "chatgpt.tokens.use.direct"
    /// Whether to send `ext_agent_host_id` (documented as required, but OpenAI's reference devkit leaves it off
    /// unless the authorization deployment supports it).
    private static let sendsHostID = UserDefaults.standard.bool(forKey: "ChatGPTSendHostID")
    private static let scopes = "openid profile email offline_access resource.invoke \(planScope)"
    /// Usage limits live in ChatGPT → Settings → Usage.
    static let manageUsageURL = URL(string: "https://chatgpt.com/#settings")!
    static let learnMoreURL = URL(string: "https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites")!

    struct Credentials: Codable {
        var clientID: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var scopes: [String]
        var email: String?
        var idToken: String?
    }

    private(set) var isSignedIn = false
    private(set) var email: String?
    /// The user allowed Dew to use their plan (the `chatgpt.tokens.use.direct` scope was granted).
    private(set) var planEnabled = false
    private(set) var isSigningIn = false
    var lastError: String?
    /// Shown once, after the first sign-in that enables plan use ("You're using your ChatGPT plan").
    var showsWelcome = false

    @ObservationIgnored private var credentials: Credentials?
    @ObservationIgnored private var refreshTask: Task<Credentials, Error>?
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private let presenter = AuthPresenter()

    /// Identifies this device to OpenAI ("distinct for each host"); chosen once and kept.
    private var hostID: String {
        if let id = UserDefaults.standard.string(forKey: "chatGPTHostID") { return id }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(id, forKey: "chatGPTHostID")
        return id
    }

    /// The client ID OpenAI issued on first registration; reused for every later sign-in, even after signing out.
    private var issuedClientID: String? {
        get { UserDefaults.standard.string(forKey: "chatGPTClientID") }
        set { UserDefaults.standard.set(newValue, forKey: "chatGPTClientID") }
    }

    init() {
        if let data = ChatKeychain.data(ChatKeychain.chatGPTCredentials),
           let saved = try? JSONDecoder().decode(Credentials.self, from: data) {
            apply(saved, persist: false)
        }
    }

    // MARK: Sign in

    /// Runs the sign-in flow. `reconsent` asks OpenAI to show the consent screen again (to enable plan use).
    func signIn(reconsent: Bool = false) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }
        let server = LoopbackServer()
        defer { server.stop() }
        do {
            let port = try await server.start(preferredPort: 1455)
            let redirect = "http://127.0.0.1:\(port)/auth/callback"
            let verifier = Self.randomToken()
            let state = Self.randomToken()
            let nonce = Self.randomToken()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
            let clientID = issuedClientID

            var items: [URLQueryItem] = [
                URLQueryItem(name: "client_id", value: clientID ?? "dynamic_agent_client"),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "scope", value: Self.scopes),
                URLQueryItem(name: "resource", value: Self.resource),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "nonce", value: nonce),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            // OpenAI's devkit sends the host ID only "for a compatible authorization deployment"; off by default there too.
            if Self.sendsHostID { items.append(URLQueryItem(name: "ext_agent_host_id", value: hostID)) }
            if clientID == nil { items.append(URLQueryItem(name: "agent_name_hint", value: "Dew")) }
            if let email, clientID != nil { items.append(URLQueryItem(name: "login_hint", value: email)) }
            if reconsent { items.append(URLQueryItem(name: "prompt", value: "consent")) }
            var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
            components.queryItems = items
            // URLComponents leaves "+" and some reserved characters unescaped; OpenAI asks for every value encoded.
            components.percentEncodedQuery = items.map {
                "\($0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")"
            }.joined(separator: "&")

            let callback = try await waitForCallback(url: components.url!, server: server)
            guard callback["state"] == state else { throw ChatError.message("Sign-in didn't match the request. Please try again.") }
            if let error = callback["error"] {
                throw ChatError.message(error == "access_denied" ? "Sign-in was cancelled." : (callback["error_description"] ?? error))
            }
            guard let code = callback["code"] else { throw ChatError.message("ChatGPT didn't return a sign-in code.") }
            let returnedClient = callback["client_id"]
            if let clientID, let returnedClient, returnedClient != clientID {
                throw ChatError.message("ChatGPT returned a different app registration. Please try again.")
            }
            guard let finalClientID = clientID ?? returnedClient else {
                throw ChatError.message("ChatGPT didn't register Dew. Please try again.")
            }
            issuedClientID = finalClientID

            let tokens = try await postToken([
                "grant_type": "authorization_code",
                "client_id": finalClientID,
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirect,
                "resource": Self.resource,
            ])
            let claims = try Self.validatedClaims(idToken: tokens["id_token"] as? String, clientID: finalClientID, nonce: nonce)
            let wasEnabled = planEnabled
            let credentials = try makeCredentials(from: tokens, clientID: finalClientID, previous: nil, email: claims["email"] as? String)
            apply(credentials, persist: true)
            if planEnabled && !wasEnabled && !UserDefaults.standard.bool(forKey: "chatGPTWelcomeShown") {
                showsWelcome = true
                UserDefaults.standard.set(true, forKey: "chatGPTWelcomeShown")
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closed before OpenAI redirected back. If OpenAI showed an error in the sheet, say what it likely means.
            lastError = "Sign-in didn't finish. If OpenAI showed an error, Sign in with ChatGPT may not be available for your account yet."
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Opens the sign-in page and waits for OpenAI to redirect to the loopback server.
    private func waitForCallback(url: URL, server: LoopbackServer) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            func resume(_ result: Result<[String: String], Error>) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            server.onCallback = { [weak self] query in
                resume(.success(query))
                self?.authSession?.cancel()   // close the sheet; the page has already said "you can close this"
            }
            // No custom scheme: the redirect goes to 127.0.0.1, which the loopback server answers.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, error in
                MainActor.assumeIsolated {
                    if let error { resume(.failure(error)) } else { resume(.failure(ChatError.message("Sign-in ended unexpectedly."))) }
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false   // reuse an existing ChatGPT login in Safari
            authSession = session
            if !session.start() { resume(.failure(ChatError.message("Couldn't open the sign-in page."))) }
        }
    }

    // MARK: Tokens

    /// A current access token, refreshed first if it expires within two minutes (or if `forceRefresh`).
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let credentials else { throw ChatError.unauthorized("Sign in with ChatGPT in Settings → AI Chat.") }
        if !forceRefresh && credentials.expiresAt.timeIntervalSinceNow > 120 { return credentials.accessToken }
        return try await refresh().accessToken
    }

    /// Refreshes once at a time: refresh tokens rotate, so two refreshes racing would invalidate each other.
    private func refresh() async throws -> Credentials {
        if let refreshTask { return try await refreshTask.value }
        guard let current = credentials, let refreshToken = current.refreshToken else {
            signOutLocally()
            throw ChatError.unauthorized("ChatGPT sign-in expired. Sign in again in Settings → AI Chat.")
        }
        let task = Task { () throws -> Credentials in
            let tokens = try await self.postToken([
                "grant_type": "refresh_token",
                "client_id": current.clientID,
                "refresh_token": refreshToken,
                "resource": Self.resource,
            ])
            return try self.makeCredentials(from: tokens, clientID: current.clientID, previous: current, email: current.email)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let renewed = try await task.value
            apply(renewed, persist: true)
            return renewed
        } catch let error as TokenError where error.isTerminal {
            // The refresh token is unusable (expired, revoked or reused): a fresh sign-in is needed.
            signOutLocally()
            throw ChatError.unauthorized("ChatGPT sign-in expired. Sign in again in Settings → AI Chat.")
        }
        // Network and server errors keep the sign-in, so a later attempt can still refresh.
    }

    private struct TokenError: LocalizedError {
        let code: String?
        let message: String
        var errorDescription: String? { message }
        var isTerminal: Bool {
            ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
             "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "")
        }
    }

    private func postToken(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.httpBody = Self.formEncode(form)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = json["error"] as? String ?? (json["error"] as? [String: Any])?["code"] as? String
            let message = json["error_description"] as? String ?? (json["error"] as? [String: Any])?["message"] as? String
            throw TokenError(code: code, message: message ?? "ChatGPT sign-in failed (\(code ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")).")
        }
        return json
    }

    private func makeCredentials(from tokens: [String: Any], clientID: String, previous: Credentials?, email: String?) throws -> Credentials {
        guard let access = tokens["access_token"] as? String else { throw ChatError.message("ChatGPT didn't return an access token.") }
        let expiresIn = (tokens["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let scopes = (tokens["scope"] as? String)?.split(separator: " ").map(String.init) ?? previous?.scopes ?? []
        return Credentials(clientID: clientID, accessToken: access,
                           refreshToken: tokens["refresh_token"] as? String ?? previous?.refreshToken,
                           expiresAt: Date().addingTimeInterval(expiresIn), scopes: scopes, email: email,
                           idToken: tokens["id_token"] as? String ?? previous?.idToken)
    }

    private func apply(_ credentials: Credentials, persist: Bool) {
        self.credentials = credentials
        isSignedIn = true
        email = credentials.email
        planEnabled = credentials.scopes.contains(Self.planScope)
        if persist {
            ChatKeychain.set(try? JSONEncoder().encode(credentials), for: ChatKeychain.chatGPTCredentials, label: "Dew Chat: ChatGPT sign-in")
        }
    }

    // MARK: Sign out

    /// Revokes the refresh token with OpenAI, then forgets the tokens on this device.
    func signOut() async {
        let current = credentials
        signOutLocally()
        guard let current, let refreshToken = current.refreshToken else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.discoveryURL)
            let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let endpoint = (config?["revocation_endpoint"] as? String).flatMap(URL.init(string:)) else { throw URLError(.badServerResponse) }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
            request.httpBody = Self.formEncode(["token": refreshToken, "token_type_hint": "refresh_token", "client_id": current.clientID])
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        } catch {
            lastError = "Signed out on this device, but OpenAI didn't confirm it. You can also disconnect Dew in ChatGPT → Settings."
        }
    }

    private func signOutLocally() {
        credentials = nil
        isSignedIn = false
        planEnabled = false
        ChatKeychain.set(nil, for: ChatKeychain.chatGPTCredentials, label: "")
    }

    // MARK: Helpers

    /// Checks the ID token's claims. It comes straight from the token endpoint over TLS, which OpenID Connect
    /// accepts in place of checking the signature; issuer, audience, expiry and nonce are still checked.
    private static func validatedClaims(idToken: String?, clientID: String, nonce: String) throws -> [String: Any] {
        guard let idToken else { return [:] }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2, let payload = Data(base64URLEncoded: String(parts[1])),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            throw ChatError.message("ChatGPT returned an unreadable sign-in token.")
        }
        let issuerHost = (claims["iss"] as? String).flatMap(URL.init(string:))?.host()
        let audience = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String) ?? ""]
        let expiry = (claims["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        guard issuerHost == "auth.openai.com", audience.contains(clientID),
              (expiry ?? .distantFuture) > Date(), claims["nonce"] as? String == nonce else {
            throw ChatError.message("ChatGPT's sign-in token didn't check out. Please try again.")
        }
        return claims
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func formEncode(_ form: [String: String]) -> Data {
        Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")" }
            .joined(separator: "&").utf8)
    }
}

private extension CharacterSet {
    /// Unreserved characters only (RFC 3986), so every other character in a value is percent-encoded.
    static let urlQueryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}

/// Anchors the sign-in sheet to the frontmost window.
private final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            #endif
        }
    }
}

// MARK: - Loopback server

/// A tiny HTTP server on 127.0.0.1 that receives the OAuth redirect once.
private final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    /// Called on the main thread with the callback's query parameters.
    var onCallback: (([String: String]) -> Void)?

    /// Listens on `preferredPort` if it's free, otherwise any free port. Returns the port.
    func start(preferredPort: UInt16) async throws -> UInt16 {
        do { return try await listen(on: NWEndpoint.Port(rawValue: preferredPort)!) } catch { return try await listen(on: .any) }
    }

    private func listen(on port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            // The state handler can be called more than once; only the first ready/failed state may resume.
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard once.claim() else { return }
                    listener.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1\(target)")
            guard components?.path == "/auth/callback" else {
                Self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            let ok = query["code"] != nil
            Self.respond(connection, status: "200 OK", body: """
            <!doctype html><meta charset="utf-8"><title>Dew</title>
            <body style="font: 15px -apple-system, sans-serif; text-align: center; padding-top: 80px; color: #333">
            <h2>\(ok ? "You're signed in to ChatGPT" : "Sign-in didn't finish")</h2>
            <p>You can close this window and go back to Dew.</p></body>
            """)
            MainActor.assumeIsolated { self?.onCallback?(query) }
        }
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// A thread-safe "only the first caller wins" flag, for callbacks that may fire more than once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// True for the first call only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
