import Foundation

/// Translates PostgreSQL plan nodes into plain English. The EXPLAIN visualizer
/// uses this so users don't need to know that "Bitmap Heap Scan" means
/// "look up matching rows via an index, then fetch them from the table."
///
/// Each node gets three pieces:
///   - `title`    — short human label (e.g., "Index lookup")
///   - `summary`  — one-sentence "why this step exists"
///   - `findings` — zero or more plain-English flags (slow, wasted rows,
///                  planner miss-estimate)
enum PlanNarrator {
    struct Narration {
        let title: String
        let summary: String
        let findings: [Finding]
    }

    /// A piece of advisory information about a node — a bad estimate, a slow
    /// step, or a scan that read way more rows than it kept. Rendered as a
    /// short chip beneath the node row.
    struct Finding: Identifiable {
        let id = UUID()
        let severity: Severity
        let text: String

        enum Severity {
            case info     // neutral observation
            case warn     // worth a look
            case bad      // probably the cause of slowness
        }
    }

    /// Produces a narration for a single node, taking into account the totals
    /// of the whole plan so findings like "this step took 80 % of the time"
    /// can be computed.
    static func narrate(_ node: PlanNode, in plan: QueryPlan) -> Narration {
        let title = titleFor(node)
        let summary = summaryFor(node)
        let findings = findingsFor(node, in: plan)
        return Narration(title: title, summary: summary, findings: findings)
    }

    // MARK: - Title (short label)

    private static func titleFor(_ node: PlanNode) -> String {
        switch node.nodeType {
        case "Seq Scan":
            return "Read the whole table"
        case "Index Scan":
            return "Look up by index"
        case "Index Only Scan":
            return "Look up by index (no table read)"
        case "Bitmap Heap Scan":
            return "Fetch rows matched by an index"
        case "Bitmap Index Scan":
            return "Find matching rows in an index"
        case "Tid Scan":
            return "Fetch rows by physical address"
        case "Subquery Scan":
            return "Read a subquery's results"
        case "CTE Scan":
            return "Read a WITH clause's results"
        case "Function Scan":
            return "Run a function as if it were a table"
        case "Values Scan":
            return "Read inline VALUES rows"
        case "Foreign Scan":
            return "Read from a remote table"
        case "Nested Loop":
            return "Match rows row-by-row"
        case "Hash Join":
            return "Match rows using a hash table"
        case "Merge Join":
            return "Match rows using a merge"
        case "Hash":
            return "Build a hash table"
        case "Sort":
            return "Sort the rows"
        case "Incremental Sort":
            return "Finish sorting partially-sorted rows"
        case "Aggregate", "Partial Aggregate", "Finalize Aggregate":
            return aggregateTitle(for: node)
        case "Group", "Group Aggregate":
            return "Group rows together"
        case "Limit":
            return "Keep only the first few rows"
        case "Unique":
            return "Drop duplicate rows"
        case "Append":
            return "Stack results from multiple sources"
        case "Merge Append":
            return "Merge already-sorted sources"
        case "Gather", "Gather Merge":
            return "Collect rows from parallel workers"
        case "Materialize":
            return "Hold rows in memory to re-read them"
        case "Memoize":
            return "Remember repeated lookups"
        case "WindowAgg":
            return "Compute window functions"
        case "Result":
            return "Compute a single result"
        case "Lock Rows":
            return "Lock selected rows"
        case "Insert", "Update", "Delete", "Merge", "ModifyTable":
            return "Modify rows"
        default:
            return node.nodeType.isEmpty ? "Step" : node.nodeType
        }
    }

    private static func aggregateTitle(for node: PlanNode) -> String {
        let strategy = (node.details.first { $0.key == "Strategy" }?.value ?? "").lowercased()
        switch strategy {
        case "plain": return "Compute a single total"
        case "sorted": return "Group sorted rows together"
        case "hashed": return "Group rows using a hash table"
        case "mixed": return "Group rows with a hybrid strategy"
        default: return "Aggregate the rows"
        }
    }

    // MARK: - Summary (one-sentence why)

