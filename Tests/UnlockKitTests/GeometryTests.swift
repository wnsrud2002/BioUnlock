import XCTest
import CoreGraphics
@testable import UnlockKit

final class GeometryTests: XCTestCase {

    func testIdentityPointsProduceIdentityTransform() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)]
        guard let t = Geometry.similarityTransform(from: points, to: points) else {
            return XCTFail("동일 점집합은 변환을 찾아야 한다")
        }
        for p in points {
            let m = p.applying(t)
            XCTAssertEqual(m.x, p.x, accuracy: 0.001)
            XCTAssertEqual(m.y, p.y, accuracy: 0.001)
        }
    }

    func testInsufficientPointsReturnsNil() {
        let single = [CGPoint(x: 0, y: 0)]
        XCTAssertNil(Geometry.similarityTransform(from: single, to: single))
    }

    func testCollinearPointsReturnNilOrDegenerateSafely() {
        // 세 점이 모두 동일 위치면(분산 0) 유사변환을 풀 수 없어야 한다.
        let same = [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)]
        XCTAssertNil(Geometry.similarityTransform(from: same, to: same))
    }
}
