//
//  PalmEnrollmentSession.swift
//  BioUnlock
//
//  손바닥 샘플을 여러 장 모아 프로필을 만드는 등록 절차.
//
//  얼굴 EnrollmentSession의 축소판이다 — 포즈 버킷은 없고(손바닥은 정면 하나뿐),
//  대신 같은 자세에서 시간 간격을 두고 N장을 모은다. 간격을 두는 이유는 얼굴과
//  같다: 연속 프레임은 거의 같은 사진이라 여러 장 모으는 의미가 없다.
//
//  왜 여러 장인가 — 참조가 한 장이면 등록 당시 각도에서 조금만 벗어나도 점수가
//  무너진다. 실측(2026-08-28)에서 같은 손인데 0.57~0.84로 출렁여 10번 중 1번만
//  잠금이 풀렸다.
//

import Foundation
import Combine
import UnlockKit
import Unlockpalm

@MainActor
final class PalmEnrollmentSession: ObservableObject {

    enum Step: Equatable {
        case idle
        case collecting
        case done(Int)          // 모은 샘플 수
        case failed(String)
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var collected: Int = 0
    /// 게이트에 막혀 샘플을 못 담고 있을 때 그 이유. UI 안내용.
    @Published private(set) var blockedReason: String = ""

    private var codes: [PalmCode] = []
    private var lastAccepted = Date.distantPast

    var isActive: Bool { step == .collecting }

    var progress: Double {
        Double(collected) / Double(max(1, PalmConfig.enrollmentSampleCount))
    }

    func start() {
        codes.removeAll()
        collected = 0
        blockedReason = ""
        step = .collecting
        lastAccepted = .distantPast
        DiagnosticLog.write("palm 등록 시작 (목표 \(PalmConfig.enrollmentSampleCount)장)")
    }

    func cancel() {
        codes.removeAll()
        collected = 0
        blockedReason = ""
        step = .idle
    }

    /// 프레임마다 메인 스레드에서 불린다. 게이트를 통과한 프레임만 샘플로 담는다.
    func feed(_ palm: AlignedPalmResult) {
        guard step == .collecting else { return }

        guard palm.isPalmFacing else {
            blockedReason = "손바닥이 카메라를 향하지 않습니다"
            return
        }
        guard palm.passesSourcePixelGate else {
            blockedReason = String(format: "손을 더 가까이 (%.0f/%.0f px)",
                                   palm.sourcePixels, PalmConfig.minSourcePixels)
            return
        }
        guard palm.passesAlignmentGate else {
            blockedReason = String(format: "손을 평평하게 펴 주세요 (정렬 %.1f px)", palm.residual)
            return
        }
        // 연속 프레임을 그대로 담으면 거의 같은 사진 N장이 된다.
        guard Date().timeIntervalSince(lastAccepted) >= PalmConfig.enrollmentSampleInterval else {
            blockedReason = ""
            return
        }

        let luma = FacePreprocessor.luma(from: palm.pixels,
                                         count: PalmAligner.roiOutputSize * PalmAligner.roiOutputSize)
        guard let code = PalmMatcher.encode(luma: luma, size: PalmAligner.roiOutputSize) else {
            blockedReason = "인코딩 실패"
            return
        }

        blockedReason = ""
        lastAccepted = Date()
        codes.append(code)
        collected = codes.count
        DiagnosticLog.write(String(format: "palm 샘플 %d/%d validRatio=%.3f residual=%.2f",
                                   collected, PalmConfig.enrollmentSampleCount,
                                   code.validRatio, palm.residual))

        if codes.count >= PalmConfig.enrollmentSampleCount { finalize() }
    }

    private func finalize() {
        guard !codes.isEmpty else {
            step = .failed("샘플을 모으지 못했습니다")
            return
        }
        PalmProfileStore.shared.register(codes)

        // 등록 샘플끼리 얼마나 일관적인지 남긴다. 낮으면 등록이 잘못된 것이고,
        // 이 값이 실사용 점수의 상한 가늠자가 된다(얼굴 등록의 내부 일관성과 같은 역할).
        var sims: [Float] = []
        for i in 0..<codes.count {
            for j in (i + 1)..<codes.count {
                if let s = PalmMatcher.score(codes[i], codes[j]) { sims.append(s) }
            }
        }
        let minSim = sims.min() ?? 0
        let avgSim = sims.isEmpty ? 0 : sims.reduce(0, +) / Float(sims.count)
        DiagnosticLog.write(String(format: "palm 등록 완료 샘플=%d 내부일관성 평균=%.3f 최저=%.3f",
                                   codes.count, avgSim, minSim))

        step = .done(codes.count)
    }
}
