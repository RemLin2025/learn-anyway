import Foundation

public enum WireProtocol: String, Sendable { case openAICompatible, anthropic, ollama, none }

public enum ConnectionStatus: String, Codable, Sendable {
    case configured, ready, invalidCredentials, unavailable, disabled
    public var label: String {
        switch self {
        case .configured: "Configured"; case .ready: "Ready"; case .invalidCredentials: "Invalid credentials"
        case .unavailable: "Unavailable"; case .disabled: "Disabled"
        }
    }
}

/// A supported provider type. `operational` lists capabilities with a real adapter in this build; `declared`
/// lists what the provider offers in principle but this app can’t call yet. Nothing outside `operational` is ever shown as working.
public struct ProviderSpec: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let symbol: String
    public let summary: String
    public let baseURL: String
    public let wire: WireProtocol
    public let operational: Set<Capability>
    public let declared: Set<Capability>
    public let needsKey: Bool
    public let isLocal: Bool
    public let inPlans: Bool
    public let endpointVerified: Bool
    public let accountURL: String?
    public let allowsCustomBaseURL: Bool

    public var isImplemented: Bool { wire != .none }
    public func supports(_ c: Capability) -> Bool { operational.contains(c) }
    public func offers(_ c: Capability) -> Bool { operational.contains(c) || declared.contains(c) }
}

public enum ProviderRegistry {
    static func p(_ id: String, _ name: String, _ symbol: String, _ summary: String, _ base: String, _ wire: WireProtocol,
                  declared: Set<Capability> = [], key: Bool = true, local: Bool = false, plans: Bool = false,
                  verified: Bool = true, account: String? = nil, custom: Bool = false) -> ProviderSpec {
        ProviderSpec(id: id, name: name, symbol: symbol, summary: summary, baseURL: base, wire: wire,
                     operational: wire == .none ? [] : [.llm], declared: declared, needsKey: key, isLocal: local,
                     inPlans: plans, endpointVerified: verified, accountURL: account, allowsCustomBaseURL: custom)
    }

    public static let all: [ProviderSpec] = [
        p("openai", "OpenAI", "sparkles", "GPT models via the OpenAI API.", "https://api.openai.com/v1", .openAICompatible,
          declared: [.imageGeneration, .tts, .stt, .embeddings, .vision], account: "https://platform.openai.com/api-keys"),
        p("anthropic", "Anthropic", "a.circle", "Claude models via the Messages API.", "https://api.anthropic.com/v1", .anthropic,
          declared: [.vision], account: "https://console.anthropic.com/settings/keys"),
        p("openrouter", "OpenRouter", "arrow.triangle.branch", "One key for many hosted models.", "https://openrouter.ai/api/v1", .openAICompatible,
          declared: [.vision, .embeddings, .imageGeneration], plans: true, account: "https://openrouter.ai/keys"),
        p("deepseek", "DeepSeek", "water.waves", "DeepSeek chat and reasoning models.", "https://api.deepseek.com", .openAICompatible,
          plans: true, account: "https://platform.deepseek.com/api_keys"),
        p("moonshot", "Kimi / Moonshot", "moon.stars", "Moonshot’s Kimi models.", "https://api.moonshot.ai/v1", .openAICompatible,
          declared: [.vision], plans: true, verified: false, account: "https://platform.moonshot.ai", custom: true),
        p("gemini", "Google Gemini", "diamond", "Gemini through Google’s OpenAI-compatible endpoint.", "https://generativelanguage.googleapis.com/v1beta/openai", .openAICompatible,
          declared: [.vision, .embeddings, .imageGeneration], verified: false, account: "https://aistudio.google.com/apikey", custom: true),
        p("ollama", "Ollama (local)", "desktopcomputer", "Models running on this Mac. No key, no cloud cost.", "http://localhost:11434", .ollama,
          declared: [.vision, .embeddings], key: false, local: true, custom: true),
        p("custom", "OpenAI-compatible endpoint", "link", "Any server that speaks the OpenAI chat API.", "https://", .openAICompatible, custom: true),
        // Listed so the UI is honest about them; no adapter exists yet.
        p("minimax", "MiniMax", "waveform", "Multi-capability plan.", "", .none, declared: [.llm, .imageGeneration, .videoGeneration, .tts, .stt], plans: true, verified: false),
        p("tokendance", "TokenDance", "d.circle", "Multi-capability plan.", "", .none, declared: [.llm, .imageGeneration, .videoGeneration, .tts, .webSearch], plans: true, verified: false),
        p("siliconflow", "SiliconFlow", "square.stack.3d.up", "Multi-model gateway.", "", .none, declared: [.llm, .imageGeneration, .embeddings], plans: true, verified: false),
        p("glm", "GLM / Zhipu", "g.circle", "GLM models.", "", .none, declared: [.llm], verified: false),
        p("qwen", "Qwen", "q.circle", "Qwen-compatible services.", "", .none, declared: [.llm, .vision], verified: false),
        p("azure", "Azure OpenAI", "cloud", "Per-deployment endpoints and API versions.", "", .none, declared: [.llm], verified: false),
    ]

    public static func spec(_ id: String) -> ProviderSpec? { all.first { $0.id == id } }
    public static func providers(for c: Capability) -> [ProviderSpec] { all.filter { $0.offers(c) } }
    public static var planProviders: [ProviderSpec] { all.filter(\.inPlans) }

    /// Refuses plain HTTP to anything but loopback, and non-HTTP schemes.
    public static func validateBaseURL(_ s: String) -> String? {
        guard let u = URL(string: s), let host = u.host, !host.isEmpty else { return "Enter a full URL, e.g. https://api.example.com/v1." }
        if u.scheme == "https" { return nil }
        if u.scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host) { return nil }
        return "Only https:// is allowed (http:// only for localhost)."
    }
}