    private static func summaryFor(_ node: PlanNode) -> String {
        let target = friendlyTarget(node)
        switch node.nodeType {
        case "Seq Scan":
            return "Reads every row in \(target). Fast for small tables; slow once a table grows."
        case "Index Scan":
            return "Walks the \(indexName(node)) to find matching rows, then fetches each one from \(target)."
        case "Index Only Scan":
            return "Reads matching values straight from \(indexName(node)) without touching the table — the fastest kind of lookup."
        case "Bitmap Heap Scan":
            return "Builds a list of matching row locations using an index, then reads those rows from \(target) in one pass."
        case "Bitmap Index Scan":
            return "Walks \(indexName(node)) to collect the matching row locations."
        case "Subquery Scan":
            return "Pulls rows from a nested query and feeds them upward."
        case "CTE Scan":
            return "Replays the rows produced by a WITH (CTE) clause earlier in the query."
        case "Function Scan":
            return "Calls a set-returning function and treats its output as a table."
        case "Values Scan":
            return "Reads literal VALUES rows written into the query."
        case "Foreign Scan":
            return "Asks a remote server (via a foreign data wrapper) for matching rows."
        case "Tid Scan":
            return "Jumps straight to specific rows by physical address — usually a CURRENT OF or system query."

        case "Nested Loop":
            return "For each row on the left, looks at every relevant row on the right. Fast when one side is tiny, slow otherwise."
        case "Hash Join":
            return "Builds an in-memory hash table from one side, then probes it with the other side."
        case "Merge Join":
            return "Walks two already-sorted inputs in lockstep, pairing up matching rows."
        case "Hash":
            return "Builds the in-memory lookup table that the next Hash Join will probe."

        case "Sort":
            let key = friendlySortKey(node)
            if !key.isEmpty {
                return "Reorders the rows by \(key)."
            }
            return "Reorders the rows."
        case "Incremental Sort":
            return "Finishes sorting rows that are already partly in order — cheaper than a full sort."

        case "Aggregate", "Partial Aggregate", "Finalize Aggregate":
            let strategy = (node.details.first { $0.key == "Strategy" }?.value ?? "").lowercased()
            switch strategy {
            case "plain":
                return "Combines all incoming rows into a single result row (e.g. COUNT, SUM, MAX)."
            case "sorted":
                return "Groups rows together — the input is already sorted by the GROUP BY keys."
            case "hashed":
                return "Groups rows together using a hash table keyed on the GROUP BY columns."
            default:
                return "Combines rows into per-group results."
            }

        case "Group", "Group Aggregate":
            return "Splits rows into groups by the GROUP BY columns and rolls up aggregates."

        case "Limit":
            return "Stops returning rows after the requested count is reached."
        case "Unique":
            return "Removes consecutive duplicates from sorted input."
        case "Append":
            return "Returns the rows of each child in turn, with no merging or sorting."
        case "Merge Append":
            return "Merges already-sorted children into one combined sorted stream."
        case "Gather", "Gather Merge":
            return "Pulls rows from parallel worker processes and combines them on the leader."
        case "Materialize":
            return "Caches the rows so a parent step can read them more than once cheaply."
        case "Memoize":
            return "Caches lookup results for repeated keys — like a memoized function call."
        case "WindowAgg":
            return "Runs window-function calculations (OVER (...)) across the ordered rows."
        case "Result":
            return "Computes a constant or one-off expression — no real data scanned."
        case "Lock Rows":
            return "Acquires row-level locks (e.g. FOR UPDATE) on the rows that pass."
        case "Insert", "Update", "Delete", "Merge", "ModifyTable":
            return "Applies row changes to \(target.isEmpty ? "the target table" : target)."

        default:
            return "PostgreSQL step: \(node.nodeType)."
        }
    }

    // MARK: - Findings

    private static func findingsFor(_ node: PlanNode, in plan: QueryPlan) -> [Finding] {
        var findings: [Finding] = []

        // 1. Bad row estimate (10×+ off in either direction). Only meaningful
        //    with ANALYZE actuals.
        if let ratio = node.estimateRatio {
            if ratio > 10 {
                let times = formatRatio(ratio)
                findings.append(Finding(
                    severity: .warn,
                    text: "Planner expected \(times)× more rows than actually came out — could be hurting join order."
                ))
            } else if ratio < 0.1 {
                let times = formatRatio(1.0 / ratio)
                findings.append(Finding(
                    severity: .warn,
                    text: "Planner expected \(times)× fewer rows than actually came out — could be hurting join order."
                ))
            }
        }

        // 2. Lots of rows discarded by filter. > 90 % filtered means the index
        //    or where clause isn't doing the work it should.
        if let removed = node.rowsRemovedByFilter, let kept = node.actualRows {
            let total = removed + kept
            if total > 100, removed / total > 0.9 {
                let pct = Int((removed / total) * 100)
                findings.append(Finding(
                    severity: .warn,
                    text: "Read \(formatRows(total)) rows but threw away \(pct)% with a filter — an index on the filter column would help."
                ))
            }
        }

        // 3. Sequential scan on a "big" table. PostgreSQL doesn't tell us the
        //    table size directly, but if a Seq Scan returns > 10k rows we
        //    flag it as something worth a look.
        if node.nodeType == "Seq Scan", let rows = node.actualRows, rows > 10_000 {
            findings.append(Finding(
                severity: .info,
                text: "Read \(formatRows(rows)) rows by scanning the whole table — an index on the filter column would skip most of that."
            ))
        }

        // 4. Step dominates total time (>= 50% of execution time after
        //    subtracting children). This is the "where the time actually went"
        //    callout.
        if let execTime = plan.executionTime,
           let selfT = node.selfTime,
           execTime > 0
        {
            let pct = selfT / execTime
            if pct >= 0.5 {
                findings.append(Finding(
                    severity: .bad,
                    text: "This step alone took \(Int(pct * 100))% of the total time."
                ))
            } else if pct >= 0.25 {
                findings.append(Finding(
                    severity: .warn,
                    text: "This step took \(Int(pct * 100))% of the total time."
                ))
            }
        }

        // 5. Nested Loop with a Seq Scan child — classic accidental quadratic.
        if node.nodeType == "Nested Loop" {
            let hasSeqScanChild = node.children.contains { $0.nodeType == "Seq Scan" }
            let loops = node.actualLoops ?? 1
            if hasSeqScanChild, loops > 100 {
                findings.append(Finding(
                    severity: .bad,
                    text: "Looped over a full table scan \(formatRows(loops)) times — usually fixable with an index on the join column."
                ))
            }
        }

        return findings
    }

