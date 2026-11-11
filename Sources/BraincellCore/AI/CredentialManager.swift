import Foundation

/// The one place API keys are read. It wraps the persistent store (the Keychain) and keeps what it has read in memory for this
/// session, so a chat turn with many tool calls and follow-up model requests asks macOS for each key at most once.
///
/// - Concurrent reads of the same account are serialised: the first reads the Keychain, the rest wait and use its result.
/// - Writes and deletes update the cache immediately, so a replaced key is used at once and a deleted key is never served.
/// - If macOS denies access, that denial is remembered. Later reads fail instantly instead of re-prompting, until `retryAfterDenial()`.
/// - Secrets are never logged and never appear in thrown errors.
public final class CredentialManager: SecretStore, @unchecked Sendable {
    private enum Entry { case value(String?), denied(Int32) }
    private let base: SecretStore
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var gates: [String: NSLock] = [:]

    public init(_ base: SecretStore) { self.base = base }

    private func gate(_ account: String) -> NSLock {
        lock.withLock { if let g = gates[account] { return g }; let g = NSLock(); gates[account] = g; return g }
    }
    private func cached(_ account: String) -> Entry? { lock.withLock { cache[account] } }
    private func set(_ account: String, _ e: Entry?) { lock.withLock { cache[account] = e } }

    public func read(_ account: String) throws -> String? {
        if let e = cached(account) { return try resolve(e) }
        let g = gate(account); g.lock(); defer { g.unlock() }
        if let e = cached(account) { return try resolve(e) }              // another caller finished while we waited
        do {
            let v = try base.read(account)
            set(account, .value(v))
            return v
        } catch let e as DirectAIError where e.isDenied {
            set(account, .denied({ if case .keychain(let s) = e { return s }; return 0 }()))
            throw e
        }                                                                  // other errors (e.g. a locked Keychain) aren't cached
    }
    private func resolve(_ e: Entry) throws -> String? {
        switch e { case .value(let v): return v; case .denied(let s): throw DirectAIError.keychain(s) }
    }

    public func write(_ account: String, value: String) throws {
        let g = gate(account); g.lock(); defer { g.unlock() }
        do { try base.write(account, value: value); set(account, .value(value)) } catch { set(account, nil); throw error }
    }
    public func delete(_ account: String) throws {
        let g = gate(account); g.lock(); defer { g.unlock() }
        do { try base.delete(account); set(account, .value(nil)) } catch { set(account, nil); throw error }
    }
    /// Existence check that never reads (or prompts for) the secret when it isn't already in memory.
    public func contains(_ account: String) -> Bool {
        if let e = cached(account) { if case .value(let v) = e { return v != nil }; return true }
        return base.contains(account)
    }

    /// Forgets remembered denials so the next read asks macOS again. Call only on an explicit user action (Retry).
    public func retryAfterDenial() {
        lock.withLock { cache = cache.filter { if case .denied = $0.value { return false }; return true } }
    }
    public func isDenied(_ account: String) -> Bool { if case .denied? = cached(account) { true } else { false } }
}
