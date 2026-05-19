import SwiftUI

/// Human-readable EXPLAIN / EXPLAIN ANALYZE visualizer. Renders the plan tree
/// as a vertical list of "what this step does" rows, with the raw PostgreSQL
/// node type pushed to a small monospaced subtitle for readers who care.
///
/// The view is read-only and self-contained — no bindings flow back into the
/// query view model. Selection state lives locally so opening the inspector
/// for a node doesn't churn QueryViewModel.
struct QueryPlanView: View {
    let plan: QueryPlan

    @State private var selectedNodeID: PlanNode.ID?
    @State private var collapsedNodes: Set<PlanNode.ID> = []

    var body: some View {
        let overview = PlanNarrator.overview(of: plan)
        return HStack(spacing: 0) {
            // Left: scrolling list of plan steps, root at the top, children
            // indented underneath. Each row is the human-language explanation.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    summaryHeader(overview)
                    DottedRule()
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                    nodeRow(plan.root, depth: 0, isLastChild: true, ancestorEdges: [])
                    if !plan.triggers.isEmpty {
                        triggerSection()
                    }
                }
                .padding(.vertical, 14)
            }
            .background(Theme.bg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Theme.line).frame(width: 1)

            // Right: details for the selected step. Defaults to the root.
            AnyView(detailsPanel(for: selectedNode))
                .frame(width: 320)
                .background(Theme.bg2)
        }
    }

    private var selectedNode: PlanNode {
        if let id = selectedNodeID, let found = findNode(id: id, in: plan.root) {
            return found
        }
        return plan.root
    }

    private func findNode(id: PlanNode.ID, in node: PlanNode) -> PlanNode? {
        if node.id == id { return node }
        for child in node.children {
            if let m = findNode(id: id, in: child) { return m }
        }
        return nil
    }

    // MARK: - Summary header

    @ViewBuilder
    private func summaryHeader(_ overview: PlanNarrator.Overview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.didAnalyze ? "i. — what actually happened" : "i. — what would happen")
                .appSectionLabel()
            Text(overview.headline)
                .appDisplayItalic(26)
            Text(overview.timing)
                .appMono(11.5, color: Theme.ink3)
                .padding(.top, 2)
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
    }

    // MARK: - Tree rows

    /// Recursively renders one plan node and its children. Depth controls the
    /// indent of the tree-guide rules drawn down the left of the row;
    /// `ancestorEdges` tracks which ancestor columns still need a vertical
    /// guide (i.e., they have a younger sibling) so the tree art is correct.
    /// Returns `AnyView` because Swift cannot infer a self-referential opaque
    /// return type — the recursive children ForEach calls back into this same
    /// function.
    private func nodeRow(_ node: PlanNode, depth: Int, isLastChild: Bool, ancestorEdges: [Bool]) -> AnyView {
        let narration = PlanNarrator.narrate(node, in: plan)
        let isCollapsed = collapsedNodes.contains(node.id)
        let isSelected = selectedNodeID == node.id || (selectedNodeID == nil && depth == 0)

        let row = Button {
            selectedNodeID = node.id
        } label: {
            HStack(alignment: .top, spacing: 0) {
                treeGuides(depth: depth, isLastChild: isLastChild, ancestorEdges: ancestorEdges)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        nodeKindPill(node.kind)
                        Text(narration.title)
                            .font(Theme.serifItalic(size: 18))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                        if !node.children.isEmpty {
                            Button {
                                toggleCollapse(node)
                            } label: {
                                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.ink3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(narration.summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    metricsRow(node)
                    if !narration.findings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(narration.findings) { finding in
                                findingChip(finding)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, 16)
            }
            .padding(.leading, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accent.opacity(0.08) : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 2)
                }
            }
        }
        .buttonStyle(.plain)

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                row
                if !isCollapsed {
                    ForEach(Array(node.children.enumerated()), id: \.element.id) { idx, child in
                        let isLast = idx == node.children.count - 1
                        let nextAncestorEdges = ancestorEdges + [!isLastChild]
                        nodeRow(child, depth: depth + 1, isLastChild: isLast, ancestorEdges: nextAncestorEdges)
                    }
                }
            }
        )
    }

    private func toggleCollapse(_ node: PlanNode) {
        if collapsedNodes.contains(node.id) {
            collapsedNodes.remove(node.id)
        } else {
            collapsedNodes.insert(node.id)
        }
    }

    /// Draws the ASCII-style tree guides to the left of each plan node row. We
    /// render a stack of fixed-width columns, one per nesting level, choosing a
    /// branch glyph (`├`, `└`, `│`, or blank) based on whether each ancestor
    /// has more siblings below.
    @ViewBuilder
    private func treeGuides(depth: Int, isLastChild: Bool, ancestorEdges: [Bool]) -> some View {
        if depth == 0 {
            EmptyView()
        } else {
            HStack(spacing: 0) {
                ForEach(0 ..< depth, id: \.self) { col in
                    let isLastCol = col == depth - 1
                    let needsVertical = col < ancestorEdges.count ? ancestorEdges[col] : false
                    treeGuideColumn(isLastCol: isLastCol, isLastChild: isLastChild, needsVertical: needsVertical)
                }
            }
        }
    }

    @ViewBuilder
    private func treeGuideColumn(isLastCol: Bool, isLastChild: Bool, needsVertical: Bool) -> some View {
        ZStack {
            if isLastCol {
                // Branch glyph
                if isLastChild {
                    Path { p in
                        p.move(to: CGPoint(x: 8, y: 0))
                        p.addLine(to: CGPoint(x: 8, y: 16))
                        p.move(to: CGPoint(x: 8, y: 16))
                        p.addLine(to: CGPoint(x: 18, y: 16))
                    }
                    .stroke(Theme.line2, lineWidth: 1)
                } else {
                    Path { p in
                        p.move(to: CGPoint(x: 8, y: 0))
                        p.addLine(to: CGPoint(x: 8, y: 50))
                        p.move(to: CGPoint(x: 8, y: 16))
                        p.addLine(to: CGPoint(x: 18, y: 16))
                    }
                    .stroke(Theme.line2, lineWidth: 1)
                }
            } else if needsVertical {
                Path { p in
                    p.move(to: CGPoint(x: 8, y: 0))
                    p.addLine(to: CGPoint(x: 8, y: 50))
                }
                .stroke(Theme.line2, lineWidth: 1)
            }
        }
        .frame(width: 22)
    }

    // MARK: - Metrics row

    @ViewBuilder
    private func metricsRow(_ node: PlanNode) -> some View {
        HStack(spacing: 16) {
            if plan.didAnalyze, let total = node.totalInclusiveTime {
                metric(label: "took", value: formatMs(total))
            } else if plan.didAnalyze, let total = node.actualTotalTime {
                metric(label: "took", value: formatMs(total))
            }
            if let rows = node.actualRows {
                metric(label: "returned", value: "\(formatRows(rows)) rows")
            } else {
                metric(label: "expected", value: "\(formatRows(node.planRows)) rows")
            }
            if let loops = node.actualLoops, loops > 1 {
                metric(label: "loops", value: "\(formatRows(loops))×")
            }
            metric(label: "cost", value: String(format: "%.0f", node.totalCost))
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func metric(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(Theme.mono(size: 10))
                .foregroundStyle(Theme.ink4)
            Text(value)
                .font(Theme.mono(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ink2)
        }
    }

    // MARK: - Findings

    @ViewBuilder
    private func findingChip(_ finding: PlanNarrator.Finding) -> some View {
        let color: Color = {
            switch finding.severity {
            case .info: return Theme.cyan
            case .warn: return Theme.amber
            case .bad: return Theme.rose
            }
        }()
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(finding.text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(color.opacity(0.25), lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: 4))
    }

    // MARK: - Node kind pill

    @ViewBuilder
    private func nodeKindPill(_ kind: PlanNode.Kind) -> some View {
        let label: String = {
            switch kind {
            case .scan: return "scan"
            case .join: return "join"
            case .aggregate: return "agg"
            case .sort: return "sort"
            case .hash: return "hash"
            case .modify: return "write"
            case .other: return "step"
            }
        }()
        let color: Color = {
            switch kind {
            case .scan: return Theme.violet
            case .join: return Theme.amber
            case .aggregate: return Theme.cyan
            case .sort: return Theme.mauve
            case .hash: return Theme.blue
            case .modify: return Theme.rose
            case .other: return Theme.ink3
            }
        }()
        Tag(label, color: color)
    }

    // MARK: - Triggers section

    @ViewBuilder
    private func triggerSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ii. — triggers")
                .appSectionLabel()
                .padding(.top, 14)
            ForEach(plan.triggers) { trigger in
                HStack(spacing: 10) {
                    Text(trigger.triggerName)
                        .font(Theme.mono(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    if let rel = trigger.relation {
                        Text("on \(rel)")
                            .appMono(11, color: Theme.ink3)
                    }
                    Spacer()
                    Text("\(formatMs(trigger.time)) · \(trigger.calls) call\(trigger.calls == 1 ? "" : "s")")
                        .appMono(11, color: Theme.ink3)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
    }

    // MARK: - Details panel (right side)

    @ViewBuilder
    private func detailsPanel(for node: PlanNode) -> some View {
        let narration = PlanNarrator.narrate(node, in: plan)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("step detail")
                        .appSectionLabel()
                    Text(narration.title)
                        .appDisplayItalic(22)
                    Text(node.nodeType)
                        .appMono(11, color: Theme.ink4)
                }

                DottedRule()

                Text(narration.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                if !narration.findings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(narration.findings) { f in
                            findingChip(f)
                        }
                    }
                }

                DottedRule()

                detailGroup("By the numbers", rows: numericDetails(for: node))

                if !node.details.isEmpty {
                    DottedRule()
                    detailGroup("PostgreSQL details", rows: node.details.map { ($0.key, $0.value) })
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func detailGroup(_ title: String, rows: [(String, String)]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .appSectionLabel()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.0) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.0)
                                .font(Theme.mono(size: 11))
                                .foregroundStyle(Theme.ink3)
                                .frame(width: 110, alignment: .leading)
                            Text(row.1)
                                .font(Theme.mono(size: 11.5))
                                .foregroundStyle(Theme.ink2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func numericDetails(for node: PlanNode) -> [(String, String)] {
        var rows: [(String, String)] = []
        if plan.didAnalyze {
            if let total = node.actualTotalTime {
                rows.append(("Actual time", "\(formatMs(node.actualStartupTime ?? 0)) → \(formatMs(total))"))
            }
            if let l = node.actualLoops { rows.append(("Loops", formatRows(l))) }
            if let r = node.actualRows { rows.append(("Actual rows", formatRows(r))) }
            if let removed = node.rowsRemovedByFilter, removed > 0 {
                rows.append(("Filtered out", formatRows(removed)))
            }
            if let ratio = node.estimateRatio {
                rows.append(("Estimate vs actual", String(format: "%.2f×", ratio)))
            }
        }
        rows.append(("Planner cost", "\(String(format: "%.1f", node.startupCost)) → \(String(format: "%.1f", node.totalCost))"))
        rows.append(("Planner rows", formatRows(node.planRows)))
        rows.append(("Row width", "\(node.planWidth) bytes"))

        let buf = bufferRows(node)
        if !buf.isEmpty {
            rows.append(("Buffers", buf))
        }
        if let rel = node.relationName {
            let qualified = node.schema.map { "\($0).\(rel)" } ?? rel
            rows.append(("On table", qualified))
        }
        if let alias = node.alias { rows.append(("Alias", alias)) }
        if let idx = node.indexName { rows.append(("Using index", idx)) }
        return rows
    }

    private func bufferRows(_ node: PlanNode) -> String {
        var parts: [String] = []
        if let h = node.sharedHitBlocks, h > 0 { parts.append("\(h) hit") }
        if let r = node.sharedReadBlocks, r > 0 { parts.append("\(r) read") }
        if let d = node.sharedDirtiedBlocks, d > 0 { parts.append("\(d) dirtied") }
        if let w = node.sharedWrittenBlocks, w > 0 { parts.append("\(w) written") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Formatters

    private func formatMs(_ ms: Double) -> String {
        if ms < 1 { return String(format: "%.2f ms", ms) }
        if ms < 1000 { return String(format: "%.1f ms", ms) }
        return String(format: "%.2f s", ms / 1000)
    }

    private func formatRows(_ n: Double) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 10_000 { return String(format: "%.0fk", n / 1_000) }
        if n >= 1_000 { return String(format: "%.1fk", n / 1_000) }
        return String(Int(n))
    }
}

/// Empty-state shown in the EXPLAIN tab before the user has run an Explain.
struct QueryPlanEmptyView: View {
    let isConnected: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("vi. — no plan yet")
                .appSectionLabel()
            Text("How would Postgres run this?")
                .appDisplayItalic(28)
            Text("Click Explain to preview the plan without running the query,\nor Analyze to run it and report what actually happened.")
                .appBody()
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                AppKbd(key: "Explain")
                Text("free — does not execute the query")
                    .appMono(11, color: Theme.ink3)
            }
            HStack(spacing: 8) {
                AppKbd(key: "Analyze")
                Text("actually runs the query and times each step")
                    .appMono(11, color: Theme.ink3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
