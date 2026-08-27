import XCTest
import CoreGraphics
@testable import UnlockKit

final class ProcrustesTests: XCTestCase {

    private let shape = [
        CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10),
        CGPoint(x: -10, y: 0), CGPoint(x: 0, y: -10)
    ]

    /// 같은 모양을 위치·회전·크기만 바꿔서 여러 번 관측하면, 평균 형상은
    /// 원래 모양과 (유사변환을 제외하고) 같아야 한다. 이게 성립해야
    /// "정준 좌표를 실측으로 재추정한다"는 발상이 성립한다.
    func testMeanShapeRecoversCommonShapeUpToSimilarity() {
        let variants = [
            shape,
            shape.map { CGPoint(x: $0.x * 2 + 50, y: $0.y * 2 - 30) },        // 크기 + 이동
            shape.map { CGPoint(x: -$0.y, y: $0.x) },                          // 90도 회전
            shape.map { CGPoint(x: -$0.y * 0.5 + 7, y: $0.x * 0.5 + 3) }       // 회전 + 축소 + 이동
        ]
        guard let mean = Geometry.procrustesMeanShape(variants) else {
            return XCTFail("정상 입력에서는 평균 형상이 나와야 한다")
        }

        // 평균을 원본에 유사변환으로 맞췄을 때 잔차가 0에 가까워야 한다.
        guard let t = Geometry.similarityTransform(from: mean, to: shape) else {
            return XCTFail("평균과 원본은 유사변환으로 연결돼야 한다")
        }
        for (m, s) in zip(mean.map({ $0.applying(t) }), shape) {
            XCTAssertEqual(m.x, s.x, accuracy: 0.01)
            XCTAssertEqual(m.y, s.y, accuracy: 0.01)
        }
    }

    /// 관측 노이즈는 평균에서 상쇄돼야 한다 — 한 관측만 크게 흔들려도
    /// 평균이 그쪽으로 끌려가면 안 된다(등록 중 손 떨림이 정확히 이 상황).
    func testMeanShapeAveragesOutObservationNoise() {
        let clean = Array(repeating: shape, count: 5)
        var noisy = clean
        noisy[0] = shape.map { CGPoint(x: $0.x + 3, y: $0.y - 3) }   // 한 관측만 치우침

        guard let mean = Geometry.procrustesMeanShape(noisy),
              let t = Geometry.similarityTransform(from: mean, to: shape) else {
            return XCTFail("평균 형상이 나와야 한다")
        }
        let worst = zip(mean.map({ $0.applying(t) }), shape)
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .max() ?? .infinity
        // 치우침 3px가 5개 중 1개면 평균 기여는 그 1/5 수준이어야 한다.
        XCTAssertLessThan(worst, 1.5)
    }

    func testEmptyOrMismatchedInputReturnsNil() {
        XCTAssertNil(Geometry.procrustesMeanShape([]))
        XCTAssertNil(Geometry.procrustesMeanShape([[]]))
        // 점 개수가 다르면 대응 관계가 없으므로 계산할 수 없다.
        XCTAssertNil(Geometry.procrustesMeanShape([shape, Array(shape.prefix(3))]))
    }
}
