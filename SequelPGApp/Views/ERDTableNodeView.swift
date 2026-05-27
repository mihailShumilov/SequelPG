import SwiftUI

/// A single table rendered as a card on the ERD canvas: a header with the table
/// name and a collapse chevron, and a body listing columns with PK/FK glyphs and
/// types. Sizing is driven by `ERDMetrics` so it matches the geometry the edge
/// layer and exporters compute. Interaction (drag/collapse/hide) is layered on
/// by the canvas in a later step; this view only renders.
struct ERDTableNodeView: View {
    let node: ERDNode
    var isSelected: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !node.isCollapsed {
                Rectangle().fill(Theme.line).frame(height: 1)
                columnRows
            }
        }
        .frame(
            width: ERDMetrics.nodeWidth,
            height: ERDMetrics.nodeHeight(columnCount: node.columns.count, collapsed: node.isCollapsed),
            alignment: .top
        )
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Theme.line2, lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.ink3)
            Text(node.name)
                .font(Theme.mono(size: 12, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if node.isCollapsed {
                Text("\(node.columns.count)")
                    .font(Theme.mono(size: 10))
                    .foregroundStyle(Theme.ink4)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ERDMetrics.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel2)
    }

    private var columnRows: some View {
        VStack(spacing: 0) {
            ForEach(node.columns) { column in
                columnRow(column)
            }
        }
        .padding(.vertical, ERDMetrics.bodyVerticalPadding)
    }

    private func columnRow(_ column: ERDColumn) -> some View {
        HStack(spacing: 6) {
            glyph(for: column)
                .frame(width: 12)
            Text(column.name)
                .font(Theme.mono(size: 11, weight: column.isPrimaryKey ? .bold : .regular))
                .foregroundStyle(column.isNullable ? Theme.ink2 : Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(column.type)
                .font(Theme.mono(size: 10))
                .foregroundStyle(Theme.typePillColor(dataType: column.type))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: ERDMetrics.rowHeight)
    }

    @ViewBuilder
    private func glyph(for column: ERDColumn) -> some View {
        if column.isPrimaryKey {
            Image(systemName: "key.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.amber)
        } else if column.isForeignKey {
            Image(systemName: "link")
                .font(.system(size: 9))
                .foregroundStyle(Theme.blue)
        } else {
            Color.clear
        }
    }
}
