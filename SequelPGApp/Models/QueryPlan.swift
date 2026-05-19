import Foundation

/// Parsed output of `EXPLAIN (FORMAT JSON ...)`. Carries a tree of `PlanNode`
/// plus the top-level timing and the original raw JSON (kept around so the UI
/// can offer a "copy / show raw" affordance without re-running the query).
struct QueryPlan: Sendable {
    let root: PlanNode
    let planningTime: Double?
    let executionTime: Double?
    let triggers: [TriggerTiming]
    let settings: [String: String]
    let rawJSON: String
    /// `true` when produced by `EXPLAIN ANALYZE` — i.e., actual timings and row
    /// counts are present on the nodes. `false` for plain `EXPLAIN`, where only
    /// the planner's estimates are available.
    let didAnalyze: Bool

    struct TriggerTiming: Sendable, Identifiable {
        let id = UUID()
        let triggerName: String
        let relation: String?
        let time: Double
        let calls: Int
    }
}

/// One node in the plan tree — the smallest unit the visualizer renders as a
/// row. `details` holds everything not promoted to a typed property so the UI
/// can show node-kind-specific fields (Sort Method, Hash Cond, Join Type, etc.)
/// without us hard-coding every PG keyword here.
struct PlanNode: Sendable, Identifiable {
    let id = UUID()
    let nodeType: String
    let parentRelationship: String?

    // Target object
    let relationName: String?
    let schema: String?
    let alias: String?
    let indexName: String?

    // Planner estimates
    let startupCost: Double
    let totalCost: Double
    let planRows: Double
    let planWidth: Int

    // EXPLAIN ANALYZE actuals (nil for plain EXPLAIN)
    let actualStartupTime: Double?
    let actualTotalTime: Double?
    let actualRows: Double?
    let actualLoops: Double?
    let rowsRemovedByFilter: Double?

    // BUFFERS
    let sharedHitBlocks: Int?
    let sharedReadBlocks: Int?
    let sharedDirtiedBlocks: Int?
    let sharedWrittenBlocks: Int?

    // Free-form fields the renderer surfaces verbatim (Filter, Hash Cond,
    // Sort Method, Join Type, etc.). Stored as ordered key/value pairs so the
    // inspector shows them in the same order PostgreSQL emitted them.
    let details: [(key: String, value: String)]

    let children: [PlanNode]

    /// Inclusive time across all loops. PostgreSQL reports per-loop figures, so
    /// the "real" cost is `time * loops`. Falls back to nil when not ANALYZE.
    var totalInclusiveTime: Double? {
        guard let t = actualTotalTime, let l = actualLoops else { return nil }
        return t * l
    }

    /// Self-time = inclusive time minus the inclusive time of all children.
    /// This is what the worst-node highlight ranks on; spotting "where the
    /// time *actually* went" is the main win over reading the raw plan.
    var selfTime: Double? {
        guard let total = totalInclusiveTime else { return nil }
        let childrenInclusive = children.reduce(0.0) { acc, child in
            acc + (child.totalInclusiveTime ?? 0)
        }
        return max(0, total - childrenInclusive)
    }

    /// Planner under/over-estimate factor (planRows vs actualRows). Returns nil
    /// when no actuals are available or either side is zero. Values much
    /// greater than 1.0 mean the planner thought there'd be more rows than
    /// there were; much less than 1.0 means it under-estimated.
    var estimateRatio: Double? {
        guard let actual = actualRows, actual > 0, planRows > 0 else { return nil }
        return planRows / actual
    }

    /// True when the planner's row estimate is off by more than 10× in either
    /// direction. Used by the renderer to flag rows that probably caused a bad
    /// join order or scan choice.
    var hasBadEstimate: Bool {
        guard let r = estimateRatio else { return false }
        return r > 10.0 || r < 0.1
    }
}

// MARK: - Decoding

extension QueryPlan {
    /// Parses the JSON payload returned by `EXPLAIN (FORMAT JSON ...)`.
    ///
    /// Shape:
    /// ```
    /// [{ "Plan": { ... }, "Planning Time": 0.123, "Execution Time": 4.56, ... }]
    /// ```
    /// PostgreSQL always wraps the result in a single-element array. Some
    /// drivers / clients also accept the inner object — both forms are handled.
    static func decode(from jsonString: String) throws -> QueryPlan {
        guard let data = jsonString.data(using: .utf8) else {
            throw QueryPlanError.invalidJSON("Could not read JSON as UTF-8")
        }
        let any = try JSONSerialization.jsonObject(with: data, options: [])

        let topObject: [String: Any]
        if let array = any as? [Any], let first = array.first as? [String: Any] {
            topObject = first
        } else if let obj = any as? [String: Any] {
            topObject = obj
        } else {
            throw QueryPlanError.invalidJSON("EXPLAIN output is neither an array nor an object")
        }

        guard let planObj = topObject["Plan"] as? [String: Any] else {
            throw QueryPlanError.invalidJSON("Top-level 'Plan' object missing")
        }

        let root = decodeNode(planObj)
        let planningTime = topObject["Planning Time"] as? Double
        let executionTime = topObject["Execution Time"] as? Double

        var triggers: [TriggerTiming] = []
        if let triggerArr = topObject["Triggers"] as? [[String: Any]] {
            for t in triggerArr {
                triggers.append(TriggerTiming(
                    triggerName: t["Trigger Name"] as? String ?? "(unknown)",
                    relation: t["Relation"] as? String,
                    time: t["Time"] as? Double ?? 0,
                    calls: (t["Calls"] as? Int) ?? Int((t["Calls"] as? Double) ?? 0)
                ))
            }
        }

        var settings: [String: String] = [:]
        if let s = topObject["Settings"] as? [String: Any] {
            for (k, v) in s {
                settings[k] = "\(v)"
            }
        }

        return QueryPlan(
            root: root,
            planningTime: planningTime,
            executionTime: executionTime,
            triggers: triggers,
            settings: settings,
            rawJSON: jsonString,
            didAnalyze: executionTime != nil
        )
    }

