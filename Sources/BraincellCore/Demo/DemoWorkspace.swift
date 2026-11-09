import Foundation
import GRDB

/// Clearly labelled sample content. It goes through the same validation/import pipeline as real AI output,
/// so it is also a fixture for every question type. Never mixed into real courses.
public enum DemoWorkspace {
    public static let courseName = "Demo: COMP 211 (sample data)"

    @discardableResult
    public static func load(into db: AppDatabase) throws -> Course {
        let courses = CourseService(db: db)
        if let existing = try courses.courses().first(where: { $0.name == courseName }) { return existing }
        let c = try courses.createCourse(name: courseName)
        let m2 = try courses.addAssessment(courseId: c.id, name: "Midterm 2", deadline: Calendar.current.date(byAdding: .day, value: 12, to: Date()))
        _ = try courses.addAssessment(courseId: c.id, name: "Final Exam", kind: .final, isCumulative: true)
        let java = try courses.addSkill(courseId: c.id, name: "Java").skill
        let it = try courses.addSkill(courseId: c.id, name: "Java iterators", parentId: java.id).skill
        let gen = try courses.addSkill(courseId: c.id, name: "Generics", parentId: java.id).skill
        let rec = try courses.addSkill(courseId: c.id, name: "Recursion").skill
        try courses.addRelation(from: rec.id, to: it.id, kind: .prerequisite)
        for s in [it, gen] { try courses.addToScope(assessmentId: m2.id, skillId: s.id) }

        let ai = AITaskService(db: db)
        let task = try ai.createGenerationTask(courseId: c.id, assessmentId: m2.id, params: GenerationParams(count: 9))
        let batch = try ai.batches(taskId: task.id)[0]
        _ = try ai.prepare(batchId: batch.id)
        try ai.markExported(batchId: batch.id, method: .clipboard)
        _ = try ai.importResponse(responseJSON.replacingOccurrences(of: "__REQUEST_ID__", with: batch.requestId), targetBatchId: batch.id)
        return c
    }

