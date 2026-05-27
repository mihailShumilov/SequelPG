import CoreGraphics
import Foundation

/// Obstacle-avoiding orthogonal edge router for the ERD. Routes every foreign-key
/// connector through the corridors *between* table cards using A* on a coordinate
/// grid, so a relationship line never passes through a table. Attach points are
/// distributed along each card side and a turn penalty plus deterministic
/// routing order keep the lines tidy and reduce (though cannot fully eliminate)
/// line-to-line crossings.
///
/// Pure and deterministic — no SwiftUI, no database — so it is unit-testable and
/// shared by the on-screen Canvas and the SVG/PDF exporters.
enum ERDRouter {
    /// Distance kept between routed lines and card edges. Also the corridor
    /// half-width; the layout engine leaves larger gaps than this so corridors
    /// always exist.
    static let clearance: CGFloat = 16
    private static let turnPenalty: CGFloat = 60
    /// Cost added per already-routed line a candidate segment would cross.
    private static let crossingPenalty: CGFloat = 200

    enum Side: Hashable {
        case left, right, top, bottom
        var isHorizontal: Bool { self == .left || self == .right }
    }

    /// Routes all edges. Returns a route per edge id; edges whose endpoints are
    /// missing from `nodeFrames` are skipped.
    static func routes(nodeFrames: [String: CGRect], edges: [ERDEdge]) -> [String: ERDGeometry.Route] {
        let obstacles = Array(nodeFrames.values)
        guard !obstacles.isEmpty, !edges.isEmpty else { return [:] }

        // Route shortest connections first so they claim direct paths and longer
        // ones detour; ties broken by id for determinism.
        let routable = edges
            .filter { nodeFrames[$0.sourceNodeID] != nil && nodeFrames[$0.targetNodeID] != nil }
            .sorted { lhs, rhs in
                let dl = centerDistance(lhs, nodeFrames)
                let dr = centerDistance(rhs, nodeFrames)
                if dl != dr { return dl < dr }
                return lhs.id < rhs.id
            }

        // Resolve attach points (distributed along each card side) and stubs.
        let attachments = attachmentPoints(for: routable, nodeFrames: nodeFrames)

        // Build the routing grid from card-edge corridors plus attach/stub lines.
        var xValues = Set<CGFloat>()
        var yValues = Set<CGFloat>()
        for rect in obstacles {
            xValues.insert(rect.minX - clearance)
            xValues.insert(rect.maxX + clearance)
            yValues.insert(rect.minY - clearance)
            yValues.insert(rect.maxY + clearance)
        }
        for attachment in attachments.values {
            xValues.insert(attachment.source.attach.x); xValues.insert(attachment.source.stub.x)
            yValues.insert(attachment.source.attach.y); yValues.insert(attachment.source.stub.y)
            xValues.insert(attachment.target.attach.x); xValues.insert(attachment.target.stub.x)
            yValues.insert(attachment.target.attach.y); yValues.insert(attachment.target.stub.y)
        }
        // Add extra lanes inside wide gaps so parallel lines can spread out.
        let xs = withLanes(xValues.sorted())
        let ys = withLanes(yValues.sorted())

        var result: [String: ERDGeometry.Route] = [:]
        var used: [(CGPoint, CGPoint)] = [] // segments already routed, for crossing penalty
        for edge in routable {
            guard let ends = attachments[edge.id] else { continue }
            let interior = astar(
                from: ends.source.stub, to: ends.target.stub,
                xs: xs, ys: ys, obstacles: obstacles, used: used
            )
            let points: [CGPoint]
            if let interior, interior.count >= 2 {
                points = simplify([ends.source.attach] + interior + [ends.target.attach])
            } else {
                // No grid path found — fall back to a direct stubbed connector.
                points = simplify([ends.source.attach, ends.source.stub, ends.target.stub, ends.target.attach])
            }
            result[edge.id] = ERDGeometry.Route(
                points: points,
                path: ERDGeometry.roundedPath(points, radius: ERDMetrics.edgeCornerRadius)
            )
            for index in 0 ..< points.count - 1 {
                used.append((points[index], points[index + 1]))
            }
        }
        return result
    }

    private static func centerDistance(_ edge: ERDEdge, _ frames: [String: CGRect]) -> CGFloat {
        guard let s = frames[edge.sourceNodeID], let t = frames[edge.targetNodeID] else {
            return .greatestFiniteMagnitude
        }
        return abs(s.midX - t.midX) + abs(s.midY - t.midY)
    }

