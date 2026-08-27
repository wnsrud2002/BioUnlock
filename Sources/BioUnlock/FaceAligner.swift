//
//  FaceAligner.swift
//  BioUnlock
//
//  5점 랜드마크를 ArcFace 표준 112x112 배치로 맞추는 유사변환(similarity transform).
//
//  여기가 틀리면 임베딩·안티스푸핑이 전부 무너진다. 정렬 결과를 화면에 띄우고
//  정준 5점 마커와 겹치는지 눈으로 확인할 수 있게 해 두었다.
//

import Foundation
import CoreGraphics
import CoreImage
import UnlockKit

enum FaceAligner {

    /// InsightFace 표준 정준 5점(ArcFace/SFace 등 이 계열 모델이 공유하는 정렬 규약).
    /// 원본 문헌 좌표는 좌상단 원점 기준이라
    /// CoreImage(좌하단 원점)에 맞추려면 y를 뒤집어야 한다.
    static let canonical112: [CGPoint] = [
        CGPoint(x: 38.2946, y: 112 - 51.6963),   // 이미지 왼쪽 눈
        CGPoint(x: 73.5318, y: 112 - 51.5014),   // 이미지 오른쪽 눈
        CGPoint(x: 56.0252, y: 112 - 71.7366),   // 코끝
        CGPoint(x: 41.5493, y: 112 - 92.3655),   // 왼쪽 입꼬리
        CGPoint(x: 70.7299, y: 112 - 92.2041)    // 오른쪽 입꼬리
    ]

    static func canonical(for size: Int) -> [CGPoint] {
        let s = CGFloat(size) / 112.0
        return canonical112.map { CGPoint(x: $0.x * s, y: $0.y * s) }
    }

    /// 5점은 어파인(6자유도)에는 과결정이라 그냥 어파인으로 풀면 얼굴이 찌그러진다.
    /// 이 계열 모델은 유사변환(4자유도)을 전제로 학습돼 있어 반드시 이쪽이어야 한다.
    /// 실제 구현은 UnlockKit.Geometry.similarityTransform (손바닥 정렬과 공유).

    /// 원본 프레임에서 정렬된 정사각 얼굴 이미지를 잘라낸다.
    /// - Parameter landmarks: Vision 정규화 좌표(원점 좌하단)
    static func align(image: CIImage,
                      landmarks: FaceLandmarks5,
                      size: Int = FaceIDConfig.alignedFaceSize) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        // 정규화 좌표 → 픽셀 좌표. CIImage도 좌하단 원점이라 y 뒤집기가 필요 없다.
        let src = landmarks.asArray.map {
            CGPoint(x: extent.origin.x + $0.x * extent.width,
                    y: extent.origin.y + $0.y * extent.height)
        }
        guard let transform = Geometry.similarityTransform(from: src, to: canonical(for: size)) else { return nil }

        // 얼굴이 프레임 가장자리에 걸리면 정렬 결과에 투명 영역이 생긴다.
        // 가장자리 픽셀을 복제해 채워야 뒤의 히스토그램 연산이 오염되지 않는다.
        let crop = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
        return image.clampedToExtent()
            .transformed(by: transform)
            .cropped(to: crop)
    }

    /// 정렬 품질 자가진단: 변환을 실제로 적용했을 때 정준 위치에서 몇 픽셀 어긋나는가.
    /// 5점이 유사변환으로 설명되지 않을수록(=검출이 나쁠수록) 커진다.
    static func residual(landmarks: FaceLandmarks5,
                         imageExtent extent: CGRect,
                         size: Int = FaceIDConfig.alignedFaceSize) -> CGFloat {
        let src = landmarks.asArray.map {
            CGPoint(x: extent.origin.x + $0.x * extent.width,
                    y: extent.origin.y + $0.y * extent.height)
        }
        let dst = canonical(for: size)
        guard let t = Geometry.similarityTransform(from: src, to: dst) else { return .infinity }
        var total: CGFloat = 0
        for (p, q) in zip(src, dst) {
            let m = p.applying(t)
            total += hypot(m.x - q.x, m.y - q.y)
        }
        return total / CGFloat(src.count)
    }
}
