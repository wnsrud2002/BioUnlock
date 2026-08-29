//
//  PalmCloseRange.swift
//  Unlockpalm
//
//  초근접 손금 촬영 — 랜드마크 없이 ROI를 잡는다.
//
//  왜 랜드마크를 못 쓰는가
//  ----------------------
//  Vision HandPose 는 손 '모양'을 봐야 21점을 낸다. 그런데 손금이 픽셀에
//  찍히려면 손바닥이 프레임을 꽉 채워야 하고, 그러면 손 윤곽이 프레임 밖으로
//  나가 Vision 이 손을 아예 못 찾는다. 실측(2026-08-29): 8~30cm 근접 촬영본
//  전부에서 검출 실패. 즉 '손금이 보이는 거리'와 '랜드마크가 나오는 거리'는
//  서로 배타적이다 — 랜드마크 기반 ROI 로는 원리적으로 손금 인증이 불가능하다.
//
//  대신 어떻게 하는가 — 손 실루엣으로 정렬한다
//  ------------------------------------------
//  처음엔 화면 중앙을 그냥 잘라 썼다. 그런데 그러면 손이 어디에 얼마만 한 크기로
//  있는지 모르므로 매 프레임 다른 데를 자르게 되고, 손금이 아무리 잘 보여도 코드가
//  서로 대응되지 않는다(등록 샘플 내부일관성이 0.5~0.78 로 출렁였다).
//
//  피부 영역(실루엣)의 무게중심과 퍼진 정도로 위치와 배율을 정규화한다. 실루엣은
//  크고 저주파라 프레임마다 안정적이다 — 주름 방향 같은 고주파로 정렬을 잡으려던
//  시도가 실패한 것과 대조적이다(아래 '회전 정규화를 쓰지 않는 이유' 참고).
//
//  거리의 스윗스팟 (720p, 화각 54도 기준 계산)
//  ------------------------------------------
//     6~8cm : 해상도 16~21 px/mm 로 좋지만 손이 프레임을 넘쳐 실루엣이 없다 →
//             정렬 기준이 사라져 오히려 인식이 안 된다
//    10~12cm: 손바닥 가장자리가 보이고(정렬 가능) 해상도도 10~12 px/mm →
//             0.5mm 주름이 5px 로 충분히 해상된다. 여기가 목표 거리다
//    20cm~  : 해상도 6 px/mm 이하로 잔주름이 뭉개진다
//

import Foundation
import Accelerate

/// 초근접 ROI 한 장과 그 품질 지표.
public struct CloseRangeROI {
    /// 전처리(CLAHE)까지 마친 루마 평면(size×size). 바로 인코딩에 넣을 수 있다.
    public let luma: [Float]
    public let size: Int
    /// 살색으로 보이는 픽셀 비율. 손이 아니라 벽·책상을 비추면 낮다.
    public let skinFraction: Float
    /// 유효 픽셀 비율(0~1). 주름 텍스처가 실제로 있는지를 나타낸다.
    /// 인코딩 결과에서 그대로 가져오므로 따로 계산 비용이 들지 않는다.
    public let salience: Float
    public var passesSkinGate: Bool { skinFraction >= PalmConfig.minSkinFraction }
    public var passesTextureGate: Bool { salience >= PalmConfig.minRoiSalience }
    public var passesAllGates: Bool { passesSkinGate && passesTextureGate }
}

/// 프레임 안에서 손이 어디에 얼마만 한 크기로 있는지.
///
/// 손 실루엣(피부 영역)에서 구한다. 실루엣은 크고 저주파라 프레임마다 안정적인
/// 반면, 주름 방향 같은 고주파 특징은 조금만 흔들려도 뒤집힌다 — 정렬 기준은
/// 안정적인 쪽에서 가져오고, 신원은 고주파(손금)에서 읽는 게 맞다.
public struct PalmLocation {
    /// 프레임 기준 정규화 좌표(0~1).
    public let centerX: CGFloat
    public let centerY: CGFloat
    /// 잘라낼 정사각의 한 변(프레임 짧은 변 기준 비율). 손 크기에 비례하므로
    /// 거리가 바뀌어도 같은 물리적 영역이 잡힌다 = 배율 정규화.
    public let cropSide: CGFloat
    public let skinFraction: Float
    public let verdict: Verdict

