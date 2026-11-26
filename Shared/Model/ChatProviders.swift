import Foundation

/// A finished answer from any provider.
struct ChatReply {
    enum Finish { case complete, truncated, refused }
    var text: String
    var finish: Finish
    /// Anthropic only: the reply's content blocks, sent back unchanged on the next turn.
    var anthropicContent: [[String: Any]]?
    var toolCalls: [ChatToolCall] = []
}

/// Parses a tool call's JSON arguments (nil if they don't parse or aren't an object).
private func parseArguments(_ json: String) -> [String: Any]? {
    let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return [:] }
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
}

enum ChatError: LocalizedError {
    case message(String)
    case unauthorized(String)
    case usageLimit(String)

    var errorDescription: String? {
        switch self {
        case .message(let text), .unauthorized(let text), .usageLimit(let text): text
        }
    }
    var isUsageLimit: Bool { if case .usageLimit = self { true } else { false } }
}

/// Server-sent events: yields the JSON object on each `data:` line (stops at `[DONE]`).
private func events(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<[String: Any], Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    if let data = payload.data(using: .utf8),
                       let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// Opens a streaming request; non-200 responses become a `ChatError` built from the body.
private func open(_ request: URLRequest, describe: (Int, [String: Any]?) -> ChatError) async throws -> URLSession.AsyncBytes {
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return bytes }
    var data = Data()
    for try await byte in bytes {
        data.append(byte)
        if data.count > 100_000 { break }
    }
    throw describe(http.statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
}

private func jsonRequest(_ url: URL, body: [String: Any], headers: [String: String]) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 600
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return request
}

// MARK: - Anthropic Messages API

/// Minimal client for the Anthropic Messages API (there's no official Swift SDK).
enum AnthropicStream {
    static func request(apiKey: String, model: ChatModel, depth: ChatDepth, system: String, messages: [[String: Any]],
                        tools: [ChatTools.Spec], allowCalls: Bool) -> URLRequest {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 64000,
            "stream": true,
            "system": [["type": "text", "text": system]],
            "messages": messages,
            "output_config": ["effort": depth.rawValue],
            "cache_control": ["type": "ephemeral"],   // pages shared earlier are re-read from cache on follow-ups
        ]
        if !tools.isEmpty {
            // Inputs stream as they're written (eager_input_streaming); Dew checks them itself before acting.
            body["tools"] = tools.map {
                ["name": $0.name, "description": $0.description, "input_schema": $0.parameters, "eager_input_streaming": true] as [String: Any]
            }
            if !allowCalls { body["tool_choice"] = ["type": "none"] }
        }
        var headers = ["x-api-key": apiKey, "anthropic-version": "2026-10-21"]
        if model.supportsFallbacks {
            // If a safety classifier declines, the API retries on a suitable model within the same request.
            body["fallbacks"] = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }
        return jsonRequest(URL(string: "https://api.anthropic.com/v1/messages")!, body: body, headers: headers)
    }

    @MainActor
    static func run(_ request: URLRequest, onText: @MainActor (String) -> Void) async throws -> ChatReply {
        let bytes = try await open(request) { status, json in
            let error = json?["error"] as? [String: Any]
            if status == 401 { return .unauthorized("Your Anthropic API key wasn't accepted. Check it in Settings → AI Chat.") }
            return .message(friendly(type: error?["type"] as? String, message: error?["message"] as? String ?? "The request failed (HTTP \(status))."))
        }
        var blocks: [Int: [String: Any]] = [:]
        var toolInputs: [Int: String] = [:]   // tool_use input JSON as it streams
        var stopReason: String?

        func answerText() -> String {
            blocks.keys.sorted().compactMap { blocks[$0] }
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n\n")
        }

        for try await event in events(bytes) {
            let index = event["index"] as? Int ?? 0
            switch event["type"] as? String {
            case "content_block_start":
                blocks[index] = event["content_block"] as? [String: Any] ?? [:]
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], var block = blocks[index] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    block["text"] = (block["text"] as? String ?? "") + (delta["text"] as? String ?? "")
                case "thinking_delta":
                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    block["signature"] = delta["signature"]
                case "input_json_delta":
                    toolInputs[index, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break
                }
                blocks[index] = block
                onText(answerText())
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String { stopReason = reason }
            case "error":
                let error = event["error"] as? [String: Any]
                throw ChatError.message(friendly(type: error?["type"] as? String, message: error?["message"] as? String))
            default:
                break
            }
        }
        // Tool inputs: parse the streamed JSON. It isn't validated by the API when streamed eagerly, so a
        // call whose input doesn't parse gets an error result instead of running.
        var calls: [ChatToolCall] = []
        for index in blocks.keys.sorted() where blocks[index]?["type"] as? String == "tool_use" {
            let json = toolInputs[index] ?? ""
            let arguments = parseArguments(json)
            blocks[index]?["input"] = arguments ?? [:]
            calls.append(ChatToolCall(id: blocks[index]?["id"] as? String ?? UUID().uuidString, name: blocks[index]?["name"] as? String ?? "",
                                      arguments: arguments, argumentsJSON: json.isEmpty ? "{}" : json))
        }
        let content = blocks.keys.sorted().compactMap { blocks[$0] }
        let finish: ChatReply.Finish = switch stopReason {
        case "refusal": .refused
        case "max_tokens": .truncated
        default: .complete
        }
        return ChatReply(text: answerText(), finish: finish, anthropicContent: replayable(content),
                         toolCalls: stopReason == "tool_use" ? calls : [])
    }

    /// After a mid-answer fallback, model-internal blocks from before the last `fallback` block are left out
    /// when the reply is sent back (text and the fallback block itself stay where they are).
    private static func replayable(_ content: [[String: Any]]) -> [[String: Any]] {
        guard let boundary = content.lastIndex(where: { $0["type"] as? String == "fallback" }) else { return content }
        let modelInternal: Set<String> = ["thinking", "redacted_thinking", "tool_use", "server_tool_use"]
        return content.enumerated().compactMap { index, block in
            index < boundary && modelInternal.contains(block["type"] as? String ?? "") ? nil : block
        }
    }

    private static func friendly(type: String?, message: String?) -> String {
        switch type {
        case "overloaded_error": "Claude is busy right now. Try again in a moment."
        case "rate_limit_error": "You've hit your API rate limit. Try again shortly."
        case "authentication_error": "Your Anthropic API key wasn't accepted. Check it in Settings → AI Chat."
        default: message ?? "Something went wrong."
        }
    }
}

