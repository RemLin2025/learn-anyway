import Foundation
import GRDB

public enum CodeVerification: Sendable, Equatable {
    /// The reference solution passes every test: the tests and the reference agree with each other.
    case verified
    case failed([String])
    case compileError(String)
}

/// "Correctness verification" for coding questions: run the question's own reference solution against its own tests.
/// Two artifacts written independently (solution and tests) agreeing is far better than nothing, but it does not prove
/// the tests match the problem statement; that is why this sets `computed` verification, not a human sign-off.
public struct CodeVerificationService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    @discardableResult
    public func verify(questionId: UUID, runner: any CodeRunner) async throws -> CodeVerification {
        let (spec, _): (QuestionSpec, Question) = try db.read { d in
            guard let q = try Question.fetchOne(d, key: questionId), let spec = try QuestionRevision.fetchOne(d, key: q.currentRevisionId)?.spec else { throw QuestionError.notFound }
            return (spec, q)
        }
        guard spec.evaluation.method == .codeTests, let tests = spec.answer.tests, !tests.isEmpty, let ref = spec.answer.referenceSolution, !ref.isEmpty else {
            throw EvaluationError.notCodeTests
        }
        let lang = spec.answer.language ?? "python"
        let file = CodeFile(name: PracticeService.defaultFileName(lang), language: lang, content: ref)
        let report = await runner.runTests(CodeRunRequest(files: [file], language: lang), tests: tests)
        let result: CodeVerification
        switch report {
        case .unavailable(let r): throw EvaluationError.runnerUnavailable(r)
        case .internalError(let m): throw EvaluationError.runnerUnavailable("The test runner failed (\(m)).")
        case .compileError(let m): result = .compileError(String(m.prefix(300)))
        case .ran(let outcomes):
            let bad = outcomes.filter { $0.status != .passed }
            result = bad.isEmpty ? .verified : .failed(bad.map { "\($0.name): \($0.status.rawValue)" })
        }
        try db.write { d in
            guard var q = try Question.fetchOne(d, key: questionId) else { return }
            var notes = q.notes.filter { !$0.hasPrefix("Reference solution") }
            switch result {
            case .verified:
                if notes.isEmpty { q.readiness = .verified; q.verificationSource = .computed }
            case .failed(let f):
                notes.append("Reference solution fails \(f.count) of its own tests (\(f.prefix(3).joined(separator: "; "))). The tests or the solution are wrong.")
                q.readiness = .needsReview; q.verificationSource = .none
            case .compileError(let m):
                notes.append("Reference solution doesn’t compile: \(m)")
                q.readiness = .needsReview; q.verificationSource = .none
            }
            q.reviewNotes = QuestionService.encodeNotes(notes)
            try q.update(d)
        }
        return result
    }
}
