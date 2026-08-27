//
//  VectorMath.swift
//  UnlockKit
//
//  얼굴 임베딩과 손바닥 임베딩이 공유하는 순수 벡터 연산.
//

import Accelerate

public enum VectorMath {

    public static func l2Normalized(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        vDSP_svesq(v, 1, &sumSq, vDSP_Length(v.count))
        let n = sqrtf(sumSq)
        guard n > .leastNormalMagnitude else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var inv = 1 / n
        vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
        return out
    }

    /// 둘 다 L2 정규화돼 있으면 내적이 곧 코사인 유사도다.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(a.count))
        return r
    }

    /// 여러 임베딩의 평균(정규화 포함). TTA와 프로필 중심 계산에 쓴다.
    public static func average(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first, !first.isEmpty else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in embeddings where v.count == first.count {
            vDSP_vadd(sum, 1, v, 1, &sum, 1, vDSP_Length(first.count))
        }
        return l2Normalized(sum)
    }
}
