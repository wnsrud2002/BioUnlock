//
//  Geometry.swift
//  UnlockKit
//
//  FaceAligner(5점 정렬)와 PalmAligner(5점 정렬)가 공유하는 순수 좌표 변환.
//  여기가 틀리면 임베딩·안티스푸핑이 전부 무너진다.
//

import CoreGraphics

public enum Geometry {

    /// 두 점집합을 잇는 최소제곱 유사변환(회전 + 등방 스케일 + 평행이동).
    /// 반사(reflection)는 허용하지 않는다 — 좌우 뒤집힌 결과가 나오면 안 된다.
    public static func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let n = CGFloat(src.count)

        let srcMean = CGPoint(x: src.map(\.x).reduce(0, +) / n, y: src.map(\.y).reduce(0, +) / n)
        let dstMean = CGPoint(x: dst.map(\.x).reduce(0, +) / n, y: dst.map(\.y).reduce(0, +) / n)

        var dot: CGFloat = 0    // Σ a·b   → s·cosθ 성분
        var cross: CGFloat = 0  // Σ a×b   → s·sinθ 성분
        var normSq: CGFloat = 0 // Σ |a|²

        for (p, q) in zip(src, dst) {
            let a = CGPoint(x: p.x - srcMean.x, y: p.y - srcMean.y)
            let b = CGPoint(x: q.x - dstMean.x, y: q.y - dstMean.y)
            dot += a.x * b.x + a.y * b.y
            cross += a.x * b.y - a.y * b.x
            normSq += a.x * a.x + a.y * a.y
        }
        guard normSq > .leastNormalMagnitude else { return nil }

        let c = dot / normSq
        let s = cross / normSq
        guard c.isFinite, s.isFinite, (c * c + s * s) > .leastNormalMagnitude else { return nil }

        // [ c  -s ] 를 CGAffineTransform 규약(x' = a·x + c·y + tx)에 맞춰 채운다.
        // [ s   c ]
        let tx = dstMean.x - (c * srcMean.x - s * srcMean.y)
        let ty = dstMean.y - (s * srcMean.x + c * srcMean.y)
        return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: tx, ty: ty)
    }
}
