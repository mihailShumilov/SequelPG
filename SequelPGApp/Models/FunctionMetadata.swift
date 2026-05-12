import Foundation

/// Argument mode reported by `pg_proc.proargmodes`.
enum FunctionParameterMode: String, Sendable, Hashable {
    case `in` = "i"
    case out = "o"
    case inout_ = "b" // both — INOUT
    case variadic = "v"
    case tableColumn = "t" // RETURNS TABLE(...) — output only

    var displayLabel: String {
        switch self {
        case .in: return "IN"
        case .out: return "OUT"
        case .inout_: return "INOUT"
        case .variadic: return "VARIADIC"
        case .tableColumn: return "TABLE"
        }
    }

    /// Whether the caller supplies a value for this parameter. OUT and TABLE
    /// columns are output-only; everything else takes an input.
    var takesInput: Bool {
        switch self {
        case .in, .inout_, .variadic: return true
        case .out, .tableColumn: return false
        }
    }
}

/// One input/output slot in a function or procedure signature.
struct FunctionParameter: Sendable, Hashable, Identifiable {
    let position: Int       // 1-based position among ALL params (including OUT/TABLE)
    let name: String?       // nil for anonymous positional args
    let mode: FunctionParameterMode
    let typeName: String    // pg_catalog.format_type, e.g. "integer", "text[]", "numeric(10,2)"
    let hasDefault: Bool    // pg_proc.pronargdefaults bookkeeping

    var id: Int { position }
}

/// What the routine returns. Drives how the Run sheet shapes its `SELECT … FROM fn(…)`
/// vs `SELECT fn(…)` vs `CALL proc(…)` and how to render the result.
struct FunctionReturn: Sendable, Hashable {
    let typeName: String     // formatted type name, or "void", or "trigger", or "SETOF foo"
    let isSetReturning: Bool // pg_proc.proretset
    let isVoid: Bool
    let isTrigger: Bool
    let isTable: Bool        // RETURNS TABLE(...) — implies set-returning
}

/// What kind of callable this is. Mirrors pg_proc.prokind on PG11+.
enum FunctionKind: Sendable, Hashable {
    case function
    case procedure
    case aggregate
    case window

    var displayName: String {
        switch self {
        case .function: return "Function"
        case .procedure: return "Procedure"
        case .aggregate: return "Aggregate"
        case .window: return "Window Function"
        }
    }
}

/// Snapshot of one resolved `pg_proc` entry — enough to build a runnable
/// SELECT/CALL with type-correct arguments.
struct FunctionMetadata: Sendable, Hashable {
    let schema: String
    let name: String                       // base name, no signature
    let signature: String                  // "(integer, text)" — argtypes only, parens included
    let kind: FunctionKind
    let parameters: [FunctionParameter]
    let returnInfo: FunctionReturn

    /// User-facing one-line signature suitable for the sheet header, e.g.
    /// `app.compute(amount integer, memo text) → setof record`.
    var displaySignature: String {
        let args = parameters
            .map { p in
                let mode = p.mode == .in ? "" : "\(p.mode.displayLabel) "
                let nm = p.name.map { "\($0) " } ?? ""
                return "\(mode)\(nm)\(p.typeName)"
            }
            .joined(separator: ", ")
        let setof = returnInfo.isSetReturning && !returnInfo.isTable ? "SETOF " : ""
        return "\(schema).\(name)(\(args)) → \(setof)\(returnInfo.typeName)"
    }

    /// Parameters the user must supply values for, in declaration order.
    var inputParameters: [FunctionParameter] {
        parameters.filter { $0.mode.takesInput }
    }
}

/// One row from the FunctionRunSheet's parameter grid. Tracked separately
/// from `FunctionParameter` so the model stays immutable while the view's
/// pending edits live in their own value type.
struct FunctionRunArgument: Identifiable, Hashable {
    enum Mode: String, Hashable {
        case value          // quoted literal, e.g. E'foo'::text
        case expression     // verbatim — for now(), gen_random_uuid(), ARRAY[…]
        case null           // emits NULL
        case useDefault     // omit from call (only valid when the param has DEFAULT)
    }

