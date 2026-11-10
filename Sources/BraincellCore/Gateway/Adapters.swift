import Foundation

public enum GatewayError: Error, LocalizedError, Equatable {
    case noKey, invalidCredentials
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int, String)
    case network(String)
    case timeout
    case malformed
    case unavailable(String)       // nothing can serve the request; the message says what to configure
    case budgetBlocked(String)
    case cancelled
    case manualRequired(String)
    case unsupported(String)
    /// macOS refused to release the saved key (or the Keychain failed). Never retried automatically and never counted as a model failure.
    case keychain(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: "No API key is stored for this connection."
        case .invalidCredentials: "The provider rejected the API key."
        case .rateLimited: "The provider is rate limiting requests."
        case .http(let c, let m): "The provider returned \(c)\(m.isEmpty ? "" : ": \(m)")"
        case .network(let m): "Couldn’t reach the provider: \(m)"
        case .timeout: "The request timed out."
        case .malformed: "The provider’s reply couldn’t be read."
        case .unavailable(let m), .budgetBlocked(let m), .manualRequired(let m), .unsupported(let m), .keychain(let m): m
        case .cancelled: "Cancelled."
        }
    }
    /// Short, content-free label stored in usage history.
    public var category: String {
        switch self {
        case .noKey, .invalidCredentials: "auth"; case .rateLimited: "rate_limit"; case .http(let c, _): "http_\(c)"
        case .network: "network"; case .timeout: "timeout"; case .malformed: "malformed"; case .unavailable: "unavailable"
        case .keychain: "keychain"; case .budgetBlocked: "budget"; case .cancelled: "cancelled"; case .manualRequired: "manual"; case .unsupported: "unsupported"
        }
    }
    /// Only transient failures are retried; auth, malformed and budget errors never are.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .timeout, .network: true
        case .http(let c, _): c >= 500
        default: false
        }
    }
}

/// One turn of an ordered conversation. Roles are limited to what every supported protocol accepts; instructions travel separately in `system`.
public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var content: String
    public init(_ role: Role, _ content: String) { self.role = role; self.content = content }
}

public struct LLMRequest: Sendable {
    public var prompt: String
    /// When set, these ordered messages are sent instead of the single `prompt` (which is then ignored). Existing single-prompt callers are unchanged.
    public var messages: [LLMMessage]?
    public var system: String?
    public var temperature: Double?
    public var maxTokens: Int?
    public var timeout: TimeInterval = 120
    public init(prompt: String, system: String? = nil, temperature: Double? = nil, maxTokens: Int? = nil, timeout: TimeInterval = 120) {
        self.prompt = prompt; self.system = system; self.temperature = temperature; self.maxTokens = maxTokens; self.timeout = timeout
    }
}

public struct LLMResult: Sendable {
    public var text: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedTokens: Int?
    public var target: String
    public var trace: [String] = []
}

public struct DiscoveredModel: Sendable, Equatable {
    public var id: String; public var name: String
    public var inputPricePerM: Double?; public var outputPricePerM: Double?
}

/// Wire-level calls for the protocols this build implements (LLM only). Stateless; the transport is injected so tests never touch the network.
public struct ProviderClient: Sendable {
    public let transport: HTTPTransport
    public init(transport: HTTPTransport) { self.transport = transport }

