import Foundation
import CryptoKit

public enum QuestionHashing {
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Identity of a question's substance: type + normalized statement + canonical answer.
    /// Equal hashes in one course = exact duplicates.
    public static func contentHash(_ spec: QuestionSpec) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let answer = (try? enc.encode(spec.answer)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return sha256("\(spec.type.rawValue)|\(normalize(spec.statementText))|\(answer)")
    }

    /// Word 3-shingles with digits masked, so a question that only swaps numbers has (nearly) the same shape as the original.
    public static func shingles(_ spec: QuestionSpec) -> Set<String> {
        let masked = String(normalize(spec.statementText).map { (c: Character) -> Character in c.isNumber ? "#" : c })
        let cleaned: [String] = masked.split(separator: " ").map { (w: Substring) -> String in String(w.filter { (c: Character) in c.isLetter || c == "#" }) }.filter { !$0.isEmpty }
        guard cleaned.count >= 3 else { return Set(cleaned) }
        return Set((0...(cleaned.count - 3)).map { cleaned[$0...($0 + 2)].joined(separator: " ") })
    }
    public static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
    /// Conservative: only near-identical statements (>= 0.85 after masking numbers). Sharing a topic or reasoning skill never triggers this.
    public static let nearDuplicateThreshold = 0.85

    public static func normalizedTitle(_ s: String) -> String { normalize(s) }

    public static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