    let parameter: FunctionParameter
    var text: String = ""
    var mode: Mode

    var id: Int { parameter.position }

    init(parameter: FunctionParameter) {
        self.parameter = parameter
        // Honor declared DEFAULTs by skipping the param from the call. Users
        // can flip back to .value to override.
        self.mode = parameter.hasDefault ? .useDefault : .value
    }
}

/// Builds the SQL the Run sheet executes. Pulled out of the view so the
/// (security-sensitive) literal-vs-expression branching is unit-testable
/// without spinning up SwiftUI.
enum FunctionCallBuilder {
    /// Returns nil when an expression argument fails injection validation —
    /// the sheet surfaces this as an inline error instead of running the call.
    static func buildSQL(metadata: FunctionMetadata, arguments: [FunctionRunArgument]) -> Result<String, BuildError> {
        // Match arguments back to parameter positions; users may have edited
        // any subset.
        let argByPosition = Dictionary(uniqueKeysWithValues: arguments.map { ($0.parameter.position, $0) })

        // PG accepts `name => value` for any parameter that has a name. We
        // use named notation whenever every supplied-input param has a name,
        // because it keeps the generated SQL readable and lets us skip
        // defaulted params without breaking positional ordering.
        let inputParams = metadata.inputParameters
        let allNamed = inputParams.allSatisfy { ($0.name?.isEmpty == false) }

        var pieces: [String] = []
        for param in inputParams {
            guard let arg = argByPosition[param.position] else { continue }
            switch arg.mode {
            case .useDefault:
                continue // PG fills in the DEFAULT
            case .null:
                pieces.append(formatPiece("NULL", for: param, named: allNamed, castType: nil))
            case .value:
                let text = arg.text
                let literal = quoteLiteral(.text(text))
                // Cast to the declared type so PG resolves the overload
                // unambiguously; text-like types skip the cast to keep the
                // SQL readable.
                let cast = needsExplicitCast(param.typeName) ? param.typeName : nil
                pieces.append(formatPiece(literal, for: param, named: allNamed, castType: cast))
            case .expression:
                let text = arg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return .failure(.emptyExpression(parameter: param))
                }
                guard isValidSQLExpression(text) else {
                    return .failure(.unsafeExpression(parameter: param))
                }
                pieces.append(formatPiece(text, for: param, named: allNamed, castType: nil))
            }
        }

        let argList = pieces.joined(separator: ", ")
        let qualifiedName = "\(quoteIdent(metadata.schema)).\(quoteIdent(metadata.name))"

        switch metadata.kind {
        case .procedure:
            return .success("CALL \(qualifiedName)(\(argList))")
        case .function, .window, .aggregate:
            if metadata.returnInfo.isVoid {
                // void-returning function — still callable but no useful column
                return .success("SELECT \(qualifiedName)(\(argList))")
            }
            if metadata.returnInfo.isSetReturning {
                return .success("SELECT * FROM \(qualifiedName)(\(argList))")
            }
            return .success("SELECT \(qualifiedName)(\(argList)) AS result")
        }
    }

    enum BuildError: Error, Hashable {
        case unsafeExpression(parameter: FunctionParameter)
        case emptyExpression(parameter: FunctionParameter)
    }

    private static func formatPiece(
        _ value: String,
        for param: FunctionParameter,
        named: Bool,
        castType: String?
    ) -> String {
        let body: String
        if let castType, isValidTypeName(castType) {
            body = "\(value)::\(castType)"
        } else {
            body = value
        }
        if named, let name = param.name, !name.isEmpty {
            return "\(quoteIdent(name)) => \(body)"
        }
        return body
    }

    private static let textLikeTypeNames: Set<String> = [
        "text", "character varying", "varchar", "character", "char",
        "name", "\"char\"",
    ]

    /// Skip the `::type` cast for text-shaped types where PG already
    /// promotes a string literal without help. Everything else gets an
    /// explicit cast — without it `'42'` could resolve to a wrong overload.
    private static func needsExplicitCast(_ typeName: String) -> Bool {
        let lower = typeName.lowercased().trimmingCharacters(in: .whitespaces)
        return !textLikeTypeNames.contains(lower)
    }
}
