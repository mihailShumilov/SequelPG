import CoreGraphics
import XCTest
@testable import SequelPG

final class ERDSVGRendererTests: XCTestCase {

    private func column(_ name: String, type: String = "int4", pk: Bool = false, fk: Bool = false) -> ERDColumn {
        ERDColumn(name: name, type: type, isPrimaryKey: pk, isForeignKey: fk, isNullable: !pk)
    }

    private func usersNode() -> ERDNode {
        ERDNode(
            schema: "public",
            name: "users",
            columns: [column("id", pk: true), column("email", type: "text")],
            position: CGPoint(x: 40, y: 40)
        )
    }

    func testProducesWellFormedSVGRoot() {
        let svg = ERDSVGRenderer.svg(nodes: [usersNode()], edges: [])
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains("</svg>"))
        XCTAssertTrue(svg.contains("viewBox=\"0 0"))
        XCTAssertTrue(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""))
    }

    func testIncludesTableNameAndColumns() {
        let svg = ERDSVGRenderer.svg(nodes: [usersNode()], edges: [])
        XCTAssertTrue(svg.contains(">users</text>"))
        XCTAssertTrue(svg.contains(">email</text>"))
        XCTAssertTrue(svg.contains(">id</text>"))
    }

    func testEscapesSpecialCharacters() {
        let node = ERDNode(schema: "public", name: "a&b<c>\"d", columns: [], position: .zero)
        let svg = ERDSVGRenderer.svg(nodes: [node], edges: [])
        XCTAssertTrue(svg.contains("a&amp;b&lt;c&gt;&quot;d"))
        XCTAssertFalse(svg.contains(">a&b<c>"))
    }

    func testDrawsEdgeWithArrowhead() {
        let nodes = [
            ERDNode(
                schema: "public",
                name: "orders",
                columns: [column("user_id", fk: true)],
                position: CGPoint(x: 0, y: 0)
            ),
            ERDNode(
                schema: "public",
                name: "users",
                columns: [column("id", pk: true)],
                position: CGPoint(x: 400, y: 0)
            ),
        ]
        let edge = ERDEdge(
            id: "e",
            constraintName: "fk",
            sourceNodeID: "public.orders",
            sourceColumns: ["user_id"],
            targetNodeID: "public.users",
            targetColumns: ["id"],
            cardinality: .manyToOne
        )
        let svg = ERDSVGRenderer.svg(nodes: nodes, edges: [edge])
        XCTAssertTrue(svg.contains("<path d=\"M"), "Edge should be an orthogonal path")
        XCTAssertTrue(svg.contains("<polygon"), "Arrowhead should be emitted as a polygon")
    }

    func testDeterministicOutput() {
        let first = ERDSVGRenderer.svg(nodes: [usersNode()], edges: [])
        let second = ERDSVGRenderer.svg(nodes: [usersNode()], edges: [])
        XCTAssertEqual(first, second)
    }
}
