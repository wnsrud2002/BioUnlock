import XCTest
import Foundation
@testable import Unlockpalm

/// 초근접 경로의 핵심 계약을 잠근다.
///
/// 랜드마크를 버리면서 위치 정렬을 매칭의 이동 탐색에 전적으로 맡기게 됐다.
/// 그 범위가 부족하면 등록 샘플끼리도 무작위 수준으로 떨어지므로 직접 검증한다.
final class PalmCloseRangeTests: XCTestCase {

    private let side = PalmCloseRange.workingSize

    /// 손금처럼 한 방향으로 흐르는 줄무늬를 가진 살색 이미지를 만든다.
    /// - Parameter degrees: 줄무늬를 이만큼 기울인다.
    private func syntheticPalm(degrees: Double) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let rad = degrees * .pi / 180
        let c = cos(rad), s = sin(rad)
        let mid = Double(side) / 2

        for y in 0..<side {
            for x in 0..<side {
                // 이미지 중심 기준으로 회전한 좌표계에서 줄무늬를 그린다.
                let dx = Double(x) - mid, dy = Double(y) - mid
                let u = dx * c + dy * s
                let line = sin(u * 2 * .pi / 14)          // 14px 주기 = 손금 간격 흉내
                let v = 150 + line * 45                    // 살색 근처에서 진동

                let o = (y * side + x) * 4
                rgba[o]     = UInt8(max(0, min(255, v + 40)))   // R 이 가장 크게(살색 조건)
                rgba[o + 1] = UInt8(max(0, min(255, v)))
                rgba[o + 2] = UInt8(max(0, min(255, v - 30)))
                rgba[o + 3] = 255
            }
        }
        return rgba
    }

    /// 같은 손금이 몇 픽셀 어긋나게 찍혀도 코드가 유지돼야 한다.
    ///
    /// 초근접에서는 손을 자유롭게 들고 있어 2~5mm 흔들림이 그대로 들어오고,
    /// 5.1 px/mm 확대에서 그게 10~25px 어긋남이 된다. 이동 탐색이 이걸 흡수하지
    /// 못하면 등록 샘플끼리도 무작위 수준(0.5)으로 떨어진다 — 실제로 그랬다.
    func testCodeSurvivesTranslation() {
        let base = syntheticPalm(degrees: 0)
        for shift in [6, 14, 20] {
            let moved = shifted(base, by: shift)
            guard let (_, a) = PalmCloseRange.analyze(rgba: base),
                  let (_, b) = PalmCloseRange.analyze(rgba: moved) else {
                return XCTFail("합성 손금은 항상 분석돼야 한다")
            }
            guard let score = PalmMatcher.score(a, b) else {
                return XCTFail("이동 \(shift)px 에서 비교 불가")
            }
            XCTAssertGreaterThan(score, 0.85,
                                 "이동 \(shift)px 를 이동 탐색이 흡수하지 못했다 (score=\(score))")
        }
    }

    /// 이미지를 x 방향으로 밀어 손 흔들림을 흉내낸다(가장자리는 복제).
    private func shifted(_ rgba: [UInt8], by dx: Int) -> [UInt8] {
        var out = rgba
        for y in 0..<side {
            for x in 0..<side {
                let src = min(side - 1, max(0, x + dx))
                let o = (y * side + x) * 4, s = (y * side + src) * 4
                out[o] = rgba[s]; out[o+1] = rgba[s+1]; out[o+2] = rgba[s+2]; out[o+3] = 255
            }
        }
        return out
    }

    /// 살색이 아닌 것(회색 벽)은 걸러야 한다.
    func testNonSkinIsRejectedBySkinGate() {
        var gray = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0..<(side * side) {
            let o = i * 4
            gray[o] = 120; gray[o + 1] = 120; gray[o + 2] = 120; gray[o + 3] = 255
        }
        guard let (roi, _) = PalmCloseRange.analyze(rgba: gray) else {
            return XCTFail("분석 자체는 되어야 한다(게이트에서 거르는 것이지 nil 이 아니다)")
        }
        XCTAssertFalse(roi.passesSkinGate, "무채색인데 살색 게이트를 통과했다")
    }

    func testTooSmallInputReturnsNil() {
        XCTAssertNil(PalmCloseRange.analyze(rgba: [UInt8](repeating: 0, count: 16)))
    }
}
