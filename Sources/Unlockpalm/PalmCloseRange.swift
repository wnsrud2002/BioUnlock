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
//  그대로 쓰면 된다. 랜드마크가 주던 회전 정규화만 잃는데, 이건 이미지 자체의
//  구조 텐서(structure tensor)로 주름의 지배 방향을 재서 대신한다.
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
    /// 회전 정규화까지 마친 루마 평면(size×size). 바로 인코딩에 넣을 수 있다.
    public let luma: [Float]
    public let size: Int
    /// 살색으로 보이는 픽셀 비율. 손이 아니라 벽·책상을 비추면 낮다.
    public let skinFraction: Float
    /// 유효 픽셀 비율(0~1). 주름 텍스처가 실제로 있는지를 나타낸다.
    /// 인코딩 결과에서 그대로 가져오므로 따로 계산 비용이 들지 않는다.
    public let salience: Float
    /// 회전 정규화로 되돌린 각도(도). 등록 샘플 간에 이 값이 크게 흔들리면
    /// 방향 추정이 불안정하다는 뜻이라 로그로 확인할 수 있게 남긴다.
    public let rotationDegrees: Float

    public var passesSkinGate: Bool { skinFraction >= PalmConfig.minSkinFraction }
    public var passesTextureGate: Bool { salience >= PalmConfig.minRoiSalience }
    public var passesAllGates: Bool { passesSkinGate && passesTextureGate }
}

public enum PalmCloseRange {

    /// 회전 후 빈 모서리가 ROI 에 들어오지 않도록, 먼저 이만큼 큰 정사각을 받는다.
    /// 256 × √2 ≈ 362 — 어떤 각도로 돌려도 중앙 256 은 항상 실제 화소로 채워진다.
    public static let workingSize = 362
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

        // 1) 주름의 지배 방향을 재서 매번 같은 각도로 되돌린다.
        //
        // 부호 주의: vImageRotate_PlanarF 의 각도 방향은 구조 텐서가 재는 방향과
        // 반대다. -angle 을 넘겼더니 상쇄 대신 누적돼 잔여각이 2배가 됐다
        // (12도 → 25도, 25도 → 50도 실측). 그래서 +angle 을 넘긴다.
        let angle = dominantOrientation(luma: luma, size: w)
        rotate(&luma, size: w, radians: angle)

        // 2) 회전으로 생긴 빈 모서리를 피해 중앙만 잘라낸다.
        var cropped = centerCrop(luma, from: w, to: outputSize)

        // 3) 대비 확보. 웹캠 손바닥은 주름 대비가 낮아 이게 없으면 방향이 노이즈다.
        PalmPreprocessor.applyCLAHE(luma: &cropped, size: outputSize)

        guard let code = PalmMatcher.encode(luma: cropped, size: outputSize) else { return nil }
        let roi = CloseRangeROI(luma: cropped,
                                size: outputSize,
                                skinFraction: skin,
                                salience: code.validRatio,
                                rotationDegrees: Float(angle * 180 / .pi))
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

    // MARK: - 회전 정규화

    /// 구조 텐서로 지배적인 기울기 방향을 구한다(0~π, 180도 모호성은 남는다).
    ///
    /// 손바닥 주름은 손가락을 위로 두면 대체로 가로로 흐른다. 그 방향을 매번
    /// 같은 각도로 되돌려 놓으면, 사용자가 손을 조금 기울여도 코드가 유지된다.
    /// CompCode 는 방향 인덱스라 15도만 틀어져도 절반 칸이 밀려 점수가 무너진다.
    static func dominantOrientation(luma: [Float], size: Int) -> Double {
        var jxx = 0.0, jyy = 0.0, jxy = 0.0
        luma.withUnsafeBufferPointer { l in
            for y in 1..<(size - 1) {
                let row = y * size
                for x in 1..<(size - 1) {
                    let gx = Double(l[row + x + 1] - l[row + x - 1])
                    let gy = Double(l[row + size + x] - l[row - size + x])
                    jxx += gx * gx
                    jyy += gy * gy
                    jxy += gx * gy
                }
            }
        }
        // 지배 기울기 방향. 0.5 배는 텐서가 방향을 2배각으로 표현하기 때문이다.
        return 0.5 * atan2(2 * jxy, jxx - jyy)
    }

    private static func rotate(_ luma: inout [Float], size: Int, radians: Double) {
        var src = luma
        var dst = [Float](repeating: 0, count: size * size)
        let rowBytes = size * MemoryLayout<Float>.size
        // 회전으로 생긴 여백은 중간 밝기로 채운다(중앙 크롭이 어차피 잘라낸다).
        let background: Pixel_F = 128

        src.withUnsafeMutableBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                var s = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(size),
                                      width: vImagePixelCount(size), rowBytes: rowBytes)
                var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(size),
                                      width: vImagePixelCount(size), rowBytes: rowBytes)
                _ = vImageRotate_PlanarF(&s, &d, nil, Float(radians), background,
                                         vImage_Flags(kvImageBackgroundColorFill))
            }
        }
        luma = dst
    }

    private static func centerCrop(_ luma: [Float], from: Int, to: Int) -> [Float] {
        let off = (from - to) / 2
        var out = [Float](repeating: 0, count: to * to)
        luma.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<to {
                    let s = (y + off) * from + off
                    let d = y * to
                    for x in 0..<to { dst[d + x] = src[s + x] }
                }
            }
        }
        return out
    }

}
