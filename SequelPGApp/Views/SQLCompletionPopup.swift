import AppKit
import Observation
import SwiftUI

// A JetBrains-style autocompletion popup for the SQL editor.
//
// The hard constraint, learned from the abandoned first attempt (see the
// `SQLCompletionWindow.swift` tombstone): the popup must NOT steal key focus
// from the editor's NSTextView. If it does, typed characters get mis-routed
// and the popup latches onto stale partials.
//
// The design here keeps the NSTextView as the sole first responder at all
// times. The popup is a **non-activating** `NSPanel` (`canBecomeKey == false`)
// attached as a child window — purely a visual surface. The text view handles
// every key event itself: while the popup is visible it forwards ↑/↓/Tab/
// Return/Esc to the controller; all other keys type normally and the popup
// simply re-queries afterwards. No event monitors, no responder games.

// MARK: - Model

/// Observable state backing the popup's SwiftUI list. The controller mutates
/// `items` / `selectedIndex`; the hosted `CompletionListView` re-renders.
@MainActor
@Observable
final class CompletionListModel {
    var items: [CompletionItem] = []
    var selectedIndex: Int = 0
}

// MARK: - SwiftUI list

/// Themed completion list — one row per candidate, with a kind chip, the label
/// (matched characters bolded in the accent color), and a trailing type/detail.
/// Display-only: selection is driven by the model, not by focus, because the
/// hosting panel never becomes key.
struct CompletionListView: View {
    let model: CompletionListModel
    /// Invoked when a row is clicked. Carries the row index.
    var onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.items.indices, id: \.self) { idx in
                        CompletionRow(item: model.items[idx], isSelected: idx == model.selectedIndex)
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(idx) }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.selectedIndex) { _, newValue in
                proxy.scrollTo(newValue, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.line2, lineWidth: 1)
        )
    }
}

private struct CompletionRow: View {
    let item: CompletionItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(item.kind.chip)
                .font(Theme.mono(size: 9, weight: .medium))
                .tracking(0.5)
                .textCase(.uppercase)
                .frame(width: 30, alignment: .leading)
                .foregroundStyle(item.kind.tint)

            Text(highlightedLabel)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(item.detail)
                .font(Theme.mono(size: 10))
                .foregroundStyle(Theme.ink4)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: SQLCompletionMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.accent.opacity(0.18) : Color.clear)
    }

    /// The label with matched characters drawn bold and accent-colored, the
    /// rest in regular ink — the JetBrains "what you typed lights up" cue.
    private var highlightedLabel: AttributedString {
        let matched = matchedOffsets
        var result = AttributedString()
        for (offset, character) in item.label.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) {
                piece.font = Theme.mono(size: 12.5, weight: .bold)
                piece.foregroundColor = Theme.accent
            } else {
                piece.font = Theme.mono(size: 12.5)
                piece.foregroundColor = Theme.ink
            }
            result.append(piece)
        }
        return result
    }

    /// Converts the item's `matchedRanges` (String.Index ranges into `label`)
    /// to a set of integer character offsets for per-character styling.
    private var matchedOffsets: Set<Int> {
        var offsets: Set<Int> = []
        for range in item.matchedRanges {
            let lower = item.label.distance(from: item.label.startIndex, to: range.lowerBound)
            let upper = item.label.distance(from: item.label.startIndex, to: range.upperBound)
            if lower < upper { offsets.formUnion(lower ..< upper) }
        }
        return offsets
    }
}

private extension CompletionItem.Kind {
    /// Accent color for the kind chip — mirrors the syntax/type palette.
    var tint: Color {
        switch self {
        case .keyword: return Theme.blue
        case .schema: return Theme.violet
        case .table: return Theme.amber
        case .column: return Theme.cyan
        case .function: return Theme.mauve
        }
    }
}

// MARK: - Panel

/// Non-activating floating panel. `canBecomeKey` is false so presenting it
/// never pulls first-responder status away from the editor's text view.
final class CompletionPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: SQLCompletionMetrics.width, height: SQLCompletionMetrics.rowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = true
        isMovableByWindowBackground = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        // Clear the standard panel background so the SwiftUI rounded card and
        // its shadow are the only thing drawn.
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Metrics

