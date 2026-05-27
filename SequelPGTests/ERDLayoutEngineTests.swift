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

    // MARK: - Force-directed layout

    func testLayoutPositionsEveryNode() {
        let nodes = [node("a"), node("b"), node("c"), node("d"), node("e")]
        let positions = ERDLayoutEngine.layout(nodes: nodes, edges: [])
        XCTAssertEqual(Set(positions.keys), Set(nodes.map(\.id)))
    }

    func testLayoutIsDeterministic() {
        let nodes = [node("a"), node("b"), node("c"), node("d")]
        let edges = [
            ERDEdge(id: "e1", constraintName: "c1", sourceNodeID: "public.b", sourceColumns: ["x"],
                    targetNodeID: "public.a", targetColumns: ["id"], cardinality: .manyToOne),
        ]
        let first = ERDLayoutEngine.layout(nodes: nodes, edges: edges)
        let second = ERDLayoutEngine.layout(nodes: nodes, edges: edges)
        XCTAssertEqual(first, second, "Force-directed layout must be reproducible")
    }

    func testLayoutNonNegativeOrigins() {
        let positions = ERDLayoutEngine.layout(nodes: [node("a"), node("b"), node("c")], edges: [])
        for point in positions.values {
            XCTAssertGreaterThanOrEqual(point.x, 0)
            XCTAssertGreaterThanOrEqual(point.y, 0)
        }
    }

    func testLayoutSeparatesNodes() {
        // After layout, no two cards' frames should overlap.
        let nodes = [node("a"), node("b"), node("c"), node("d")]
        let positions = ERDLayoutEngine.layout(nodes: nodes, edges: [])
        let frames = nodes.map { node -> CGRect in
            let origin = positions[node.id] ?? .zero
            return CGRect(origin: origin, size: ERDMetrics.size(of: node))
        }
        for i in 0 ..< frames.count {
            for j in (i + 1) ..< frames.count {
                XCTAssertFalse(frames[i].intersects(frames[j]), "Cards \(i) and \(j) overlap")
            }
        }
    }

    // MARK: - ERDGeometry

    func testRouteStartsAndEndsOnCardBorders() throws {
        let source = CGRect(x: 0, y: 0, width: 200, height: 100)
        let target = CGRect(x: 500, y: 0, width: 200, height: 100)
        let route = ERDGeometry.route(from: source, to: target)
        let first = try XCTUnwrap(route.points.first)
        let last = try XCTUnwrap(route.points.last)
        XCTAssertEqual(first.x, source.maxX, accuracy: 0.001)
        XCTAssertEqual(last.x, target.minX, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(route.points.count, 2)
    }

    func testRouteConnectsVerticallyWhenStacked() throws {
        let source = CGRect(x: 0, y: 0, width: 200, height: 100)
        let target = CGRect(x: 0, y: 400, width: 200, height: 100)
        let route = ERDGeometry.route(from: source, to: target)
        let first = try XCTUnwrap(route.points.first)
        let last = try XCTUnwrap(route.points.last)
        XCTAssertEqual(first.y, source.maxY, accuracy: 0.001)
        XCTAssertEqual(last.y, target.minY, accuracy: 0.001)
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