    static let responseJSON = #"""
    {"schemaVersion":"cramlab.questions.v1","requestId":"__REQUEST_ID__","questions":[
    {"importId":"d1","type":"flashcard","title":"What does Iterator.hasNext() return?","difficulty":1,"learningObjective":"Recall the Iterator contract",
     "content":[{"kind":"markdown","text":"What does `hasNext()` tell you, and does it advance the iterator?"}],
     "answer":{"back":[{"kind":"markdown","text":"Whether another element remains. It does **not** advance the iterator."}]},"evaluation":{"method":"self_review"},
     "hints":["Think about the difference between peeking and consuming."],"solution":[{"kind":"markdown","text":"`hasNext()` is a pure query; `next()` consumes."}],"skills":["Java iterators"],"assessments":["Midterm 2"]},
    {"importId":"d2","type":"single_choice","title":"Which call removes the last element returned by next()?","difficulty":2,"learningObjective":"Know Iterator.remove semantics",
     "content":[{"kind":"markdown","text":"Which method removes the element most recently returned by `next()`?"}],
     "answer":{"choices":[{"id":"a","text":"it.remove()"},{"id":"b","text":"it.delete()"},{"id":"c","text":"list.remove(it)"}],"correctIds":["a"]},"evaluation":{"method":"choice"},
     "hints":["It is part of the Iterator interface."],"solution":[{"kind":"markdown","text":"`Iterator.remove()` removes the last element returned by `next()`."}],"skills":["Java iterators"]},
    {"importId":"d3","type":"multiple_select","title":"Which are valid generic declarations?","difficulty":2,"learningObjective":"Read generic syntax",
     "content":[{"kind":"markdown","text":"Select all valid declarations."}],
     "answer":{"choices":[{"id":"a","text":"List<String> xs;"},{"id":"b","text":"List<int> ys;"},{"id":"c","text":"Map<String, Integer> m;"}],"correctIds":["a","c"]},"evaluation":{"method":"choice"},
     "hints":["Generics cannot use primitives."],"solution":[{"kind":"markdown","text":"Type arguments must be reference types, so `int` is invalid."}],"skills":["Generics"]},
    {"importId":"d4","type":"short_answer","title":"Name the interface that for-each requires","difficulty":1,"learningObjective":"Connect for-each to Iterable",
     "content":[{"kind":"markdown","text":"A for-each loop can iterate over any object implementing which interface?"}],
     "answer":{"accepted":["Iterable","java.lang.Iterable"],"caseSensitive":false},"evaluation":{"method":"exact"},
     "hints":["It has an iterator() method."],"solution":[{"kind":"markdown","text":"`Iterable<T>`, whose `iterator()` supplies the Iterator."}],"skills":["Java iterators"]},
    {"importId":"d5","type":"numeric","title":"Recursive call count","difficulty":3,"learningObjective":"Count calls of a recursive function",
     "content":[{"kind":"markdown","text":"`f(n)` calls `f(n-1)` once until `n == 0`. How many calls does `f(6)` make in total, including the first?"}],
     "answer":{"value":7,"tolerance":0,"verificationExpression":"6+1"},"evaluation":{"method":"numeric"},
     "hints":["Count n = 6 down to 0."],"solution":[{"kind":"markdown","text":"Calls for n = 6,5,4,3,2,1,0 → 7."}],"skills":["Recursion"]},
    {"importId":"d6","type":"code_tracing","title":"Trace the iterator loop","difficulty":3,"learningObjective":"Trace iterator-driven loops",
     "content":[{"kind":"markdown","text":"What does this print?"},{"kind":"code","language":"java","text":"List<Integer> xs = List.of(1, 2, 3);\nIterator<Integer> it = xs.iterator();\nint sum = 0;\nwhile (it.hasNext()) { sum += it.next(); }\nSystem.out.println(sum);"}],
     "answer":{"expectedOutput":"6","accepted":["6"]},"evaluation":{"method":"exact"},
     "hints":["Add each element once."],"solution":[{"kind":"markdown","text":"1 + 2 + 3 = 6."}],"skills":["Java iterators"]},
    {"importId":"d7","type":"coding","title":"Write a Python generator that yields squares","difficulty":3,"learningObjective":"Write an iterator-like generator",
     "content":[{"kind":"markdown","text":"Read an integer `n` from standard input and print the squares `0, 1, 4, …` up to `(n-1)²`, one per line. (Use a generator inside your solution if you like.)"}],
     "answer":{"language":"python","starterCode":"def squares(n):\n    pass\n\nn = int(input())\n","referenceSolution":"def squares(n):\n    for i in range(n):\n        yield i * i\n\nn = int(input())\nfor v in squares(n):\n    print(v)\n",
       "tests":[{"name":"three","input":"3","expectedOutput":"0\n1\n4"},{"name":"one","input":"1","expectedOutput":"0"},{"name":"zero","input":"0","expectedOutput":""},{"name":"larger (hidden)","input":"6","expectedOutput":"0\n1\n4\n9\n16\n25","hidden":true}]},
     "evaluation":{"method":"code_tests"},
     "hints":["Use the yield keyword."],"solution":[{"kind":"code","language":"python","text":"def squares(n):\n    for i in range(n):\n        yield i * i"}],"skills":["Java iterators"]},
    {"importId":"d8","type":"long_form","title":"Explain fail-fast iterators","difficulty":4,"learningObjective":"Explain ConcurrentModificationException",
     "content":[{"kind":"markdown","text":"Explain why modifying a list during iteration can throw `ConcurrentModificationException`."}],
     "answer":{},"evaluation":{"method":"ai_rubric","rubric":[{"criterion":"Mentions the modification count check","points":2},{"criterion":"Gives a correct example","points":2}]},
     "hints":["Iterators remember a count."],"solution":[{"kind":"markdown","text":"The iterator snapshots `modCount`; a structural change outside the iterator makes the check fail."}],"skills":["Java iterators"]},
    {"importId":"d9","type":"derivation_proof","title":"Prove the sum of the first n odd numbers","difficulty":5,"learningObjective":"Prove by induction",
     "content":[{"kind":"markdown","text":"Prove by induction that:"},{"kind":"math","latex":"\\sum_{k=1}^{n}(2k-1)=n^2"}],
     "answer":{},"evaluation":{"method":"ai_rubric","rubric":[{"criterion":"Base case","points":1},{"criterion":"Inductive step","points":3}]},
     "hints":["Add (2(n+1)-1) to both sides."],"solution":[{"kind":"math","latex":"n^2 + (2n+1) = (n+1)^2"}],"skills":["Recursion"]}
    ]}
    """#
}
