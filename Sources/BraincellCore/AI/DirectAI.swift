import Foundation
import Security

/// Opt-in alternative to the manual ChatGPT bridge: send a prepared request straight to the Anthropic Messages API.
/// The response goes through exactly the same validation and import as a pasted one, so nothing is trusted more.
/// Nothing is sent unless the learner enabled it, stored a key, and pressed Send for that batch.

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw DirectAIError.network("Not an HTTP response.") }
        return (data, http)
    }
}

public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> String?
    func write(_ account: String, value: String) throws
    func delete(_ account: String) throws
    /// Whether a credential exists. Must not read the secret itself, so a Keychain-backed store can answer without an authorization prompt.
    func contains(_ account: String) -> Bool
}
public extension SecretStore { func contains(_ account: String) -> Bool { ((try? read(account)) ?? nil) != nil } }

/// The key lives in the login Keychain, never in the database, backups, logs or exports.
/// `legacyService` is the pre-rename (CramLab) entry: a key found only there is copied to `service` on first read.
public struct KeychainSecretStore: SecretStore {
    let service: String
    let legacyService: String?
    public init(service: String = "com.braincell.api-keys", legacyService: String? = nil) { self.service = service; self.legacyService = legacyService }
    private func query(_ account: String, _ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private func read(_ account: String, service: String) throws -> String? {
        var q = query(account, service); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let d = out as? Data else { throw DirectAIError.keychain(st) }
        return String(data: d, encoding: .utf8)
    }
    /// Attributes-only lookup: macOS doesn't ask for authorization because no secret data is returned.
    public func contains(_ account: String) -> Bool {
        for s in [service, legacyService].compactMap({ $0 }) {
            var q = query(account, s); q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }
    private func remove(_ account: String, service: String) throws {
        let st = SecItemDelete(query(account, service) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw DirectAIError.keychain(st) }
    }
    public func read(_ account: String) throws -> String? {
        if let v = try read(account, service: service) { return v }
        guard let legacyService, let v = try read(account, service: legacyService) else { return nil }
        try? write(account, value: v)
        return v
    }
    public func write(_ account: String, value: String) throws {
        try remove(account, service: service)
        var q = query(account, service); q[kSecValueData as String] = Data(value.utf8); q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw DirectAIError.keychain(st) }
    }
    public func delete(_ account: String) throws {
        try remove(account, service: service)
        if let legacyService { try remove(account, service: legacyService) }
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    public init() {}
    public func read(_ account: String) throws -> String? { lock.withLock { items[account] } }
    public func write(_ account: String, value: String) throws { lock.withLock { items[account] = value } }
    public func delete(_ account: String) throws { lock.withLock { items[account] = nil } }
}

public enum DirectAIError: Error, LocalizedError, Equatable {
    case disabled, noKey
    case network(String)
    case http(Int, String)
    case malformedResponse
    case refused(String)
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .disabled: "Direct AI requests are switched off in Settings."
        case .noKey: "No API key is stored. Add one in Settings."
        case .network(let m): "Couldn’t reach the API: \(m)"
        case .http(401, _), .http(403, _): "The API rejected the key. Check it in Settings."
        case .http(429, _): "The API is rate limiting requests. Try again in a minute."
        case .http(let c, let m) where c >= 500: "The API had a problem (\(c)). Try again later. \(m)"
        case .http(let c, let m): "The API refused the request (\(c)): \(m)"
        case .malformedResponse: "The API answered in a way Learn Anyway couldn’t read. The request is unchanged; use the manual route instead."
        case .refused(let m): m
        case .keychain(let s): isDenied ? "macOS denied access to the saved API key (code \(s))." : "The Keychain refused the operation (code \(s))."
        }
    }
    /// The user (or macOS) refused to let Learn Anyway read the item, as opposed to a missing or broken item.
    public var isDenied: Bool {
        if case .keychain(let s) = self { return [-128, -25293, -25308, -25243].contains(s) }     // userCanceled, authFailed, interactionNotAllowed, noAccessForItem
        return false
    }
}

public struct DirectAIService: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let keyAccount = "anthropic"
    public static let defaultModel = "claude-sonnet-5-5"
    public static let maxOutputTokens = 8192

    let ai: AITaskService, settings: SettingsStore, secrets: SecretStore, transport: HTTPTransport
    public init(ai: AITaskService, settings: SettingsStore, secrets: SecretStore, transport: HTTPTransport = URLSessionTransport()) {
        self.ai = ai; self.settings = settings; self.secrets = secrets; self.transport = transport
    }

    public var isEnabled: Bool { (try? settings.bool(.directAPIEnabled)) ?? false }
    public var hasKey: Bool { secrets.contains(Self.keyAccount) }
    public var model: String { ((try? settings.string(.directAPIModel)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultModel }

    /// The exact bytes that would be sent, for the confirmation sheet. Contains no key.
    public func preview(batchId: UUID) throws -> (model: String, characters: Int, text: String) {
        let pkg = try ai.prepare(batchId: batchId)
        return (model, pkg.singlePrompt.count, pkg.singlePrompt)
    }

    /// Sends one batch and imports the reply. Throws before any network use when disabled or keyless.
    /// A failed call leaves the batch exactly as it was, so the manual route stays available.
    @discardableResult
    public func send(batchId: UUID) async throws -> AnyImportReport {
        guard isEnabled else { throw DirectAIError.disabled }
        guard let key = try secrets.read(Self.keyAccount), !key.isEmpty else { throw DirectAIError.noKey }
        let pkg = try ai.prepare(batchId: batchId)

        var req = URLRequest(url: Self.endpoint, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["model": model, "max_tokens": Self.maxOutputTokens,
                                   "messages": [["role": "user", "content": pkg.singlePrompt]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await transport.send(req) }
        catch let e as DirectAIError { throw e }
        catch { throw DirectAIError.network((error as? URLError)?.localizedDescription ?? "request failed") }

        guard (200..<300).contains(http.statusCode) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            throw DirectAIError.http(http.statusCode, String(msg.prefix(300)))
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let parts = obj["content"] as? [[String: Any]] else { throw DirectAIError.malformedResponse }
        if obj["stop_reason"] as? String == "refusal" { throw DirectAIError.refused("The model declined this request.") }
        let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw DirectAIError.malformedResponse }

        try ai.markExported(batchId: batchId, method: .api)
        // A reply cut off at the token limit is almost always unparseable JSON; the import preserves it and reports it like any bad paste.
        return try ai.importAny(text, targetBatchId: batchId)
    }
}
