import CoreGraphics
import Foundation

/// Shared geometry for the ERD canvas. Both the layout engine and the SwiftUI
/// node views read these so auto-layout spacing and on-screen sizing agree, and
/// so the SVG/image exporters can reproduce the same metrics.
enum ERDMetrics {
    static let nodeWidth: CGFloat = 220
    static let headerHeight: CGFloat = 34
    static let rowHeight: CGFloat = 22
    /// Vertical padding above/below the column rows inside a node body.
    static let bodyVerticalPadding: CGFloat = 6
    static let gridGapX: CGFloat = 56
    static let gridGapY: CGFloat = 48
    static let canvasMargin: CGFloat = 48
    /// Corner radius for the rounded bends in orthogonal edge connectors.
    static let edgeCornerRadius: CGFloat = 12

    /// Rendered height of a node given its column count and collapsed state.
    static func nodeHeight(columnCount: Int, collapsed: Bool) -> CGFloat {
        if collapsed { return headerHeight }
        return headerHeight + bodyVerticalPadding * 2 + CGFloat(max(columnCount, 1)) * rowHeight
    }

    static func size(of node: ERDNode) -> CGSize {
        CGSize(width: nodeWidth, height: nodeHeight(columnCount: node.columns.count, collapsed: node.isCollapsed))
    }
}

