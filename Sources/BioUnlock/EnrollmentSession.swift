//
//  EnrollmentSession.swift
//  BioUnlock
//
//  포즈 버킷별로 샘플을 모아 프로필을 만드는 등록 절차.
//
//  버킷마다 후보 프레임을 여러 장 모은 뒤 가장 선명한 것만 남긴다. 흐린 샘플이
//  프로필에 들어가면 이후 인증 임계값이 통째로 느슨해지기 때문이다.
//

import Foundation
import Combine
import UnlockKit

@MainActor
final class EnrollmentSession: ObservableObject {

    enum Step: Equatable {
        case idle
        case collecting(FacePoseBucket)
        case extendedPrompt
        case finalizing
        case done(String)
        case failed(String)
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var captured: [FacePoseBucket: Int] = [:]
    @Published private(set) var hint: String = ""
    @Published private(set) var rejectReason: String = ""

    private var candidates: [FacePoseBucket: [PoseSample]] = [:]
    /// 버킷별 마지막 채택 시각. 연속 프레임이 몰려 들어오는 것을 막는다.
    private var lastAccepted: [FacePoseBucket: Date] = [:]
    private var neutralYawProxies: [Double] = []
    private var neutralPitchRatios: [Double] = []
    private var profileName = ""
    private var includeExtended = false

    /// 현재 진행 중인 버킷 순서.
    private var plan: [FacePoseBucket] = []
    private var planIndex = 0

    /// rejectReason 은 UI 전용이라 파일 로그로는 왜 막히는지 알 수 없었다.
    /// (실제로 3번의 등록 시도가 전부 진행 없이 끝났는데 원인을 특정할 수 없었다.)
    /// 진단을 위해 어느 게이트에서 막히는지 주기적으로 로그에 남긴다.
    private var lastDiagLog = Date.distantPast

    var isActive: Bool { Self.isActive(for: step) }

