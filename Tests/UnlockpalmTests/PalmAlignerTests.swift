import XCTest
import CoreGraphics
@testable import Unlockpalm

final class PalmAlignerTests: XCTestCase {

    /// 정규화 좌표 × 192 extent == canonical192 정확히 그 위치가 되도록 만들면
    /// 유사변환은 항등에 가까워야 한다: 잔차 ≈ 0, ROI 원본 픽셀 ≈ roiInCanonical.width.
    func testDiagnosticsOnCanonicalPointsIsNearIdentity() {
        let extent = CGRect(x: 0, y: 0, width: 192, height: 192)
        let points = PalmPoints(
            indexMCP: normalized(PalmAligner.canonical192[0], in: extent),
            middleMCP: normalized(PalmAligner.canonical192[1], in: extent),
            ringMCP: normalized(PalmAligner.canonical192[2], in: extent),
            littleMCP: normalized(PalmAligner.canonical192[3], in: extent),
            wrist: normalized(PalmAligner.canonical192[4], in: extent)
        )

        guard let diag = PalmAligner.diagnostics(points: points, imageExtent: extent, flipLeftHand: false) else {
            return XCTFail("정상 5점 입력에서는 진단 결과가 나와야 한다")
        }
        XCTAssertEqual(diag.residual, 0, accuracy: 0.01)
        XCTAssertEqual(diag.sourcePixels, PalmAligner.roiInCanonical.width, accuracy: 0.5)
    }

    func testZeroSizedExtentReturnsNil() {
        let points = PalmPoints(indexMCP: .zero, middleMCP: .zero, ringMCP: .zero, littleMCP: .zero, wrist: .zero)
        XCTAssertNil(PalmAligner.diagnostics(points: points, imageExtent: .zero, flipLeftHand: false))
    }

    private func normalized(_ p: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: (p.x - extent.origin.x) / extent.width, y: (p.y - extent.origin.y) / extent.height)
    }
}
