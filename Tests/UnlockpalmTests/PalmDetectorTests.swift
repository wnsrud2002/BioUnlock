import XCTest
import CoreGraphics
import Vision
@testable import Unlockpalm

final class PalmDetectorTests: XCTestCase {

    private var savedSign: CGFloat = 0

    override func setUp() {
        super.setUp()
        savedSign = PalmConfig.palmFacingSign
    }

    override func tearDown() {
        PalmConfig.palmFacingSign = savedSign
        super.tearDown()
    }

    /// across(index-little)=(2,0), along(middle-wrist)=(0,2) → 외적 z = +4.
    private let points = PalmPoints(
        indexMCP: CGPoint(x: 1, y: 0),
        middleMCP: CGPoint(x: 0, y: 1),
        ringMCP: CGPoint(x: 0, y: 0.5),
        littleMCP: CGPoint(x: -1, y: 0),
        wrist: CGPoint(x: 0, y: -1)
    )

    func testSignFlipInvertsFacingResultForSameChirality() {
        PalmConfig.palmFacingSign = 1
        XCTAssertTrue(PalmDetector.isPalmFacing(points, chirality: .right))

        PalmConfig.palmFacingSign = -1
        XCTAssertFalse(PalmDetector.isPalmFacing(points, chirality: .right))
    }

    /// 왼손/오른손은 좌표계 방향이 반대라, 같은 z 부호에서도 판정이 반대여야 한다.
    func testOppositeChiralityInvertsFacingResult() {
        PalmConfig.palmFacingSign = 1
        let rightFacing = PalmDetector.isPalmFacing(points, chirality: .right)
        let leftFacing = PalmDetector.isPalmFacing(points, chirality: .left)
        XCTAssertNotEqual(rightFacing, leftFacing)
    }
}