    private static func decodeNode(_ obj: [String: Any]) -> PlanNode {
        // Keys that get promoted to typed fields — everything else falls
        // through into `details` so the inspector can show them verbatim.
        let promoted: Set<String> = [
            "Node Type", "Parent Relationship",
            "Relation Name", "Schema", "Alias", "Index Name",
            "Startup Cost", "Total Cost", "Plan Rows", "Plan Width",
            "Actual Startup Time", "Actual Total Time", "Actual Rows", "Actual Loops",
            "Rows Removed by Filter",
            "Shared Hit Blocks", "Shared Read Blocks",
            "Shared Dirtied Blocks", "Shared Written Blocks",
            "Plans",
        ]

        var details: [(key: String, value: String)] = []
        // Preserve PG's emission order for the detail list. JSONSerialization
        // doesn't guarantee order, so we sort by a stable "interesting first"
        // priority instead — the most useful fields surface at the top of the
        // detail card.
        let ordering = ["Join Type", "Strategy", "Hash Cond", "Index Cond",
                        "Filter", "Recheck Cond", "Sort Key", "Sort Method",
                        "Sort Space Used", "Sort Space Type",
                        "Group Key", "Workers Planned", "Workers Launched",
                        "Heap Fetches", "Subplan Name", "Output"]
        var seen = Set<String>()
        for key in ordering {
            guard !promoted.contains(key), let v = obj[key] else { continue }
            details.append((key: key, value: stringify(v)))
            seen.insert(key)
        }
        for (k, v) in obj where !promoted.contains(k) && !seen.contains(k) {
            details.append((key: k, value: stringify(v)))
        }

        let childObjs = obj["Plans"] as? [[String: Any]] ?? []
        let children = childObjs.map(decodeNode)

        return PlanNode(
            nodeType: obj["Node Type"] as? String ?? "Unknown",
            parentRelationship: obj["Parent Relationship"] as? String,
            relationName: obj["Relation Name"] as? String,
            schema: obj["Schema"] as? String,
            alias: obj["Alias"] as? String,
            indexName: obj["Index Name"] as? String,
            startupCost: doubleOrZero(obj["Startup Cost"]),
            totalCost: doubleOrZero(obj["Total Cost"]),
            planRows: doubleOrZero(obj["Plan Rows"]),
            planWidth: intOrZero(obj["Plan Width"]),
            actualStartupTime: obj["Actual Startup Time"] as? Double,
            actualTotalTime: obj["Actual Total Time"] as? Double,
            actualRows: doubleOrNil(obj["Actual Rows"]),
            actualLoops: doubleOrNil(obj["Actual Loops"]),
            rowsRemovedByFilter: doubleOrNil(obj["Rows Removed by Filter"]),
            sharedHitBlocks: intOrNil(obj["Shared Hit Blocks"]),
            sharedReadBlocks: intOrNil(obj["Shared Read Blocks"]),
            sharedDirtiedBlocks: intOrNil(obj["Shared Dirtied Blocks"]),
            sharedWrittenBlocks: intOrNil(obj["Shared Written Blocks"]),
            details: details,
            children: children
        )
    }

    private static func doubleOrZero(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return 0
    }

    private static func doubleOrNil(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    private static func intOrZero(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }

    private static func intOrNil(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private static func stringify(_ any: Any) -> String {
        switch any {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double:
            if d.truncatingRemainder(dividingBy: 1) == 0, abs(d) < 1e15 {
                return String(Int(d))
            }
            return String(d)
        case let arr as [Any]:
            return arr.map(stringify).joined(separator: ", ")
        default:
            return String(describing: any)
        }
    }
}

typealias TriggerTiming = QueryPlan.TriggerTiming

enum QueryPlanError: LocalizedError {
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let msg): return "Failed to parse EXPLAIN output: \(msg)"
        }
    }
}

// MARK: - Node classification (for type-pill coloring)

extension PlanNode {
    /// Coarse-grained classification used by the UI to pick a type-pill color
    /// for the node kind. Mirrors the violet/mauve/amber/cyan palette already
    /// used for column type pills elsewhere in the app.
    enum Kind {
        case scan        // Seq Scan, Index Scan, Bitmap Heap Scan, …
        case join        // Hash Join, Nested Loop, Merge Join, …
        case aggregate   // Aggregate, GroupAggregate, HashAggregate
        case sort        // Sort, Incremental Sort
        case hash        // Hash (build), Bitmap Index Scan
        case modify      // Insert, Update, Delete, Merge
        case other       // Limit, Gather, Materialize, CTE Scan, …
    }

    var kind: Kind {
        let t = nodeType.lowercased()
        if t.contains("join") || t.contains("nested loop") { return .join }
        if t.contains("aggregate") { return .aggregate }
        if t.contains("sort") { return .sort }
        if t.contains("scan") || t.contains("seek") { return .scan }
        if t == "hash" || t.contains("bitmap index") { return .hash }
        if ["insert", "update", "delete", "merge", "modifytable"].contains(t) ||
            t.hasPrefix("modify") { return .modify }
        return .other
    }
}