    /// Inserts a lane line in the middle of every wide gap between adjacent grid
    /// coordinates, giving the router parallel channels to spread lines across.
    private static func withLanes(_ coords: [CGFloat]) -> [CGFloat] {
        guard coords.count > 1 else { return coords }
        var out: [CGFloat] = []
        for index in 0 ..< coords.count {
            out.append(coords[index])
            if index < coords.count - 1 {
                let gap = coords[index + 1] - coords[index]
                if gap > 4 * clearance {
                    out.append((coords[index] + coords[index + 1]) / 2)
                }
            }
        }
        return out
    }

    // MARK: - Attach points

    private struct Anchor {
        let attach: CGPoint
        let stub: CGPoint
    }

    private struct Attachment {
        let source: Anchor
        let target: Anchor
    }

    private struct SideKey: Hashable {
        let nodeID: String
        let side: Side
    }

    private static func attachmentPoints(
        for edges: [ERDEdge],
        nodeFrames: [String: CGRect]
    ) -> [String: Attachment] {
        // Decide the exit side for each endpoint, then group endpoints by the
        // side they share so we can spread them evenly along that edge.
        struct EndpointRef {
            let edgeID: String
            let isSource: Bool
            let otherCenter: CGPoint
        }
        var sideOf: [String: (source: Side, target: Side)] = [:]
        var groups: [SideKey: [EndpointRef]] = [:]

        for edge in edges {
            guard let s = nodeFrames[edge.sourceNodeID], let t = nodeFrames[edge.targetNodeID] else { continue }
            let sc = CGPoint(x: s.midX, y: s.midY)
            let tc = CGPoint(x: t.midX, y: t.midY)
            let sourceSide = side(from: sc, toward: tc)
            let targetSide = side(from: tc, toward: sc)
            sideOf[edge.id] = (sourceSide, targetSide)
            groups[SideKey(nodeID: edge.sourceNodeID, side: sourceSide), default: []]
                .append(EndpointRef(edgeID: edge.id, isSource: true, otherCenter: tc))
            groups[SideKey(nodeID: edge.targetNodeID, side: targetSide), default: []]
                .append(EndpointRef(edgeID: edge.id, isSource: false, otherCenter: sc))
        }

        var anchors: [String: Anchor] = [:] // key "edgeID#s" / "edgeID#t"
        for (key, refs) in groups {
            guard let frame = nodeFrames[key.nodeID] else { continue }
            // Order endpoints along the side by the position of their counterpart,
            // so lines leaving a side don't immediately swap order and cross.
            let ordered = refs.sorted { lhs, rhs in
                key.side.isHorizontal ? lhs.otherCenter.y < rhs.otherCenter.y : lhs.otherCenter.x < rhs.otherCenter.x
            }
            let count = ordered.count
            for (index, ref) in ordered.enumerated() {
                let fraction = CGFloat(index + 1) / CGFloat(count + 1)
                anchors[anchorKey(ref.edgeID, ref.isSource)] = anchor(on: key.side, of: frame, fraction: fraction)
            }
        }

        var attachments: [String: Attachment] = [:]
        for edge in edges {
            guard
                let source = anchors[anchorKey(edge.id, true)],
                let target = anchors[anchorKey(edge.id, false)]
            else { continue }
            attachments[edge.id] = Attachment(source: source, target: target)
        }
        return attachments
    }

    private static func anchorKey(_ edgeID: String, _ isSource: Bool) -> String {
        "\(edgeID)#\(isSource ? "s" : "t")"
    }

    private static func side(from center: CGPoint, toward other: CGPoint) -> Side {
        let dx = other.x - center.x
        let dy = other.y - center.y
        if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
        return dy >= 0 ? .bottom : .top
    }

    private static func anchor(on side: Side, of frame: CGRect, fraction: CGFloat) -> Anchor {
        switch side {
        case .left:
            let y = frame.minY + frame.height * fraction
            return Anchor(attach: CGPoint(x: frame.minX, y: y), stub: CGPoint(x: frame.minX - clearance, y: y))
        case .right:
            let y = frame.minY + frame.height * fraction
            return Anchor(attach: CGPoint(x: frame.maxX, y: y), stub: CGPoint(x: frame.maxX + clearance, y: y))
        case .top:
            let x = frame.minX + frame.width * fraction
            return Anchor(attach: CGPoint(x: x, y: frame.minY), stub: CGPoint(x: x, y: frame.minY - clearance))
        case .bottom:
            let x = frame.minX + frame.width * fraction
            return Anchor(attach: CGPoint(x: x, y: frame.maxY), stub: CGPoint(x: x, y: frame.maxY + clearance))
        }
    }

