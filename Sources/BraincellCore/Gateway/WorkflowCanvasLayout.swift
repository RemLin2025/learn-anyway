import Foundation
import CoreGraphics

/// Pure geometry for the AI Workflow canvas: a layered layout (default model → category columns → tasks) with
/// orthogonal edge routing. No UI types, so it is cached by the view and unit-tested. Visual grouping here never
/// affects routing or execution: it only decides which nodes are drawn.
public enum VisualKind: Hashable, Sendable { case defaultModel, group(TaskGroup), task(String) }
public enum EdgeKind: Hashable, Sendable { case inheritance, dependency }

public struct VisualNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: VisualKind
    public var rect: CGRect
    public static let defaultId = "default.llm"
    public static func groupId(_ g: TaskGroup) -> String { "group:\(g.rawValue)" }
}

public struct VisualEdge: Identifiable, Hashable, Sendable {
    public let id: String
    public let from: String
    public let to: String
    public let kind: EdgeKind
    /// Axis-aligned polyline in canvas coordinates; the renderer rounds the corners.
    public let points: [CGPoint]
}

public struct WorkflowCanvasLayout: Sendable {
    public let nodes: [VisualNode]
    public let edges: [VisualEdge]
    public let bounds: CGRect
    public let nodeIndex: [String: Int]
    public func node(_ id: String) -> VisualNode? { nodeIndex[id].map { nodes[$0] } }

    // Geometry (points). Columns are one per category; gutters carry the vertical edge runs.
    public static let nodeW: CGFloat = 212, taskH: CGFloat = 80, groupH: CGFloat = 96, defaultW: CGFloat = 268, defaultH: CGFloat = 96
    static let pitch: CGFloat = 252, left0: CGFloat = 44, gutter: CGFloat = pitch - nodeW
    static let defaultY: CGFloat = 16, groupY: CGFloat = 176, firstTaskY: CGFloat = 316, rowPitch: CGFloat = 98

    static func leftOf(_ col: Int) -> CGFloat { left0 + CGFloat(col) * pitch }
    static func laneX(_ gutterIndex: Int, _ lane: Int) -> CGFloat { leftOf(gutterIndex) - gutter + 8 + CGFloat(lane % 4) * 6 }