    public enum Verdict: Equatable {
        case ok
        /// 손이 프레임을 넘쳐 실루엣이 안 보인다. 이러면 위치·크기를 알 수 없어
        /// 매 프레임 다른 데를 자르게 된다 — 손금은 잘 보여도 정렬이 불가능하다.
        case tooClose
        case tooFar
        case noHand
    }
}

public enum PalmCloseRange {

    /// 손 위치를 찾을 때 쓰는 축소 프레임의 짧은 변. 실루엣만 보면 되므로
    /// 원본 해상도가 필요 없다.
    public static let locateSize = 160
    /// 최종 ROI 크기.
    public static let outputSize = 256

    /// locate() 가 정해준 자리에서 잘라 온 RGBA(outputSize×outputSize)를 받아
    /// ROI 와 코드를 한 번에 낸다.
    ///
    /// 등록과 인증이 반드시 같은 경로를 타야 하므로 진입점을 하나로 둔다
    /// (전처리가 갈리면 코드가 통째로 어긋나는데 점수는 "좀 낮네" 로만 보인다).
    /// 인코딩을 여기서 함께 하는 이유는 품질 지표(유효 픽셀 비율)가 인코딩
    /// 결과에서 나오기 때문이다 — 따로 재면 같은 컨볼루션을 두 번 돌게 된다.
    public static func analyze(rgba: [UInt8]) -> (roi: CloseRangeROI, code: PalmCode)? {
        let w = outputSize
        guard rgba.count >= w * w * 4 else { return nil }

        let skin = skinFraction(rgba: rgba, count: w * w)
        var luma = PalmPreprocessor.luma(from: rgba, count: w * w)

        // 대비 확보. 웹캠 손바닥은 주름 대비가 낮아 이게 없으면 방향이 노이즈다.
        PalmPreprocessor.applyCLAHE(luma: &luma, size: outputSize)

        guard let code = PalmMatcher.encode(luma: luma, size: outputSize) else { return nil }
        let roi = CloseRangeROI(luma: luma,
                                size: outputSize,
                                skinFraction: skin,
                                salience: code.validRatio)
        return (roi, code)
    }

    // MARK: - 좌표 변환

    /// 축소 프레임의 크기를 정한다. 세로를 locateSize 에 맞추고 가로는 종횡비대로.
    ///
    /// 예전에 `locateSize * Int(width / height)` 로 썼다가 1280×720 에서
    /// Int(1.777) = 1 이 되어 160×160 이 나왔다. 284×160 을 그 버퍼에 렌더링하니
    /// 프레임 왼쪽 56% 만 보고 손 위치를 계산했다 — ROI 가 엉뚱한 데로 갔다.
    public static func locateFrameSize(for extent: CGRect) -> (width: Int, height: Int) {
        guard extent.height > 0 else { return (locateSize, locateSize) }
        let w = Int((extent.width / extent.height * CGFloat(locateSize)).rounded())
        return (max(1, w), locateSize)
    }

    /// 찾은 손 위치를 원본 이미지 좌표계의 잘라낼 사각형으로 옮긴다.
    ///
    /// !! y 뒤집기 !!
    /// locate() 가 받는 비트맵은 첫 행이 화면 위쪽이다(CGImage 규약). 반면
    /// CIImage 는 좌하단 원점이라 y 가 위로 증가한다. 그래서 centerY 를 그대로
    /// 쓰면 위아래가 뒤집힌 자리를 자르게 된다. 이 변환을 호출부에 흩어 놓으면
    /// 한쪽만 고치고 다른 쪽을 놓치기 쉬워 여기 한 곳에 모았다.
    public static func cropRect(for location: PalmLocation, in extent: CGRect) -> CGRect {
        let side = location.cropSide * min(extent.width, extent.height)
        let cx = extent.origin.x + location.centerX * extent.width
        let cy = extent.origin.y + (1 - location.centerY) * extent.height
        return CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
    }

    // MARK: - 손 위치 찾기 (실루엣 기반 정렬)

    /// 축소한 전체 프레임에서 손이 어디에 얼마만 한 크기로 있는지 찾는다.
    ///
    /// 평균 위치와 '퍼진 정도'로만 판단한다 — 연결요소 분석 같은 걸 하지 않는
    /// 이유는 표준편차가 튀는 픽셀 몇 개에 훨씬 둔감하기 때문이다.
    public static func locate(rgba: [UInt8], width: Int, height: Int) -> PalmLocation {
        var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0
        var hits = 0
        var borderHits = 0, borderTotal = 0

        rgba.withUnsafeBufferPointer { px in
            for y in 0..<height {
                let onVerticalEdge = (y == 0 || y == height - 1)
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    let skin = isSkin(r: Int(px[o]), g: Int(px[o + 1]), b: Int(px[o + 2]))
                    if skin {
                        hits += 1
                        let fx = Double(x), fy = Double(y)
                        sumX += fx; sumY += fy
                        sumXX += fx * fx; sumYY += fy * fy
                    }
                    // 테두리에 살색이 얼마나 닿아 있는지 = 손이 프레임을 넘쳤는지.
                    if onVerticalEdge || x == 0 || x == width - 1 {
                        borderTotal += 1
                        if skin { borderHits += 1 }
                    }
                }
            }
        }

