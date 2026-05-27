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

    /// Rendered height of a node given its column count and collapsed state.
    static func nodeHeight(columnCount: Int, collapsed: Bool) -> CGFloat {
        if collapsed { return headerHeight }
        return headerHeight + bodyVerticalPadding * 2 + CGFloat(max(columnCount, 1)) * rowHeight
    }
}

/// Pure, deterministic auto-layout. v1 places nodes on a grid ordered by their
/// relationship degree (most-connected first) so hub tables cluster toward the
/// top-left. Designed to be swappable for a force-directed engine in a later
/// phase — callers depend only on the `[nodeID: position]` result.
enum ERDLayoutEngine {
    /// Computes a top-left origin for every node. Independent of view state, so
    /// it can be unit-tested without SwiftUI or a database.
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
}

/// Pure geometry shared by the on-screen Canvas and the SVG/image exporters, so
/// node frames and edge endpoints are computed identically everywhere.
enum ERDGeometry {
    /// A node's frame (top-left origin + rendered size) in diagram coordinates.
    static func frame(for node: ERDNode) -> CGRect {
        CGRect(
            x: node.position.x,
            y: node.position.y,
            width: ERDMetrics.nodeWidth,
            height: ERDMetrics.nodeHeight(columnCount: node.columns.count, collapsed: node.isCollapsed)
        )
    }

    /// The point on `rect`'s border along the ray from its center toward `target`.
    static func borderPoint(of rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        if dx == 0, dy == 0 { return center }
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        let scaleX = dx == 0 ? CGFloat.greatestFiniteMagnitude : halfWidth / abs(dx)
        let scaleY = dy == 0 ? CGFloat.greatestFiniteMagnitude : halfHeight / abs(dy)
        let t = min(scaleX, scaleY)
        return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }

    /// Endpoints of the connector between two node frames, each landing on the
    /// facing border so the line appears to run card-edge to card-edge.
    static func connection(from source: CGRect, to target: CGRect) -> (from: CGPoint, to: CGPoint) {
        let targetCenter = CGPoint(x: target.midX, y: target.midY)
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        return (borderPoint(of: source, toward: targetCenter), borderPoint(of: target, toward: sourceCenter))
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
}
