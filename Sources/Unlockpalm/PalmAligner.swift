//
//  PalmAligner.swift
//  Unlockpalm
//
//  MCP 4점 + 손목 = 5점으로 유사변환을 푼다(FaceAligner와 동일한 이유 —
//  2점으로 풀면 자유도 4개에 방정식 4개라 잔차가 항상 0이 되어 정렬 품질
//  자가진단이 불가능해진다). 정렬과 ROI 정의는 분리한다: 5점으로 정준 손
//  프레임(192×192)을 만들고, 그 안에서 고정 사각형을 잘라 팜프린트 ROI로 쓴다.
//
//  주의: 카메라 프레임 자체의 좌우 미러링은 CameraController가
//  AVCaptureConnection.isVideoMirrored로 이미 처리하므로(FaceAligner와 동일
//  전제) 여기서 다시 다루지 않는다. flipLeftHand는 그것과 다른 문제 —
//  왼손을 오른손 정준 레이아웃에 맞추기 위한 손 자체의 좌우 반전이다.
//

import Foundation
import CoreGraphics
import CoreImage
import UnlockKit

public enum PalmAligner {

    /// 정준 손 프레임 192×192, 원점 좌하단(CoreImage 규약).
    /// 출발점 추정치 — 등록 샘플 20장의 평균 정렬 잔차가 최소가 되도록 재추정할 것.
    public static let canonical192: [CGPoint] = [
        CGPoint(x: 146, y: 158),   // indexMCP
        CGPoint(x: 114, y: 164),   // middleMCP
        CGPoint(x:  82, y: 160),   // ringMCP
        CGPoint(x:  52, y: 146),   // littleMCP
        CGPoint(x:  98, y:  14)    // wrist
    ]

    /// 정준 프레임 안에서 실제로 매칭에 쓰는 팜프린트 영역.
    /// 손목 주름(변형 심함)과 손가락 밑동(가림 잦음)을 뺀 안쪽.
    public static let roiInCanonical = CGRect(x: 32, y: 32, width: 128, height: 128)
    public static let roiOutputSize = 128

    private static func canonicalSource(points: PalmPoints, imageExtent extent: CGRect,
                                        flipLeftHand: Bool) -> [CGPoint] {
        var src = points.alignmentArray.map {
            CGPoint(x: extent.origin.x + $0.x * extent.width,
                    y: extent.origin.y + $0.y * extent.height)
        }
        if flipLeftHand { src = src.map { CGPoint(x: extent.maxX - $0.x, y: $0.y) } }
        return src
    }

    /// 원본 프레임에서 정렬된 정사각 손바닥 ROI를 잘라낸다.
    public static func align(image: CIImage, points: PalmPoints, flipLeftHand: Bool) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let src = canonicalSource(points: points, imageExtent: extent, flipLeftHand: flipLeftHand)
        guard let t = Geometry.similarityTransform(from: src, to: canonical192) else { return nil }

        let base = flipLeftHand
            ? image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.maxX, y: 0))
            : image
        return base.clampedToExtent()
            .transformed(by: t)
            .cropped(to: roiInCanonical)
    }

    /// 정렬 품질 자가진단(잔차) + ROI 원본 픽셀 수(스케일 역산)를 한 번에 낸다.
    /// 둘 다 같은 유사변환에서 나와야 서로 어긋나지 않는다.
    public static func diagnostics(points: PalmPoints, imageExtent extent: CGRect, flipLeftHand: Bool)
        -> (residual: CGFloat, sourcePixels: CGFloat)? {
        guard extent.width > 0, extent.height > 0 else { return nil }
        let src = canonicalSource(points: points, imageExtent: extent, flipLeftHand: flipLeftHand)
        guard let t = Geometry.similarityTransform(from: src, to: canonical192) else { return nil }

        var total: CGFloat = 0
        for (p, q) in zip(src, canonical192) {
            let m = p.applying(t)
            total += hypot(m.x - q.x, m.y - q.y)
        }
        let residual = total / CGFloat(src.count)

        let scale = sqrt(t.a * t.a + t.b * t.b)
        let sourcePixels = scale > .leastNormalMagnitude ? roiInCanonical.width / scale : 0

        return (residual, sourcePixels)
    }
}
