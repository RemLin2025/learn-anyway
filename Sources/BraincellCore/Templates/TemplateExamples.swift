import Foundation

/// Realistic sample questions the gallery renders through the same `RenderBuilder` a real set uses, so a preview is exactly what the template produces.
public enum TemplateExamples {
    public static let questions: [QuestionSpec] = [
        QuestionSpec(type: .singleChoice, title: "Conditional probability from a joint table", difficulty: 2, learningObjective: "Condition on a marginal",
                     content: [.markdown("Let $(X,Y)$ have joint pmf with $P(X=1,Y=1)=0.2$ and $P(X=1)=0.5$. What is $P(Y=1\\mid X=1)$?")],
                     answer: AnswerSpec(choices: [Choice(id: "a", text: "$0.1$"), Choice(id: "b", text: "$0.4$"), Choice(id: "c", text: "$0.5$"), Choice(id: "d", text: "$0.7$")], correctIds: ["b"]), evaluation: EvaluationSpec(method: .choice),
                     hints: ["Divide the joint probability by the marginal."], solution: [.markdown("$P(Y=1\\mid X=1)=\\dfrac{P(X=1,Y=1)}{P(X=1)}=\\dfrac{0.2}{0.5}=0.4$.")]),
        QuestionSpec(type: .numeric, title: "Mean of a geometric distribution", difficulty: 3, learningObjective: "Recall E[X]=1/p",
                     content: [.markdown("A trial succeeds with probability $p=0.2$. Let $X$ be the number of trials until the first success."), ContentBlock(kind: .math, latex: "E[X]=\\sum_{k=1}^{\\infty} k\\,p(1-p)^{k-1}"), .markdown("Compute $E[X]$.")],
                     answer: AnswerSpec(value: 5, tolerance: 0.001), evaluation: EvaluationSpec(method: .numeric), hints: ["Use the closed form."], solution: [.markdown("$E[X]=\\dfrac{1}{p}=5$.")]),
        QuestionSpec(type: .shortAnswer, title: "Independence versus zero correlation", difficulty: 2, learningObjective: "Distinguish concepts",
                     content: [.markdown("State whether zero correlation implies independence, in one sentence.")], answer: AnswerSpec(accepted: ["No"]), evaluation: EvaluationSpec(method: .exact),
                     hints: ["Think of $Y=X^2$."], solution: [.markdown("No: $Y=X^2$ with $X$ symmetric is uncorrelated with $X$ but dependent on it.")]),
        QuestionSpec(type: .flashcard, title: "Variance identity", difficulty: 1, learningObjective: "Recall",
                     content: [.markdown("Write $\\operatorname{Var}(X)$ in terms of moments.")], answer: AnswerSpec(back: [.markdown("$\\operatorname{Var}(X)=E[X^2]-\\left(E[X]\\right)^2$")]), evaluation: EvaluationSpec(method: .selfReview)),
    ]
}
