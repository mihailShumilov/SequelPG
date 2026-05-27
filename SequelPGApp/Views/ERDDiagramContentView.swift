import SwiftUI

/// The whole diagram drawn at natural (un-zoomed) size: an edge layer behind a
/// set of table cards positioned in diagram coordinates. Deliberately free of
/// viewport transforms and gestures so it renders identically whether shown
/// inside the interactive canvas or handed to `ImageRenderer` for export.
struct ERDDiagramContentView: View {
    let nodes: [ERDNode]
    let edges: [ERDEdge]
    var selectedNodeID: String?
    /// Filled behind the diagram. Opaque for export; the interactive canvas can
    /// pass a matching background so on-screen and exported output agree.
    var background: Color = Theme.bg

    private var contentSize: CGSize {
        ERDGeometry.contentBounds(of: nodes)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background

            ERDEdgesCanvas(nodes: nodes, edges: edges)

            ForEach(nodes) { node in
                ERDTableNodeView(node: node, isSelected: node.id == selectedNodeID)
                    .offset(x: node.position.x, y: node.position.y)
            }
        }
        .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
    }
}

/// The FK relationship layer: straight connectors between table cards with an
/// arrowhead at the parent (target) end, a dot at the child (source) end, and a
/// perpendicular tick marking one-to-one relationships. Shared by the static
/// content view and the interactive canvas so geometry is identical everywhere.
struct ERDEdgesCanvas: View {
    let nodes: [ERDNode]
    let edges: [ERDEdge]

    private var contentSize: CGSize {
        ERDGeometry.contentBounds(of: nodes)
    }

    var body: some View {
        Canvas { context, _ in
            let frames = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, ERDGeometry.frame(for: $0)) })
            for edge in edges {
                guard let source = frames[edge.sourceNodeID], let target = frames[edge.targetNodeID] else { continue }
                draw(context: context, route: ERDGeometry.route(from: source, to: target), cardinality: edge.cardinality)
            }
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .allowsHitTesting(false)
    }

    private func draw(context: GraphicsContext, route: ERDGeometry.Route, cardinality: ERDCardinality) {
        guard let from = route.points.first, let to = route.points.last, route.points.count >= 2 else { return }

        context.stroke(Path(route.path), with: .color(Theme.line2), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

        let childDot = Path(ellipseIn: CGRect(x: from.x - 3, y: from.y - 3, width: 6, height: 6))
        context.fill(childDot, with: .color(Theme.blue))

        // Arrowhead points along the final segment entering the parent.
        let incoming = route.points[route.points.count - 2]
        let angle = atan2(to.y - incoming.y, to.x - incoming.x)
        context.fill(arrowhead(at: to, angle: angle, length: 9, spread: .pi / 7), with: .color(Theme.ink3))

        if cardinality == .oneToOne {
            context.stroke(tick(at: to, angle: angle, back: 11, half: 5), with: .color(Theme.ink3), lineWidth: 1.5)
        }
    }

    private func arrowhead(at tip: CGPoint, angle: CGFloat, length: CGFloat, spread: CGFloat) -> Path {
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)))
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)))
        path.closeSubpath()
        return path
    }

    private func tick(at tip: CGPoint, angle: CGFloat, back: CGFloat, half: CGFloat) -> Path {
        let center = CGPoint(x: tip.x - back * cos(angle), y: tip.y - back * sin(angle))
        let perpendicular = angle + .pi / 2
        var path = Path()
        path.move(to: CGPoint(x: center.x - half * cos(perpendicular), y: center.y - half * sin(perpendicular)))
        path.addLine(to: CGPoint(x: center.x + half * cos(perpendicular), y: center.y + half * sin(perpendicular)))
        return path
    }
}
