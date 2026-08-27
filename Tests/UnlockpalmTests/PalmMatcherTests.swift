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
    ///
    /// 나머지 연산에 주의: 반대 대각선은 x - y 가 음수가 되는데 Swift 의 % 는
    /// 음수를 그대로 돌려준다. 그냥 `phase % 8 < 4` 로 쓰면 줄무늬가 아니라
    /// 절반이 통짜로 칠해진 패턴이 나온다(실제로 그렇게 틀려 있었다).
    private func stripes(angle: StripeAngle) -> [Float] {
        var luma = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let phase = angle == .diagonal ? (x + y) : (x - y)
                luma[y * size + x] = (((phase % 8) + 8) % 8 < 4) ? 255 : 0
            }
        }
        return luma
    }

    private enum StripeAngle { case diagonal, antiDiagonal }

    func testSameCodeScoresNearOne() {
        guard let code = PalmMatcher.encode(luma: stripes(angle: .diagonal), size: size) else {
            return XCTFail("고대비 합성 패턴에서는 인코딩이 실패하면 안 된다")
        }
        guard let score = PalmMatcher.score(code, code) else {
            return XCTFail("같은 코드끼리는 비교 불가(nil)가 나오면 안 된다")
        }
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testDifferentOrientationScoresLowerThanSelf() {
        guard let a = PalmMatcher.encode(luma: stripes(angle: .diagonal), size: size),
              let b = PalmMatcher.encode(luma: stripes(angle: .antiDiagonal), size: size) else {
            return XCTFail("두 합성 패턴 모두 인코딩이 성공해야 한다")
        }
        guard let selfScore = PalmMatcher.score(a, a), let crossScore = PalmMatcher.score(a, b) else {
            return XCTFail("고대비 합성 패턴은 항상 비교 가능해야 한다")
        }
        XCTAssertLessThan(crossScore, selfScore)
    }

    func testEncodeRejectsTooSmallSize() {
        XCTAssertNil(PalmMatcher.encode(luma: [Float](repeating: 128, count: 4), size: 2))
    }

    /// 실제로 겪은 버그: 유효 픽셀이 부족하면 "다른 손"처럼 보이는 0점이 아니라
    /// nil("비교 불가")이 나와야 한다. 완전히 평평한 이미지는 모든 픽셀이
    /// 응답 임계값 미달이라 mask가 전부 false여야 한다.
    func testFlatImageWithNoValidPixelsScoresNilNotZero() {
        let flat = [Float](repeating: 128, count: size * size)
        guard let code = PalmMatcher.encode(luma: flat, size: size) else {
            return XCTFail("평평한 이미지도 인코딩 자체는 성공해야 한다(mask만 전부 false)")
        }
        XCTAssertEqual(code.validRatio, 0, accuracy: 0.001)
        XCTAssertNil(PalmMatcher.score(code, code))
    }
}
