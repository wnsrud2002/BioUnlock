//
//  PalmDetector.swift
//  Unlockpalm
//
//  Vision은 21점과 chirality(왼손/오른손)만 준다. 손바닥을 보는 중인지 손등을
//  보는 중인지는 알려주지 않는다 — 오른손 손등은 왼손 손바닥과 2D 투영이 거의
//  같아서, 이걸 안 거르면 등록된 오른손 손바닥이 왼손 손등으로도 매칭될 여지가 생긴다.
//
//  판별법: 손등을 보면 랜드마크 좌표계의 방향(handedness)이 뒤집힌다.
//  새끼→검지 벡터와 손목→중지 벡터의 외적 부호로 판정한다.
//
//  PalmConfig.palmFacingSign은 실측 전 추정치다. 카메라 미러링·Vision의
//  chirality 판정 방식에 따라 뒤집힐 수 있어 DebugView에서 라이브로 확정한다.
//

import Foundation
import CoreGraphics
import Vision

/// 정렬(5점)에 쓰는 손 관절 좌표. Vision 정규화 좌표(원점 좌하단).
public struct PalmPoints: Equatable {
    public let indexMCP: CGPoint
    public let middleMCP: CGPoint
    public let ringMCP: CGPoint
    public let littleMCP: CGPoint
    public let wrist: CGPoint

    public init(indexMCP: CGPoint, middleMCP: CGPoint, ringMCP: CGPoint, littleMCP: CGPoint, wrist: CGPoint) {
        self.indexMCP = indexMCP
        self.middleMCP = middleMCP
        self.ringMCP = ringMCP
        self.littleMCP = littleMCP
        self.wrist = wrist
    }

    public var alignmentArray: [CGPoint] { [indexMCP, middleMCP, ringMCP, littleMCP, wrist] }
}

public enum PalmDetector {

    /// 정렬에 쓰는 5점 — 21점 전부가 아니라 이 5개만 엄격하게 신뢰도를 본다.
    public static let alignmentJoints: [VNHumanHandPoseObservation.JointName] =
        [.indexMCP, .middleMCP, .ringMCP, .littleMCP, .wrist]

    /// observation에서 정렬용 5점을 뽑는다. 신뢰도가 낮은 점이 하나라도 있으면 nil.
    public static func points(from observation: VNHumanHandPoseObservation) -> PalmPoints? {
        func point(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let p = try? observation.recognizedPoint(name),
                  p.confidence >= PalmConfig.minJointConfidence else { return nil }
            return CGPoint(x: p.location.x, y: p.location.y)
        }
        guard let index = point(.indexMCP),
              let middle = point(.middleMCP),
              let ring = point(.ringMCP),
              let little = point(.littleMCP),
              let wrist = point(.wrist) else { return nil }
        return PalmPoints(indexMCP: index, middleMCP: middle, ringMCP: ring, littleMCP: little, wrist: wrist)
    }

    /// 디버그 오버레이용 — 21점 전부(신뢰도 느슨하게). 정렬에는 쓰지 않는다.
    public static func allPoints(from observation: VNHumanHandPoseObservation) -> [CGPoint] {
        (try? observation.recognizedPoints(.all))?.values
            .filter { $0.confidence >= PalmConfig.minOverlayConfidence }
            .map { CGPoint(x: $0.location.x, y: $0.location.y) } ?? []
    }

    /// 손등을 보면 새끼→검지, 손목→중지 두 벡터의 외적 부호가 뒤집힌다.
    /// 왼손/오른손은 좌표계 방향 자체가 반대라 chirality에 따라 기대 부호도 반대다.
    public static func isPalmFacing(_ p: PalmPoints, chirality: VNChirality) -> Bool {
        let across = CGPoint(x: p.indexMCP.x - p.littleMCP.x, y: p.indexMCP.y - p.littleMCP.y)
        let along  = CGPoint(x: p.middleMCP.x - p.wrist.x, y: p.middleMCP.y - p.wrist.y)
        let z = across.x * along.y - across.y * along.x
        let want = (chirality == .right) ? PalmConfig.palmFacingSign : -PalmConfig.palmFacingSign
        return z * want > 0
    }
}
