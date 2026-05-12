import AppKit
import SwiftUI

/// Focused builder for invoking a function or procedure. Loads pg_proc metadata,
/// renders one typed input per parameter, builds a SELECT/CALL with explicit
/// type casts, and displays the result inline without leaving the sheet.
///
/// Disabled (with an explanation) for trigger functions and aggregates, which
/// can't be invoked directly via SELECT.
struct FunctionRunSheet: View {
    let object: DBObject
    @Environment(AppViewModel.self) var appVM
    @Environment(\.dismiss) private var dismiss

    @State private var loadState: LoadState = .loading
    @State private var arguments: [FunctionRunArgument] = []
    @State private var isRunning = false
    @State private var lastSQL: String = ""
    @State private var result: QueryResult?
    @State private var scalarValue: CellValue?
    @State private var scalarColumn: String?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showSQLPreview = false
    @State private var selectedRowIndex: Int?

    enum LoadState: Equatable {
        case loading
        case loaded(FunctionMetadata)
        case unrunnable(reason: String, metadata: FunctionMetadata?)
        case failed(String)

        var metadata: FunctionMetadata? {
            switch self {
            case .loaded(let m): return m
            case .unrunnable(_, let m): return m
            default: return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch loadState {
            case .loading:
                loadingView
            case .failed(let msg):
                failureView(message: msg)
            case .unrunnable(let reason, let metadata):
                unrunnableView(reason: reason, metadata: metadata)
            case .loaded(let metadata):
                content(metadata: metadata)
            }

            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 620)
        .task(id: object.id) {
            await loadMetadata()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIcon)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                if let metadata = loadState.metadata {
                    Text(metadata.displaySignature)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(metadata.displaySignature)
                } else {
                    Text("\(object.schema).\(object.name)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerIcon: String {
        switch object.type {
        case .procedure: return "gearshape.fill"
        case .triggerFunction: return "bolt.fill"
        case .aggregate: return "sum"
        default: return "function"
        }
    }

    private var headerTitle: String {
        switch object.type {
        case .procedure: return "Call Procedure"
        case .triggerFunction: return "Trigger Function"
        case .aggregate: return "Aggregate"
        default: return "Run Function"
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading signature…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .font(.title)
                .foregroundStyle(.red)
            Text("Could not load function metadata")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func unrunnableView(reason: String, metadata: FunctionMetadata?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("This routine can't be invoked from here")
                .font(.headline)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let metadata, !metadata.inputParameters.isEmpty {
                Text("Signature: \(metadata.displaySignature)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func content(metadata: FunctionMetadata) -> some View {
        VSplitView {
            parametersPane(metadata: metadata)
                .frame(minHeight: 160)
            resultsPane
                .frame(minHeight: 140)
        }
    }

    // MARK: - Parameters pane

    @ViewBuilder
    private func parametersPane(metadata: FunctionMetadata) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Parameters")
                    .font(.headline)
                Spacer()
                Toggle("Show SQL", isOn: $showSQLPreview)
                    .toggleStyle(.button)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if arguments.isEmpty {
                Text("No input parameters — click Run to invoke.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($arguments) { $arg in
                            parameterRow(arg: $arg)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }

            if showSQLPreview {
                sqlPreview(metadata: metadata)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func parameterRow(arg: Binding<FunctionRunArgument>) -> some View {
        let param = arg.wrappedValue.parameter
        HStack(alignment: .center, spacing: 8) {
            // Name + position
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(param.name ?? "$\(param.position)")
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                    if param.mode != .in {
                        Text(param.mode.displayLabel)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(modeColor(param.mode).opacity(0.18))
                            .foregroundStyle(modeColor(param.mode))
                            .clipShape(.rect(cornerRadius: 3))
                    }
                }
                Text(param.typeName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 160, alignment: .leading)
            .help("Position \(param.position)")

            // Value editor — disabled when mode != .value/.expression
            TextField(placeholder(for: param, mode: arg.wrappedValue.mode), text: arg.text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: arg.wrappedValue.mode == .expression ? .monospaced : .default))
                .disabled(arg.wrappedValue.mode == .null || arg.wrappedValue.mode == .useDefault)

            // Mode picker — collapsed to an icon-only Picker to keep rows tidy.
            modePicker(arg: arg, hasDefault: param.hasDefault)
        }
    }

    @ViewBuilder
    private func modePicker(arg: Binding<FunctionRunArgument>, hasDefault: Bool) -> some View {
        Picker(selection: arg.mode) {
            Text("Value").tag(FunctionRunArgument.Mode.value)
            Text("Expression").tag(FunctionRunArgument.Mode.expression)
            Text("NULL").tag(FunctionRunArgument.Mode.null)
            if hasDefault {
                Text("DEFAULT").tag(FunctionRunArgument.Mode.useDefault)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .frame(width: 124)
        .controlSize(.small)
        .help(modeHelp)
    }

    private var modeHelp: String {
        """
        Value: quote-escape and cast to the declared type.
        Expression: insert verbatim (use for now(), gen_random_uuid(), ARRAY[…]).
        NULL: send a NULL value.
        DEFAULT: omit so the function applies its declared default.
        """
    }

    private func placeholder(for param: FunctionParameter, mode: FunctionRunArgument.Mode) -> String {
        switch mode {
        case .null: return "NULL"
        case .useDefault: return "(using declared default)"
        case .expression: return "SQL expression — e.g. now()"
        case .value:
            return typePlaceholder(param.typeName)
        }
    }

    private func typePlaceholder(_ type: String) -> String {
        let lower = type.lowercased()
        if lower.contains("int") { return "0" }
        if lower.contains("numeric") || lower.contains("decimal") { return "0.00" }
        if lower == "boolean" { return "true / false" }
        if lower.contains("uuid") { return "00000000-0000-0000-0000-000000000000" }
        if lower.contains("timestamp") || lower == "date" { return "2026-01-01 00:00:00" }
        if lower.contains("json") { return "{}" }
        if lower.contains("[]") { return "{1,2,3}" }
        return ""
    }

    private func modeColor(_ mode: FunctionParameterMode) -> Color {
        switch mode {
        case .out: return .orange
        case .inout_: return .purple
        case .variadic: return .blue
        case .tableColumn: return .gray
        case .in: return .secondary
        }
    }

    // MARK: - SQL preview

    @ViewBuilder
    private func sqlPreview(metadata: FunctionMetadata) -> some View {
        let preview = currentSQL(metadata: metadata)
        VStack(alignment: .leading, spacing: 4) {
            Text("Generated SQL")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(preview)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func currentSQL(metadata: FunctionMetadata) -> String {
        switch FunctionCallBuilder.buildSQL(metadata: metadata, arguments: arguments) {
        case .success(let sql): return sql
        case .failure(let err):
            switch err {
            case .emptyExpression(let p):
                return "-- expression for parameter \(p.name ?? "$\(p.position)") is empty"
            case .unsafeExpression(let p):
                return "-- expression for parameter \(p.name ?? "$\(p.position)") was rejected by safety check"
            }
        }
    }

    // MARK: - Results pane

    @ViewBuilder
    private var resultsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Result")
                    .font(.headline)
                Spacer()
                if let result {
                    Text("\(result.rowCount) row\(result.rowCount == 1 ? "" : "s") · \(String(format: "%.3f", result.executionTime))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if let errorMessage {
                errorBanner(errorMessage)
            } else if isRunning {
                ProgressView("Running…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result {
                if result.columns.isEmpty {
                    resultCompletionView()
                } else if isScalarSingleValue(result) {
                    scalarResultView(value: result.rows[0][0], column: result.columns[0])
                } else {
                    ResultsGridView(
                        result: result,
                        selectedRowIndex: $selectedRowIndex
                    )
                }
            } else if let statusMessage {
                resultCompletionView(custom: statusMessage)
            } else {
                placeholderResult
            }
        }
    }

    private var placeholderResult: some View {
        VStack(spacing: 6) {
            Image(systemName: "play.circle")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Fill in parameters and press Run to invoke.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultCompletionView(custom: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text(custom ?? defaultCompletionText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var defaultCompletionText: String {
        switch object.type {
        case .procedure: return "Procedure completed."
        default: return "Executed."
        }
    }

    private func scalarResultView(value: CellValue, column: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(column)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(value.isNull ? "NULL" : value.displayString)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(value.isNull ? .secondary : .primary)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func isScalarSingleValue(_ result: QueryResult) -> Bool {
        result.columns.count == 1 && result.rows.count == 1
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .lineLimit(8)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.1))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let metadata = loadState.metadata {
                Button("Copy SQL") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(currentSQL(metadata: metadata), forType: .string)
                }
                .disabled(!canRun(metadata: metadata))
                .help("Copy the generated call to the clipboard")

                Button("Edit in Query") {
                    appVM.queryVM.queryText = currentSQL(metadata: metadata)
                    appVM.selectedTab = .query
                    dismiss()
                }
                .disabled(!canRun(metadata: metadata))
                .help("Open this call in the Query tab for further editing")
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if case .loaded(let metadata) = loadState {
                Button(runButtonLabel(metadata: metadata)) {
                    Task { await runCall(metadata: metadata) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || !canRun(metadata: metadata))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func runButtonLabel(metadata: FunctionMetadata) -> String {
        switch metadata.kind {
        case .procedure: return "Call"
        default: return "Run"
        }
    }

    private func canRun(metadata: FunctionMetadata) -> Bool {
        // We can always *try* — invalid expressions surface as build errors
        // at run time. But block runs while metadata is loading.
        _ = metadata
        return !isRunning
    }

    // MARK: - Actions

    private func loadMetadata() async {
        // Trigger functions and aggregates can't be invoked directly; tell the
        // user up front rather than letting them build a call that PG rejects.
        switch object.type {
        case .triggerFunction:
            loadState = .unrunnable(
                reason: "Trigger functions are only invoked by triggers — they don't accept arguments and can't be called from SELECT.",
                metadata: nil
            )
            return
        case .aggregate:
            loadState = .unrunnable(
                reason: "Aggregates are invoked over result sets — write a SELECT in the Query tab instead, e.g. SELECT \(object.schema).\(object.name)(col) FROM …",
                metadata: nil
            )
            return
        case .function, .procedure:
            break
        default:
            loadState = .failed("Unsupported object type: \(object.type.rawValue)")
            return
        }

        do {
            let metadata = try await appVM.dbClient.getFunctionMetadata(schema: object.schema, name: object.name)
            // Pre-flight: trigger functions slip through if the navigator
            // miscategorized them — double-check by return type.
            if metadata.returnInfo.isTrigger {
                loadState = .unrunnable(
                    reason: "This function returns trigger and can only be invoked by a trigger.",
                    metadata: metadata
                )
                return
            }
            arguments = metadata.inputParameters.map { FunctionRunArgument(parameter: $0) }
            loadState = .loaded(metadata)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func runCall(metadata: FunctionMetadata) async {
        errorMessage = nil
        statusMessage = nil
        result = nil
        scalarValue = nil

        switch FunctionCallBuilder.buildSQL(metadata: metadata, arguments: arguments) {
        case .failure(let err):
            switch err {
            case .emptyExpression(let p):
                errorMessage = "Expression for parameter \(p.name ?? "$\(p.position)") is empty. Either enter a SQL expression or switch the row to Value / NULL / DEFAULT."
            case .unsafeExpression(let p):
                errorMessage = "Expression for parameter \(p.name ?? "$\(p.position)") was rejected by safety check. Multi-statement expressions and DDL keywords aren't allowed here — drop into the Query tab for unrestricted SQL."
            }
            return
        case .success(let sql):
            lastSQL = sql
            isRunning = true
            defer { isRunning = false }
            do {
                let res = try await appVM.dbClient.runQuery(
                    sql,
                    maxRows: AppViewModel.maxQueryRows,
                    timeout: AppViewModel.defaultQueryTimeout
                )
                result = res
                // Procedures that don't return rows surface as 0-column results;
                // give a friendlier message than an empty grid.
                if metadata.kind == .procedure, res.columns.isEmpty {
                    statusMessage = "Procedure \(metadata.schema).\(metadata.name) completed."
                }
                appVM.queryHistoryVM.logQuery(
                    sql: sql,
                    source: .system,
                    duration: res.executionTime,
                    success: true,
                    rowCount: res.rowCount
                )
            } catch {
                errorMessage = error.localizedDescription
                appVM.queryHistoryVM.logQuery(
                    sql: sql,
                    source: .system,
                    success: false,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }
}
