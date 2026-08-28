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

    /// 정준 손 프레임 192×192, 원점 좌하단(CoreImage 규약)의 '기본값'.
    ///
    /// 눈대중으로 잡은 출발점이라 실제 손 형상과 어긋나 있었다. 그 결과 모든
    /// 프레임의 잔차가 함께 커져(실측 3.2~5.9px, 게이트 6.0에 아슬아슬) 매 프레임
    /// ROI가 다른 곳을 잘랐고, 같은 손을 같은 세션에서 찍어도 코드가 0.66까지
    /// 어긋났다. 등록 때 그 사용자의 실측 형상으로 재추정한 값을 쓰고, 이 값은
    /// 등록 전(그리고 등록 중)의 임시 기준으로만 남는다. calibrated(from:) 참고.
    public static let defaultCanonical192: [CGPoint] = [
        CGPoint(x: 146, y: 158),   // indexMCP
        CGPoint(x: 114, y: 164),   // middleMCP
        CGPoint(x:  82, y: 160),   // ringMCP
        CGPoint(x:  52, y: 146),   // littleMCP
        CGPoint(x:  98, y:  14)    // wrist
    ]

    /// 정준 프레임 안에서 실제로 매칭에 쓰는 팜프린트 영역.
    /// 손목 주름(변형 심함)과 손가락 밑동(가림 잦음)을 뺀 안쪽.
    public static let roiInCanonical = CGRect(x: 32, y: 32, width: 128, height: 128)

    /// ROI 를 몇 픽셀로 뽑을지. roiInCanonical(128 정준 단위)과 별개다 —
    /// 128 단위 영역을 256px 로 뽑으면 2배 초과표본이 된다.
    ///
    /// 128 이던 것을 256 으로 올렸다. 8cm 근접 촬영에서 손바닥이 센서에 1280px 로
    /// 잡히는데 128px 로 줄이면 10:1 로 뭉개져, 개인을 구분하는 잔주름 그물망이
    /// 통째로 사라졌다(2026-08-28 실측). 큰 손금은 사람마다 비슷해서 그것만 남으면
    /// 타인 0.69 / 본인 0.72 처럼 구분이 안 된다.
    public static let roiOutputSize = 256

    /// 관측된 5점 집합들로 그 사용자 전용 정준 좌표를 만든다.
    ///
    /// Procrustes 평균으로 '순수한 모양'을 뽑은 뒤, 기본 정준 좌표 위에 유사변환으로
    /// 얹는다. 후자가 중요하다 — 평균 형상을 그대로 쓰면 프레임 안 위치·크기가
    /// 제멋대로라 roiInCanonical이 손바닥을 벗어난다. 기본값에 맞춰 놓으면 ROI
    /// 사각형은 그대로 두고 '모양'만 사용자 것으로 바꿀 수 있다.
    public static func calibrated(from observations: [[CGPoint]]) -> [CGPoint]? {
        guard let mean = Geometry.procrustesMeanShape(observations),
              let place = Geometry.similarityTransform(from: mean, to: defaultCanonical192)
        else { return nil }
        return mean.map { $0.applying(place) }
    }

    /// 정렬에 쓰는 5점을 이미지 픽셀 좌표로 변환한다(왼손 반전 반영).
    /// 정준 좌표 재추정(calibrated)에 넣을 관측 형상이 바로 이 값이다.
    public static func alignmentPointsInImage(points: PalmPoints, imageExtent extent: CGRect,
                                              flipLeftHand: Bool) -> [CGPoint] {
        canonicalSource(points: points, imageExtent: extent, flipLeftHand: flipLeftHand)
    }

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
    ///
    /// 반환 이미지의 extent 는 항상 (0, 0, roiOutputSize, roiOutputSize) 다.
    /// 호출부가 그 가정으로 비트맵을 렌더링하므로 이 계약을 깨면 안 된다
    /// (PalmAlignerROITests 가 잠가 둔다). 예전에는 roiInCanonical 원점(32,32)
    /// 그대로 돌려줘서 호출부가 (0,0)부터 읽었고, ROI 의 43%가 빈 픽셀이었다.
    public static func align(image: CIImage, points: PalmPoints, flipLeftHand: Bool,
                             canonical: [CGPoint]) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let src = canonicalSource(points: points, imageExtent: extent, flipLeftHand: flipLeftHand)
        guard let t = Geometry.similarityTransform(from: src, to: canonical) else { return nil }

        let base = flipLeftHand
            ? image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.maxX, y: 0))
            : image
        let side = CGFloat(roiOutputSize)
        return base.clampedToExtent()
            .transformed(by: t.concatenating(roiToOutput))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// 정준 프레임의 roiInCanonical 영역을 (0,0,roiOutputSize,roiOutputSize)로 옮긴다.
    /// 이동 먼저, 그다음 확대 — 순서를 바꾸면 원점이 어긋난다.
    private static var roiToOutput: CGAffineTransform {
        let s = CGFloat(roiOutputSize) / roiInCanonical.width
        return CGAffineTransform(translationX: -roiInCanonical.origin.x,
                                 y: -roiInCanonical.origin.y)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
    }

    /// 정렬 품질 자가진단(잔차) + ROI 원본 픽셀 수(스케일 역산)를 한 번에 낸다.
    /// 둘 다 같은 유사변환에서 나와야 서로 어긋나지 않는다.
    public static func diagnostics(points: PalmPoints, imageExtent extent: CGRect,
                                   flipLeftHand: Bool, canonical: [CGPoint])
        -> (residual: CGFloat, sourcePixels: CGFloat)? {
        guard extent.width > 0, extent.height > 0 else { return nil }
        let src = canonicalSource(points: points, imageExtent: extent, flipLeftHand: flipLeftHand)
        guard let t = Geometry.similarityTransform(from: src, to: canonical) else { return nil }

        var total: CGFloat = 0
        for (p, q) in zip(src, canonical) {
            let m = p.applying(t)
            total += hypot(m.x - q.x, m.y - q.y)
        }
        let residual = total / CGFloat(src.count)

        let scale = sqrt(t.a * t.a + t.b * t.b)
        let sourcePixels = scale > .leastNormalMagnitude ? roiInCanonical.width / scale : 0

        return (residual, sourcePixels)
    }
}
