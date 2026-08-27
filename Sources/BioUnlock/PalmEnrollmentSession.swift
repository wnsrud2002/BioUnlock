//
//  PalmEnrollmentSession.swift
//  BioUnlock
//
//  손바닥 등록. 2단계로 나뉜다.
//
//    1단계 (형상 측정) — 5점만 모아 이 사용자의 정준 좌표를 재추정한다.
//    2단계 (코드 수집) — 그 정준 좌표로 자른 ROI에서 CompCode를 뽑는다.
//
//  왜 나눠야 하나: ROI를 어디서 자를지가 정준 좌표에 달려 있다. 좌표를 바꾸면
//  그 전에 뽑아둔 코드는 다른 곳을 가리키게 되어 전부 무효다. 그래서 좌표를
//  먼저 확정하고, 그다음에 코드를 뽑는다.
//
//  왜 재추정이 필요한가: 기본 정준 좌표는 눈대중 값이라 실제 손 형상과 어긋나
//  있었다. 잔차가 3.2~5.9px(게이트 6.0)로 상시 높았고, 매 프레임 ROI가 다른
//  곳을 잘라 같은 손을 같은 세션에서 찍어도 코드가 0.66까지 어긋났다
//  (2026-08-28 실측 — 다른 사람 손 점수와 구분이 안 되는 수준이었다).
//

import Foundation
import CoreGraphics
import Combine
import UnlockKit
import Unlockpalm

@MainActor
final class PalmEnrollmentSession: ObservableObject {

    enum Step: Equatable {
        case idle
        case measuring          // 1단계: 형상 측정
        case collecting         // 2단계: 코드 수집
        case done(Int)
        case failed(String)
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var collected: Int = 0
    /// 게이트에 막혀 샘플을 못 담고 있을 때 그 이유. UI 안내용.
    @Published private(set) var blockedReason: String = ""

    private var shapes: [[CGPoint]] = []
    private var codes: [PalmCode] = []
    private var calibrated: [CGPoint]?
    private var lastAccepted = Date.distantPast

    var isActive: Bool { step == .measuring || step == .collecting }

    var progress: Double {
        Double(collected) / Double(max(1, PalmConfig.enrollmentSampleCount))
    }

    var phaseLabel: String {
        switch step {
        case .measuring:  return "1/2 손 모양 재는 중"
        case .collecting: return "2/2 손금 담는 중"
        default:          return ""
        }
    }

    func start() {
        shapes.removeAll()
        codes.removeAll()
        calibrated = nil
        collected = 0
        blockedReason = ""
        lastAccepted = .distantPast
        // 1단계는 기본 좌표로 게이트만 통과시키면 되므로 임시값을 비운다.
        PalmProfileStore.shared.endCalibration()
        step = .measuring
        DiagnosticLog.write("palm 등록 시작 (1단계 형상 측정, 목표 \(PalmConfig.enrollmentSampleCount)장)")
    }

    func cancel() {
        shapes.removeAll()
        codes.removeAll()
        calibrated = nil
        collected = 0
        blockedReason = ""
        PalmProfileStore.shared.endCalibration()
        step = .idle
    }

    /// 프레임마다 메인 스레드에서 불린다.
    func feed(_ palm: AlignedPalmResult) {
        switch step {
        case .measuring:  feedMeasuring(palm)
        case .collecting: feedCollecting(palm)
        default:          return
        }
    }

    // MARK: - 게이트

    /// 통과하면 nil, 막히면 사용자에게 보여줄 이유.
    private func gateFailure(_ palm: AlignedPalmResult) -> String? {
        if !palm.isPalmFacing { return "손바닥이 카메라를 향하지 않습니다" }
        if !palm.passesSourcePixelGate {
            return String(format: "손을 더 가까이 (%.0f/%.0f px)",
                          palm.sourcePixels, PalmConfig.minSourcePixels)
        }
        if !palm.passesAlignmentGate {
            return String(format: "손을 평평하게 펴 주세요 (정렬 %.1f px)", palm.residual)
        }
        return nil
    }

    /// 연속 프레임을 그대로 담으면 거의 같은 사진 N장이 된다.
    private func intervalElapsed() -> Bool {
        Date().timeIntervalSince(lastAccepted) >= PalmConfig.enrollmentSampleInterval
    }

    // MARK: - 1단계: 형상 측정

    private func feedMeasuring(_ palm: AlignedPalmResult) {
        if let reason = gateFailure(palm) { blockedReason = reason; return }
        blockedReason = ""
        guard intervalElapsed() else { return }

        lastAccepted = Date()
        shapes.append(palm.alignmentPointsInImage)
        collected = shapes.count

        guard shapes.count >= PalmConfig.enrollmentSampleCount else { return }
        beginSecondPhase()
    }

    private func beginSecondPhase() {
        guard let canonical = PalmAligner.calibrated(from: shapes) else {
            step = .failed("손 모양을 재지 못했습니다 — 다시 시도해 주세요")
            return
        }
        calibrated = canonical
        PalmProfileStore.shared.beginCalibration(canonical)

        collected = 0
        lastAccepted = .distantPast
        step = .collecting
        DiagnosticLog.write("palm 등록 1단계 완료 — 정준 좌표 재추정됨, 2단계 시작")
    }

    // MARK: - 2단계: 코드 수집

    private func feedCollecting(_ palm: AlignedPalmResult) {
        if let reason = gateFailure(palm) { blockedReason = reason; return }
        blockedReason = ""
        guard intervalElapsed() else { return }

        guard let code = PalmMatcher.encode(rgba: palm.pixels, size: PalmAligner.roiOutputSize) else {
            blockedReason = "인코딩 실패"
            return
        }

        lastAccepted = Date()
        codes.append(code)
        collected = codes.count
        DiagnosticLog.write(String(format: "palm 샘플 %d/%d validRatio=%.3f residual=%.2f",
                                   collected, PalmConfig.enrollmentSampleCount,
                                   code.validRatio, palm.residual))

        guard codes.count >= PalmConfig.enrollmentSampleCount else { return }
        finalize()
    }

    private func finalize() {
        guard let canonical = calibrated, !codes.isEmpty else {
            step = .failed("샘플을 모으지 못했습니다")
            PalmProfileStore.shared.endCalibration()
            return
        }
        PalmProfileStore.shared.register(PalmProfile(codes: codes, canonical: canonical))
        // 저장된 프로필이 같은 좌표를 들고 있으므로 임시값은 비운다.
        PalmProfileStore.shared.endCalibration()

        // 등록 샘플끼리의 일관성이 곧 실사용 점수의 상한이다. 이 값이 임계값보다
        // 낮으면 그 임계값으로는 본인도 절대 통과할 수 없다 — 실제로 그랬다.
        var sims: [Float] = []
        for i in 0..<codes.count {
            for j in (i + 1)..<codes.count {
                if let s = PalmMatcher.score(codes[i], codes[j]) { sims.append(s) }
            }
        }
        let minSim = sims.min() ?? 0
        let avgSim = sims.isEmpty ? 0 : sims.reduce(0, +) / Float(sims.count)
        DiagnosticLog.write(String(format: "palm 등록 완료 샘플=%d 내부일관성 평균=%.3f 최저=%.3f (임계 %.2f)",
                                   codes.count, avgSim, minSim, PalmConfig.matchThreshold))

        step = .done(codes.count)
    }
}
