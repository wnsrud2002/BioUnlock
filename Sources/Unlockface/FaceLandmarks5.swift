//
//  FaceLandmarks5.swift
//  Unlockface
//
//  Vision 랜드마크에서 ArcFace 정렬용 5점을 뽑고, 거기서 머리 자세를 직접 계산한다.
//
//  Vision이 주는 VNFaceObservation.yaw/pitch/roll은 쓸 수 없다:
//    - pitch는 landmarks rev3에서 항상 nil
//    - roll/yaw는 π/6, π/4 단위로 양자화됨 (실측 확인)
//  포즈 버킷 임계값이 0.10 rad(5.7°) 수준이라 자체 계산이 필요하다.
//
//  좌표계: 전부 Vision 이미지 정규화 좌표(원점 좌하단, y 위로 증가).
//

import Foundation
import CoreGraphics
import Vision

// MARK: - 2D 벡터 도우미

private func norm(_ v: CGPoint) -> CGFloat { sqrt(v.x * v.x + v.y * v.y) }
private func unit(_ v: CGPoint) -> CGPoint {
    let n = norm(v)
    guard n > .leastNormalMagnitude else { return CGPoint(x: 1, y: 0) }
    return CGPoint(x: v.x / n, y: v.y / n)
}
private func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
private func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }

struct FaceLandmarks5: Equatable {
    /// 이미지 기준 왼쪽 눈(피사체의 오른쪽 눈). 미러링 여부와 무관하게 x가 작은 쪽.
    let leftEye: CGPoint
    let rightEye: CGPoint
    let noseTip: CGPoint
    let leftMouth: CGPoint
    let rightMouth: CGPoint

    /// 두 눈 모두 동공(leftPupil/rightPupil)에서 왔는지. 눈을 감으면 false가 되고
    /// 윤곽 중심으로 대체되면서 roll/pitch가 튄다. 품질 게이트에서 걸러야 한다.
    let usedPupils: Bool
    /// 코끝을 medianLine 교집합으로 확정했는지. false면 큰 yaw에서 신뢰도가 낮다.
    let noseTipFromMedianLine: Bool

    var asArray: [CGPoint] { [leftEye, rightEye, noseTip, leftMouth, rightMouth] }

    var eyeMid: CGPoint { mid(leftEye, rightEye) }
    var mouthMid: CGPoint { mid(leftMouth, rightMouth) }
    var interocular: CGFloat { norm(sub(rightEye, leftEye)) }

    // MARK: - 추출

    init?(observation: VNFaceObservation) {
        guard let lm = observation.landmarks else { return nil }
        let box = observation.boundingBox

        // 랜드마크는 bounding box 기준 정규화값이라 이미지 기준으로 되돌린다.
        func toImage(_ p: CGPoint) -> CGPoint {
            CGPoint(x: box.origin.x + p.x * box.width,
                    y: box.origin.y + p.y * box.height)
        }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.normalizedPoints ?? []).map(toImage)
        }
        func centroid(_ pts: [CGPoint]) -> CGPoint? {
            guard !pts.isEmpty else { return nil }
            return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                           y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
        }

        // 눈: 동공이 있으면 그대로, 없으면(눈 감음 등) 눈 윤곽 중심으로 대체.
        var pupilCount = 0
        func eyeCenter(pupil: VNFaceLandmarkRegion2D?, contour: VNFaceLandmarkRegion2D?) -> CGPoint? {
            if let p = points(pupil).first { pupilCount += 1; return p }
            return centroid(points(contour))
        }

        guard let eyeA = eyeCenter(pupil: lm.leftPupil, contour: lm.leftEye),
              let eyeB = eyeCenter(pupil: lm.rightPupil, contour: lm.rightEye) else { return nil }
        self.usedPupils = (pupilCount == 2)

        // Vision의 left/right는 피사체 기준이라 미러링에 따라 뒤집힌다. 화면 x 기준으로 재배치.
        let (eL, eR) = eyeA.x <= eyeB.x ? (eyeA, eyeB) : (eyeB, eyeA)
        self.leftEye = eL
        self.rightEye = eR

        let io = norm(sub(eR, eL))
        guard io > 0 else { return nil }
        let eyeMid = mid(eL, eR)

        // 입꼬리: 바깥 입술 윤곽의 좌우 최외곽.
        // 이 시점엔 얼굴 축이 아직 없으므로 눈선 방향을 임시 기준으로 쓴다.
        let provisionalX = unit(sub(eR, eL))
        let lips = points(lm.outerLips)
        guard lips.count >= 2, let lipCenter = centroid(lips) else { return nil }
        guard let mA = lips.min(by: { dot(provisionalX, sub($0, lipCenter)) < dot(provisionalX, sub($1, lipCenter)) }),
              let mB = lips.max(by: { dot(provisionalX, sub($0, lipCenter)) < dot(provisionalX, sub($1, lipCenter)) })
        else { return nil }
        self.leftMouth = mA
        self.rightMouth = mB

        // 얼굴 세로축: 눈중심 → 입중심. yaw 회전축과 거의 평행해서 yaw에 불변이다.
        // (눈선을 축으로 쓰면 yaw가 roll을 오염시킨다 — 실측 상관 -0.98)
        let axisY = unit(sub(mid(mA, mB), eyeMid))
        let axisX = CGPoint(x: -axisY.y, y: axisY.x)

        // 코끝.
        //
        // nose 영역과 medianLine(얼굴 중심선)은 코끝에서 같은 점을 공유한다.
        // 중심선은 yaw가 커져도 코를 따라가므로 이 교집합이 각도에 가장 강건하다.
        // "눈중심에서 일정 거리 안"으로 거르면 yaw 50°에서 코끝이 범위를 벗어나 콧방울을 집는다.
        let nosePoints = points(lm.nose)
        guard !nosePoints.isEmpty else { return nil }
        let medianPoints = points(lm.medianLine)

        let tolerance = io * 0.02
        let onMedian = nosePoints.filter { n in
            medianPoints.contains { norm(sub($0, n)) <= tolerance }
        }

        if let tip = onMedian.max(by: { dot(axisY, sub($0, eyeMid)) < dot(axisY, sub($1, eyeMid)) }) {
            self.noseTip = tip
            self.noseTipFromMedianLine = true
        } else {
            // 중심선이 없거나 겹치는 점이 없을 때만. 얼굴 축 기준 가로 편차가 가장 작은 점.
            guard let tip = nosePoints.min(by: {
                abs(dot(axisX, sub($0, eyeMid))) < abs(dot(axisX, sub($1, eyeMid)))
            }) else { return nil }
            self.noseTip = tip
            self.noseTipFromMedianLine = false
        }
    }
}

