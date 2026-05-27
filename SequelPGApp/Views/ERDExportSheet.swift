import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet for exporting the current diagram to PNG, SVG, or PDF. Mirrors the
/// app's export flow: pick options, then an `NSSavePanel` chooses the
/// destination and the file is written in-process.
struct ERDExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ERDViewModel.self) private var erdVM

    enum Format: String, CaseIterable, Identifiable {
        case png = "PNG"
        case svg = "SVG"
        case pdf = "PDF"

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .svg: return "svg"
            case .pdf: return "pdf"
            }
        }

        var detail: String {
            switch self {
            case .png: return "Raster image at the chosen scale."
            case .svg: return "Scalable vector — crisp at any size, editable."
            case .pdf: return "Single-page vector document."
            }
        }
    }

    @State private var format: Format = .png
    @State private var pngScale: Double = 2
    @State private var errorMessage: String?

    private var tableCount: Int { erdVM.visibleNodes.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export Diagram")
                .appDisplay(20)

            Picker("Format", selection: $format) {
                ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(format.detail)
                .appMono(11, color: Theme.ink3)

            if format == .png {
                HStack(spacing: 10) {
                    Text("Scale")
                        .appMono(12, color: Theme.ink2)
                    Picker("Scale", selection: $pngScale) {
                        Text("1×").tag(1.0)
                        Text("2×").tag(2.0)
                        Text("3×").tag(3.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            Text("\(tableCount) \(tableCount == 1 ? "table" : "tables") · \(erdVM.selectedSchema ?? "schema")")
                .appMono(11, color: Theme.ink4)

            if let errorMessage {
                Text(errorMessage)
                    .appMono(11, color: Theme.rose)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tableCount == 0)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Theme.bg)
    }

    private func export() {
        errorMessage = nil
        let nodes = erdVM.visibleNodes
        let edges = erdVM.visibleEdges
        guard !nodes.isEmpty else {
            errorMessage = "There are no visible tables to export."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Diagram"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(erdVM.selectedSchema ?? "schema")-erd.\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try render(nodes: nodes, edges: edges)
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func render(nodes: [ERDNode], edges: [ERDEdge]) throws -> Data {
        switch format {
        case .png:
            guard let data = ERDImageExporter.pngData(nodes: nodes, edges: edges, scale: CGFloat(pngScale)) else {
                throw ExportError.renderFailed
            }
            return data
        case .pdf:
            guard let data = ERDImageExporter.pdfData(nodes: nodes, edges: edges) else {
                throw ExportError.renderFailed
            }
            return data
        case .svg:
            return Data(ERDSVGRenderer.svg(nodes: nodes, edges: edges).utf8)
        }
    }

    private enum ExportError: LocalizedError {
        case renderFailed
        var errorDescription: String? { "Could not render the diagram." }
    }
}
