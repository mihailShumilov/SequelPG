import CoreGraphics
import Foundation

/// Persisted, user-controlled view state for one schema's diagram: where each
/// table sits, which are collapsed/hidden, and the viewport zoom/pan. Stored as
/// JSON by `ERDLayoutStore`, keyed by connection profile + schema.
///
/// `schemaVersion` is bumped if the on-disk shape changes; loaders treat an
/// unknown future version as "no saved layout" rather than crashing, and the
/// fields are all defaulted so older files decode forward cleanly.
struct ERDLayout: Codable, Equatable {
    /// Current on-disk format version. Phase 2 may grow this struct.
    static let currentVersion = 1

    var schemaVersion: Int
    /// Node id (`schema.table`) → top-left origin in diagram coordinates.
    var positions: [String: CGPoint]
    /// Node ids the user collapsed to header-only.
    var collapsed: Set<String>
    /// Node ids the user hid from the canvas.
    var hidden: Set<String>
    /// Viewport zoom factor (1.0 == 100%).
    var scale: CGFloat
    /// Viewport pan offset.
    var offset: CGPoint

    init(
        schemaVersion: Int = ERDLayout.currentVersion,
        positions: [String: CGPoint] = [:],
        collapsed: Set<String> = [],
        hidden: Set<String> = [],
        scale: CGFloat = 1,
        offset: CGPoint = .zero
    ) {
        self.schemaVersion = schemaVersion
        self.positions = positions
        self.collapsed = collapsed
        self.hidden = hidden
        self.scale = scale
        self.offset = offset
    }

    /// Whether this layout was written by a format version this build understands.
    var isReadable: Bool {
        schemaVersion <= ERDLayout.currentVersion
    }
}
