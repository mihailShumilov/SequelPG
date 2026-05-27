import SwiftUI

/// The "Diagram" main tab: a schema picker and toolbar above the interactive
/// ERD canvas. Schema-scoped and connection-gated (like the Query tab). All
/// data loading goes through `AppViewModel`; this view only drives intent.
struct DiagramTabView: View {
    @Environment(AppViewModel.self) private var appVM
    @Environment(ERDViewModel.self) private var erdVM
    @State private var showExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)
            content
        }
        .task { await initialLoad() }
        .sheet(isPresented: $showExportSheet) {
            ERDExportSheet()
                .environment(erdVM)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Schema", selection: schemaSelection) {
                ForEach(erdVM.availableSchemas, id: \.self) { schema in
                    Text(schema).tag(Optional(schema))
                }
            }
            .labelsHidden()
            .frame(width: 180)
            .disabled(erdVM.isLoading || erdVM.availableSchemas.isEmpty)

            Divider().frame(height: 16)

            Button { applyAutoLayout() } label: {
                Label("Auto Layout", systemImage: "rectangle.3.offgrid")
            }
            .help("Re-arrange tables automatically")
            .disabled(erdVM.diagram == nil)

            zoomControls

            if erdVM.hasHiddenNodes {
                Button("Show All") {
                    erdVM.showAllNodes()
                    appVM.saveDiagramLayout()
                }
                .help("Reveal hidden tables")
            }

            Spacer()

            Button { reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload diagram")
            .disabled(erdVM.selectedSchema == nil || erdVM.isLoading)

            Button { showExportSheet = true } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .help("Export as PNG, SVG, or PDF")
            .disabled(erdVM.diagram == nil || erdVM.visibleNodes.isEmpty)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.bg)
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button { setZoom(erdVM.scale - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Text("\(Int((erdVM.scale * 100).rounded()))%")
                .appMono(11, color: Theme.ink3)
                .frame(width: 42)
            Button { setZoom(erdVM.scale + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Button { erdVM.resetViewport(); appVM.saveDiagramLayout() } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("Reset zoom and position")
        }
        .disabled(erdVM.diagram == nil)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if erdVM.isLoading {
            centered {
                ProgressView("Loading diagram…")
                    .controlSize(.small)
            }
        } else if let error = erdVM.errorMessage {
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.amber)
                    Text(error)
                        .appMono(12, color: Theme.ink2)
                        .multilineTextAlignment(.center)
                    Button("Retry") { reload() }
                }
                .frame(maxWidth: 360)
            }
        } else if erdVM.diagram == nil || erdVM.visibleNodes.isEmpty {
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.ink4)
                    Text(emptyMessage)
                        .appMono(12, color: Theme.ink3)
                    if erdVM.hasHiddenNodes {
                        Button("Show All Tables") {
                            erdVM.showAllNodes()
                            appVM.saveDiagramLayout()
                        }
                    }
                }
            }
        } else {
            ERDCanvasView()
        }
    }

    private var emptyMessage: String {
        if erdVM.hasHiddenNodes { return "All tables are hidden." }
        return "This schema has no tables to diagram."
    }

    private func centered(@ViewBuilder _ inner: () -> some View) -> some View {
        inner()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
    }

    // MARK: - Actions

    private var schemaSelection: Binding<String?> {
        Binding(
            get: { erdVM.selectedSchema },
            set: { newValue in
                guard let schema = newValue else { return }
                erdVM.selectedSchema = schema
                Task { await appVM.loadDiagram(schema: schema) }
            }
        )
    }

    private func initialLoad() async {
        await appVM.refreshDiagramSchemas()
        if erdVM.diagram == nil, let schema = erdVM.selectedSchema {
            await appVM.loadDiagram(schema: schema)
        }
    }

    private func reload() {
        guard let schema = erdVM.selectedSchema else { return }
        Task { await appVM.loadDiagram(schema: schema) }
    }

    private func applyAutoLayout() {
        erdVM.applyAutoLayout()
        appVM.saveDiagramLayout()
    }

    private func setZoom(_ scale: CGFloat) {
        erdVM.zoom(to: scale)
        appVM.saveDiagramLayout()
    }
}
