//
//  FacePreprocessor.swift
//  Unlockface
//
//  정렬된 얼굴 버퍼(RGBA8)에 적용하는 전처리. 순서가 정해져 있다:
//    1. 선명도 게이트  — 흐린 프레임은 여기서 버린다
//    2. 노출 정규화    — 역광/저조도 보정
//    3. CLAHE          — 국소 대비 확보
//

import Foundation
import Accelerate

enum FacePreprocessor {

    /// 타입 추론이 폭발하지 않도록 계수를 명시한 단일 진입점.
    @inline(__always)
    static func lumaValue(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Float {
        let fr = Float(r), fg = Float(g), fb = Float(b)
        let wr: Float = 0.299, wg: Float = 0.587, wb: Float = 0.114
        return fr * wr + fg * wg + fb * wb
    }

    /// RGBA8 버퍼에서 루마(0~255)를 뽑는다.
    static func luma(from pixels: [UInt8], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        pixels.withUnsafeBufferPointer { px in
            for i in 0..<count {
                let o = i * 4
                out[i] = lumaValue(px[o], px[o + 1], px[o + 2])
            }
        }
        return out
    }

    // MARK: - 1. 선명도

    /// 라플라시안 분산. 값이 클수록 선명하다.
    /// 절대 스케일은 루마 범위(0~255)와 해상도에 의존하므로 임계값은 실측으로 잡아야 한다.
    static func laplacianVariance(luma: [Float], size: Int) -> Float {
        guard size > 2, luma.count >= size * size else { return 0 }
        var response = [Float](repeating: 0, count: (size - 2) * (size - 2))
        var k = 0
        luma.withUnsafeBufferPointer { l in
            for y in 1..<(size - 1) {
                for x in 1..<(size - 1) {
                    let c = y * size + x
                    // 4-이웃 라플라시안 커널
                    response[k] = l[c - size] + l[c + size] + l[c - 1] + l[c + 1] - 4 * l[c]
                    k += 1
                }
            }
        }
        var mean: Float = 0
        vDSP_meanv(response, 1, &mean, vDSP_Length(response.count))
        var negMean = -mean
        var centered = [Float](repeating: 0, count: response.count)
        vDSP_vsadd(response, 1, &negMean, &centered, 1, vDSP_Length(response.count))
        var sumSq: Float = 0
        vDSP_svesq(centered, 1, &sumSq, vDSP_Length(centered.count))
        return sumSq / Float(response.count)
    }

    // MARK: - 2. 노출 정규화

    /// 루마 백분위로 구한 범위를 0~255로 선형 확장한다.
    /// 극단값에 끌려가지 않도록 평균/표준편차가 아니라 백분위를 쓴다.
    static func normalizeExposure(pixels: inout [UInt8], size: Int) {
        let count = size * size
        guard pixels.count >= count * 4 else { return }

        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<count {
            let o = i * 4
            let y = Int(lumaValue(pixels[o], pixels[o + 1], pixels[o + 2]))
            histogram[min(255, max(0, y))] += 1
        }

        let lowCut = Int(Float(count) * FaceIDConfig.exposureClipPercentile)
        let highCut = count - lowCut
        var acc = 0, lo = 0, hi = 255
        for v in 0..<256 { acc += histogram[v]; if acc > lowCut { lo = v; break } }
        acc = 0
        for v in 0..<256 { acc += histogram[v]; if acc >= highCut { hi = v; break } }

        // 이미 범위를 다 쓰고 있거나 완전 평면이면 건드리지 않는다.
        guard hi > lo, hi - lo < 250 else { return }

        let scale = 255.0 / Float(hi - lo)
        var lut = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 {
            lut[v] = UInt8(max(0, min(255, (Float(v) - Float(lo)) * scale)))
        }
        for i in 0..<count {
            let o = i * 4
            pixels[o] = lut[Int(pixels[o])]
            pixels[o + 1] = lut[Int(pixels[o + 1])]
            pixels[o + 2] = lut[Int(pixels[o + 2])]
        }
    }

    // MARK: - 3. CLAHE

    /// Contrast Limited Adaptive Histogram Equalization.
    /// 타일별로 히스토그램 평활화를 하되, 클립 한계를 넘는 도수는 재분배해 노이즈 증폭을 막는다.
    /// 타일 경계가 드러나지 않도록 인접 타일 매핑을 이중선형 보간한다.
    static func applyCLAHE(pixels: inout [UInt8],
                           size: Int,
                           tiles: Int = FaceIDConfig.claheTiles,
                           clipLimit: Float = FaceIDConfig.claheClipLimit,
                           strength: Float = FaceIDConfig.claheStrength,
                           gainMin: Float = FaceIDConfig.claheGainMin,
                           gainMax: Float = FaceIDConfig.claheGainMax) {
        let count = size * size
        guard pixels.count >= count * 4, tiles >= 1, size % tiles == 0 else { return }

        let tileSize = size / tiles
        let tilePixels = tileSize * tileSize
        let limit = max(1, Int(clipLimit * Float(tilePixels) / 256.0))

        // 타일별 매핑 LUT 계산
        var maps = [[Float]](repeating: [Float](repeating: 0, count: 256), count: tiles * tiles)
        for ty in 0..<tiles {
            for tx in 0..<tiles {
                var hist = [Int](repeating: 0, count: 256)
                for y in (ty * tileSize)..<((ty + 1) * tileSize) {
                    for x in (tx * tileSize)..<((tx + 1) * tileSize) {
                        let o = (y * size + x) * 4
                        let v = Int(lumaValue(pixels[o], pixels[o + 1], pixels[o + 2]))
                        hist[min(255, max(0, v))] += 1
                    }
                }

                // 클리핑 + 잘린 양을 전 구간에 균등 재분배
                var excess = 0
                for v in 0..<256 where hist[v] > limit {
                    excess += hist[v] - limit
                    hist[v] = limit
                }
                let share = excess / 256
                let remainder = excess % 256
                for v in 0..<256 { hist[v] += share }
                for v in 0..<remainder { hist[v] += 1 }

                var cdf = 0
                var map = [Float](repeating: 0, count: 256)
                for v in 0..<256 {
                    cdf += hist[v]
                    map[v] = Float(cdf) * 255.0 / Float(tilePixels)
                }
                maps[ty * tiles + tx] = map
            }
        }

        // 픽셀마다 인접 4타일 매핑을 이중선형 보간
        let half = Float(tileSize) / 2
        for y in 0..<size {
            let fy = (Float(y) - half) / Float(tileSize)
            let ty0 = max(0, min(tiles - 1, Int(floor(fy))))
            let ty1 = max(0, min(tiles - 1, ty0 + 1))
            let wy = max(0, min(1, fy - Float(ty0)))

            for x in 0..<size {
                let fx = (Float(x) - half) / Float(tileSize)
                let tx0 = max(0, min(tiles - 1, Int(floor(fx))))
                let tx1 = max(0, min(tiles - 1, tx0 + 1))
                let wx = max(0, min(1, fx - Float(tx0)))

                let o = (y * size + x) * 4
                let r = Float(pixels[o]), g = Float(pixels[o + 1]), b = Float(pixels[o + 2])
                let oldY = lumaValue(pixels[o], pixels[o + 1], pixels[o + 2])
                let idx = Int(min(255, max(0, oldY)))

                let top = maps[ty0 * tiles + tx0][idx] * (1 - wx) + maps[ty0 * tiles + tx1][idx] * wx
                let bottom = maps[ty1 * tiles + tx0][idx] * (1 - wx) + maps[ty1 * tiles + tx1][idx] * wx
                let equalized = top * (1 - wy) + bottom * wy

                // 원본과 섞어 강도를 낮춘다. 전량 적용하면 살색이 주황으로 쏠린다.
                let newY = oldY + (equalized - oldY) * strength

                // 색상은 유지하고 밝기만 옮기되, 이득을 제한해 채도가 튀는 것을 막는다.
                let rawGain = oldY > 1 ? newY / oldY : 1
                let gain = max(gainMin, min(gainMax, rawGain))
                pixels[o]     = UInt8(max(0, min(255, r * gain)))
                pixels[o + 1] = UInt8(max(0, min(255, g * gain)))
                pixels[o + 2] = UInt8(max(0, min(255, b * gain)))
            }
        }
    }
}
