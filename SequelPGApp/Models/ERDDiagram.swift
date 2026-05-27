import CoreGraphics
import Foundation

/// Relationship multiplicity between two tables, derived from foreign-key shape.
/// `oneToOne` when the referencing columns are exactly the child's primary key
/// (so each child row maps to one parent and vice versa); `manyToOne` otherwise
/// (many child rows reference one parent — the common FK case).
enum ERDCardinality: String, Equatable, Sendable {
    case oneToOne
    case manyToOne
}

/// A single column rendered inside a table node. Derived from `ColumnInfo`
/// plus foreign-key participation. This is display state for the diagram — it
/// is the editable source of truth that Phase 2 (DDL editing) will mutate.
struct ERDColumn: Identifiable, Equatable {
    /// Column name — unique within a table, so it doubles as the identity.
    let id: String
    let name: String
    /// Human-readable type, e.g. `varchar(255)`, `int4`, `timestamptz`.
    let type: String
    let isPrimaryKey: Bool
    let isForeignKey: Bool
    let isNullable: Bool

    init(name: String, type: String, isPrimaryKey: Bool, isForeignKey: Bool, isNullable: Bool) {
        self.id = name
        self.name = name
        self.type = type
        self.isPrimaryKey = isPrimaryKey
        self.isForeignKey = isForeignKey
        self.isNullable = isNullable
    }
}

/// A table drawn as a card on the canvas. `position` is the top-left origin in
/// diagram (un-zoomed) coordinates; `isCollapsed`/`isHidden` are user view
/// toggles. Layout and view state persist via `ERDLayout`.
struct ERDNode: Identifiable, Equatable {
    /// `schema.table`, qualified so it is unique and matches edge endpoints.
    let id: String
    let schema: String
    let name: String
    var columns: [ERDColumn]
    var position: CGPoint
    var isCollapsed: Bool
    var isHidden: Bool

    init(
        schema: String,
        name: String,
        columns: [ERDColumn],
        position: CGPoint = .zero,
        isCollapsed: Bool = false,
        isHidden: Bool = false
    ) {
        self.id = "\(schema).\(name)"
        self.schema = schema
        self.name = name
        self.columns = columns
        self.position = position
        self.isCollapsed = isCollapsed
        self.isHidden = isHidden
    }
}

/// A foreign-key relationship between two nodes. `source` is the referencing
/// (child) table, `target` is the referenced (parent) table.
struct ERDEdge: Identifiable, Equatable {
    /// Constraint identity (`schema.table.constraint`).
    let id: String
    let constraintName: String
    let sourceNodeID: String
    let sourceColumns: [String]
    let targetNodeID: String
    let targetColumns: [String]
    let cardinality: ERDCardinality
}

/// The whole diagram for one schema: the editable graph of table nodes and the
/// foreign-key edges between them. Viewport state (zoom/pan) lives on the view
/// model, not here, so the diagram stays a pure content model.
struct ERDDiagram: Equatable {
    let schema: String
    var nodes: [ERDNode]
    var edges: [ERDEdge]

    init(schema: String, nodes: [ERDNode] = [], edges: [ERDEdge] = []) {
        self.schema = schema
        self.nodes = nodes
        self.edges = edges
    }

    func node(id: String) -> ERDNode? {
        nodes.first { $0.id == id }
    }
}

extension ERDDiagram {
    /// Builds a diagram from raw introspection results. Pure and deterministic
    /// so it can be unit-tested without a database.
    ///
    /// - Parameters:
    ///   - schema: the schema being diagrammed.
    ///   - tables: every base table in the schema (`DBObject` of type `.table`).
    ///   - columnsByTable: columns keyed by **table name** (not qualified).
    ///   - foreignKeys: FK constraints in the schema, as `ConstraintInfo` with
    ///     `kind == .foreignKey`. `referencedTable` is `refSchema.refTable`.
    ///
    /// Edges whose referenced table is not among `tables` (e.g. a cross-schema
    /// FK) are dropped, since the target node would not exist on the canvas.
    static func build(
        schema: String,
        tables: [DBObject],
        columnsByTable: [String: [ColumnInfo]],
        foreignKeys: [ConstraintInfo]
    ) -> ERDDiagram {
        // Columns participating in any FK, keyed by table name, for the FK glyph.
        var fkColumnsByTable: [String: Set<String>] = [:]
        for fk in foreignKeys where fk.kind == .foreignKey {
            fkColumnsByTable[fk.table, default: []].formUnion(fk.columns)
        }

        let nodes: [ERDNode] = tables.map { table in
            let cols = columnsByTable[table.name] ?? []
            let fkCols = fkColumnsByTable[table.name] ?? []
            let erdColumns = cols.map { col in
                ERDColumn(
                    name: col.name,
                    type: displayType(for: col),
                    isPrimaryKey: col.isPrimaryKey,
                    isForeignKey: fkCols.contains(col.name),
                    isNullable: col.isNullable
                )
            }
            return ERDNode(schema: schema, name: table.name, columns: erdColumns)
        }

        let nodeIDs = Set(nodes.map(\.id))
        let edges: [ERDEdge] = foreignKeys.compactMap { fk -> ERDEdge? in
            guard fk.kind == .foreignKey, let referenced = fk.referencedTable else { return nil }
            let sourceID = "\(fk.schema).\(fk.table)"
            let targetID = qualifiedTarget(referenced, fallbackSchema: schema)
            // Only draw edges whose both endpoints are on the canvas.
            guard nodeIDs.contains(sourceID), nodeIDs.contains(targetID) else { return nil }
            let childPK = Set((columnsByTable[fk.table] ?? []).filter(\.isPrimaryKey).map(\.name))
            let cardinality: ERDCardinality =
                !childPK.isEmpty && childPK == Set(fk.columns) ? .oneToOne : .manyToOne
            return ERDEdge(
                id: fk.id,
                constraintName: fk.name,
                sourceNodeID: sourceID,
                sourceColumns: fk.columns,
                targetNodeID: targetID,
                targetColumns: fk.referencedColumns,
                cardinality: cardinality
            )
        }

        return ERDDiagram(schema: schema, nodes: nodes, edges: edges)
    }

    /// Normalizes a referenced-table string to a `schema.table` node id. The
    /// value may already be qualified (`public.users`) or bare (`users`).
    private static func qualifiedTarget(_ referenced: String, fallbackSchema: String) -> String {
        referenced.contains(".") ? referenced : "\(fallbackSchema).\(referenced)"
    }

    /// Renders a compact, human-friendly type label from `ColumnInfo`.
    private static func displayType(for col: ColumnInfo) -> String {
        if let len = col.characterMaximumLength, col.dataType.lowercased().contains("char") {
            return "\(col.dataType)(\(len))"
        }
        if let precision = col.numericPrecision, col.dataType.lowercased() == "numeric" {
            if let scale = col.numericScale, scale > 0 {
                return "numeric(\(precision),\(scale))"
            }
            return "numeric(\(precision))"
        }
        return col.dataType
    }
}