    // MARK: - Friendly text helpers

    /// Backtick-quoted target name used by summaries — `schema.table` when both
    /// are present, otherwise whichever piece we have.
    private static func friendlyTarget(_ node: PlanNode) -> String {
        if let rel = node.relationName {
            if let schema = node.schema, schema != "public" {
                return "`\(schema).\(rel)`"
            }
            return "`\(rel)`"
        }
        return ""
    }

    private static func indexName(_ node: PlanNode) -> String {
        if let idx = node.indexName { return "index `\(idx)`" }
        return "an index"
    }

    /// Translates the Sort Key detail array into a human phrase. PG emits the
    /// key as a string like `((u.created_at DESC), (u.id))`, which we strip
    /// down to the column list for the summary line.
    private static func friendlySortKey(_ node: PlanNode) -> String {
        let raw = node.details.first { $0.key == "Sort Key" }?.value ?? ""
        return raw
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func formatRows(_ n: Double) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", n / 1_000_000)
        }
        if n >= 10_000 {
            return String(format: "%.0fk", n / 1_000)
        }
        if n >= 1_000 {
            return String(format: "%.1fk", n / 1_000)
        }
        return String(Int(n))
    }

    private static func formatRatio(_ r: Double) -> String {
        if r >= 100 { return String(Int(r)) }
        if r >= 10 { return String(format: "%.0f", r) }
        return String(format: "%.1f", r)
    }
}

// MARK: - Plan-level overview

extension PlanNarrator {
    /// One-paragraph headline for the entire plan — what the query is doing,
    /// roughly, and what the headline number is (planning + execution time, or
    /// just the estimated cost when there's no ANALYZE).
    struct Overview {
        let headline: String
        let timing: String
    }

    static func overview(of plan: QueryPlan) -> Overview {
        let headline = headline(for: plan.root)
        let timing = timingSummary(for: plan)
        return Overview(headline: headline, timing: timing)
    }

    private static func headline(for root: PlanNode) -> String {
        // The root tells us the shape of the query at a glance. We pick the
        // top-level verb based on the root node, mostly: ModifyTable means
        // INSERT/UPDATE/DELETE, otherwise we describe the data-gathering shape.
        switch root.nodeType {
        case "Insert", "Update", "Delete", "Merge", "ModifyTable":
            return "Modifies rows."
        case "Limit":
            return "Returns a slice of the rows."
        case "Aggregate", "Partial Aggregate", "Finalize Aggregate":
            return "Rolls the rows up into one or a few aggregate values."
        case "Sort":
            return "Sorts the rows before returning them."
        case "Hash Join", "Nested Loop", "Merge Join":
            return "Joins rows from multiple sources."
        default:
            return "Reads rows from the database."
        }
    }

    private static func timingSummary(for plan: QueryPlan) -> String {
        if let exec = plan.executionTime {
            let planning = plan.planningTime ?? 0
            return "Planning \(formatMs(planning)) · Execution \(formatMs(exec)) · Total \(formatMs(planning + exec))"
        }
        // Plain EXPLAIN — no actuals, just planner estimates.
        let cost = plan.root.totalCost
        return "Estimated cost \(String(format: "%.1f", cost)) · \(Int(plan.root.planRows)) rows expected"
    }

    private static func formatMs(_ ms: Double) -> String {
        if ms < 1 {
            return String(format: "%.2f ms", ms)
        }
        if ms < 1000 {
            return String(format: "%.1f ms", ms)
        }
        return String(format: "%.2f s", ms / 1000)
    }
}