    /// `offsets` are user drags (visual only), applied before routing; `expanded` decides which tasks are drawn.
    public static func make(expanded: Set<TaskGroup>, offsets: [String: CGSize] = [:]) -> WorkflowCanvasLayout {
        var nodes: [VisualNode] = []
        var cols: [String: Int] = [:]
        func shifted(_ id: String, _ r: CGRect) -> CGRect { guard let o = offsets[id] else { return r }; return r.offsetBy(dx: o.width, dy: o.height) }

        let groups = TaskGroup.allCases
        let midCol = groups.count / 2
        let dRect = CGRect(x: leftOf(midCol) + nodeW / 2 - defaultW / 2, y: defaultY, width: defaultW, height: defaultH)
        nodes.append(VisualNode(id: VisualNode.defaultId, kind: .defaultModel, rect: shifted(VisualNode.defaultId, dRect)))
        var taskRects: [String: CGRect] = [:]
        for (c, g) in groups.enumerated() {
            let gid = VisualNode.groupId(g)
            cols[gid] = c
            nodes.append(VisualNode(id: gid, kind: .group(g), rect: shifted(gid, CGRect(x: leftOf(c), y: groupY, width: nodeW, height: groupH))))
            guard expanded.contains(g) else { continue }
            for (j, t) in WorkflowTask.all.filter({ $0.group == g }).enumerated() {
                cols[t.id] = c
                let r = shifted(t.id, CGRect(x: leftOf(c), y: firstTaskY + CGFloat(j) * rowPitch, width: nodeW, height: taskH))
                taskRects[t.id] = r
                nodes.append(VisualNode(id: t.id, kind: .task(t.id), rect: r))
            }
        }
        var index: [String: Int] = [:]
        for (i, n) in nodes.enumerated() { index[n.id] = i }
        func rect(_ id: String) -> CGRect { nodes[index[id]!].rect }
        func taskGroup(_ id: String) -> TaskGroup { WorkflowTask.find(id)!.group }
        /// The node that represents a task right now: itself when its category is open, else the category node.
        func rep(_ taskId: String) -> String { index[taskId] != nil ? taskId : VisualNode.groupId(taskGroup(taskId)) }

        var edges: [VisualEdge] = []
        var lanes: [Int: Int] = [:]
        func nextLane(_ g: Int) -> Int { let l = lanes[g, default: 0]; lanes[g] = l + 1; return l }
        func dedupe(_ p: [CGPoint]) -> [CGPoint] {
            var out: [CGPoint] = []
            for q in p where out.last != q { out.append(q) }
            var i = 1
            while i < out.count - 1 {          // drop collinear middle points
                let a = out[i - 1], b = out[i], c = out[i + 1]
                if (a.x == b.x && b.x == c.x) || (a.y == b.y && b.y == c.y) { out.remove(at: i) } else { i += 1 }
            }
            return out
        }

        // Inheritance: default → category (only categories that contain LLM tasks), category → each LLM task.
        let d = rect(VisualNode.defaultId)
        for g in groups where WorkflowTask.all.contains(where: { $0.group == g && $0.capability == .llm }) {
            let gr = rect(VisualNode.groupId(g)); let bus = min(d.maxY, gr.minY) + (gr.minY - d.maxY) / 2
            edges.append(VisualEdge(id: "i:default:\(g.rawValue)", from: VisualNode.defaultId, to: VisualNode.groupId(g), kind: .inheritance,
                                    points: dedupe([CGPoint(x: d.midX, y: d.maxY), CGPoint(x: d.midX, y: bus), CGPoint(x: gr.midX, y: bus), CGPoint(x: gr.midX, y: gr.minY)])))
            guard expanded.contains(g) else { continue }
            for t in WorkflowTask.all where t.group == g && t.capability == .llm {
                let r = rect(t.id); let tx = gr.minX - 8
                edges.append(VisualEdge(id: "i:\(VisualNode.groupId(g)):\(t.id)", from: VisualNode.groupId(g), to: t.id, kind: .inheritance,
                                        points: dedupe([CGPoint(x: gr.minX, y: gr.midY), CGPoint(x: tx, y: gr.midY), CGPoint(x: tx, y: r.midY), CGPoint(x: r.minX, y: r.midY)])))
            }
        }

        // Dependencies: between the visible representatives of both tasks.
        var seen = Set<String>()
        for t in WorkflowTask.all {
            for dep in t.dependsOn where WorkflowTask.find(dep) != nil {
                let aId = rep(dep), bId = rep(t.id)
                guard aId != bId, seen.insert("\(aId)>\(bId)").inserted else { continue }
                let a = rect(aId), b = rect(bId), ca = cols[aId]!, cb = cols[bId]!
                let pts: [CGPoint]
                if ca == cb {                                   // same column: a C on the right-hand gutter
                    let x = laneX(ca + 1, nextLane(ca + 1))
                    pts = [CGPoint(x: a.maxX, y: a.midY), CGPoint(x: x, y: a.midY), CGPoint(x: x, y: b.midY), CGPoint(x: b.maxX, y: b.midY)]
                } else {
                    let dir = cb > ca ? 1 : -1
                    let sx = dir > 0 ? a.maxX : a.minX, tx = dir > 0 ? b.minX : b.maxX
                    let gA = dir > 0 ? ca + 1 : ca, gB = dir > 0 ? cb : cb + 1
                    let farGroups = abs(a.midY - b.midY) < 1 && abs(ca - cb) > 1
                    if gA == gB {
                        let x = laneX(gA, nextLane(gA))
                        pts = [CGPoint(x: sx, y: a.midY), CGPoint(x: x, y: a.midY), CGPoint(x: x, y: b.midY), CGPoint(x: tx, y: b.midY)]
                    } else if farGroups {                       // distant category nodes: over the top, never through the ones between
                        let l = nextLane(100 + ca), y = a.minY - 12 - CGFloat(l % 3) * 5
                        let ax = a.midX + 30 + CGFloat(l % 3) * 6, bx = b.midX + 30 + CGFloat(l % 3) * 6
                        pts = [CGPoint(x: ax, y: a.minY), CGPoint(x: ax, y: y), CGPoint(x: bx, y: y), CGPoint(x: bx, y: b.minY)]
                    } else {                                    // run along the free gap above the target's row
                        let x1 = laneX(gA, nextLane(gA)), x2 = laneX(gB, nextLane(gB))
                        let gap: CGFloat = { if case .group = nodes[index[bId]!].kind { return 14 }; return b.minY - firstTaskY < 1 ? 20 : 9 }()
                        let gy = b.minY - gap
                        pts = [CGPoint(x: sx, y: a.midY), CGPoint(x: x1, y: a.midY), CGPoint(x: x1, y: gy), CGPoint(x: x2, y: gy), CGPoint(x: x2, y: b.midY), CGPoint(x: tx, y: b.midY)]
                    }
                }
                edges.append(VisualEdge(id: "d:\(aId)>\(bId)", from: aId, to: bId, kind: .dependency, points: dedupe(pts)))
            }
        }
        var content = nodes.map(\.rect).reduce(nodes[0].rect) { $0.union($1) }
        for e in edges { for p in e.points { content = content.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) } }      // edge runs can leave the node box
        let bounds = content.insetBy(dx: -56, dy: -48)
        return WorkflowCanvasLayout(nodes: nodes, edges: edges, bounds: bounds, nodeIndex: index)
    }
}


/// Camera math for "Fit to view": one pure function so it can be tested at any viewport size.
public enum CanvasFit {
    /// Scale and pan that centre `bounds` inside `viewport` with `padding`, never zooming in past `maxScale`.
    /// If the content would need less than `minScale` to fit, it is centred at `minScale` (readability wins over showing everything).
    public static func transform(bounds: CGRect, viewport: CGSize, minScale: CGFloat = 0.2, maxScale: CGFloat = 1, padding: CGFloat = 20) -> (scale: CGFloat, pan: CGSize) {
        guard viewport.width > 0, viewport.height > 0, bounds.width > 0, bounds.height > 0 else { return (1, .zero) }
        let aw = max(1, viewport.width - 2 * padding), ah = max(1, viewport.height - 2 * padding)
        let s = min(maxScale, max(minScale, min(aw / bounds.width, ah / bounds.height)))
        return (s, CGSize(width: (viewport.width - bounds.width * s) / 2 - bounds.minX * s, height: (viewport.height - bounds.height * s) / 2 - bounds.minY * s))
    }
}
