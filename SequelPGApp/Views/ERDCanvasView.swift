import SwiftUI

/// The interactive diagram workspace. Wraps the shared edge layer and table
/// cards in a zoom/pan viewport and adds per-node dragging, selection, collapse,
/// and hide. View state lives on `ERDViewModel`; persistence is delegated to
/// `AppViewModel.saveDiagramLayout()` after each gesture or edit so Views never
/// touch storage directly.
struct ERDCanvasView: View {
    @Environment(AppViewModel.self) private var appVM
    @Environment(ERDViewModel.self) private var erdVM

    private static let space = "erdCanvas"

    // Gesture anchors captured on first change, mirroring the SidebarResizeHandle
    // pattern (start value + delta) used elsewhere in the app.
    @State private var panStart: CGPoint?
    @State private var magnifyStart: CGFloat?
    @State private var nodeDragStart: [String: CGPoint] = [:]
    /// While a node is being dragged we use cheap direct edge routing; the full
    /// obstacle-avoiding router runs once the drag ends.
    @State private var isDraggingNode = false

    private var contentSize: CGSize {
        ERDGeometry.contentBounds(of: erdVM.visibleNodes)
    }

    var body: some View {
        ZStack {
            Theme.bg
                .contentShape(Rectangle())
                .onTapGesture { erdVM.selectedNodeID = nil }
                .gesture(panGesture)

            scaledContent
        }
        .coordinateSpace(name: Self.space)
        .clipped()
        .simultaneousGesture(magnifyGesture)
    }

    private var scaledContent: some View {
        ZStack(alignment: .topLeading) {
            ERDEdgesCanvas(nodes: erdVM.visibleNodes, edges: erdVM.visibleEdges, obstacleAvoiding: !isDraggingNode)

            ForEach(erdVM.visibleNodes) { node in
                interactiveNode(node)
            }
        }
        .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
        .scaleEffect(erdVM.scale)
        .offset(x: erdVM.offset.x, y: erdVM.offset.y)
    }

    private func interactiveNode(_ node: ERDNode) -> some View {
        ERDTableNodeView(node: node, isSelected: node.id == erdVM.selectedNodeID)
            .offset(x: node.position.x, y: node.position.y)
            .gesture(nodeDrag(node))
            .onTapGesture(count: 2) { toggleCollapse(node) }
            .onTapGesture { erdVM.selectedNodeID = node.id }
            .contextMenu {
                Button(node.isCollapsed ? "Expand" : "Collapse") { toggleCollapse(node) }
                Button("Hide Table") {
                    erdVM.hideNode(id: node.id)
                    appVM.saveDiagramLayout()
                }
            }
    }

    // MARK: - Edits

    private func toggleCollapse(_ node: ERDNode) {
        erdVM.toggleCollapse(id: node.id)
        appVM.saveDiagramLayout()
    }

    // MARK: - Gestures

    private func nodeDrag(_ node: ERDNode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                isDraggingNode = true
                let start = nodeDragStart[node.id] ?? node.position
                if nodeDragStart[node.id] == nil { nodeDragStart[node.id] = start }
                // Translation is in screen points; divide by scale to convert to
                // diagram coordinates. Clamp to the positive quadrant so the
                // content bounds (and exports) stay anchored at the origin.
                let moved = CGPoint(
                    x: max(0, start.x + value.translation.width / erdVM.scale),
                    y: max(0, start.y + value.translation.height / erdVM.scale)
                )
                erdVM.moveNode(id: node.id, to: moved)
            }
            .onEnded { _ in
                nodeDragStart[node.id] = nil
                isDraggingNode = false
                appVM.saveDiagramLayout()
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = panStart ?? erdVM.offset
                if panStart == nil { panStart = start }
                erdVM.offset = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
            }
            .onEnded { _ in
                panStart = nil
                appVM.saveDiagramLayout()
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = magnifyStart ?? erdVM.scale
                if magnifyStart == nil { magnifyStart = start }
                erdVM.zoom(to: start * value.magnification)
            }
            .onEnded { _ in
                magnifyStart = nil
                appVM.saveDiagramLayout()
            }
    }
}
