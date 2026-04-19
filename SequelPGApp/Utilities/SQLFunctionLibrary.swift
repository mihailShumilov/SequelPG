import Foundation

/// Curated catalog of frequently-used built-in PostgreSQL functions, grouped
/// by category. Keeps the SQL editor completion suggestions useful without
/// reading from `pg_proc` on every keystroke.
enum SQLFunctionLibrary {
    struct Entry: Identifiable, Hashable {
        let id: String
        let name: String
        /// Signature label for UI display: e.g. `substring(string, from, for)`.
        let signature: String
        /// One-line summary describing what the function does.
        let summary: String
        let category: Category

        init(name: String, signature: String, summary: String, category: Category) {
            self.id = "\(category.rawValue).\(name).\(signature)"
            self.name = name
            self.signature = signature
            self.summary = summary
            self.category = category
        }
    }

    enum Category: String, CaseIterable, Identifiable {
        var id: String { rawValue }
        case string = "String"
        case numeric = "Numeric"
        case dateTime = "Date / Time"
        case jsonb = "JSON / JSONB"
        case aggregate = "Aggregate"
        case window = "Window"
        case array = "Array"
    }

    /// The complete catalog. Small on purpose — covers the ~50 functions a
    /// typical user reaches for; not an exhaustive mirror of `pg_proc`.
    static let all: [Entry] = [
        // String
        .init(name: "substring", signature: "substring(string, from, for)", summary: "Extract substring by position", category: .string),
        .init(name: "trim", signature: "trim([both|leading|trailing] chars from string)", summary: "Strip characters from ends", category: .string),
        .init(name: "ltrim", signature: "ltrim(string [, chars])", summary: "Strip characters from left end", category: .string),
        .init(name: "rtrim", signature: "rtrim(string [, chars])", summary: "Strip characters from right end", category: .string),
        .init(name: "left", signature: "left(string, n)", summary: "First n characters", category: .string),
        .init(name: "right", signature: "right(string, n)", summary: "Last n characters", category: .string),
        .init(name: "lower", signature: "lower(string)", summary: "Lowercase", category: .string),
        .init(name: "upper", signature: "upper(string)", summary: "Uppercase", category: .string),
        .init(name: "length", signature: "length(string)", summary: "Character count", category: .string),
        .init(name: "position", signature: "position(substring in string)", summary: "Index of substring (1-based)", category: .string),
        .init(name: "regexp_replace", signature: "regexp_replace(string, pattern, replacement [, flags])", summary: "Regex-based replacement", category: .string),
        .init(name: "regexp_matches", signature: "regexp_matches(string, pattern [, flags])", summary: "Extract regex matches", category: .string),
        .init(name: "split_part", signature: "split_part(string, delimiter, n)", summary: "Split by delimiter; return nth part", category: .string),
        .init(name: "format", signature: "format(format_string, args...)", summary: "printf-style formatting", category: .string),
        .init(name: "concat", signature: "concat(str1, str2, ...)", summary: "Concatenate ignoring nulls", category: .string),
        .init(name: "concat_ws", signature: "concat_ws(sep, str1, str2, ...)", summary: "Concatenate with separator", category: .string),

        // Numeric
        .init(name: "abs", signature: "abs(x)", summary: "Absolute value", category: .numeric),
        .init(name: "ceil", signature: "ceil(x)", summary: "Ceiling", category: .numeric),
        .init(name: "floor", signature: "floor(x)", summary: "Floor", category: .numeric),
        .init(name: "round", signature: "round(x [, digits])", summary: "Round to nearest", category: .numeric),
        .init(name: "trunc", signature: "trunc(x [, digits])", summary: "Truncate toward zero", category: .numeric),
        .init(name: "mod", signature: "mod(x, y)", summary: "Remainder", category: .numeric),
        .init(name: "power", signature: "power(x, y)", summary: "x raised to y", category: .numeric),
        .init(name: "random", signature: "random()", summary: "Random value in [0, 1)", category: .numeric),
        .init(name: "greatest", signature: "greatest(v1, v2, ...)", summary: "Largest non-null value", category: .numeric),
        .init(name: "least", signature: "least(v1, v2, ...)", summary: "Smallest non-null value", category: .numeric),

        // Date / Time
        .init(name: "now", signature: "now()", summary: "Current transaction timestamp", category: .dateTime),
        .init(name: "current_date", signature: "current_date", summary: "Today's date", category: .dateTime),
        .init(name: "current_timestamp", signature: "current_timestamp", summary: "Current statement timestamp", category: .dateTime),
        .init(name: "date_trunc", signature: "date_trunc(field, source [, time_zone])", summary: "Truncate timestamp to precision", category: .dateTime),
        .init(name: "date_part", signature: "date_part(field, source)", summary: "Extract named component", category: .dateTime),
        .init(name: "extract", signature: "extract(field FROM source)", summary: "Extract named component", category: .dateTime),
        .init(name: "age", signature: "age(timestamp [, timestamp])", summary: "Interval between timestamps", category: .dateTime),
        .init(name: "to_char", signature: "to_char(value, format)", summary: "Format as text", category: .dateTime),
        .init(name: "to_date", signature: "to_date(text, format)", summary: "Parse as date", category: .dateTime),
        .init(name: "to_timestamp", signature: "to_timestamp(text, format)", summary: "Parse as timestamp", category: .dateTime),
        .init(name: "generate_series", signature: "generate_series(start, stop [, step])", summary: "Series of dates/numbers", category: .dateTime),

        // JSON / JSONB
        .init(name: "jsonb_set", signature: "jsonb_set(target, path, new_value [, create_missing])", summary: "Update value at JSONB path", category: .jsonb),
        .init(name: "jsonb_agg", signature: "jsonb_agg(expression)", summary: "Aggregate values into JSONB array", category: .jsonb),
        .init(name: "jsonb_build_object", signature: "jsonb_build_object(key, value, ...)", summary: "Build JSONB from key/value pairs", category: .jsonb),
        .init(name: "jsonb_build_array", signature: "jsonb_build_array(value, ...)", summary: "Build JSONB array", category: .jsonb),
        .init(name: "jsonb_array_elements", signature: "jsonb_array_elements(jsonb)", summary: "Expand array to set", category: .jsonb),
        .init(name: "jsonb_object_keys", signature: "jsonb_object_keys(jsonb)", summary: "Top-level keys", category: .jsonb),
        .init(name: "jsonb_each", signature: "jsonb_each(jsonb)", summary: "Expand top-level key/value pairs", category: .jsonb),

        // Aggregate
        .init(name: "count", signature: "count(*) / count(expr)", summary: "Row count", category: .aggregate),
        .init(name: "sum", signature: "sum(expr)", summary: "Total", category: .aggregate),
        .init(name: "avg", signature: "avg(expr)", summary: "Mean", category: .aggregate),
        .init(name: "min", signature: "min(expr)", summary: "Smallest value", category: .aggregate),
        .init(name: "max", signature: "max(expr)", summary: "Largest value", category: .aggregate),
        .init(name: "string_agg", signature: "string_agg(expr, delimiter)", summary: "Concatenate strings", category: .aggregate),
        .init(name: "array_agg", signature: "array_agg(expr)", summary: "Aggregate into array", category: .aggregate),
        .init(name: "percentile_cont", signature: "percentile_cont(fraction) WITHIN GROUP (ORDER BY expr)", summary: "Continuous percentile", category: .aggregate),
        .init(name: "mode", signature: "mode() WITHIN GROUP (ORDER BY expr)", summary: "Most frequent value", category: .aggregate),

        // Window
        .init(name: "row_number", signature: "row_number() OVER (...)", summary: "Sequential row number", category: .window),
        .init(name: "rank", signature: "rank() OVER (...)", summary: "Rank with gaps", category: .window),
        .init(name: "dense_rank", signature: "dense_rank() OVER (...)", summary: "Rank without gaps", category: .window),
        .init(name: "lag", signature: "lag(expr [, offset [, default]]) OVER (...)", summary: "Value from previous row", category: .window),
        .init(name: "lead", signature: "lead(expr [, offset [, default]]) OVER (...)", summary: "Value from next row", category: .window),
        .init(name: "first_value", signature: "first_value(expr) OVER (...)", summary: "First value in window", category: .window),
        .init(name: "last_value", signature: "last_value(expr) OVER (...)", summary: "Last value in window", category: .window),

        // Array
        .init(name: "array_length", signature: "array_length(anyarray, dim)", summary: "Length along dimension", category: .array),
        .init(name: "unnest", signature: "unnest(anyarray)", summary: "Expand array to rows", category: .array),
        .init(name: "array_append", signature: "array_append(anyarray, elem)", summary: "Append element", category: .array),
        .init(name: "array_remove", signature: "array_remove(anyarray, elem)", summary: "Remove all occurrences of elem", category: .array),
    ]

    /// Quick lookup: all function names in lowercase — used by the editor
    /// autocomplete to suggest functions alongside keywords/tables/columns.
    static let names: [String] = all.map(\.name)
}
