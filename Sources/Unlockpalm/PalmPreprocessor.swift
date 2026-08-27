//
//  PalmPreprocessor.swift
//  Unlockpalm
//
//  ROI(RGBA8) → Gabor에 넣을 루마 평면.
//
//  왜 얼굴의 FacePreprocessor를 재사용하지 않는가:
//  얼굴 CLAHE는 RGB 채널별 이득을 제한하고 강도를 0.6으로 낮춘다 — 살색이
//  주황으로 쏠리면 임베딩 모델이 학습 분포 밖으로 밀려나기 때문이다.
//  손바닥은 색을 전혀 쓰지 않고(루마만) 목표가 정반대다: 손금 주름의 국소
//  대비를 최대로 끌어올려야 Gabor 응답이 방향을 제대로 가리킨다.
//  그래서 루마 도메인에서 이득 제한 없이 전량 적용하는 별도 구현을 둔다.
//
//  !! 대칭 규칙 !!
//  등록과 인증이 반드시 같은 전처리를 거쳐야 한다. 한쪽만 CLAHE를 적용하면
//  코드가 통째로 어긋나는데 점수는 "좀 낮네" 정도로만 보여 조용히 틀린다
//  (SFace 이중정규화 때와 같은 종류의 함정). 그래서 호출부가 전처리를
//  직접 하지 못하게 PalmMatcher.encode(rgba:)만 노출한다.
//

import Foundation

enum PalmPreprocessor {

    /// RGBA8 → 루마(0~255). 계수는 FacePreprocessor와 동일(BT.601).
    static func luma(from rgba: [UInt8], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        rgba.withUnsafeBufferPointer { px in
            for i in 0..<count {
                let o = i * 4
                out[i] = Float(px[o]) * 0.299 + Float(px[o + 1]) * 0.587 + Float(px[o + 2]) * 0.114
            }
        }
        return out
    }

    /// 루마 평면에 국소 대비 평활화(CLAHE)를 건다.
    ///
    /// 웹캠으로 찍은 손바닥은 주름 대비가 매우 낮다(실측 validRatio 0.21~0.41).
    /// 대비가 낮으면 Gabor 응답의 방향별 차이가 노이즈에 묻혀 argmin이 사실상
    /// 난수가 된다 — 같은 손을 같은 세션에서 찍어도 코드가 0.66까지 어긋나던
    /// 주된 이유다(2026-08-28 실측).
    static func applyCLAHE(luma: inout [Float],
                           size: Int,
                           tiles: Int = PalmConfig.claheTiles,
                           clipLimit: Float = PalmConfig.claheClipLimit) {
        let count = size * size
        guard luma.count >= count, tiles >= 1, size % tiles == 0 else { return }

        let tileSize = size / tiles
        let tilePixels = tileSize * tileSize
        let limit = max(1, Int(clipLimit * Float(tilePixels) / 256.0))

        // 타일별 매핑 LUT
        var maps = [[Float]](repeating: [Float](repeating: 0, count: 256), count: tiles * tiles)
        for ty in 0..<tiles {
            for tx in 0..<tiles {
                var hist = [Int](repeating: 0, count: 256)
                for y in (ty * tileSize)..<((ty + 1) * tileSize) {
                    for x in (tx * tileSize)..<((tx + 1) * tileSize) {
                        let v = Int(luma[y * size + x])
                        hist[min(255, max(0, v))] += 1
                    }
                }
                // 클리핑 + 잘린 양을 전 구간에 균등 재분배(노이즈 증폭 방지)
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

        // 픽셀마다 인접 4타일 매핑을 이중선형 보간(타일 경계가 드러나지 않게)
        let half = Float(tileSize) / 2
        var out = [Float](repeating: 0, count: count)
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

                let idx = min(255, max(0, Int(luma[y * size + x])))
                let top = maps[ty0 * tiles + tx0][idx] * (1 - wx) + maps[ty0 * tiles + tx1][idx] * wx
                let bottom = maps[ty1 * tiles + tx0][idx] * (1 - wx) + maps[ty1 * tiles + tx1][idx] * wx
                // 얼굴과 달리 원본과 섞지 않고 전량 적용한다 — 색 보존 제약이 없다.
                out[y * size + x] = top * (1 - wy) + bottom * wy
            }
        }
        luma = out
    }
}
