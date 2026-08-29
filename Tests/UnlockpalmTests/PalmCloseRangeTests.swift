import XCTest
import Foundation
@testable import Unlockpalm

/// 초근접 경로의 핵심 계약을 잠근다.
///
/// 랜드마크를 버리면서 회전 정규화를 이미지 구조에서 추정하게 됐다. 이게
/// 불안정하면 손을 조금만 기울여도 코드가 통째로 어긋난다 — CompCode 는 방향
/// 인덱스라 15도만 밀려도 절반 칸이 틀어진다. 그래서 직접 검증한다.
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

    /// 기울기를 바꿔도 회전 정규화가 그만큼 되돌려야 한다.
    func testDominantOrientationTracksActualTilt() {
        var previous: Float?
        for tilt in [0.0, 10.0, 20.0] {
            guard let (roi, _) = PalmCloseRange.analyze(rgba: syntheticPalm(degrees: tilt)) else {
                return XCTFail("합성 손금은 항상 분석돼야 한다 (기울기 \(tilt))")
            }
            if let prev = previous {
                // 기울기를 10도 더 줬으면 보정각도 그만큼 따라와야 한다.
                let delta = abs(abs(roi.rotationDegrees - prev) - 10.0)
                XCTAssertLessThan(delta, 4.0,
                                  "기울기 10도 변화에 보정각이 따라오지 않는다 (기울기 \(tilt))")
            }
            previous = roi.rotationDegrees
        }
    }

    /// 같은 손금을 기울여 찍어도 코드가 유지돼야 한다. 이게 회전 정규화의 목적이다.
    func testCodeSurvivesTilt() {
        guard let (_, upright) = PalmCloseRange.analyze(rgba: syntheticPalm(degrees: 0)),
              let (_, tilted) = PalmCloseRange.analyze(rgba: syntheticPalm(degrees: 12)) else {
            return XCTFail("합성 손금은 항상 분석돼야 한다")
        }
        guard let score = PalmMatcher.score(upright, tilted) else {
            return XCTFail("정규화가 됐다면 비교가 가능해야 한다")
        }
        // 회전 정규화가 없으면 12도(=0.4칸)가 밀려 0.5 근처(무작위)로 떨어진다.
        XCTAssertGreaterThan(score, 0.8, "기울기 12도에서 코드가 유지되지 않았다 (score=\(score))")
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
