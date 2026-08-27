import XCTest
@testable import Unlockpalm

final class PalmMatcherTests: XCTestCase {

    // MARK: - angularDiff (원형 거리)

    func testAngularDiffWrapsAroundInsteadOfLinear() {
        // 0과 5는 인덱스 차는 5지만 실제 각도로는 30°(1스텝) 차이다.
        XCTAssertEqual(PalmMatcher.angularDiff(0, 5), 1.0 / 3.0, accuracy: 0.001)
        // 0과 3은 정반대 방향(90°/3스텝) — 최댓값 1.0.
        XCTAssertEqual(PalmMatcher.angularDiff(0, 3), 1.0, accuracy: 0.001)
        XCTAssertEqual(PalmMatcher.angularDiff(2, 2), 0.0, accuracy: 0.001)
    }

    // MARK: - encode + score

    private let size = 24

    /// 대각선 줄무늬(고대비) — 어느 커널 튜닝에서도 응답이 강하게 나오게 만든 합성 패턴.
    private func stripes(angle: StripeAngle) -> [Float] {
        var luma = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let phase = angle == .diagonal ? (x + y) : (x - y)
                luma[y * size + x] = (phase % 8 < 4) ? 255 : 0
            }
        }
        return luma
    }

    private enum StripeAngle { case diagonal, antiDiagonal }

    func testSameCodeScoresNearOne() {
        guard let code = PalmMatcher.encode(luma: stripes(angle: .diagonal), size: size) else {
            return XCTFail("고대비 합성 패턴에서는 인코딩이 실패하면 안 된다")
        }
        XCTAssertEqual(PalmMatcher.score(code, code), 1.0, accuracy: 0.001)
    }

    func testDifferentOrientationScoresLowerThanSelf() {
        guard let a = PalmMatcher.encode(luma: stripes(angle: .diagonal), size: size),
              let b = PalmMatcher.encode(luma: stripes(angle: .antiDiagonal), size: size) else {
            return XCTFail("두 합성 패턴 모두 인코딩이 성공해야 한다")
        }
        let selfScore = PalmMatcher.score(a, a)
        let crossScore = PalmMatcher.score(a, b)
        XCTAssertLessThan(crossScore, selfScore)
    }

    func testEncodeRejectsTooSmallSize() {
        XCTAssertNil(PalmMatcher.encode(luma: [Float](repeating: 128, count: 4), size: 2))
    }
}