enum SQLCompletionMetrics {
    static let rowHeight: CGFloat = 24
    static let width: CGFloat = 380
    static let maxVisibleRows = 10
    /// Vertical chrome around the list (the LazyVStack's top+bottom padding).
    static let verticalInset: CGFloat = 8
}

// MARK: - Controller

/// Owns the popup panel and mediates between the editor's text view and the
/// completion model. The text view forwards key intents (move/accept/dismiss)
/// here; the coordinator pushes fresh candidate lists here via `present`.
@MainActor
final class SQLCompletionController {
    let model = CompletionListModel()
    /// The document range the accepted completion replaces (the partial word
    /// under the caret when the popup was last presented).
    var partialRange = NSRange(location: 0, length: 0)

    private weak var textView: CompletionTextView?
    private let panel: CompletionPanel
    private var dismissObservers: [NSObjectProtocol] = []

    var isVisible: Bool { panel.isVisible }

    init() {
        // Build the panel up front; show/hide just orders it in and out.
        let model = self.model
        var pickHandler: ((Int) -> Void)?
        let host = NSHostingView(
            rootView: CompletionListView(model: model, onPick: { pickHandler?($0) })
        )
        host.autoresizingMask = [.width, .height]
        panel = CompletionPanel(contentView: host)
        pickHandler = { [weak self] index in
            self?.model.selectedIndex = index
            self?.acceptSelected()
        }
    }

    func attach(to textView: CompletionTextView) {
        self.textView = textView
    }

    /// Show (or refresh) the popup with `items`, anchored under the partial
    /// word at `partialRange`. An empty list hides the popup.
    func present(items: [CompletionItem], partialRange: NSRange, in textView: CompletionTextView) {
        guard !items.isEmpty else { hide(); return }
        self.textView = textView
        self.partialRange = partialRange
        model.items = items
        model.selectedIndex = 0
        sizeAndPosition(under: partialRange, in: textView)
        orderFront(in: textView)
    }

    func hide() {
        guard panel.isVisible else { return }
        removeDismissObservers()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        model.items = []
    }

    /// Move the highlighted row, wrapping at both ends (JetBrains behavior).
    func moveSelection(by delta: Int) {
        let count = model.items.count
        guard count > 0 else { return }
        model.selectedIndex = ((model.selectedIndex + delta) % count + count) % count
    }

    /// Insert the highlighted candidate and dismiss. Returns false if there's
    /// nothing to accept (so the caller can let the key fall through).
    @discardableResult
    func acceptSelected() -> Bool {
        guard let textView, model.items.indices.contains(model.selectedIndex) else { return false }
        let item = model.items[model.selectedIndex]
        textView.commitCompletion(item.insertText, replacing: partialRange)
        hide()
        return true
    }

    // MARK: Geometry

    private func sizeAndPosition(under range: NSRange, in textView: CompletionTextView) {
        let rows = min(model.items.count, SQLCompletionMetrics.maxVisibleRows)
        let height = CGFloat(rows) * SQLCompletionMetrics.rowHeight + SQLCompletionMetrics.verticalInset
        let size = NSSize(width: SQLCompletionMetrics.width, height: height)

        // Caret rect in screen coordinates (origin bottom-left, y grows up).
        let caretRange = NSRange(location: range.location, length: 0)
        let caretRect = textView.firstRect(forCharacterRange: caretRange, actualRange: nil)

        var origin = NSPoint(x: caretRect.minX, y: caretRect.minY - height - 2)
        // Flip above the line if there isn't room below on this screen.
        if let screen = textView.window?.screen ?? NSScreen.main,
           origin.y < screen.visibleFrame.minY
        {
            origin.y = caretRect.maxY + 2
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func orderFront(in textView: CompletionTextView) {
        guard let window = textView.window else { return }
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        installDismissObservers(for: textView, window: window)
    }

    // MARK: Dismissal

    /// Hide the popup on the events that would otherwise leave it stranded:
    /// scrolling the editor, resizing the window, or the window losing key.
    private func installDismissObservers(for textView: CompletionTextView, window: NSWindow) {
        guard dismissObservers.isEmpty else { return }
        let center = NotificationCenter.default

        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            dismissObservers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } })
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didResignKeyNotification] {
            dismissObservers.append(center.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } })
        }
    }

    private func removeDismissObservers() {
        let center = NotificationCenter.default
        for token in dismissObservers { center.removeObserver(token) }
        dismissObservers.removeAll()
    }
}
