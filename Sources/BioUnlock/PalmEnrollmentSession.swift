//
//  PalmEnrollmentSession.swift
//  BioUnlock
//
//  초근접 손금 등록. 손을 카메라 코앞에 대고 있으면 N장을 모은다.
//
//  이전에는 2단계(정준 좌표 재추정 → 코드 수집)였다. 그 단계는 랜드마크로 손을
//  정렬할 때만 의미가 있었는데, 손금이 보이는 거리에서는 Vision 이 손을 아예
//  못 찾아 랜드마크 경로 자체가 성립하지 않았다(PalmCloseRange 주석 참고).
//  초근접은 화면 중앙을 그대로 쓰고 회전만 이미지에서 정규화하므로 한 단계로 끝난다.
//
//  왜 여러 장인가: 참조가 한 장이면 등록 당시 각도에서 조금만 벗어나도 점수가
//  무너진다. 여러 장 중 '가장 잘 맞는 것'을 쓰면 그 출렁임의 아래쪽 꼬리가 올라간다.
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
        case done(Int)
        case failed(String)
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var collected: Int = 0
    /// 게이트에 막혀 샘플을 못 담고 있을 때 그 이유. UI 안내용.
    @Published private(set) var blockedReason: String = ""

    private var codes: [PalmCode] = []
    private var rotations: [Float] = []
    private var lastAccepted = Date.distantPast

    var isActive: Bool { step == .collecting }

    var progress: Double {
        Double(collected) / Double(max(1, PalmConfig.enrollmentSampleCount))
    }

    func start() {
        codes.removeAll()
        rotations.removeAll()
        collected = 0
        blockedReason = ""
        lastAccepted = .distantPast
        step = .collecting
        DiagnosticLog.write("palm 등록 시작 (초근접, 목표 \(PalmConfig.enrollmentSampleCount)장)")
    }

    func cancel() {
        codes.removeAll()
        rotations.removeAll()
        collected = 0
        blockedReason = ""
        step = .idle
    }

    /// 손금을 계산한 프레임마다 메인 스레드에서 불린다.
    func feed(_ palm: PalmFrameResult) {
        guard step == .collecting else { return }

        if !palm.passesSkinGate {
            blockedReason = String(format: "손바닥이 화면을 덮도록 더 가까이 (살색 %.0f%%)",
                                   palm.skinFraction * 100)
            return
        }
        if !palm.passesTextureGate {
            blockedReason = String(format: "손금이 안 잡힙니다 — 거리·조명을 조절하세요 (텍스처 %.0f%%)",
                                   palm.salience * 100)
            return
        }
        blockedReason = ""

        // 연속 프레임을 그대로 담으면 거의 같은 사진 N장이 된다.
        guard Date().timeIntervalSince(lastAccepted) >= PalmConfig.enrollmentSampleInterval else { return }

        lastAccepted = Date()
        codes.append(palm.code)
        rotations.append(palm.rotationDegrees)
        collected = codes.count
        DiagnosticLog.write(String(format: "palm 샘플 %d/%d 텍스처=%.3f 살색=%.2f 회전=%+.1f도",
                                   collected, PalmConfig.enrollmentSampleCount,
                                   palm.salience, palm.skinFraction, palm.rotationDegrees))

        guard codes.count >= PalmConfig.enrollmentSampleCount else { return }
        finalize()
    }

    private func finalize() {
        guard !codes.isEmpty else {
            step = .failed("샘플을 모으지 못했습니다")
            return
        }
        PalmProfileStore.shared.register(PalmProfile(codes: codes))

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

        // 회전 추정이 흔들리면 코드가 서로 어긋난다. 등록 샘플 간 편차를 같이
        // 남겨서, 일관성이 낮을 때 원인이 회전인지 아닌지 구분할 수 있게 한다.
        let rotSpread = (rotations.max() ?? 0) - (rotations.min() ?? 0)
        DiagnosticLog.write(String(
            format: "palm 등록 완료 샘플=%d 내부일관성 평균=%.3f 최저=%.3f 회전편차=%.1f도 (임계 %.2f)",
            codes.count, avgSim, minSim, rotSpread, PalmConfig.matchThreshold))

        step = .done(codes.count)
    }
}