// MARK: - OpenAI Responses API (ChatGPT plan)

/// Streams from `POST /v1/responses` with a "Sign in with ChatGPT" token. The plan route requires
/// `store: false` and `stream: true`, takes the full history in `input`, and rejects `max_output_tokens`,
/// `temperature` and similar fields, so none are sent.
enum ResponsesStream {
    static func request(token: String, model: String, instructions: String, input: [[String: Any]],
                        tools: [ChatTools.Spec], allowCalls: Bool) -> URLRequest {
        var body: [String: Any] = ["model": model, "instructions": instructions, "input": input, "store": false, "stream": true]
        if !tools.isEmpty {
            body["tools"] = tools.map {
                ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters, "strict": false] as [String: Any]
            }
            if !allowCalls { body["tool_choice"] = "none" }
        }
        return jsonRequest(ChatGPTAccount.apiBase.appending(path: "responses"), body: body,
                           headers: ["authorization": "Bearer \(token)", "accept": "text/event-stream"])
    }

    @MainActor
    static func run(_ request: URLRequest, onText: @MainActor (String) -> Void) async throws -> ChatReply {
        let bytes = try await open(request) { status, json in
            let error = json?["error"] as? [String: Any]
            return describe(status: status, code: error?["code"] as? String ?? error?["type"] as? String, message: error?["message"] as? String)
        }
        var text = ""
        var refusal = ""
        var calls: [ChatToolCall] = []
        var finish: ChatReply.Finish?
        for try await event in events(bytes) {
            switch event["type"] as? String {
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
                onText(text)
            case "response.output_item.done":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "function_call" {
                    let json = item["arguments"] as? String ?? "{}"
                    calls.append(ChatToolCall(id: item["call_id"] as? String ?? UUID().uuidString, name: item["name"] as? String ?? "",
                                              arguments: parseArguments(json), argumentsJSON: json))
                }
            case "response.refusal.delta":
                refusal += event["delta"] as? String ?? ""
            case "response.completed":
                finish = .complete
            case "response.incomplete":
                finish = .truncated
            case "response.failed":
                let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
                throw describe(status: nil, code: error?["code"] as? String, message: error?["message"] as? String)
            case "error":
                let error = event["error"] as? [String: Any] ?? event
                throw describe(status: nil, code: error["code"] as? String, message: error["message"] as? String)
            default:
                break
            }
        }
        // Only `response.completed` means success; a stream that just stops has failed.
        guard let finish else { throw ChatError.message("The answer stopped unexpectedly. Try again.") }
        if text.isEmpty && !refusal.isEmpty && calls.isEmpty { return ChatReply(text: refusal, finish: .refused) }
        return ChatReply(text: text, finish: finish, toolCalls: calls)
    }

    private static func describe(status: Int?, code: String?, message: String?) -> ChatError {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return .usageLimit("You've reached the limit for using your ChatGPT plan in Dew. You can check or change it in ChatGPT's settings under Usage.")
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return .message("ChatGPT plan usage is temporarily unavailable. Try again in a moment.")
        case "subscription_sharing_user_not_eligible":
            return .message("Your ChatGPT plan can't be used in other apps. Go, Plus, Pro and Business plans can.")
        case "subscription_sharing_route_not_supported":
            return .message("This request isn't supported with a ChatGPT plan.")
        default:
            if status == 401 { return .unauthorized("ChatGPT sign-in expired. Sign in again in Settings → AI Chat.") }
            if status == 429 { return .usageLimit(message ?? "You've reached your ChatGPT plan's usage limit.") }
            return .message(message ?? "The request failed\(status.map { " (HTTP \($0))" } ?? "").")
        }
    }
}

