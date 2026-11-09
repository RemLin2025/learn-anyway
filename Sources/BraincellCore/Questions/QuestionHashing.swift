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

    public static func normalizedTitle(_ s: String) -> String { normalize(s) }

    public static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