/// Auto-layout for the diagram. The public `layout` is a deterministic
/// force-directed (Fruchterman–Reingold) placement that pulls related tables
/// together and pushes unrelated ones apart, then separates any overlaps — this
/// clusters foreign-key neighbourhoods and keeps relationship lines short and
/// largely un-crossed. A grid seed makes the result stable and reproducible.
enum ERDLayoutEngine {
    /// Computes a top-left origin for every node. Independent of view state, so
    /// it can be unit-tested without SwiftUI or a database.
    static func layout(nodes: [ERDNode], edges: [ERDEdge]) -> [String: CGPoint] {
        guard nodes.count > 1 else { return gridLayout(nodes: nodes, edges: edges) }

        let ids = nodes.map(\.id)
        let sizes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, ERDMetrics.size(of: $0)) })

        // Seed from the grid (deterministic) and work in node-center space.
        let seed = gridLayout(nodes: nodes, edges: edges)
        var positions: [String: CGPoint] = [:]
        for node in nodes {
            let origin = seed[node.id] ?? .zero
            let size = sizes[node.id] ?? .zero
            positions[node.id] = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        }

        // Ideal separation a bit larger than a card so neighbours don't overlap.
        let k = ERDMetrics.nodeWidth * 1.6
        var temperature = k * 2
        let iterations = 400
        let edgePairs = edges
            .map { ($0.sourceNodeID, $0.targetNodeID) }
            .filter { positions[$0.0] != nil && positions[$0.1] != nil }

        // Bound the drawing area (classic FR frame) so disconnected nodes, which
        // feel only repulsion, can't drift to infinity. Centered on the seed
        // centroid; sized to comfortably hold the node count.
        var boxCenterX: CGFloat = 0
        var boxCenterY: CGFloat = 0
        for id in ids {
            boxCenterX += positions[id]!.x
            boxCenterY += positions[id]!.y
        }
        boxCenterX /= CGFloat(nodes.count)
        boxCenterY /= CGFloat(nodes.count)
        let halfExtent = max(900, CGFloat(Double(nodes.count).squareRoot()) * k)

        for _ in 0 ..< iterations {
            var displacement = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGVector.zero) })

            // Repulsion between every pair of nodes.
            for i in 0 ..< nodes.count {
                for j in (i + 1) ..< nodes.count {
                    let a = ids[i]
                    let b = ids[j]
                    var dx = positions[a]!.x - positions[b]!.x
                    var dy = positions[a]!.y - positions[b]!.y
                    var distance = (dx * dx + dy * dy).squareRoot()
                    if distance < 0.01 {
                        // Deterministic nudge so coincident seeds separate.
                        dx = CGFloat((i % 7) - 3) * 0.5 + 0.1
                        dy = CGFloat((j % 5) - 2) * 0.5 + 0.1
                        distance = max((dx * dx + dy * dy).squareRoot(), 0.01)
                    }
                    let force = k * k / distance
                    displacement[a]!.dx += dx / distance * force
                    displacement[a]!.dy += dy / distance * force
                    displacement[b]!.dx -= dx / distance * force
                    displacement[b]!.dy -= dy / distance * force
                }
            }

            // Attraction along edges.
            for (source, target) in edgePairs {
                let dx = positions[source]!.x - positions[target]!.x
                let dy = positions[source]!.y - positions[target]!.y
                let distance = max((dx * dx + dy * dy).squareRoot(), 0.01)
                let force = distance * distance / k
                displacement[source]!.dx -= dx / distance * force
                displacement[source]!.dy -= dy / distance * force
                displacement[target]!.dx += dx / distance * force
                displacement[target]!.dy += dy / distance * force
            }

            // Gravity toward the centroid. Without it, tables with no foreign
            // keys feel only repulsion and drift off to infinity, blowing up the
            // bounding box (ForceAtlas2's fix). A linear spring keeps every node —
            // connected or not — within a bounded region.
            var centerX: CGFloat = 0
            var centerY: CGFloat = 0
            for id in ids {
                centerX += positions[id]!.x
                centerY += positions[id]!.y
            }
            centerX /= CGFloat(nodes.count)
            centerY /= CGFloat(nodes.count)
            let gravity: CGFloat = 0.3
            for id in ids {
                displacement[id]!.dx += (centerX - positions[id]!.x) * gravity
                displacement[id]!.dy += (centerY - positions[id]!.y) * gravity
            }

            // Move each node, capped by the cooling temperature, then confine it
            // to the drawing frame so nothing escapes the bounded area.
            for id in ids {
                let vector = displacement[id]!
                let length = max((vector.dx * vector.dx + vector.dy * vector.dy).squareRoot(), 0.01)
                let step = min(length, temperature)
                var x = positions[id]!.x + vector.dx / length * step
                var y = positions[id]!.y + vector.dy / length * step
                x = min(max(x, boxCenterX - halfExtent), boxCenterX + halfExtent)
                y = min(max(y, boxCenterY - halfExtent), boxCenterY + halfExtent)
                positions[id] = CGPoint(x: x, y: y)
            }
            temperature = max(temperature * 0.96, k * 0.05)
        }

        resolveOverlaps(&positions, sizes: sizes, ids: ids)
        return normalize(positions, sizes: sizes, ids: ids)
    }

    /// Deterministic grid placement ordered by relationship degree. Used as the
    /// seed for force-directed layout and as the fallback for trivial diagrams.
    static func gridLayout(nodes: [ERDNode], edges: [ERDEdge]) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }

        var degree: [String: Int] = [:]
        for edge in edges {
            degree[edge.sourceNodeID, default: 0] += 1
            degree[edge.targetNodeID, default: 0] += 1
        }

        // Most-connected first; break ties by name for a stable layout.
        let ordered = nodes.sorted { lhs, rhs in
            let dl = degree[lhs.id] ?? 0
            let dr = degree[rhs.id] ?? 0
            if dl != dr { return dl > dr }
            return lhs.name < rhs.name
        }

        let columns = max(1, Int(Double(ordered.count).squareRoot().rounded(.up)))
        var positions: [String: CGPoint] = [:]
        var x = ERDMetrics.canvasMargin
        var y = ERDMetrics.canvasMargin
        var column = 0
        var rowMaxHeight: CGFloat = 0

        for node in ordered {
            positions[node.id] = CGPoint(x: x, y: y)
            let height = ERDMetrics.nodeHeight(columnCount: node.columns.count, collapsed: node.isCollapsed)
            rowMaxHeight = max(rowMaxHeight, height)
            column += 1
            if column >= columns {
                column = 0
                x = ERDMetrics.canvasMargin
                y += rowMaxHeight + ERDMetrics.gridGapY
                rowMaxHeight = 0
            } else {
                x += ERDMetrics.nodeWidth + ERDMetrics.gridGapX
            }
        }
        return positions
    }

    /// Separates overlapping cards by pushing pairs apart along their smaller
    /// overlap axis, leaving a uniform gap. Operates on node centers in place.
    private static func resolveOverlaps(
        _ positions: inout [String: CGPoint],
        sizes: [String: CGSize],
        ids: [String],
        iterations: Int = 80
    ) {
        let gap: CGFloat = 36
        for _ in 0 ..< iterations {
            var moved = false
            for i in 0 ..< ids.count {
                for j in (i + 1) ..< ids.count {
                    let a = ids[i]
                    let b = ids[j]
                    let sizeA = sizes[a]!
                    let sizeB = sizes[b]!
                    let dx = positions[b]!.x - positions[a]!.x
                    let dy = positions[b]!.y - positions[a]!.y
                    let overlapX = (sizeA.width + sizeB.width) / 2 + gap - abs(dx)
                    let overlapY = (sizeA.height + sizeB.height) / 2 + gap - abs(dy)
                    guard overlapX > 0, overlapY > 0 else { continue }
                    moved = true
                    if overlapX < overlapY {
                        let shift = overlapX / 2 * (dx < 0 ? -1 : 1)
                        positions[a]!.x -= shift
                        positions[b]!.x += shift
                    } else {
                        let shift = overlapY / 2 * (dy < 0 ? -1 : 1)
                        positions[a]!.y -= shift
                        positions[b]!.y += shift
                    }
                }
            }
            if !moved { break }
        }
    }

    /// Shifts node centers into the positive quadrant (with a margin) and
    /// converts them back to top-left origins.
    private static func normalize(
        _ positions: [String: CGPoint],
        sizes: [String: CGSize],
        ids: [String]
    ) -> [String: CGPoint] {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        for id in ids {
            minX = min(minX, positions[id]!.x - sizes[id]!.width / 2)
            minY = min(minY, positions[id]!.y - sizes[id]!.height / 2)
        }
        let offsetX = ERDMetrics.canvasMargin - minX
        let offsetY = ERDMetrics.canvasMargin - minY
        var result: [String: CGPoint] = [:]
        for id in ids {
            result[id] = CGPoint(
                x: positions[id]!.x - sizes[id]!.width / 2 + offsetX,
                y: positions[id]!.y - sizes[id]!.height / 2 + offsetY
            )
        }
        return result
    }
}