// MARK: - OpenAI-compatible Chat Completions (OpenRouter, OpenAI, Ollama, LM Studio…)

/// Chat Completions is the format nearly every OpenAI-compatible server supports.
enum ChatCompletionsStream {
    static func request(baseURL: URL, apiKey: String?, model: String, messages: [[String: Any]],
                        tools: [ChatTools.Spec], allowCalls: Bool) -> URLRequest {
        var headers: [String: String] = [:]
        if let apiKey { headers["authorization"] = "Bearer \(apiKey)" }
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        if !tools.isEmpty {
            body["tools"] = tools.map {
                ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]] as [String: Any]
            }
            if !allowCalls { body["tool_choice"] = "none" }
        }
        return jsonRequest(baseURL.appending(path: "chat/completions"), body: body, headers: headers)
    }

    @MainActor
    static func run(_ request: URLRequest, onText: @MainActor (String) -> Void) async throws -> ChatReply {
        let bytes: URLSession.AsyncBytes
        do {
            bytes = try await open(request) { status, json in
                let error = json?["error"] as? [String: Any]
                let message = error?["message"] as? String ?? json?["error"] as? String
                if status == 401 || status == 403 { return .unauthorized(message ?? "The server didn't accept your API key.") }
                if status == 404 { return .message(message ?? "The server or model wasn't found. Check the address and model in Settings → AI Chat.") }
                return .message(message ?? "The request failed (HTTP \(status)).")
            }
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw ChatError.message("Couldn't reach \(request.url?.host() ?? "the server"). If it's a local model, check that it's running.")
        }
        var text = ""
        var finishReason: String?
        var partialCalls: [Int: (id: String, name: String, arguments: String)] = [:]   // tool calls stream in pieces
        for try await event in events(bytes) {
            if let error = event["error"] as? [String: Any] {
                throw ChatError.message(error["message"] as? String ?? "The server reported an error.")
            }
            guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
            if let content = (choice["delta"] as? [String: Any])?["content"] as? String, !content.isEmpty {
                text += content
                onText(text)
            }
            for piece in (choice["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]] ?? [] {
                let index = piece["index"] as? Int ?? 0
                var call = partialCalls[index] ?? (id: "", name: "", arguments: "")
                if let id = piece["id"] as? String, !id.isEmpty { call.id = id }
                let function = piece["function"] as? [String: Any]
                if let name = function?["name"] as? String { call.name += name }
                if let arguments = function?["arguments"] as? String { call.arguments += arguments }
                partialCalls[index] = call
            }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
        }
        let calls = partialCalls.keys.sorted().compactMap { partialCalls[$0] }.filter { !$0.name.isEmpty }.map {
            ChatToolCall(id: $0.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : $0.id, name: $0.name,
                         arguments: parseArguments($0.arguments), argumentsJSON: $0.arguments.isEmpty ? "{}" : $0.arguments)
        }
        let finish: ChatReply.Finish = switch finishReason {
        case "length": .truncated
        case "content_filter": .refused
        default: .complete
        }
        return ChatReply(text: text, finish: finish, toolCalls: calls)
    }
}

// MARK: - Model lists

enum ModelList {
    /// `GET {base}/models`. Understands the standard OpenAI shape (`data[].id`) and the ChatGPT plan's
    /// (`models[]` with `slug`, `display_name` and `visibility`).
    static func fetch(baseURL: URL, bearer: String?) async throws -> [RemoteModel] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.timeoutInterval = 20
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw ChatError.message(message ?? "Couldn't load models (HTTP \(http.statusCode)).")
        }
        if let models = json?["models"] as? [[String: Any]] {
            return models.compactMap { model in
                guard let slug = model["slug"] as? String ?? model["id"] as? String else { return nil }
                if let visibility = model["visibility"] as? String, visibility != "list" { return nil }
                return RemoteModel(id: slug, name: model["display_name"] as? String ?? slug)
            }
        }
        let list = (json?["data"] as? [[String: Any]] ?? []).compactMap { model -> RemoteModel? in
            guard let id = model["id"] as? String else { return nil }
            return RemoteModel(id: id, name: model["name"] as? String ?? id)
        }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
