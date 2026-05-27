import CoreGraphics
import Foundation

/// State for the schema diagram view. Pure presentation/view state — like the
/// other child view models it never touches `dbClient`; `AppViewModel` loads the
/// data and pushes a built `ERDDiagram` in via `setDiagram`. Mutating helpers
/// here keep the diagram graph and viewport as the editable source of truth,
/// ready for Phase 2 (DDL editing) to build on.
@MainActor
@Observable final class ERDViewModel {
    /// The diagram currently shown, or `nil` before a schema is loaded.
    var diagram: ERDDiagram?
    /// Schemas the user can pick from (populated by `AppViewModel`).
    var availableSchemas: [String] = []
    /// The schema the current diagram represents.
    var selectedSchema: String?
    var isLoading = false
    var errorMessage: String?

    // Viewport.
    var scale: CGFloat = 1
    var offset: CGPoint = .zero
    /// Size of the on-screen canvas, reported by the view; used for fit-to-window.
    var viewportSize: CGSize = .zero

    // Selection.
    var selectedNodeID: String?

    /// Cached obstacle-avoiding edge routes. Recomputed only when the diagram
    /// geometry settles (load, auto-layout, collapse/hide, drag end) — never on
    /// hover, selection, or viewport changes — so those stay cheap.
    private(set) var routes: [String: ERDGeometry.Route] = [:]

    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 2.5

    /// Nodes the user has not hidden, in stable id order.
    var visibleNodes: [ERDNode] {
        diagram?.nodes.filter { !$0.isHidden } ?? []
    }

    /// Edges whose endpoints are both visible.
    var visibleEdges: [ERDEdge] {
        guard let diagram else { return [] }
        let visibleIDs = Set(visibleNodes.map(\.id))
        return diagram.edges.filter { visibleIDs.contains($0.sourceNodeID) && visibleIDs.contains($0.targetNodeID) }
    }

    var hasHiddenNodes: Bool {
        diagram?.nodes.contains(where: \.isHidden) ?? false
    }

    // MARK: - Loading

    /// Replaces the diagram, resetting transient selection but preserving the
    /// caller-provided node positions (auto-layout or restored layout).
    func setDiagram(_ diagram: ERDDiagram) {
        self.diagram = diagram
        selectedNodeID = nil
        // Reset the viewport so a newly loaded schema doesn't inherit a stale
        // pan/zoom from the previously viewed one (which can push it off-screen).
        scale = 1
        offset = .zero
        recomputeRoutes()
    }

    func clear() {
        diagram = nil
        selectedSchema = nil
        selectedNodeID = nil
        errorMessage = nil
        scale = 1
        offset = .zero
        routes = [:]
    }

    /// Rebuilds the cached edge routes from the current visible geometry. Call
    /// after the layout settles; cheap enough to run on each settle, too costly
    /// to run on every drag frame (the canvas uses direct routing mid-drag).
    func recomputeRoutes() {
        guard diagram != nil else {
            routes = [:]
            return
        }
        let frames = Dictionary(uniqueKeysWithValues: visibleNodes.map { ($0.id, ERDGeometry.frame(for: $0)) })
        routes = ERDRouter.routes(nodeFrames: frames, edges: visibleEdges)
    }

    // MARK: - Node mutation

    func moveNode(id: String, to position: CGPoint) {
        guard let index = diagram?.nodes.firstIndex(where: { $0.id == id }) else { return }
        diagram?.nodes[index].position = position
    }

    func toggleCollapse(id: String) {
        guard let index = diagram?.nodes.firstIndex(where: { $0.id == id }) else { return }
        diagram?.nodes[index].isCollapsed.toggle()
        recomputeRoutes()
    }

    func hideNode(id: String) {
        guard let index = diagram?.nodes.firstIndex(where: { $0.id == id }) else { return }
        diagram?.nodes[index].isHidden = true
        if selectedNodeID == id { selectedNodeID = nil }
        recomputeRoutes()
    }

    func showAllNodes() {
        guard diagram != nil else { return }
        for index in diagram!.nodes.indices {
            diagram!.nodes[index].isHidden = false
        }
        recomputeRoutes()
    }

    // MARK: - Layout

    /// Re-runs auto-layout over the current nodes, overwriting positions.
    func applyAutoLayout() {
        guard let current = diagram else { return }
        let positions = ERDLayoutEngine.layout(nodes: current.nodes, edges: current.edges)
        for index in diagram!.nodes.indices {
            if let position = positions[diagram!.nodes[index].id] {
                diagram!.nodes[index].position = position
            }
        }
        recomputeRoutes()
    }

    // MARK: - Viewport

    func zoom(to newScale: CGFloat) {
        scale = min(max(newScale, Self.minScale), Self.maxScale)
    }

    func resetViewport() {
        scale = 1
        offset = .zero
    }

    /// Scales and centers the diagram so the whole thing fits the current
    /// viewport (never zooming past 100%). No-op until the view has reported a
    /// size and there is something to show.
    func fitToViewport() {
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        let content = ERDGeometry.contentBounds(of: visibleNodes)
        guard content.width > 1, content.height > 1 else { return }
        let margin: CGFloat = 24
        let fit = min(
            (viewportSize.width - margin * 2) / content.width,
            (viewportSize.height - margin * 2) / content.height
        )
        let clamped = min(max(fit, Self.minScale), 1)
        scale = clamped
        offset = CGPoint(
            x: max(margin, (viewportSize.width - content.width * clamped) / 2),
            y: max(margin, (viewportSize.height - content.height * clamped) / 2)
        )
    }

    // MARK: - Persistence bridge

    /// A snapshot of the current view state for saving to disk.
    func currentLayout() -> ERDLayout {
        var positions: [String: CGPoint] = [:]
        var collapsed: Set<String> = []
        var hidden: Set<String> = []
        for node in diagram?.nodes ?? [] {
            positions[node.id] = node.position
            if node.isCollapsed { collapsed.insert(node.id) }
            if node.isHidden { hidden.insert(node.id) }
        }
        return ERDLayout(positions: positions, collapsed: collapsed, hidden: hidden, scale: scale, offset: offset)
    }

    /// Applies a previously saved layout onto the current diagram, matching by
    /// node id. Nodes absent from the layout keep their freshly-computed values.
    func apply(layout: ERDLayout) {
        guard layout.isReadable, diagram != nil else { return }
        for index in diagram!.nodes.indices {
            let id = diagram!.nodes[index].id
            if let position = layout.positions[id] {
                diagram!.nodes[index].position = position
            }
            diagram!.nodes[index].isCollapsed = layout.collapsed.contains(id)
            diagram!.nodes[index].isHidden = layout.hidden.contains(id)
        }
        // Intentionally does NOT restore scale/offset: the viewport is reframed
        // (fit-to-window) on every open, so a stale saved pan/zoom can't push the
        // diagram off-screen. Only the node arrangement is persisted/restored.
        recomputeRoutes()
    }
}
