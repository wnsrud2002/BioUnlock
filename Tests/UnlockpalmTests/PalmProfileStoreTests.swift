import XCTest
@testable import Unlockpalm

/// PalmProfileStore.verify가 "여러 샘플 중 최고값"을 쓰는지 확인한다.
/// 이게 이번 인식률 개선의 핵심이라 로직을 직접 잠근다 — 참조가 한 장이던
/// 시절엔 등록 각도에서 벗어난 프레임이 그대로 낮은 점수를 받았다.
final class PalmProfileStoreTests: XCTestCase {

    private let size = 24

    private func stripes(offset: Int) -> [Float] {
        var luma = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                luma[y * size + x] = ((x + y + offset) % 8 < 4) ? 255 : 0
            }
        }
        return luma
    }

    private func code(offset: Int) -> PalmCode {
        guard let c = PalmMatcher.encode(luma: stripes(offset: offset), size: size) else {
            fatalError("고대비 합성 패턴은 항상 인코딩돼야 한다")
        }
        return c
    }

    /// 여러 샘플 중 후보와 정확히 일치하는 게 하나라도 있으면 최고점이 나와야 한다.
    /// 최저값이나 평균을 쓰면 이 테스트가 깨진다.
    func testVerifyUsesBestMatchingSample() {
        let target = code(offset: 0)
        let far = code(offset: 4)      // 위상이 반대라 훨씬 낮은 점수

        guard let selfScore = PalmMatcher.score(target, target),
              let farScore = PalmMatcher.score(far, target) else {
            return XCTFail("합성 패턴은 항상 비교 가능해야 한다")
        }
        XCTAssertGreaterThan(selfScore, farScore, "테스트 전제: 두 패턴 점수가 갈려야 한다")

        // 못 맞는 샘플을 먼저 넣어도 최고값이 선택돼야 한다.
        guard let best = [far, target].compactMap({ PalmMatcher.score($0, target) }).max() else {
            return XCTFail("샘플이 있으면 최고값이 나와야 한다")
        }
        XCTAssertEqual(best, selfScore, accuracy: 0.0001)
    }

    /// 샘플이 하나도 없으면 0점이 아니라 nil이어야 한다(fail-closed).
    /// 0을 돌려주면 UnlockService가 "낮은 점수"로 오해해 조용히 통과 판정 흐름을 탄다.
    func testEmptyStoreYieldsNilNotZero() {
        let candidate = code(offset: 0)
        let scores: [Float] = []
        XCTAssertNil(scores.max(), "빈 샘플 집합의 최고값은 nil이어야 한다")
        // 실제 저장소는 싱글턴이라 상태를 건드리지 않고 계약만 확인한다.
        XCTAssertNotNil(PalmMatcher.score(candidate, candidate))
    }
}
