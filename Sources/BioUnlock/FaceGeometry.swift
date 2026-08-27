//
//  FaceGeometry.swift
//  BioUnlock
//

import Foundation
import CoreGraphics
import Vision

/// 등록 시 수집해야 하는 머리 자세 버킷.
enum FacePoseBucket: String, CaseIterable {
    case center, left, right, up, down, tiltLeft, tiltRight, closer, farther

    /// core는 필수, extended는 선택 등록.
    static let core: [FacePoseBucket] = [.center, .left, .right]
    static let extended: [FacePoseBucket] = [.up, .down, .tiltLeft, .tiltRight, .closer, .farther]

    var hint: String {
        switch self {
        case .center:    return "정면을 봐주세요"
        case .left:      return "천천히 왼쪽으로"
        case .right:     return "천천히 오른쪽으로"
        case .up:        return "살짝 위를 보세요"
        case .down:      return "살짝 아래를 보세요"
        case .tiltLeft:  return "고개를 왼쪽으로 기울이세요"
        case .tiltRight: return "고개를 오른쪽으로 기울이세요"
        case .closer:    return "조금 더 가까이"
        case .farther:   return "조금 더 멀리"
        }
    }

    /// 거리 판정은 bbox 폭이 아니라 눈 간격(interocular)으로 한다.
    /// 같은 거리에서 실측 변동계수가 bbox 폭 3.6% vs 눈 간격 0.6%로 6배 안정적이다.
    func matches(yaw: Double, pitch: Double, roll: Double, interocular: CGFloat) -> Bool {
        switch self {
        case .center:
            return abs(yaw) < 0.15 && abs(roll) < 0.25 && abs(pitch) < 0.25
                && interocular >= FaceIDConfig.interocularMin
                && interocular <= FaceIDConfig.interocularMax
        case .left:      return yaw < -0.10
        case .right:     return yaw > 0.10
        case .up:        return pitch > 0.08
        case .down:      return pitch < -0.08
        case .tiltLeft:  return roll < -0.12
        case .tiltRight: return roll > 0.12
        case .closer:    return interocular > FaceIDConfig.interocularMax
        case .farther:   return interocular < FaceIDConfig.interocularMin
                              && interocular > FaceIDConfig.interocularFloor
        }
    }
}

/// 한 프레임에서 뽑아낸 얼굴 관측 결과. UI로 그대로 넘긴다.
struct FaceFrameInfo: Equatable {
    /// Vision 정규화 좌표(원점 좌하단).
    var boundingBox: CGRect
    /// 이미지 전체 폭 대비 얼굴 폭 비율. 거리 판정에 쓴다.
    var faceWidth: CGFloat
    /// 랜드마크에서 직접 계산한 자세. Vision이 주는 각도는 쓰지 않는다.
    var pose: FacePose
    /// ArcFace 정렬용 5점. Phase 2에서 그대로 쓴다.
    var keyPoints: FaceLandmarks5
    /// 랜드마크 전체를 이미지 정규화 좌표로 펼친 것(원점 좌하단). 디버그 표시용.
    var landmarks: [CGPoint]

    var yaw: Double { pose.yaw }
    var pitch: Double { pose.pitch }
    var roll: Double { pose.roll }

    var matchedBuckets: [FacePoseBucket] {
        FacePoseBucket.allCases.filter {
            $0.matches(yaw: yaw, pitch: pitch, roll: roll, interocular: pose.interocular)
        }
    }

    init?(observation: VNFaceObservation) {
        let box = observation.boundingBox
        guard box.width > 0, box.height > 0 else { return nil }

        guard let key = FaceLandmarks5(observation: observation) else { return nil }
        self.boundingBox = box
        self.faceWidth = box.width
        self.keyPoints = key
        self.pose = FacePose(landmarks: key)

        // 랜드마크는 bounding box 기준 정규화값이라 이미지 기준으로 되돌린다.
        if let points = observation.landmarks?.allPoints?.normalizedPoints {
            self.landmarks = points.map {
                CGPoint(x: box.origin.x + $0.x * box.width,
                        y: box.origin.y + $0.y * box.height)
            }
        } else {
            self.landmarks = []
        }
    }
}
