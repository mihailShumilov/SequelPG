import CoreGraphics
import XCTest
@testable import SequelPG

@MainActor
final class ERDViewModelTests: XCTestCase {

    private func sampleDiagram() -> ERDDiagram {
        ERDDiagram.build(
            schema: "public",
            tables: [
                DBObject(schema: "public", name: "users", type: .table),
                DBObject(schema: "public", name: "orders", type: .table),
            ],
            columnsByTable: [
                "users": [pkColumn("id")],
                "orders": [pkColumn("id"), plainColumn("user_id")],
            ],
            foreignKeys: [
                ConstraintInfo(
                    schema: "public",
                    table: "orders",
                    name: "fk",
                    kind: .foreignKey,
                    definition: "",
                    columns: ["user_id"],
                    referencedTable: "public.users",
                    referencedColumns: ["id"]
                ),
            ]
        )
    }

    private func pkColumn(_ name: String) -> ColumnInfo {
        ColumnInfo(
            name: name,
            ordinalPosition: 1,
            dataType: "int4",
            isNullable: false,
            columnDefault: nil,
            characterMaximumLength: nil,
            isPrimaryKey: true
        )
    }

    private func plainColumn(_ name: String) -> ColumnInfo {
        ColumnInfo(
            name: name,
            ordinalPosition: 2,
            dataType: "int4",
            isNullable: true,
            columnDefault: nil,
            characterMaximumLength: nil
        )
    }

    func testSetDiagramClearsSelection() {
        let vm = ERDViewModel()
        vm.selectedNodeID = "stale"
        vm.setDiagram(sampleDiagram())
        XCTAssertNil(vm.selectedNodeID)
        XCTAssertEqual(vm.diagram?.nodes.count, 2)
    }

    func testMoveNode() {
        let vm = ERDViewModel()
        vm.setDiagram(sampleDiagram())
        vm.moveNode(id: "public.users", to: CGPoint(x: 120, y: 240))
        XCTAssertEqual(vm.diagram?.node(id: "public.users")?.position, CGPoint(x: 120, y: 240))
    }

    func testToggleCollapse() {
        let vm = ERDViewModel()
        vm.setDiagram(sampleDiagram())
        vm.toggleCollapse(id: "public.users")
        XCTAssertEqual(vm.diagram?.node(id: "public.users")?.isCollapsed, true)
        vm.toggleCollapse(id: "public.users")
        XCTAssertEqual(vm.diagram?.node(id: "public.users")?.isCollapsed, false)
    }

    func testHideNodeRemovesItAndItsEdges() {
        let vm = ERDViewModel()
        vm.setDiagram(sampleDiagram())
        XCTAssertEqual(vm.visibleNodes.count, 2)
        XCTAssertEqual(vm.visibleEdges.count, 1)

        vm.hideNode(id: "public.users")
        XCTAssertEqual(vm.visibleNodes.count, 1)
        XCTAssertTrue(vm.hasHiddenNodes)
        XCTAssertEqual(vm.visibleEdges.count, 0, "Edge with a hidden endpoint should not be drawn")
    }

    func testShowAllNodes() {
        let vm = ERDViewModel()
        vm.setDiagram(sampleDiagram())
        vm.hideNode(id: "public.users")
        vm.showAllNodes()
        XCTAssertFalse(vm.hasHiddenNodes)
        XCTAssertEqual(vm.visibleNodes.count, 2)
    }

    func testZoomIsClamped() {
        let vm = ERDViewModel()
        vm.zoom(to: 99)
        XCTAssertEqual(vm.scale, ERDViewModel.maxScale)
        vm.zoom(to: 0.0001)
        XCTAssertEqual(vm.scale, ERDViewModel.minScale)
    }

    func testApplyAutoLayoutAssignsPositions() {
        let vm = ERDViewModel()
        vm.setDiagram(sampleDiagram())
        vm.moveNode(id: "public.users", to: .zero)
        vm.moveNode(id: "public.orders", to: .zero)
        vm.applyAutoLayout()
        // Distinct, non-negative positions after layout.
        let positions = vm.diagram?.nodes.map(\.position) ?? []
        XCTAssertEqual(Set(positions.map { "\($0.x),\($0.y)" }).count, positions.count)
    }

    func testCurrentLayoutAndApplyRoundTrip() {
        let source = ERDViewModel()
        source.setDiagram(sampleDiagram())
        source.moveNode(id: "public.users", to: CGPoint(x: 50, y: 60))
        source.toggleCollapse(id: "public.orders")
        source.hideNode(id: "public.users")
        source.scale = 1.25
        source.offset = CGPoint(x: 7, y: 8)
        let layout = source.currentLayout()

        let restored = ERDViewModel()
        restored.setDiagram(sampleDiagram())
        restored.apply(layout: layout)

        // The node arrangement is restored…
        XCTAssertEqual(restored.diagram?.node(id: "public.users")?.position, CGPoint(x: 50, y: 60))
        XCTAssertEqual(restored.diagram?.node(id: "public.orders")?.isCollapsed, true)
        XCTAssertEqual(restored.diagram?.node(id: "public.users")?.isHidden, true)
        // …but the viewport is intentionally NOT restored (it's reframed on open),
        // so it stays at the default that setDiagram reset it to.
        XCTAssertEqual(restored.scale, 1)
        XCTAssertEqual(restored.offset, .zero)
    }

    func testClearResetsState() {
        let vm = ERDViewModel()
        vm.setDiagram(sampleDiagram())
        vm.scale = 2
        vm.offset = CGPoint(x: 10, y: 10)
        vm.clear()
        XCTAssertNil(vm.diagram)
        XCTAssertNil(vm.selectedSchema)
        XCTAssertEqual(vm.scale, 1)
        XCTAssertEqual(vm.offset, .zero)
    }
}
