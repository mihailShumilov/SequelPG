import AppKit
import ApplicationServices

/// One element of the app's interface, read through the macOS accessibility
/// API: its role, label, identifier and value.
struct AXNode: CustomStringConvertible {
    let element: AXUIElement

    func attribute(_ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func string(_ name: String) -> String { (attribute(name) as? String) ?? "" }

    private func node(_ name: String) -> AXNode? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // The type ID was just checked.
        return AXNode(element: unsafeBitCast(value, to: AXUIElement.self))
    }

    var role: String { string(kAXRoleAttribute) }
    var subrole: String { string(kAXSubroleAttribute) }
    var identifier: String { string("AXIdentifier") }
    var help: String { string(kAXHelpAttribute) }
    var title: String { string(kAXTitleAttribute) }

    /// Visible title, else the accessibility description, else the title element's text.
    var label: String {
        if !title.isEmpty { return title }
        let description = string(kAXDescriptionAttribute)
        if !description.isEmpty { return description }
        guard let titleNode = node(kAXTitleUIElementAttribute) else { return "" }
        return titleNode.value.isEmpty ? titleNode.title : titleNode.value
    }

    var value: String {
        guard let value = attribute(kAXValueAttribute) else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    /// Label and value of this element and everything below it (for "contains text" checks).
    var allText: String {
        descendants(maxDepth: 12).map(\.node).flatMap { [$0.label, $0.value] }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var isEnabled: Bool { (attribute(kAXEnabledAttribute) as? Bool) ?? true }
    var isSelected: Bool { (attribute(kAXSelectedAttribute) as? Bool) ?? false }
    var children: [AXNode] { ((attribute(kAXChildrenAttribute) as? [AXUIElement]) ?? []).map(AXNode.init) }
    var parent: AXNode? { node(kAXParentAttribute) }

    /// Table rows (`AXRows`) for tables and outlines.
    var rows: [AXNode] { ((attribute(kAXRowsAttribute) as? [AXUIElement]) ?? []).map(AXNode.init) }

    var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Frame in screen coordinates (top-left origin).
    var frame: CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let value = axValue(kAXPositionAttribute) { AXValueGetValue(value, .cgPoint, &origin) }
        if let value = axValue(kAXSizeAttribute) { AXValueGetValue(value, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    private func axValue(_ name: String) -> AXValue? {
        guard let value = attribute(name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // The type ID was just checked.
        return unsafeBitCast(value, to: AXValue.self)
    }

    var description: String {
        var parts = [role]
        if !subrole.isEmpty, subrole != role { parts.append("(\(subrole))") }
        if !label.isEmpty { parts.append("“\(label)”") }
        if !identifier.isEmpty { parts.append("#\(identifier)") }
        let shown = value.replacingOccurrences(of: "\n", with: "⏎")
        if !shown.isEmpty { parts.append("= \(shown.prefix(60))") }
        if !isEnabled { parts.append("[disabled]") }
        return parts.joined(separator: " ")
    }

    /// Every element below this one, depth first, with its depth.
    func descendants(maxDepth: Int = 60) -> [(node: AXNode, depth: Int)] {
        var result: [(AXNode, Int)] = []
        func walk(_ node: AXNode, _ depth: Int) {
            guard depth <= maxDepth else { return }
            result.append((node, depth))
            for child in node.children { walk(child, depth + 1) }
        }
        walk(self, 0)
        return result
    }

    // MARK: - Actions (none of these move the pointer or take the focus)

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    /// Presses a button, checkbox, menu item or segment.
    @discardableResult
    func press() -> Bool { perform(kAXPressAction) }

    @discardableResult
    func focus() -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Replaces the text of a field or text view.
    @discardableResult
    func setValue(_ text: String) -> Bool {
        focus()
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success
    }

    /// Selects `rows` in a table/outline/list, as clicking them would.
    @discardableResult
    func selectRows(_ rows: [AXNode]) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedRowsAttribute as CFString, rows.map(\.element) as CFArray)
            == .success
    }

    @discardableResult
    func setSelected(_ selected: Bool = true) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, selected as CFBoolean) == .success
    }

    @discardableResult
    func setExpanded(_ expanded: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, kAXDisclosingAttribute as CFString, expanded as CFBoolean) == .success
    }
}

/// What to look for: any combination of role, identifier, label and value.
struct Query: CustomStringConvertible {
    var role: String?
    var identifier: String?
    var label: String?
    var value: String?
    /// Match label/value by substring instead of equality.
    var partial = false

    static func id(_ identifier: String) -> Query { Query(identifier: identifier) }
    static func button(_ label: String) -> Query { Query(role: "AXButton", label: label) }
    static func text(_ text: String, partial: Bool = false) -> Query {
        Query(role: "AXStaticText", value: text, partial: partial)
    }

    func matches(_ node: AXNode) -> Bool {
        if let identifier, node.identifier != identifier { return false }
        if let role, node.role != role { return false }
        if let label {
            let candidates = [node.label, node.help]
            guard candidates.contains(where: { partial ? $0.contains(label) : $0 == label }) else { return false }
        }
        if let value {
            let candidates = [node.value, node.label]
            guard candidates.contains(where: { partial ? $0.contains(value) : $0 == value }) else { return false }
        }
        return true
    }

    var description: String {
        [role, identifier.map { "#\($0)" }, label.map { "“\($0)”" }, value.map { "= “\($0)”" }]
            .compactMap { $0 }.joined(separator: " ")
    }
}
