import Foundation
@testable import BraincellCore

/// Deterministic AI-response fixtures; no live ChatGPT involved.
enum Fx {
    static func md(_ s: String) -> [String: Any] { ["kind": "markdown", "text": s] }

    static func base(_ type: String, title: String, answer: [String: Any], method: String,
                     skills: [String] = ["Java iterators"], extra: [String: Any] = [:]) -> [String: Any] {
        var q: [String: Any] = [
            "importId": title, "type": type, "title": title, "difficulty": 2, "learningObjective": "Understand \(title)",
            "content": [md("Statement for \(title)")], "answer": answer, "evaluation": ["method": method],
            "hints": ["Think about hasNext()"], "solution": [md("Because.")], "skills": skills,
        ]
        for (k, v) in extra { q[k] = v }
        return q
    }

    static var all: [[String: Any]] {
        [
            base("flashcard", title: "FC", answer: ["back": [md("back")]], method: "self_review"),
            base("single_choice", title: "SC", answer: ["choices": [["id": "a", "text": "A"], ["id": "b", "text": "B"]], "correctIds": ["a"]], method: "choice"),
            base("multiple_select", title: "MS", answer: ["choices": [["id": "a", "text": "A"], ["id": "b", "text": "B"], ["id": "c", "text": "C"]], "correctIds": ["a", "c"]], method: "choice"),
            base("short_answer", title: "SA", answer: ["accepted": ["hasNext"], "caseSensitive": false], method: "exact"),
            base("numeric", title: "NU", answer: ["value": 14, "tolerance": 0.01, "verificationExpression": "2+3*4"], method: "numeric"),
            base("code_tracing", title: "CT", answer: ["expectedOutput": "3"], method: "exact",
                 extra: ["content": [md("What prints?"), ["kind": "code", "language": "python", "text": "print(1+2)"]]]),
            base("coding", title: "CO", answer: ["language": "java", "starterCode": "class A {}", "referenceSolution": "class A { }"], method: "self_review"),
            base("long_form", title: "LF", answer: [:], method: "ai_rubric", extra: ["evaluation": ["method": "ai_rubric", "rubric": [["criterion": "clear", "points": 2]]]]),
            base("derivation_proof", title: "DP", answer: [:], method: "ai_rubric",
                 extra: ["content": [md("Prove $a^2\\ge 0$"), ["kind": "math", "latex": "a^2 \\ge 0"]],
                         "evaluation": ["method": "ai_rubric", "rubric": [["criterion": "valid", "points": 3]]]]),
        ]
    }

    static func envelope(_ requestId: String, _ questions: [[String: Any]], version: String = QuestionSchema.version) -> String {
        let o: [String: Any] = ["schemaVersion": version, "requestId": requestId, "questions": questions]
        return String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)!
    }
}