        let total = width * height
        let skinFraction = Float(hits) / Float(max(1, total))
        let borderFraction = Float(borderHits) / Float(max(1, borderTotal))
        let shortSide = CGFloat(min(width, height))

        guard hits > total / 20 else {
            return PalmLocation(centerX: 0.5, centerY: 0.5, cropSide: 0.5,
                                skinFraction: skinFraction, verdict: .noHand)
        }

        let n = Double(hits)
        let mx = sumX / n, my = sumY / n
        let spread = (sqrt(max(0, sumXX / n - mx * mx)) + sqrt(max(0, sumYY / n - my * my))) / 2

        // 손 크기에 비례한 정사각을 잡는다. 채워진 타원이면 표준편차가 폭의 1/4쯤
        // 되므로, 손바닥 안쪽에 들어오도록 계수를 잡았다(실측으로 조정할 값).
        let side = CGFloat(spread) * PalmConfig.cropSpreadMultiplier

        let verdict: PalmLocation.Verdict
        if borderFraction > PalmConfig.maxBorderSkinFraction {
            verdict = .tooClose
        } else if side < shortSide * PalmConfig.minCropSideRatio {
            verdict = .tooFar
        } else {
            verdict = .ok
        }

        return PalmLocation(centerX: CGFloat(mx) / CGFloat(width),
                            centerY: CGFloat(my) / CGFloat(height),
                            cropSide: side / shortSide,
                            skinFraction: skinFraction,
                            verdict: verdict)
    }

    // MARK: - 살색 판정

    /// 아주 느슨한 살색 검사. 피부색은 인종·조명에 따라 폭이 넓어서 빡빡하게
    /// 잡으면 정당한 사용자를 막는다. "확실히 손이 아닌 것"(회색 벽, 검은 책상)만
    /// 걸러내는 게 목적이고, 진짜 게이트는 텍스처(salience) 쪽이다.
    private static func skinFraction(rgba: [UInt8], count: Int) -> Float {
        var hits = 0
        rgba.withUnsafeBufferPointer { px in
            for i in 0..<count {
                let o = i * 4
                if isSkin(r: Int(px[o]), g: Int(px[o + 1]), b: Int(px[o + 2])) { hits += 1 }
            }
        }
        return Float(hits) / Float(max(1, count))
    }

    /// 피부는 조명과 무관하게 대체로 R > G > B 이고 너무 어둡지 않다.
    @inline(__always)
    static func isSkin(r: Int, g: Int, b: Int) -> Bool {
        r > 60 && r > g && g >= b && r - b > 10
    }

    // MARK: - 회전 정규화를 쓰지 않는 이유
    //
    // 구조 텐서로 주름의 지배 방향을 재서 되돌리는 방식을 넣었다가 걷어냈다.
    // 손바닥에는 서로 수직인 주름 방향이 경쟁해서 '지배 방향'이 프레임마다
    // 뒤집힌다 — 같은 사진에서 크롭 위치만 10px 옮겨도 추정값이 -3.6도 →
    // +88.4도 → -84.8도 로 튀었다(2026-08-29 실측). 그 값으로 매 프레임 다른
    // 각도만큼 돌리면 정규화가 아니라 훼손이다. 실제로 등록 샘플 간 회전편차가
    // 31도까지 벌어졌고 내부일관성이 0.528(무작위 수준)까지 떨어졌다.
    //
    // 지금은 회전을 보정하지 않는다. 대신 사용자가 손을 일정하게 두도록 화면에
    // 안내선을 두고, 남는 어긋남은 PalmMatcher 의 이동 탐색이 흡수한다.
    // 회전까지 탐색해야 할 만큼 흔들린다면 그때 매칭 단계에서 다루는 게 맞다
    // — 이미지를 미리 돌려놓는 방식은 추정이 틀리면 되돌릴 수가 없다.
}
