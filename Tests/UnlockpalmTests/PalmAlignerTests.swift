import XCTest
import CoreGraphics
@testable import Unlockpalm

final class PalmAlignerTests: XCTestCase {

    private let canonical = PalmAligner.defaultCanonical192

    /// 정규화 좌표 × 192 extent == 정준 좌표 그 자리가 되도록 만들면
    /// 유사변환은 항등에 가까워야 한다: 잔차 ≈ 0, ROI 원본 픽셀 ≈ roiInCanonical.width.
    func testDiagnosticsOnCanonicalPointsIsNearIdentity() {
        let extent = CGRect(x: 0, y: 0, width: 192, height: 192)
        let points = PalmPoints(
            indexMCP: normalized(canonical[0], in: extent),
            middleMCP: normalized(canonical[1], in: extent),
            ringMCP: normalized(canonical[2], in: extent),
            littleMCP: normalized(canonical[3], in: extent),
            wrist: normalized(canonical[4], in: extent)
        )

        guard let diag = PalmAligner.diagnostics(points: points, imageExtent: extent,
                                                 flipLeftHand: false, canonical: canonical) else {
            return XCTFail("정상 5점 입력에서는 진단 결과가 나와야 한다")
        }
        XCTAssertEqual(diag.residual, 0, accuracy: 0.01)
        XCTAssertEqual(diag.sourcePixels, PalmAligner.roiInCanonical.width, accuracy: 0.5)
    }

    func testZeroSizedExtentReturnsNil() {
        let points = PalmPoints(indexMCP: .zero, middleMCP: .zero, ringMCP: .zero, littleMCP: .zero, wrist: .zero)
        XCTAssertNil(PalmAligner.diagnostics(points: points, imageExtent: .zero,
                                             flipLeftHand: false, canonical: canonical))
    }

    // MARK: - 정준 좌표 재추정

    /// 재추정한 정준 좌표로 정렬하면 잔차가 기본 좌표일 때보다 작아야 한다.
    /// 이게 이번 인식률 개선의 핵심 가정이라 직접 잠근다 — 실제 손 형상이
    /// 기본 좌표와 어긋나 있어서 모든 프레임의 잔차가 함께 커지던 문제.
    func testCalibratedCanonicalLowersResidualForItsOwnShape() {
        let extent = CGRect(x: 0, y: 0, width: 192, height: 192)

        // 기본 좌표와 형태가 다른 손(손가락 간격이 넓고 손목이 치우친 모양)을
        // 미세한 관측 노이즈와 함께 여러 번 관측한 것으로 흉내낸다.
        let trueShape = [
            CGPoint(x: 150, y: 150), CGPoint(x: 112, y: 168),
            CGPoint(x: 74, y: 156),  CGPoint(x: 40, y: 132),
            CGPoint(x: 104, y: 20)
        ]
        let jitters: [CGFloat] = [-1.5, -0.5, 0.5, 1.5]
        let observations = jitters.map { j in
            trueShape.enumerated().map { i, p in
                CGPoint(x: p.x + (i.isMultiple(of: 2) ? j : -j), y: p.y + j)
            }
        }

        guard let calibrated = PalmAligner.calibrated(from: observations) else {
            return XCTFail("관측이 충분하면 정준 좌표가 나와야 한다")
        }

        let probe = PalmPoints(
            indexMCP: normalized(trueShape[0], in: extent),
            middleMCP: normalized(trueShape[1], in: extent),
            ringMCP: normalized(trueShape[2], in: extent),
            littleMCP: normalized(trueShape[3], in: extent),
            wrist: normalized(trueShape[4], in: extent)
        )

        guard let withDefault = PalmAligner.diagnostics(points: probe, imageExtent: extent,
                                                        flipLeftHand: false,
                                                        canonical: PalmAligner.defaultCanonical192),
              let withCalibrated = PalmAligner.diagnostics(points: probe, imageExtent: extent,
                                                           flipLeftHand: false,
                                                           canonical: calibrated) else {
            return XCTFail("두 경우 모두 진단이 나와야 한다")
        }

        XCTAssertLessThan(withCalibrated.residual, withDefault.residual,
                          "재추정한 좌표가 그 형상에 대해 더 잘 맞아야 한다")
        XCTAssertLessThan(withCalibrated.residual, 1.0, "자기 형상에 대한 잔차는 거의 0이어야 한다")
    }

    /// ROI 사각형이 손바닥을 벗어나지 않도록, 재추정 좌표는 기본 좌표 근처에
    /// 놓여야 한다(모양만 바뀌고 위치·크기는 유지). calibrated()가 기본 좌표
    /// 위에 유사변환으로 얹는 이유가 이것이다.
    func testCalibratedCanonicalStaysNearDefaultPlacement() {
        let shape = [
            CGPoint(x: 300, y: 500), CGPoint(x: 260, y: 520),
            CGPoint(x: 220, y: 505), CGPoint(x: 185, y: 480),
            CGPoint(x: 250, y: 360)
        ]
        guard let calibrated = PalmAligner.calibrated(from: [shape, shape, shape]) else {
            return XCTFail("정준 좌표가 나와야 한다")
        }
        let cx = calibrated.map(\.x).reduce(0, +) / CGFloat(calibrated.count)
        let cy = calibrated.map(\.y).reduce(0, +) / CGFloat(calibrated.count)
        let dx = PalmAligner.defaultCanonical192.map(\.x).reduce(0, +) / 5
        let dy = PalmAligner.defaultCanonical192.map(\.y).reduce(0, +) / 5

        // 원본 좌표가 192 프레임 밖(수백 px)에 있어도 프레임 안으로 들어와야 한다.
        XCTAssertEqual(cx, dx, accuracy: 20)
        XCTAssertEqual(cy, dy, accuracy: 20)
    }

    private func normalized(_ p: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: (p.x - extent.origin.x) / extent.width, y: (p.y - extent.origin.y) / extent.height)
    }
}
