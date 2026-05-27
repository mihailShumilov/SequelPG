import CoreGraphics
import XCTest
@testable import SequelPG

final class ERDLayoutEngineTests: XCTestCase {

    private func node(_ name: String, columns: Int = 3) -> ERDNode {
        ERDNode(
            schema: "public",
            name: name,
            columns: (0 ..< columns).map {
                ERDColumn(name: "c\($0)", type: "int4", isPrimaryKey: false, isForeignKey: false, isNullable: true)
            }
        )
    }

    func testGridLayoutPositionsEveryNode() {
        let nodes = [node("a"), node("b"), node("c"), node("d"), node("e")]
        let positions = ERDLayoutEngine.gridLayout(nodes: nodes, edges: [])
        XCTAssertEqual(Set(positions.keys), Set(nodes.map(\.id)))
    }

    func testGridLayoutIsOrderIndependent() {
        let nodes = [node("a"), node("b"), node("c"), node("d")]
        let forward = ERDLayoutEngine.gridLayout(nodes: nodes, edges: [])
        let reversed = ERDLayoutEngine.gridLayout(nodes: nodes.reversed(), edges: [])
        XCTAssertEqual(forward, reversed, "Layout should be deterministic regardless of input order")
    }

    func testGridLayoutEmptyInput() {
        XCTAssertTrue(ERDLayoutEngine.gridLayout(nodes: [], edges: []).isEmpty)
    }

    func testGridLayoutNonNegativeOrigins() {
        let positions = ERDLayoutEngine.gridLayout(nodes: [node("a"), node("b")], edges: [])
        for point in positions.values {
            XCTAssertGreaterThanOrEqual(point.x, 0)
            XCTAssertGreaterThanOrEqual(point.y, 0)
        }
    }

    // MARK: - ERDGeometry

    func testBorderPointOnRightEdge() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let point = ERDGeometry.borderPoint(of: rect, toward: CGPoint(x: 1000, y: 25))
        XCTAssertEqual(point.x, 100, accuracy: 0.001)
        XCTAssertEqual(point.y, 25, accuracy: 0.001)
    }

    func testBorderPointOnTopEdge() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let point = ERDGeometry.borderPoint(of: rect, toward: CGPoint(x: 50, y: -1000))
        XCTAssertEqual(point.y, 0, accuracy: 0.001)
        XCTAssertEqual(point.x, 50, accuracy: 0.001)
    }

    func testContentBoundsIncludesNodeAndMargin() {
        let single = node("a")
        let size = ERDGeometry.contentBounds(of: [single])
        XCTAssertGreaterThan(size.width, ERDMetrics.nodeWidth)
        XCTAssertGreaterThan(size.height, ERDMetrics.headerHeight)
    }

    func testContentBoundsEmptyHasFallbackSize() {
        let size = ERDGeometry.contentBounds(of: [])
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }
}
