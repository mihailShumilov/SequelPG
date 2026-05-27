import CoreGraphics
import Foundation

/// Serializes an ERD into a standalone SVG document. Pure and deterministic —
/// no SwiftUI, no database, no app appearance — so it unit-tests cleanly and
/// produces identical output for the same diagram. Reuses `ERDMetrics`/
/// `ERDGeometry` so the vector output matches the on-screen layout exactly.
///
/// Uses a fixed light palette (independent of the app's dark/light mode) so
/// exported diagrams read well when embedded in docs or printed.
enum ERDSVGRenderer {
    private enum Palette {
        static let background = "#FAF6EC"
        static let card = "#ECE5D4"
        static let header = "#E2DAC7"
        static let border = "#BEB59C"
        static let edge = "#BEB59C"
        static let ink = "#1A1812"
        static let ink2 = "#403C33"
        static let ink3 = "#6F6959"
        static let primaryKey = "#B08218"
        static let foreignKey = "#2F5FB7"
    }

    private static let fontFamily = "'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, monospace"

    /// Produces a complete `<svg>…</svg>` document string for the given nodes and
    /// edges (already filtered to those that should be drawn).
    static func svg(nodes: [ERDNode], edges: [ERDEdge]) -> String {
        let size = ERDGeometry.contentBounds(of: nodes)
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))

        var body = ""
        body += "<rect x=\"0\" y=\"0\" width=\"\(width)\" height=\"\(height)\" fill=\"\(Palette.background)\"/>\n"
        body += edgeMarkup(nodes: nodes, edges: edges)
        for node in nodes {
            body += nodeMarkup(node)
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" \
        viewBox="0 0 \(width) \(height)" font-family="\(fontFamily)">
        \(body)</svg>
        """
    }

    // MARK: - Edges

    private static func edgeMarkup(nodes: [ERDNode], edges: [ERDEdge]) -> String {
        let frames = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, ERDGeometry.frame(for: $0)) })
        var out = ""
        for edge in edges {
            guard let source = frames[edge.sourceNodeID], let target = frames[edge.targetNodeID] else { continue }
            let ends = ERDGeometry.connection(from: source, to: target)
            let from = ends.from
            let to = ends.to
            out += "<line x1=\"\(num(from.x))\" y1=\"\(num(from.y))\" x2=\"\(num(to.x))\" y2=\"\(num(to.y))\" "
            out += "stroke=\"\(Palette.edge)\" stroke-width=\"1.5\"/>\n"
            out += "<circle cx=\"\(num(from.x))\" cy=\"\(num(from.y))\" r=\"3\" fill=\"\(Palette.foreignKey)\"/>\n"

            let angle = atan2(to.y - from.y, to.x - from.x)
            out += arrowheadMarkup(at: to, angle: angle)
            if edge.cardinality == .oneToOne {
                out += tickMarkup(at: to, angle: angle)
            }
        }
        return out
    }

    private static func arrowheadMarkup(at tip: CGPoint, angle: CGFloat) -> String {
        let length: CGFloat = 9
        let spread: CGFloat = .pi / 7
        let p1 = CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread))
        let p2 = CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread))
        let points = "\(num(tip.x)),\(num(tip.y)) \(num(p1.x)),\(num(p1.y)) \(num(p2.x)),\(num(p2.y))"
        return "<polygon points=\"\(points)\" fill=\"\(Palette.ink3)\"/>\n"
    }

    private static func tickMarkup(at tip: CGPoint, angle: CGFloat) -> String {
        let back: CGFloat = 11
        let half: CGFloat = 5
        let center = CGPoint(x: tip.x - back * cos(angle), y: tip.y - back * sin(angle))
        let perpendicular = angle + .pi / 2
        let a = CGPoint(x: center.x - half * cos(perpendicular), y: center.y - half * sin(perpendicular))
        let b = CGPoint(x: center.x + half * cos(perpendicular), y: center.y + half * sin(perpendicular))
        return "<line x1=\"\(num(a.x))\" y1=\"\(num(a.y))\" x2=\"\(num(b.x))\" y2=\"\(num(b.y))\" "
            + "stroke=\"\(Palette.ink3)\" stroke-width=\"1.5\"/>\n"
    }

    // MARK: - Nodes

    private static func nodeMarkup(_ node: ERDNode) -> String {
        let frame = ERDGeometry.frame(for: node)
        let width = ERDMetrics.nodeWidth
        var out = "<g transform=\"translate(\(num(frame.minX)),\(num(frame.minY)))\">\n"
        // Card + header.
        out += "<rect x=\"0\" y=\"0\" width=\"\(num(width))\" height=\"\(num(frame.height))\" rx=\"8\" "
        out += "fill=\"\(Palette.card)\" stroke=\"\(Palette.border)\" stroke-width=\"1\"/>\n"
        out += "<path d=\"M0,8 a8,8 0 0 1 8,-8 h\(num(width - 16)) a8,8 0 0 1 8,8 "
        out += "v\(num(ERDMetrics.headerHeight - 8)) h\(num(-width)) z\" fill=\"\(Palette.header)\"/>\n"
        out += text(node.name, x: 10, y: ERDMetrics.headerHeight / 2 + 4, size: 12, weight: "bold", color: Palette.ink)

        if !node.isCollapsed {
            var y = ERDMetrics.headerHeight + ERDMetrics.bodyVerticalPadding
            for column in node.columns {
                let rowCenter = y + ERDMetrics.rowHeight / 2
                if column.isPrimaryKey {
                    out += "<circle cx=\"16\" cy=\"\(num(rowCenter))\" r=\"3\" fill=\"\(Palette.primaryKey)\"/>\n"
                } else if column.isForeignKey {
                    out += "<circle cx=\"16\" cy=\"\(num(rowCenter))\" r=\"3\" fill=\"\(Palette.foreignKey)\"/>\n"
                }
                let nameColor = column.isNullable ? Palette.ink2 : Palette.ink
                let weight = column.isPrimaryKey ? "bold" : "normal"
                out += text(column.name, x: 26, y: rowCenter + 4, size: 11, weight: weight, color: nameColor)
                out += text(
                    column.type,
                    x: width - 10,
                    y: rowCenter + 4,
                    size: 10,
                    weight: "normal",
                    color: Palette.ink3,
                    anchor: "end"
                )
                y += ERDMetrics.rowHeight
            }
        }
        out += "</g>\n"
        return out
    }

    // MARK: - Helpers

    private static func text(
        _ value: String,
        x: CGFloat,
        y: CGFloat,
        size: CGFloat,
        weight: String,
        color: String,
        anchor: String = "start"
    ) -> String {
        "<text x=\"\(num(x))\" y=\"\(num(y))\" font-size=\"\(num(size))\" font-weight=\"\(weight)\" "
            + "text-anchor=\"\(anchor)\" fill=\"\(color)\">\(escape(value))</text>\n"
    }

    /// Trims trailing `.0` so integers stay tidy and output is stable.
    private static func num(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(Double(rounded))
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