    // MARK: - A* on the coordinate grid

    private static func astar(
        from start: CGPoint,
        to goal: CGPoint,
        xs: [CGFloat],
        ys: [CGFloat],
        obstacles: [CGRect],
        used: [(CGPoint, CGPoint)]
    ) -> [CGPoint]? {
        guard
            let startI = index(of: start.x, in: xs), let startJ = index(of: start.y, in: ys),
            let goalI = index(of: goal.x, in: xs), let goalJ = index(of: goal.y, in: ys)
        else {
            return nil
        }

        let columns = xs.count
        let rows = ys.count
        // State = grid cell + entry direction (0 none, 1 horizontal, 2 vertical),
        // so the turn penalty can be charged correctly.
        func key(_ i: Int, _ j: Int, _ dir: Int) -> Int { (i * rows + j) * 3 + dir }

        var gScore: [Int: CGFloat] = [:]
        var cameFrom: [Int: Int] = [:]
        var heap = MinHeap()
        var counter = 0

        let startKey = key(startI, startJ, 0)
        gScore[startKey] = 0
        heap.push(.init(
            priority: heuristic(startI, startJ, goalI, goalJ, xs, ys),
            order: counter, i: startI, j: startJ, dir: 0, g: 0
        ))
        counter += 1

        while let current = heap.pop() {
            if current.i == goalI, current.j == goalJ {
                return reconstruct(cameFrom: cameFrom, lastKey: key(current.i, current.j, current.dir), xs: xs, ys: ys, rows: rows)
            }
            let currentKey = key(current.i, current.j, current.dir)
            // Skip stale heap entries.
            if let best = gScore[currentKey], best < current.g { continue }

            let neighbors = [(current.i - 1, current.j), (current.i + 1, current.j),
                             (current.i, current.j - 1), (current.i, current.j + 1)]
            for (ni, nj) in neighbors {
                guard ni >= 0, ni < columns, nj >= 0, nj < rows else { continue }
                let from = CGPoint(x: xs[current.i], y: ys[current.j])
                let to = CGPoint(x: xs[ni], y: ys[nj])
                if blocked(from, to, obstacles: obstacles) { continue }
                let newDir = ni == current.i ? 2 : 1
                let turn = current.dir != 0 && current.dir != newDir ? turnPenalty : 0
                let cross = crossingPenalty * CGFloat(crossings(from, to, used: used))
                let tentative = current.g + distance(from, to) + turn + cross
                let neighborKey = key(ni, nj, newDir)
                if let best = gScore[neighborKey], best <= tentative { continue }
                gScore[neighborKey] = tentative
                cameFrom[neighborKey] = currentKey
                let f = tentative + heuristic(ni, nj, goalI, goalJ, xs, ys)
                heap.push(.init(priority: f, order: counter, i: ni, j: nj, dir: newDir, g: tentative))
                counter += 1
            }
        }
        return nil
    }

    private static func reconstruct(
        cameFrom: [Int: Int],
        lastKey: Int,
        xs: [CGFloat],
        ys: [CGFloat],
        rows: Int
    ) -> [CGPoint] {
        var points: [CGPoint] = []
        var key: Int? = lastKey
        while let current = key {
            let cell = current / 3
            let i = cell / rows
            let j = cell % rows
            points.append(CGPoint(x: xs[i], y: ys[j]))
            key = cameFrom[current]
        }
        return points.reversed()
    }

    private static func heuristic(_ i: Int, _ j: Int, _ gi: Int, _ gj: Int, _ xs: [CGFloat], _ ys: [CGFloat]) -> CGFloat {
        abs(xs[i] - xs[gi]) + abs(ys[j] - ys[gj])
    }

