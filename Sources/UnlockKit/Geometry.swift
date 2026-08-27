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

    /// 여러 관측 형상의 평균 형상(Procrustes mean).
    ///
    /// 각 관측을 현재 평균에 유사변환으로 맞춘 뒤 좌표를 평균내고, 그 결과를 다시
    /// 평균으로 삼아 반복한다. 위치·회전·크기 차이를 걷어낸 '순수한 모양'만 남는다.
    ///
    /// 쓰는 이유: 정렬의 기준(정준 좌표)이 실제 형상과 어긋나 있으면 모든 프레임의
    /// 잔차가 함께 커지고, 정렬 결과가 매번 다른 곳을 가리킨다. 문헌값이나 눈대중
    /// 좌표 대신 그 사용자의 실측 형상으로 기준을 다시 잡는 데 쓴다.
    ///
    /// - Parameter shapes: 점 개수가 모두 같아야 한다. 빈 배열이면 nil.
    public static func procrustesMeanShape(_ shapes: [[CGPoint]], iterations: Int = 8) -> [CGPoint]? {
        guard let first = shapes.first, !first.isEmpty else { return nil }
        guard shapes.allSatisfy({ $0.count == first.count }) else { return nil }

        var mean = first
        for _ in 0..<max(1, iterations) {
            var sum = [CGPoint](repeating: .zero, count: first.count)
            var used = 0
            for shape in shapes {
                // 이미 평균과 같은 자리에 있는 형상은 변환이 항등이라 그대로 더한다.
                let aligned: [CGPoint]
                if let t = similarityTransform(from: shape, to: mean) {
                    aligned = shape.map { $0.applying(t) }
                } else {
                    continue   // 퇴화된 관측(모든 점이 같은 자리 등)은 건너뛴다
                }
                for i in 0..<first.count {
                    sum[i].x += aligned[i].x
                    sum[i].y += aligned[i].y
                }
                used += 1
            }
            guard used > 0 else { return nil }
            mean = sum.map { CGPoint(x: $0.x / CGFloat(used), y: $0.y / CGFloat(used)) }
        }
        return mean
    }
}