    static func url(_ base: String, _ path: String) -> URL? { URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) }

    private func request(_ conn: AIConnection, key: String?, path: String, body: Data?, timeout: TimeInterval) throws -> URLRequest {
        guard let spec = conn.spec else { throw GatewayError.unsupported("Unknown provider.") }
        guard let u = Self.url(conn.effectiveBaseURL, path) else { throw GatewayError.unavailable("The base URL isn’t valid.") }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = body == nil ? "GET" : "POST"
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        switch spec.wire {
        case .anthropic: r.setValue(key, forHTTPHeaderField: "x-api-key"); r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        default: if let key, !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await transport.send(r) }
        catch is CancellationError { throw GatewayError.cancelled }
        catch let e as URLError where e.code == .cancelled { throw GatewayError.cancelled }
        catch let e as URLError where e.code == .timedOut { throw GatewayError.timeout }
        catch let e as GatewayError { throw e }
        catch { throw GatewayError.network((error as? URLError)?.localizedDescription ?? "request failed") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw GatewayError.invalidCredentials
        case 429: throw GatewayError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init))
        default:
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? (obj?["error"] as? String) ?? ""
            throw GatewayError.http(http.statusCode, String(msg.prefix(200)))
        }
    }

    // MARK: Models

    public func listModels(_ conn: AIConnection, key: String?) async throws -> [DiscoveredModel] {
        guard let spec = conn.spec, spec.isImplemented else { throw GatewayError.unsupported("This provider isn’t supported yet.") }
        let path = spec.wire == .ollama ? "/api/tags" : "/models"
        let data = try await send(try request(conn, key: key, path: path, body: nil, timeout: 20))
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw GatewayError.malformed }
        if spec.wire == .ollama {
            guard let ms = obj["models"] as? [[String: Any]] else { throw GatewayError.malformed }
            return ms.compactMap { ($0["name"] as? String).map { DiscoveredModel(id: $0, name: $0) } }
        }
        guard let ms = obj["data"] as? [[String: Any]] else { throw GatewayError.malformed }
        return ms.compactMap { m in
            guard let id = m["id"] as? String, Self.looksLikeChatModel(id) else { return nil }
            let pricing = m["pricing"] as? [String: Any]       // OpenRouter reports USD per token as strings
            func perM(_ k: String) -> Double? { (pricing?[k] as? String).flatMap(Double.init).map { $0 * 1_000_000 } }
            return DiscoveredModel(id: id, name: (m["display_name"] as? String) ?? (m["name"] as? String) ?? id, inputPricePerM: perM("prompt"), outputPricePerM: perM("completion"))
        }
    }

    /// Model lists mix chat and non-chat models. This only filters out clearly non-chat ids; users can add any id by hand.
    static func looksLikeChatModel(_ id: String) -> Bool {
        let l = id.lowercased()
        return !["embedding", "whisper", "tts", "dall-e", "moderation", "transcribe", "realtime", "image", "audio"].contains { l.contains($0) }
    }

    // MARK: Chat

    /// The conversation as the providers expect it: strictly alternating, starting with a user turn. Adjacent turns of one role are merged,
    /// and a history that would start with the assistant gets an explicit placeholder rather than being silently reordered.
    static func wireMessages(_ req: LLMRequest) -> [[String: String]] {
        guard let ms = req.messages, !ms.isEmpty else { return [["role": "user", "content": req.prompt]] }
        var merged: [LLMMessage] = []
        for m in ms where !m.content.isEmpty {
            if let last = merged.last, last.role == m.role { merged[merged.count - 1].content += "\n\n" + m.content } else { merged.append(m) }
        }
        if merged.first?.role == .assistant { merged.insert(LLMMessage(.user, "(Earlier conversation omitted.)"), at: 0) }
        return merged.map { ["role": $0.role.rawValue, "content": $0.content] }
    }

    public func complete(_ conn: AIConnection, model: String, key: String?, _ req: LLMRequest) async throws -> LLMResult {
        guard let spec = conn.spec, spec.isImplemented else { throw GatewayError.unsupported("This provider isn’t supported yet.") }
        if spec.needsKey, (key ?? "").isEmpty { throw GatewayError.noKey }
        var body: [String: Any] = ["model": model]
        let path: String
        if spec.wire == .anthropic {
            path = "/messages"
            body["max_tokens"] = req.maxTokens ?? 4096                      // required by this API
            body["messages"] = Self.wireMessages(req)
            if let s = req.system { body["system"] = s }
            if let t = req.temperature { body["temperature"] = t }
        } else {
            path = spec.wire == .ollama ? "/v1/chat/completions" : "/chat/completions"
            var msgs: [[String: String]] = []
            if let s = req.system { msgs.append(["role": "system", "content": s]) }
            msgs += Self.wireMessages(req)
            body["messages"] = msgs
            if let t = req.temperature { body["temperature"] = t }
            if let m = req.maxTokens { body[conn.providerId == "openai" ? "max_completion_tokens" : "max_tokens"] = m }
        }
        let r = try request(conn, key: key, path: path, body: try JSONSerialization.data(withJSONObject: body), timeout: req.timeout)
        let data = try await send(r)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw GatewayError.malformed }
        let usage = obj["usage"] as? [String: Any]
        if spec.wire == .anthropic {
            guard let parts = obj["content"] as? [[String: Any]] else { throw GatewayError.malformed }
            let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            guard !text.isEmpty else { throw GatewayError.malformed }
            return LLMResult(text: text, inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int,
                             cachedTokens: usage?["cache_read_input_tokens"] as? Int, target: model)
        }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first, let text = (choice["message"] as? [String: Any])?["content"] as? String, !text.isEmpty
        else { throw GatewayError.malformed }
        return LLMResult(text: text, inputTokens: usage?["prompt_tokens"] as? Int, outputTokens: usage?["completion_tokens"] as? Int,
                         cachedTokens: (usage?["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int, target: model)
    }
}