    /// Number of already-routed segments the axis-aligned segment a→b crosses
    /// perpendicularly (interior intersections only). Parallel/collinear overlaps
    /// are ignored — only true crossings are penalized.
    private static func crossings(_ a: CGPoint, _ b: CGPoint, used: [(CGPoint, CGPoint)]) -> Int {
        let horizontal = abs(a.y - b.y) < 0.5
        var count = 0
        for (c, d) in used {
            let usedHorizontal = abs(c.y - d.y) < 0.5
            if horizontal == usedHorizontal { continue } // parallel — not a crossing
            if horizontal {
                let y = a.y
                let x0 = min(a.x, b.x), x1 = max(a.x, b.x)
                let vx = c.x
                let vy0 = min(c.y, d.y), vy1 = max(c.y, d.y)
                if vx > x0, vx < x1, y > vy0, y < vy1 { count += 1 }
            } else {
                let x = a.x
                let y0 = min(a.y, b.y), y1 = max(a.y, b.y)
                let hy = c.y
                let hx0 = min(c.x, d.x), hx1 = max(c.x, d.x)
                if hy > y0, hy < y1, x > hx0, x < hx1 { count += 1 }
            }
        }
        return count
    }

    /// True if the axis-aligned segment a→b passes through any card (inflated by
    /// just under `clearance`, so corridor lines exactly at ±clearance stay free).
    private static func blocked(_ a: CGPoint, _ b: CGPoint, obstacles: [CGRect]) -> Bool {
        let inset = clearance - 1
        let minX = min(a.x, b.x)
        let maxX = max(a.x, b.x)
        let minY = min(a.y, b.y)
        let maxY = max(a.y, b.y)
        for obstacle in obstacles {
            let r = obstacle.insetBy(dx: -inset, dy: -inset)
            if maxX > r.minX, minX < r.maxX, maxY > r.minY, minY < r.maxY {
                return true
            }
        }
        return false
    }

    // MARK: - Path cleanup

    private static func simplify(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result: [CGPoint] = [points[0]]
        for index in 1 ..< points.count - 1 {
            guard let previous = result.last else { continue }
            let current = points[index]
            let next = points[index + 1]
            // Drop duplicates and collinear midpoints.
            if approx(previous, current) { continue }
            let collinearX = abs(previous.x - current.x) < 0.5 && abs(current.x - next.x) < 0.5
            let collinearY = abs(previous.y - current.y) < 0.5 && abs(current.y - next.y) < 0.5
            if collinearX || collinearY { continue }
            result.append(current)
        }
        if let last = points.last, !approx(result.last ?? last, last) {
            result.append(last)
        }
        return result
    }

    private static func approx(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
    }

    private static func index(of value: CGFloat, in sorted: [CGFloat]) -> Int? {
        sorted.firstIndex { abs($0 - value) < 0.001 }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        abs(a.x - b.x) + abs(a.y - b.y)
    }

    // MARK: - Min-heap

    private struct Element {
        let priority: CGFloat // f = g + heuristic, used for ordering
        let order: Int
        let i: Int
        let j: Int
        let dir: Int
        let g: CGFloat // running cost from start
    }

    private struct MinHeap {
        private var storage: [Element] = []

        var isEmpty: Bool { storage.isEmpty }

        mutating func push(_ element: Element) {
            storage.append(element)
            siftUp(storage.count - 1)
        }

        mutating func pop() -> HeapNode? {
            guard !storage.isEmpty else { return nil }
            storage.swapAt(0, storage.count - 1)
            let removed = storage.removeLast()
            if !storage.isEmpty { siftDown(0) }
            return HeapNode(element: removed)
        }

        private func lessThan(_ a: Element, _ b: Element) -> Bool {
            a.priority != b.priority ? a.priority < b.priority : a.order < b.order
        }

        private mutating func siftUp(_ start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                if lessThan(storage[child], storage[parent]) {
                    storage.swapAt(child, parent)
                    child = parent
                } else {
                    break
                }
            }
        }

        private mutating func siftDown(_ start: Int) {
            var parent = start
            let count = storage.count
            while true {
                let left = parent * 2 + 1
                let right = parent * 2 + 2
                var candidate = parent
                if left < count, lessThan(storage[left], storage[candidate]) { candidate = left }
                if right < count, lessThan(storage[right], storage[candidate]) { candidate = right }
                if candidate == parent { break }
                storage.swapAt(parent, candidate)
                parent = candidate
            }
        }
    }

    /// Popped A* node with the running cost resolved from the heap element.
    private struct HeapNode {
        let i: Int
        let j: Int
        let dir: Int
        let g: CGFloat

        init(element: Element) {
            self.i = element.i
            self.j = element.j
            self.dir = element.dir
            self.g = element.g
        }
    }
}
