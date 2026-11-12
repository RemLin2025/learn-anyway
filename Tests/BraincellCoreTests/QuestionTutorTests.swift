import Testing
import Foundation
import GRDB
@testable import BraincellCore

extension AgentTests {
    static func choiceSpec(why: Bool, partial: Bool = false) -> QuestionSpec {
        let cs = [("a", "T item;", "Declares T and uses it for storage and return."), ("b", "Object item;", "Stores Object, which cannot be returned as T."), ("c", "int item;", "Primitive cannot hold a generic T.")]
        return QuestionSpec(type: .singleChoice, title: "Generic box", difficulty: 2, learningObjective: "generics",
                            content: [.markdown("Which field works?"), ContentBlock(kind: .code, text: "class Box<T> {\n    // ?\n}", language: "java")],
                            answer: AnswerSpec(choices: cs.enumerated().map { Choice(id: $1.0, text: $1.1, why: why && !(partial && $0 == 2) ? $1.2 : nil) }, correctIds: ["a"]),
                            evaluation: EvaluationSpec(method: .choice), solution: [.markdown("Use the declared type parameter.")])
    }

    @Test func answerReviewMarksKeyAndPickInDisplayOrder() {
        let r = AnswerReview(spec: Self.choiceSpec(why: true), selected: ["b"])!
        #expect(r.rows.map(\.label) == ["A", "B", "C"])
        #expect(r.right.map(\.label) == ["A"] && r.yours.map(\.label) == ["B"] && !r.answeredCorrectly)
        #expect(r.rows.map(\.verdict) == ["Correct", "Incorrect (your choice)", "Incorrect"])
        #expect(r.hasPerOptionExplanations)
        #expect(AnswerReview(spec: Self.choiceSpec(why: false), selected: ["a"])!.hasPerOptionExplanations == false)
        #expect(AnswerReview(spec: Self.choiceSpec(why: false), selected: [])!.yours.isEmpty)       // skipped: nothing invented
    }

    @Test func oldQuestionsDecodeWithoutExplanationsAndKeepNoWhyOnEncode() throws {
        let json = #"{"id":"a","text":"x"}"#
        let c = try JSONDecoder().decode(Choice.self, from: Data(json.utf8))
        #expect(c.why == nil)
        #expect(!String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("why"))
    }

    @Test func validatorKeepsCompleteExplanationsAndDropsPartialOnes() {
        func q(_ whys: [String?]) -> [String: Any] {
            let cs = ["A", "B"].enumerated().map { i, t -> [String: Any] in var c: [String: Any] = ["id": t.lowercased(), "text": t]; if i < whys.count, let w = whys[i] { c["why"] = w }; return c }
            return Fx.base("single_choice", title: "SC", answer: ["choices": cs, "correctIds": ["a"]], method: "choice")
        }
        let all = QuestionValidator.validate(entry: q(["because", "since"]), index: 0).question?.spec.answer.choices
        let some = QuestionValidator.validate(entry: q(["because"]), index: 0)
        #expect(all?.map(\.why) == ["because", "since"])
        #expect(some.question?.spec.answer.choices?.allSatisfy { $0.why == nil } == true && !some.hasBlocking && some.readiness != .needsReview)
    }

    @Test func tutorSendsQuestionContextAndKeepsConversationPerAttempt() async throws {
        let seen = LockedBox<[String]>([])
        let e = try await env { sys, user, _ in seen.withLock { $0.append(sys + "\n" + user) }; return "Because T is declared." }
        let svc = QuestionTutorService(db: e.db, gateway: e.ctx.gateway)
        let a1 = UUID(), a2 = UUID(), q = UUID()
        let ctx = TutorContext(questionId: q, topics: ["Generics"], spec: Self.choiceSpec(why: true), selected: ["b"], typedAnswer: "", keyVerified: false)
        let r = try await svc.send(attemptId: a1, context: ctx, text: "Why is my answer wrong?")
        #expect(r.role == "assistant")
        let p = seen.value.joined()
        #expect(p.contains("T item;") && p.contains("Learner's answer: B. Object item;") && p.contains("UNVERIFIED") && p.contains("class Box<T>") && p.contains("Generics"))
        _ = try await svc.send(attemptId: a1, context: ctx, text: "Show a similar example.")
        #expect(try svc.messages(attemptId: a1).map(\.role) == ["user", "assistant", "user", "assistant"])
        #expect(try svc.messages(attemptId: a2).isEmpty)                                          // other attempts are separate
    }

    @Test func tutorFailureKeepsMessageAndRetryDoesNotDuplicateIt() async throws {
        let fail = LockedBox<Bool>(true)
        let e = try await env { _, _, _ in fail.value ? "" : "Here is why." }
        let svc = QuestionTutorService(db: e.db, gateway: e.ctx.gateway)
        let a = UUID()
        let ctx = TutorContext(questionId: UUID(), topics: [], spec: Self.choiceSpec(why: false), selected: ["a"], typedAnswer: "", keyVerified: true)
        await #expect(throws: TutorFailure.invalidResponse) { _ = try await svc.send(attemptId: a, context: ctx, text: "Explain") }
        #expect(try svc.messages(attemptId: a).count == 1)
        fail.withLock { $0 = false }
        _ = try await svc.send(attemptId: a, context: ctx, text: nil)
        #expect(try svc.messages(attemptId: a).map(\.role) == ["user", "assistant"])
    }

    @Test func tutorWithoutAProviderFailsCleanlyWithoutCallingAnything() async throws {
        let e = try await env(connect: false) { _, _, _ in Issue.record("model must not be called"); return "x" }
        let svc = QuestionTutorService(db: e.db, gateway: e.ctx.gateway)
        let ctx = TutorContext(questionId: UUID(), topics: [], spec: Self.choiceSpec(why: false), selected: [], typedAnswer: "", keyVerified: nil)
        do { _ = try await svc.send(attemptId: UUID(), context: ctx, text: "hi"); Issue.record("should throw") }
        catch let f as TutorFailure { if case .noProvider = f {} else { Issue.record("got \(f)") } }
    }
}