/// Pure geometry shared by the on-screen Canvas and the SVG/image exporters, so
/// node frames and edge routes are computed identically everywhere.
enum ERDGeometry {
    /// One routed relationship: the ordered waypoints (first = child border,
    /// last = parent border) and a stroked path with rounded corners.
    struct Route {
        let points: [CGPoint]
        let path: CGPath
    }

    /// A node's frame (top-left origin + rendered size) in diagram coordinates.
    static func frame(for node: ERDNode) -> CGRect {
        CGRect(
            x: node.position.x,
            y: node.position.y,
            width: ERDMetrics.nodeWidth,
            height: ERDMetrics.nodeHeight(columnCount: node.columns.count, collapsed: node.isCollapsed)
        )
    }

    /// Routes an orthogonal connector between two card frames. Connects on the
    /// facing left/right sides when the cards are mostly side-by-side, or
    /// top/bottom when mostly stacked, with a single mid bend and rounded
    /// corners — the standard ERD look.
    static func route(from source: CGRect, to target: CGRect) -> Route {
        let points = waypoints(from: source, to: target)
        return Route(points: points, path: roundedPath(points, radius: ERDMetrics.edgeCornerRadius))
    }

    private static func waypoints(from source: CGRect, to target: CGRect) -> [CGPoint] {
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        let targetCenter = CGPoint(x: target.midX, y: target.midY)
        let dx = targetCenter.x - sourceCenter.x
        let dy = targetCenter.y - sourceCenter.y

        if abs(dx) >= abs(dy) {
            // Side-by-side: exit/enter on the left or right edges.
            let from = CGPoint(x: dx >= 0 ? source.maxX : source.minX, y: sourceCenter.y)
            let to = CGPoint(x: dx >= 0 ? target.minX : target.maxX, y: targetCenter.y)
            let midX = (from.x + to.x) / 2
            return [from, CGPoint(x: midX, y: from.y), CGPoint(x: midX, y: to.y), to]
        } else {
            // Stacked: exit/enter on the top or bottom edges.
            let from = CGPoint(x: sourceCenter.x, y: dy >= 0 ? source.maxY : source.minY)
            let to = CGPoint(x: targetCenter.x, y: dy >= 0 ? target.minY : target.maxY)
            let midY = (from.y + to.y) / 2
            return [from, CGPoint(x: from.x, y: midY), CGPoint(x: to.x, y: midY), to]
        }
    }

    /// Builds a path through `points` with rounded corners of up to `radius`
    /// (clamped to the shorter adjacent segment so tight bends stay valid).
    static func roundedPath(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        for index in 1 ..< (points.count - 1) {
            let previous = points[index - 1]
            let corner = points[index]
            let next = points[index + 1]
            let limit = min(distance(previous, corner), distance(corner, next)) / 2
            path.addArc(tangent1End: corner, tangent2End: next, radius: min(radius, limit))
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Total drawable size needed to contain every node frame, plus a margin.
    /// Pass only the nodes that are actually drawn (e.g. non-hidden).
    static func contentBounds(of nodes: [ERDNode]) -> CGSize {
        guard !nodes.isEmpty else { return CGSize(width: 480, height: 320) }
        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        for node in nodes {
            let rect = frame(for: node)
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }
        return CGSize(width: maxX + ERDMetrics.canvasMargin, height: maxY + ERDMetrics.canvasMargin)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// Shortest distance from a point to a polyline — used to hit-test which
    /// relationship line the cursor is hovering.
    static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else {
            guard let only = points.first else { return .greatestFiniteMagnitude }
            return hypot(point.x - only.x, point.y - only.y)
        }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 0 ..< points.count - 1 {
            best = min(best, pointSegmentDistance(point, points[index], points[index + 1]))
        }
        return best
    }

    private static func pointSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