    /// AppCoordinator 가 $step 구독 안에서 방금 emit된 값으로 직접 계산할 수 있도록
    /// 정적으로도 노출한다. @Published 는 willSet 에서 값을 내보내는데, 그 시점엔
    /// self.step 의 실제 저장값이 아직 새 값으로 갱신되기 전이다. 구독 콜백 안에서
    /// self.enrollment.isActive 처럼 인스턴스 프로퍼티를 다시 읽으면 '한 단계 이전'
    /// 값을 보게 된다 — 실제로 이 버그 때문에 등록 시작 시 camera.setEnrolling(true)가
    /// 한 번도 불리지 않아 TTA 임베딩이 계속 nil이었고, 등록이 첫 버킷에서 멈췄다.
    static func isActive(for step: Step) -> Bool {
        switch step {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    // MARK: - 제어

    func start(name: String) {
        profileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileName.isEmpty else {
            step = .failed("이름을 입력하세요")
            return
        }
        candidates.removeAll()
        captured.removeAll()
        lastAccepted.removeAll()
        neutralYawProxies.removeAll()
        neutralPitchRatios.removeAll()
        includeExtended = false

        // 이전에 등록한 다른 사람의 보정값이 남아있으면 지금 등록하는 사람의
        // 포즈 버킷 판정(특히 center)이 어긋난다. 기본값으로 되돌리고, 이 사람
        // 고유의 값은 center 버킷을 모으면서 다시 측정해 finalize() 에서 저장한다.
        FaceIDConfig.yawProxyNeutral = FaceIDConfig.yawProxyNeutralDefault
        FaceIDConfig.pitchNeutralRatio = FaceIDConfig.pitchNeutralRatioDefault
        plan = FacePoseBucket.core
        planIndex = 0
        progress = 0
        rejectReason = ""
        step = .collecting(plan[0])
        hint = plan[0].hint
        DiagnosticLog.write("enroll 시작 '\(profileName)'")
    }

    func cancel() {
        step = .idle
        hint = ""
        rejectReason = ""
        candidates.removeAll()
        captured.removeAll()
    }

    func acceptExtended() {
        includeExtended = true
        plan = FacePoseBucket.extended
        planIndex = 0
        step = .collecting(plan[0])
        hint = plan[0].hint
    }

    func declineExtended() {
        finalize()
    }

    // MARK: - 프레임 입력

    func feed(face: FaceFrameInfo, aligned: AlignedFaceResult) {
        guard case .collecting(let bucket) = step else { return }

        if Date().timeIntervalSince(lastDiagLog) >= 1.0 {
            lastDiagLog = Date()
            DiagnosticLog.write(String(
                format: "enroll 진단 bucket=%@ align=%@ sharp=%.0f/%.0f ttaNil=%@ matched=%@ yaw=%+.3f pitch=%+.3f roll=%+.3f io=%.4f",
                bucket.rawValue,
                aligned.passesAlignment ? "OK" : "X",
                aligned.sharpness, FaceIDConfig.enrollmentBlurThreshold,
                aligned.embeddingTTA == nil ? "Y" : "N",
                face.matchedBuckets.map(\.rawValue).joined(separator: ","),
                face.pose.yaw, face.pose.pitch, face.pose.roll, face.pose.interocular))
        }

        guard aligned.passesAlignment else {
            rejectReason = String(format: "정렬 불안정 (residual %.1f)", aligned.residual)
            return
        }
        guard aligned.sharpness >= FaceIDConfig.enrollmentBlurThreshold else {
            rejectReason = String(format: "흐림 (%.0f < %.0f)",
                                  aligned.sharpness, FaceIDConfig.enrollmentBlurThreshold)
            return
        }
        guard let embedding = aligned.embeddingTTA else {
            rejectReason = "임베딩 없음"
            return
        }
        guard face.matchedBuckets.contains(bucket) else {
            rejectReason = ""
            hint = bucket.hint
            return
        }

        // 같은 버킷 안에서 너무 촘촘히 뽑으면 사실상 같은 프레임이 중복된다.
        if let last = lastAccepted[bucket],
           Date().timeIntervalSince(last) < FaceIDConfig.minSampleInterval {
            rejectReason = ""
            hint = bucket.hint + " (자세 유지)"
            return
        }

        rejectReason = ""
        hint = bucket.hint
        lastAccepted[bucket] = Date()
        candidates[bucket, default: []].append(
            PoseSample(bucket: bucket.rawValue, embedding: embedding, sharpness: aligned.sharpness))
        captured[bucket] = candidates[bucket]?.count ?? 0

        // 정면 프레임에서 사용자별 중립 자세를 같이 기록한다.
        if bucket == .center {
            neutralYawProxies.append(face.pose.yawProxy)
            neutralPitchRatios.append(face.pose.pitchRatio)
        }

        updateProgress()

        if (candidates[bucket]?.count ?? 0) >= FaceIDConfig.framesPerPose {
            advance()
        }
    }

    // MARK: - 진행

    private func advance() {
        planIndex += 1
        if planIndex < plan.count {
            let next = plan[planIndex]
            step = .collecting(next)
            hint = next.hint
            return
        }
        if !includeExtended {
            step = .extendedPrompt
            hint = "필수 등록 완료. 확장 포즈도 등록하면 인식률이 올라갑니다."
            return
        }
        finalize()
    }

    private func updateProgress() {
        let total = plan.count * FaceIDConfig.framesPerPose
        let got = plan.reduce(0) { $0 + min(FaceIDConfig.framesPerPose, candidates[$1]?.count ?? 0) }
        progress = total > 0 ? Double(got) / Double(total) : 0
    }

    private func finalize() {
        step = .finalizing
        hint = "프로필을 만드는 중…"

        // 버킷마다 가장 선명한 것만 남긴다.
        var kept: [PoseSample] = []
        for (bucket, list) in candidates {
            let target = FaceIDConfig.samplesToKeep(for: bucket)
            kept.append(contentsOf: list.sorted { $0.sharpness > $1.sharpness }.prefix(target))
        }

        guard kept.count >= FacePoseBucket.core.count else {
            step = .failed("샘플이 부족합니다 (\(kept.count)개)")
            return
        }

        let yawNeutral = neutralYawProxies.isEmpty ? 0 : neutralYawProxies.reduce(0, +) / Double(neutralYawProxies.count)
        let pitchNeutral = neutralPitchRatios.isEmpty
            ? FaceIDConfig.pitchNeutralRatio
            : neutralPitchRatios.reduce(0, +) / Double(neutralPitchRatios.count)

        FaceProfileStore.shared.register(name: profileName,
                                         samples: kept,
                                         neutralYawProxy: yawNeutral,
                                         neutralPitchRatio: pitchNeutral)

        // 등록 샘플끼리의 일관성을 남겨둔다. 낮으면 등록이 잘못된 것이다.
        var sims: [Float] = []
        for i in 0..<kept.count {
            for j in (i + 1)..<kept.count {
                sims.append(VectorMath.cosineSimilarity(kept[i].embedding, kept[j].embedding))
            }
        }
        let minSim = sims.min() ?? 1
        let avgSim = sims.isEmpty ? 1 : sims.reduce(0, +) / Float(sims.count)
        DiagnosticLog.write(String(format: "enroll 완료 '%@' 샘플=%d 내부일관성 평균=%.3f 최저=%.3f",
                                   profileName, kept.count, avgSim, minSim))

        progress = 1
        step = .done(String(format: "%@ · 샘플 %d개 · 내부 일관성 평균 %.3f",
                            profileName, kept.count, avgSim))
        hint = ""
    }
}
