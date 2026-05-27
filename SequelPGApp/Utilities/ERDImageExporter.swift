import AppKit
import SwiftUI

/// Rasterizes/vectorizes the diagram to PNG or PDF by running the same
/// `ERDDiagramContentView` used on screen through SwiftUI's `ImageRenderer`.
/// Rendering the full-extent content view (not the zoomed viewport) means
/// exports always capture the entire diagram at full fidelity.
///
/// `@MainActor` because `ImageRenderer` must build the SwiftUI view tree on the
/// main actor.
@MainActor
enum ERDImageExporter {
    /// PNG data at `scale`× pixel density (e.g. 2 for retina-quality output),
    /// or `nil` if the renderer could not produce an image.
    static func pngData(nodes: [ERDNode], edges: [ERDEdge], scale: CGFloat) -> Data? {
        let renderer = ImageRenderer(content: content(nodes: nodes, edges: edges))
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: cgImage.width, height: cgImage.height)
        return rep.representation(using: .png, properties: [:])
    }

    /// Single-page vector PDF sized to the diagram bounds, or `nil` on failure.
    static func pdfData(nodes: [ERDNode], edges: [ERDEdge]) -> Data? {
        let renderer = ImageRenderer(content: content(nodes: nodes, edges: edges))
        let data = NSMutableData()
        var produced = false
        renderer.render { size, renderInContext in
            var mediaBox = CGRect(origin: .zero, size: size)
            guard
                let consumer = CGDataConsumer(data: data as CFMutableData),
                let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
            else {
                return
            }
            context.beginPDFPage(nil)
            renderInContext(context)
            context.endPDFPage()
            context.closePDF()
            produced = true
        }
        return produced ? (data as Data) : nil
    }

    private static func content(nodes: [ERDNode], edges: [ERDEdge]) -> some View {
        ERDDiagramContentView(nodes: nodes, edges: edges, selectedNodeID: nil, background: Theme.bg)
    }
}