// MARK: - 자세 추정

struct FacePose: Equatable {
    let yaw: Double
    let pitch: Double
    let roll: Double

    /// 보정(calibration)용 원본 비율. gain을 맞출 때 이 값을 본다.
    let yawProxy: Double
    let pitchRatio: Double
    /// 눈선 기울기. yaw에 오염되므로 roll로 쓰지 않고 비교/진단용으로만 남긴다.
    let eyeLineRoll: Double
    /// 두 눈 사이 거리(이미지 폭 대비). bbox 폭보다 안정적이다.
    let interocular: CGFloat

    init(landmarks p: FaceLandmarks5) {
        let io = p.interocular
        self.interocular = io

        let eyeMid = p.eyeMid
        let mouthMid = p.mouthMid

        // 얼굴 세로축(아래 방향)을 기준으로 좌표계를 세운다.
        let axisY = unit(sub(mouthMid, eyeMid))
        let axisX = CGPoint(x: -axisY.y, y: axisY.x)

        // roll: 세로축이 화면 수직에서 얼마나 기울었는가.
        // Vision 좌표는 y가 위쪽이므로 정면일 때 axisY ≈ (0,-1).
        self.roll = Double(atan2(-axisY.x, -axisY.y))

        let eyeVec = sub(p.rightEye, p.leftEye)
        self.eyeLineRoll = Double(atan2(eyeVec.y, eyeVec.x))

        func along(_ axis: CGPoint, _ q: CGPoint) -> Double { Double(dot(axis, sub(q, eyeMid))) }

        // 강체 머리 모델: 코끝은 눈선 평면보다 앞으로 d 만큼 튀어나와 있다.
        // 머리가 θ만큼 돌면 코끝의 가로 변위는 d·sinθ, 눈 간격은 io·cosθ 로 줄어든다.
        //   yawProxy = (d/io)·tanθ  →  θ = atan(yawProxy / (d/io))
        let proxy = along(axisX, p.noseTip) / Double(max(io, .leastNonzeroMagnitude))
        self.yawProxy = proxy
        self.yaw = atan((proxy - FaceIDConfig.yawProxyNeutral) / FaceIDConfig.noseDepthRatio)

        // pitch는 눈–입 축에서 코끝이 차지하는 상대 위치로 본다.
        // 위를 보면 코끝이 눈 쪽으로 당겨져 비율이 작아지므로 baseline에서 뺀다.
        let faceHeight = along(axisY, mouthMid)
        let noseDepth = along(axisY, p.noseTip)
        let ratio = faceHeight != 0 ? noseDepth / faceHeight : FaceIDConfig.pitchNeutralRatio
        self.pitchRatio = ratio
        self.pitch = atan((FaceIDConfig.pitchNeutralRatio - ratio) / FaceIDConfig.noseDepthRatioVertical)
    }
}
