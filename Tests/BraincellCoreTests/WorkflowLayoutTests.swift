import Testing
import Foundation
import CoreGraphics
@testable import BraincellCore

@Suite struct WorkflowLayoutTests {
    static let allGroups = Set(TaskGroup.allCases)
    func layouts() -> [(String, WorkflowCanvasLayout)] {
        [("collapsed", .make(expanded: [])), ("all", .make(expanded: Self.allGroups))] + TaskGroup.allCases.map { ("only \($0.rawValue)", .make(expanded: [$0])) }
    }
    func segments(_ e: VisualEdge) -> [CGRect] {
        zip(e.points, e.points.dropFirst()).map { a, b in CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }
    }

    @Test func collapsedOverviewShowsOnlyTheDefaultAndCategories() {
        let l = WorkflowCanvasLayout.make(expanded: [])
        #expect(l.nodes.count == 1 + TaskGroup.allCases.count)
        #expect(l.edges.filter { $0.kind == .inheritance }.count == 4)          // Multimedia has no LLM tasks, so no default edge
        #expect(l.node(VisualNode.defaultId) != nil && l.node("quizGeneration") == nil)
    }

    @Test func expandingShowsExactlyThatCategorysTasks() {
        let l = WorkflowCanvasLayout.make(expanded: [.study])
        let tasks = WorkflowTask.all.filter { $0.group == .study }
        #expect(l.nodes.count == 6 + tasks.count && tasks.allSatisfy { l.node($0.id) != nil })
        #expect(WorkflowCanvasLayout.make(expanded: Self.allGroups).nodes.count == 6 + WorkflowTask.all.count)
    }

    @Test func nodesNeverOverlap() {
        for (name, l) in layouts() {
            for (i, a) in l.nodes.enumerated() { for b in l.nodes[(i + 1)...] { #expect(!a.rect.intersects(b.rect), "\(name): \(a.id) overlaps \(b.id)") } }
        }
    }

    @Test func everyEdgeIsOrthogonalAndAvoidsEveryNode() {
        for (name, l) in layouts() {
            for e in l.edges {
                #expect(e.points.count >= 2)
                for (a, b) in zip(e.points, e.points.dropFirst()) { #expect(a.x == b.x || a.y == b.y, "\(name): \(e.id) has a diagonal segment") }
                for s in segments(e) { for n in l.nodes {
                    #expect(!s.insetBy(dx: -0.5, dy: -0.5).intersects(n.rect.insetBy(dx: 1.5, dy: 1.5)), "\(name): \(e.id) crosses \(n.id)")
                } }
            }
        }
    }

    @Test func edgesStartAndEndOnTheirNodes() {
        for (name, l) in layouts() {
            for e in l.edges {
                guard let f = l.node(e.from)?.rect, let t = l.node(e.to)?.rect else { Issue.record("\(name): dangling edge \(e.id)"); continue }
                #expect(f.insetBy(dx: -0.5, dy: -0.5).contains(e.points.first!) && t.insetBy(dx: -0.5, dy: -0.5).contains(e.points.last!), "\(name): \(e.id) endpoints off their nodes")
            }
        }
    }

    @Test func dependencyEdgesMatchTheTaskGraphWhenFullyExpanded() {
        let l = WorkflowCanvasLayout.make(expanded: Self.allGroups)
        let want = Set(WorkflowTask.all.flatMap { t in t.dependsOn.map { "d:\($0)>\(t.id)" } })
        #expect(Set(l.edges.filter { $0.kind == .dependency }.map(\.id)) == want)
        // Inheritance edges exist exactly for LLM tasks.
        let taskTargets = Set(l.edges.filter { $0.kind == .inheritance && !$0.to.hasPrefix("group:") }.map(\.to))
        #expect(taskTargets == Set(WorkflowTask.all.filter { $0.capability == .llm }.map(\.id)))
    }

    @Test func collapsedDependenciesCollapseToCategoryPairsWithoutSelfLoops() {
        let l = WorkflowCanvasLayout.make(expanded: [])
        let deps = l.edges.filter { $0.kind == .dependency }
        #expect(!deps.isEmpty && deps.allSatisfy { $0.from != $0.to && $0.from.hasPrefix("group:") && $0.to.hasPrefix("group:") })
        #expect(Set(deps.map(\.id)).count == deps.count)
    }

    @Test func layoutIsDeterministicAndOffsetsOnlyMoveVisuals() {
        let a = WorkflowCanvasLayout.make(expanded: [.core]), b = WorkflowCanvasLayout.make(expanded: [.core])
        #expect(a.nodes == b.nodes && a.edges == b.edges)
        let moved = WorkflowCanvasLayout.make(expanded: [.core], offsets: ["courseOutline": CGSize(width: 30, height: 20)])
        #expect(moved.node("courseOutline")!.rect == a.node("courseOutline")!.rect.offsetBy(dx: 30, dy: 20))
        #expect(moved.node("lessonContent")!.rect == a.node("lessonContent")!.rect)
        #expect(moved.nodes.map(\.id) == a.nodes.map(\.id))                     // same nodes; only geometry changed
        #expect(moved.edges.filter { $0.to == "courseOutline" }.allSatisfy { moved.node("courseOutline")!.rect.insetBy(dx: -0.5, dy: -0.5).contains($0.points.last!) })
    }

    @Test func batchResolutionMatchesPerTaskResolution() async throws {
        let db = try AppDatabase.inMemory()
        let body = try JSONSerialization.data(withJSONObject: ["data": [["id": "m1"], ["id": "m2"]]])
        let gw = AIGateway(db: db, secrets: InMemorySecretStore(), transport: MockTransport { _ in (body, 200) })
        let (c, _) = try await gw.connect(providerId: "openai", apiKey: "k")
        try gw.store.setDefault(.llm, connection: c.id, model: "m1")
        var r = TaskRoute(task: "answerEvaluation"); r.inherit = false; r.connectionId = c.id; r.modelId = "m2"; try gw.store.save(r)
        var m = TaskRoute(task: "tutoring"); m.manualBridge = true; try gw.store.save(m)
        let all = try gw.resolveAll()
        #expect(all.count == WorkflowTask.all.count)
        for t in WorkflowTask.all {
            let one = try gw.resolve(t), batch = all[t.id]!
            #expect(one.primary?.model.modelId == batch.primary?.model.modelId && one.manual == batch.manual && one.inherited == batch.inherited && one.trace == batch.trace && one.problem == batch.problem, "\(t.id)")
        }
        #expect(all["answerEvaluation"]?.primary?.model.modelId == "m2" && all["tutoring"]?.manual == true && all["quizGeneration"]?.primary?.model.modelId == "m1")
    }
}
