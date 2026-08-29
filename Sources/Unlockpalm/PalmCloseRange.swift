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
//  대신 어떻게 하는가
//  ------------------
//  초근접에서는 손바닥이 화면을 덮으므로 ROI 를 '찾을' 필요가 없다. 화면 중앙을
//  그대로 쓰면 된다. 랜드마크가 주던 회전 정규화는 포기했다 — 아래 '회전 정규화를
//  쓰지 않는 이유' 참고. 남는 어긋남은 매칭의 이동 탐색이 흡수한다.
//
//  해상도 계산: 8cm 에서 손바닥 90mm 가 센서에 약 1280px 로 잡힌다(14.2 px/mm).
//  중앙 정사각(720px)은 손바닥 약 50mm 구간이고, 이를 256px 로 내리면 5.1 px/mm.
//  0.5mm 주름이 2.6px 이 되어 해상된다. 랜드마크 방식(128px, 2.1 px/mm)에서는
//  0.5mm 주름이 1px 로 나이퀴스트 한계였다.
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

public enum PalmCloseRange {

    /// 화면 중앙에서 받아올 정사각 크기. 회전 정규화를 걷어내면서 여유분이
    /// 필요 없어져 출력 크기와 같다.
    public static let workingSize = 256
    public static let outputSize = 256

    /// 중앙 정사각 RGBA(workingSize×workingSize)를 받아 ROI 와 코드를 한 번에 낸다.
    ///
    /// 등록과 인증이 반드시 같은 경로를 타야 하므로 진입점을 하나로 둔다
    /// (전처리가 갈리면 코드가 통째로 어긋나는데 점수는 "좀 낮네" 로만 보인다).
    /// 인코딩을 여기서 함께 하는 이유는 품질 지표(유효 픽셀 비율)가 인코딩
    /// 결과에서 나오기 때문이다 — 따로 재면 같은 컨볼루션을 두 번 돌게 된다.
    public static func analyze(rgba: [UInt8]) -> (roi: CloseRangeROI, code: PalmCode)? {
        let w = workingSize
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

    // MARK: - 살색 판정

    /// 아주 느슨한 살색 검사. 피부색은 인종·조명에 따라 폭이 넓어서 빡빡하게
    /// 잡으면 정당한 사용자를 막는다. "확실히 손이 아닌 것"(회색 벽, 검은 책상)만
    /// 걸러내는 게 목적이고, 진짜 게이트는 텍스처(salience) 쪽이다.
    private static func skinFraction(rgba: [UInt8], count: Int) -> Float {
        var hits = 0
        rgba.withUnsafeBufferPointer { px in
            for i in 0..<count {
                let o = i * 4
                let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
                // 피부는 조명과 무관하게 대체로 R > G > B 이고 너무 어둡지 않다.
                if r > 60, r > g, g >= b, r - b > 10 { hits += 1 }
            }
        }
        return Float(hits) / Float(max(1, count))
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
